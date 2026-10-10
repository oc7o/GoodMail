import GoodMailCore

/// The reading pane's attachment strip works on the account's attachment store (C12). Only the progress type
/// differs: the components keep their own, since they don't depend on GoodMailCore.
extension AttachmentCenter: AttachmentActions {
    func attachmentProgress(blobId: String) -> AttachmentProgress? {
        progress(blobId: blobId).map { AttachmentProgress(received: $0.received, expected: $0.expected) }
    }
}
