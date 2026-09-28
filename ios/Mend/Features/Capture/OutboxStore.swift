import Foundation
import Network
import UserNotifications

/// Reports captured with no connection (MASTER.md §7.1 step 5: "Never lose a capture"). Each one is the exact
/// verify-report body (JPEG inside) in Application Support/Outbox, sent oldest-first when the app comes to the
/// foreground or the network comes back. Deleted on success, a definitive 4xx, or 5xx for over a week; kept otherwise.
/// Each body carries its client_id, so a resend after a lost response never files or pays twice.
@MainActor @Observable
final class OutboxStore {
    static let shared = OutboxStore(directory: URL.applicationSupportDirectory.appending(path: "Outbox"))
    static let limit = 50                         // ~25 MB of photos
    static let maxServerErrorAge: TimeInterval = 7 * 24 * 3600

    private(set) var count = 0
    private let directory: URL
    private var isSending = false
    @ObservationIgnored private var monitor: NWPathMonitor?

    init(directory: URL) {
        self.directory = directory
        count = pending().count
    }

    /// Timestamped names sort oldest-first.
    func add(_ body: Data, at date: Date = .now) throws {
        guard pending().count < Self.limit else {
            throw VerificationError(message: "\(Self.limit) reports are already waiting to send. Get online to send them first.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true  // photos waiting to upload, not user data worth an iCloud backup
        try? dir.setResourceValues(values)
        let name = String(format: "%015.0f-", date.timeIntervalSince1970 * 1000) + UUID().uuidString + ".json"
        try body.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        count = pending().count
    }

    func pending() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// When a file was queued, from its name.
    nonisolated static func queuedAt(_ file: URL) -> Date? {
        file.lastPathComponent.split(separator: "-").first.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        count = pending().count
    }

    /// Sends queued reports one at a time; stops at the first one that can't get through. Returns what got verified.
    @discardableResult
    func flush(now: Date = .now, send: (Data) async throws -> Verification = ReportService.send) async -> [Verification] {
        guard !isSending else { return [] }
        isSending = true
        defer { isSending = false }
        var sent: [Verification] = []
        for file in pending() {
            guard let body = try? Data(contentsOf: file) else { continue }  // maybe locked right now; keep it
            do {
                let result = try await send(body)
                remove(file)
                sent.append(result)
                await Self.notify(result.reportId.uuidString, Self.message(result))
            } catch let error as VerificationError where Self.isDefinitive(error.status)
                        || ((error.status ?? 0) >= 500 && now.timeIntervalSince(Self.queuedAt(file) ?? now) > Self.maxServerErrorAge) {
                // The server said no, or has kept failing on this one for a week: retrying won't help.
                remove(file)
                await Self.notify(file.lastPathComponent, "Your report from earlier couldn't be sent.")
            } catch {
                break  // offline or server trouble: keep it, try again later
            }
        }
        return sent
    }

    /// 4xx means the request itself is bad. Not 401 (sign-in hiccup), 408 or 429 (try later).
    nonisolated static func isDefinitive(_ status: Int?) -> Bool {
        guard let status else { return false }
        return (400..<500).contains(status) && ![401, 408, 429].contains(status)
    }

    /// Retries whenever the network comes back. RootView also flushes once per foreground.
    func startMonitoring(onSent: @escaping @MainActor ([Verification]) -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                guard let sent = await self?.flush() else { return }
                if !sent.isEmpty { onSent(sent) }
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    /// Posted only if the player allowed notifications (asked on the ResultSheet); silently dropped otherwise.
    private static func notify(_ id: String, _ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Report from earlier"
        content.body = body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "outbox-\(id)", content: content, trigger: nil))
    }

    private static func message(_ result: Verification) -> String {
        switch result.reportStatus {
        case .rejected: "Your report from earlier wasn't counted as damage."
        case .accepted where result.pointsPending > 0: "Your report from earlier was verified: +\(result.pointsPending) points."
        case .accepted: "Your report from earlier was verified."
        default: "A reviewer will confirm your report from earlier."
        }
    }
}
