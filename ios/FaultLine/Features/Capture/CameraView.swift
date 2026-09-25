@preconcurrency import AVFoundation
import AVKit
import PhotosUI
import SwiftUI

/// Full-screen camera (design-system/MASTER.md §7.1). Shutter bottom-center, library bottom-left, glass controls.
struct CameraView: View {
    let camera: CameraService
    @Binding var pickerItem: PhotosPickerItem?
    let onClose: () -> Void
    let onPhoto: (CapturedPhoto) -> Void

    @State private var shots = 0

    var body: some View {
        ZStack {
            Color.flMedia.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()
            VStack {
                HStack(alignment: .center) {
                    GlassIconButton(symbol: "xmark", label: "Close", action: onClose)
                    Spacer()
                    LocationChip(location: camera.location)
                }
                Spacer()
                HStack {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        GlassIcon(symbol: "photo.on.rectangle")
                    }
                    .accessibilityLabel("Choose from library")
                    Spacer()
                    ShutterButton(isBusy: camera.isCapturing || camera.state != .running, action: shoot)
                    Spacer()
                    Color.clear.frame(width: FLSpace.minTap, height: FLSpace.minTap)  // balances the library button
                }
            }
            .padding(.horizontal, FLSpace.gutter)
            .padding(.vertical, FLSpace.lg)
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .onCameraCaptureEvent { event in  // volume / Camera Control buttons shoot too
            if event.phase == .ended { shoot() }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: shots)
    }

    private func shoot() {
        shots += 1
        Task {
            if let photo = await camera.capture() { onPhoto(photo) }
        }
    }
}

/// MASTER.md §6 ShutterButton: 72 pt ring + inner disc; ready / pressed / processing.
struct ShutterButton: View {
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.flOnMedia, lineWidth: 4)
                if isBusy {
                    ProgressView().tint(.flOnMedia)
                } else {
                    Circle().fill(.flOnMedia).padding(8)
                }
            }
            .frame(width: 72, height: 72)
            .contentShape(.circle)
        }
        .buttonStyle(ShutterPressStyle())
        .disabled(isBusy)
        .accessibilityLabel("Take photo")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(FLMotion.quick, value: configuration.isPressed)
    }
}

/// 44 pt glass circle icon for controls floating over camera/map.
struct GlassIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.flHeadline)
            .foregroundStyle(.flOnMedia)
            .frame(width: FLSpace.minTap, height: FLSpace.minTap)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { GlassIcon(symbol: symbol) }
            .accessibilityLabel(label)
    }
}

/// GPS accuracy at a glance; reports need a fix to identify the asset.
private struct LocationChip: View {
    let location: CLLocation?

    var body: some View {
        Label(text, systemImage: location == nil ? "location.slash" : "location.fill")
            .font(.flCaption.weight(.semibold))
            .foregroundStyle(.flOnMedia)
            .padding(.horizontal, FLSpace.md)
            .frame(minHeight: FLSpace.minTap)
            .glassEffect(.regular, in: .capsule)
    }

    private var text: String {
        guard let location, location.horizontalAccuracy >= 0 else { return "Finding location…" }
        return "Location ±\(Int(location.horizontalAccuracy.rounded())) m"
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
