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

/// One H3 cell priced by supabase/functions/_shared/surge.ts: the same multiplier verify-report pays.
struct HeatCell: Decodable, Identifiable, Hashable {
    let h3: String
    let multiplier: Double    // 0 inside a danger core
    var danger = false        // evacuation / fire / flood core of a surge: no points, capture paused
    var surge = false         // a surge bounty (CLAUDE.md §6.8) covers it
    var bountyId: UUID?
    var name: String?
    var why: [String] = []    // "Figueroa corridor: 3×", "Needs coverage (never reported): +50%"
    let boundary: [[Double]]  // [lat, lng]

    var id: String { h3 }
    var coordinates: [CLLocationCoordinate2D] { boundary.map { .init(latitude: $0[0], longitude: $0[1]) } }

    private enum CodingKeys: String, CodingKey { case h3, multiplier, danger, surge, bountyId, name, why, boundary }

    init(h3: String, multiplier: Double, danger: Bool = false, surge: Bool = false, bountyId: UUID? = nil,
         name: String? = nil, why: [String] = [], boundary: [[Double]]) {
        self.h3 = h3; self.multiplier = multiplier; self.danger = danger; self.surge = surge
        self.bountyId = bountyId; self.name = name; self.why = why; self.boundary = boundary
    }

    /// Tolerates older map-data deploys (no danger / surge / why).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        h3 = try c.decode(String.self, forKey: .h3)
        multiplier = try c.decode(Double.self, forKey: .multiplier)
        danger = try c.decodeIfPresent(Bool.self, forKey: .danger) ?? false
        surge = try c.decodeIfPresent(Bool.self, forKey: .surge) ?? false
        bountyId = try c.decodeIfPresent(UUID.self, forKey: .bountyId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        why = try c.decodeIfPresent([String].self, forKey: .why) ?? []
        boundary = try c.decode([[Double]].self, forKey: .boundary)
    }

    /// Ray casting in lat/lng; plenty accurate at city-block scale.
    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        var inside = false
        var j = boundary.count - 1
        for i in boundary.indices {
            let (latI, lngI, latJ, lngJ) = (boundary[i][0], boundary[i][1], boundary[j][0], boundary[j][1])
            if (latI > point.latitude) != (latJ > point.latitude),
               point.longitude < (lngJ - lngI) * (point.latitude - latI) / (latJ - latI) + lngI {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// A participating store in a sponsored campaign (supabase/migrations/*_campaigns.sql, CLAUDE.md §9.1).
struct CampaignStop: Decodable, Identifiable, Hashable {
    let id: UUID            // store id (check-in target)
    let campaignId: UUID
    let name: String
    let title: String       // "Slushie Sweep"
    let sponsor: String
    let offer: String       // "Free small slushie"
    let bonusPoints: Int
    let radiusM: Int
    let lat: Double
    let lng: Double

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
}

struct MapSnapshot: Decodable, Equatable {
    var reports: [MapReport] = []
    var bounties: [MapBounty] = []
    var cells: [HeatCell] = []
    var stops: [CampaignStop] = []

    /// The priced cell under a coordinate, if it's inside a bounty, surge or danger core.
    func cell(at coordinate: CLLocationCoordinate2D) -> HeatCell? {
        cells.first { $0.contains(coordinate) }
    }
}

extension MapSnapshot {
    private enum CodingKeys: String, CodingKey { case reports, bounties, cells, stops }

    /// `stops` is optional so the app still reads a map-data deployed before campaigns existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reports = try c.decode([MapReport].self, forKey: .reports)
        bounties = try c.decode([MapBounty].self, forKey: .bounties)
        cells = try c.decode([HeatCell].self, forKey: .cells)
        stops = try c.decodeIfPresent([CampaignStop].self, forKey: .stops) ?? []
    }
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
