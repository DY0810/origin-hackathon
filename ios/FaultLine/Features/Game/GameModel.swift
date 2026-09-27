import Foundation

/// Player state from the `game_state()` SQL function (supabase/migrations/*_game.sql). Server is the source of truth;
/// balances come from the append-only ledger.
struct GameState: Decodable, Equatable {
    let handle: String
    let xp: Int
    let level: Int
    let title: String
    let levelStartXp: Int
    let nextLevelXp: Int
    let pointsSettled: Int
    let pointsPending: Int
    let quests: [Quest]
    let leaderboard: [LeaderboardEntry]
    let history: [LedgerEntry]

    /// 0...1 progress through the current level.
    var levelProgress: Double {
        Double(xp - levelStartXp) / Double(max(1, nextLevelXp - levelStartXp))
    }

    struct Quest: Decodable, Identifiable, Equatable {
        let id: UUID
        let title: String
        let description: String
        let target: Int
        let progress: Int
        let completed: Bool
        let rewardPoints: Int
        let rewardXp: Int
        let endsAt: Date?
        let multiplier: Double?
        let areaName: String?
    }

    struct LeaderboardEntry: Decodable, Identifiable, Equatable {
        let rank: Int
        let handle: String
        let points: Int
        let isMe: Bool
        var id: String { handle }
    }

    struct LedgerEntry: Decodable, Identifiable, Equatable {
        let amount: Int
        let kind: String
        let note: String?
        let createdAt: Date
        let settled: Bool
        var id: String { "\(createdAt.timeIntervalSince1970)-\(kind)-\(amount)-\(note ?? "")" }

        /// "crack · 3× zone" -> "Crack · 3× zone"; quests show their title.
        var label: String {
            let text = note ?? kind
            switch kind {
            case "quest": return "Quest: \(text)"
            case "redeem": return "Redeemed: \(text)"
            default: return text.prefix(1).uppercased() + text.dropFirst().replacingOccurrences(of: "_", with: " ")
            }
        }
    }
}

/// `rewards_catalog()` (supabase/migrations/*_surge_pricing_rewards.sql): what points buy, plus the rate card.
struct RewardsCatalog: Decodable, Equatable {
    let items: [Item]
    let severityPoints: [Int]  // base points for severity 1…5
    let pointsPerDollar: Int

    struct Item: Decodable, Identifiable, Equatable, Hashable {
        let sku: String
        let title: String
        let detail: String
        let kind: String  // partner_offer (merchant-funded) | gift_card | donation
        let costPoints: Int
        let partner: String?
        var id: String { sku }

        var symbol: String {
            switch kind {
            case "partner_offer": "storefront.fill"
            case "donation": "heart.fill"
            default: "giftcard.fill"
            }
        }
    }
}

/// `redeem_reward()`: ok with a (mock) code, or not ok with a reason. Balance is settled points after the call.
struct Redemption: Decodable, Equatable {
    let ok: Bool
    let balance: Int
    var code: String?
    var title: String?
    var error: String?
}

/// A live sponsored campaign from `campaign_state()` (supabase/migrations/*_campaigns.sql, CLAUDE.md §9.1):
/// report a real issue near a participating store, check in there, show the code at the till.
struct SponsoredCampaign: Decodable, Identifiable, Equatable {
    let id: UUID
    let sponsor: String
    let title: String
    let offer: String
    let detail: String?
    let bonusPoints: Int
    let radiusM: Int
    let endsAt: Date
    let visitsLeft: Int
    private let stores: [Store]?  // null when every store sits in a danger core

    var storeList: [Store] { stores ?? [] }
    /// Codes the player has earned in this campaign (one per store).
    var visits: [Store] { storeList.filter { $0.code != nil } }

    struct Store: Decodable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let lat: Double
        let lng: Double
        let qualified: Bool      // the player has a verified report within radiusM
        let code: String?        // set once checked in
        let checkedInAt: Date?
        let redeemedAt: Date?
    }

    func store(_ id: UUID) -> Store? { storeList.first { $0.id == id } }
}

/// `campaign_check_in()`: ok with the offer code (and bonus points the first time), or a reason to fix.
struct CheckIn: Decodable, Equatable {
    let ok: Bool
    var already: Bool?
    var code: String?
    var offer: String?
    var store: String?
    var bonusPoints: Int?
    var error: String?
}

@MainActor @Observable
final class GameModel {
    private(set) var state: GameState?
    private(set) var loadFailed = false
    private(set) var catalog: RewardsCatalog?
    private(set) var campaigns: [SponsoredCampaign] = []

    func campaign(_ id: UUID) -> SponsoredCampaign? { campaigns.first { $0.id == id } }

    func loadCampaigns() async {
        do {
            let (data, response) = try await Backend.data(for: Backend.rpc("campaign_state"))
            guard response?.statusCode == 200 else { return }
            campaigns = try Backend.decoder.decode([SponsoredCampaign].self, from: data)
        } catch {
            // Campaigns are extra: keep the last list rather than blanking the Quests tab.
        }
    }

    /// The server checks the 75 m geofence, the nearby report and the campaign's visit cap.
    func checkIn(store: UUID, latitude: Double, longitude: Double) async throws -> CheckIn {
        struct Arguments: Encodable { let p_store: UUID; let p_lat: Double; let p_lng: Double }
        let request = try await Backend.rpc("campaign_check_in", arguments: Arguments(p_store: store, p_lat: latitude, p_lng: longitude))
        let (data, response) = try await Backend.data(for: request)
        guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let result = try Backend.decoder.decode(CheckIn.self, from: data)
        if result.ok { await load() }
        return result
    }

    func loadCatalog() async {
        do {
            let (data, response) = try await Backend.data(for: Backend.rpc("rewards_catalog"))
            guard response?.statusCode == 200 else { return }
            catalog = try Backend.decoder.decode(RewardsCatalog.self, from: data)
        } catch {
            // The Rewards tab still shows balance and history without the catalog.
        }
    }

    /// The server checks the settled balance and spends it atomically; then balances and history refresh.
    func redeem(_ item: RewardsCatalog.Item) async throws -> Redemption {
        let (data, response) = try await Backend.data(for: Backend.rpc("redeem_reward", arguments: ["p_sku": item.sku]))
        guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let result = try Backend.decoder.decode(Redemption.self, from: data)
        await load()
        return result
    }

    func load() async {
        do {
            let (data, response) = try await Backend.data(for: Backend.rpc("game_state"))
            guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
            state = try Backend.decoder.decode(GameState.self, from: data)
            loadFailed = false
        } catch {
            loadFailed = true
        }
        await loadCampaigns()  // qualification changes as reports land, so it refreshes with the rest
    }
}
