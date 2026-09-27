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

/// One H3 cell, priced by supabase/functions/_shared/surge.ts: the same multiplier verify-report pays.
struct HeatCell: Decodable, Identifiable, Hashable {
    let h3: String
    let multiplier: Double
    let bountyId: UUID
    let boundary: [[Double]] // [lat, lng]
    private let surge: Bool?  // true if any bounty covering the cell is a surge
    let name: String?         // the bounty that sets its price; absent from older map-data deploys
    private let why: [String]?  // "Figueroa corridor: 3×", "Needs coverage (never reported): +50%"

    var isSurge: Bool { surge ?? false }
    var reasons: [String] { why ?? [] }
    var id: String { h3 }
    var coordinates: [CLLocationCoordinate2D] { boundary.map { .init(latitude: $0[0], longitude: $0[1]) } }
    func contains(_ point: CLLocationCoordinate2D) -> Bool { ringContains(coordinates, point) }
}

/// Even-odd ray cast; planar lat/lng is fine at city scale.
func ringContains(_ ring: [CLLocationCoordinate2D], _ point: CLLocationCoordinate2D) -> Bool {
    var inside = false
    for (a, b) in zip(ring, ring.suffix(1) + ring.dropLast()) where (a.latitude > point.latitude) != (b.latitude > point.latitude) {
        let crossLng = a.longitude + (point.latitude - a.latitude) * (b.longitude - a.longitude) / (b.latitude - a.latitude)
        if point.longitude < crossLng { inside.toggle() }
    }
    return inside
}

/// A participating store in a sponsored campaign (supabase/migrations/*_campaigns.sql, CLAUDE.md §9.1).
struct CampaignStop: Decodable, Identifiable, Hashable {
    let id: UUID            // store id (the check-in target)
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

/// Active danger zone (CLAUDE.md §6.8): no points, multipliers or quests inside.
struct DangerZone: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let boundary: [[Double]] // [lat, lng], outer ring

    var coordinates: [CLLocationCoordinate2D] { boundary.map { .init(latitude: $0[0], longitude: $0[1]) } }
    /// North edge, off the pins inside.
    var labelCoordinate: CLLocationCoordinate2D {
        .init(latitude: coordinates.map(\.latitude).max() ?? center.latitude, longitude: center.longitude)
    }
    var center: CLLocationCoordinate2D {
        let points = coordinates
        return .init(latitude: points.map(\.latitude).reduce(0, +) / Double(max(points.count, 1)),
                     longitude: points.map(\.longitude).reduce(0, +) / Double(max(points.count, 1)))
    }

    func contains(_ point: CLLocationCoordinate2D) -> Bool { ringContains(coordinates, point) }
}

struct MapSnapshot: Decodable, Equatable {
    var reports: [MapReport] = []
    var bounties: [MapBounty] = []
    var cells: [HeatCell] = []
    var dangerZones: [DangerZone]? = nil  // absent from older map-data deploys
    var stops: [CampaignStop]? = nil      // sponsored stores; absent before campaigns were deployed

    var dangers: [DangerZone] { dangerZones ?? [] }
    var sponsoredStops: [CampaignStop] { stops ?? [] }
    func inDanger(_ point: CLLocationCoordinate2D?) -> Bool { point.map { p in dangers.contains { $0.contains(p) } } ?? false }
    /// The priced cell under a coordinate (tap a hex to see why it's worth what it's worth).
    func cell(at point: CLLocationCoordinate2D) -> HeatCell? { cells.first { $0.contains(point) } }
}

/// Damage pins bucketed on a world-anchored grid about 1/8 of the screen wide (MASTER.md §6 MapPin "Clusters show a count").
/// Area labels that fit without overlapping: danger zones always, then surges, then higher multipliers; a label that would
/// cover one already placed is dropped (its heat still shows).
enum AreaLabels {
    // ponytail: label sizes estimated for a phone-size map (~400×800 pt); use MapReader's projection if iPad matters.
    static let viewport = CGSize(width: 400, height: 800)

    static func bounties(_ bounties: [MapBounty], dangers: [DangerZone], region: MKCoordinateRegion, showsNames: Bool) -> [MapBounty] {
        var placed = dangers.map { box(at: $0.labelCoordinate, width: textWidth($0.name), region: region) }
        let ranked = bounties.sorted { ($0.isSurge ? 1 : 0, $0.multiplier) > ($1.isSurge ? 1 : 0, $1.multiplier) }
        return ranked.filter { bounty in
            let rect = box(at: bounty.coordinate, width: showsNames ? textWidth(bounty.name) + 44 : 56, region: region)
            guard !placed.contains(where: { $0.intersects(rect) }) else { return false }
            placed.append(rect)
            return true
        }
    }

    private static func textWidth(_ text: String) -> CGFloat { min(40 + 8 * CGFloat(text.count), 300) }

    /// Label rect in degrees, anchored bottom-center at the coordinate (lng on x, lat on y).
    private static func box(at c: CLLocationCoordinate2D, width: CGFloat, region: MKCoordinateRegion) -> CGRect {
        let w = region.span.longitudeDelta * width / viewport.width, h = region.span.latitudeDelta * 40 / viewport.height
        return CGRect(x: c.longitude - w / 2, y: c.latitude, width: w, height: h)
    }
}

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
