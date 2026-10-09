import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MailPrivacy

struct SafeFilenameTests {
    @Test func bidiOverridesCannotHideTheExtension() {
        #expect(SafeFilename.make("invoice\u{202E}fdp.exe", mimeType: "application/pdf") == "invoicefdp.exe")
        #expect(SafeFilename.make("photo\u{2067}gpj.\u{2069}scr", mimeType: nil) == "photogpj.scr")
        #expect(SafeFilename.make("a\u{200B}b\u{FEFF}.txt", mimeType: nil) == "ab.txt")
    }

    @Test func controlsAndPathsAreRemoved() {
        #expect(SafeFilename.make("../../etc/passwd", mimeType: "text/plain") == "passwd.txt")
        #expect(SafeFilename.make("C:\\Users\\x\\report.pdf", mimeType: nil) == "report.pdf")
        #expect(SafeFilename.make("line\nbreak\u{0}.txt", mimeType: nil) == "linebreak.txt")
        #expect(SafeFilename.make("  .hidden.pdf. ", mimeType: nil) == "hidden.pdf")
    }

    @Test func normalisesToNFC() {
        let decomposed = "Cafe\u{301}.txt"
        #expect(SafeFilename.make(decomposed, mimeType: nil) == "Caf\u{E9}.txt")
        #expect(SafeFilename.make(decomposed, mimeType: nil).unicodeScalars.count == 8)
    }

    @Test func fitsIn255UnitsKeepingTheExtension() {
        let long = SafeFilename.make(String(repeating: "a", count: 400) + ".pdf", mimeType: nil)
        #expect(long.utf16.count == 255)
        #expect(long.hasSuffix(".pdf"))

        let emoji = SafeFilename.make(String(repeating: "📎", count: 200) + ".pdf", mimeType: nil)
        #expect(emoji.utf16.count <= 255 && emoji.utf8.count <= 255)
        #expect(emoji.hasSuffix(".pdf"))
        #expect(emoji.dropLast(4).allSatisfy { $0 == "📎" })
    }

    @Test func emptyNamesGetAName() {
        #expect(SafeFilename.make(nil, mimeType: "application/pdf") == "Attachment.pdf")
        #expect(SafeFilename.make("", mimeType: "application/pdf") == "Attachment.pdf")
        #expect(SafeFilename.make("\u{202E}", mimeType: nil) == "Attachment")
        #expect(SafeFilename.make("...", mimeType: "image/png") == "Attachment.png")
    }

    @Test func addsAnExtensionFromTheType() {
        #expect(SafeFilename.make("README", mimeType: "text/plain; charset=utf-8") == "README.txt")
        #expect(SafeFilename.make("Invoice 3.5", mimeType: "application/pdf") == "Invoice 3.5.pdf")
        #expect(SafeFilename.make("Forwarded", mimeType: "message/rfc822") == "Forwarded.eml")
        #expect(SafeFilename.make("photo.JPG", mimeType: "image/png") == "photo.JPG")
    }
}

struct PhotoMetadataTests {
    static func image(type: UTType, gps: Bool) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera", kCGImagePropertyTIFFModel: "One"],
            kCGImagePropertyOrientation: 6,
        ]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 13.405, kCGImagePropertyGPSLongitudeRef: "E",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    /// HEIC is what an iPhone camera writes; ImageIO's exclude-GPS option leaves its location in place.
    @Test(arguments: [UTType.jpeg, .heic, .png, .tiff])
    func removesTheLocationAndKeepsTheImage(type: UTType) throws {
        let original = try Self.image(type: type, gps: true)
        #expect(try Self.properties(original)[kCGImagePropertyGPSDictionary] != nil)

        let cleaned = try #require(PhotoMetadata.removingLocation(from: original, typeIdentifier: type.identifier))
        let properties = try Self.properties(cleaned)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let source = try #require(CGImageSourceCreateWithData(cleaned as CFData, nil))
        #expect(!PhotoMetadata.hasLocation(source, at: 0))
        #expect(CGImageSourceGetType(source) as String? == type.identifier)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 8)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 6)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func findsPhotosWithAVagueType() throws {
        let original = try Self.image(type: .jpeg, gps: true)
        let cleaned = try #require(PhotoMetadata.removingLocation(from: original, typeIdentifier: UTType.data.identifier))
        #expect(try Self.properties(cleaned)[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func otherFilesAreNotImages() {
        #expect(PhotoMetadata.removingLocation(from: Data("hello".utf8), typeIdentifier: UTType.plainText.identifier) == nil)
        #expect(PhotoMetadata.removingLocation(from: Data(repeating: 7, count: 512), typeIdentifier: UTType.data.identifier) == nil)
        let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
        #expect(PhotoMetadata.removingLocation(from: pdf, typeIdentifier: UTType.pdf.identifier) == nil)
    }
}
