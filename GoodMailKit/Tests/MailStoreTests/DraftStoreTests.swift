import Foundation
import GRDB
import JMAPKit
import Testing
@testable import MailStore

/// Drafts, the outbox rows they become, and the attachments added to them.
struct DraftStoreTests {
    let clock = StoreTestClock()
    let store: MailStore

    init() throws {
        store = try MailStore(now: clock.reading)
    }

    private func content(_ text: String) -> Data { Data(text.utf8) }

    private func newDraft(_ id: String = "d1") async throws {
        try await store.saveDraftContent(id: id, content: content(id), messageID: "\(id)@example.com")
    }

    // MARK: Drafts

    @Test func savingTheContentCountsRevisions() async throws {
        #expect(try await store.saveDraftContent(id: "d1", content: content("one"), messageID: "m1@example.com") == 1)
        clock.advance(seconds: 5)
        #expect(try await store.saveDraftContent(id: "d1", content: content("two"), messageID: "m2@example.com") == 2)

        #expect(try await store.draft(id: "d1") == StoredDraft(
            id: "d1", revision: 2, content: content("two"), messageID: "m2@example.com", updatedAt: clock.now))
        #expect(try await store.draft(id: "d2") == nil)
    }

    @Test func savingCanQueueTheMessageInTheSameTransaction() async throws {
        try await store.saveDraftContent(id: "d1", content: content("draft"), messageID: "m1@example.com")
        clock.advance(seconds: 10)
        let queuedAt = clock.now

        try await store.saveDraftContent(id: "d1", content: content("final"), messageID: "m1@example.com", state: .queued)

        var draft = try #require(try await store.draft(id: "d1"))
        #expect(draft.content == content("final") && draft.state == .queued && draft.queuedAt == queuedAt)

        // Saved again while waiting, it keeps its place in the outbox.
        clock.advance(seconds: 10)
        try await store.saveDraftContent(id: "d1", content: content("final!"), messageID: "m1@example.com", state: .queued)
        draft = try #require(try await store.draft(id: "d1"))
        #expect(draft.queuedAt == queuedAt && draft.revision == 3)

        // Saving without a state leaves it alone.
        try await store.saveDraftContent(id: "d1", content: content("final!!"), messageID: "m1@example.com")
        #expect(try await store.draft(id: "d1")?.state == .queued)

        try await store.saveDraftContent(id: "d1", content: content("edit"), messageID: "m1@example.com", state: .editing)
        draft = try #require(try await store.draft(id: "d1"))
        #expect(draft.state == .editing && draft.queuedAt == nil)

        try await store.saveDraftContent(id: "d2", content: content("now"), messageID: "m2@example.com", state: .queued)
        #expect(try await store.draft(id: "d2")?.queuedAt == clock.now)
    }

    @Test func updatesAreAtomic() async throws {
        try await newDraft()
        let store = store

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = try await store.updateDraft(id: "d1") { $0.serverRevision = ($0.serverRevision ?? 0) + 1 }
                }
            }
            try await group.waitForAll()
        }

        #expect(try await store.draft(id: "d1")?.serverRevision == 50)
    }

    @Test func updatesStampTheTimeUnlessTheyChangeNothingOrSetItThemselves() async throws {
        try await newDraft()
        let saved = try #require(try await store.draft(id: "d1"))
        clock.advance(seconds: 60)

        #expect(try await store.updateDraft(id: "d1") { _ in } == saved)

        let failed = try await store.updateDraft(id: "d1") { draft in
            draft.state = .failed
            draft.outbox = Data(#"{"failure":"refused"}"#.utf8)
        }
        #expect(failed?.state == .failed && failed?.updatedAt == clock.now)
        #expect(try await store.draft(id: "d1") == failed)

        let stamp = Date(timeIntervalSince1970: 1_790_000_000)
        let saving = try await store.updateDraft(id: "d1") { draft in
            draft.serverEmailID = "M1"
            draft.serverRevision = draft.revision
            draft.updatedAt = stamp
        }
        #expect(saving?.updatedAt == stamp)
        #expect(try await store.draft(serverEmailID: "M1")?.id == "d1")
        #expect(try await store.draft(serverEmailID: "M2") == nil)
        #expect(try await store.updateDraft(id: "d9") { $0.state = .queued } == nil)
    }

    @Test func emptyContentAndOutboxRecordsStayEmptyRatherThanMissing() async throws {
        try await store.saveDraftContent(id: "d1", content: Data(), messageID: "m1@example.com")
        let draft = try await store.updateDraft(id: "d1") { $0.outbox = Data() }
        #expect(draft?.content == Data() && draft?.outbox == Data())
        #expect(try await store.updateDraft(id: "d1") { $0.outbox = nil }?.outbox == nil)
    }

    @Test func draftsAreListedInOutboxOrder() async throws {
        for id in ["d1", "d2", "d3", "d4"] {
            try await newDraft(id)
            clock.advance(seconds: 1)
        }
        try await store.saveDraftContent(id: "d3", content: content("d3"), messageID: "d3@example.com", state: .queued)
        clock.advance(seconds: 1)
        try await store.saveDraftContent(id: "d1", content: content("d1"), messageID: "d1@example.com", state: .queued)
        try await store.updateDraft(id: "d1") { $0.state = .held }
        try await store.updateDraft(id: "d4") { $0.state = .failed }

        #expect(try await store.drafts().map(\.id) == ["d3", "d1", "d2", "d4"])
        #expect(try await store.drafts(in: [.queued, .held]).map(\.id) == ["d3", "d1"])
        #expect(try await store.drafts(in: [.editing]).map(\.id) == ["d2"])
        #expect(try await store.drafts(in: []).isEmpty)
    }

    @Test func resettingTheEmailsKeepsDrafts() async throws {
        try await newDraft()
        _ = try await store.addOutgoingAttachment(Data([1]), id: "a1", draftID: "d1", name: "a.txt", type: "text/plain")

        try await store.resetEmails()

        #expect(try await store.draft(id: "d1") != nil)
        #expect(try await store.outgoingAttachmentData(id: "a1") == Data([1]))
    }

    // MARK: Attachments

    @Test func attachmentsGoWithTheirDraft() async throws {
        try await newDraft("d1")
        try await newDraft("d2")
        let first = try await store.addOutgoingAttachment(
            Data([1, 2, 3]), id: "a1", draftID: "d1", name: "one.txt", type: "text/plain")
        _ = try await store.addOutgoingAttachment(Data([4]), id: "a2", draftID: "d1", name: "two.txt", type: "text/plain")
        _ = try await store.addOutgoingAttachment(Data([5]), id: "b1", draftID: "d2", name: "other.txt", type: "text/plain")
        #expect(first == OutgoingAttachment(
            id: "a1", draftID: "d1", position: 0, name: "one.txt", type: "text/plain", size: 3, hasBytes: true))

        // Saving the content again keeps them: the row is updated, never replaced.
        try await store.saveDraftContent(id: "d1", content: content("sent"), messageID: "d1@example.com", state: .queued)
        #expect(try await store.outgoingAttachments(draftID: "d1").map(\.id) == ["a1", "a2"])
        #expect(try await store.outgoingAttachments(draftID: "d1").map(\.position) == [0, 1])

        try await store.deleteDraft(id: "d1")

        #expect(try await store.draft(id: "d1") == nil)
        #expect(try await store.outgoingAttachments(draftID: "d1").isEmpty)
        await #expect(throws: MailStoreError.outgoingBytesMissing("a1")) { try await store.outgoingAttachmentData(id: "a1") }
        #expect(try await store.chunkSizes(of: MailStore.outgoingKey("a2")).isEmpty)
        #expect(try await store.outgoingAttachmentData(id: "b1") == Data([5]))
    }

    @Test func largeFilesAreImportedInChunks() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: "Scan.pdf")
        let data = StoreFixtures.randomData((3 << 20) + 12_345)
        try data.write(to: file)
        try await newDraft()
        let note = try await store.addOutgoingAttachment(Data([1]), id: "a0", draftID: "d1", name: "note.txt", type: "text/plain")

        let scan = try await store.importOutgoingAttachment(
            from: file, id: "a1", draftID: "d1", name: "Scan.pdf", type: "application/pdf")

        #expect(scan == OutgoingAttachment(
            id: "a1", draftID: "d1", position: 1, name: "Scan.pdf", type: "application/pdf", size: data.count,
            hasBytes: true))
        #expect(try await store.chunkSizes(of: MailStore.outgoingKey("a1")) == [1 << 20, 1 << 20, 1 << 20, 12_345])
        #expect(try await store.outgoingAttachmentData(id: "a1") == data)
        #expect(try await store.outgoingAttachments(draftID: "d1") == [note, scan])
    }

    @Test func uploadsAreRecordedAndForgottenWhenTheyExpire() async throws {
        try await newDraft()
        _ = try await store.addOutgoingAttachment(Data([1]), id: "a1", draftID: "d1", name: "a.txt", type: "text/plain")
        func attachment() async throws -> OutgoingAttachment {
            try #require(try await store.outgoingAttachments(draftID: "d1").first)
        }
        clock.advance(seconds: 30)

        try await store.markOutgoingAttachmentUploaded(id: "a1", blobID: "G1", expiresAt: nil)
        var uploaded = try await attachment()
        #expect(uploaded.blobID == "G1" && uploaded.uploadedAt == clock.now)
        #expect(uploaded.expiresAt == clock.now.addingTimeInterval(3600))

        let expiry = clock.now.addingTimeInterval(86_400)
        try await store.markOutgoingAttachmentUploaded(id: "a1", blobID: "G2", expiresAt: expiry)
        uploaded = try await attachment()
        #expect(uploaded.blobID == "G2" && uploaded.expiresAt == expiry)

        try await store.markOutgoingAttachmentExpired(id: "a1")
        let expired = try await attachment()
        #expect(expired.blobID == nil && expired.uploadedAt == nil && expired.expiresAt == nil && expired.hasBytes)

        // Adding the same id again replaces the bytes, keeps the place, and forgets the upload.
        try await store.markOutgoingAttachmentUploaded(id: "a1", blobID: "G3", expiresAt: nil)
        let replaced = try await store.addOutgoingAttachment(Data([2, 2]), id: "a1", draftID: "d1", name: "b.txt", type: "text/plain")
        #expect(replaced == OutgoingAttachment(
            id: "a1", draftID: "d1", position: 0, name: "b.txt", type: "text/plain", size: 2, hasBytes: true))
        #expect(try await store.outgoingAttachmentData(id: "a1") == Data([2, 2]))

        try await store.deleteOutgoingAttachment(id: "a1")
        #expect(try await store.outgoingAttachments(draftID: "d1").isEmpty)
        #expect(try await store.blobRowCounts() == (0, 0))
    }

    @Test func attachingToADraftThatDoesntExistKeepsNothing() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let file = folder.url.appending(path: "a.txt")
        try Data("hello".utf8).write(to: file)

        await #expect(throws: MailStoreError.draftNotFound("d9")) {
            try await store.addOutgoingAttachment(Data([1]), id: "a1", draftID: "d9", name: "a.txt", type: "text/plain")
        }
        await #expect(throws: MailStoreError.draftNotFound("d9")) {
            try await store.importOutgoingAttachment(from: file, id: "a2", draftID: "d9", name: "a.txt", type: "text/plain")
        }
        #expect(try await store.blobRowCounts() == (0, 0))
    }

    @Test func maintenanceSweepsOrphansInBothDirections() async throws {
        try await newDraft()
        for (id, byte) in [("kept", 1), ("orphan", 2), ("lost", 3)] {
            _ = try await store.addOutgoingAttachment(Data([UInt8(byte)]), id: id, draftID: "d1", name: id, type: "text/plain")
        }
        // As if the app quit between the two halves of an add or a delete.
        try await store.writer.write { db in
            try db.execute(sql: "DELETE FROM outgoingAttachment WHERE id = 'orphan'")
        }
        try await store.blobs.delete(keys: [MailStore.outgoingKey("lost")], kind: .outgoing)
        clock.advance(seconds: 2 * 3600)
        // Bytes of an attachment still being added.
        try await store.blobs.store(
            Data([4]), key: MailStore.outgoingKey("adding"), kind: .outgoing, type: "text/plain", evictingBeyond: nil)

        try await store.maintainFully()

        #expect(try await store.chunkSizes(of: MailStore.outgoingKey("orphan")).isEmpty)
        #expect(try await store.chunkSizes(of: MailStore.outgoingKey("adding")) == [1])
        let attachments = try await store.outgoingAttachments(draftID: "d1")
        #expect(attachments.map(\.id) == ["kept", "lost"])
        #expect(attachments.map(\.hasBytes) == [true, false])
        await #expect(throws: MailStoreError.outgoingBytesMissing("lost")) { try await store.outgoingAttachmentData(id: "lost") }
    }

    @Test func outgoingBytesAreMissingAfterTheBlobFileWasReset() async throws {
        let folder = StoreFolder()
        defer { folder.remove() }
        let key = StoreFixtures.randomKey()
        do {
            let store = try MailStore(url: folder.storeURL) { key }
            try await store.saveDraftContent(id: "d1", content: content("x"), messageID: "m1@example.com", state: .queued)
            _ = try await store.addOutgoingAttachment(Data([1, 2, 3]), id: "a1", draftID: "d1", name: "a.txt", type: "text/plain")
            try await store.markOutgoingAttachmentUploaded(id: "a1", blobID: "G1", expiresAt: nil)
        }
        try StoreFixtures.randomData(64 << 10).write(to: folder.blobURL)

        let store = try MailStore(url: folder.storeURL) { key }

        #expect(store.blobStoreWasReset)
        #expect(try await store.draft(id: "d1")?.state == .queued)
        let attachment = try #require(try await store.outgoingAttachments(draftID: "d1").first)
        #expect(!attachment.hasBytes)
        // The upload may still be usable even though the bytes are gone.
        #expect(attachment.blobID == "G1")
        await #expect(throws: MailStoreError.outgoingBytesMissing("a1")) { try await store.outgoingAttachmentData(id: "a1") }
    }
}
