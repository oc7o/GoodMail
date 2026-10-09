import Foundation
import JMAPKit
import Synchronization
import Testing
@testable import DemoAccount

struct DemoClockTests {
    let start = DemoAccountTests.start

    @Test func manualClockMovesOnlyWhenAdvanced() {
        let clock = DemoClock(manualStart: start)

        #expect(clock.isManual)
        #expect(clock.now == start)
        clock.advance(by: 90)
        #expect(clock.now == start.addingTimeInterval(90))
    }

    @Test func waitReturnsOnceAnAdvancePassesTheDate() async {
        let clock = DemoClock(manualStart: start)
        let woke = Mutex<Date?>(nil)
        let waiter = Task {
            await clock.wait(until: start.addingTimeInterval(10))
            woke.withLock { $0 = clock.now }
        }

        clock.advance(by: 5)
        // Some real time, so that an early return would show.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(woke.withLock { $0 } == nil)
        clock.advance(by: 6)
        await waiter.value

        #expect(woke.withLock { $0 } == start.addingTimeInterval(11))
    }

    @Test func waitForAPastDateReturnsAtOnce() async {
        let clock = DemoClock(manualStart: start)

        await clock.wait(until: start)
        await clock.wait(until: start.addingTimeInterval(-60))
    }

    @Test func cancellingEndsTheWait() async {
        let clock = DemoClock(manualStart: start)
        let waiter = Task { await clock.wait(until: start.addingTimeInterval(3600)) }

        waiter.cancel()
        await waiter.value

        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await clock.wait(until: start.addingTimeInterval(3600))
        }
        await alreadyCancelled.value
    }

    @Test func systemClockFollowsRealTimeAndCanBeAdvanced() async {
        let clock = DemoClock()
        let before = Date.now

        await clock.wait(until: before.addingTimeInterval(0.05))
        #expect(Date.now >= before.addingTimeInterval(0.05))
        #expect(!clock.isManual)

        clock.advance(by: 3600)
        #expect(clock.now >= Date.now.addingTimeInterval(3599))
        await clock.wait(until: before.addingTimeInterval(1800))
    }

    /// Demo mode: nothing advances the system clock, so the server releases held mail by itself.
    @Test func heldMailGoesOutByItselfOnTheSystemClock() async throws {
        let server = DemoTransport()
        let client = JMAPClient(token: "demo", transport: server, maxRetries: 0)
        let body = EmailCreate.body(text: "Hi", html: "<div>Hi</div>", inline: [], attachments: [])
        let email = EmailCreate(
            mailboxIds: ["drafts": true], keywords: ["$draft": true], messageId: ["realtime@fastmail.com"],
            from: [EmailAddress(email: "alex@fastmail.com")], to: [EmailAddress(email: "maya@lindqvist.example")],
            subject: "Real time", sentAt: nil, bodyStructure: body.structure, bodyValues: body.values)
        let envelope = EmailSubmission.Envelope(
            mailFrom: .init(email: "alex@fastmail.com", parameters: ["HOLDFOR": "1"]),
            rcptTo: [.init(email: "maya@lindqvist.example")])

        let result = try await client.submit(
            email, identityID: "ident-1", envelope: envelope, mailboxes: MailboxRoles(drafts: "drafts", sent: "sent"))
        #expect(result.submission?.undoStatus == .pending)
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.pendingSubmissionIDs.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(server.sentMessages.map(\.messageId) == ["realtime@fastmail.com"])
    }

    @Test func advancingReleasesHeldMailBeforeWaitersWake() async throws {
        let clock = DemoClock(manualStart: start)
        let server = DemoTransport(clock: clock)
        var request = URLRequest(url: URL(string: "https://demo.invalid/jmap/api/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"""
            {"using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail", "urn:ietf:params:jmap:submission"],
             "methodCalls": [["EmailSubmission/set", {"accountId": "demo", "create": {"s": {"identityId": "ident-1",
               "emailId": "e14", "envelope": {"mailFrom": {"email": "alex@fastmail.com", "parameters": {"HOLDFOR": "15"}},
                                              "rcptTo": [{"email": "lena@fischer.example", "parameters": null}]}}}}, "c0"]]}
            """#.utf8)
        _ = try await server.send(request)
        let sentWhenWoken = Mutex<Int?>(nil)
        let waiter = Task {
            await clock.wait(until: start.addingTimeInterval(15))
            sentWhenWoken.withLock { $0 = server.sentMessages.count }
        }

        clock.advance(by: 15)
        await waiter.value

        #expect(sentWhenWoken.withLock { $0 } == 1)
        #expect(server.sentMessages.first?.emailId == "e14")
    }
}
