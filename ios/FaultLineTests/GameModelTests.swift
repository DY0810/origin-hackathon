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
