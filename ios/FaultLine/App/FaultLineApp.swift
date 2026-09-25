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
        .fullScreenCover(isPresented: $isCapturing, onDismiss: { mapRefresh += 1 }) {
            CaptureScreen()
        }
    }
}

/// Shared placeholder for screens not built yet. Delete once every tab has real content.
struct ComingSoon: View {
    let title: String
    let symbol: String
    let line: String

    var body: some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol, description: Text(line))
                .background(.flCanvas)
                .navigationTitle(title)
        }
    }
}

#Preview { RootView() }
