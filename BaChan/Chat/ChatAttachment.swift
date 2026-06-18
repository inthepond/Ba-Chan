import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
#if canImport(PDFKit)
import PDFKit
#endif

/// One file the user feeds into the chat — an image, a video, or a document.
/// Ingestion distills it to text Ba-Chan can hold (`digest`): document text is
/// excerpted, images and sampled video frames go through the same Apple-Vision
/// `SightService` the camera uses. Images also keep the decoded frame so a
/// VLM-capable brain can really look at the picture, not just the cues.
struct ChatAttachment: Identifiable, Equatable {
    enum Kind { case image, video, document }

    let id = UUID()
    let fileName: String
    let kind: Kind
    /// The text essence handed to the brain (excerpt or sight summary).
    var digest: String = ""
    /// Images only: the decoded (downscaled) frame for a VLM look.
    var image: CGImage?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    var icon: String {
        switch kind {
        case .image:    return "photo"
        case .video:    return "film"
        case .document: return "doc.text"
        }
    }

    /// How this attachment reads inside the prompt context.
    var contextLine: String {
        switch kind {
        case .image:    return "A picture called “\(fileName)”. In it you can see: \(digest)"
        case .video:    return "A video called “\(fileName)”. Moments from it show: \(digest)"
        case .document: return "A document called “\(fileName)”. It says: \(digest)"
        }
    }
}

/// Turns a file URL into a `ChatAttachment`, fully on-device. Returns nil only
/// when the file can't be read or yields nothing usable.
enum AttachmentIngestor {
    /// Cap on extracted document text — enough to discuss, small enough for the
    /// lean prompt of a 2–4B model.
    static let textCap = 1200

    static func ingest(url: URL) async -> ChatAttachment? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) {
            return await ingestImage(url: url)
        }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) {
            return await ingestVideo(url: url)
        }
        return ingestDocument(url: url, type: type)
    }

    // MARK: - Images

    private static func ingestImage(url: URL) async -> ChatAttachment? {
        guard let image = decodeImage(url: url) else { return nil }
        return await imageAttachment(image, name: url.lastPathComponent)
    }

    /// Ingest an image from raw bytes — a pasted screenshot or copied web image has
    /// no backing file URL. Same downscale + sight pipeline as a picked image file.
    static func ingest(imageData data: Data, name: String) async -> ChatAttachment? {
        guard let image = decodeImage(data: data) else { return nil }
        return await imageAttachment(image, name: name)
    }

    private static func imageAttachment(_ image: CGImage, name: String) async -> ChatAttachment {
        let summary = await SightService.analyze(image).summary
        return ChatAttachment(fileName: name, kind: .image,
                              digest: summary.isEmpty ? "something hard to make out" : summary,
                              image: image)
    }

    /// Decode downscaled (≤ 1024 px) — plenty for Vision and a VLM, and it keeps
    /// the base64 payload to a local Ollama server small.
    private static let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 1024,
    ] as CFDictionary

    private static func decodeImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    private static func decodeImage(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
    }

    // MARK: - Video (sample a few frames through the same sight pipeline)

    private static func ingestVideo(url: URL) async -> ChatAttachment? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)

        var summaries: [String] = []
        for fraction in [0.15, 0.5, 0.85] {
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            guard let frame = try? await generator.image(at: time).image else { continue }
            let summary = await SightService.analyze(frame).summary
            if !summary.isEmpty, !summaries.contains(summary) { summaries.append(summary) }
        }
        guard !summaries.isEmpty else { return nil }
        return ChatAttachment(fileName: url.lastPathComponent, kind: .video,
                              digest: summaries.joined(separator: "; then "))
    }

    // MARK: - Documents (PDF / anything textual)

    private static func ingestDocument(url: URL, type: UTType) -> ChatAttachment? {
        var text: String?
        #if canImport(PDFKit)
        if type.conforms(to: .pdf) { text = PDFDocument(url: url)?.string }
        #endif
        if text == nil { text = try? String(contentsOf: url, encoding: .utf8) }
        guard var body = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else { return nil }
        if body.count > textCap {
            body = String(body.prefix(textCap)) + "… (it goes on)"
        }
        // Collapse runs of whitespace so a PDF's layout doesn't bloat the prompt.
        body = body.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return ChatAttachment(fileName: url.lastPathComponent, kind: .document, digest: body)
    }

    // MARK: - Encoding for a multimodal HTTP brain (Ollama)

    /// JPEG-encode a frame as base64 for Ollama's `images` message field.
    static func jpegBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.7,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
