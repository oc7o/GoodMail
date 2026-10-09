import Foundation
import JMAPKit

/// Sample account contents for `DemoTransport`.
enum DemoData {
    static let me = "alex@fastmail.com"

    /// Fastmail's session, with the limits it announces, for a token with or without the submission scope.
    static func session(supportsSubmission: Bool) -> String {
        let submission = Capability.submission
        let submissionAccount = "\"\(submission)\": {\"maxDelayedSend\": 44236800, \"submissionExtensions\": {}},"
        return """
            {
              "capabilities": {
                "\(Capability.core)": {
                  "maxSizeUpload": 250000000, "maxConcurrentUpload": 10, "maxSizeRequest": 10000000,
                  "maxConcurrentRequests": 10, "maxCallsInRequest": 50, "maxObjectsInGet": 4096,
                  "maxObjectsInSet": 4096, "collationAlgorithms": ["i;ascii-numeric", "i;ascii-casemap", "i;octet"]
                },
                "\(Capability.mail)": {},
                \(supportsSubmission ? "\"\(submission)\": {}," : "")
                "\(Capability.maskedEmail)": {}
              },
              "accounts": {"demo": {
                "name": "\(me)", "isPersonal": true, "isReadOnly": false,
                "accountCapabilities": {
                  "\(Capability.mail)": {
                    "maxMailboxesPerEmail": 1000, "maxMailboxDepth": null, "maxSizeMailboxName": 490,
                    "maxSizeAttachmentsPerEmail": 50000000, "mayCreateTopLevelMailbox": true,
                    "emailQuerySortOptions": ["receivedAt", "sentAt", "size", "from", "to", "subject"]
                  },
                  \(supportsSubmission ? submissionAccount : "")
                  "\(Capability.maskedEmail)": {}
                }
              }},
              "primaryAccounts": {
                "\(Capability.mail)": "demo", \(supportsSubmission ? "\"\(submission)\": \"demo\"," : "")
                "\(Capability.maskedEmail)": "demo"
              },
              "username": "\(me)",
              "apiUrl": "https://\(DemoTransport.host)/jmap/api/",
              "downloadUrl": "https://\(DemoTransport.host)/jmap/download/{accountId}/{blobId}/{name}?type={type}",
              "uploadUrl": "https://\(DemoTransport.host)/jmap/upload/{accountId}/",
              "eventSourceUrl": "https://\(DemoTransport.host)/jmap/event/",
              "state": "\(sessionState(supportsSubmission: supportsSubmission))"
            }
            """
    }

    /// Differs with the scopes, so that a client notices when they change.
    static func sessionState(supportsSubmission: Bool) -> String {
        supportsSubmission ? "demo" : "demo-without-submission"
    }

    /// `ident-1` is the default identity: its address is the login name and it can't be deleted.
    static let identities: [[String: JSONValue]] = [
        [
            "id": "ident-1", "name": "Alex Berg", "email": .string(me), "replyTo": .null, "bcc": .null,
            "textSignature": "-- \nAlex", "htmlSignature": "<div>Alex</div>", "mayDelete": false,
        ],
        [
            "id": "ident-2", "name": "Alex Berg", "email": "*@berg.example", "replyTo": .null, "bcc": .null,
            "textSignature": "", "htmlSignature": "", "mayDelete": true,
        ],
    ]

    /// Where the Fjord Outdoor newsletter (e4) takes one-click unsubscribe requests (RFC 8058).
    static let oneClickURL = URL(string: "https://fjord-outdoor.example/unsubscribe/one-click?u=8f2a11&l=news")!

    /// Header fields of demo emails beyond those their properties make, topmost first, as delivered to Fastmail.
    ///
    /// The newsletter's DKIM signature covers both List-Unsubscribe fields, and Fastmail's topmost
    /// Authentication-Results pairs a `dkim=pass` with it through `header.d` and the first 8 characters of `b=`.
    static let headers: [String: [DemoHeader]] = [
        "e4": [
            DemoHeader("X-Delivered-To", "fjord.k3x9@fastmail.com"),
            DemoHeader("Authentication-Results", """
                mx.messagingengine.com;\r
                    dkim=pass (2048-bit rsa key sha256) header.d=fjord-outdoor.example\r
                    header.i=@fjord-outdoor.example header.b=Xq3vL0f8 header.a=rsa-sha256\r
                    header.s=fm2;\r
                    spf=pass smtp.mailfrom=bounce@fjord-outdoor.example\r
                    smtp.helo=mail.fjord-outdoor.example
                """),
            DemoHeader("DKIM-Signature", """
                v=1; a=rsa-sha256; c=relaxed/relaxed; d=fjord-outdoor.example;\r
                \ts=fm2; t=1791043200; h=from:to:subject:list-unsubscribe:list-unsubscribe-post;\r
                \tbh=7Xq3Lk2hT1mB5cW9zA4yE6uJ0pS3dG8iK2oH1nQ7rV4=;\r
                \tb=Xq3vL0f8N2kR7hT1mB5cW9zA4yE6uJ0pS3dG8iK2oH1nQ7rV5xF9wC4eZ6tY8jU0lM2bN4vP6s\r
                \t D8gA1kR3hT5mW7qL9eV2pQ4xF6zB8nC0dE2fG4hJ6kL8mN0pR2sT4uW6yA8cE0gI2==
                """),
            DemoHeader("List-Id", "Fjord Outdoor News <news.fjord-outdoor.example>"),
            DemoHeader("List-Unsubscribe", """
                <\(oneClickURL.absoluteString)>,\r
                 <mailto:unsubscribe@fjord-outdoor.example?subject=unsubscribe%208f2a11>
                """),
            DemoHeader("List-Unsubscribe-Post", "List-Unsubscribe=One-Click"),
        ],
        "e7": [DemoHeader("X-Delivered-To", "paperplane.x2m4@fastmail.com")],
        "e8": [DemoHeader("X-Delivered-To", "parcel.q8w1@fastmail.com")],
    ]

    static let logo = """
        <svg xmlns="http://www.w3.org/2000/svg" width="160" height="40" viewBox="0 0 160 40">\
        <rect width="160" height="40" rx="8" fill="#1f6feb"/>\
        <text x="80" y="26" font-family="Helvetica" font-size="17" fill="#fff" text-anchor="middle">Northwind</text></svg>
        """

    static func date(hoursAgo: Double, before now: Date) -> String {
        now.addingTimeInterval(-hoursAgo * 3600).formatted(.iso8601)
    }

    static func maskedEmails(relativeTo now: Date) -> [[String: JSONValue]] {
        func masked(
            _ id: String, _ email: String, _ state: String, _ description: String?, _ domain: String?,
            _ lastHoursAgo: Double?
        ) -> [String: JSONValue] {
            [
                "id": .string(id), "email": .string(email), "state": .string(state),
                "description": description.map(JSONValue.string) ?? .null,
                "forDomain": domain.map(JSONValue.string) ?? .null, "url": .null, "createdBy": "GoodMail",
                "createdAt": .string(date(hoursAgo: (lastHoursAgo ?? 2) + 5000, before: now)),
                "lastMessageAt": lastHoursAgo.map { .string(date(hoursAgo: $0, before: now)) } ?? .null,
            ]
        }
        return [
            masked("masked-1", "fjord.k3x9@fastmail.com", "enabled", "Fjord Outdoor newsletter", "https://fjord-outdoor.example", 3),
            masked("masked-2", "paperplane.x2m4@fastmail.com", "enabled", "Paperplane account", "https://paperplane.example", 30),
            masked("masked-3", "parcel.q8w1@fastmail.com", "enabled", "Parcel tracking", "https://shipfast.example", 52),
            masked("masked-4", "win.a7b2@fastmail.com", "disabled", "Prize draw at the hardware store", nil, 900),
            masked("masked-5", "forum.z5c3@fastmail.com", "deleted", "Old forum account", "https://oldforum.example", 4000),
            masked("masked-6", "quiet.harbor.1182@fastmail.com", "pending", nil, "https://newshop.example", nil),
        ]
    }

    /// The sample mail, received the given number of hours before `now`.
    static func emails(relativeTo now: Date) -> [[String: JSONValue]] {
        func email(
            _ id: String, thread: String, in mailbox: String, hoursAgo: Double, from: (String, String),
            to: (String, String) = ("Alex Berg", me), subject: String, seen: Bool = false, flagged: Bool = false,
            draft: Bool = false, text: String? = nil, html: String? = nil,
            attachments: [(name: String, type: String, size: Int)] = [], inlineLogo: Bool = false
        ) -> [String: JSONValue] {
            DemoData.email(
                id, thread: thread, in: mailbox, hoursAgo: hoursAgo, before: now, from: from, to: to, subject: subject,
                seen: seen, flagged: flagged, draft: draft, text: text, html: html, attachments: attachments,
                inlineLogo: inlineLogo)
        }
        return [
            email("e1", thread: "t1", in: "inbox", hoursAgo: 50, from: ("Maya Lindqvist", "maya@lindqvist.example"),
                  subject: "Trip to Lisbon", seen: true, text: """
                    Hi Alex,

                    I found flights for the first week of November: out on the 3rd, back on the 8th. \
                    Shall I book? The apartment in Alfama is still free too:
                    https://stays.example/alfama-loft?utm_source=share&utm_medium=email

                    Maya
                    """),
            email("e2", thread: "t1", in: "sent", hoursAgo: 47, from: ("Alex Berg", me), to: ("Maya Lindqvist", "maya@lindqvist.example"),
                  subject: "Re: Trip to Lisbon", seen: true, text: """
                    Yes, please book! The 3rd works. I'll take care of the apartment tonight.

                    > I found flights for the first week of November: out on the 3rd, back on the 8th.
                    """),
            email("e3", thread: "t1", in: "inbox", hoursAgo: 1.5, from: ("Maya Lindqvist", "maya@lindqvist.example"),
                  subject: "Re: Trip to Lisbon", text: """
                    Booked! Confirmation attached. We land at 11:40, so we could be at the apartment by one.

                    Can you ask the host about early check-in?
                    """, attachments: [("Flight confirmation.pdf", "application/pdf", 184_320)]),

            email("e4", thread: "t2", in: "inbox", hoursAgo: 3, from: ("Fjord Outdoor", "news@fjord-outdoor.example"),
                  to: ("", "fjord.k3x9@fastmail.com"), subject: "Autumn layers are here", html: """
                    <html><head><style>.cta{background:#14532d;color:#fff;padding:12px 22px;border-radius:6px;text-decoration:none}</style></head>
                    <body style="margin:0;background:#f4f1ea;font-family:Georgia,serif">
                    <table width="640" align="center" cellpadding="0" cellspacing="0" style="background:#ffffff">
                    <tr><td><img src="https://picsum.photos/seed/fjord/640/260" width="640" height="260" alt="Hikers on a ridge"></td></tr>
                    <tr><td style="padding:28px 36px">
                    <h1 style="margin:0 0 12px;font-size:28px;color:#14532d">Autumn layers are here</h1>
                    <p style="font-size:16px;line-height:1.5;color:#333">Merino base layers, windproof shells and our warmest fleece yet. \
                    Members get 15% off everything until Sunday.</p>
                    <p style="margin:28px 0"><a class="cta" href="https://fjord-outdoor.example/autumn?utm_source=newsletter&utm_medium=email&utm_campaign=autumn26&mc_eid=8f2a11">Shop the collection</a></p>
                    <p style="font-size:12px;color:#888">You receive this because you signed up at fjord-outdoor.example. \
                    <a href="https://fjord-outdoor.example/unsubscribe?u=8f2a11">Unsubscribe</a></p>
                    </td></tr></table>
                    <img src="https://fjord-outdoor.us7.list-manage.com/track/open.php?u=8f2a11&id=44" width="1" height="1">
                    <img src="https://stats.fjord-outdoor.example/o.gif?m=8f2a11" style="display:none">
                    </body></html>
                    """),

            email("e5", thread: "t3", in: "inbox", hoursAgo: 6, from: ("Northwind Hosting", "billing@northwind.example"),
                  subject: "Invoice 2041 for September", seen: true, html: """
                    <div style="font-family:Helvetica,Arial,sans-serif;max-width:520px">
                    <img src="cid:logo@northwind.example" width="160" height="40" alt="Northwind">
                    <p>Hello Alex,</p>
                    <p>your invoice for September is attached. The amount of <b>12.00 EUR</b> will be charged to your card ending in 4411.</p>
                    <table style="border-collapse:collapse;width:100%"><tr><td style="border-top:1px solid #ddd;padding:6px 0">VPS S, 1 month</td>
                    <td style="border-top:1px solid #ddd;padding:6px 0;text-align:right">12.00 EUR</td></tr></table>
                    <p>Thanks for hosting with us.</p></div>
                    """, attachments: [("Invoice-2041.pdf", "application/pdf", 61_440)], inlineLogo: true),

            email("e6", thread: "t4", in: "inbox", hoursAgo: 9, from: ("Jonas Weber", "jonas@weber.example"),
                  subject: "Standup notes", seen: true, flagged: true, text: """
                    Notes from today:

                    - Sync engine: change tracking works, conflicts still open
                    - Search: index size is fine, ranking needs work
                    - Release: aiming for the 14th

                    Shout if I missed something.
                    """),
            email("e7", thread: "t5", in: "inbox", hoursAgo: 30, from: ("Paperplane", "hello@paperplane.example"),
                  to: ("", "paperplane.x2m4@fastmail.com"), subject: "Welcome to Paperplane", seen: true, html: """
                    <div style="font-family:-apple-system,Helvetica,sans-serif"><h2>Welcome aboard</h2>
                    <p>Your account is ready. <a href="https://paperplane.example/start?utm_campaign=welcome&fbclid=abc123">Take the tour</a> \
                    or just start writing.</p>
                    <img src="https://paperplane.example/pixel.png" width="1" height="1" alt=""></div>
                    """),
            email("e8", thread: "t6", in: "inbox", hoursAgo: 52, from: ("ShipFast", "tracking@shipfast.example"),
                  to: ("", "parcel.q8w1@fastmail.com"), subject: "Your parcel is out for delivery", seen: true,
                  text: "Your parcel 00340434161094 is out for delivery today between 12:00 and 15:00.\n\nTrack it: https://shipfast.example/t/00340434161094"),
            email("e9", thread: "t7", in: "inbox", hoursAgo: 75, from: ("Priya Raman", "priya@raman.example"),
                  subject: "Book club: next pick?", seen: true,
                  text: "I'd vote for \"The Dispossessed\". Anyone against? Otherwise let's meet on the 21st at my place."),
            email("e10", thread: "t7", in: "inbox", hoursAgo: 70, from: ("Tomás Oliveira", "tomas@oliveira.example"),
                  subject: "Re: Book club: next pick?", seen: true, text: "Fine with me. I'll bring dessert."),
            email("e11", thread: "t8", in: "inbox", hoursAgo: 120, from: ("Fastmail", "security@fastmail.example"),
                  subject: "New API token created", seen: true,
                  text: "A new API token named \"GoodMail\" was created for your account. If this wasn't you, revoke it in Settings."),
            email("e12", thread: "t9", in: "archive", hoursAgo: 400, from: ("Lena Fischer", "lena@fischer.example"),
                  subject: "Apartment viewing on Saturday", seen: true, text: "Saturday at 10 works. See you there!"),
            email("e13", thread: "t10", in: "receipts", hoursAgo: 200, from: ("Corner Books", "orders@cornerbooks.example"),
                  subject: "Receipt for order 7731", seen: true, text: "Thanks for your order.\n\n1 x The Dispossessed    11.90 EUR"),
            email("e14", thread: "t11", in: "sent", hoursAgo: 26, from: ("Alex Berg", me), to: ("Lena Fischer", "lena@fischer.example"),
                  subject: "Keys", seen: true, text: "I left the spare keys with the neighbour on the second floor."),
            email("e15", thread: "t12", in: "drafts", hoursAgo: 2, from: ("Alex Berg", me), to: ("Alfama Loft", "host@stays.example"),
                  subject: "Early check-in on 3 November?", seen: true, draft: true,
                  text: "Hello, we land at 11:40 on the 3rd. Would it be possible to"),
            email("e16", thread: "t13", in: "junk", hoursAgo: 15, from: ("Prize Center", "winner@prizes.example"),
                  to: ("", "win.a7b2@fastmail.com"), subject: "You have been selected!!!",
                  html: "<p>Claim your prize now.</p><img src=\"https://prizes.example/t.gif\" width=\"1\" height=\"1\">"),
            email("e17", thread: "t14", in: "trash", hoursAgo: 90, from: ("Old Forum", "noreply@oldforum.example"),
                  subject: "We miss you", seen: true, text: "It has been a while since your last visit."),
        ]
    }

    static func email(
        _ id: String, thread: String, in mailbox: String, hoursAgo: Double, before now: Date, from: (String, String),
        to: (String, String) = ("Alex Berg", me), subject: String, seen: Bool = false, flagged: Bool = false,
        draft: Bool = false, text: String? = nil, html: String? = nil,
        attachments: [(name: String, type: String, size: Int)] = [], inlineLogo: Bool = false
    ) -> [String: JSONValue] {
        var keywords: [String: JSONValue] = [:]
        if seen { keywords["$seen"] = true }
        if flagged { keywords["$flagged"] = true }
        if draft { keywords["$draft"] = true }

        let body = html ?? text ?? ""
        let preview = (html == nil ? body : body.replacing(/<style.*?<\/style>|<[^>]+>/.dotMatchesNewlines(), with: " "))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var files: [JSONValue] = attachments.enumerated().map { index, file in
            [
                "partId": .null, "blobId": .string("\(id)-file\(index)"), "name": .string(file.name),
                "type": .string(file.type), "size": .number(Double(file.size)), "disposition": "attachment", "cid": .null,
            ]
        }
        if inlineLogo {
            files.append([
                "partId": .null, "blobId": .string("\(id)-logo"), "name": "logo.svg", "type": "image/svg+xml",
                "size": 420, "disposition": "inline", "cid": "logo@northwind.example",
            ])
        }
        func address(_ pair: (String, String)) -> JSONValue {
            [["name": pair.0.isEmpty ? .null : .string(pair.0), "email": .string(pair.1)]]
        }
        let received = date(hoursAgo: hoursAgo, before: now)
        return [
            "id": .string(id), "blobId": .string("\(id)-blob"), "threadId": .string(thread),
            "mailboxIds": [mailbox: true], "keywords": .object(keywords),
            "size": .number(Double(body.utf8.count)), "receivedAt": .string(received), "sentAt": .string(received),
            "from": address(from), "to": address(to), "cc": .null, "bcc": .null, "replyTo": .null, "sender": .null,
            "messageId": [.string("\(id)@demo")], "inReplyTo": .null, "references": .null,
            "subject": .string(subject), "preview": .string(String(preview.prefix(200))),
            "hasAttachment": .bool(!attachments.isEmpty),
            "htmlBody": [["partId": "1", "type": html == nil ? "text/plain" : "text/html"]],
            "textBody": [["partId": "1", "type": html == nil ? "text/plain" : "text/html"]],
            "bodyValues": ["1": ["value": .string(body), "isEncodingProblem": false, "isTruncated": false]],
            "attachments": .array(files),
        ]
    }
}
