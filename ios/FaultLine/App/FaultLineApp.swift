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
    // Tab badge dots (MASTER.md §5): what the player last saw on each tab.
    @AppStorage("seenSettledPoints") private var seenSettledPoints = 0
    @AppStorage("seenSurgeQuests") private var seenSurgeQuests = ""
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        // Onboarding replaces the tabs rather than covering them, so nothing underneath (map, location updates) can
        // trigger a permission prompt before its explain-first page.
        if onboarded { tabs } else { OnboardingScreen { onboarded = true; tab = .map } }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Map", systemImage: "map", value: .map) {
                MapScreen(onCapture: { isCapturing = true }, onScan: { isScanning = true }, refreshToken: mapRefresh)
            }
            Tab("Quests", systemImage: "flag", value: .quests) {
                QuestsScreen()
            }
            .badge(questsDot ? newDot : nil)
            Tab("Rewards", systemImage: "star.circle", value: .rewards) {
                RewardsScreen()
            }
            .badge(rewardsDot ? newDot : nil)
            Tab("Profile", systemImage: "person.crop.circle", value: .profile) {
                ProfileScreen(onReportsChanged: reportsChanged)
            }
        }
        .tint(.flBrand)
        .fullScreenCover(isPresented: $isCapturing, onDismiss: reportsChanged) { CaptureScreen() }
        .fullScreenCover(isPresented: $isScanning, onDismiss: reportsChanged) { GalleryScanScreen() }
        .environment(game)
        .onChange(of: tab) { markSeen() }
        .onChange(of: game.state) { markSeen() }
        // Tab badges aren't reliably spoken, so say it once when a dot turns on.
        .onChange(of: questsDot) { _, on in if on, tab != .quests { AccessibilityNotification.Announcement("New surge quest").post() } }
        .onChange(of: rewardsDot) { _, on in if on, tab != .rewards { AccessibilityNotification.Announcement("New points available in Rewards").post() } }
        // Signs the player in on first launch, then keeps points, "your report got fixed" and the map
        // (new buyer bounties heat it) fresh while open.
        // ponytail: 30 s poll stands in for push; swap for APNs / Realtime when there's an Apple team.
        .task { OutboxStore.shared.startMonitoring { _ in reportsChanged() } }
        .task(id: scenePhase) {
            // Saved-offline reports go first, once per foreground (NWPathMonitor covers the network coming back).
            if scenePhase == .active, await !OutboxStore.shared.flush().isEmpty { mapRefresh += 1 }
            while scenePhase == .active, !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }  // left active: no extra bump
                mapRefresh += 1
            }
        }
    }

    private var questsDot: Bool { game.state?.hasNewSurge(seen: seenSurgeQuests) == true }
    private var rewardsDot: Bool { game.state?.hasNewSettledPoints(seen: seenSettledPoints) == true }

    /// Empty badge text renders as a dot (checked in the simulator).
    private var newDot: Text { Text("").accessibilityLabel("New") }

    /// Visiting a tab clears its dot (and keeps it clear while the tab stays open).
    private func markSeen() {
        guard let state = game.state else { return }
        if tab == .quests { seenSurgeQuests = state.surgeQuestKey }
        if tab == .rewards { seenSettledPoints = state.pointsSettled }
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
