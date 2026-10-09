import Foundation
import Testing
@testable import JMAPKit

struct BlobTransferTests {
    let transport = StubTransport()

    func makeClient() -> JMAPClient {
        JMAPClient(token: "secret", transport: transport, retryDelay: { _ in .zero })
    }

    // MARK: Upload

    @Test func uploadPostsTheBytesToTheAccountsUploadURL() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: 201, body: Data(#"""
            {"accountId": "u1234", "blobId": "G4f2a", "type": "application/pdf", "size": 4,
             "expires": "2026-10-10T14:03:00Z"}
            """#.utf8)))
        let bytes = Data("%PDF".utf8)

        let uploaded = try await makeClient().upload(bytes, type: "application/pdf")

        #expect(uploaded == UploadedBlob(
            accountId: "u1234", blobId: "G4f2a", type: "application/pdf", size: 4,
            expires: Date(timeIntervalSince1970: 1_791_554_580 + 86_400)))
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString == "https://api.fastmail.com/jmap/upload/u1234/")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == bytes)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func uploadWithoutExpiryIsAccepted() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: 200, body: Data(#"""
            {"accountId": "u1234", "blobId": "G1", "type": "image/png", "size": 2}
            """#.utf8)))

        let uploaded = try await makeClient().upload(Data([0x89, 0x50]), type: "image/png")

        #expect(uploaded.expires == nil)
    }

    @Test func uploadTooLargeIsRefused() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(status: 413, body: Data(#"{"type": "urn:ietf:params:jmap:error:limit", "limit": "maxSizeUpload"}"#.utf8)))

        await #expect(throws: JMAPError.http(status: 413, problemType: JMAPError.limitProblemType)) {
            try await makeClient().upload(Data(count: 8), type: "application/octet-stream")
        }
    }

    // MARK: Download

    @Test func downloadStreamHandsOverChunksAsTheyArrive() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream(headers: ["Content-Type": "application/pdf", "Content-Length": "11"], sending: "%PDF-", "1.4")
        transport.enqueue(stream)

        let download = try await makeClient().downloadStream(blobId: "b1", type: "application/pdf", name: "a b.pdf")
        var chunks = download.chunks.makeAsyncIterator()
        #expect(try await chunks.next() == Data("%PDF-".utf8))
        #expect(try await chunks.next() == Data("1.4".utf8))
        stream.send("\n%%EOF")
        #expect(try await chunks.next() == Data("\n%%EOF".utf8))
        stream.finish()
        #expect(try await chunks.next() == nil)

        #expect(download.expectedLength == 11)
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString
            == "https://www.fastmailusercontent.com/jmap/download/u1234/b1/a%20b.pdf?type=application%2Fpdf")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/pdf")
        #expect(request.allowsConstrainedNetworkAccess)
    }

    @Test func downloadStreamWithoutLengthHasNone() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream(headers: ["Content-Type": "image/png"], sending: "png")
        stream.finish()
        transport.enqueue(stream)

        let download = try await makeClient().downloadStream(blobId: "b1", type: "image/png", name: "x.png")
        var received = Data()
        for try await chunk in download.chunks { received += chunk }

        #expect(download.expectedLength == nil)
        #expect(received == Data("png".utf8))
    }

    @Test func downloadStreamRejectsATokenAndAMissingBlob() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(StubStream(status: 401, headers: [:]))
        let client = makeClient()
        await #expect(throws: JMAPError.unauthorized) {
            try await client.downloadStream(blobId: "b1", type: "image/png", name: "x.png")
        }

        let missing = StubStream(status: 404, headers: ["Content-Type": "application/problem+json"],
                                 sending: #"{"type": "about:blank", "status": 404}"#)
        missing.finish()
        transport.enqueue(missing)
        await #expect(throws: JMAPError.http(status: 404, problemType: "about:blank")) {
            try await client.downloadStream(blobId: "gone", type: "image/png", name: "x.png")
        }
    }

    @Test func droppedDownloadFailsWithTheConnectionError() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream(headers: ["Content-Type": "application/pdf"], sending: "%PDF")
        stream.finish(throwing: URLError(.networkConnectionLost))
        transport.enqueue(stream)

        let download = try await makeClient().downloadStream(blobId: "b1", type: "application/pdf", name: "x.pdf")
        var received = Data()
        let error = await #expect(throws: JMAPError.self) {
            for try await chunk in download.chunks { received += chunk }
        }

        #expect(received == Data("%PDF".utf8))
        #expect(error == .connection(.networkConnectionLost, URLError(.networkConnectionLost).localizedDescription))
        #expect(error?.mayHaveReachedServer == true)
    }

    @Test func stoppingToReadCancelsTheDownload() async throws {
        transport.enqueue(fixture: "session")
        let stream = StubStream(headers: ["Content-Type": "application/pdf"], sending: "%PDF")
        transport.enqueue(stream)

        do {
            let download = try await makeClient().downloadStream(blobId: "b1", type: "application/pdf", name: "x.pdf")
            for try await _ in download.chunks { break }
        }

        #expect(await eventually { stream.wasCancelled })
    }

    @Test func downloadsCanStayOffConstrainedNetworks() async throws {
        transport.enqueue(fixture: "session")
        transport.enqueue(.init(body: Data([1])))
        let stream = StubStream(sending: "x")
        stream.finish()
        transport.enqueue(stream)
        let client = makeClient()

        _ = try await client.download(blobId: "b1", type: "image/png", name: "x.png", allowsConstrainedNetworkAccess: false)
        #expect(transport.requests.last?.allowsConstrainedNetworkAccess == false)
        _ = try await client.downloadStream(blobId: "b1", type: "image/png", name: "x.png", allowsConstrainedNetworkAccess: false)
        #expect(transport.requests.last?.allowsConstrainedNetworkAccess == false)
    }
}
