import Foundation
import Testing
@testable import Mend

@MainActor
struct FixNotifierTests {
    @Test func decodesMyFixesAndSkipsAlreadyNotified() throws {
        let json = #"""
        [{"id":"107544cb-4b60-44d7-a811-235c949d1fe0","primary_type":"pothole","fixed_at":"2026-09-26T01:02:03.456+00:00","fixed_note":"Patched"},
         {"id":"8b1c2c55-9a0e-4b7a-9d7e-1f2a3b4c5d6e","primary_type":null,"fixed_at":"2026-09-25T01:02:03+00:00","fixed_note":null}]
        """#
        let fixes = try Backend.decoder.decode([FixedReport].self, from: Data(json.utf8))
        let new = FixNotifier.newlyFixed(fixes, seen: ["8B1C2C55-9A0E-4B7A-9D7E-1F2A3B4C5D6E"])
        #expect(new.map(\.fixedNote) == ["Patched"])
    }
}
