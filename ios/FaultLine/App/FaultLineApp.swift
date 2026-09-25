import SwiftUI

@main
struct FaultLineApp: App {
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
    @State private var tab: AppTab = .map
    @State private var isCapturing = false
    @State private var mapRefresh = 0
    @State private var game = GameModel()

    var body: some View {
        TabView(selection: $tab) {
            Tab("Map", systemImage: "map", value: .map) {
                MapScreen(onCapture: { isCapturing = true }, refreshToken: mapRefresh)
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
        .fullScreenCover(isPresented: $isCapturing, onDismiss: {
            mapRefresh += 1
            Task { await game.load() }
        }) {
            CaptureScreen()
        }
        .environment(game)
        .task { await game.load() } // signs the player in on first launch
    }
}

#Preview { RootView() }
