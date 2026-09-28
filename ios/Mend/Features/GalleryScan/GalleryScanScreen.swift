import MapKit
import Photos
import SwiftUI
import Vision

/// A photo the on-device pipeline flagged. Nothing about it leaves the phone until the user approves it.
struct GalleryCandidate: Identifiable {
    enum Decision { case undecided, approved, skipped }
    enum Upload { case idle, uploading, done(Verification), failed(String) }

    let asset: PHAsset
    let thumbnail: UIImage
    let types: [DamageType]
    let severity: Severity?
    var decision = Decision.undecided
    var upload = Upload.idle
    let clientId = UUID()  // same id on retry: verify-report won't file it twice

    var id: String { asset.localIdentifier }
    var isPendingUpload: Bool {
        guard decision == .approved else { return false }
        switch upload {
        case .idle, .failed: return true
        case .uploading, .done: return false
        }
    }
}

/// Gallery scan (CLAUDE.md §6.3, MASTER.md §7.4): recent photos with GPS -> scene gate + classifier + detector,
/// all on-device -> candidates -> the user approves -> approved ones go through verify-report as source "library".
// ponytail: foreground only, latest 200 photos; BGProcessingTask while charging (MASTER §7.4) when the demo needs it.
@MainActor @Observable
final class GalleryScanModel {
    enum Phase: Equatable { case intro, denied, scanning, review }

    static let scanLimit = 200

    var phase = Phase.intro
    var scanned = 0
    var total = 0
    var candidates: [GalleryCandidate] = []
    var isLimited = false
    var isUploading = false
    private var scanTask: Task<Void, Never>?
    private var scanID = 0  // a rescan (Add photos) supersedes the running scan
    private let classifier = try? DamageClassifier()
    private let detector = try? DamageDetector()

    var approvedCount: Int { candidates.filter(\.isPendingUpload).count }

    func start() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        isLimited = status == .limited
        guard status == .authorized || status == .limited else { phase = .denied; return }
        scan()
    }

    /// Limited access: let the user add more photos, then rescan.
    func addPhotos() async {
        guard var top = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        _ = await PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
        scan()
    }

    func stop() { scanTask?.cancel() }

    private func scan() {
        scanTask?.cancel()
        scanID += 1
        let id = scanID
        phase = .scanning
        candidates = []
        scanned = 0
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = Self.scanLimit
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        let uploaded = Set(UserDefaults.standard.stringArray(forKey: GalleryScanScreen.uploadedKey) ?? [])
        fetched.enumerateObjects { asset, _, _ in  // no GPS, no report
            if asset.location != nil, !uploaded.contains(asset.localIdentifier) { assets.append(asset) }
        }
        total = assets.count
        scanTask = Task {
            for asset in assets {
                if Task.isCancelled { break }
                let candidate = await check(asset)
                guard id == scanID else { return }
                if let candidate { candidates.append(candidate) }
                scanned += 1
            }
            guard id == scanID else { return }  // superseded: the new scan owns the phase. "Stop scan" still lands in review.
            phase = .review
            AccessibilityNotification.Announcement("Scan finished. \(candidates.count) possible finds.").post()
        }
    }

    private func check(_ asset: PHAsset) async -> GalleryCandidate? {
        guard let classifier, let image = await Self.image(for: asset, side: 768, network: false),
              let (findings, offTopic) = try? await classifier.classify(image) else { return nil }
        let issues = offTopic ? [] : (try? await detector?.detect(image)) ?? []
        guard DamageClassifier.looksLikeDamage(findings: findings, issues: issues, offTopic: offTopic) else { return nil }
        var types = findings.map(\.type)
        for issue in issues where !types.contains(issue.type) { types.append(issue.type) }
        return GalleryCandidate(asset: asset, thumbnail: image, types: types, severity: DamageClassifier.preliminarySeverity(findings))
    }

    func upload() async {
        isUploading = true
        defer { isUploading = false }
        for index in candidates.indices where candidates[index].isPendingUpload {
            let candidate = candidates[index]
            candidates[index].upload = .uploading
            guard let full = await Self.image(for: candidate.asset, side: 1568, network: true) else {
                candidates[index].upload = .failed("Couldn't load the photo.")
                continue
            }
            let photo = CapturedPhoto(image: Self.blurringFaces(full), location: candidate.asset.location, heading: nil,
                                      capturedAt: candidate.asset.creationDate ?? .now, fromLibrary: true)
            do {
                let verdict = try await ReportService.verify(image: photo.image, photo: photo, suggested: candidate.types, note: "", clientId: candidate.clientId)
                candidates[index].upload = .done(verdict)
                let uploaded = UserDefaults.standard.stringArray(forKey: GalleryScanScreen.uploadedKey) ?? []
                UserDefaults.standard.set(uploaded + [candidate.id], forKey: GalleryScanScreen.uploadedKey)
            } catch {
                candidates[index].upload = .failed(error.localizedDescription)
            }
        }
        AccessibilityNotification.Announcement("Upload finished.").post()
    }

    // MARK: Pure rules (MendTests/GalleryScanTests)

    /// Older photos are useful as trend baselines but can't show current condition (CLAUDE.md §6.3). UI tag only.
    nonisolated static func isHistorical(_ date: Date?, now: Date = .now) -> Bool {
        guard let date, let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now) else { return false }
        return date < cutoff
    }

    /// "Possible crack", "Possible crack + pothole". MASTER §8 wants Foundation Models titles; this is the fallback.
    nonisolated static func title(_ types: [DamageType]) -> String {
        "Possible " + types.prefix(2).map { $0.label.lowercased() }.joined(separator: " + ")
    }

    // MARK: Photos

    private static func image(for asset: PHAsset, side: CGFloat, network: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat  // one callback
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = network   // the scan never pulls from iCloud
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }  // wait for the final image
                continuation.resume(returning: image)
            }
        }
    }

    /// Blur faces before upload (CLAUDE.md §8 privacy). Returns the photo upright.
    // ponytail: faces only; license plates need a plate detector (none shipped), add with the next model.
    nonisolated static func blurringFaces(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
        guard let cgImage = upright.cgImage else { return upright }
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        guard let faces = request.results, !faces.isEmpty else { return upright }
        let input = CIImage(cgImage: cgImage)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 30)
        let output = faces.reduce(input) { result, face in
            let box = VNImageRectForNormalizedRect(face.boundingBox, cgImage.width, cgImage.height)
            return blurred.cropped(to: box.insetBy(dx: -box.width * 0.2, dy: -box.height * 0.2)).composited(over: result)
        }
        guard let blurredImage = CIContext().createCGImage(output, from: input.extent) else { return upright }
        return UIImage(cgImage: blurredImage)
    }
}

struct GalleryScanScreen: View {
    /// UserDefaults: asset IDs already sent, so a rescan doesn't offer them again. Cleared by "Reset demo player".
    static let uploadedKey = "galleryUploaded"
    private static let actionMaxWidth: CGFloat = 240  // matches GameContainer's empty-state action
    @Environment(\.dismiss) private var dismiss
    @State private var model = GalleryScanModel()

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .intro: intro
                case .denied: denied
                case .scanning, .review: results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.flCanvas)
            .navigationTitle("Scan my photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.stop(); dismiss() }
                        .disabled(model.isUploading)  // finish sending first; the summary says what landed
                }
            }
        }
        .interactiveDismissDisabled(model.isUploading)
    }

    // MARK: Explain before asking (MASTER §7.4)

    private var intro: some View {
        ScrollView {
            VStack(spacing: FLSpace.xl) {
            Image(systemName: "photo.stack")
                .font(.system(.largeTitle).weight(.semibold))
                .foregroundStyle(.flBrand)
                .accessibilityHidden(true)
            VStack(spacing: FLSpace.sm) {
                Text("Find damage in photos you already took").font(.flTitle).foregroundStyle(.flInk).multilineTextAlignment(.center)
                Text("Mend checks your latest \(GalleryScanModel.scanLimit) photos that have a location. The scan runs on your iPhone, and nothing uploads unless you approve it. Place names come from Apple Maps.")
                    .font(.flCallout).foregroundStyle(.flInk2).multilineTextAlignment(.center)
            }
            }
            .padding(FLSpace.gutter)
            .padding(.top, FLSpace.xxxl)
        }
        .safeAreaInset(edge: .bottom) {  // pinned, so long copy at large text sizes scrolls instead of truncating
            Button("Scan my photos") { Task { await model.start() } }
                .buttonStyle(.flPrimary)
                .padding(FLSpace.gutter)
                .background(.flCanvas)
        }
    }

    private var denied: some View {
        FLEmptyState(title: "Photo access is off", systemImage: "photo.badge.exclamationmark",
                     message: "Turn on photo access in Settings to scan your photos. You can pick just some photos.") {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.flPrimary).frame(maxWidth: Self.actionMaxWidth)
        }
    }

    // MARK: Progress + candidates

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: FLSpace.lg) {
                if model.phase == .scanning { progress } else { summary }
                if model.isLimited, model.phase == .review {
                    HStack(spacing: FLSpace.sm) {
                        Text("Mend only sees the photos you picked.").font(.flCallout).foregroundStyle(.flInk2)
                        Spacer(minLength: 0)
                        Button("Add photos") { Task { await model.addPhotos() } }
                            .font(.flCallout.weight(.semibold))
                            .frame(minHeight: FLSpace.minTap)
                            .disabled(model.isUploading)
                    }
                }
                ForEach($model.candidates) { $candidate in
                    CandidateCard(candidate: $candidate, locked: model.isUploading)
                }
            }
            .padding(FLSpace.gutter)
        }
        .safeAreaInset(edge: .bottom) {
            if model.phase == .review, model.approvedCount > 0 || model.isUploading {
                Button { Task { await model.upload() } } label: {
                    if model.isUploading { ProgressView().tint(.flOnBrand) } else { Text("Upload \(model.approvedCount) approved") }
                }
                .buttonStyle(.flPrimary)
                .disabled(model.isUploading)
                .padding(FLSpace.gutter)
                .background(.flCanvas)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: FLSpace.sm) {
            ProgressView(value: Double(model.scanned), total: Double(max(model.total, 1))) {
                Text("Scanned \(model.scanned) of \(model.total) photos").font(.flHeadline).foregroundStyle(.flInk)
            }
            .tint(.flBrand)
            Text("\(model.candidates.count) possible finds so far").font(.flCallout).foregroundStyle(.flInk2)
            Button("Stop scan", action: model.stop).buttonStyle(.flSecondary)
        }
        .flCard()
    }

    @ViewBuilder private var summary: some View {
        let sent = model.candidates.compactMap { if case .done(let v) = $0.upload { v } else { nil } }
        if !sent.isEmpty {
            let onMap = sent.filter { $0.reportStatus != .rejected }.count  // map-data hides rejected reports
            StatusBanner(status: onMap > 0 ? (sent.contains { $0.reportStatus == .accepted } ? .accepted : .review) : .rejected,
                         detail: "\(sent.count) sent · \(sent.filter { $0.reportStatus == .accepted }.count) verified · \(sent.reduce(0) { $0 + $1.pointsPending }) points pending."
                             + (onMap > 0 ? " \(onMap == 1 ? "It's" : "\(onMap) are") on the map now." : ""))
        } else if model.candidates.isEmpty {
            FLEmptyState(title: "No damage found", systemImage: "checkmark.circle",
                         message: "Checked \(model.scanned) photos with a location. Try again after your next walk.")
        } else {
            Text("\(model.candidates.count) possible finds in \(model.scanned) photos. Approve the ones that show real damage.")
                .font(.flCallout).foregroundStyle(.flInk2)
        }
    }
}

/// MASTER.md §6 CandidateCard: photo, "Possible crack · place", date, Approve / Skip buttons.
struct CandidateCard: View {
    private static let photoHeight: CGFloat = 180
    @Binding var candidate: GalleryCandidate
    let locked: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Side by side normally; stacked at accessibility text sizes.
    private var row: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: FLSpace.sm)) : AnyLayout(HStackLayout(spacing: FLSpace.sm))
    }
    @State private var place: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.md) {
            Image(uiImage: candidate.thumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: Self.photoHeight)
                .clipShape(.rect(cornerRadius: FLRadius.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: FLSpace.xs) {
                Text([GalleryScanModel.title(candidate.types), place].compactMap { $0 }.joined(separator: " · "))
                    .font(.flHeadline).foregroundStyle(.flInk)
                HStack(spacing: FLSpace.sm) {
                    if let date = candidate.asset.creationDate {
                        Text(date, format: .dateTime.month().day().year()).font(.flCaption).foregroundStyle(.flInk2)
                    }
                    if GalleryScanModel.isHistorical(candidate.asset.creationDate) {
                        Label("Historical", systemImage: "clock.arrow.circlepath").font(.flCaption.weight(.semibold)).foregroundStyle(.flInk2)
                    }
                }
            }
            if let severity = candidate.severity {
                FLInfoRow(title: "Emergency level", note: "Preliminary") { SeverityBadge(severity: severity) }
            }
            status
        }
        .flCard()
        .task { await geocode() }
    }

    @ViewBuilder private func rewardTags(_ verdict: Verification) -> some View {
        if verdict.pointsPending > 0 { PointsPill(points: verdict.pointsPending, pending: true) }
        if verdict.isDamage, verdict.inDanger != true, let first = verdict.firstFinder { FinderTag(firstFinder: first) }
    }

    @ViewBuilder private var status: some View {
        switch candidate.upload {
        case .uploading:
            HStack(spacing: FLSpace.sm) { ProgressView(); Text("Checking…").font(.flCallout).foregroundStyle(.flInk2) }
        case .done(let verdict):
            VStack(alignment: .leading, spacing: FLSpace.sm) {
                StatusBanner(status: verdict.reportStatus, detail: verdict.primaryType.map(Verification.label))
                ViewThatFits(in: .horizontal) {  // pill + tag share a row until large text needs them stacked
                    HStack(spacing: FLSpace.sm) { rewardTags(verdict) }
                    VStack(alignment: .leading, spacing: FLSpace.sm) { rewardTags(verdict) }
                }
            }
        case .failed(let message):
            StatusBanner(status: .failed, detail: message)
            decisionButtons
        case .idle:
            decisionButtons
        }
    }

    private var decisionButtons: some View {
        row {
            Button {
                candidate.decision = candidate.decision == .skipped ? .undecided : .skipped
            } label: {
                Label(candidate.decision == .skipped ? "Skipped" : "Skip", systemImage: "xmark")
            }
            .buttonStyle(.flSecondary)
            .accessibilityAddTraits(candidate.decision == .skipped ? .isSelected : [])
            Button {
                candidate.decision = candidate.decision == .approved ? .undecided : .approved
            } label: {
                Label {
                    Text(candidate.decision == .approved ? "Approved" : "Approve")
                } icon: {
                    Image(systemName: candidate.decision == .approved ? "checkmark.circle.fill" : "checkmark").foregroundStyle(.flBrand)
                }
            }
            .buttonStyle(.flSecondary)
            .overlay {
                if candidate.decision == .approved { Capsule().strokeBorder(.flBrand, lineWidth: 2) }  // matches the capsule button
            }
            .accessibilityAddTraits(candidate.decision == .approved ? .isSelected : [])
        }
        .disabled(locked)
        .opacity(candidate.decision == .skipped ? 0.6 : 1)
    }

    private func geocode() async {
        guard place == nil, let location = candidate.asset.location,
              let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return }
        place = item.address?.shortAddress ?? item.name
    }
}

#Preview { GalleryScanScreen() }
