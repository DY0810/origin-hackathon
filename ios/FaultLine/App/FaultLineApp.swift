import SwiftUI
import UserNotifications

@main
struct FaultLineApp: App {
    init() { UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Top-level tabs (design-system/MASTER.md §5). Capture is an action, not a tab.
enum AppTab: Hashable {
    case map, quests, rewards, profile
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .map
    @State private var isCapturing = false
    @State private var isScanning = false
    @State private var mapRefresh = 0
    @State private var game = GameModel()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Map", systemImage: "map", value: .map) {
                MapScreen(onCapture: { isCapturing = true }, onScan: { isScanning = true }, refreshToken: mapRefresh)
            }
            Tab("Quests", systemImage: "flag", value: .quests) {
                QuestsScreen()
            }
            Tab("Rewards", systemImage: "star.circle", value: .rewards) {
                RewardsScreen()
            }
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                ProfileScreen()
            }
        }
        .tint(.flBrand)
        .fullScreenCover(isPresented: $isCapturing, onDismiss: reportsChanged) { CaptureScreen() }
        .fullScreenCover(isPresented: $isScanning, onDismiss: reportsChanged) { GalleryScanScreen() }
        .environment(game)
        // Signs the player in on first launch, then keeps points, "your report got fixed" and the map
        // (new buyer bounties heat it) fresh while open.
        // ponytail: 30 s poll stands in for push; swap for APNs / Realtime when there's an Apple team.
        .task(id: scenePhase) {
            while scenePhase == .active, !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }  // left active: no extra bump
                mapRefresh += 1
            }
        }
    }

    /// New reports may have landed: drop their pins and update points.
    private func reportsChanged() {
        mapRefresh += 1
        Task { await refresh() }
    }

    private func refresh() async {
        await game.load()
        if await FixNotifier.check() > 0 {
            mapRefresh += 1
            await game.load()
        }
    }
}

#Preview { RootView() }
