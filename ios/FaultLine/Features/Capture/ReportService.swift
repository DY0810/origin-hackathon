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
    let multiplier: Double?     // zone surge; 0 inside a danger area
    var finder: String? = nil   // first | confirmation | repeat
    var zoneName: String? = nil
    var why: [String]? = nil    // itemized receipt: "Severity 4 pothole: 50 pts", "Zone: ×2.5", "First finder: full points"
    let xp: Int?
    let levelBefore: Int?
    let levelAfter: Int?
    let questsCompleted: [QuestReward]?

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
    }

    private struct ServerError: Decodable { let error: String }

    static func verify(image: UIImage, photo: CapturedPhoto?, suggested: [DamageType], note: String) async throws -> Verification {
        guard let jpeg = downscaled(image).jpegData(compressionQuality: 0.8) else {
            throw VerificationError(message: "Couldn't encode the photo.")
        }
        let location = photo?.location
        let payload = Payload(
            imageBase64: jpeg.base64EncodedString(),
            source: photo == nil ? "library" : "camera",
            suggestedTypes: suggested.map(\.rawValue),
            note: note,
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude,
            accuracyM: location?.horizontalAccuracy,
            heading: photo?.heading,
            capturedAt: photo?.capturedAt
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601

        var request: URLRequest
        do {
            request = try await Backend.playerRequest("verify-report", timeout: 90)
        } catch {
            throw VerificationError(message: "Couldn't sign you in. Check your connection and try again.")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let data: Data
        let response: HTTPURLResponse?
        do {
            (data, response) = try await Backend.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw VerificationError(message: "FaultLine took too long to answer. Try again.")
        } catch {
            throw VerificationError(message: "No connection to FaultLine. Check your signal and try again.")
        }
        let decoder = Backend.decoder
        guard response?.statusCode == 200 else {
            let message = (try? decoder.decode(ServerError.self, from: data))?.error ?? "The server couldn't check this report."
            throw VerificationError(message: message)
        }
        return try decoder.decode(Verification.self, from: data)
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
