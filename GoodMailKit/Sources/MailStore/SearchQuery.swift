import Foundation

/// A search as typed, in the operator syntax Fastmail uses, e.g.
/// `from:maya subject:"lisbon trip" has:attachment is:unread after:2026-01-01 in:archive flights`.
///
/// Words without an operator, and operators that aren't understood, are searched as text. An operator
/// without a usable value yet (`from:`, `before:2026-0`) is ignored, so a search doesn't jump around
/// while it is being typed.
public struct SearchQuery: Sendable, Hashable {
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case text, from, to, cc, bcc, subject, body
    }

    public struct Term: Sendable, Hashable {
        public var field: Field
        public var value: String

        public init(_ field: Field, _ value: String) {
            self.field = field
            self.value = value
        }
    }

    /// All must match. Free text is collected into a single `.text` term.
    public var terms: [Term] = []
    /// The mailbox named by `in:`, as typed. The store doesn't look at it; callers resolve it to an id.
    public var mailbox: String?
    public var isUnread: Bool?
    public var isFlagged: Bool?
    public var hasAttachment: Bool?
    /// Received before the start of this day.
    public var before: Date?
    /// Received on or after the start of this day.
    public var after: Date?

    public init() {}

    public init(parsing string: String, calendar: Calendar = .current) {
        var words: [String] = []
        for token in Self.tokens(in: string) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                words.append(token)
                continue
            }
            let key = token[..<colon].lowercased()
            let value = token[token.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty, Self.operators.contains(key) { continue }
            if let field = Field(rawValue: key) {
                if field == .text { words.append(value) } else { terms.append(Term(field, value)) }
                continue
            }

            switch (key, value.lowercased()) {
            case ("in", _): mailbox = value
            case ("is", "unread"): isUnread = true
            case ("is", "read"), ("is", "seen"): isUnread = false
            // Fastmail's web app calls flagged messages pinned.
            case ("is", "flagged"), ("is", "pinned"): isFlagged = true
            case ("has", "attachment"), ("has", "attachments"): hasAttachment = true
            case ("before", _), ("after", _):
                guard let day = Self.day(value, calendar: calendar) else { continue }
                if key == "before" { before = day } else { after = day }
            default: words.append(token)
            }
        }
        if !words.isEmpty { terms.insert(Term(.text, words.joined(separator: " ")), at: 0) }
    }

    /// Whether it narrows anything down beyond picking a mailbox.
    public var hasCriteria: Bool {
        !terms.isEmpty || isUnread != nil || isFlagged != nil || hasAttachment != nil || before != nil || after != nil
    }

    private static let operators: Set<String> = Set(Field.allCases.map(\.rawValue))
        .union(["in", "is", "has", "before", "after"])

    /// Splits at whitespace outside double quotes, dropping the quotes.
    private static func tokens(in string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        for character in string {
            if character == "\"" {
                isQuoted.toggle()
            } else if character.isWhitespace, !isQuoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The start of a day written as `yyyy-mm-dd`.
    private static func day(_ string: String, calendar: Calendar) -> Date? {
        guard let match = string.wholeMatch(of: /(\d{4})-(\d{1,2})-(\d{1,2})/),
              let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
