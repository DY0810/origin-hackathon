import SwiftUI

struct QuestsScreen: View {
    @Environment(GameModel.self) private var game

    var body: some View {
        GameContainer(title: "Quests") { state in
            let quests = state.quests.sorted { !$0.completed && $1.completed }
            if quests.isEmpty && game.campaigns.isEmpty {
                ContentUnavailableView("No quests right now", systemImage: "flag", description: Text("New quests appear when buyers post bounties."))
            }
            ForEach(quests) { QuestCard(quest: $0) }
            if !game.campaigns.isEmpty {
                Text("Sponsored").font(.flHeadline).foregroundStyle(.flInk2)
                ForEach(game.campaigns) { SponsoredQuestCard(campaign: $0) }
            }
        }
    }
}

/// A sponsored campaign as a quest (CLAUDE.md §9.1): offer, sponsor, stores visited, deadline. Always labelled Sponsored.
struct SponsoredQuestCard: View {
    let campaign: SponsoredCampaign

    var body: some View {
        let stores = campaign.storeList
        VStack(alignment: .leading, spacing: FLSpace.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(campaign.title).font(.flHeadline).foregroundStyle(.flInk)
                Spacer(minLength: FLSpace.sm)
                Label("Sponsored", systemImage: "storefront.fill").font(.flCaption.weight(.semibold)).foregroundStyle(.flBrand)
            }
            Text("\(campaign.offer) from \(campaign.sponsor). Report a real issue within \(campaign.radiusM) m of a participating store, then check in there.")
                .font(.flCallout).foregroundStyle(.flInk2)
            ForEach(campaign.visits) { store in
                Label("\(store.name): code \(store.code ?? "")\(store.redeemedAt != nil ? " (used)" : "")", systemImage: "checkmark.seal.fill")
                    .font(.flCaption.monospacedDigit()).foregroundStyle(.flSuccess)
            }
            HStack(spacing: FLSpace.sm) {
                ProgressView(value: Double(campaign.visits.count), total: Double(max(1, stores.count))).tint(.flBrand)
                Text("\(campaign.visits.count)/\(stores.count) stores").font(.flCaption.weight(.semibold).monospacedDigit()).foregroundStyle(.flInk2)
            }
            HStack(spacing: FLSpace.sm) {
                if campaign.bonusPoints > 0 { PointsPill(points: campaign.bonusPoints) }
                Spacer(minLength: 0)
                Text("Ends \(campaign.endsAt, format: .relative(presentation: .named))").font(.flCaption).foregroundStyle(.flInk2)
            }
            Text("Find the stores on the map (blue storefront pins).").font(.flCaption).foregroundStyle(.flInk2)
        }
        .flCard()
        .accessibilityElement(children: .combine)
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
