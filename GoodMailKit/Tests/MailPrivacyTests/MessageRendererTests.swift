import Foundation
import Testing
@testable import MailPrivacy

struct MessageRendererTests {
    @Test func blocksRemoteContentByDefault() {
        let rendered = MessageRenderer.render([.init(kind: .html, content: "<p>Hi</p>")], policy: .blockAll)
        #expect(rendered.html.contains("img-src data: cid:;"))
        #expect(rendered.html.contains("default-src 'none'"))
        #expect(rendered.isStyled)
    }

    @Test func allowingImagesStillForbidsEverythingElse() {
        let rendered = MessageRenderer.render([.init(kind: .html, content: "<p>Hi</p>")], policy: .allowImages)
        #expect(rendered.html.contains("img-src data: cid: https:;"))
        #expect(rendered.html.contains("default-src 'none'"))
    }

    @Test func policyComesBeforeMessageContent() throws {
        let rendered = MessageRenderer.render([.init(kind: .html, content: "<p>MARKER</p>")], policy: .blockAll)
        let policy = try #require(rendered.html.range(of: "Content-Security-Policy"))
        let content = try #require(rendered.html.range(of: "MARKER"))
        #expect(policy.lowerBound < content.lowerBound)
    }

    @Test func countsRemoteImagesAndRemovesTrackers() {
        let html = """
            <img src="https://cdn.example.com/banner.png" width="600" height="200">
            <img src="cid:logo@example.com">
            <img src="data:image/png;base64,AAAA">
            <IMG SRC='https://example.com/pixel.gif' WIDTH=1 HEIGHT=1>
            <img src="https://example.com/open?id=1" style="display: none">
            <img src="//news.us1.list-manage.com/track/open.php?u=1&id=2" width="50" height="50">
            <img src="https://example.com/spacer.gif" width="1" height="24">
            """
        let sanitized = MessageRenderer.sanitize(html)

        #expect(sanitized.remoteImages == 2)
        #expect(sanitized.trackers == 3)
        #expect(sanitized.html.contains("banner.png"))
        #expect(sanitized.html.contains("cid:logo@example.com"))
        #expect(sanitized.html.contains("spacer.gif"))
        #expect(!sanitized.html.contains("pixel.gif"))
        #expect(!sanitized.html.contains("open?id=1"))
        #expect(!sanitized.html.contains("list-manage"))
    }

    @Test func removesActiveAndPrefetchingMarkup() {
        let html = """
            <head><link rel="dns-prefetch" href="//t.example.com"><base href="https://evil.example/">
            <meta http-equiv="refresh" content="0; url=https://evil.example/"><meta name="x" content="y"></head>
            <p>Before</p><script type="text/javascript">alert(1)</script><p>After</p><script>unterminated
            """
        let sanitized = MessageRenderer.sanitize(html).html

        #expect(!sanitized.contains("dns-prefetch"))
        #expect(!sanitized.contains("<base"))
        #expect(!sanitized.contains("refresh"))
        #expect(!sanitized.contains("alert"))
        #expect(!sanitized.contains("unterminated"))
        #expect(sanitized.contains("<meta name=\"x\" content=\"y\">"))
        #expect(sanitized.contains("<p>Before</p><p>After</p>"))
    }

    @Test func plainTextIsEscapedAndLinkified() {
        let text = "Tom & <b>Jerry</b>\nSee https://example.com/a?b=1&c=2. Or <https://example.org>"
        let rendered = MessageRenderer.render([.init(kind: .plainText, content: text)], policy: .blockAll)

        #expect(rendered.html.contains("Tom &amp; &lt;b&gt;Jerry&lt;/b&gt;"))
        #expect(rendered.html.contains(
            "<a href=\"https://example.com/a?b=1&amp;c=2\">https://example.com/a?b=1&amp;c=2</a>."))
        #expect(rendered.html.contains("&lt;<a href=\"https://example.org\">https://example.org</a>&gt;"))
        #expect(!rendered.isStyled)
        #expect(rendered.html.contains("content=\"light dark\""))
    }

    @Test(arguments: [
        ("https://news.us1.list-manage.com/track/open.php?u=1", true),
        ("https://news.us1.list-manage.com:443/v2/track/open.php?u=1", true),
        ("https://list-manage.com/subscribe", false),
        ("https://notlist-manage.com/track/open.php", false),
        ("https://abc.r.us-east-1.awstrack.me/I0/123", true),
        ("https://example.com/image.png", false),
    ])
    func recognisesKnownTrackers(url: String, expected: Bool) throws {
        #expect(TrackerList.isTracker(try #require(URL(string: url))) == expected)

        // The network-level rules must agree with the markup-level check.
        let blockedByRules = try TrackerList.contentRuleFilters.contains { filter in
            let regex = try NSRegularExpression(pattern: filter)
            return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        #expect(blockedByRules == expected)
    }

    @Test func contentRulesBlockEverythingUnlessImagesAreAllowed() throws {
        func rules(_ policy: RemoteContentPolicy) throws -> [[String: Any]] {
            try #require(JSONSerialization.jsonObject(with: Data(policy.contentRuleListJSON.utf8)) as? [[String: Any]])
        }
        func actions(_ rules: [[String: Any]]) -> [String] {
            rules.compactMap { ($0["action"] as? [String: Any])?["type"] as? String }
        }

        #expect(actions(try rules(.blockAll)) == ["block", "block", "block"])
        let allowing = actions(try rules(.allowImages))
        #expect(allowing.prefix(4) == ["block", "block", "block", "ignore-previous-rules"])
        #expect(allowing.dropFirst(4).count == TrackerList.contentRuleFilters.count)
        #expect(allowing.dropFirst(4).allSatisfy { $0 == "block" })
    }
}
