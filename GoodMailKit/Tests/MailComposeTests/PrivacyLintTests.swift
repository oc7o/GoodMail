import Foundation
import Testing

/// Source-level checks for the privacy invariants a type checker can't see (C22): untrusted HTML never reaches a
/// system HTML importer (WebKit-backed, it loads remote resources), outgoing mail names no mailer, and drafts
/// carry no GoodMail markers.
struct PrivacyLintTests {
    struct Rule {
        var name: String
        var pattern: String
        /// Text the rule must catch, so a broken pattern can't pass silently.
        var positive: String
    }

    static let rules: [Rule] = [
        Rule(name: "document type option", pattern: #"documentType"#,
             positive: "[.documentType: NSAttributedString.DocumentType.html]"),
        Rule(name: "HTML document type", pattern: #"DocumentType\.html"#, positive: "NSAttributedString.DocumentType.html"),
        // `fromHTML(` and `.fromHTML` are the importer; an argument label such as `plainText(fromHTML:)` is not.
        Rule(name: "async HTML importer", pattern: #"\.fromHTML\b|\bfromHTML\s*\("#,
             positive: "try await NSAttributedString.fromHTML(html)"),
        Rule(name: "HTML loader", pattern: #"loadFromHTML"#, positive: "NSAttributedString.loadFromHTML(string: html)"),
        Rule(name: "NSAttributedString HTML initialiser", pattern: #"NSAttributedString\(html"#,
             positive: "NSAttributedString(html: data, documentAttributes: nil)"),
        Rule(name: "AttributedString HTML initialiser", pattern: #"AttributedString\(html"#,
             positive: "AttributedString(html: data)"),
        // `.init(html:` calls the importer; declaring a value type's own `init(html:text:)` doesn't.
        Rule(name: "explicit HTML initialiser", pattern: #"\.init\(html:"#, positive: "NSAttributedString.init(html: data)"),
        Rule(name: "HTML initialiser", pattern: #"\(HTML:"#, positive: "NSAttributedString(HTML: data, documentAttributes: nil)"),
        Rule(name: "formatting transferable", pattern: #"AttributedTextFormatting\.Transferable"#,
             positive: "let item = AttributedTextFormatting.Transferable(text: text)"),
        Rule(name: "mailer header", pattern: #"X-Mailer"#, positive: "\"X-Mailer\": \"GoodMail\""),
        Rule(name: "draft marker", pattern: #"data-goodmail"#, positive: "<div data-goodmail=\"quote\">"),
    ]

    /// Lines that must pass: the rules may not flag ordinary code.
    static let negatives = [
        "case .html: body += sanitized.html",
        "MessagePart(kind: part.type == \"text/html\" ? .html : .plainText, content: value)",
        "return part.type == \"text/html\" ? plainText(fromHTML: value) : value",
        "static func plainText(fromHTML html: String) -> String {",
        "let html = MailHTMLWriter.write(text).html",
        "OutgoingHTMLSanitizer.sanitize(html, options: .init(cleansLinks: false))",
        "public init(html: String, text: String) {",
        "let tail = PreservedTail(html: sanitized.html, text: text)",
    ]

    static func regex(_ rule: Rule) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: rule.pattern)
    }

    static func matches(_ rule: Rule, _ text: String) throws -> Bool {
        try regex(rule).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    @Test(arguments: rules.map(\.name))
    func ruleCatchesItsExample(name: String) throws {
        let rule = try #require(Self.rules.first { $0.name == name })
        #expect(try Self.matches(rule, rule.positive))
    }

    @Test func rulesLeaveOrdinaryCodeAlone() throws {
        for line in Self.negatives {
            for rule in Self.rules {
                #expect(try !Self.matches(rule, line), "\(rule.name) flags: \(line)")
            }
        }
    }

    /// The repository root, found from this file: GoodMailKit/Tests/MailComposeTests/PrivacyLintTests.swift.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func sourceFiles(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    @Test func sourcesKeepThePrivacyInvariants() throws {
        let directories = [Self.root.appending(path: "GoodMailKit/Sources"), Self.root.appending(path: "App")]
        var scanned = 0
        var violations: [String] = []
        for directory in directories {
            #expect(FileManager.default.fileExists(atPath: directory.path), "missing \(directory.path)")
            for file in Self.sourceFiles(in: directory) {
                guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else {
                    continue // binary assets
                }
                scanned += 1
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    for rule in Self.rules where try Self.matches(rule, String(line)) {
                        violations.append("\(file.path(percentEncoded: false)):\(number + 1): \(rule.name)")
                    }
                }
            }
        }
        #expect(scanned > 40, "only \(scanned) files scanned; is the repository layout still the same?")
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }
}
