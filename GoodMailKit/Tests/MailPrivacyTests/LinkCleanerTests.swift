import Foundation
import Testing
@testable import MailPrivacy

struct LinkCleanerTests {
    @Test(arguments: [
        ("https://example.com/a?utm_source=news&utm_medium=email&id=7", "https://example.com/a?id=7"),
        ("https://example.com/a?fbclid=abc", "https://example.com/a"),
        ("https://example.com/a?id=7&MC_EID=x#top", "https://example.com/a?id=7#top"),
        ("https://example.com/a?q=a%20b&gclid=1", "https://example.com/a?q=a%20b"),
        ("https://example.com/a?id=7", "https://example.com/a?id=7"),
        ("https://example.com/utm_source", "https://example.com/utm_source"),
        ("mailto:someone@example.com?utm_source=x", "mailto:someone@example.com?utm_source=x"),
    ])
    func cleans(original: String, expected: String) throws {
        #expect(LinkCleaner.clean(try #require(URL(string: original))).absoluteString == expected)
    }
}
