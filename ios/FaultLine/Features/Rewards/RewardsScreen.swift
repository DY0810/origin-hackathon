import SwiftUI

/// MASTER.md §7.5: spendable (settled) balance big, pending separate, points history.
// ponytail: redemption catalog is the next step (CLAUDE.md §6.6, mocked for the demo).
struct RewardsScreen: View {
    var body: some View {
        GameContainer(title: "Rewards") { state in
            VStack(alignment: .leading, spacing: FLSpace.sm) {
                Text("Available").font(.flCallout).foregroundStyle(.flInk2)
                Text(state.pointsSettled.formatted())
                    .font(.flDisplay)
                    .foregroundStyle(.flInk)
                    .contentTransition(.numericText(value: Double(state.pointsSettled)))
                    .accessibilityLabel("\(state.pointsSettled) points available")
                if state.pointsPending > 0 {
                    PointsPill(points: state.pointsPending, pending: true)
                }
                Text("Points settle 24 hours after a report is verified. Reports under review settle once a person checks them.")
                    .font(.flCaption)
                    .foregroundStyle(.flInk2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .flCard()

            VStack(alignment: .leading, spacing: FLSpace.md) {
                Text("History").font(.flHeadline).foregroundStyle(.flInk)
                if state.history.isEmpty {
                    Text("Verified reports and completed quests show up here.").font(.flCallout).foregroundStyle(.flInk2)
                }
                ForEach(state.history) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: FLSpace.sm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label).font(.flBody).foregroundStyle(.flInk)
                            Text(entry.createdAt, format: .relative(presentation: .named)).font(.flCaption).foregroundStyle(.flInk2)
                        }
                        Spacer(minLength: FLSpace.sm)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(entry.amount > 0 ? "+" : "")\(entry.amount)")
                                .font(.flHeadline.monospacedDigit())
                                .foregroundStyle(entry.amount >= 0 ? .flGoldText : .flWarning)
                            if !entry.settled { Text("pending").font(.flCaption).foregroundStyle(.flInk2) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
        }
    }
}

#Preview { RewardsScreen().environment(GameModel()) }
