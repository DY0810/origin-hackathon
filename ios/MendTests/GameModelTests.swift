import Foundation
import Testing
@testable import Mend

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

/// Merchant partner offers in the catalog, the rate card, and sponsored campaigns (20260927*_*.sql).
struct MerchantTests {
    private let json = """
    {"handle":"h","xp":0,"level":1,"title":"Rookie Spotter","level_start_xp":0,"next_level_xp":25,
     "points_settled":200,"points_pending":0,"min_redeem":500,"quests":[],"leaderboard":[],"history":[],
     "catalog":[{"sku":"partner-coffee","name":"Free coffee","points":150,"kind":"partner_offer","partner":"Partner café","detail":"d"},
                {"sku":"amazon-5","name":"$5 Amazon gift card","points":500,"kind":"gift_card","partner":null,"detail":null}],
     "redemptions":[],"severity_points":[10,25,50,80,120],"points_per_dollar":100}
    """

    @Test func partnerOffersSkipTheGiftCardMinimum() throws {
        let state = try Backend.decoder.decode(GameState.self, from: Data(json.utf8))
        let coffee = state.catalog![0], giftCard = state.catalog![1]
        #expect(coffee.isPartnerOffer && coffee.symbol == "storefront.fill" && coffee.partner == "Partner café")
        #expect(state.shortfall(for: coffee) == 0)      // 150 ≤ 200 settled, no $5 floor
        #expect(state.shortfall(for: giftCard) == 300)  // gift cards keep it
        #expect(state.severityPoints == [10, 25, 50, 80, 120] && state.pointsPerDollar == 100)
    }

    @Test func decodesCampaignStateAndCheckIn() throws {
        let campaigns = try Backend.decoder.decode([SponsoredCampaign].self, from: Data(#"""
        [{"id":"1b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","sponsor":"Demo: Convenience chain","title":"Slushie Sweep",
          "offer":"Free small slushie","detail":null,"bonus_points":50,"radius_m":300,"ends_at":"2026-10-10T20:00:00.123456+00:00",
          "visits_left":1999,
          "stores":[{"id":"0b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","name":"Store: Jefferson & Hoover","lat":34.0214,"lng":-118.2862,
                     "qualified":true,"code":"A1B2C3","checked_in_at":"2026-09-26T20:00:00.512345+00:00","redeemed_at":null},
                    {"id":"2b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","name":"Store: Figueroa & 23rd","lat":34.0306,"lng":-118.2742,
                     "qualified":false,"code":null,"checked_in_at":null,"redeemed_at":null}]},
         {"id":"3b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","sponsor":"Brand","title":"Danger-only","offer":"x","detail":null,
          "bonus_points":0,"radius_m":150,"ends_at":"2026-10-10T20:00:00+00:00","visits_left":5,"stores":null}]
        """#.utf8))
        #expect(campaigns.first?.visits.map(\.code) == ["A1B2C3"])
        #expect(campaigns.first?.storeList.count == 2)
        #expect(campaigns.last?.storeList.isEmpty == true)  // every store in a danger zone

        let refused = try Backend.decoder.decode(CheckIn.self, from: Data(#"{"ok":false,"distance_m":960,"error":"Get within 75 m of Store: Jefferson & Hoover to check in."}"#.utf8))
        #expect(!refused.ok && refused.code == nil && refused.error?.contains("75 m") == true)
        let ok = try Backend.decoder.decode(CheckIn.self, from: Data(#"{"ok":true,"already":false,"code":"A1B2C3","offer":"Free small slushie","title":"Slushie Sweep","store":"Store: Jefferson & Hoover","bonus_points":50}"#.utf8))
        #expect(ok.code == "A1B2C3" && ok.bonusPoints == 50)
    }

    @Test func sponsoredBonusHistoryLabel() throws {
        let entry = try Backend.decoder.decode(GameState.LedgerEntry.self, from: Data(#"""
        {"amount":50,"kind":"campaign","note":"Sponsored: Slushie Sweep","created_at":"2026-09-26T20:00:00+00:00","settled":false}
        """#.utf8))
        #expect(entry.label == "Sponsored: Slushie Sweep")
    }
}
