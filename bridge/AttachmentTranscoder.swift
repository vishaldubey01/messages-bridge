import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing

struct PreparedAttachment {
    let data: Data
    let name: String
    let mimeType: String
    let inlineRenderable: Bool
    let originalMimeType: String?
    let originalByteCount: Int
    let previewData: Data?

    var wasTranscoded: Bool { originalMimeType != nil }
}

struct PreparedAttachmentPreview {
    let name: String
    let mimeType: String
    let originalByteCount: Int
    let previewData: Data
}

enum AttachmentTranscoder {
    private static let maximumPreviewBytes = 1 * 1024 * 1024
    private static let inlineImageMimeTypes: Set<String> = [
        "image/gif",
        "image/jpeg",
        "image/png",
        "image/webp",
    ]

    static func prepare(
        data: Data,
        fileURL: URL,
        filename: String,
        mimeType: String,
        maximumBytes: Int
    ) -> PreparedAttachment {
        let resolvedMimeType = resolvedMimeType(filename: filename, mimeType: mimeType)
        if resolvedMimeType.hasPrefix("image/"),
           !inlineImageMimeTypes.contains(resolvedMimeType),
           let jpeg = convertedJPEG(data: data, maximumBytes: maximumBytes) {
            let baseName = (filename as NSString).deletingPathExtension
            return PreparedAttachment(
                data: jpeg,
                name: "\(baseName.isEmpty ? "attachment" : baseName).jpg",
                mimeType: "image/jpeg",
                inlineRenderable: true,
                originalMimeType: resolvedMimeType,
                originalByteCount: data.count,
                previewData: nil
            )
        }

        let inlineRenderable = inlineImageMimeTypes.contains(resolvedMimeType)
            || resolvedMimeType.hasPrefix("audio/")
        return PreparedAttachment(
            data: data,
            name: filename,
            mimeType: resolvedMimeType,
            inlineRenderable: inlineRenderable,
            originalMimeType: nil,
            originalByteCount: data.count,
            previewData: inlineRenderable ? nil : quickLookPreview(fileURL: fileURL)
        )
    }

    static func previewOnly(
        fileURL: URL,
        filename: String,
        mimeType: String,
        originalByteCount: Int
    ) -> PreparedAttachmentPreview? {
        guard let previewData = quickLookPreview(fileURL: fileURL) else { return nil }
        return PreparedAttachmentPreview(
            name: filename,
            mimeType: resolvedMimeType(filename: filename, mimeType: mimeType),
            originalByteCount: originalByteCount,
            previewData: previewData
        )
    }

    private static func resolvedMimeType(filename: String, mimeType: String) -> String {
        let normalized = mimeType
            .lowercased()
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        if !normalized.isEmpty, normalized != "application/octet-stream" { return normalized }
        switch (filename as NSString).pathExtension.lowercased() {
        case "bmp": return "image/bmp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "jpeg", "jpg": return "image/jpeg"
        case "png": return "image/png"
        case "tif", "tiff": return "image/tiff"
        case "webp": return "image/webp"
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4v": return "video/x-m4v"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private static func convertedJPEG(data: Data, maximumBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let originalMaximumDimension = maximumPixelDimension(source: source)
        let candidates: [(pixels: Int, quality: CGFloat)] = [
            (min(originalMaximumDimension, 6_000), 0.88),
            (min(originalMaximumDimension, 4_096), 0.84),
            (min(originalMaximumDimension, 3_072), 0.80),
            (min(originalMaximumDimension, 2_048), 0.78),
        ]
        var attemptedDimensions = Set<Int>()
        for candidate in candidates where candidate.pixels > 0 {
            guard attemptedDimensions.insert(candidate.pixels).inserted,
                  let image = thumbnail(source: source, maximumPixelDimension: candidate.pixels),
                  let jpeg = jpegData(image: image, quality: candidate.quality) else { continue }
            if jpeg.count <= maximumBytes { return jpeg }
        }
        return nil
    }

    private static func maximumPixelDimension(source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return 6_000
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(width, height, 1)
    }

    private static func thumbnail(source: CGImageSource, maximumPixelDimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func quickLookPreview(fileURL: URL) -> Data? {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 1_600, height: 1_600),
            scale: 1,
            representationTypes: .thumbnail
        )
        let result = ThumbnailResult()
        let semaphore = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            result.image = representation?.cgImage
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 8) == .success,
              let image = result.image else { return nil }
        for quality: CGFloat in [0.82, 0.68, 0.54] {
            guard let jpeg = jpegData(image: image, quality: quality) else { continue }
            if jpeg.count <= maximumPreviewBytes { return jpeg }
        }
        return nil
    }

    private static func jpegData(image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private final class ThumbnailResult: @unchecked Sendable {
    var image: CGImage?
}
