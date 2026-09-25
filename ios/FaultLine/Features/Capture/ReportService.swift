import UIKit

/// Supabase project `faultline`. The anon key is public by design (it only gets through `verify_jwt`);
/// the function holds the secrets and writes with the service role.
enum Backend {
    static let verifyURL = URL(string: "https://kiygfzzdaqabrggjnrmf.supabase.co/functions/v1/verify-report")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtpeWdmenpkYXFhYnJnZ2pucm1mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAzNjAyMDIsImV4cCI6MjEwNTkzNjIwMn0.iDKLYnqrAm3DETJIm-ZjJUx6Si4b1H5Vrz71ddsQNkQ"
}

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

    var reportStatus: ReportStatus {
        switch status {
        case "accepted": .accepted
        case "rejected": .rejected
        default: .review
        }
    }

    var severityLevel: Severity? { severity.flatMap(Severity.init(rawValue:)) }

    /// "exposed_rebar" -> "Exposed rebar"
    static func label(_ type: String) -> String {
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

        var request = URLRequest(url: Backend.verifyURL, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(Backend.anonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw VerificationError(message: "No connection to FaultLine. Check your signal and try again.")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
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
