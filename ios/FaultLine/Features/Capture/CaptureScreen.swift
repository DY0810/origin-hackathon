import PhotosUI
import SwiftUI

/// Capture flow (design-system/MASTER.md §7.1): camera -> on-device suggestion -> confirm type -> submit.
/// Falls back to the photo library when there's no camera or access is denied.
struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var classifier = try? DamageClassifier()
    @State private var detector = try? DamageDetector()   // nil without FaultLineDetector.mlpackage in the bundle
    @State private var issues: [DetectedIssue] = []
    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var camera = CameraService()
    @State private var photo: CapturedPhoto?
    @State private var findings: [DamageFinding] = []
    @State private var selected: Set<DamageType> = []
    @State private var hinted: Set<DamageType> = []  // suggested by the dictated note or the detector
    @State private var showMoreTypes = false
    @State private var isAnalyzing = false
    @State private var analysisFailed = false
    @State private var offTopic = false          // scene gate: not infrastructure (DamageClassifier.isOffTopic)
    @State private var note = ""
    @State private var dictation = Dictation()
    @State private var isDrafting = false
    @State private var noteIsDraft = false       // Foundation Models rewrote the dictated note
    @State private var dangerMentioned = false   // MASTER §8 rule 7: show the 911 prompt before the server answers
    @State private var submitted = false
    @State private var phase: ResultSheet.Phase = .checking

    private var severity: Severity? { DamageClassifier.preliminarySeverity(findings) }
    /// Nothing on-device found damage: block the normal submit, keep "Submit anyway" (the server still decides).
    private var noDamage: Bool { !isAnalyzing && !analysisFailed && !DamageClassifier.looksLikeDamage(findings: findings, issues: issues, offTopic: offTopic) }

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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()  // whole photo, so issue boxes line up exactly
                    .overlay { IssueBoxes(issues: issues) }
                    .clipShape(.rect(cornerRadius: FLRadius.lg))
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .accessibilityElement()
                    .accessibilityLabel(issues.isEmpty ? "Your photo" : "Your photo. \(IssueBoxes.summary(issues))")

                analysisRow

                VStack(alignment: .leading, spacing: FLSpace.md) {
                    Text("Damage type").font(.flHeadline).foregroundStyle(.flInk)
                    chipGrid(DamageType.allCases.filter { DamageType.common.contains($0) || isSuggested($0) })
                    let more = DamageType.allCases.filter { !DamageType.common.contains($0) && !isSuggested($0) }
                    let moreSelected = more.filter(selected.contains).count
                    DisclosureGroup(isExpanded: $showMoreTypes) {
                        chipGrid(more).padding(.top, FLSpace.sm)
                    } label: {
                        Text(moreSelected > 0 ? "More types (\(moreSelected) selected)" : "More types")
                            .font(.flCallout.weight(.semibold))
                            .frame(minHeight: FLSpace.minTap)
                    }
                    .tint(.flInk)
                }

                VStack(alignment: .leading, spacing: FLSpace.sm) {
                    Text("Note (optional)").font(.flHeadline).foregroundStyle(.flInk)
                    HStack(alignment: .top, spacing: FLSpace.sm) {
                        TextField("Where on the structure, how big", text: $note, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.flBody)
                            .accessibilityLabel("Note")
                        if Dictation.isAvailable { micButton }
                    }
                    .padding(FLSpace.md)
                    .frame(minHeight: FLSpace.minTap)
                    .background(.flSurface, in: .rect(cornerRadius: FLRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: FLRadius.md).strokeBorder(dictation.state == .recording ? Color.flBrand : Color.flStroke))
                    dictationStatus
                }

                if dangerMentioned {
                    VStack(alignment: .leading, spacing: FLSpace.sm) {
                        Label("If anyone is in danger right now, call 911.", systemImage: "exclamationmark.octagon.fill")
                            .font(.flHeadline)
                            .foregroundStyle(.flDanger)
                        Link("Call 911", destination: URL(string: "tel:911")!).buttonStyle(.flSecondary)
                    }
                    .flCard()
                }

                VStack(spacing: FLSpace.md) {
                    if noDamage {
                        Button("Retake", action: retake).buttonStyle(.flPrimary)
                        Button("Submit anyway") { submitted = true; Task { await submit() } }
                            .buttonStyle(.flSecondary)
                            .disabled(selected.isEmpty)
                    } else {
                        Button("Submit report") { submitted = true; Task { await submit() } }
                            .buttonStyle(.flPrimary)
                            .disabled(selected.isEmpty || isAnalyzing)
                    }
                    if selected.isEmpty && !isAnalyzing {
                        Text("Pick at least one damage type.").font(.flCaption).foregroundStyle(.flInk2)
                    }
                    if !noDamage {
                        Button("Retake", action: retake).buttonStyle(.flSecondary)
                    }
                }
            }
            .padding(FLSpace.gutter)
        }
    }

    // MARK: Dictation

    private var micButton: some View {
        let recording = dictation.state == .recording
        return Button {
            Task {
                if recording {
                    if let text = await dictation.stop() { await applyDictation(text) }
                } else {
                    await dictation.start()
                    if dictation.state == .recording { AccessibilityNotification.Announcement("Listening").post() }
                }
            }
        } label: {
            Image(systemName: recording ? "stop.circle.fill" : "mic")
                .font(.title2)
                .foregroundStyle(recording ? .flDanger : .flBrand)
                .frame(width: FLSpace.minTap, height: FLSpace.minTap)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(dictation.state == .loading || dictation.state == .transcribing || isDrafting)
        .accessibilityLabel(recording ? "Stop dictation" : "Dictate note")
    }

    @ViewBuilder private var dictationStatus: some View {
        HStack(spacing: FLSpace.sm) {
            switch dictation.state {
            case .loading: ProgressView(); Text("Preparing dictation…")
            case .recording: Text("Listening. Tap stop when you're done.")
            case .transcribing: ProgressView(); Text("Transcribing…")
            case .failed(let message): Text(message)
            case .idle:
                if isDrafting { ProgressView(); Text("Tidying up your note…") }
                else if noteIsDraft { Label("Suggested", systemImage: "sparkles") }
            }
            Spacer(minLength: 0)
            if dictation.state != .idle || isDrafting || noteIsDraft { OnDeviceBadge() }
        }
        .font(.flCaption)
        .foregroundStyle(.flInk2)
    }

    /// Transcript -> note. With Apple Intelligence, the note is cleaned (fillers, PII) and may suggest a type or danger.
    private func applyDictation(_ transcript: String) async {
        let typed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = typed.isEmpty ? transcript : typed + " " + transcript
        isDrafting = true
        defer { isDrafting = false }
        guard let draft = await ReportNoteDraft.draft(from: transcript) else { return }
        note = typed.isEmpty ? draft.cleanedNote : typed + " " + draft.cleanedNote
        noteIsDraft = true
        if let type = draft.suggestedType {
            hinted.insert(type)
            selected.insert(type)
        }
        if draft.mentionsImmediateDanger {
            dangerMentioned = true
            AccessibilityNotification.Announcement("If anyone is in danger right now, call 911.").post()
        }
    }

    private func isSuggested(_ type: DamageType) -> Bool {
        hinted.contains(type) || findings.contains { $0.type == type }
    }

    private func chipGrid(_ types: [DamageType]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: FLSpace.sm)], spacing: FLSpace.sm) {
            ForEach(types) { type in
                DamageTypeChip(type: type, isOn: selected.contains(type), isSuggested: isSuggested(type)) {
                    if selected.contains(type) { selected.remove(type) } else { selected.insert(type) }
                }
            }
        }
    }

    @ViewBuilder private var analysisRow: some View {
        HStack(spacing: FLSpace.sm) {
            if isAnalyzing {
                ProgressView()
                Text("Analyzing…").font(.flCallout).foregroundStyle(.flInk2)
            } else if analysisFailed {
                Text("On-device analysis unavailable. Pick the type yourself.").font(.flCallout).foregroundStyle(.flInk2)
            } else if offTopic {
                Text("This doesn't look like infrastructure. Get closer to the damage and retake.").font(.flCallout).foregroundStyle(.flInk2)
            } else if let severity {
                SeverityBadge(severity: severity)
                Text("Preliminary").font(.flCaption).foregroundStyle(.flInk2)
            } else {
                Text("No damage detected. Try closer, or pick a type and submit anyway.").font(.flCallout).foregroundStyle(.flInk2)
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
        dictation.cancel()
        noteIsDraft = false
        dangerMentioned = false
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
        issues = []
        selected = []
        hinted = []
        analysisFailed = false
        offTopic = false
        guard let image else { return }
        guard let classifier else { analysisFailed = true; return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        do {
            (findings, offTopic) = try await classifier.classify(image)
            issues = offTopic ? [] : (try? await detector?.detect(image)) ?? []
            hinted = Set(issues.map(\.type))
            selected = Set(findings.map(\.type)).union(hinted)
            var summary = severity.map { "\($0.accessibilityText). Suggested: " + findings.map(\.type.label).joined(separator: ", ") }
            if !issues.isEmpty { summary = [summary, IssueBoxes.summary(issues)].compactMap { $0 }.joined(separator: ". ") }
            AccessibilityNotification.Announcement(summary ?? (offTopic ? "This doesn't look like infrastructure" : "No damage detected")).post()
        } catch {
            analysisFailed = true
        }
    }
}

/// Detector boxes over the photo, each tagged with its damage type.
struct IssueBoxes: View {
    let issues: [DetectedIssue]

    nonisolated static func summary(_ issues: [DetectedIssue]) -> String {
        let counts = Dictionary(grouping: issues, by: \.type).map { $1.count > 1 ? "\($0.label) ×\($1.count)" : $0.label }
        return "\(issues.count) issue\(issues.count == 1 ? "" : "s") found: " + counts.sorted().joined(separator: ", ")
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                let rect = CGRect(x: issue.box.minX * geo.size.width, y: issue.box.minY * geo.size.height,
                                  width: issue.box.width * geo.size.width, height: issue.box.height * geo.size.height)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.flBrand, lineWidth: 2)
                    .overlay(alignment: .topLeading) {
                        Text(issue.type.label)
                            .font(.flCaption.weight(.semibold))
                            .foregroundStyle(.flOnBrand)
                            .padding(.horizontal, FLSpace.xs)
                            .background(.flBrand, in: .rect(cornerRadius: 4))
                            .fixedSize()
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .accessibilityHidden(true)  // the photo's label carries the summary
    }
}

/// Selectable damage type (MASTER.md §6 DamageTypeChip): unselected, selected, AI-suggested (sparkle + "Suggested").
struct DamageTypeChip: View {
    let type: DamageType
    let isOn: Bool
    let isSuggested: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: FLSpace.sm) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 0) {
                    Label(type.label, systemImage: type.symbol).lineLimit(1).minimumScaleFactor(0.8)
                    if isSuggested {
                        Label("Suggested", systemImage: "sparkles").font(.flCaption).foregroundStyle(.flInk2)
                    }
                }
                Spacer(minLength: 0)
            }
            .font(.flCallout.weight(.semibold))
            .foregroundStyle(isOn ? .flBrand : .flInk)
            .padding(.horizontal, FLSpace.md)
            .padding(.vertical, FLSpace.xs)
            .frame(minHeight: FLSpace.minTap)
            .background(.flSurface, in: .rect(cornerRadius: FLRadius.md))
            .overlay(RoundedRectangle(cornerRadius: FLRadius.md).strokeBorder(isOn ? Color.flBrand : Color.flStroke, lineWidth: isOn ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(type.label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSuggested ? "Suggested on-device" : "")
    }
}

#Preview { CaptureScreen() }
