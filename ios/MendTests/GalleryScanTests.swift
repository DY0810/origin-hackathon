import CoreGraphics
import Foundation
import Testing
@testable import Mend

struct GalleryScanTests {
    static let crack = DamageFinding(type: .crack, probability: 0.8)
    static let pothole = DetectedIssue(type: .pothole, confidence: 0.6, box: .zero)

    @Test func candidatesPassTheSceneGateAndHaveAFinding() {
        #expect(DamageClassifier.looksLikeDamage(findings: [Self.crack], issues: [], offTopic: false))
        #expect(DamageClassifier.looksLikeDamage(findings: [], issues: [Self.pothole], offTopic: false))
        #expect(!DamageClassifier.looksLikeDamage(findings: [], issues: [], offTopic: false))
        #expect(!DamageClassifier.looksLikeDamage(findings: [Self.crack], issues: [Self.pothole], offTopic: true))
    }

    @Test func historicalMeansOlderThanSixMonths() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(GalleryScanModel.isHistorical(now.addingTimeInterval(-200 * 86_400), now: now))
        #expect(!GalleryScanModel.isHistorical(now.addingTimeInterval(-30 * 86_400), now: now))
        #expect(!GalleryScanModel.isHistorical(nil, now: now))
    }

    @Test func titleNamesAtMostTwoTypes() {
        #expect(GalleryScanModel.title([.crack]) == "Possible crack")
        #expect(GalleryScanModel.title([.crack, .pothole, .spalling]) == "Possible crack + pothole")
    }
}
