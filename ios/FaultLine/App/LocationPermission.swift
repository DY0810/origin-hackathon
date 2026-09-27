import CoreLocation

/// When-in-use location permission, observed: views re-render the moment the player answers or changes it in Settings.
/// Used by onboarding (ask and wait) and the map (danger watcher + "Location off" row).
@MainActor @Observable
final class LocationPermission: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAllowed: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    /// Shows the system prompt if it was never shown, and returns once the player answers.
    func request() async {
        guard status == .notDetermined else { return }
        await withCheckedContinuation { waiters.append($0); manager.requestWhenInUseAuthorization() }
    }

    // Delivered on the main thread: the manager was created there.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        MainActor.assumeIsolated {
            status = newStatus
            guard status != .notDetermined else { return }
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }
}
