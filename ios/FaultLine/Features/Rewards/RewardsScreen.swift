import SwiftUI

/// MASTER.md §7.5: spendable (settled) balance big, pending separate, catalog, how points work, history.
/// Partner offers come first: merchants fund them to win the visit (the CRED model), so they cost fewer points.
// ponytail: redemption codes are mocked server-side (CLAUDE.md §6.6); a gift-card API replaces them later.
struct RewardsScreen: View {
    @Environment(GameModel.self) private var game
    @State private var redeeming: RewardsCatalog.Item?

    var body: some View {
        GameContainer(title: "Rewards") { state in
            balance(state)
            if let catalog = game.catalog {
                shop(catalog, settled: state.pointsSettled)
                HowPointsWork(catalog: catalog)
            }
            history(state)
        }
        .task { await game.loadCatalog() }
        .sheet(item: $redeeming) { item in
            RedeemSheet(item: item, settled: game.state?.pointsSettled ?? 0)
        }
    }

    private func balance(_ state: GameState) -> some View {
        VStack(alignment: .leading, spacing: FLSpace.sm) {
            Text("Available").font(.flCallout).foregroundStyle(.flInk2)
            Text(state.pointsSettled.formatted())
                .font(.flDisplay)
                .foregroundStyle(.flInk)
                .contentTransition(.numericText(value: Double(state.pointsSettled)))
                .accessibilityLabel("\(state.pointsSettled) points available")
            if let perDollar = game.catalog?.pointsPerDollar, perDollar > 0 {
                Text("Worth \((Double(state.pointsSettled) / Double(perDollar)).formatted(.currency(code: "USD"))) in gift cards")
                    .font(.flCallout)
                    .foregroundStyle(.flInk2)
            }
            if state.pointsPending > 0 {
                PointsPill(points: state.pointsPending, pending: true)
            }
            Text("Points settle 24 hours after a report is verified. Reports under review settle once a person checks them.")
                .font(.flCaption)
                .foregroundStyle(.flInk2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard()
    }

    private func shop(_ catalog: RewardsCatalog, settled: Int) -> some View {
        VStack(alignment: .leading, spacing: FLSpace.md) {
            Text("Spend points").font(.flHeadline).foregroundStyle(.flInk)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: FLSpace.md)], spacing: FLSpace.md) {
                ForEach(catalog.items) { item in
                    Button { redeeming = item } label: { RewardCard(item: item, affordable: settled >= item.costPoints) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func history(_ state: GameState) -> some View {
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
                            .foregroundStyle(entry.amount >= 0 ? .flGoldText : .flInk2)
                        if !entry.settled { Text("pending").font(.flCaption).foregroundStyle(.flInk2) }
                    }
                }
                .accessibilityElement(children: .combine)
                Divider()
            }
        }
    }
}

/// MASTER §7.5 catalog card: brand-neutral, cost as a PointsPill, dimmed (still tappable) when out of reach.
struct RewardCard: View {
    let item: RewardsCatalog.Item
    let affordable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.sm) {
            Image(systemName: item.symbol).font(.flTitle).foregroundStyle(.flBrand)
            Text(item.title).font(.flHeadline).foregroundStyle(.flInk).multilineTextAlignment(.leading)
            Text(item.partner ?? item.detail).font(.flCaption).foregroundStyle(.flInk2).lineLimit(2)
            Spacer(minLength: 0)
            PointsPill(points: item.costPoints)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .flCard()
        .opacity(affordable ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(affordable ? "Redeem" : "Not enough settled points yet")
    }
}

/// MASTER §7.5: confirmation states the cost and what happens next.
struct RedeemSheet: View {
    let item: RewardsCatalog.Item
    let settled: Int

    @Environment(GameModel.self) private var game
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var result: Redemption?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.lg) {
            Label(item.title, systemImage: item.symbol).font(.flTitle).foregroundStyle(.flInk)
            Text(item.detail).font(.flCallout).foregroundStyle(.flInk2)

            if let result, result.ok, let code = result.code {
                StatusBanner(status: .accepted, detail: "Your code is below. We've also emailed it (demo: nothing is sent).")
                Text(code).font(.flNumber).foregroundStyle(.flInk).textSelection(.enabled)
                Text("\(result.balance.formatted()) points left").font(.flCallout).foregroundStyle(.flInk2)
                Button("Done") { dismiss() }.buttonStyle(.flPrimary)
            } else {
                HStack {
                    Text("Cost").font(.flBody).foregroundStyle(.flInk2)
                    Spacer()
                    PointsPill(points: item.costPoints)
                }
                Text("You have \(settled.formatted()) settled points. Pending points can't be spent yet.")
                    .font(.flCaption).foregroundStyle(.flInk2)
                if let message = failure ?? result?.error {
                    StatusBanner(status: .failed, detail: message)
                }
                Button(busy ? "Redeeming…" : "Redeem for \(item.costPoints.formatted()) points") {
                    Task { await redeem() }
                }
                .buttonStyle(.flPrimary)
                .disabled(busy || settled < item.costPoints)
                Button("Cancel") { dismiss() }.buttonStyle(.flSecondary)
            }
        }
        .padding(FLSpace.gutter)
        .presentationDetents([.medium])
        .sensoryFeedback(.success, trigger: result?.ok == true)
    }

    private func redeem() async {
        busy = true
        defer { busy = false }
        do {
            result = try await game.redeem(item)
            failure = nil
        } catch {
            failure = "Couldn't reach FaultLine. Nothing was spent. Try again."
        }
    }
}

/// The rate card, from the server so it never drifts from award_report (MASTER §9: rewards are explained).
struct HowPointsWork: View {
    let catalog: RewardsCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.md) {
            Text("How points work").font(.flHeadline).foregroundStyle(.flInk)
            ForEach(Severity.allCases.filter { $0.rawValue <= catalog.severityPoints.count }) { severity in
                HStack {
                    SeverityBadge(severity: severity)
                    Spacer()
                    Text("\(catalog.severityPoints[severity.rawValue - 1]) pts").font(.flCallout.monospacedDigit()).foregroundStyle(.flInk)
                }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: FLSpace.xs) {
                rule("building.columns.fill", "Structure at risk (exposed rebar, bulging, falling pieces): ×1.5")
                rule("bolt.fill", "Poles, lights, signs, leaks, fire damage: ×1.25")
                rule("hexagon.fill", "Bounty and surge zones: up to ×5. Tap a gold hex on the map to see why.")
                rule("flag.fill", "First to report it gets full points. Confirming someone else's open report: ×⅓.")
                rule("photo.on.rectangle", "Photos from your library: ×0.5 and no zone bonus.")
                rule("exclamationmark.octagon.fill", "Danger areas pay nothing. Never go somewhere unsafe for points.")
            }
            Text("\(catalog.pointsPerDollar) points = $1 in gift cards. Partner offers need fewer points.")
                .font(.flCaption).foregroundStyle(.flInk2)
        }
        .flCard()
    }

    private func rule(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.flCallout).foregroundStyle(.flInk)
    }
}

#Preview { RewardsScreen().environment(GameModel()) }
