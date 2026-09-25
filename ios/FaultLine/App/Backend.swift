import Foundation

/// Supabase project `faultline` (supabase/). The anon key is public by design: it only gets past `verify_jwt`;
/// the Edge Functions hold the secrets and use the service role.
enum Backend {
    static let functionsURL = URL(string: "https://kiygfzzdaqabrggjnrmf.supabase.co/functions/v1/")!
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtpeWdmenpkYXFhYnJnZ2pucm1mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAzNjAyMDIsImV4cCI6MjEwNTkzNjIwMn0.iDKLYnqrAm3DETJIm-ZjJUx6Si4b1H5Vrz71ddsQNkQ"

    static func request(_ function: String, query: [URLQueryItem] = [], timeout: TimeInterval = 30) -> URLRequest {
        var url = functionsURL.appending(path: function)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Fresh connection per call: calls are often minutes apart, and a pooled HTTP/3 connection that sat idle
    /// ~2.5 min was silently dropped server-side, so the next request hung until timeout (URLError -1001, 0 bytes sent).
    static func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return (data, response as? HTTPURLResponse)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return decoder
    }()
}
