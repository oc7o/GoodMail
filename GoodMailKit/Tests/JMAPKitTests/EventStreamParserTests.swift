import Foundation
import Testing
@testable import JMAPKit

struct EventStreamParserTests {
    typealias Event = EventStreamParser.Event

    /// Feeds the chunks to one parser in order and collects every event.
    func parse<Chunk: Sequence<UInt8>>(_ chunks: [Chunk]) -> [Event] {
        var parser = EventStreamParser()
        return chunks.flatMap { parser.parse($0) }
    }

    func parse(_ text: String) -> [Event] {
        parse([Array(text.utf8)])
    }

    @Test func dispatchesOnBlankLine() {
        #expect(parse("event: state\ndata: {\"a\": 1}\n\n") == [Event(type: "state", data: "{\"a\": 1}")])
    }

    @Test func typeDefaultsToMessageAndResetsAfterEachEvent() {
        #expect(parse("event: state\ndata: one\n\ndata: two\n\nevent: ping\ndata: three\n\n") == [
            Event(type: "state", data: "one"),
            Event(type: "message", data: "two"),
            Event(type: "ping", data: "three"),
        ])
    }

    @Test func joinsDataLinesWithLineFeeds() {
        #expect(parse("data: first\ndata:\ndata: third\n\n") == [Event(type: "message", data: "first\n\nthird")])
    }

    @Test(arguments: ["\n", "\r", "\r\n"])
    func acceptsEveryLineBreak(_ lineBreak: String) {
        let text = ["event: state", "data: a", "data: b", "", "data: c", "", ""].joined(separator: lineBreak)
        #expect(parse(text) == [Event(type: "state", data: "a\nb"), Event(type: "message", data: "c")])
    }

    @Test func mixesLineBreaks() {
        #expect(parse("data: a\rdata: b\r\ndata: c\n\r\n") == [Event(type: "message", data: "a\nb\nc")])
        #expect(parse("data: a\n\rdata: b\r\r") == [Event(type: "message", data: "a"), Event(type: "message", data: "b")])
    }

    @Test func carriageReturnAndLineFeedInSeparateChunksAreOneLineBreak() {
        #expect(parse(["data: a\r", "\ndata: b\r", "\n\r", "\n"].map { Array($0.utf8) })
            == [Event(type: "message", data: "a\nb")])
    }

    @Test func chunksMaySplitAnywhere() {
        let stream = Array("\u{FEFF}: hello\r\nevent: state\r\ndata: Grüße 🙂\r\ndata: two\r\n\r\ndata: x\r\r".utf8)
        let expected = [Event(type: "state", data: "Grüße 🙂\ntwo"), Event(type: "message", data: "x")]

        #expect(parse([stream]) == expected)
        #expect(parse(stream.map { [$0] }) == expected)
        for split in stream.indices {
            #expect(parse([stream[..<split], stream[split...]]) == expected, "Split at byte \(split)")
        }
    }

    @Test func keepsStateUntilTheEventIsComplete() {
        var parser = EventStreamParser()
        #expect(parser.parse(Array("event: state\ndata: a".utf8)).isEmpty)
        #expect(parser.parse(Array("\n".utf8)).isEmpty)
        #expect(parser.parse(Array("\n".utf8)) == [Event(type: "state", data: "a")])
    }

    @Test func stripsOnlyOneLeadingByteOrderMark() {
        #expect(parse("\u{FEFF}data: a\n\n") == [Event(type: "message", data: "a")])
        #expect(parse("\u{FEFF}\u{FEFF}data: a\n\n").isEmpty)
        #expect(parse("data: a\n\n\u{FEFF}data: b\n\n") == [Event(type: "message", data: "a")])
        #expect(parse([[0xEF], [0xBB], [0xBF]] + [Array("data: a\n\n".utf8)]) == [Event(type: "message", data: "a")])
    }

    @Test func ignoresCommentsAndOtherFields() {
        #expect(parse(": ping\n\n").isEmpty)
        #expect(parse(": comment\nid: 7\nretry: 1000\nfoo: bar\nData: shouted\ndata: kept\n\n")
            == [Event(type: "message", data: "kept")])
    }

    @Test func lineWithoutColonIsAFieldWithEmptyValue() {
        #expect(parse("data\n\n") == [Event(type: "message", data: "")])
        #expect(parse("event: state\nevent\ndata: x\n\n") == [Event(type: "message", data: "x")])
    }

    @Test func stripsOneSpaceAfterTheFirstColon() {
        #expect(parse("data:tight\n\ndata:  roomy\n\ndata: a: b\n\n") == [
            Event(type: "message", data: "tight"),
            Event(type: "message", data: " roomy"),
            Event(type: "message", data: "a: b"),
        ])
    }

    @Test func eventWithoutDataIsDropped() {
        #expect(parse("event: ping\n\ndata: x\n\n") == [Event(type: "message", data: "x")])
    }

    @Test func eventCutOffByTheEndIsNeverDispatched() {
        #expect(parse("data: a\n").isEmpty)
        #expect(parse("data: a").isEmpty)
    }

    @Test func remembersTheIDOfTheLastCompleteEvent() {
        var parser = EventStreamParser()
        #expect(parser.lastEventID == "")
        _ = parser.parse(Array("event: state\nid: s1\ndata: a\n\n".utf8))
        #expect(parser.lastEventID == "s1")
        // Events without one keep it, such as pings.
        _ = parser.parse(Array("event: ping\ndata: {}\n\n".utf8))
        #expect(parser.lastEventID == "s1")
        // It only counts once its event is complete.
        _ = parser.parse(Array("id: s2\ndata: b\n".utf8))
        #expect(parser.lastEventID == "s1")
        _ = parser.parse(Array("\n".utf8))
        #expect(parser.lastEventID == "s2")
    }

    @Test func idCountsWithoutDataAndAnEmptyOneClearsIt() {
        var parser = EventStreamParser()
        #expect(parser.parse(Array("id: s1\n\n".utf8)).isEmpty)
        #expect(parser.lastEventID == "s1")
        _ = parser.parse(Array("id\ndata: x\n\n".utf8))
        #expect(parser.lastEventID == "")
    }

    @Test func ignoresIDContainingNull() {
        var parser = EventStreamParser()
        _ = parser.parse(Array("id: s1\n\nid: s\0 2\ndata: x\n\n".utf8))
        #expect(parser.lastEventID == "s1")
    }

    @Test func continuesFromTheIDThePreviousConnectionEndedWith() {
        var parser = EventStreamParser(lastEventID: "s1")
        #expect(parser.parse(Array("event: ping\ndata: {}\n\n".utf8)) == [Event(type: "ping", data: "{}")])
        #expect(parser.lastEventID == "s1")
    }

    @Test func replacesInvalidUTF8() {
        #expect(parse([Array("data: ".utf8) + [0xFF, 0x41, 0xE2, 0x82] + Array("\n\n".utf8)])
            == [Event(type: "message", data: "\u{FFFD}A\u{FFFD}")])
    }
}
