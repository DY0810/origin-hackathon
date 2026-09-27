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

    /// Mocked gift card (CLAUDE.md §6.6). Priced in settled points.
    struct Reward: Decodable, Identifiable, Equatable {
        let sku: String
        let name: String
        let points: Int
        var id: String { sku }
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
        max(0, max(reward.points, minRedeem ?? 0) - pointsSettled)
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

@MainActor @Observable
final class GameModel {
    private(set) var state: GameState?
    private(set) var loadFailed = false

    func load() async {
        do {
            let (data, response) = try await Backend.data(for: Backend.rpc("game_state"))
            guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
            state = try Backend.decoder.decode(GameState.self, from: data)
            loadFailed = false
        } catch {
            loadFailed = true
        }
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
