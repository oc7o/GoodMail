import Foundation
import JMAPKit

/// What another device signed in to the same account does, for the conflict and at-most-once tests.
extension DemoTransport {
    /// Another device sent the message with `messageID`: a copy of it shows up in Sent, no draft. If a draft with
    /// that Message-ID is on the server, the message is that draft as sent.
    public func sendFromAnotherDevice(messageID: String, subject: String) {
        let now = clock.now
        update { store in
            let draft = store.emails.first { DemoTransport.strings($0["messageId"]).contains(messageID) }
            let id = store.makeID("M")
            var email = draft ?? DemoData.email(
                id, thread: "", in: "sent", hoursAgo: 0, before: now, from: ("Alex Berg", DemoData.me),
                to: ("Maya Lindqvist", "maya@lindqvist.example"), subject: subject, text: "Sent from another device.")
            email["id"] = .string(id)
            email["blobId"] = .string("\(id)-blob")
            email["threadId"] = .string(draft.map { DemoTransport.string($0["threadId"]) } ?? store.makeID("T"))
            email["mailboxIds"] = ["sent": true]
            email["keywords"] = ["$seen": true]
            email["messageId"] = [.string(messageID)]
            email["subject"] = .string(subject)
            email["receivedAt"] = .string(now.formatted(.iso8601))
            store.emails.append(email)
            store.record(id, .created)
        }
    }

    /// Another device saved a new version of the draft `emailID`: it replaces the draft under a new id, with the
    /// same Message-ID and a changed text. Returns the new version's id, or `nil` if there is no such email.
    @discardableResult
    public func editDraftOnAnotherDevice(emailID: String) -> String? {
        let now = clock.now
        return update { store in
            guard let index = store.emails.firstIndex(where: { $0["id"] == .string(emailID) }) else { return nil }
            var email = store.emails.remove(at: index)
            let id = store.makeID("M")
            email["id"] = .string(id)
            email["blobId"] = .string("\(id)-blob")
            email["receivedAt"] = .string(now.formatted(.iso8601))
            if case .object(var values)? = email["bodyValues"] {
                let htmlParts = Set(DemoMessages.objects(email["htmlBody"]).map { DemoTransport.string($0["partId"]) })
                    .subtracting(DemoMessages.objects(email["textBody"]).map { DemoTransport.string($0["partId"]) })
                for (partId, value) in values {
                    guard case .object(var value) = value else { continue }
                    let addition = htmlParts.contains(partId)
                        ? "<div>Changed on another device.</div>" : "\n\nChanged on another device."
                    value["value"] = .string(DemoTransport.string(value["value"]) + addition)
                    values[partId] = .object(value)
                }
                email["bodyValues"] = .object(values)
            }
            store.emails.append(email)
            store.headers[id] = store.headers.removeValue(forKey: emailID)
            store.record(emailID, .destroyed)
            store.record(id, .created)
            return id
        }
    }

    /// Another device moved the email to Trash, as Fastmail's web app does when a draft is deleted.
    public func moveToTrash(emailID: String) {
        update { store in
            guard let index = store.emails.firstIndex(where: { $0["id"] == .string(emailID) }) else { return }
            store.emails[index]["mailboxIds"] = ["trash": true]
            store.record(emailID, .updated)
        }
    }
}
