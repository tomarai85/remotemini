import XCTest
@testable import RemoteMini

/// Spec §3-2 / the cursor section of `tail.mjs`: the cursor is opaque -- the client stores whatever
/// string arrives and returns it byte-for-byte. These tests prove the type never
/// reformats, truncates, or reinterprets its `wireValue`, and that the documented
/// `""` "fresh" sentinel is exactly what the wire protocol defines it to be, not a
/// client-side guess at what "fresh" should look like.
final class PollCursorTests: XCTestCase {
    func testRoundTripPreservesTheExactWireValue() {
        let raw = "t.abc123.5.2"
        XCTAssertEqual(PollCursor(raw: raw).wireValue, raw)
    }

    func testEmptyStringIsTheDocumentedFreshSentinel() {
        // `tail.mjs`'s `pollDecision`: `s === ""` -> `{kind:"fresh"}`. This is the one
        // value the wire protocol itself assigns meaning to -- not a client-invented
        // "no cursor" marker.
        XCTAssertEqual(PollCursor.empty.wireValue, "")
    }

    func testOpacityRoundTripsAnUnrecognizedFutureFormatUnchanged() {
        // A hypothetical future server cursor shape the client has never seen (5
        // segments instead of tail.mjs's documented 4, e.g. a shard id inserted by a
        // later server version). An opaque client must carry it byte for byte
        // without needing to understand the shape.
        let futureFormat = "t.abc123.5.2.shard9"
        XCTAssertEqual(PollCursor(raw: futureFormat).wireValue, futureFormat)

        // Negative control: the easy-to-confuse wrong implementation "helpfully"
        // parses `cursor.split(".")` into (route, token, seq, screenRev) and
        // reconstructs from only the first 4 parts -- exactly the opacity violation
        // this contract exists to prevent. Prove the control can actually fail: the
        // naive reconstruction silently drops the 5th segment and differs from the
        // real cursor.
        let naiveParts = futureFormat.split(separator: ".").prefix(4)
        let naiveReconstruction = naiveParts.joined(separator: ".")
        XCTAssertNotEqual(naiveReconstruction, futureFormat, "control must actually mangle the unknown-format cursor")
        XCTAssertNotEqual(PollCursor(raw: futureFormat).wireValue, naiveReconstruction)
    }

    func testDistinctWireValuesAreNotEqual() {
        XCTAssertNotEqual(PollCursor(raw: "t.abc.1.0"), PollCursor(raw: "t.abc.2.0"))
    }

    // MARK: - Decodable (Sprint 4: `PollResponse.cursor` is a bare JSON string)

    func testDecodesFromABareJSONStringSingleValueContainer() throws {
        let decoded = try JSONDecoder().decode(PollCursor.self, from: Data(#""t.abc123.5.2""#.utf8))
        XCTAssertEqual(decoded, PollCursor(raw: "t.abc123.5.2"))
    }

    func testDecodesTheEmptyStringToTheSameFreshSentinel() throws {
        let decoded = try JSONDecoder().decode(PollCursor.self, from: Data(#""""#.utf8))
        XCTAssertEqual(decoded, PollCursor.empty)
    }

    func testDoesNotUnwrapAnObjectWrapperNegativeControl() {
        // Negative control: a `{ "cursor": "..." }` object wrapper (the easy mistake
        // if this were modeled as a keyed struct instead of a single-value
        // container) must NOT decode -- the wire sends a bare string.
        XCTAssertThrowsError(try JSONDecoder().decode(PollCursor.self, from: Data(#"{ "cursor": "t.abc.1.0" }"#.utf8)))
    }
}
