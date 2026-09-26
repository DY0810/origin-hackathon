import CoreGraphics
import Testing
@testable import FaultLine

struct DamageDetectorTests {
    @Test func flipsVisionBoxesAndDropsWeakHiddenOrUnknownClasses() {
        let raw: [(String, Float, CGRect)] = [
            ("crack", 0.9, CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.3)),   // Vision: origin bottom-left
            ("pothole", 0.2, CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)), // below threshold
            ("bulge", 0.9, CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),       // hidden by detector_labels.json
            ("manhole", 0.9, CGRect(x: 0, y: 0, width: 0.1, height: 0.1)),     // not a damage type
        ]
        let issues = DamageDetector.issues(raw, thresholds: ["pothole": 0.35], hidden: ["bulge"])
        #expect(issues.map(\.type) == [.crack])
        let box = issues[0].box
        #expect(abs(box.minY - 0.1) < 1e-9 && abs(box.height - 0.3) < 1e-9 && box.minX == 0.1)
    }

    @Test func summaryCountsRepeats() {
        let box = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let issues = [DetectedIssue(type: .crack, confidence: 0.9, box: box), DetectedIssue(type: .crack, confidence: 0.8, box: box),
                      DetectedIssue(type: .pothole, confidence: 0.7, box: box)]
        #expect(IssueBoxes.summary(issues) == "3 issues found: Crack ×2, Pothole")
    }
}
