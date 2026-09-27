@preconcurrency import AVFoundation
import CoreLocation
import UIKit

/// A photo plus where and which way the phone was pointing at shutter time (CLAUDE.md §7.2 asset identification).
struct CapturedPhoto {
    let image: UIImage
    let location: CLLocation?
    let heading: CLLocationDirection?
    let capturedAt: Date
    var fromLibrary = false  // gallery scan: location/date come from the photo's metadata, so no zone multiplier
}

/// Back camera + location/heading for the capture flow (design-system/MASTER.md §7.1).
@MainActor @Observable
final class CameraService: NSObject {
    enum State: Equatable {
        case idle, running
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var isCapturing = false
    private(set) var location: CLLocation?
    private(set) var heading: CLLocationDirection?

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "faultline.camera")
    private let locationManager = CLLocationManager()
    private var photoContinuation: CheckedContinuation<UIImage?, Never>?

    func start() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            state = .unavailable("Camera access is off. Turn it on in Settings, or choose a photo from your library.")
            return
        }
        if session.inputs.isEmpty {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(output) else {
                state = .unavailable("No camera on this device. Choose a photo from your library.")
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90  // app is portrait-only
            }
        }
        let session = session
        await withCheckedContinuation { done in
            sessionQueue.async {
                session.startRunning()
                done.resume()
            }
        }
        state = .running
    }

    func stop() {
        let session = session
        sessionQueue.async { session.stopRunning() }
        if state == .running { state = .idle }
    }

    /// Takes a photo and stamps it with the latest fix and heading. Nil if the camera isn't ready or capture failed.
    func capture() async -> CapturedPhoto? {
        guard state == .running, !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }
        let image = await withCheckedContinuation { continuation in
            photoContinuation = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
        return image.map { CapturedPhoto(image: $0, location: location, heading: heading, capturedAt: .now) }
    }

    /// Location runs for the whole capture flow, not just the camera: the asset lookup needs it on the review form
    /// too, including with no camera (simulator, access denied).
    func startLocation() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        if locationManager.authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        locationManager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { locationManager.startUpdatingHeading() }
    }

    func stopLocation() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }
}

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap(UIImage.init(data:))
        Task { @MainActor in
            photoContinuation?.resume(returning: image)
            photoContinuation = nil
        }
    }
}

extension CameraService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in location = latest }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in heading = degrees }
    }
}
