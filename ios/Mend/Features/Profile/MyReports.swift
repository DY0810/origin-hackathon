import SwiftUI

/// The player's recent reports and badge counts, from `my_reports()` (supabase/migrations/*_my_reports.sql).
struct MyReports: Decodable, Equatable {
    let reports: [Report]
    let stats: Stats

    struct Report: Decodable, Identifiable, Equatable, Hashable {
        let id: UUID
        let primaryType: String?
        let severity: Int?
        let status: String          // accepted | review | rejected
        let assetName: String?
        let isFirstFinder: Bool?
        let points: Int
        let createdAt: Date
        let fixedAt: Date?
        let inSurge: Bool

        /// Earned something or is waiting on a reviewer: same rule as my_reports() stats.
        var counts: Bool { status != "rejected" && (points > 0 || status == "review") }

        var typeLabel: String { primaryType.map(Verification.label) ?? (status == "rejected" ? "Not damage" : "Damage") }

        var reportStatus: ReportStatus {
            if fixedAt != nil { return .fixed }
            return switch status {
            case "accepted": .accepted
            case "rejected": .rejected
            default: .review
            }
        }
    }

    struct Stats: Decodable, Equatable {
        let verified: Int
        let firstFinds: Int
        let legendary: Int
        let surge: Int
        let fixed: Int
        let quests: Int
    }

    /// Longest run of consecutive calendar days with a counted (not rejected) report, in the given calendar.
    // ponytail: from the last 50 reports only; a server-side streak once players file more than that.
    static func longestStreak(_ dates: [Date], calendar: Calendar = .current) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) }).sorted()
        var best = 0, run = 0
        var previous: Date?
        for day in days {
            run = previous.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } == day ? run + 1 : 1
            best = max(best, run)
            previous = day
        }
        return best
    }

    var badges: [Badge] {
        let streak = Self.longestStreak(reports.filter(\.counts).map(\.createdAt))
        return [
            Badge(name: "First find", symbol: "camera.viewfinder", earned: stats.verified > 0,
                  detail: stats.verified > 0 ? "\(stats.verified) counted reports" : "File your first report that counts as damage."),
            Badge(name: "First finder", symbol: "flag.checkered", earned: stats.firstFinds > 0,
                  detail: stats.firstFinds > 0 ? "×\(stats.firstFinds): first to report an asset" : "Be the first to report damage on an asset."),
            Badge(name: "Legendary", symbol: "crown", earned: stats.legendary > 0,
                  detail: stats.legendary > 0 ? "×\(stats.legendary) severity 5 finds" : "Find a severity 5 hazard. Report it from a safe distance."),
            Badge(name: "Streak", symbol: "calendar", earned: streak >= 3,
                  detail: streak >= 3 ? "\(streak) days in a row, your best" : "Report on 3 days in a row, whenever it suits you."),
            Badge(name: "Surge responder", symbol: "cloud.bolt", earned: stats.surge > 0,
                  detail: stats.surge > 0 ? "×\(stats.surge) reports during a surge" : "Report inside a surge zone, only where it's safe."),
            Badge(name: "Fixed!", symbol: "wrench.and.screwdriver", earned: stats.fixed > 0,
                  detail: stats.fixed > 0 ? "×\(stats.fixed) of your reports got fixed" : "Get one of your reports repaired by the owner."),
            Badge(name: "Quest finisher", symbol: "flag", earned: stats.quests > 0,
                  detail: stats.quests > 0 ? "×\(stats.quests) quests completed" : "Complete any quest."),
        ]
    }
}

struct Badge: Identifiable, Equatable {
    let name: String
    let symbol: String
    let earned: Bool
    let detail: String   // earned: what you did; locked: how to earn it (no pressure copy, MASTER.md §1.7)
    var id: String { name }
}

@MainActor @Observable
final class MyReportsModel {
    private(set) var data: MyReports?
    private(set) var loadFailed = false

    func load() async {
        do {
            let (body, response) = try await Backend.data(for: Backend.rpc("my_reports"))
            guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
            data = try Backend.decoder.decode(MyReports.self, from: body)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}

struct BadgeTile: View {
    let badge: Badge

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.xs) {
            Image(systemName: badge.symbol)
                .symbolVariant(badge.earned ? .fill : .none)
                .font(.flTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(badge.earned ? .flBrand : .flInk3)
            // Locked also shows a lock, so earned vs locked isn't color alone (MASTER.md §1.5).
            HStack(spacing: FLSpace.xs) {
                if !badge.earned { Image(systemName: "lock.fill").font(.flCaption) }
                Text(badge.name).font(.flHeadline)
            }
            .foregroundStyle(badge.earned ? .flInk : .flInk2)
            Text(badge.detail).font(.flCaption).foregroundStyle(.flInk2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .flCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(badge.name), \(badge.earned ? "earned" : "locked"). \(badge.detail)")
    }
}

/// MASTER.md §6 ReportCard, without the thumbnail (my_reports sends no photo URLs).
struct ReportRow: View {
    let report: MyReports.Report
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Side by side normally; stacked at accessibility sizes so nothing wraps mid-word (MASTER.md §11.2).
    private var row: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: FLSpace.xs))
                                     : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: FLSpace.sm))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.xs) {
            row {
                Text(report.typeLabel).font(.flHeadline).foregroundStyle(.flInk)
                Spacer(minLength: FLSpace.sm)
                if report.points > 0 { Text("+\(report.points) pts").font(.flCaption.weight(.bold).monospacedDigit()).foregroundStyle(.flGoldText) }
                if let s = report.severity.flatMap(Severity.init(rawValue:)) { SeverityBadge(severity: s, showsLabel: false) }
            }
            if let asset = report.assetName { Text(asset).font(.flCallout).foregroundStyle(.flInk2) }
            row {
                Label(report.fixedAt != nil ? "Fixed" : statusWord, systemImage: report.reportStatus.symbol)
                    .foregroundStyle(report.reportStatus.tint)
                if report.isFirstFinder == true { Text("First finder").foregroundStyle(.flInk2) }
                Spacer(minLength: 0)
                Text(report.createdAt, format: .relative(presentation: .named)).foregroundStyle(.flInk2)
            }
            .font(.flCaption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .flCard()  // white canvas: rows need the card shadow to read as separate
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens report")
    }

    private var statusWord: String {
        switch report.reportStatus {
        case .accepted: "Verified"
        case .rejected: "Not counted"
        default: "In review"
        }
    }
}

/// Report detail: what it was, where it is in its life (filed → verified → fixed), and for cracks a demo trend.
struct ReportDetailScreen: View {
    let report: MyReports.Report
    @ScaledMetric(relativeTo: .body) private var iconWidth = FLSpace.xl  // one column width for every status icon

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FLSpace.xl) {
                VStack(spacing: 0) {
                    if let asset = report.assetName {
                        FLInfoRow(title: "Asset") { Text(asset).font(.flHeadline).foregroundStyle(.flInk).multilineTextAlignment(.trailing) }
                    }
                    if let s = report.severity.flatMap(Severity.init(rawValue:)) {
                        FLInfoRow(title: "Emergency level") { SeverityBadge(severity: s) }
                    }
                    if let first = report.isFirstFinder {
                        FLInfoRow(title: "Find") { FinderTag(firstFinder: first) }
                    }
                    if report.points > 0 {
                        FLInfoRow(title: "Points") { PointsPill(points: report.points) }
                    }
                }
                .flCard()

                VStack(alignment: .leading, spacing: FLSpace.md) {
                    Text("Status").font(.flHeadline).foregroundStyle(.flInk)
                    ForEach(Array(history.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: FLSpace.sm) {
                            Image(systemName: step.symbol).foregroundStyle(step.tint).frame(width: iconWidth)  // aligns the titles at every text size
                            VStack(alignment: .leading, spacing: FLSpace.xs) {
                                Text(step.title).font(.flBody).foregroundStyle(step.date == nil ? .flInk2 : .flInk)
                                if let date = step.date {
                                    Text(date, format: .dateTime.month().day().hour().minute()).font(.flCaption).foregroundStyle(.flInk2)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .flCard()

                if report.primaryType == "crack" && report.status != "rejected" { DemoTrend(start: report.createdAt).flCard() }
            }
            .padding(FLSpace.gutter)
        }
        .background(.flCanvas)
        .navigationTitle(report.typeLabel)
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Step { let title: String; let symbol: String; let tint: Color; let date: Date? }

    /// verify-report stores the report with its verdict, so "verified" happens at created_at.
    private var history: [Step] {
        var steps = [Step(title: "Submitted", symbol: "tray.and.arrow.up.fill", tint: .flInk2, date: report.createdAt)]
        switch report.status {
        case "accepted": steps.append(Step(title: "Verified", symbol: ReportStatus.accepted.symbol, tint: .flSuccess, date: report.createdAt))
        case "rejected": steps.append(Step(title: "Not counted as damage", symbol: ReportStatus.rejected.symbol, tint: .flWarning, date: report.createdAt))
        default: steps.append(Step(title: "Waiting for a reviewer", symbol: ReportStatus.review.symbol, tint: .flInk2, date: nil))
        }
        if report.status != "rejected" {
            steps.append(report.fixedAt.map { Step(title: "Fixed", symbol: ReportStatus.fixed.symbol, tint: .flSuccess, date: $0) }
                         ?? Step(title: "Not fixed yet", symbol: "circle.dashed", tint: .flInk3, date: nil))
        }
        return steps
    }
}

/// CLAUDE.md §10: mocked "crack widened 40% over 3 reports". Clearly labelled demo data.
// ponytail: a real trend needs repeat photos of the same asset (asset id + measured crack width per report); fake until then.
struct DemoTrend: View {
    let start: Date

    private var points: [(date: Date, width: Double)] {
        [(start.addingTimeInterval(-120 * 86_400), 2.5), (start.addingTimeInterval(-60 * 86_400), 3.0), (start, 3.5)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FLSpace.sm) {
            FLAdaptiveRow {
                Text("Condition trend").font(.flHeadline).foregroundStyle(.flInk)
                Spacer(minLength: 0)
                Text("Demo trend").font(.flCaption.weight(.bold)).foregroundStyle(.flInk2)
                    .padding(.horizontal, FLSpace.sm).padding(.vertical, FLSpace.xs)
                    .background(.flSurface2, in: .capsule)
            }
            Text("Crack widened 40% over 3 reports").font(.flBody).foregroundStyle(.flInk)
            ForEach(points, id: \.date) { point in
                VStack(alignment: .leading, spacing: FLSpace.xs) {
                    Text(point.date, format: .dateTime.month(.abbreviated).day().year()).font(.flCaption).foregroundStyle(.flInk2)
                    HStack(spacing: FLSpace.sm) {
                        Capsule().fill(.flBrand).frame(width: FLSpace.xxl * point.width, height: FLSpace.sm)
                        Text("\(point.width, format: .number.precision(.fractionLength(1))) mm crack width")
                            .font(.flCaption.monospacedDigit()).foregroundStyle(.flInk)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Sample data for the demo. Real trends need repeat photos of the same asset.").font(.flCaption).foregroundStyle(.flInk2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
