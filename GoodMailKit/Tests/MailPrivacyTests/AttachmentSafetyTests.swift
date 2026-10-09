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
        try #require(encoded(type: type, gps: gps))
    }

    static var location: [CFString: Any] {
        [
            kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 13.405, kCGImagePropertyGPSLongitudeRef: "E",
        ]
    }

    static func pixels(width: Int = 8, height: Int = 6, gray: CGFloat = 0.5) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(red: 0.2, green: gray, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// nil when this Mac can't encode the type (HEIC needs a hardware encoder some virtual machines lack).
    static func encoded(type: UTType, gps: Bool) -> Data? {
        let data = NSMutableData()
        guard let image = pixels(), let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Camera", kCGImagePropertyTIFFModel: "One"],
            kCGImagePropertyOrientation: 6,
        ]
        if gps { properties[kCGImagePropertyGPSDictionary] = location }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Three frames looping forever; ImageIO stores a location in a GIF's XMP.
    static func animatedGIF(gps: Bool) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil))
        CGImageDestinationSetProperties(
            destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for gray in [0.1, 0.5, 0.9] {
            var properties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]]
            if gps { properties[kCGImagePropertyGPSDictionary] = location }
            CGImageDestinationAddImage(destination, try #require(pixels(gray: gray)), properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A 1×1 lossless WebP, hand-built because ImageIO reads WebP but can't write it. `exif` is the TIFF block of
    /// an EXIF chunk.
    static func webP(exif: [UInt8]?, bitstream: [UInt8] = [0x2F, 0, 0, 0, 0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xFE, 0x07]) -> Data {
        func littleEndian(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xFF) } }
        func chunk(_ name: String, _ payload: [UInt8]) -> [UInt8] {
            Array(name.utf8) + littleEndian(payload.count) + payload + (payload.count.isMultiple(of: 2) ? [] : [0])
        }
        let flags: UInt8 = exif == nil ? 0 : 0x08
        var body = Array("WEBP".utf8) + chunk("VP8X", [flags] + [UInt8](repeating: 0, count: 9)) + chunk("VP8L", bitstream)
        if let exif { body += chunk("EXIF", exif) }
        return Data(Array("RIFF".utf8) + littleEndian(body.count) + body)
    }

    /// The EXIF block (a TIFF structure) of a JPEG's APP1 segment.
    static func exifBlock(ofJPEG jpeg: Data) throws -> [UInt8] {
        let bytes = [UInt8](jpeg)
        var offset = 2
        while offset + 10 < bytes.count {
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if bytes[offset + 1] == 0xE1, Array(bytes[(offset + 4)..<(offset + 10)]) == Array("Exif\0\0".utf8) {
                return Array(bytes[(offset + 10)..<(offset + 2 + length)])
            }
            offset += 2 + length
        }
        throw CocoaError(.fileReadCorruptFile)
    }

    static func properties(_ data: Data, at index: Int = 0) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
    }

    static func cleaned(_ data: Data, type: UTType) throws -> (data: Data, type: String) {
        guard case .image(let cleaned, let cleanedType) = PhotoMetadata.withoutLocation(data, typeIdentifier: type.identifier)
        else { throw CocoaError(.fileReadCorruptFile) }
        return (cleaned, cleanedType)
    }

    static func hasLocation(_ data: Data) throws -> Bool {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return (0..<CGImageSourceGetCount(source)).contains { PhotoMetadata.hasLocation(source, at: $0) }
    }

    static let encodableTypes = [UTType.jpeg, .heic, .png, .tiff].filter { encoded(type: $0, gps: false) != nil }

    /// HEIC is what an iPhone camera writes; ImageIO's exclude-GPS option leaves its location in place.
    @Test(arguments: encodableTypes)
    func removesTheLocationAndKeepsTheImage(type: UTType) throws {
        let original = try Self.image(type: type, gps: true)
        #expect(try Self.properties(original)[kCGImagePropertyGPSDictionary] != nil)

        let (cleaned, cleanedType) = try Self.cleaned(original, type: type)
        #expect(cleanedType == type.identifier)
        let properties = try Self.properties(cleaned)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(try !Self.hasLocation(cleaned))
        let source = try #require(CGImageSourceCreateWithData(cleaned as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == type.identifier)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 8)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 6)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
    }

    @Test func coversTheCommonPhotoFormats() {
        #expect(Self.encodableTypes.contains(.jpeg) && Self.encodableTypes.contains(.png))
    }

    @Test func findsPhotosWithAVagueType() throws {
        let original = try Self.image(type: .jpeg, gps: true)
        let (cleaned, cleanedType) = try Self.cleaned(original, type: .data)
        #expect(cleanedType == UTType.jpeg.identifier)
        #expect(try Self.properties(cleaned)[kCGImagePropertyGPSDictionary] == nil)
    }

    /// Re-encoding would cost quality and drop what ImageIO doesn't copy, such as a GIF's loop count.
    @Test func imagesWithoutALocationAreLeftAsTheyAre() throws {
        let jpeg = try Self.image(type: .jpeg, gps: false)
        #expect(PhotoMetadata.withoutLocation(jpeg, typeIdentifier: UTType.jpeg.identifier) == .image(jpeg, typeIdentifier: UTType.jpeg.identifier))
        let gif = try Self.animatedGIF(gps: false)
        #expect(PhotoMetadata.withoutLocation(gif, typeIdentifier: UTType.gif.identifier) == .image(gif, typeIdentifier: UTType.gif.identifier))
        let webP = Self.webP(exif: nil)
        #expect(PhotoMetadata.withoutLocation(webP, typeIdentifier: UTType.webP.identifier) == .image(webP, typeIdentifier: UTType.webP.identifier))
    }

    @Test func animationsKeepTheirFramesAndLoopCount() throws {
        let original = try Self.animatedGIF(gps: true)
        #expect(try Self.hasLocation(original))
        let (cleaned, cleanedType) = try Self.cleaned(original, type: .gif)
        #expect(cleanedType == UTType.gif.identifier)
        #expect(try !Self.hasLocation(cleaned))
        let source = try #require(CGImageSourceCreateWithData(cleaned as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let file = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        #expect((file[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        let frame = try Self.properties(cleaned, at: 1)[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(frame?[kCGImagePropertyGIFDelayTime] as? Double == 0.5)
    }

    /// ImageIO reads WebP, RAW, JPEG XL and HEIF but can't write them: such a photo becomes a JPEG or PNG without
    /// its location rather than going out as it is.
    @Test func formatsImageIOCannotWriteAreConverted() throws {
        let original = Self.webP(exif: try Self.exifBlock(ofJPEG: Self.image(type: .jpeg, gps: true)))
        #expect(try Self.hasLocation(original))
        #expect(!((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains(UTType.webP.identifier))

        let (cleaned, cleanedType) = try Self.cleaned(original, type: .webP)
        #expect([UTType.jpeg.identifier, UTType.png.identifier].contains(cleanedType))
        #expect(try !Self.hasLocation(cleaned))
        let properties = try Self.properties(cleaned)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1 && properties[kCGImagePropertyPixelHeight] as? Int == 1)
        let source = try #require(CGImageSourceCreateWithData(cleaned as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == cleanedType)
    }

    @Test func imagesItCannotReadAreNotPassedOn() throws {
        let exif = try Self.exifBlock(ofJPEG: Self.image(type: .jpeg, gps: true))
        let broken = Self.webP(exif: exif, bitstream: [0x2F, 0, 0, 0, 0x99, 0x99, 0x99])
        #expect(PhotoMetadata.withoutLocation(broken, typeIdentifier: UTType.webP.identifier) == .locationNotRemovable)
    }

    @Test func otherFilesAreNotImages() {
        #expect(PhotoMetadata.withoutLocation(Data("hello".utf8), typeIdentifier: UTType.plainText.identifier) == .notAnImage)
        #expect(PhotoMetadata.withoutLocation(Data(repeating: 7, count: 512), typeIdentifier: UTType.data.identifier) == .notAnImage)
        let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".utf8)
        #expect(PhotoMetadata.withoutLocation(pdf, typeIdentifier: UTType.pdf.identifier) == .notAnImage)
    }

    /// The plan's original call: nil for anything it can't hand back without a location.
    @available(*, deprecated)
    @Test func theOlderCallReturnsOnlyCleanedImages() throws {
        let cleaned = try #require(PhotoMetadata.removingLocation(from: Self.image(type: .jpeg, gps: true), typeIdentifier: UTType.jpeg.identifier))
        #expect(try !Self.hasLocation(cleaned))
        #expect(PhotoMetadata.removingLocation(from: Data("hello".utf8), typeIdentifier: UTType.plainText.identifier) == nil)
    }
}
