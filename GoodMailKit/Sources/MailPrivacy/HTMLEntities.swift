/// HTML character references, decoded the way a browser's parser decodes them, so the text GoodMail sends on reads as
/// the original did: every named reference HTML knows, the legacy names that work without a ";", and numeric
/// references with their error handling (128–159 as Windows-1252, NUL and surrogates as U+FFFD).
package enum Entities {
    package static func decode(_ string: String, inAttribute: Bool = false) -> String {
        guard string.utf8.contains(ampersand) else { return string }
        var output: [UInt8] = []
        output.reserveCapacity(string.utf8.count)
        decode(Array(string.utf8)[...], inAttribute: inAttribute, into: &output)
        return String(decoding: output, as: UTF8.self)
    }

    /// In an attribute value a legacy name followed by "=", a letter or a digit stays as it is, so a URL such as
    /// "?a=1&copy=2" keeps its parameter.
    package static func decode(_ bytes: ArraySlice<UInt8>, inAttribute: Bool, into output: inout [UInt8]) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            guard let ampersandIndex = bytes[index...].firstIndex(of: ampersand) else {
                output.append(contentsOf: bytes[index...])
                return
            }
            output.append(contentsOf: bytes[index..<ampersandIndex])
            if let (end, value) = reference(in: bytes, at: ampersandIndex, inAttribute: inAttribute) {
                output.append(contentsOf: value.utf8)
                index = end
            } else {
                output.append(ampersand)
                index = ampersandIndex + 1
            }
        }
    }

    static let ampersand = UInt8(ascii: "&")
    static let semicolon = UInt8(ascii: ";")
    /// The longest name, "CounterClockwiseContourIntegral".
    static let longestName = 31

    /// The reference starting at the "&" at `start`: where it ends and what it stands for.
    static func reference(in bytes: ArraySlice<UInt8>, at start: Int, inAttribute: Bool) -> (Int, String)? {
        let first = start + 1
        guard first < bytes.endIndex else { return nil }
        if bytes[first] == UInt8(ascii: "#") {
            var cursor = first + 1
            var radix: UInt32 = 10
            if cursor < bytes.endIndex, bytes[cursor] | 0x20 == UInt8(ascii: "x") {
                radix = 16
                cursor += 1
            }
            let digits = cursor
            var value: UInt32 = 0
            while cursor < bytes.endIndex, let digit = digitValue(bytes[cursor], radix: radix) {
                value = min(value * radix + digit, 0x110000)
                cursor += 1
            }
            guard cursor > digits else { return nil }
            if cursor < bytes.endIndex, bytes[cursor] == semicolon { cursor += 1 }
            return (cursor, String(numeric(value)))
        }
        guard isAlphanumeric(bytes[first]) else { return nil }
        var cursor = first
        while cursor < bytes.endIndex, cursor - first <= longestName, isAlphanumeric(bytes[cursor]) { cursor += 1 }
        if cursor < bytes.endIndex, bytes[cursor] == semicolon,
           let value = named[String(decoding: bytes[first..<cursor], as: UTF8.self)] {
            return (cursor + 1, value)
        }
        for length in stride(from: min(6, cursor - first), through: 2, by: -1) {
            let name = String(decoding: bytes[first..<first + length], as: UTF8.self)
            guard legacy.contains(name), let value = named[name] else { continue }
            let end = first + length
            if inAttribute, end < bytes.endIndex, bytes[end] == UInt8(ascii: "=") || isAlphanumeric(bytes[end]) {
                return nil
            }
            return (end, value)
        }
        return nil
    }

    static func numeric(_ value: UInt32) -> Unicode.Scalar {
        if let mapped = windows1252[value] { return mapped }
        return Unicode.Scalar(value).flatMap { $0.value == 0 ? nil : $0 } ?? "\u{FFFD}"
    }

    /// What browsers show for references to 128–159: the Windows-1252 characters text in that range almost always
    /// meant. The five codes Windows-1252 leaves undefined stay as they are.
    static let windows1252: [UInt32: Unicode.Scalar] = [
        0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}",
        0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}",
        0x8E: "\u{017D}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
        0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}",
        0x9C: "\u{0153}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    static func digitValue(_ byte: UInt8, radix: UInt32) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where radix == 16: UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F") where radix == 16: UInt32(byte - UInt8(ascii: "A") + 10)
        default: nil
        }
    }

    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    static let named: [String: String] = {
        var table: [String: String] = [:]
        table.reserveCapacity(2125)
        for entry in namedData.split(whereSeparator: \.isWhitespace) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let scalars = entry[entry.index(after: equals)...].split(separator: "+")
                .compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            table[String(entry[..<equals])] = String(String.UnicodeScalarView(scalars))
        }
        return table
    }()

    static let legacy = Set(legacyData.split(whereSeparator: \.isWhitespace).map(String.init))
}
