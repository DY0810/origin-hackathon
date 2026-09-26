import UserNotifications

/// One of the player's reports that a buyer marked fixed (`my_fixes()`, supabase/migrations/*_fixes.sql).
struct FixedReport: Decodable, Identifiable, Equatable {
    let id: UUID
    let primaryType: String?
    let fixedAt: Date
    let fixedNote: String?
}

/// "Your report got fixed": a local notification the first time the app sees each fix.
// ponytail: checked when the app is open (RootView polls); real APNs push needs an Apple team + device tokens.
@MainActor
enum FixNotifier {
    static let seenKey = "notifiedFixIDs"

    static func newlyFixed(_ fixes: [FixedReport], seen: Set<String>) -> [FixedReport] {
        fixes.filter { !seen.contains($0.id.uuidString) }
    }

    /// Returns how many new fixes it announced.
    @discardableResult
    static func check() async -> Int {
        guard let (data, response) = try? await Backend.data(for: Backend.rpc("my_fixes")), response?.statusCode == 200,
              let fixes = try? Backend.decoder.decode([FixedReport].self, from: data) else { return 0 }
        let defaults = UserDefaults.standard
        let seen = Set(defaults.stringArray(forKey: seenKey) ?? [])
        let new = newlyFixed(fixes, seen: seen)
        for fix in new {
            let content = UNMutableNotificationContent()
            let type = fix.primaryType.map(Verification.label) ?? "Damage"
            content.title = "Fixed: \(type)"
            content.body = "The \(type.lowercased()) you reported was repaired. +25 points."
                + (fix.fixedNote.map { " Crew note: \($0)" } ?? "")
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fix-\(fix.id)", content: content, trigger: nil))
        }
        if !new.isEmpty { defaults.set(Array(seen.union(new.map(\.id.uuidString))), forKey: seenKey) }
        return new.count
    }

    /// Asked right after a report is accepted, when "we'll tell you when it's fixed" makes sense.
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}

/// Shows fix notifications as banners even while FaultLine is open.
final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundNotifications()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
