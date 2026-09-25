import PhotosUI
import SwiftUI

/// Capture flow (design-system/MASTER.md §7.1): camera -> on-device suggestion -> confirm type -> submit.
/// Falls back to the photo library when there's no camera or access is denied.
struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var classifier = try? DamageClassifier()
    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var camera = CameraService()
    @State private var photo: CapturedPhoto?
    @State private var findings: [DamageFinding] = []
    @State private var selected: Set<DamageType> = []
    @State private var isAnalyzing = false
    @State private var analysisFailed = false
    @State private var note = ""
    @State private var submitted = false
    @State private var phase: ResultSheet.Phase = .checking

    private var severity: Severity? { DamageClassifier.preliminarySeverity(findings) }

    private var cameraProblem: String? {
        if case .unavailable(let reason) = camera.state { reason } else { nil }
    }

    var body: some View {
        Group {
            if image == nil, cameraProblem == nil {
                CameraView(camera: camera, pickerItem: $pickerItem, onClose: { dismiss() }) { shot in
                    photo = shot
                    image = shot.image
                }
            } else {
                form
            }
        }
        .onChange(of: pickerItem) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                photo = nil  // library photos carry no capture-time location/heading
                image = UIImage(data: data)
            }
        }
        .task(id: image) { await analyze() }
        .sheet(isPresented: $submitted) {
            ResultSheet(phase: phase,
                        onRetry: { Task { await submit() } },
                        onReportAnother: { submitted = false; retake() },
                        onDone: { submitted = false; dismiss() })
        }
    }

    private var form: some View {
        NavigationStack {
            Group {
                if let image { review(image) } else { fallback }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.flCanvas)
            .navigationTitle(image == nil ? "Report damage" : "Review report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }

    // MARK: No camera

    private var fallback: some View {
        VStack(spacing: FLSpace.xl) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(.largeTitle).weight(.semibold))
                .foregroundStyle(.flBrand)
                .accessibilityHidden(true)
            VStack(spacing: FLSpace.sm) {
                Text("Photograph the damage").font(.flTitle).foregroundStyle(.flInk)
                Text(cameraProblem ?? "Get close enough that the damage fills most of the frame.")
                    .font(.flCallout).foregroundStyle(.flInk2).multilineTextAlignment(.center)
            }
            Spacer()
            PhotosPicker("Choose from library", selection: $pickerItem, matching: .images).buttonStyle(.flPrimary)
        }
        .padding(FLSpace.gutter)
    }

    // MARK: Review

    private func review(_ image: UIImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FLSpace.xl) {
                Color.clear  // fixed-size frame so a wide photo can't widen the layout
                    .frame(height: 280)
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipShape(.rect(cornerRadius: FLRadius.lg))
                    .accessibilityElement()
                    .accessibilityLabel("Your photo")

                analysisRow

                VStack(alignment: .leading, spacing: FLSpace.md) {
                    Text("Damage type").font(.flHeadline).foregroundStyle(.flInk)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: FLSpace.sm)], spacing: FLSpace.sm) {
                        ForEach(DamageType.allCases) { type in
                            DamageTypeChip(type: type,
                                           isOn: selected.contains(type),
                                           isSuggested: findings.contains { $0.type == type }) {
                                if selected.contains(type) { selected.remove(type) } else { selected.insert(type) }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: FLSpace.sm) {
                    Text("Note (optional)").font(.flHeadline).foregroundStyle(.flInk)
                    TextField("Where on the structure, how big", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .font(.flBody)
                        .padding(FLSpace.md)
                        .frame(minHeight: FLSpace.minTap)
                        .background(.flSurface, in: .rect(cornerRadius: FLRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: FLRadius.md).strokeBorder(.flStroke))
                }

                VStack(spacing: FLSpace.md) {
                    Button("Submit report") { submitted = true; Task { await submit() } }
                        .buttonStyle(.flPrimary)
                        .disabled(selected.isEmpty || isAnalyzing)
                    if selected.isEmpty && !isAnalyzing {
                        Text("Pick at least one damage type.").font(.flCaption).foregroundStyle(.flInk2)
                    }
                    Button("Retake", action: retake).buttonStyle(.flSecondary)
                }
            }
            .padding(FLSpace.gutter)
        }
    }

    @ViewBuilder private var analysisRow: some View {
        HStack(spacing: FLSpace.sm) {
            if isAnalyzing {
                ProgressView()
                Text("Analyzing…").font(.flCallout).foregroundStyle(.flInk2)
            } else if analysisFailed {
                Text("On-device analysis unavailable. Pick the type yourself.").font(.flCallout).foregroundStyle(.flInk2)
            } else if let severity {
                SeverityBadge(severity: severity)
                Text("Preliminary").font(.flCaption).foregroundStyle(.flInk2)
            } else {
                Text("No damage detected. You can still pick a type.").font(.flCallout).foregroundStyle(.flInk2)
            }
            Spacer(minLength: 0)
            OnDeviceBadge()
        }
    }

    private func retake() {
        image = nil
        photo = nil
        pickerItem = nil
        note = ""
    }

    // MARK: Server verification

    private func submit() async {
        guard let image else { return }
        phase = .checking
        do {
            let suggested = selected.sorted { $0.rawValue < $1.rawValue }
            phase = .verified(try await ReportService.verify(image: image, photo: photo, suggested: suggested, note: note))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Analysis

    private func analyze() async {
        findings = []
        selected = []
        analysisFailed = false
        guard let image else { return }
        guard let classifier else { analysisFailed = true; return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            findings = try await classifier.classify(image)
            selected = Set(findings.map(\.type))
            let summary = severity.map { "\($0.accessibilityText). Suggested: " + findings.map(\.type.label).joined(separator: ", ") }
            AccessibilityNotification.Announcement(summary ?? "No damage detected").post()
        } catch {
            analysisFailed = true
        }
    }
}

/// Selectable damage type (MASTER.md §6 DamageTypeChip): unselected, selected, AI-suggested.
struct DamageTypeChip: View {
    let type: DamageType
    let isOn: Bool
    let isSuggested: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: FLSpace.sm) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                Text(type.label).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if isSuggested {
                    Image(systemName: "sparkles").foregroundStyle(.flInk2)
                }
            }
            .font(.flCallout.weight(.semibold))
            .foregroundStyle(isOn ? .flBrand : .flInk)
            .padding(.horizontal, FLSpace.md)
            .frame(minHeight: FLSpace.minTap)
            .background(.flSurface, in: .rect(cornerRadius: FLRadius.md))
            .overlay(RoundedRectangle(cornerRadius: FLRadius.md).strokeBorder(isOn ? Color.flBrand : Color.flStroke, lineWidth: isOn ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isSuggested ? "Suggested by on-device analysis" : "")
    }
}

#Preview { CaptureScreen() }
