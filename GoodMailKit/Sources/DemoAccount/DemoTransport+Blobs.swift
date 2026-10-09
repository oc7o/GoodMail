import CryptoKit
import Foundation
import JMAPKit

extension DemoTransport {
    /// How many uploads have been received.
    public var uploadCount: Int {
        store.withLock { $0.uploadCount }
    }

    /// Uploads that no email refers to vanish, as on Fastmail a day after the upload, so that creating an email
    /// with them fails with `blobNotFound`. Blobs an email refers to stay, as they do on Fastmail.
    public func expireUploads() {
        store.withLock { store in store.blobs = store.blobs.filter { $0.value.expires == nil } }
    }

    /// `POST /upload/{accountId}/` (RFC 8620 §6.1). Like Fastmail, the blob id is derived from the content, and
    /// an upload expires after 24 hours unless an email refers to it by then.
    func upload(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let data = request.httpBody ?? Data()
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let blobId = "G" + Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let expires = clock.now.addingTimeInterval(24 * 60 * 60)
        store.withLock { store in
            store.uploadCount += 1
            if let kept = store.blobs[blobId], kept.expires == nil { return }
            store.blobs[blobId] = Blob(data: data, type: type, expires: expires)
        }
        let answer: JSONValue = [
            "accountId": .string(Self.accountId), "blobId": .string(blobId), "type": .string(type),
            "size": .number(Double(data.count)), "expires": .string(expires.formatted(.iso8601)),
        ]
        return Self.reply(request.url!, status: 201, body: try! JSONEncoder().encode(answer))
    }

    /// `GET /download/{accountId}/{blobId}/{name}`.
    func download(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        let url = request.url!
        let blobId = url.pathComponents.dropFirst(4).first ?? ""
        let now = clock.now
        let blob = store.withLock { store -> (data: Data, type: String)? in
            guard let blob = store.blob(blobId, now: now) else { return nil }
            store.downloadCount += 1
            return blob
        }
        guard let blob else { return Self.reply(url, status: 404) }
        return Self.reply(url, body: blob.data, type: blob.type, headers: ["Content-Length": String(blob.data.count)])
    }
}

extension DemoTransport.Store {
    /// A blob of the account: an upload that hasn't expired, an attachment of the sample mail, or the message an
    /// email is.
    func blob(_ blobId: String, now: Date) -> (data: Data, type: String)? {
        if let blob = blobs[blobId], blob.expires.map({ $0 > now }) ?? true { return (blob.data, blob.type) }
        // An attachment of the sample mail is gone with the last email that has it.
        if let blob = DemoMessages.staticBlob(blobId) { return refersToAttachment(blobId) ? blob : nil }
        guard let email = emails.first(where: { $0["blobId"] == .string(blobId) }) else { return nil }
        let message = DemoMessages.message(
            email, headers: headers[DemoTransport.string(email["id"])] ?? [], blob: { blob($0, now: now)?.data })
        return (message, "message/rfc822")
    }

    private func refersToAttachment(_ blobId: String) -> Bool {
        emails.contains { email in
            DemoMessages.objects(email["attachments"]).contains { $0["blobId"] == .string(blobId) }
        }
    }
}
