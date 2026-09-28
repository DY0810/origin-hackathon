import SwiftUI

/// MASTER.md §7.5: spendable (settled) balance big, pending separate, redeem catalog, points history.
struct RewardsScreen: View {
    @State private var redeeming: GameState.Reward?
    @State private var mine = MyReportsModel()
    @Environment(GameModel.self) private var game
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GameContainer(title: "Rewards") { state in
            VStack(alignment: .leading, spacing: FLSpace.md) {
                // Badges sit beside the total (team decision 2026-09-27); below it when there's no room.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: FLSpace.md) { balance(state); Spacer(minLength: 0); badgeStrip }
                    VStack(alignment: .leading, spacing: FLSpace.md) { balance(state); badgeStrip }
                }
                if state.pointsPending > 0 {
                    PointsPill(points: state.pointsPending, pending: true)
                }
                Text("Points settle 24 hours after a report is verified. Reports under review settle once a person checks them.")
                    .font(.flCaption)
                    .foregroundStyle(.flOnAccent)  // on Sky; flInk2 would be 3.75:1
                    .fixedSize(horizontal: false, vertical: true)
            }
            .flHeroCard()

            if let catalog = state.catalog, !catalog.isEmpty {
                VStack(alignment: .leading, spacing: FLSpace.md) {
                    Text("Redeem").font(.flHeadline).foregroundStyle(.flInk)
                    LazyVGrid(columns: [typeSize.isAccessibilitySize ? GridItem(.flexible()) : GridItem(.adaptive(minimum: 150), spacing: FLSpace.md)],
                              spacing: FLSpace.md) {
                        ForEach(catalog) { reward in
                            RewardCard(reward: reward, shortfall: state.shortfall(for: reward)) { redeeming = reward }
                        }
                    }
                }
            }

            if let redemptions = state.redemptions, !redemptions.isEmpty {
                VStack(alignment: .leading, spacing: FLSpace.md) {
                    Text("Your rewards").font(.flHeadline).foregroundStyle(.flInk)
                    ForEach(redemptions) { item in
                        FLAdaptiveRow(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.flBody).foregroundStyle(.flInk)
                                Text(item.code).font(.flCallout.monospaced()).foregroundStyle(.flInk2).textSelection(.enabled)
                                Text(item.createdAt, format: .relative(presentation: .named)).font(.flCaption).foregroundStyle(.flInk2)
                            }
                            Spacer(minLength: FLSpace.sm)
                            Text("\(item.points) pts").font(.flCallout.monospacedDigit()).foregroundStyle(.flInk2)
                                .accessibilityLabel("\(item.points) points")
                        }
                        .accessibilityElement(children: .combine)
                        Divider()
                    }
                    Text("Demo codes. Not real gift cards.").font(.flCaption).foregroundStyle(.flInk2)
                }
            }

            VStack(alignment: .leading, spacing: FLSpace.md) {
                Text("History").font(.flHeadline).foregroundStyle(.flInk)
                if state.history.isEmpty {
                    Text("Verified reports and completed quests show up here.").font(.flCallout).foregroundStyle(.flInk2)
                }
                ForEach(state.history) { entry in
                    FLAdaptiveRow(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label).font(.flBody).foregroundStyle(.flInk)
                            Text(entry.createdAt, format: .relative(presentation: .named)).font(.flCaption).foregroundStyle(.flInk2)
                        }
                        Spacer(minLength: FLSpace.sm)
                        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
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
        .sheet(item: $redeeming) { RedeemSheet(reward: $0) }
        .task(id: game.state) { await mine.load() }  // badges come from my_reports(), same as Profile
    }

    private func balance(_ state: GameState) -> some View {
        VStack(alignment: .leading, spacing: FLSpace.xs) {
            Text("Available").font(.flCallout).foregroundStyle(.flOnAccent)
            Text(state.pointsSettled.formatted())
                .font(.flDisplay)
                .foregroundStyle(.flInk)
                .contentTransition(.numericText(value: Double(state.pointsSettled)))
                .accessibilityLabel("\(state.pointsSettled) points available")
        }
    }

    /// Earned badges as small white medallions; the full list with how to earn each lives on Profile.
    @ViewBuilder private var badgeStrip: some View {
        let earned = mine.data?.badges.filter(\.earned) ?? []
        if !earned.isEmpty {
            HStack(spacing: -FLSpace.sm) {  // slight overlap, like a stack of medals
                ForEach(earned.prefix(4)) { badge in
                    Image(systemName: badge.symbol)
                        .symbolVariant(.fill)
                        .font(.flHeadline)
                        .foregroundStyle(.flInk)
                        .frame(width: FLSize.iconButton, height: FLSize.iconButton)
                        .background(.flSurface, in: .circle)
                        .overlay(Circle().strokeBorder(.flAccent, lineWidth: 2))
                }
                if earned.count > 4 {
                    Text("+\(earned.count - 4)")
                        .font(.flCaption.monospacedDigit())
                        .foregroundStyle(.flInk)
                        .frame(width: FLSize.iconButton, height: FLSize.iconButton)
                        .background(.flSurface, in: .circle)
                        .overlay(Circle().strokeBorder(.flAccent, lineWidth: 2))
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)  // fixed-size medallions; names are in the label
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Badges earned: " + earned.map(\.name).joined(separator: ", "))
        }
    }
}

/// Catalog item: brand-neutral placeholder art (no merchant logos, MASTER.md §7.5), price, and either
/// "Redeem" or a factual "N more points" when the settled balance is short.
struct RewardCard: View {
    let reward: GameState.Reward
    let shortfall: Int
    let onRedeem: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.sm) {
            Image(systemName: "giftcard.fill")
                .font(.flTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.flBrand)
                .accessibilityHidden(true)
            Text(reward.name).font(.flHeadline).foregroundStyle(.flInk).fixedSize(horizontal: false, vertical: true)
            // Neutral price: gold is for earning moments (MASTER.md principle 3), not prices.
            Label("\(reward.points.formatted()) points", systemImage: "star.circle")
                .font(.flCallout.monospacedDigit())
                .foregroundStyle(.flInk2)
            Spacer(minLength: 0)
            if shortfall > 0 {
                Text("\(shortfall.formatted()) more points")
                    .font(.flCallout)
                    .foregroundStyle(.flInk2)
                    .frame(maxWidth: .infinity, minHeight: FLSpace.minTap, alignment: .leading)
            } else {
                Button("Redeem", action: onRedeem)
                    .buttonStyle(.flSecondary)
                    .accessibilityLabel("Redeem \(reward.name)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .flCard()
    }
}

/// Confirm -> redeeming -> code (or error). MASTER.md §7.5: states the cost and what happens next.
struct RedeemSheet: View {
    let reward: GameState.Reward
    @Environment(GameModel.self) private var game
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var result: GameModel.RedeemResult?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FLSpace.lg) {
                if let result {
                    Label("Code sent", systemImage: "checkmark.seal.fill").font(.flHeadline).foregroundStyle(.flSuccess)
                    Text(reward.name).font(.flTitle).foregroundStyle(.flInk)
                    Text("It's also saved under Your rewards.").font(.flCallout).foregroundStyle(.flInk2)
                    Text(result.code)
                        .font(.flNumber.monospaced())
                        .foregroundStyle(.flInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(FLSpace.lg)
                        .background(.flSurface2, in: .rect(cornerRadius: FLRadius.md))
                    Label("Demo: not a real gift card.", systemImage: "info.circle").font(.flCallout).foregroundStyle(.flInk2)
                    Button(copied ? "Copied" : "Copy code") {
                        UIPasteboard.general.string = result.code
                        copied = true
                    }
                    .buttonStyle(.flSecondary)
                    Button("Done") { dismiss() }.buttonStyle(.flPrimary)
                } else {
                    Text("Redeem \(reward.points.formatted()) points for a \(reward.name)?")
                        .font(.flTitle)
                        .foregroundStyle(.flInk)
                    Text("Points come out of your available balance. You'll get a code here right away, and it stays under Your rewards.")
                        .font(.flCallout)
                        .foregroundStyle(.flInk2)
                    Label("Demo: not a real gift card.", systemImage: "info.circle").font(.flCallout).foregroundStyle(.flInk2)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.flCallout).foregroundStyle(.flWarning)
                    }
                    Button { busy = true; Task { await redeem() } } label: {
                        if busy { ProgressView().tint(.flOnBrand) } else { Text("Redeem \(reward.points.formatted()) points") }
                    }
                    .buttonStyle(.flPrimary)
                    .disabled(busy)
                    Button("Cancel") { dismiss() }.buttonStyle(.flSecondary).disabled(busy)
                }
            }
            .padding(FLSpace.gutter)
        }
        .background(.flCanvas)
        .presentationDetents([.medium, .large])
        .presentationBackground(.flCanvas)
        .interactiveDismissDisabled(busy)
        .sensoryFeedback(.success, trigger: result)
    }

    private func redeem() async {
        error = nil
        do { result = try await game.redeem(reward) } catch { self.error = error.localizedDescription }
        busy = false
    }
}

#Preview { RewardsScreen().environment(GameModel()) }
