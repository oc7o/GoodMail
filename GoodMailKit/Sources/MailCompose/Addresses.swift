import Foundation
import JMAPKit

/// Addresses as people type and paste them into recipient fields.
public enum AddressParser {
    /// Splits text such as `Maya <maya@x.example>, "Berg, Alex" <alex@y.example>; b@z.example` at commas,
    /// semicolons and line breaks outside quotes and angle brackets.
    ///
    /// Every item followed by a separator becomes an address, valid or not, so the field can show invalid ones
    /// in red. The last item becomes an address only when it is complete and valid; otherwise it is returned as
    /// `remainder`, the text still being typed.
    public static func parse(_ text: String) -> (addresses: [EmailAddress], remainder: String) {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" && !inBrackets {
                inQuotes.toggle()
            } else if !inQuotes && character == "<" {
                inBrackets = true
            } else if !inQuotes && character == ">" {
                inBrackets = false
            } else if !inQuotes && !inBrackets && (character == "," || character == ";" || character.isNewline) {
                items.append(current)
                current = ""
                continue
            }
            current.append(character)
        }

        var addresses = items.compactMap { item -> EmailAddress? in
            item.allSatisfy(\.isWhitespace) ? nil : address(item)
        }
        let last = String(current.drop(while: \.isWhitespace))
        if !last.isEmpty, let address = address(last), isValid(address.email) {
            addresses.append(address)
            return (addresses, "")
        }
        return (addresses, last)
    }

    /// One item: `Name <address>`, `"Quoted, Name" <address>`, `<address>`, `Name address` or `address`.
    static func address(_ item: String) -> EmailAddress? {
        var item = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.lowercased().hasPrefix("mailto:") { item = String(item.dropFirst(7)) }
        guard !item.isEmpty else { return nil }
        if let open = lastBracket(in: item), let close = item[open...].firstIndex(of: ">") {
            let email = item[item.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: displayName(String(item[..<open])), email: email)
        }
        let words = item.split(whereSeparator: \.isWhitespace)
        if words.count > 1, let last = words.last, last.contains("@") {
            let name = item[..<last.startIndex].trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: displayName(name), email: String(last))
        }
        return EmailAddress(name: nil, email: item)
    }

    /// The "<" that opens the address: the last one outside quotes.
    static func lastBracket(in item: String) -> String.Index? {
        var inQuotes = false
        var escaped = false
        var found: String.Index?
        for index in item.indices {
            let character = item[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == "<" && !inQuotes {
                found = index
            }
        }
        return found
    }

    static func displayName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A practical check, not RFC 5321 in full: a dot-atom local part (international characters allowed) and
    /// a domain name with at least two labels and a top-level domain that starts with a letter. Quoted local
    /// parts and IP literals are refused.
    public static func isValid(_ address: String) -> Bool {
        guard address.utf8.count <= 254, let at = address.lastIndex(of: "@") else { return false }
        let local = address[..<at]
        let domain = address[address.index(after: at)...]
        guard !local.isEmpty, local.utf8.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."),
              !local.contains(".."),
              local.allSatisfy({ isAtomCharacter($0) || $0 == "." })
        else { return false }
        return isValidDomain(String(domain))
    }

    static func isAtomCharacter(_ character: Character) -> Bool {
        if character.isASCII {
            return character.isLetter || character.isNumber || "!#$%&'*+/=?^_`{|}~-".contains(character)
        }
        return !character.isWhitespace
            && !character.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func isValidDomain(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, labels.count >= 2, labels.last?.first?.isLetter == true else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    /// The lower-cased part after the last "@"; for a wildcard identity "*@berg.example" that is "berg.example".
    public static func domain(of address: String) -> String? {
        guard let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !domain.isEmpty, !domain.contains(where: \.isWhitespace) else { return nil }
        return domain
    }
}

/// A recipient the composer suggests while typing.
public struct AddressSuggestion: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case contacts, correspondent, both
    }

    public var address: EmailAddress
    /// A second line, such as the organisation.
    public var detail: String?
    public var source: Source
    public var id: String { address.email.lowercased() }

    public init(address: EmailAddress, detail: String? = nil, source: Source) {
        self.address = address
        self.detail = detail
        self.source = source
    }
}
