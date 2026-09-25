import SwiftUI

/// Shared shell for the Quests / Rewards / Profile tabs: title, loading, error with retry, pull to refresh.
struct GameContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: (GameState) -> Content
    @Environment(GameModel.self) private var game

    var body: some View {
        NavigationStack {
            Group {
                if let state = game.state {
                    ScrollView {
                        VStack(alignment: .leading, spacing: FLSpace.xl) { content(state) }
                            .padding(FLSpace.gutter)
                    }
                    .refreshable { await game.load() }
                } else if game.loadFailed {
                    ContentUnavailableView {
                        Label("Couldn't load your progress", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection.")
                    } actions: {
                        Button("Try again") { Task { await game.load() } }.buttonStyle(.flPrimary).frame(maxWidth: 240)
                    }
                } else {
                    ProgressView().accessibilityLabel("Loading")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.flCanvas)
            .navigationTitle(title)
        }
    }
}

/// "+25 XP" in brand blue (XP isn't redeemable, so it never uses gold).
struct XPLabel: View {
    let xp: Int

    var body: some View {
        Text("+\(xp) XP")
            .font(.flCaption.weight(.bold).monospacedDigit())
            .foregroundStyle(.flBrand)
            .accessibilityLabel("\(xp) XP")
    }
}
