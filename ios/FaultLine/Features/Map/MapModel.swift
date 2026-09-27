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

/// Active danger zone (CLAUDE.md §6.8): no points, multipliers or quests inside.
struct DangerZone: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let boundary: [[Double]] // [lat, lng], outer ring

    var coordinates: [CLLocationCoordinate2D] { boundary.map { .init(latitude: $0[0], longitude: $0[1]) } }
    var center: CLLocationCoordinate2D {
        let points = coordinates
        return .init(latitude: points.map(\.latitude).reduce(0, +) / Double(max(points.count, 1)),
                     longitude: points.map(\.longitude).reduce(0, +) / Double(max(points.count, 1)))
    }

    /// Even-odd ray cast; planar lat/lng is fine at city scale.
    func contains(_ point: CLLocationCoordinate2D) -> Bool {
        let ring = coordinates
        var inside = false
        for (a, b) in zip(ring, ring.suffix(1) + ring.dropLast()) where (a.latitude > point.latitude) != (b.latitude > point.latitude) {
            let crossLng = a.longitude + (point.latitude - a.latitude) * (b.longitude - a.longitude) / (b.latitude - a.latitude)
            if point.longitude < crossLng { inside.toggle() }
        }
        return inside
    }
}

struct MapSnapshot: Decodable, Equatable {
    var reports: [MapReport] = []
    var bounties: [MapBounty] = []
    var cells: [HeatCell] = []
    var dangerZones: [DangerZone]? = nil  // absent from older map-data deploys

    var dangers: [DangerZone] { dangerZones ?? [] }
    func inDanger(_ point: CLLocationCoordinate2D?) -> Bool { point.map { p in dangers.contains { $0.contains(p) } } ?? false }
}

/// Damage pins bucketed on a world-anchored grid about 1/8 of the screen wide (MASTER.md §6 MapPin "Clusters show a count").
struct PinCluster: Identifiable {
    let id: String
    let reports: [MapReport]

    var coordinate: CLLocationCoordinate2D {
        .init(latitude: reports.map(\.lat).reduce(0, +) / Double(reports.count),
              longitude: reports.map(\.lng).reduce(0, +) / Double(reports.count))
    }
    /// Highest open severity; nil when every report in it is fixed.
    var topSeverity: Severity? { reports.filter { $0.fixedAt == nil }.compactMap(\.severityLevel).max() }

    static func make(_ reports: [MapReport], region: MKCoordinateRegion, columns: Double = 8) -> [PinCluster] {
        // Steps snap to powers of two so small zooms and pans keep the same grid (and the same groups).
        let snap = { (degrees: Double) in pow(2, floor(log2(degrees))) }
        let lngStep = snap(region.span.longitudeDelta / columns)
        guard lngStep > 0.0003 else { return reports.map { PinCluster(id: $0.id.uuidString, reports: [$0]) } }  // street level: every pin
        let latStep = snap(lngStep * cos(region.center.latitude * .pi / 180))  // ~square cells on screen
        return Dictionary(grouping: reports) { "\(Int(floor($0.lat / latStep))):\(Int(floor($0.lng / lngStep)))" }
            .map { key, members in PinCluster(id: members.count == 1 ? members[0].id.uuidString : key, reports: members) }
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
    /// The player is inside an active danger zone (MASTER.md §6 SafetyBanner, CaptureButton disabled).
    private(set) var inDanger = false
    @ObservationIgnored var userLocation: CLLocationCoordinate2D? { didSet { updateDanger() } }
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
                updateDanger()
            } catch {
                if !Task.isCancelled { loadFailed = true }
            }
        }
    }

    private func updateDanger() {
        let inside = snapshot.inDanger(userLocation)
        if inside != inDanger { inDanger = inside }  // location ticks every second; only a change re-renders
    }
}
