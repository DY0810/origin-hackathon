import CoreML
import UIKit
import Vision

/// The server taxonomy (DAMAGE_TYPES in supabase/functions/verify-report). The first six are the everyday picks;
/// the on-device model can suggest those and never `modelHidden` (ml/README.md "App guidance").
enum DamageType: String, CaseIterable, Identifiable {
    case crack, spalling, efflorescence, exposedRebar = "exposed_rebar", corrosion, pothole
    case leakage, detachment, bulge
    case leaningOrDamagedPole = "leaning_or_damaged_pole", brokenSignOrLight = "broken_sign_or_light"
    case debrisOnAsset = "debris_on_asset", fireDamage = "fire_damage", structuralCollapse = "structural_collapse", other

    /// Model outputs that don't generalize yet (v4 AP: leakage .07, detachment .09, bulge from ~3 buildings).
    /// Users can still pick them; the model just never suggests them.
    static let modelHidden: Set<DamageType> = [.leakage, .detachment, .bulge]
    static let common: [DamageType] = [.crack, .spalling, .efflorescence, .exposedRebar, .corrosion, .pothole]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .crack: "Crack"
        case .spalling: "Spalling"
        case .efflorescence: "Efflorescence"
        case .exposedRebar: "Exposed rebar"
        case .corrosion: "Corrosion"
        case .pothole: "Pothole"
        case .leakage: "Leak"
        case .detachment: "Detachment"
        case .bulge: "Bulge"
        case .leaningOrDamagedPole: "Damaged pole"
        case .brokenSignOrLight: "Sign or light"
        case .debrisOnAsset: "Debris"
        case .fireDamage: "Fire damage"
        case .structuralCollapse: "Collapse"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .crack: "bolt"
        case .spalling: "square.dashed"
        case .efflorescence: "snowflake"
        case .exposedRebar: "line.3.horizontal"
        case .corrosion: "drop.halffull"
        case .pothole: "road.lanes"
        case .leakage: "drop"
        case .detachment: "square.stack.3d.down.right"
        case .bulge: "oval"
        case .leaningOrDamagedPole: "antenna.radiowaves.left.and.right"
        case .brokenSignOrLight: "lightbulb.slash"
        case .debrisOnAsset: "tree"
        case .fireDamage: "flame"
        case .structuralCollapse: "building.2"
        case .other: "questionmark.circle"
        }
    }
}

struct DamageFinding: Hashable {
    let type: DamageType
    let probability: Float
}

/// Runs FaultLineDamage.mlpackage (v4, EfficientNet-B0, 384 px, sigmoid outputs listed in labels.json).
/// Results are *preliminary*; the server model is the authority (design-system/MASTER.md §7.2).
actor DamageClassifier {
    /// v4's val-tuned thresholds for crack (0.05) and corrosion (0.10) flag almost everything on real photos.
    // ponytail: flat floor; replace with thresholds tuned on our own photo test set once it exists.
    static let minThreshold: Float = 0.5

    private let request: VNCoreMLRequest
    private let outputs: [String]
    private let thresholds: [String: Float]

    private struct Labels: Decodable {
        let outputs: [String]
        let thresholds: [String: Float]
    }

    init() throws {
        let model = try VNCoreMLModel(for: FaultLineDamage(configuration: MLModelConfiguration()).model)
        request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop  // matches training eval: resize + center crop
        guard let url = Bundle.main.url(forResource: "labels", withExtension: "json") else { throw CocoaError(.fileNoSuchFile) }
        let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: url))
        outputs = labels.outputs
        thresholds = labels.thresholds
    }

    /// `offTopic`: Apple's scene classifier sees no infrastructure. v4 never saw such photos in training and calls a
    /// waterfall corrosion (0.71) and a leaf crack (0.91), so off-topic photos get no findings at all.
    func classify(_ image: UIImage) throws -> (findings: [DamageFinding], offTopic: Bool) {
        guard let cgImage = image.cgImage else { return ([], false) }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        try VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([request])
        // Fail open: no gate, not no suggestions. The simulator always lands here (no GPU context for the scene model,
        // and its CPU fallback calls a waterfall "night_sky"), so verify the gate on a device.
        let scene = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: cgImage, orientation: orientation).perform([scene])
        let labels = Dictionary((scene.results ?? []).map { ($0.identifier, $0.confidence) }, uniquingKeysWith: max)
        if Self.isOffTopic(labels) { return ([], true) }
        guard let probs = (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue else { return ([], false) }
        return (Self.findings(probabilities: (0..<probs.count).map { probs[$0].floatValue }, outputs: outputs, thresholds: thresholds), false)
    }

    static let infraLabels: Set<String> = ["structure", "path", "road", "road_other", "road_safety_equipment", "street", "sidewalk",
                                           "parking_lot", "building", "house_single", "skyscraper", "cityscape", "bridge", "tunnel",
                                           "brick", "fence", "pole", "sign", "street_sign", "pipe", "stairs", "door", "window"]
    static let offTopicLabels: Set<String> = ["waterfall", "water_body", "ocean", "beach", "mountain", "forest", "tree", "plant",
                                              "foliage", "flower", "sky", "animal", "cat", "dog", "food", "people", "document", "screenshot"]

    /// Off-topic = a confident non-infrastructure scene and no infrastructure label. "grass" isn't off-topic: road cracks score 0.65.
    // ponytail: thresholds from 16 photos (road cracks score structure/path 0.32–0.38, a stained wall 0.21); retune on the own-photo test set.
    static func isOffTopic(_ labels: [String: Float]) -> Bool {
        let infra = infraLabels.compactMap { labels[$0] }.max() ?? 0
        let offTopic = offTopicLabels.compactMap { labels[$0] }.max() ?? 0
        return infra < 0.2 && offTopic >= 0.5
    }

    /// Suggested damage types, most confident first. Unknown/hidden outputs are ignored.
    static func findings(probabilities: [Float], outputs: [String], thresholds: [String: Float]) -> [DamageFinding] {
        zip(outputs, probabilities)
            .compactMap { name, p in
                guard let type = DamageType(rawValue: name), !DamageType.modelHidden.contains(type), p >= max(thresholds[name] ?? 0.5, minThreshold) else { return nil }
                return DamageFinding(type: type, probability: p)
            }
            .sorted { $0.probability > $1.probability }
    }

    /// Preliminary severity from which defects co-occur (ml/README.md "Severity"). Never returns .hazard;
    /// severity 5 only comes from the server or human review.
    static func preliminarySeverity(_ findings: [DamageFinding]) -> Severity? {
        let p = Dictionary(findings.map { ($0.type, $0.probability) }, uniquingKeysWith: max)
        if p[.exposedRebar] != nil || (p[.spalling] != nil && p[.corrosion] != nil) { return .urgent }
        if p[.spalling] != nil || p[.pothole] != nil || (p[.crack] ?? 0) >= 0.8 { return .schedule }
        if p[.crack] != nil || p[.corrosion] != nil { return .monitor }
        if p[.efflorescence] != nil { return .cosmetic }
        return nil
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
