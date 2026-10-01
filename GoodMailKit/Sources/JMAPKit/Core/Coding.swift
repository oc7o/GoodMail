import Foundation

/// JSON coders using JMAP's date format, also used to persist JMAP objects.
public enum JMAPCoding {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = parseDate(string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid JMAP date: \(string)")
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// JMAP UTCDate / Date values: RFC 3339, with or without fractional seconds, `Z` or offset.
    static func parseDate(_ string: String) -> Date? {
        let plain = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? plain.parse(string)) ?? (try? fractional.parse(string))
    }
}
