import Foundation
import Testing
import MailStore

struct SearchQueryTests {
    static let calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func parsesOperatorsQuotedValuesAndFreeText() {
        let query = SearchQuery(
            parsing: #"from:"Maya L" Lisbon SUBJECT:trip is:unread has:attachment in:Archive before:2026-03-01 after:2026-1-5 "early check-in""#,
            calendar: Self.calendar)

        #expect(query.terms == [.init(.text, "Lisbon early check-in"), .init(.from, "Maya L"), .init(.subject, "trip")])
        #expect(query.mailbox == "Archive")
        #expect(query.isUnread == true)
        #expect(query.hasAttachment == true)
        #expect(query.isFlagged == nil)
        #expect(query.before == day(2026, 3, 1))
        #expect(query.after == day(2026, 1, 5))
    }

    @Test func understandsReadAndFlaggedState() {
        #expect(SearchQuery(parsing: "is:read").isUnread == false)
        #expect(SearchQuery(parsing: "is:flagged").isFlagged == true)
        #expect(SearchQuery(parsing: "is:pinned").isFlagged == true)
    }

    @Test func searchesUnknownOperatorsAsText() {
        let query = SearchQuery(parsing: "is:important has:pdf https://example.com text:hello")
        #expect(query.terms == [.init(.text, "is:important has:pdf https://example.com hello")])
    }

    @Test func ignoresOperatorsStillBeingTyped() {
        let query = SearchQuery(parsing: "from: in: before:2026-0 after:2026-13-01 is:")
        #expect(!query.hasCriteria)
        #expect(query.mailbox == nil)
        #expect(SearchQuery(parsing: "in:inbox").hasCriteria == false)
        #expect(SearchQuery(parsing: "   ").terms.isEmpty)
    }
}
