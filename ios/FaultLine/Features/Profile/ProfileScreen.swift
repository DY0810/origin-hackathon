import SwiftUI

/// Level/XP and the weekly leaderboard (MASTER.md §9: handles only, weekly reset, your row always visible).
// ponytail: one city-wide board; per-neighborhood boards once reports carry a neighborhood.
struct ProfileScreen: View {
    var body: some View {
        GameContainer(title: "Profile") { state in
            VStack(alignment: .leading, spacing: FLSpace.md) {
                Text(state.handle).font(.flTitle).foregroundStyle(.flInk)
                Text("Level \(state.level) · \(state.title)").font(.flHeadline).foregroundStyle(.flBrand)
                ProgressView(value: state.levelProgress).tint(.flBrand)
                    .accessibilityLabel("Level progress")
                    .accessibilityValue("\(state.xp - state.levelStartXp) of \(state.nextLevelXp - state.levelStartXp) XP")
                Text("\(state.xp - state.levelStartXp) / \(state.nextLevelXp - state.levelStartXp) XP to level \(state.level + 1)")
                    .font(.flCaption.monospacedDigit())
                    .foregroundStyle(.flInk2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .flCard()

            VStack(alignment: .leading, spacing: FLSpace.sm) {
                Text("This week").font(.flHeadline).foregroundStyle(.flInk)
                if let me = state.leaderboard.first(where: \.isMe) {
                    LeaderboardRow(entry: me)  // pinned: your row is always visible (MASTER.md §9)
                    Divider().padding(.vertical, FLSpace.xs)
                }
                ForEach(state.leaderboard.filter { !$0.isMe || $0.rank <= 10 }) { LeaderboardRow(entry: $0) }
                Text("Resets every Monday. Only handles are shown.").font(.flCaption).foregroundStyle(.flInk2)
            }
        }
    }
}

/// MASTER.md §6 LeaderboardRow: rank, handle, points; your row highlighted.
struct LeaderboardRow: View {
    let entry: GameState.LeaderboardEntry

    var body: some View {
        HStack(spacing: FLSpace.md) {
            Text("\(entry.rank)")
                .font(.flNumber)
                .foregroundStyle(entry.rank <= 3 ? .flGoldText : .flInk2)
                .frame(minWidth: 32, alignment: .leading)
            Text(entry.isMe ? "\(entry.handle) (you)" : entry.handle)
                .font(entry.isMe ? .flHeadline : .flBody)
                .foregroundStyle(.flInk)
            Spacer(minLength: FLSpace.sm)
            Text(entry.points.formatted()).font(.flHeadline.monospacedDigit()).foregroundStyle(.flInk)
        }
        .padding(.horizontal, FLSpace.md)
        .frame(minHeight: FLSpace.minTap)
        .background(entry.isMe ? Color.flSurface2 : Color.flSurface, in: .rect(cornerRadius: FLRadius.md))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.handle)\(entry.isMe ? ", you" : ""), \(entry.points) points")
    }
}

#Preview { ProfileScreen().environment(GameModel()) }
