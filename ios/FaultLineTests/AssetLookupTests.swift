import CoreLocation
import Foundation
import ImageIO
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

    /// Same query asset-lookup used to build server-side (60 m radius, 100 m bbox clip).
    @Test func buildsOverpassQuery() {
        #expect(AssetLookup.overpassQuery(lat: 34.0205, lng: -118.2856) == "[out:json][timeout:8];(way(around:60,34.0205,-118.2856)[building];"
            + "rel(around:60,34.0205,-118.2856)[building];way(around:60,34.0205,-118.2856)[highway];way(around:60,34.0205,-118.2856)[man_made=bridge];"
            + "node(around:60,34.0205,-118.2856)[power=pole];node(around:60,34.0205,-118.2856)[highway=street_lamp];"
            + "node(around:60,34.0205,-118.2856)[man_made][man_made!=surveillance];);out geom(34.019602,-118.286684,34.021398,-118.284516);")
    }

    @Test func readsOverpassElements() {
        let ok = #"{"version":0.6,"elements":[{"type":"node","id":1,"lat":34.02,"lon":-118.28,"tags":{"power":"pole"}}]}"#
        #expect(AssetLookup.overpassElements(Data(ok.utf8))?.count == 1)
        #expect(AssetLookup.overpassElements(Data("<html>rate limited</html>".utf8)) == nil)
        #expect(AssetLookup.overpassElements(Data(#"{"remark":"runtime error"}"#.utf8)) == nil)
    }
}

/// Library picks earn only with GPS in their EXIF (CLAUDE.md §6.3), so the reader must get sign and date right.
struct LibraryExifTests {
    @Test func readsSignedGPSAndDate() throws {
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 34.0205, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 118.2856, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:09:20 14:30:00"],
        ]
        let loc = try #require(CapturedPhoto.location(exif: props))
        #expect(loc.coordinate.latitude == 34.0205)
        #expect(loc.coordinate.longitude == -118.2856)
        #expect(Calendar.current.component(.day, from: loc.timestamp) == 20)
    }

    @Test func noGPSMeansNoLocation() {
        #expect(CapturedPhoto.location(exif: [:]) == nil)
        #expect(CapturedPhoto.location(exif: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0.0, kCGImagePropertyGPSLongitude: 0.0]]) == nil)
    }
}
