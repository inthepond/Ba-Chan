import Vision
import CoreGraphics

/// What Stackchan understood from a single camera frame.
struct Sighting {
    /// A short natural-language description, e.g. "a cup, a laptop; a face looking at me".
    var summary: String
    var faceCount: Int
    var topLabels: [String]
    var recognizedText: [String]

    var isEmpty: Bool { summary.isEmpty }
}

/// The always-available "sight" using Apple's on-device **Vision** framework —
/// scene/object classification, text (OCR), and face detection. Free, private,
/// runs on iOS 18, and turns a frame into a text summary that any text brain can
/// use. (For a richer, free-form description, a multimodal VLM brain can look at
/// the raw frame instead — see `VisionBrain`.)
enum SightService {
    static func analyze(_ image: CGImage) async -> Sighting {
        await Task.detached(priority: .userInitiated) {
            perform(image)
        }.value
    }

    private static func perform(_ image: CGImage) -> Sighting {
        let classify = VNClassifyImageRequest()
        let recognizeText = VNRecognizeTextRequest()
        recognizeText.recognitionLevel = .fast
        recognizeText.usesLanguageCorrection = true
        let detectFaces = VNDetectFaceRectanglesRequest()

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([classify, recognizeText, detectFaces])

        // Top object/scene labels. A low floor keeps it responsive to whatever
        // the camera is pointed at (classification confidences run low).
        let labels = (classify.results ?? [])
            .filter { $0.confidence > 0.12 }
            .prefix(4)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }

        let faceCount = detectFaces.results?.count ?? 0

        let text = (recognizeText.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { $0.count >= 2 }
            .prefix(3)
            .map { String($0) }

        // Assemble a friendly summary.
        var parts: [String] = []
        if !labels.isEmpty { parts.append(labels.joined(separator: ", ")) }
        switch faceCount {
        case 1: parts.append("a face looking at me")
        case 2...: parts.append("\(faceCount) faces")
        default: break
        }
        if !text.isEmpty { parts.append("text that says \u{201C}\(text.joined(separator: " "))\u{201D}") }

        return Sighting(summary: parts.joined(separator: "; "),
                        faceCount: faceCount,
                        topLabels: Array(labels),
                        recognizedText: Array(text))
    }
}
