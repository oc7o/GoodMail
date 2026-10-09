import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photos carry where they were taken; an attachment shouldn't tell the recipient where the user lives.
public enum PhotoMetadata {
    /// What `withoutLocation(_:typeIdentifier:)` made of a file.
    public enum Result: Sendable, Equatable {
        /// Not an image ImageIO knows: the bytes can be attached as they are.
        case notAnImage
        /// The image, carrying no location: the original bytes when it had none, else a copy without it.
        ///
        /// `typeIdentifier` is the format of `data`. It is the original's unless ImageIO can't write that format
        /// (WebP, camera RAW and DNG, JPEG XL, HEIF): such an image is converted to JPEG, or to PNG when it has
        /// transparency, and the attachment's name and type have to follow.
        case image(Data, typeIdentifier: String)
        /// An image whose location couldn't be removed, or couldn't be ruled out because ImageIO can't read the
        /// image. These bytes must not be sent as they are.
        case locationNotRemovable
    }

    /// The image without GPS metadata (EXIF and XMP).
    ///
    /// ImageIO sniffs the bytes, so a photo with a vague `typeIdentifier` such as public.data is still found.
    /// Images without a location are left exactly as they are. ImageIO's own options don't remove one reliably (on
    /// the 27 SDKs `kCGImageMetadataShouldExcludeGPS` leaves the location in PNG, TIFF and HEIC, and drops a JPEG's
    /// orientation), so each way is tried in turn and its result checked: copying the image data with the metadata
    /// minus GPS (lossless, JPEG and HEIC), re-encoding with the GPS properties removed, the pixels with nothing but
    /// their orientation, and finally converting the main image to a format ImageIO can write.
    public static func withoutLocation(_ data: Data, typeIdentifier: String) -> Result {
        if let type = UTType(typeIdentifier), type.conforms(to: .audiovisualContent) { return .notAnImage }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true
        else { return .notAnImage }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .locationNotRemovable }
        guard (0..<count).contains(where: { hasLocation(source, at: $0) }) else {
            return .image(data, typeIdentifier: type as String)
        }
        if let cleaned = sameFormat(source, type: type, count: count) {
            return .image(cleaned, typeIdentifier: type as String)
        }
        if let (converted, convertedType) = converted(source) {
            return .image(converted, typeIdentifier: convertedType)
        }
        return .locationNotRemovable
    }

    /// The image without GPS metadata, or nil when `data` isn't an image, or is one whose location can't be removed.
    @available(*, deprecated, message: "Use withoutLocation(_:typeIdentifier:): this can't say that an image was converted to another format, or that its location couldn't be removed")
    public static func removingLocation(from data: Data, typeIdentifier: String) -> Data? {
        if case .image(let cleaned, _) = withoutLocation(data, typeIdentifier: typeIdentifier) { cleaned } else { nil }
    }

    /// A copy in the original's format, all frames and their orientation kept.
    static func sameFormat(_ source: CGImageSource, type: CFString, count: Int) -> Data? {
        let orientations = (0..<count).map { orientation(of: source, at: $0) }
        // Settings of the whole file, such as how often an animation loops; adding frames doesn't carry them over.
        var fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        fileProperties[kCGImagePropertyGPSDictionary] = nil

        let attempts: [(CGImageDestination) -> Bool] = [
            { destination in
                guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
                let options = [
                    kCGImageDestinationMetadata: metadataWithoutLocation(metadata),
                    kCGImageDestinationMergeMetadata: false,
                ] as CFDictionary
                return CGImageDestinationCopyImageSource(destination, source, options, nil)
            },
            { destination in
                CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
                let properties = [kCGImagePropertyGPSDictionary: kCFNull] as CFDictionary
                for index in 0..<count { CGImageDestinationAddImageFromSource(destination, source, index, properties) }
                return CGImageDestinationFinalize(destination)
            },
            { destination in
                CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
                for index in 0..<count {
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return false }
                    let kept = [kCGImagePropertyOrientation: orientations[index]] as CFDictionary
                    CGImageDestinationAddImage(destination, image, kept)
                }
                return CGImageDestinationFinalize(destination)
            },
        ]
        for attempt in attempts {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type, count, nil), attempt(destination),
                  let result = CGImageSourceCreateWithData(output, nil), CGImageSourceGetCount(result) == count,
                  (0..<count).allSatisfy({ !hasLocation(result, at: $0) }),
                  (0..<count).allSatisfy({ orientation(of: result, at: $0) == orientations[$0] })
            else { continue }
            return output as Data
        }
        return nil
    }

    /// The main image as JPEG, or PNG if it has transparency, upright and without any metadata. Animations keep
    /// their first image only; this is for formats ImageIO can read but not write.
    static func converted(_ source: CGImageSource) -> (Data, String)? {
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let size = max(
            (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as CFDictionary
        guard size > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, index, options) else { return nil }
        let isOpaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = (isOpaque ? UTType.jpeg : UTType.png).identifier
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil) else { return nil }
        let quality = isOpaque ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil
        CGImageDestinationAddImage(destination, image, quality)
        guard CGImageDestinationFinalize(destination), let result = CGImageSourceCreateWithData(output, nil),
              CGImageSourceGetCount(result) == 1, !hasLocation(result, at: 0)
        else { return nil }
        return (output as Data, type)
    }

    static func metadataWithoutLocation(_ metadata: CGImageMetadata) -> CGImageMetadata {
        guard let copy = CGImageMetadataCreateMutableCopy(metadata) else { return metadata }
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?)?.lowercased() ?? ""
            let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
            if prefix.hasPrefix("exif"), name.hasPrefix("GPS") { CGImageMetadataRemoveTagWithPath(copy, nil, path) }
            return true
        }
        return copy
    }

    static func hasLocation(_ source: CGImageSource, at index: Int) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if properties?[kCGImagePropertyGPSDictionary] != nil { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else { return false }
        return CGImageMetadataCopyTagMatchingImageProperty(
            metadata, kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude) != nil
    }

    /// The EXIF orientation; 1 (up) when there is none.
    static func orientation(of source: CGImageSource, at index: Int) -> Int {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }
}
