import UIKit

/// Server verdict from supabase/functions/verify-report (Claude vision). Authoritative over on-device suggestions.
struct Verification: Decodable, Equatable {
    let reportId: UUID
    let status: String          // accepted | review | rejected
    let isDamage: Bool
    let damageTypes: [String]
    let primaryType: String?
    let severity: Int?
    let confidence: Double
    let explanation: String
    let retakeTip: String?
    let immediateDanger: Bool
    let pointsPending: Int
    // Rewards (award_report). Optional so a verdict still decodes if rewards are missing.
    let basePoints: Int?
    let multiplier: Double?
    let xp: Int?
    let levelBefore: Int?
    let levelAfter: Int?
    let questsCompleted: [QuestReward]?
    var asset: Asset? = nil     // echoed back as stored
    var inDanger: Bool? = nil   // taken inside an active danger zone: nothing paid (CLAUDE.md §6.8)
    var firstFinder: Bool? = nil  // false = confirmation of a known defect (CLAUDE.md §6.5); nil from an older server

    struct QuestReward: Decodable, Equatable, Hashable {
        let title: String
        let rewardPoints: Int
        let rewardXp: Int
    }

    var leveledUp: Bool { (levelAfter ?? 0) > (levelBefore ?? 0) }

    var reportStatus: ReportStatus {
        switch status {
        case "accepted": .accepted
        case "rejected": .rejected
        default: .review
        }
    }

    var severityLevel: Severity? { severity.flatMap(Severity.init(rawValue:)) }

    /// "exposed_rebar" -> "Exposed rebar"; known types use their chip label ("leaning_or_damaged_pole" -> "Damaged pole").
    static func label(_ type: String) -> String {
        if let known = DamageType(rawValue: type) { return known.label }
        let words = type.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

struct VerificationError: LocalizedError {
    let message: String
    var status: Int? = nil       // HTTP status when the server answered
    var offline = false          // never reached the server: the Outbox keeps the report
    var errorDescription: String? { message }
}

enum ReportService {
    private struct Payload: Encodable {
        let imageBase64: String
        let source: String
        let suggestedTypes: [String]
        let note: String
        let latitude: Double?
        let longitude: Double?
        let accuracyM: Double?
        let heading: Double?
        let capturedAt: Date?
        let asset: Asset?
        let clientId: UUID  // idempotency key: a resend of this body never files or pays twice
    }

    private struct ServerError: Decodable { let error: String }

    static func verify(image: UIImage, photo: CapturedPhoto?, suggested: [DamageType], note: String, asset: Asset? = nil,
                       clientId: UUID = UUID()) async throws -> Verification {
        try await send(body(image: image, photo: photo, suggested: suggested, note: note, asset: asset, clientId: clientId))
    }

    /// The exact verify-report request body (JPEG inside). The Outbox stores this as-is.
    static func body(image: UIImage, photo: CapturedPhoto?, suggested: [DamageType], note: String, asset: Asset? = nil,
                     clientId: UUID = UUID()) throws -> Data {
        guard let jpeg = downscaled(image).jpegData(compressionQuality: 0.8) else {
            throw VerificationError(message: "Couldn't encode the photo.")
        }
        let location = photo?.location
        let payload = Payload(
            imageBase64: jpeg.base64EncodedString(),
            source: photo == nil || photo?.fromLibrary == true ? "library" : "camera",
            suggestedTypes: suggested.map(\.rawValue),
            note: note,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            accuracyM: location?.horizontalAccuracy,
            heading: photo?.heading,
            capturedAt: photo?.capturedAt,
            asset: asset,
            clientId: clientId
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func send(_ body: Data) async throws -> Verification {
        var request: URLRequest
        do {
            request = try await Backend.playerRequest("verify-report", timeout: 90)
        } catch {
            throw VerificationError(message: "Couldn't sign you in. Check your connection and try again.", offline: isOffline(error))
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: HTTPURLResponse?
        do {
            (data, response) = try await Backend.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw VerificationError(message: "Mend took too long to answer. Try again.", offline: true)
        } catch {
            throw VerificationError(message: "No connection to Mend. Check your signal and try again.", offline: isOffline(error))
        }
        let decoder = Backend.decoder
        guard response?.statusCode == 200 else {
            let message = (try? decoder.decode(ServerError.self, from: data))?.error ?? "The server couldn't check this report."
            throw VerificationError(message: message, status: response?.statusCode)
        }
        return try decoder.decode(Verification.self, from: data)
    }

    /// Connectivity failures (worth queueing and retrying), as opposed to the server saying no.
    // A timeout can hide a report the server already filed; resending is safe because client_id makes verify-report
    // return the stored verdict instead of filing (and paying) it again.
    nonisolated static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive,
                .secureConnectionFailed].contains(error.code)
    }

    /// Longest side 1568 px: Claude's recommended max, and keeps uploads ~300-600 KB.
    static func downscaled(_ image: UIImage, maxSide: CGFloat = 1568) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
