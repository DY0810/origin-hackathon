import Foundation
import Security

/// The player's identity: a Supabase anonymous account per install (no signup screen). The refresh token lives in
/// the Keychain so points survive relaunches; the access token (1 h) is kept in memory and refreshed as needed.
// ponytail: deleting the app loses the identity; add "link an email/Apple ID" before real payouts.
actor PlayerSession {
    static let shared = PlayerSession()

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var inFlight: Task<String, Error>?
    private var generation = 0   // bumped by reset(), so a sign-in already in flight can't write the old player back

    /// A valid access token, signing in on first use.
    func token() async throws -> String {
        if let accessToken, expiresAt > .now.addingTimeInterval(60) { return accessToken }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await refreshOrSignIn() }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }  // not a newer one started after reset()
        return try await task.value
    }

    /// "Reset demo player" (Profile > Settings): forget this player; the next call signs up a fresh anonymous one.
    // ponytail: the old anonymous user stays in auth.users; purge orphans server-side if it ever matters.
    func reset() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        accessToken = nil
        expiresAt = .distantPast
        Keychain.delete("refresh_token")
    }

    private func refreshOrSignIn() async throws -> String {
        let started = generation
        if let refresh = Keychain.read("refresh_token"),
           let token = try? await exchange("token?grant_type=refresh_token", body: ["refresh_token": refresh], generation: started) {
            return token
        }
        return try await exchange("signup", body: [:], generation: started) // new anonymous player
    }

    private struct AuthResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
    }

    private func exchange(_ path: String, body: [String: String], generation started: Int) async throws -> String {
        guard started == generation else { throw CancellationError() }
        var request = URLRequest(url: URL(string: Backend.projectURL.absoluteString + "/auth/v1/" + path)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Backend.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await Backend.data(for: request)
        guard response?.statusCode == 200 else { throw URLError(.userAuthenticationRequired) }
        let auth = try Backend.decoder.decode(AuthResponse.self, from: data)
        guard started == generation else { throw CancellationError() }  // reset() ran while this was on the wire
        Keychain.write("refresh_token", auth.refreshToken)
        accessToken = auth.accessToken
        expiresAt = .now.addingTimeInterval(auth.expiresIn)
        return auth.accessToken
    }
}

/// Minimal Keychain storage for one-string secrets, this device only.
enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "faultline", kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }

    static func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query(key) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var q = query(key)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}
