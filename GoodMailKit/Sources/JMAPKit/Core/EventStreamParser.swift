/// Parses a `text/event-stream` body as it arrives (HTML Living Standard, "Server-sent events").
///
/// Works on bytes, so a chunk may end anywhere, even inside a UTF-8 sequence or between the CR and LF of a line
/// break: line breaks are ASCII, and a line is only decoded once it is complete. The caller decides when to
/// reconnect, so `retry` is ignored like unknown fields. An event cut off by the end of the stream is never
/// dispatched, and its `id` doesn't count.
struct EventStreamParser {
    struct Event: Equatable, Sendable {
        var type: String
        var data: String
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The id of the last complete event, or of an earlier one if it had none; what a reconnection hands back as
    /// `Last-Event-ID`. The server clears it by sending an empty id.
    private(set) var lastEventID: String

    private var line: [UInt8] = []
    private var isAtStreamStart = true
    private var followsCarriageReturn = false
    private var type = ""
    private var data: [UInt8] = []
    private var id: String

    /// - Parameter lastEventID: Where the previous connection left off. The standard starts every connection
    ///   without one, but pings carry no id (RFC 8620 §7.3), so a connection that only pinged would forget it.
    init(lastEventID: String = "") {
        self.lastEventID = lastEventID
        id = lastEventID
    }

    /// Takes the next chunk of the body and returns the events it completed.
    mutating func parse(_ chunk: some Sequence<UInt8>) -> [Event] {
        var events: [Event] = []
        for byte in chunk {
            switch byte {
            case UInt8(ascii: "\n") where followsCarriageReturn:
                followsCarriageReturn = false
            case UInt8(ascii: "\r"), UInt8(ascii: "\n"):
                followsCarriageReturn = byte == UInt8(ascii: "\r")
                if let event = process(line[...]) { events.append(event) }
                line.removeAll(keepingCapacity: true)
            default:
                followsCarriageReturn = false
                line.append(byte)
            }
        }
        return events
    }

    /// A comment line starts with a colon, so its field name is empty and matches nothing.
    private mutating func process(_ line: ArraySlice<UInt8>) -> Event? {
        var line = line
        if isAtStreamStart {
            isAtStreamStart = false
            if line.starts(with: Self.byteOrderMark) { line = line.dropFirst(Self.byteOrderMark.count) }
        }
        guard !line.isEmpty else { return dispatch() }

        let colon = line.firstIndex(of: UInt8(ascii: ":")) ?? line.endIndex
        let field = line[..<colon]
        var value = line[colon...].dropFirst()
        if value.first == UInt8(ascii: " ") { value = value.dropFirst() }

        if field.elementsEqual("event".utf8) {
            type = String(decoding: value, as: UTF8.self)
        } else if field.elementsEqual("data".utf8) {
            data += value
            data.append(UInt8(ascii: "\n"))
        } else if field.elementsEqual("id".utf8), !value.contains(0) {
            id = String(decoding: value, as: UTF8.self)
        }
        return nil
    }

    /// Takes the id even when there is no event to hand out.
    private mutating func dispatch() -> Event? {
        lastEventID = id
        defer {
            type = ""
            data.removeAll(keepingCapacity: true)
        }
        guard !data.isEmpty else { return nil }
        return Event(type: type.isEmpty ? "message" : type, data: String(decoding: data.dropLast(), as: UTF8.self))
    }
}
