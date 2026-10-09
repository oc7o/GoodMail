import Foundation
import Testing
import JMAPKit

struct EmailTests {
    @Test func inlineImagesAreCidImagesListedOncePerBlob() throws {
        let email = try JMAPCoding.makeDecoder().decode(Email.self, from: Data("""
            {"id": "e1", "htmlBody": [
               {"partId": "1", "type": "text/html"},
               {"partId": "2", "blobId": "b-logo", "type": "image/png", "cid": "logo@x", "size": 420}],
             "attachments": [
               {"blobId": "b-logo", "type": "image/png", "cid": "logo@x", "disposition": "inline"},
               {"blobId": "b-chart", "type": "IMAGE/SVG+XML", "cid": "chart@x", "disposition": "inline"},
               {"blobId": "b-pdf", "type": "application/pdf", "cid": "invoice@x", "disposition": "inline"},
               {"blobId": "b-photo", "type": "image/jpeg", "disposition": "attachment"}]}
            """.utf8))

        #expect(email.inlineImageParts.map(\.blobId) == ["b-logo", "b-chart"])
        #expect(email.inlineImagePart(cid: "chart@x")?.blobId == "b-chart")
        #expect(email.inlineImagePart(cid: "invoice@x") == nil)
        #expect(email.inlineImagePart(cid: "missing@x") == nil)
    }
}
