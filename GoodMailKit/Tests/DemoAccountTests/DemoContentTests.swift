import Foundation
import JMAPKit
import PDFKit
import Testing
@testable import DemoAccount

/// What the demo account holds: its sample mail and its header fields, blobs, uploads and session.
struct DemoContentTests {
    let clock = DemoClock(manualStart: DemoAccountTests.start)
    let server: DemoTransport
    let client: JMAPClient

    init() {
        server = DemoTransport(clock: clock)
        client = JMAPClient(token: "demo", transport: server, maxRetries: 0)
    }

    @Test func sampleMailIsUnchanged() async throws {
        let emails = try await client.emailPage(limit: 100).emails

        #expect(Dictionary(uniqueKeysWithValues: emails.map { ($0.id, $0.threadId ?? "") }) == [
            "e1": "t1", "e2": "t1", "e3": "t1", "e4": "t2", "e5": "t3", "e6": "t4", "e7": "t5", "e8": "t6", "e9": "t7",
            "e10": "t7", "e11": "t8", "e12": "t9", "e13": "t10", "e14": "t11", "e15": "t12", "e16": "t13", "e17": "t14",
        ])
        #expect(emails.first?.id == "e3")
        #expect(emails.first?.receivedAt == clock.now.addingTimeInterval(-1.5 * 3600))
    }

    @Test func sessionAnnouncesFastmailsLimits() async throws {
        let session = try await client.session()

        #expect(session.canSubmit)
        #expect(session.coreCapabilities?.maxSizeUpload == 250_000_000)
        #expect(session.coreCapabilities?.maxSizeRequest == 10_000_000)
        #expect(session.mailCapabilities(accountId: "demo")?.maxSizeAttachmentsPerEmail == 50_000_000)
        #expect(session.submissionCapabilities(accountId: "demo")
            == SubmissionAccountCapabilities(maxDelayedSend: 44_236_800, submissionExtensions: [:]))
    }

    // MARK: Header fields

    @Test func newsletterCarriesItsListHeaders() async throws {
        let headers = try #require(try await client.unsubscribeHeaders(emailID: "e4"))

        #expect(headers.listUnsubscribe == [[
            DemoTransport.oneClickUnsubscribeURL.absoluteString,
            "mailto:unsubscribe@fjord-outdoor.example?subject=unsubscribe%208f2a11",
        ]])
        #expect(headers.listUnsubscribePost == ["List-Unsubscribe=One-Click"])
        #expect(headers.listId == "Fjord Outdoor News <news.fjord-outdoor.example>")
        #expect(headers.dkimSignatures.count == 1)

        // Fastmail's layout: three verdicts of its MX above the Received field with which the MX accepted the
        // message, the DKIM one not on top, and a Fastmail-looking verdict below, which came with the message.
        let names = headers.headers.map(\.name)
        let arrival = try #require(headers.headers.firstIndex { $0.value.contains("by phl-mx-03.messagingengine.com (Postfix)") })
        #expect(names[..<arrival].filter { $0 == "Authentication-Results" }.count == 3)
        #expect(names[arrival...].filter { $0 == "Authentication-Results" }.count == 1)
        #expect(headers.headers.allSatisfy { $0.value.hasPrefix(" ") })
        #expect(headers.headers.last?.name == "Message-ID")
        #expect(headers.authenticationResults.count == 4)
        #expect(headers.authenticationResults.allSatisfy { $0.contains("messagingengine.com;") })
        #expect(headers.authenticationResults.first?.contains("dkim=") == false)

        // Its dkim=pass pairs with a signature covering both fields.
        let results = headers.authenticationResults[2]
        #expect(results.hasPrefix("phl-mx-03.messagingengine.com;"))
        #expect(results.contains("dkim=pass"))
        #expect(results.contains("header.d=fjord-outdoor.example"))
        let headerB = String(try #require(results.firstMatch(of: /header\.b=([^\s;]+)/)).output.1)
        let raw = try #require(headers.dkimSignatures.first)
        #expect(raw.hasPrefix(" v=1;"))
        #expect(raw.contains("\r\n\t"))
        let signature = raw.filter { !$0.isWhitespace }
        #expect(signature.contains(";d=fjord-outdoor.example;"))
        #expect(signature.contains(";h=from:to:subject:list-unsubscribe:list-unsubscribe-post;"))
        let b = String(try #require(signature.firstMatch(of: /;b=([^;]+)/)).output.1)
        #expect(headerB.count >= 8)
        #expect(b.hasPrefix(headerB))
    }

    @Test func emailsTellWhereTheyWereDelivered() async throws {
        let emails = try await client.emails(ids: ["e4", "e7", "e8", "e1"])

        #expect(emails.map(\.deliveredToAddresses) == [
            [EmailAddress(email: "fjord.k3x9@fastmail.com")], [EmailAddress(email: "paperplane.x2m4@fastmail.com")],
            [EmailAddress(email: "parcel.q8w1@fastmail.com")], [],
        ])
        #expect(emails[0].listUnsubscribe?.count == 2)
        #expect(emails[0].listUnsubscribePost == "List-Unsubscribe=One-Click")
        #expect(emails[0].listId == "Fjord Outdoor News <news.fjord-outdoor.example>")
        #expect(emails[3].listUnsubscribe == nil)
        #expect(emails[3].listId == nil)
    }

    @Test func headerFilterFindsByPresenceAndText() async throws {
        func ids(_ header: [String]) async throws -> [String] {
            var batch = Batch()
            let query = batch.add(EmailQuery(accountId: "demo", filter: .condition(.init(header: header))))
            return try await client.send(batch).get(query).ids
        }

        #expect(try await ids(["List-Unsubscribe-Post"]) == ["e4"])
        #expect(try await ids(["X-Delivered-To", "PARCEL"]) == ["e8"])
        #expect(try await ids(["Message-ID", "e12@demo"]) == ["e12"])
        #expect(try await ids(["Subject", "book club"]) == ["e10", "e9"])
        #expect(try await ids(["From", "Tomás"]) == ["e10"])
    }

    // MARK: Blobs

    @Test func attachmentsAreRealPDFs() async throws {
        let confirmation = try await client.download(blobId: "e3-file0", type: "application/pdf", name: "Flight confirmation.pdf")
        let invoice = try await client.download(blobId: "e5-file0", type: "application/pdf", name: "Invoice-2041.pdf")

        #expect(confirmation.count == 184_320)
        #expect(invoice.count == 61_440)
        let confirmationPDF = try #require(PDFDocument(data: confirmation))
        let invoicePDF = try #require(PDFDocument(data: invoice))
        #expect(confirmationPDF.pageCount == 1)
        #expect(confirmationPDF.string?.contains("Flight confirmation") == true)
        #expect(invoicePDF.string?.contains("Invoice 2041") == true)
        #expect(server.downloadCount == 2)
    }

    @Test func logoIsTheSameSVG() async throws {
        let logo = try await client.download(blobId: "e5-logo", type: "image/svg+xml", name: "logo.svg")

        #expect(String(decoding: logo, as: UTF8.self) == DemoData.logo)
    }

    @Test func emailsBlobIsTheWholeMessage() async throws {
        let newsletter = String(decoding: try await client.download(blobId: "e4-blob", type: "message/rfc822", name: "e4.eml"),
                                as: UTF8.self)
        let invoice = String(decoding: try await client.download(blobId: "e5-blob", type: "message/rfc822", name: "e5.eml"),
                             as: UTF8.self)

        #expect(newsletter.hasPrefix("Received: from phl-compute-04.internal (phl-compute-04.internal [10.202.2.44])\r\n"))
        #expect(newsletter.contains("\r\nX-Delivered-To: fjord.k3x9@fastmail.com\r\n"))
        #expect(newsletter.contains("\r\nAuthentication-Results: phl-mx-03.messagingengine.com;\r\n"))
        #expect(newsletter.contains("\r\nList-Unsubscribe-Post: List-Unsubscribe=One-Click\r\n"))
        #expect(newsletter.contains("\r\nFrom: Fjord Outdoor <news@fjord-outdoor.example>\r\n"))
        #expect(newsletter.contains("\r\nSubject: Autumn layers are here\r\n"))
        #expect(newsletter.contains("\r\nMessage-ID: <e4@demo>\r\n"))
        #expect(newsletter.contains("\r\nContent-Type: text/html; charset=utf-8\r\n"))
        #expect(invoice.contains("multipart/mixed"))
        #expect(invoice.contains("multipart/related"))
        #expect(invoice.contains("\r\nContent-ID: <logo@northwind.example>\r\n"))
        #expect(invoice.contains("\r\nContent-Disposition: attachment; filename=\"Invoice-2041.pdf\"\r\n"))
        #expect(invoice.contains(DemoMessages.invoice.prefix(57).base64EncodedString()))

        let reply = String(decoding: try await client.download(blobId: "e10-blob", type: "message/rfc822", name: "e10.eml"),
                           as: UTF8.self)
        let name = Data("Tomás Oliveira".utf8).base64EncodedString()
        #expect(reply.hasPrefix("From: =?UTF-8?B?\(name)?= <tomas@oliveira.example>\r\n"))
    }

    @Test func blobsOfDeletedMailAreGone() async throws {
        server.destroyEmail(id: "e5")

        await #expect(throws: JMAPError.http(status: 404, problemType: nil)) {
            try await client.download(blobId: "e5-file0", type: "application/pdf", name: "x.pdf")
        }
        await #expect(throws: JMAPError.http(status: 404, problemType: nil)) {
            try await client.download(blobId: "e5-blob", type: "message/rfc822", name: "x.eml")
        }
    }

    @Test func downloadStreamsInChunks() async throws {
        let download = try await client.downloadStream(blobId: "e3-file0", type: "application/pdf", name: "x.pdf")
        var chunks: [Data] = []
        for try await chunk in download.chunks { chunks.append(chunk) }

        #expect(download.expectedLength == 184_320)
        #expect(chunks.map(\.count) == [65_536, 65_536, 53_248])
        #expect(chunks.reduce(Data(), +) == DemoMessages.flightConfirmation)
    }

    @Test func uploadIsAnsweredLikeFastmail() async throws {
        let uploaded = try await client.upload(Data("hello".utf8), type: "text/plain")

        #expect(uploaded == UploadedBlob(
            accountId: "demo", blobId: "Gaaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d", type: "text/plain", size: 5,
            expires: clock.now.addingTimeInterval(86_400)))
        #expect(server.uploadCount == 1)
        #expect(try await client.download(blobId: uploaded.blobId, type: "text/plain", name: "a.txt") == Data("hello".utf8))
    }

    @Test func forwardedAttachmentsAndMessagesAreReferencedByBlob() async throws {
        let body = EmailCreate.body(text: "FYI", html: "<div>FYI</div>", inline: [], attachments: [
            .blob("e5-file0", type: "application/pdf", name: "Invoice-2041.pdf", disposition: "attachment"),
            .blob("e4-blob", type: "message/rfc822", name: "Autumn layers are here.eml", disposition: "attachment"),
        ])
        let forward = EmailCreate(
            mailboxIds: ["drafts": true], keywords: ["$draft": true], messageId: ["fwd@fastmail.com"],
            from: [EmailAddress(email: "alex@fastmail.com")], to: [], subject: "Fwd: Invoice", sentAt: clock.now,
            bodyStructure: body.structure, bodyValues: body.values)

        let id = try #require(try await client.saveDraft(forward, replacing: nil).createdID)

        let saved = try #require(try await client.emails(ids: [id]).first)
        #expect(saved.attachments?.map(\.blobId) == ["e5-file0", "e4-blob"])
        #expect(saved.attachments?.first?.size == 61_440)
        #expect(saved.attachments?.last?.type == "message/rfc822")
        #expect(saved.hasAttachment == true)
        #expect(saved.textBody?.map(\.partId) == ["text"])
    }

    // MARK: One-click unsubscribe

    @Test func oneClickRequestIsRecorded() async throws {
        var request = URLRequest(url: DemoTransport.oneClickUnsubscribeURL)
        request.httpMethod = "POST"
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await server.send(request)
        let (_, elsewhere) = try await server.send(URLRequest(url: URL(string: "https://fjord-outdoor.example/other")!))

        #expect(response.statusCode == 200)
        #expect(elsewhere.statusCode == 404)
        #expect(server.oneClickRequests.map(\.httpBody) == [Data("List-Unsubscribe=One-Click".utf8)])
        #expect(server.oneClickRequests.first?.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }
}
