import Foundation
import MapKit
import Testing
@testable import FaultLine

struct MapModelTests {
    @Test(arguments: [(1.0, 0.12), (1.5, 0.22), (2.0, 0.34), (3.0, 0.46), (5.0, 0.58)])
    func heatBandsMatchDesignSystem(multiplier: Double, opacity: Double) {
        #expect(HeatStyle.opacity(for: multiplier) == opacity)
    }

    @Test func decodesMapDataResponse() throws {
        let json = #"""
        {"reports":[{"id":"107544cb-4b60-44d7-a811-235c949d1fe0","lat":34.0205,"lng":-118.2856,"severity":2,
          "primary_type":"exposed_rebar","status":"accepted","created_at":"2026-09-25T21:59:45.156785+00:00","fixed_at":null},
          {"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","lat":34.02,"lng":-118.28,"severity":3,"primary_type":"pothole",
           "status":"accepted","created_at":"2026-09-25T21:59:45+00:00","fixed_at":"2026-09-26T01:00:00+00:00"}],
         "bounties":[{"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","name":"Figueroa corridor","multiplier":3,"label_lat":34.045,"label_lng":-118.273}],
         "cells":[{"h3":"8929a1d6457ffff","multiplier":1.5,"bounty_id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","surge":true,
           "boundary":[[34.0176,-118.2842],[34.0193,-118.2831],[34.0200,-118.2850]]}]}
        """#
        let snapshot = try Backend.decoder.decode(MapSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.reports.first?.typeLabel == "Exposed rebar")
        #expect(snapshot.reports.first?.severityLevel == .monitor)
        #expect(snapshot.reports.map { $0.fixedAt != nil } == [false, true])
        #expect(snapshot.bounties.first?.multiplier == 3)
        #expect(snapshot.bounties.first?.isSurge == false)  // older map-data: no surge key
        #expect(snapshot.cells.first?.isSurge == true)
        #expect(snapshot.cells.first?.coordinates.count == 3)
        #expect(snapshot.cells.first?.coordinates.first?.latitude == 34.0176)
    }

    // Unit square-ish zone, closed ring like GeoJSON; an L-shape checks the concave case.
    static let zone = DangerZone(id: UUID(), name: "Fire perimeter",
                                 boundary: [[34.0, -118.3], [34.0, -118.2], [34.02, -118.2], [34.02, -118.25], [34.04, -118.25], [34.04, -118.3], [34.0, -118.3]])

    @Test(arguments: [(34.01, -118.25, true), (34.03, -118.28, true), (34.03, -118.22, false), (34.05, -118.28, false), (33.99, -118.25, false)])
    func dangerZonePointInPolygon(lat: Double, lng: Double, inside: Bool) {
        #expect(Self.zone.contains(.init(latitude: lat, longitude: lng)) == inside)
    }

    @Test func snapshotInDangerAndOlderDeploys() throws {
        var snapshot = try Backend.decoder.decode(MapSnapshot.self, from: Data(#"{"reports":[],"bounties":[],"cells":[]}"#.utf8))
        #expect(snapshot.dangers.isEmpty)  // no danger_zones key: nothing is dangerous
        #expect(snapshot.inDanger(CLLocationCoordinate2D(latitude: 34.01, longitude: -118.25)) == false)
        snapshot = try Backend.decoder.decode(MapSnapshot.self, from: Data(#"""
        {"reports":[],"bounties":[],"cells":[],"danger_zones":[{"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","name":"Fire","boundary":[[34.0,-118.3],[34.0,-118.2],[34.02,-118.2],[34.0,-118.3]]}]}
        """#.utf8))
        #expect(snapshot.inDanger(CLLocationCoordinate2D(latitude: 34.005, longitude: -118.22)))
        #expect(snapshot.inDanger(nil) == false)
    }

    static func report(_ lat: Double, _ lng: Double, severity: Int, fixed: Bool = false) -> MapReport {
        MapReport(id: UUID(), lat: lat, lng: lng, severity: severity, primaryType: nil, status: "accepted", createdAt: .now,
                  fixedAt: fixed ? .now : nil)
    }

    @Test func pinsClusterWhenZoomedOutAndSplitWhenZoomedIn() {
        let reports = [Self.report(34.0201, -118.2851, severity: 2), Self.report(34.0202, -118.2852, severity: 4),
                       Self.report(34.0203, -118.2853, severity: 5, fixed: true), Self.report(34.05, -118.20, severity: 1)]
        let city = MKCoordinateRegion(center: .init(latitude: 34.03, longitude: -118.25), span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
        let clusters = PinCluster.make(reports, region: city).sorted { $0.reports.count > $1.reports.count }
        #expect(clusters.map(\.reports.count) == [3, 1])
        #expect(clusters[0].topSeverity == .urgent)  // the fixed 5 doesn't color the cluster
        let street = MKCoordinateRegion(center: .init(latitude: 34.0202, longitude: -118.2852), span: .init(latitudeDelta: 0.002, longitudeDelta: 0.002))
        #expect(PinCluster.make(reports, region: street).count == 4)
    }
}

/// Overlapping area labels: danger wins, then surge, then the higher multiplier; far-apart labels all stay.
struct AreaLabelsTests {
    private let region = MKCoordinateRegion(center: .init(latitude: 34.02, longitude: -118.28),
                                            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05))

    private func bounty(_ name: String, _ mult: Double, lat: Double, lng: Double, surge: Bool = false) throws -> MapBounty {
        try Backend.decoder.decode(MapBounty.self, from: Data(#"""
            {"id":"\#(UUID().uuidString)","name":"\#(name)","multiplier":\#(mult),"label_lat":\#(lat),"label_lng":\#(lng),"surge":\#(surge)}
            """#.utf8))
    }

    @Test func dropsLowerPriorityOverlaps() throws {
        let campus = try bounty("Campus", 1.5, lat: 34.020, lng: -118.285)
        let storm = try bounty("Zone B", 5, lat: 34.0202, lng: -118.2852, surge: true)
        let far = try bounty("Far", 2, lat: 34.040, lng: -118.265)
        let shown = AreaLabels.bounties([campus, storm, far], dangers: [], region: region, showsNames: true).map(\.name)
        #expect(Set(shown) == ["Zone B", "Far"])
    }

    @Test func dangerLabelBeatsBounty() throws {
        let zone = try Backend.decoder.decode(DangerZone.self, from: Data(#"""
            {"id":"\#(UUID().uuidString)","name":"Gas leak","boundary":[[34.019,-118.286],[34.020,-118.286],[34.020,-118.284],[34.019,-118.284]]}
            """#.utf8))
        let campus = try bounty("Campus", 1.5, lat: 34.0201, lng: -118.2851)
        #expect(AreaLabels.bounties([campus], dangers: [zone], region: region, showsNames: false).isEmpty)
    }
}
