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

    @Test func decodesCatalogAndRedemption() throws {
        let catalog = try Backend.decoder.decode(RewardsCatalog.self, from: Data(#"""
        {"items":[{"sku":"partner-coffee","title":"Free coffee","detail":"Any size drip coffee.","kind":"partner_offer",
                   "cost_points":150,"partner":"Partner café"},
                  {"sku":"gift-5","title":"$5 gift card","detail":"100+ brands.","kind":"gift_card","cost_points":500,"partner":null}],
         "severity_points":[10,20,30,50,80],"points_per_dollar":100}
        """#.utf8))
        #expect(catalog.items.map(\.symbol) == ["storefront.fill", "giftcard.fill"])
        #expect(catalog.severityPoints[3] == 50)

        let refused = try Backend.decoder.decode(Redemption.self, from: Data(#"{"ok":false,"balance":20,"error":"You need 480 more settled points for this."}"#.utf8))
        #expect(!refused.ok && refused.code == nil)
        let sent = try Backend.decoder.decode(Redemption.self, from: Data(#"{"ok":true,"code":"FL-1A2B3C4D","title":"$5 gift card","cost_points":500,"balance":100}"#.utf8))
        #expect(sent.code == "FL-1A2B3C4D" && sent.balance == 100)
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
        #expect(campaigns.last?.storeList.isEmpty == true)  // every store in a danger core

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

    @Test func redemptionHistoryLabel() throws {
        let entry = try Backend.decoder.decode(GameState.LedgerEntry.self, from: Data(#"""
        {"amount":-500,"kind":"redeem","note":"$5 gift card","created_at":"2026-09-26T20:00:00+00:00","settled":true}
        """#.utf8))
        #expect(entry.label == "Redeemed: $5 gift card")
    }
}
