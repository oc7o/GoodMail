import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Photos carry where they were taken; an attachment shouldn't tell the recipient where the user lives.
public enum PhotoMetadata {
    /// The image without GPS metadata (EXIF and XMP), or nil when `data` isn't an image ImageIO can read.
    ///
    /// ImageIO sniffs the bytes, so a photo with a vague `typeIdentifier` such as public.data is still found.
    /// ImageIO's own options don't do this reliably (on the 27 SDKs `kCGImageMetadataShouldExcludeGPS` leaves the
    /// location in PNG, TIFF and HEIC, and drops a JPEG's orientation), so each way is tried in turn and its result
    /// checked: copying the image data with the metadata minus GPS (lossless, JPEG and HEIC), re-encoding with the
    /// GPS properties removed, and finally the pixels with nothing but their orientation.
    public static func removingLocation(from data: Data, typeIdentifier: String) -> Data? {
        if let type = UTType(typeIdentifier), type.conforms(to: .audiovisualContent) { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true
        else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        let orientations = (0..<count).map { orientation(of: source, at: $0) }

        let attempts: [(CGImageDestination) -> Bool] = [
            { destination in
                guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
                let options = [
                    kCGImageDestinationMetadata: withoutLocation(metadata), kCGImageDestinationMergeMetadata: false,
                ] as CFDictionary
                return CGImageDestinationCopyImageSource(destination, source, options, nil)
            },
            { destination in
                let properties = [kCGImagePropertyGPSDictionary: kCFNull] as CFDictionary
                for index in 0..<count { CGImageDestinationAddImageFromSource(destination, source, index, properties) }
                return CGImageDestinationFinalize(destination)
            },
            { destination in
                for index in 0..<count {
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return false }
                    let kept = [kCGImagePropertyOrientation: orientations[index]] as CFDictionary
                    CGImageDestinationAddImage(destination, image, kept)
                }
                return CGImageDestinationFinalize(destination)
            },
        ]
        for (number, attempt) in attempts.enumerated() {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type, count, nil), attempt(destination),
                  let result = CGImageSourceCreateWithData(output, nil), CGImageSourceGetCount(result) == count,
                  (0..<count).allSatisfy({ !hasLocation(result, at: $0) }),
                  // A photo that turns sideways is a lesser evil than one that tells where it was taken.
                  number == attempts.count - 1
                    || (0..<count).allSatisfy({ orientation(of: result, at: $0) == orientations[$0] })
            else { continue }
            return output as Data
        }
        return nil
    }

    static func withoutLocation(_ metadata: CGImageMetadata) -> CGImageMetadata {
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
