import Foundation
import ImageIO

@main
struct AttachmentTranscoderTests {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            fatalError("Usage: AttachmentTranscoderTests fixture.heic fixture.pdf fixture.mov")
        }
        let heicURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let pdfURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let videoURL = URL(fileURLWithPath: CommandLine.arguments[3])

        let heic = AttachmentTranscoder.prepare(
            data: try Data(contentsOf: heicURL),
            fileURL: heicURL,
            filename: "photo.heic",
            mimeType: "image/heic",
            maximumBytes: 20 * 1024 * 1024
        )
        precondition(heic.mimeType == "image/jpeg")
        precondition(heic.inlineRenderable)
        precondition(heic.wasTranscoded)
        precondition(heic.name == "photo.jpg")
        precondition(CGImageSourceCreateWithData(heic.data as CFData, nil) != nil)
        let inferredHEIC = AttachmentTranscoder.prepare(
            data: try Data(contentsOf: heicURL),
            fileURL: heicURL,
            filename: "photo.heic",
            mimeType: "application/octet-stream",
            maximumBytes: 20 * 1024 * 1024
        )
        precondition(inferredHEIC.mimeType == "image/jpeg")
        precondition(inferredHEIC.wasTranscoded)

        let pdfData = try Data(contentsOf: pdfURL)
        let pdf = AttachmentTranscoder.prepare(
            data: pdfData,
            fileURL: pdfURL,
            filename: "document.pdf",
            mimeType: "application/pdf",
            maximumBytes: 20 * 1024 * 1024
        )
        precondition(pdf.data == pdfData)
        precondition(pdf.mimeType == "application/pdf")
        precondition(!pdf.inlineRenderable)
        precondition(pdf.previewData != nil)
        precondition(CGImageSourceCreateWithData(pdf.previewData! as CFData, nil) != nil)

        let videoData = try Data(contentsOf: videoURL)
        let video = AttachmentTranscoder.prepare(
            data: videoData,
            fileURL: videoURL,
            filename: "clip.mov",
            mimeType: "video/quicktime",
            maximumBytes: 20 * 1024 * 1024
        )
        precondition(video.data == videoData)
        precondition(video.mimeType == "video/quicktime")
        precondition(!video.inlineRenderable)
        precondition(video.previewData != nil)
        precondition(CGImageSourceCreateWithData(video.previewData! as CFData, nil) != nil)
        let largeVideoPreview = AttachmentTranscoder.previewOnly(
            fileURL: videoURL,
            filename: "large-clip.mov",
            mimeType: "video/quicktime",
            originalByteCount: 50 * 1024 * 1024
        )
        precondition(largeVideoPreview != nil)
        precondition(largeVideoPreview?.originalByteCount == 50 * 1024 * 1024)
        precondition(CGImageSourceCreateWithData(largeVideoPreview!.previewData as CFData, nil) != nil)

        print("Attachment transcoding, document/video resources, and large-file previews passed.")
    }
}
