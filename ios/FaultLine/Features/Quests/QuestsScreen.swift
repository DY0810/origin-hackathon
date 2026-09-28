import SwiftUI

struct QuestsScreen: View {
    var body: some View {
        GameContainer(title: "Quests") { state in
            let quests = state.quests.sorted { !$0.completed && $1.completed }
            if quests.isEmpty {
                FLEmptyState(title: "No quests right now", systemImage: "flag", message: "New quests appear when buyers post bounties.")
            }
            ForEach(quests) { QuestCard(quest: $0) }
        }
    }
}

/// MASTER.md §6 QuestCard: title, area + multiplier, progress n/m, rewards, deadline; complete state.
struct QuestCard: View {
    let quest: GameState.Quest

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(quest.title).font(.flHeadline).foregroundStyle(.flInk)
                Spacer(minLength: FLSpace.sm)
                if quest.completed {
                    Label("Complete", systemImage: "checkmark.seal.fill")
                        .font(.flCaption.weight(.semibold))
                        .foregroundStyle(.flSuccess)
                } else if let multiplier = quest.multiplier {
                    MultiplierChip(multiplier: multiplier)
                }
            }
            Text(quest.description).font(.flCallout).foregroundStyle(.flInk2)
            if let area = quest.areaName, !quest.title.contains(area) {
                Label(area, systemImage: "mappin.and.ellipse").font(.flCaption).foregroundStyle(.flInk2)
            }
            HStack(spacing: FLSpace.sm) {
                ProgressView(value: Double(quest.progress), total: Double(quest.target)).tint(quest.completed ? .flSuccess : .flBrand)
                Text("\(quest.progress)/\(quest.target)").font(.flCaption.weight(.semibold).monospacedDigit()).foregroundStyle(.flInk2)
            }
            HStack(spacing: FLSpace.sm) {
                PointsPill(points: quest.rewardPoints)
                XPLabel(xp: quest.rewardXp)
                Spacer(minLength: 0)
                if let endsAt = quest.endsAt, !quest.completed {
                    Text("Ends \(endsAt, format: .relative(presentation: .named))").font(.flCaption).foregroundStyle(.flInk2)
                }
            }
        }
        .flCard()
        .opacity(quest.completed ? 0.7 : 1)
        .accessibilityElement(children: .combine)
    }
}

#Preview { QuestsScreen().environment(GameModel()) }
