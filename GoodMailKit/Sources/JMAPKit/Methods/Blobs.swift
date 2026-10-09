import Foundation

/// A blob on its way down, chunk by chunk.
public struct BlobDownload: Sendable {
    /// The size the server announced, if it did.
    public let expectedLength: Int?
    /// Ends when the blob is complete and throws a `JMAPError` when the connection fails. Ending its iteration
    /// early cancels the download.
    public let chunks: AsyncThrowingStream<Data, any Error>

    public init(expectedLength: Int?, chunks: AsyncThrowingStream<Data, any Error>) {
        self.expectedLength = expectedLength
        self.chunks = chunks
    }
}

/// The server's answer to an upload (RFC 8620 §6.1).
public struct UploadedBlob: Decodable, Sendable, Equatable {
    public let accountId: String
    public let blobId: String
    public let type: String
    public let size: Int
    /// When the server deletes the blob unless an email refers to it by then; Fastmail says so, the RFC doesn't.
    public let expires: Date?

    public init(accountId: String, blobId: String, type: String, size: Int, expires: Date?) {
        self.accountId = accountId
        self.blobId = blobId
        self.type = type
        self.size = size
        self.expires = expires
    }
}

extension JMAPClient {
    /// Downloads a blob such as an attachment or inline image from the mail account.
    ///
    /// - Parameter allowsConstrainedNetworkAccess: Pass `false` for downloads that can wait until the device
    ///   is out of Low Data Mode, such as prefetching.
    public func download(
        blobId: String, type: String = "application/octet-stream", name: String = "blob",
        allowsConstrainedNetworkAccess: Bool = true
    ) async throws -> Data {
        try await perform(downloadRequest(
            blobId: blobId, type: type, name: name, allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess))
    }

    /// Starts downloading a blob and returns once the server answered, for blobs too large to hold in memory.
    public func downloadStream(
        blobId: String, type: String, name: String, allowsConstrainedNetworkAccess: Bool = true
    ) async throws -> BlobDownload {
        let request = try await downloadRequest(
            blobId: blobId, type: type, name: name, allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess)
        let (response, chunks) = try await performStreaming(request)
        let length = response.expectedContentLength
        return BlobDownload(expectedLength: length >= 0 ? Int(length) : nil, chunks: chunks)
    }

    /// Uploads `data` to the mail account, for referring to it by `blobId` from an email created afterwards.
    public func upload(_ data: Data, type: String) async throws -> UploadedBlob {
        let session = try await session()
        let accountId = try session.primaryAccountId(for: Capability.mail)
        guard let url = session.uploadURL(accountId: accountId) else {
            throw JMAPError.transport("Invalid upload URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let body = try await perform(request)
        do {
            return try JMAPCoding.makeDecoder().decode(UploadedBlob.self, from: body)
        } catch {
            throw JMAPError.decoding("Upload: \(error)")
        }
    }

    private func downloadRequest(
        blobId: String, type: String, name: String, allowsConstrainedNetworkAccess: Bool
    ) async throws -> URLRequest {
        let session = try await session()
        let accountId = try session.primaryAccountId(for: Capability.mail)
        guard let url = session.downloadURL(accountId: accountId, blobId: blobId, type: type, name: name) else {
            throw JMAPError.transport("Invalid download URL")
        }
        var request = URLRequest(url: url)
        request.setValue(type, forHTTPHeaderField: "Accept")
        request.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        return request
    }
}
