/// RFC 8621 §3. Named `EmailThread` to avoid clashing with `Foundation.Thread`.
public struct EmailThread: JMAPObject, Equatable {
    public static let typeName = "Thread"
    public static let capability = Capability.mail

    public let id: String
    /// Sorted by `receivedAt`, oldest first.
    public let emailIds: [String]
}

public typealias ThreadGet = GetRequest<EmailThread>
public typealias ThreadChanges = ChangesRequest<EmailThread>
