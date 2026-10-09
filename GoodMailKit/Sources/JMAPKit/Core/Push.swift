import Foundation

/// The types whose state changed, as pushed by the server (RFC 8620 §7.1).
public struct StateChange: Decodable, Sendable, Equatable {
    /// Account id → type name, such as `"Email"` → the state its `/get` would return now.
    public let changed: [String: [String: String]]

    public init(changed: [String: [String: String]]) {
        self.changed = changed
    }
}

/// What happened on a push connection; see `JMAPClient.pushEvents(types:ping:)`.
public enum PushEvent: Sendable, Equatable {
    /// The server accepted the connection. Changes from now on are pushed, earlier ones only if the server can tell
    /// from the last event this client got that it missed them.
    ///
    /// Over `URLSessionTransport` this comes with the first event or ping, as URLSession hands over a response
    /// only together with the first bytes of its body.
    case connected
    case stateChange(StateChange)
}
