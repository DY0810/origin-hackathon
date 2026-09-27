import Foundation
import Testing
@testable import FaultLine

struct GameModelTests {
    @Test func decodesGameStateAndDerivesProgress() throws {
        let json = #"""
        {"handle":"Sunny Kestrel 23","xp":50,"level":2,"title":"Rookie Spotter","level_start_xp":25,"next_level_xp":100,
         "points_settled":0,"points_pending":170,
         "quests":[{"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","title":"Figueroa sweep","description":"Report 3 issues.","target":3,
           "progress":1,"completed":false,"reward_points":150,"reward_xp":60,"ends_at":"2026-10-02T23:03:10.12345+00:00",
           "multiplier":3,"area_name":"Figueroa corridor"}],
         "leaderboard":[{"rank":6,"handle":"Sunny Kestrel 23","points":170,"is_me":true}],
         "history":[{"amount":150,"kind":"earn","note":"crack · 3× zone","created_at":"2026-09-25T23:13:15.538051+00:00","settled":false},
                    {"amount":20,"kind":"quest","note":"First find","created_at":"2026-09-25T23:13:15.538051+00:00","settled":false}]}
        """#
        let state = try Backend.decoder.decode(GameState.self, from: Data(json.utf8))
        #expect(state.levelProgress == 1.0 / 3.0)  // 25 of 75 XP into level 2
        #expect(state.quests.first?.multiplier == 3)
        #expect(state.leaderboard.first?.isMe == true)
        #expect(state.history.map(\.label) == ["Crack · 3× zone", "Quest: First find"])
    }
}

struct RewardsTests {
    private func state(settled: Int, quests: String = "[]") throws -> GameState {
        let json = """
        {"handle":"h","xp":0,"level":1,"title":"Rookie Spotter","level_start_xp":0,"next_level_xp":25,
         "points_settled":\(settled),"points_pending":900,"min_redeem":500,"quests":\(quests),"leaderboard":[],"history":[],
         "catalog":[{"sku":"amazon-5","name":"$5 Amazon gift card","points":500}],"redemptions":[]}
        """
        return try Backend.decoder.decode(GameState.self, from: Data(json.utf8))
    }

    @Test func shortfallCountsOnlySettledPoints() throws {
        let short = try state(settled: 320)
        #expect(short.shortfall(for: short.catalog![0]) == 180)  // 900 pending doesn't help
        let rich = try state(settled: 500)
        #expect(rich.shortfall(for: rich.catalog![0]) == 0)
        let cheap = GameState.Reward(sku: "x", name: "x", points: 100)
        #expect(short.shortfall(for: cheap) == 180)  // minimum threshold applies
    }

    @Test func badgeDots() throws {
        let surge = #"[{"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","title":"Storm sweep","description":"d","target":2,"progress":0,"completed":false,"reward_points":200,"reward_xp":80,"ends_at":null,"multiplier":5,"area_name":"A","surge":true},{"id":"9b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","title":"Plain","description":"d","target":2,"progress":0,"completed":false,"reward_points":200,"reward_xp":80,"ends_at":null,"multiplier":null,"area_name":null,"surge":false}]"#
        let s = try state(settled: 700, quests: surge)
        #expect(s.surgeQuestKey == "8B1C2C55-9A0E-4B7A-9D7E-1F2A3B4C5D6E")
        #expect(s.hasNewSurge(seen: ""))
        #expect(!s.hasNewSurge(seen: s.surgeQuestKey))
        #expect(try !state(settled: 0).hasNewSurge(seen: ""))
        #expect(s.hasNewSettledPoints(seen: 500))
        #expect(!s.hasNewSettledPoints(seen: 700))
    }

    @Test func decodesOldGameStateWithoutRewards() throws {
        let json = #"{"handle":"h","xp":0,"level":1,"title":"t","level_start_xp":0,"next_level_xp":25,"points_settled":0,"points_pending":0,"quests":[],"leaderboard":[],"history":[]}"#
        #expect(try Backend.decoder.decode(GameState.self, from: Data(json.utf8)).catalog == nil)
    }
}
