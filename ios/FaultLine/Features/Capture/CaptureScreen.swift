import PhotosUI
import SwiftUI

/// Capture flow (design-system/MASTER.md §7.1): photo -> on-device suggestion -> confirm type -> submit.
// ponytail: UIImagePickerController camera; move to AVCaptureSession when heading/GPS/attestation capture lands.
struct CaptureScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var classifier = try? DamageClassifier()
    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var findings: [DamageFinding] = []
    @State private var selected: Set<DamageType> = []
    @State private var isAnalyzing = false
    @State private var analysisFailed = false
    @State private var note = ""
    @State private var submitted = false

    private var severity: Severity? { DamageClassifier.preliminarySeverity(findings) }

    var body: some View {
        NavigationStack {
            Group {
                if let image { review(image) } else { start }
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
        .fullScreenCover(isPresented: $showCamera) { CameraPicker(image: $image).ignoresSafeArea() }
        .onChange(of: pickerItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { image = UIImage(data: data) }
            }
        }
        .task(id: image) { await analyze() }
        .sheet(isPresented: $submitted) { submittedSheet }
        .sensoryFeedback(.success, trigger: submitted) { _, new in new }
    }

    // MARK: Start

    private var start: some View {
        VStack(spacing: FLSpace.xl) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(.largeTitle).weight(.semibold))
                .foregroundStyle(.flBrand)
                .accessibilityHidden(true)
            VStack(spacing: FLSpace.sm) {
                Text("Photograph the damage").font(.flTitle).foregroundStyle(.flInk)
                Text("Get close enough that the damage fills most of the frame.")
                    .font(.flCallout).foregroundStyle(.flInk2).multilineTextAlignment(.center)
            }
            Spacer()
            VStack(spacing: FLSpace.md) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take photo", systemImage: "camera.fill") { showCamera = true }.buttonStyle(.flPrimary)
                    PhotosPicker("Choose from library", selection: $pickerItem, matching: .images).buttonStyle(.flSecondary)
                } else {
                    PhotosPicker("Choose from library", selection: $pickerItem, matching: .images).buttonStyle(.flPrimary)
                }
            }
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
                    Button("Submit report") { submitted = true }
                        .buttonStyle(.flPrimary)
                        .disabled(selected.isEmpty || isAnalyzing)
                    if selected.isEmpty && !isAnalyzing {
                        Text("Pick at least one damage type.").font(.flCaption).foregroundStyle(.flInk2)
                    }
                    Button("Retake") { self.image = nil; pickerItem = nil }.buttonStyle(.flSecondary)
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

    private var submittedSheet: some View {
        VStack(alignment: .leading, spacing: FLSpace.lg) {
            StatusBanner(status: .pending,
                         detail: "Server verification isn't connected yet, so this report stays preliminary.")
            if let severity { SeverityBadge(severity: severity) }
            Text(selected.map(\.label).sorted().joined(separator: ", ")).font(.flBody).foregroundStyle(.flInk)
            Spacer()
            Button("Done") { submitted = false; dismiss() }.buttonStyle(.flPrimary)
        }
        .padding(FLSpace.gutter)
        .presentationDetents([.medium])
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

/// System camera. Dismisses itself after a photo or cancel.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.image = info[.originalImage] as? UIImage
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

#Preview { CaptureScreen() }
