import Testing
@testable import FaultLine

struct DamageClassifierTests {
    static let outputs = ["crack", "spalling", "efflorescence", "exposed_rebar", "corrosion", "pothole",
                          "leakage", "detachment", "bulge", "mat_concrete"]

    @Test func findingsFloorThresholdsAndDropHiddenOutputs() {
        let probs: [Float] = [0.7, 0.3, 0.1, 0.1, 0.45, 0.1, 0.99, 0.99, 0.99, 0.99]
        // corrosion's tuned 0.1 is floored to 0.5, so 0.45 doesn't count; leakage/detachment/bulge/material are never surfaced.
        let found = DamageClassifier.findings(probabilities: probs, outputs: Self.outputs, thresholds: ["crack": 0.05, "corrosion": 0.1])
        #expect(found.map(\.type) == [.crack])
    }

    // Real VNClassifyImageRequest scores from the simulator's sample photos and our report photos.
    @Test(arguments: [
        (["waterfall": 0.88, "sky": 0.52], true),                                  // IMG_0005: v4 said corrosion 0.71
        (["plant": 0.89, "foliage": 0.86], true),                                  // leaf: v4 said crack 0.91
        (["waterfall": 0.72, "structure": 0.47], false),                           // waterfall next to a structure
        (["grass": 0.65, "structure": 0.36, "path": 0.32], false),                 // road crack report
        (["animal": 0.39, "structure": 0.21], false),                              // stained wall report
    ] as [([String: Float], Bool)])
    func sceneGate(labels: [String: Float], offTopic: Bool) {
        #expect(DamageClassifier.isOffTopic(labels) == offTopic)
    }

    @Test func labelsPreferChipNamesAndFallBackForUnknownTypes() {
        #expect(Verification.label("leaning_or_damaged_pole") == "Damaged pole")
        #expect(Verification.label("exposed_rebar") == "Exposed rebar")
        #expect(Verification.label("new_server_type") == "New server type")
    }

    @Test func findingsAreSortedByConfidence() {
        let probs: [Float] = [0.6, 0.9, 0, 0, 0, 0.75, 0, 0, 0, 0]
        let found = DamageClassifier.findings(probabilities: probs, outputs: Self.outputs, thresholds: [:])
        #expect(found.map(\.type) == [.spalling, .pothole, .crack])
    }

    @Test(arguments: [
        ([], nil),
        ([DamageFinding(type: .efflorescence, probability: 0.9)], Severity.cosmetic),
        ([DamageFinding(type: .crack, probability: 0.6)], .monitor),
        ([DamageFinding(type: .crack, probability: 0.85)], .schedule),
        ([DamageFinding(type: .pothole, probability: 0.7)], .schedule),
        ([DamageFinding(type: .spalling, probability: 0.7), DamageFinding(type: .corrosion, probability: 0.7)], .urgent),
        ([DamageFinding(type: .exposedRebar, probability: 0.6), DamageFinding(type: .efflorescence, probability: 0.9)], .urgent),
    ] as [([DamageFinding], Severity?)])
    func preliminarySeverity(findings: [DamageFinding], expected: Severity?) {
        #expect(DamageClassifier.preliminarySeverity(findings) == expected)
    }
}
