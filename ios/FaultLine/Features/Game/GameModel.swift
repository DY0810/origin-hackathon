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
}
