import CoreML
import UIKit
import Vision

/// One localized issue in the photo. `box` is normalized to the upright image, origin top-left (SwiftUI space).
struct DetectedIssue: Hashable {
    let type: DamageType
    let confidence: Float
    let box: CGRect
}

/// Runs FaultLineDetector.mlpackage (YOLO with NMS, ml/detector/train_detector.py): a box per issue, so one photo
/// can show several cracks and a pothole. Optional: without the model in the bundle, `init` throws and capture skips it.
/// Preliminary like the classifier; the server verdict is the authority.
actor DamageDetector {
    private let request: VNCoreMLRequest
    private let thresholds: [String: Float]
    private let hidden: Set<String>

    private struct Labels: Decodable {
        let thresholds: [String: Float]
        let hidden: [String]?  // classes whose test AP says they don't work yet (ml/README.md)
    }

    init() throws {
        guard let model = Bundle.main.url(forResource: "FaultLineDetector", withExtension: "mlmodelc"),
              let labels = Bundle.main.url(forResource: "detector_labels", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        request = VNCoreMLRequest(model: try VNCoreMLModel(for: MLModel(contentsOf: model)))
        request.imageCropAndScaleOption = .scaleFill
        let decoded = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: labels))
        thresholds = decoded.thresholds
        hidden = Set(decoded.hidden ?? [])
    }

    func detect(_ image: UIImage) throws -> [DetectedIssue] {
        guard let cgImage = image.cgImage else { return [] }
        try VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation)).perform([request])
        let raw = (request.results as? [VNRecognizedObjectObservation] ?? []).compactMap { o in
            o.labels.first.map { ($0.identifier, $0.confidence, o.boundingBox) }
        }
        return Self.issues(raw, thresholds: thresholds, hidden: hidden)
    }

    /// Vision boxes (normalized, origin bottom-left) -> issues above threshold, origin top-left, most confident first.
    static func issues(_ raw: [(String, Float, CGRect)], thresholds: [String: Float], hidden: Set<String>) -> [DetectedIssue] {
        raw.compactMap { name, confidence, box in
            guard let type = DamageType(rawValue: name), !hidden.contains(name), confidence >= (thresholds[name] ?? 0.35) else { return nil }
            return DetectedIssue(type: type, confidence: confidence,
                                 box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
        .sorted { $0.confidence > $1.confidence }
    }
}
