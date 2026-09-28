import SwiftUI

/// Shared shell for the Quests / Rewards / Profile tabs: title, loading, error with retry, pull to refresh.
/// `trailing` is a toolbar item that stays reachable even when game_state fails (Profile's Settings).
struct GameContainer<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
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
                    FLEmptyState(title: "Couldn't load your progress", systemImage: "wifi.exclamationmark",
                                 message: "Check your connection.") {
                        Button("Try again") { Task { await game.load() } }.buttonStyle(.flPrimary).frame(maxWidth: 240)
                    }
                } else {
                    ProgressView().accessibilityLabel("Loading")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.flCanvas)
            .navigationTitle(title)
            .toolbar { if Trailing.self != EmptyView.self { ToolbarItem(placement: .topBarTrailing) { trailing() } } }
        }
    }
}

extension GameContainer where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: @escaping (GameState) -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
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
