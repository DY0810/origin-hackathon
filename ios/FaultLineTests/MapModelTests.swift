import Foundation
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
        #expect(snapshot.cells.first?.surge == true)
        #expect(snapshot.cells.first?.coordinates.count == 3)
        #expect(snapshot.cells.first?.coordinates.first?.latitude == 34.0176)
        #expect(snapshot.cells.first?.danger == false)  // older map-data: no danger / why / stops
        #expect(snapshot.stops.isEmpty)
    }

    @Test func decodesSurgePricedCellsAndSponsoredStops() throws {
        let json = #"""
        {"reports":[],
         "bounties":[{"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","name":"Storm sweep","multiplier":5,"surge":true,"label_lat":34.04,"label_lng":-118.23}],
         "cells":[{"h3":"8929a1d6457ffff","multiplier":4.5,"danger":false,"surge":true,"bounty_id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e",
           "name":"Storm sweep","why":["Storm sweep (surge): 3×","Needs coverage (never reported): +50%"],
           "boundary":[[34.0,-118.0],[34.0,-117.99],[34.01,-117.99],[34.01,-118.0]]},
          {"h3":"8929a1d645bffff","multiplier":0,"danger":true,"surge":true,"bounty_id":null,"name":null,
           "why":["Danger area"],"boundary":[[35.0,-118.0],[35.0,-117.99],[35.01,-117.99]]}],
         "stops":[{"id":"0b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","campaign_id":"1b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e",
           "name":"Store: Jefferson & Hoover","title":"Slushie Sweep","sponsor":"Demo: Convenience chain","offer":"Free small slushie",
           "bonus_points":50,"radius_m":300,"lat":34.0214,"lng":-118.2862}]}
        """#
        let snapshot = try Backend.decoder.decode(MapSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.bounties.first?.isSurge == true)
        #expect(snapshot.cells.first?.why.count == 2)
        #expect(snapshot.cells.last?.danger == true)
        #expect(snapshot.cell(at: .init(latitude: 34.005, longitude: -117.995))?.multiplier == 4.5)
        #expect(snapshot.cell(at: .init(latitude: 34.02, longitude: -117.995)) == nil)
        #expect(snapshot.stops.first?.offer == "Free small slushie")
        #expect(snapshot.stops.first?.radiusM == 300)
    }

    @Test func hexHitTest() {
        // Regular hexagon around (34, -118), ~0.001° across.
        let ring = (0..<6).map { i -> [Double] in
            let a = Double(i) * .pi / 3
            return [34 + 0.001 * sin(a), -118 + 0.001 * cos(a)]
        }
        let cell = HeatCell(h3: "x", multiplier: 2, boundary: ring)
        #expect(cell.contains(.init(latitude: 34, longitude: -118)))
        #expect(cell.contains(.init(latitude: 34.0005, longitude: -118.0003)))
        #expect(!cell.contains(.init(latitude: 34.002, longitude: -118)))
    }
}
