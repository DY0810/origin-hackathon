import Foundation
import Testing
@testable import FaultLine

struct MyReportsTests {
    private func day(_ d: Int, hour: Int = 12) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.date(from: DateComponents(year: 2026, month: 9, day: d, hour: hour))!
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func longestStreakCountsConsecutiveDaysOnce() {
        #expect(MyReports.longestStreak([], calendar: utc) == 0)
        // 1, 2 (twice), 3, then a gap, then 10, 11: best run is 3.
        let dates = [day(3), day(1), day(2, hour: 9), day(2, hour: 20), day(10), day(11)]
        #expect(MyReports.longestStreak(dates, calendar: utc) == 3)
    }

    @Test func decodesAndDerivesBadges() throws {
        let json = #"""
        {"reports":[
          {"id":"107544cb-4b60-44d7-a811-235c949d1fe0","primary_type":"crack","severity":5,"status":"accepted","asset_name":"Doheny Library",
           "is_first_finder":true,"points":240,"created_at":"2026-09-26T01:02:03.456+00:00","fixed_at":"2026-09-26T05:00:00+00:00","in_surge":true},
          {"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","primary_type":null,"severity":null,"status":"rejected","asset_name":null,
           "is_first_finder":null,"points":0,"created_at":"2026-09-25T01:02:03+00:00","fixed_at":null,"in_surge":false}],
         "stats":{"verified":1,"first_finds":1,"legendary":1,"surge":1,"fixed":1,"quests":0}}
        """#
        let mine = try Backend.decoder.decode(MyReports.self, from: Data(json.utf8))
        #expect(mine.reports.first?.reportStatus == .fixed)
        #expect(mine.reports.last?.typeLabel == "Not damage")
        let earned = Dictionary(uniqueKeysWithValues: mine.badges.map { ($0.name, $0.earned) })
        #expect(earned == ["First find": true, "First finder": true, "Legendary": true, "Streak": false,
                           "Surge responder": true, "Fixed!": true, "Quest finisher": false])
        // Locked badges say how to earn them.
        #expect(mine.badges.first { $0.name == "Quest finisher" }?.detail == "Complete any quest.")
    }

    @Test func rejectedReportsNeverBuildAStreak() throws {
        func report(_ day: Int, _ status: String, points: Int) -> String {
            #"{"id":"\#(UUID())","primary_type":null,"severity":null,"status":"\#(status)","asset_name":null,"is_first_finder":null,"# +
            #""points":\#(points),"created_at":"2026-09-2\#(day)T18:00:00+00:00","fixed_at":null,"in_surge":false}"#
        }
        let stats = #""stats":{"verified":0,"first_finds":0,"legendary":0,"surge":0,"fixed":0,"quests":0}"#
        let rejected = "{\"reports\":[\(report(1, "rejected", points: 0)),\(report(2, "rejected", points: 0)),\(report(3, "rejected", points: 0))],\(stats)}"
        let mine = try Backend.decoder.decode(MyReports.self, from: Data(rejected.utf8))
        #expect(mine.badges.first { $0.name == "Streak" }?.earned == false)
        #expect(mine.badges.allSatisfy { !$0.earned })
        // Same days, but in review (counts) -> a 3-day streak.
        let review = rejected.replacingOccurrences(of: "\"rejected\"", with: "\"review\"")
        let reviewed = try Backend.decoder.decode(MyReports.self, from: Data(review.utf8))
        #expect(reviewed.badges.first { $0.name == "Streak" }?.earned == true)
    }
}
