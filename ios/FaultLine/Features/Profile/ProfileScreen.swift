import SwiftUI

/// Level/XP, badges, my reports, the weekly leaderboard (MASTER.md §9: handles only, weekly reset, your row always
/// visible) and Settings.
// ponytail: one city-wide board; per-neighborhood boards once reports carry a neighborhood.
struct ProfileScreen: View {
    /// RootView's reportsChanged: Settings' "Send now" / "Scan my photos" can land new reports.
    var onReportsChanged: () -> Void = {}
    @Environment(GameModel.self) private var game
    @State private var mine = MyReportsModel()
    @Environment(\.dynamicTypeSize) private var typeSize
    private static let badgeMinWidth: CGFloat = 150  // two tiles across on a phone; one at accessibility sizes

    var body: some View {
        GameContainer(title: "Profile") {
            NavigationLink {
                SettingsScreen(onReset: resetPlayer, onReportsChanged: onReportsChanged)
            } label: { Label("Settings", systemImage: "gearshape") }
        } content: { state in
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
            .navigationDestination(for: MyReports.Report.self) { ReportDetailScreen(report: $0) }

            reportsSection

            VStack(alignment: .leading, spacing: FLSpace.sm) {
                Text("This week").font(.flHeadline).foregroundStyle(.flInk)
                // Your row is always visible (MASTER.md §9): in the top 10 it's already there, highlighted; else pinned.
                if let me = state.leaderboard.first(where: \.isMe), me.rank > 10 {
                    LeaderboardRow(entry: me)
                    Divider().padding(.vertical, FLSpace.xs)
                }
                ForEach(state.leaderboard.filter { $0.rank <= 10 }) { LeaderboardRow(entry: $0) }
                Text("Resets every Monday. Only handles are shown.").font(.flCaption).foregroundStyle(.flInk2)
            }
        }
        .task(id: game.state) { await mine.load() }  // new points usually mean a new report or a fix
    }

    @ViewBuilder private var reportsSection: some View {
        if let data = mine.data {
            VStack(alignment: .leading, spacing: FLSpace.sm) {
                Text("Badges").font(.flHeadline).foregroundStyle(.flInk)
                LazyVGrid(columns: [GridItem(typeSize.isAccessibilitySize ? .flexible() : .adaptive(minimum: Self.badgeMinWidth),
                                             spacing: FLSpace.sm, alignment: .top)], spacing: FLSpace.sm) {
                    ForEach(data.badges) { BadgeTile(badge: $0) }
                }
            }
            VStack(alignment: .leading, spacing: FLSpace.sm) {
                Text("My reports").font(.flHeadline).foregroundStyle(.flInk)
                if data.reports.isEmpty {
                    Text("No reports yet. Tap the camera on the Map to file your first.").font(.flCallout).foregroundStyle(.flInk2)
                }
                ForEach(data.reports.prefix(5)) { report in
                    NavigationLink(value: report) { ReportRow(report: report) }.buttonStyle(.plain)
                }
                if data.reports.count > 5 {
                    NavigationLink("See all \(data.reports.count) reports") { AllReportsScreen(reports: data.reports) }
                        .font(.flHeadline).frame(minHeight: FLSpace.minTap)
                }
            }
        } else if mine.loadFailed {
            HStack {
                Text("Couldn't load your reports.").font(.flCallout).foregroundStyle(.flInk2)
                Spacer()
                Button("Try again") { Task { await mine.load() } }.frame(minHeight: FLSpace.minTap)
            }
        }
    }

    /// Settings > Reset demo player: new anonymous player, then reload everything that belongs to the old one.
    private func resetPlayer() async {
        await PlayerSession.shared.reset()
        // Per-player local state: tab-dot baselines, fix notices, and which library photos this player already sent.
        for key in ["seenSettledPoints", "seenSurgeQuests", FixNotifier.seenKey, GalleryScanScreen.uploadedKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        await game.load()
        await mine.load()
    }
}

/// Every report my_reports() returned (the last 50).
struct AllReportsScreen: View {
    let reports: [MyReports.Report]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: FLSpace.sm) {
                ForEach(reports) { report in
                    NavigationLink(value: report) { ReportRow(report: report) }.buttonStyle(.plain)
                }
            }
            .padding(FLSpace.gutter)
        }
        .background(.flCanvas)
        .navigationTitle("My reports")
        .navigationBarTitleDisplayMode(.inline)
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
