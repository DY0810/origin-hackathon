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
        #expect(snapshot.cells.first?.isSurge == true)
        #expect(snapshot.cells.first?.coordinates.count == 3)
        #expect(snapshot.cells.first?.coordinates.first?.latitude == 34.0176)
    }
}
