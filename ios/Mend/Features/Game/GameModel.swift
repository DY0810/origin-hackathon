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
    // Optional: absent until 20260926030000_rewards.sql is deployed, and the rest of the app must keep working.
    let minRedeem: Int?
    let catalog: [Reward]?
    let redemptions: [Redemption]?
    // Rate card for "How points work" (20260927000000_surge_pricing_rewards.sql); optional for older deploys.
    let severityPoints: [Int]?
    let pointsPerDollar: Int?

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
        let surge: Bool?
    }

    /// Catalog item (CLAUDE.md §6.6): a mocked gift card, a donation, or a merchant-funded partner offer. Priced in settled points.
    struct Reward: Decodable, Identifiable, Equatable {
        let sku: String
        let name: String
        let points: Int
        var kind: String? = nil     // gift_card | partner_offer | donation; nil from an older server = gift card
        var partner: String? = nil  // "Partner café"
        var detail: String? = nil
        var id: String { sku }

        /// Merchant-funded (the CRED model): cheaper in points, and the gift-card minimum doesn't apply.
        var isPartnerOffer: Bool { kind == "partner_offer" }
        var symbol: String {
            switch kind {
            case "partner_offer": "storefront.fill"
            case "donation": "heart.fill"
            default: "giftcard.fill"
            }
        }
    }

    struct Redemption: Decodable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let points: Int
        let code: String
        let createdAt: Date
    }

    /// Points still needed before `reward` can be redeemed (0 = affordable). Pending points never count.
    func shortfall(for reward: Reward) -> Int {
        max(0, max(reward.points, reward.isPartnerOffer ? 0 : minRedeem ?? 0) - pointsSettled)  // same rule as redeem()
    }

    /// Active, unfinished surge quests, as a stable string for "last seen" storage.
    var surgeQuestKey: String {
        quests.filter { $0.surge == true && !$0.completed }.map(\.id.uuidString).sorted().joined(separator: ",")
    }

    /// Tab badge dots (MASTER.md §5): Quests for a surge quest not seen yet, Rewards for newly settled points.
    func hasNewSurge(seen: String) -> Bool {
        !Set(surgeQuestKey.split(separator: ",")).isSubset(of: Set(seen.split(separator: ",")))
    }

    func hasNewSettledPoints(seen: Int) -> Bool { pointsSettled > seen }

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
            return kind == "quest" ? "Quest: \(text)" : text.prefix(1).uppercased() + text.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }
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
    private let stores: [Store]?  // null when every store sits in a danger zone

    var storeList: [Store] { stores ?? [] }
    /// Stores where the player already checked in (one code each).
    var visits: [Store] { storeList.filter { $0.code != nil } }
    func store(_ id: UUID) -> Store? { storeList.first { $0.id == id } }

    struct Store: Decodable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let lat: Double
        let lng: Double
        let qualified: Bool      // the player has a counted report within radiusM
        let code: String?        // set once checked in
        let checkedInAt: Date?
        let redeemedAt: Date?
    }
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
    private(set) var campaigns: [SponsoredCampaign] = []

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

    struct RedeemResult: Decodable, Equatable {
        let code: String
        let sku: String
        let points: Int
        let balance: Int
    }

    /// Server-side error with a message meant for the player (redeem raises FL001/P0002 with plain copy).
    struct RedeemError: LocalizedError {
        let errorDescription: String?
    }

    /// Spends settled points on a catalog item (`redeem()` SQL function), then refreshes balances.
    func redeem(_ reward: GameState.Reward) async throws -> RedeemResult {
        let offline = "Couldn't redeem right now. Check your connection and try again."
        let data: Data, response: HTTPURLResponse?
        do { (data, response) = try await Backend.data(for: Backend.rpc("redeem", body: ["p_sku": reward.sku])) }
        catch { throw RedeemError(errorDescription: offline) }
        await load()
        guard response?.statusCode == 200 else {
            struct Body: Decodable { let code: String?; let message: String? }
            let body = try? Backend.decoder.decode(Body.self, from: data)
            let friendly = ["FL001", "P0002"].contains(body?.code ?? "") ? body?.message : nil
            throw RedeemError(errorDescription: friendly ?? offline)
        }
        return try Backend.decoder.decode(RedeemResult.self, from: data)
    }
}
