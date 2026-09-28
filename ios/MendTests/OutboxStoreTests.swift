import Foundation
import Testing
import UIKit
@testable import Mend

@MainActor
struct OutboxStoreTests {
    private func tempStore() -> OutboxStore {
        OutboxStore(directory: FileManager.default.temporaryDirectory.appending(path: "outbox-\(UUID().uuidString)"))
    }

    private func verification(_ id: UUID = UUID()) -> Verification {
        Verification(reportId: id, status: "accepted", isDamage: true, damageTypes: ["crack"], primaryType: "crack", severity: 2,
                     confidence: 0.9, explanation: "", retakeTip: nil, immediateDanger: false, pointsPending: 25, basePoints: 25,
                     multiplier: 1, xp: 20, levelBefore: 1, levelAfter: 1, questsCompleted: [])
    }

    @Test func connectivityErrorsQueueServerErrorsDont() {
        #expect(ReportService.isOffline(URLError(.notConnectedToInternet)))
        #expect(ReportService.isOffline(URLError(.networkConnectionLost)))
        #expect(ReportService.isOffline(URLError(.timedOut)))
        #expect(ReportService.isOffline(URLError(.cannotFindHost)))
        #expect(!ReportService.isOffline(URLError(.userAuthenticationRequired)))
        #expect(!ReportService.isOffline(VerificationError(message: "Bad", status: 500)))
        #expect(OutboxStore.isDefinitive(400) && OutboxStore.isDefinitive(413))
        #expect(!OutboxStore.isDefinitive(401) && !OutboxStore.isDefinitive(429) && !OutboxStore.isDefinitive(500) && !OutboxStore.isDefinitive(nil))
    }

    /// A real URLSession failure (nothing listens on port 9) is classified as offline, so the capture gets queued.
    @Test func unreachableServerCountsAsOffline() async {
        do {
            _ = try await Backend.data(for: URLRequest(url: URL(string: "https://127.0.0.1:9/verify-report")!, timeoutInterval: 5))
            Issue.record("expected a connection failure")
        } catch {
            #expect(ReportService.isOffline(error))
        }
    }

    @Test func decodesFirstFinderAndToleratesOldServer() throws {
        let base = #"{"report_id":"107544cb-4b60-44d7-a811-235c949d1fe0","status":"accepted","is_damage":true,"damage_types":["crack"],"primary_type":"crack","severity":2,"confidence":0.9,"explanation":"","retake_tip":null,"immediate_danger":false,"points_pending":10"#
        #expect(try Backend.decoder.decode(Verification.self, from: Data((base + #","first_finder":false}"#).utf8)).firstFinder == false)
        #expect(try Backend.decoder.decode(Verification.self, from: Data((base + "}").utf8)).firstFinder == nil)
    }

    @Test func persistsOldestFirstAcrossInstances() throws {
        let store = tempStore()
        try store.add(Data("second".utf8), at: Date(timeIntervalSince1970: 2_000))
        try store.add(Data("first".utf8), at: Date(timeIntervalSince1970: 1_000))
        try store.add(Data("third".utf8), at: Date(timeIntervalSince1970: 30_000))
        #expect(store.count == 3)
        let reopened = OutboxStore(directory: store.pending()[0].deletingLastPathComponent())
        #expect(reopened.count == 3)
        #expect(try reopened.pending().map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["first", "second", "third"])
    }

    @Test func flushSendsInOrderDropsRejectsAndStopsWhenOffline() async throws {
        let store = tempStore()
        for (i, name) in ["ok", "bad", "offline", "later"].enumerated() {
            try store.add(Data(name.utf8), at: Date(timeIntervalSince1970: Double(i)))
        }
        var tried: [String] = []
        let sent = await store.flush { body in
            let name = String(decoding: body, as: UTF8.self)
            tried.append(name)
            switch name {
            case "ok": return verification()
            case "bad": throw VerificationError(message: "Bad", status: 400)
            default: throw VerificationError(message: "Offline", offline: true)
            }
        }
        #expect(tried == ["ok", "bad", "offline"])
        #expect(sent.count == 1)
        #expect(try store.pending().map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["offline", "later"])
        #expect(store.count == 2)
    }

    @Test func bodyCarriesTheSameClientIdOnRebuild() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        let id = UUID()
        let json = { try JSONSerialization.jsonObject(with: ReportService.body(image: image, photo: nil, suggested: [.crack], note: "", clientId: id)) as? [String: Any] }
        #expect(try json()?["client_id"] as? String == id.uuidString)
        let fresh = try JSONSerialization.jsonObject(with: ReportService.body(image: image, photo: nil, suggested: [], note: "")) as? [String: Any]
        #expect(fresh?["client_id"] as? String != id.uuidString)
    }

    @Test func dropsWeekOldServerErrorsKeepsFreshOnesAndCaps() async throws {
        let store = tempStore()
        let now = Date(timeIntervalSince1970: 10_000_000)
        try store.add(Data("stale".utf8), at: now.addingTimeInterval(-8 * 24 * 3600))
        try store.add(Data("fresh".utf8), at: now.addingTimeInterval(-3600))
        #expect(OutboxStore.queuedAt(store.pending()[0]).map { Int($0.timeIntervalSince1970) } == Int(now.timeIntervalSince1970) - 8 * 24 * 3600)
        _ = await store.flush(now: now) { _ in throw VerificationError(message: "Down", status: 503) }
        #expect(try store.pending().map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["fresh"])
        for i in 1..<OutboxStore.limit { try store.add(Data(), at: now.addingTimeInterval(Double(i))) }
        #expect(throws: VerificationError.self) { try store.add(Data()) }
    }
}
