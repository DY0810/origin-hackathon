import CoreLocation
import Foundation
import Testing
@testable import FaultLine

/// When the camera re-asks asset-lookup (CLAUDE.md §7.2): after a 15 m move or a 30° turn, not on GPS jitter.
struct AssetLookupTests {
    private let here = CLLocation(latitude: 34.0205, longitude: -118.2856)

    @Test func firstFixAlwaysQueries() {
        #expect(AssetLookup.shouldRequery(from: nil, to: here, heading: nil))
    }

    @Test func smallMoveOrTurnDoesNot() {
        let nearby = CLLocation(latitude: 34.0206, longitude: -118.2856)  // ~11 m north
        #expect(!AssetLookup.shouldRequery(from: (here, 90), to: nearby, heading: 110))
        #expect(!AssetLookup.shouldRequery(from: (here, 90), to: here, heading: nil))
    }

    @Test func bigMoveQueries() {
        let away = CLLocation(latitude: 34.0207, longitude: -118.2856)  // ~22 m north
        #expect(AssetLookup.shouldRequery(from: (here, 90), to: away, heading: 90))
    }

    @Test func turnQueriesAcrossNorth() {
        #expect(AssetLookup.shouldRequery(from: (here, 90), to: here, heading: 125))
        #expect(!AssetLookup.shouldRequery(from: (here, 350), to: here, heading: 10))   // 20° through north
        #expect(AssetLookup.shouldRequery(from: (here, 340), to: here, heading: 20))    // 40° through north
        #expect(AssetLookup.shouldRequery(from: (here, nil), to: here, heading: 0))     // compass just came up
    }

    @Test func decodesLookupResponse() throws {
        let json = #"""
        {"primary":{"kind":"building","name":"Bovard Administration Building","osm_id":"way/406923885","distance_m":10},
         "candidates":[{"kind":"building","name":"Bovard Administration Building","osm_id":"way/406923885","distance_m":10},
                       {"kind":"sidewalk","name":"Childs Way","osm_id":"way/727170375","distance_m":3}],
         "address":null,"multiplier":2}
        """#
        let match = try Backend.decoder.decode(AssetLookup.Match.self, from: Data(json.utf8))
        #expect(match.primary?.osmId == "way/406923885")
        #expect(match.candidates.count == 2)
        #expect(match.multiplier == 2)
        #expect(match.reason == nil)
    }
}
