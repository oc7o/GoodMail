import Foundation
import UniformTypeIdentifiers

/// A file name from a message, made safe to create on disk and to show: attachment names are chosen by the
/// sender, who can use them to hide the real extension or to escape the directory they are saved to.
public enum SafeFilename {
    /// The longest name APFS and HFS+ both accept, counted in UTF-16 units and in UTF-8 bytes.
    static let maxLength = 255

    /// - The last path component only (RFC 2183 §2.3), NFC-normalised.
    /// - No control, bidirectional-override or invisible formatting characters, so "invoice\u{202E}fdp.exe" can't
    ///   pose as a PDF; no leading dots (hidden files) and no trailing dots or spaces.
    /// - An extension from `mimeType` when the name has none, so Quick Look can pick a viewer.
    /// - At most 255 UTF-16 units and 255 UTF-8 bytes, keeping the extension.
    /// - "Attachment" when nothing is left.
    public static func make(_ name: String?, mimeType: String?) -> String {
        var name = (name ?? "").precomposedStringWithCanonicalMapping
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            name = String(name[name.index(after: slash)...])
        }
        name = String(String.UnicodeScalarView(name.unicodeScalars.filter { !isUnsafe($0) }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        while let last = name.last, last == "." || last.isWhitespace { name.removeLast() }

        var (base, fileExtension) = split(name)
        if fileExtension.isEmpty, let preferred = mimeType.flatMap(preferredExtension) {
            fileExtension = preferred
        }
        if base.isEmpty { base = "Attachment" }
        return fitted(base: base, fileExtension: fileExtension)
    }

    static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true          // controls
        case 0x061C, 0x200E, 0x200F: true            // ALM, LRM, RLM
        case 0x202A...0x202E, 0x2066...0x2069: true  // embeddings, overrides and isolates
        case 0x00AD, 0x180E, 0x200B, 0x2060...0x2064, 0xFEFF: true // invisible formatting
        case 0xFFF9...0xFFFB: true                    // interlinear annotation controls
        default: false
        }
    }

    /// Splits off a plausible extension: up to 16 letters or digits, at least one a letter, after the last dot.
    /// "Invoice 3.5" has none.
    static func split(_ name: String) -> (base: String, fileExtension: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let candidate = name[name.index(after: dot)...]
        guard !candidate.isEmpty, candidate.count <= 16, candidate.allSatisfy({ $0.isLetter || $0.isNumber }),
              candidate.contains(where: \.isLetter)
        else { return (name, "") }
        return (String(name[..<dot]), String(candidate))
    }

    static func preferredExtension(forMIMEType mimeType: String) -> String? {
        let essence = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let essence, !essence.isEmpty else { return nil }
        if essence == "message/rfc822" { return "eml" }
        return UTType(mimeType: essence)?.preferredFilenameExtension
    }

    static func fitted(base: String, fileExtension: String) -> String {
        let suffix = fileExtension.isEmpty ? "" : "." + fileExtension
        var base = base
        func fits(_ name: String) -> Bool { name.utf16.count <= maxLength && name.utf8.count <= maxLength }
        while !base.isEmpty, !fits(base + suffix) { base.removeLast() } // whole characters, never half a pair
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = "Attachment" }
        return fits(base + suffix) ? base + suffix : base
    }
}
