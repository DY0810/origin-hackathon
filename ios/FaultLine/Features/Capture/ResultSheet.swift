import SwiftUI

/// MASTER.md §6 ResultSheet: checking -> verdict (or failure with retry).
struct ResultSheet: View {
    enum Phase: Equatable {
        case checking
        case verified(Verification)
        case failed(String)
    }

    let phase: Phase
    let onRetry: () -> Void
    let onReportAnother: () -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shownPoints = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FLSpace.lg) {
                switch phase {
                case .checking:
                    StatusBanner(status: .pending, detail: "FaultLine is checking the photo. This takes a few seconds.")
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    StatusBanner(status: .failed, detail: message)
                    Button("Try again", action: onRetry).buttonStyle(.flPrimary)
                    Button("Close", action: onDone).buttonStyle(.flSecondary)
                case .verified(let result):
                    verdict(result)
                }
            }
            .padding(FLSpace.gutter)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(phase == .checking)
        .sensoryFeedback(trigger: phase) { _, new in
            guard case .verified(let result) = new else { return nil }
            return result.reportStatus == .rejected ? .warning : .success
        }
    }

    @ViewBuilder private func verdict(_ result: Verification) -> some View {
        StatusBanner(status: result.reportStatus, detail: result.reportStatus == .rejected ? result.retakeTip ?? result.explanation : result.explanation)

        if result.immediateDanger {
            Label("If anyone is in danger right now, call 911.", systemImage: "exclamationmark.octagon.fill")
                .font(.flHeadline)
                .foregroundStyle(.flDanger)
        }

        if let asset = result.asset {
            Label(asset.name, systemImage: asset.symbol)
                .font(.flCallout)
                .foregroundStyle(.flInk2)
                .accessibilityLabel("Asset: \(asset.name)")
        }

        if result.isDamage {
            HStack(spacing: FLSpace.sm) {
                if let severity = result.severityLevel { SeverityBadge(severity: severity) }
                Spacer(minLength: 0)
                if result.pointsPending > 0 { PointsPill(points: shownPoints, pending: true) }
            }
            Text(result.damageTypes.map(Verification.label).joined(separator: ", "))
                .font(.flBody)
                .foregroundStyle(.flInk)
            rewards(result)
        }

        Button("Done", action: onDone).buttonStyle(.flPrimary)
        Button(result.reportStatus == .rejected ? "Retake photo" : "Report another", action: onReportAnother)
            .buttonStyle(.flSecondary)
            .onAppear {
                withAnimation(FLMotion.resolve(FLMotion.reward, reduceMotion)) { shownPoints = result.pointsPending }
                AccessibilityNotification.Announcement(announcement(result)).post()
            }
    }

    @ViewBuilder private func rewards(_ result: Verification) -> some View {
        HStack(spacing: FLSpace.sm) {
            if let base = result.basePoints, let multiplier = result.multiplier, multiplier > 1 {
                Text("\(base) × \(multiplier.formatted())× zone").font(.flCaption.monospacedDigit()).foregroundStyle(.flGoldText)
            }
            if let xp = result.xp, xp > 0 { XPLabel(xp: xp) }
        }
        ForEach(result.questsCompleted ?? [], id: \.self) { quest in
            HStack(spacing: FLSpace.sm) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.flSuccess)
                Text("Quest complete: \(quest.title)").font(.flHeadline).foregroundStyle(.flInk)
                Spacer(minLength: 0)
                PointsPill(points: quest.rewardPoints, pending: true)
                XPLabel(xp: quest.rewardXp)
            }
            .accessibilityElement(children: .combine)
        }
        if result.leveledUp, let level = result.levelAfter {
            Label("Level up! You're now level \(level).", systemImage: "sparkles")
                .font(.flHeadline)
                .foregroundStyle(.flBrand)
        }
        if result.pointsPending > 0 {
            Text("Points settle after fraud checks.").font(.flCaption).foregroundStyle(.flInk2)
        }
        Label("We'll let you know when it's fixed.", systemImage: "bell")
            .font(.flCaption)
            .foregroundStyle(.flInk2)
            .task { await FixNotifier.requestPermission() }
    }

    private func announcement(_ result: Verification) -> String {
        var parts = [result.reportStatus.text]
        if let severity = result.severityLevel { parts.append(severity.accessibilityText) }
        if result.pointsPending > 0 { parts.append("\(result.pointsPending) points pending") }
        for quest in result.questsCompleted ?? [] { parts.append("Quest complete: \(quest.title)") }
        if result.leveledUp, let level = result.levelAfter { parts.append("Level up, level \(level)") }
        return parts.joined(separator: ". ")
    }
}

#Preview("Verified") {
    ResultSheet(phase: .verified(Verification(
        reportId: UUID(), status: "accepted", isDamage: true, damageTypes: ["spalling", "exposed_rebar"],
        primaryType: "spalling", severity: 4, confidence: 0.86,
        explanation: "Concrete has broken away exposing corroded rebar on the column base.",
        retakeTip: nil, immediateDanger: false, pointsPending: 160, basePoints: 80, multiplier: 2, xp: 30,
        levelBefore: 1, levelAfter: 2, questsCompleted: [.init(title: "First find", rewardPoints: 20, rewardXp: 25)],
        asset: Asset(kind: "building", name: "Doheny Library"))),
        onRetry: {}, onReportAnother: {}, onDone: {})
}

#Preview("Checking") {
    ResultSheet(phase: .checking, onRetry: {}, onReportAnother: {}, onDone: {})
}
