import SwiftUI

/// MASTER.md §6 ResultSheet: checking -> verdict (or failure with retry, or saved offline for the Outbox).
struct ResultSheet: View {
    enum Phase: Equatable {
        case checking
        case verified(Verification)
        case failed(String)
        case queued
    }

    let phase: Phase
    var image: UIImage? = nil   // the photo just taken, already in memory
    let onRetry: () -> Void
    let onReportAnother: () -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var shownPoints = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FLSpace.lg) {
                if case .verified = phase {} else { photoRow(nil) }
                switch phase {
                case .checking:
                    StatusBanner(status: .pending, detail: "FaultLine is checking the photo. This takes a few seconds.")
                    ProgressView().frame(maxWidth: .infinity)
                case .failed(let message):
                    StatusBanner(status: .failed, detail: message)
                    Button("Try again", action: onRetry).buttonStyle(.flPrimary)
                    Button("Close", action: onDone).buttonStyle(.flSecondary)
                case .queued:  // MASTER §7.1 step 5: never lose a capture
                    StatusBanner(status: .queued, detail: "It's kept on this phone. We'll let you know when it's checked.")
                    Button("Done", action: onDone).buttonStyle(.flPrimary)
                    Button("Report another", action: onReportAnother)
                        .buttonStyle(.flSecondary)
                        .onAppear { AccessibilityNotification.Announcement(ReportStatus.queued.text).post() }
                        .task { await FixNotifier.requestPermission() }
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

    /// Thumbnail with the asset and, once verified, the first finder / confirmation tag beside it.
    @ViewBuilder private func photoRow(_ result: Verification?) -> some View {
        let asset = result?.asset
        let finder = result.flatMap { $0.isDamage && $0.inDanger != true ? $0.firstFinder : nil }
        if image != nil || asset != nil || finder != nil {
            // Stacks at accessibility sizes so the asset name and tag get the full width.
            let row = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: FLSpace.md))
                                                   : AnyLayout(HStackLayout(alignment: .top, spacing: FLSpace.md))
            row {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.thumbSide, height: Self.thumbSide)
                        .clipShape(.rect(cornerRadius: FLRadius.md))
                        .accessibilityLabel("Your photo")
                }
                VStack(alignment: .leading, spacing: FLSpace.sm) {
                    if let asset {
                        Label(asset.name, systemImage: asset.symbol)
                            .font(.flCallout)
                            .foregroundStyle(.flInk2)
                            .accessibilityLabel("Asset: \(asset.name)")
                    }
                    if let finder { FinderTag(firstFinder: finder) }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
        }
    }

    static let thumbSide = FLSpace.xxxl + FLSpace.lg  // 64 pt, same as ReportCard

    @ViewBuilder private func verdict(_ result: Verification) -> some View {
        photoRow(result)
        StatusBanner(status: result.reportStatus, detail: result.reportStatus == .rejected ? result.retakeTip ?? result.explanation : result.explanation)

        if result.immediateDanger {
            Label("If anyone is in danger right now, call 911.", systemImage: "exclamationmark.octagon.fill")
                .font(.flHeadline)
                .foregroundStyle(.flDanger)
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
            if result.inDanger == true {  // MASTER principle 7: no reward copy at all
                Label(Self.dangerText, systemImage: "flame.fill").font(.flHeadline).foregroundStyle(.flDanger)
            } else {
                rewards(result)
            }
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
            if result.why == nil, let base = result.basePoints, let multiplier = result.multiplier, multiplier > 1 {
                Text("\(base) × \(multiplier.formatted())× zone").font(.flCaption.monospacedDigit()).foregroundStyle(.flGoldText)
            }
            if let xp = result.xp, xp > 0 { XPLabel(xp: xp) }
        }
        // MASTER §9: deterministic and explained. One line per factor, straight from award_report.
        if let why = result.why, !why.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(why, id: \.self) { Text($0) }
                Text("= \(result.pointsPending) pts").fontWeight(.bold).foregroundStyle(.flGoldText)
            }
            .font(.flCaption.monospacedDigit())
            .foregroundStyle(.flInk2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("How your points were calculated: " + why.joined(separator: ". ") + ". Total \(result.pointsPending) points.")
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

    static let dangerText = "No points inside a danger zone. Stay safe."

    private func announcement(_ result: Verification) -> String {
        var parts = [result.reportStatus.text]
        if result.inDanger == true { parts.append(Self.dangerText) }
        if let severity = result.severityLevel { parts.append(severity.accessibilityText) }
        if result.isDamage, result.inDanger != true, let first = result.firstFinder { parts.append(FinderTag.text(first)) }
        if result.pointsPending > 0 { parts.append("\(result.pointsPending) points pending") }
        for quest in result.questsCompleted ?? [] { parts.append("Quest complete: \(quest.title)") }
        if result.leveledUp, let level = result.levelAfter { parts.append("Level up, level \(level)") }
        return parts.joined(separator: ". ")
    }
}

/// MASTER.md §6 ResultSheet tag. First finder is gold (it pays the full reward, CLAUDE.md §6.5); a confirmation is neutral.
struct FinderTag: View {
    let firstFinder: Bool

    static func text(_ firstFinder: Bool) -> String { firstFinder ? "First finder" : "Confirmation" }

    var body: some View {
        Label(Self.text(firstFinder), systemImage: firstFinder ? "star.fill" : "person.2.fill")
            .font(.flCaption.weight(.bold))
            .foregroundStyle(firstFinder ? .flOnGold : .flInk2)
            .padding(.horizontal, FLSpace.sm)
            .padding(.vertical, FLSpace.xs)
            .background(firstFinder ? Color.flGold : Color.flSurface2, in: .capsule)
            .accessibilityLabel(firstFinder ? "First finder: full points" : "Confirmation: someone reported this first, reduced points")
    }
}

#Preview("Verified") {
    ResultSheet(phase: .verified(Verification(
        reportId: UUID(), status: "accepted", isDamage: true, damageTypes: ["spalling", "exposed_rebar"],
        primaryType: "spalling", severity: 4, confidence: 0.86,
        explanation: "Concrete has broken away exposing corroded rebar on the column base.",
        retakeTip: nil, immediateDanger: false, pointsPending: 160, basePoints: 80, multiplier: 2, xp: 30,
        levelBefore: 1, levelAfter: 2, questsCompleted: [.init(title: "First find", rewardPoints: 20, rewardXp: 25)],
        asset: Asset(kind: "building", name: "Doheny Library"), firstFinder: true)),
        image: UIImage(systemName: "photo"), onRetry: {}, onReportAnother: {}, onDone: {})
}

#Preview("Queued") {
    ResultSheet(phase: .queued, image: UIImage(systemName: "photo"), onRetry: {}, onReportAnother: {}, onDone: {})
}

#Preview("Checking") {
    ResultSheet(phase: .checking, onRetry: {}, onReportAnother: {}, onDone: {})
}
