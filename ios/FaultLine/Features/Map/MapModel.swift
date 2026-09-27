import MapKit
import SwiftUI

// Read model from supabase/functions/map-data.

struct MapReport: Decodable, Identifiable, Hashable {
    let id: UUID
    let lat: Double
    let lng: Double
    let severity: Int?
    let primaryType: String?
    let status: String
    let createdAt: Date
    var fixedAt: Date? = nil

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
    var severityLevel: Severity? { severity.flatMap(Severity.init(rawValue:)) }
    var typeLabel: String { primaryType.map(Verification.label) ?? "Damage" }
}

struct MapBounty: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let multiplier: Double
    let labelLat: Double  // north edge of the bounty area
    let labelLng: Double
    private let surge: Bool?  // disaster surge (CLAUDE.md §6.8); absent from older map-data deploys

    var isSurge: Bool { surge ?? false }
    var coordinate: CLLocationCoordinate2D { .init(latitude: labelLat, longitude: labelLng) }
}

struct HeatCell: Decodable, Identifiable, Hashable {
    let h3: String
    let multiplier: Double
    let bountyId: UUID
    let boundary: [[Double]] // [lat, lng]
    private let surge: Bool?  // true if any bounty covering the cell is a surge

    var isSurge: Bool { surge ?? false }
    var id: String { h3 }
    var coordinates: [CLLocationCoordinate2D] { boundary.map { .init(latitude: $0[0], longitude: $0[1]) } }
}

struct MapSnapshot: Decodable, Equatable {
    var reports: [MapReport] = []
    var bounties: [MapBounty] = []
    var cells: [HeatCell] = []
}

/// MASTER.md §6 MapModeToggle.
enum MapLayer: String, CaseIterable, Identifiable {
    case bounties = "Bounties", damage = "Damage", both = "Both"

    var id: String { rawValue }
    var showsHeat: Bool { self != .damage }
    var showsPins: Bool { self != .bounties }
}

/// MASTER.md §3.1 bounty heat: one gold hue, opacity by multiplier band (1× / 1.5× / 2× / 3× / 5×).
enum HeatStyle {
    static func opacity(for multiplier: Double) -> Double {
        switch multiplier {
        case ..<1.5: 0.12
        case ..<2: 0.22
        case ..<3: 0.34
        case ..<5: 0.46
        default: 0.58
        }
    }
}

@MainActor @Observable
final class MapModel {
    private(set) var snapshot = MapSnapshot()
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var loadTask: Task<Void, Never>?

    /// Loads the visible region plus a 25% margin so small pans don't pop pins in and out.
    func load(region: MKCoordinateRegion) {
        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            defer { if !Task.isCancelled { isLoading = false } }  // a newer load owns the spinner
            let latPad = region.span.latitudeDelta * 0.625, lngPad = region.span.longitudeDelta * 0.625  // half-span × 1.25
            let bbox = [region.center.longitude - lngPad, region.center.latitude - latPad,
                        region.center.longitude + lngPad, region.center.latitude + latPad]
                .map { String(format: "%.5f", $0) }.joined(separator: ",")
            do {
                let (data, response) = try await Backend.data(for: Backend.request("map-data", query: [.init(name: "bbox", value: bbox)]))
                guard !Task.isCancelled else { return }
                guard response?.statusCode == 200 else { throw URLError(.badServerResponse) }
                snapshot = try Backend.decoder.decode(MapSnapshot.self, from: data)
                loadFailed = false
            } catch {
                if !Task.isCancelled { loadFailed = true }
            }
        }
    }
}
