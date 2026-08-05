import XCTest
@testable import RemoteMini

/// `PollModels.swift` decode tests -- Sprint 4 brief §0's 7 discrepancies (§0-b①-⑦)
/// each get a dedicated case here, not just a passing mention in a doc comment; §0-b④
/// (the `tail-attached` null-notice case) gets its own negative control, per that
/// file's own note that it is "the sprint's most dangerous single fact."
final class PollModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Root response: tmux route, all 7 keys present

    func testTmuxRouteDecodesAllSevenRootKeys() throws {
        let response = try decode(PollResponse.self, """
        {
          "items": [],
          "screen": { "route": "tmux", "pane": "p", "screen": "SENDABLE", "work": "quiet", "windowMs": 0 },
          "display": { "choice": { "show": true, "reason": "確認が要ります" } },
          "queued": null,
          "cursor": "t.abc123.5.2",
          "more": false
        }
        """)

        XCTAssertEqual(response.items, [])
        XCTAssertEqual(response.screen?.classification, .sendable)
        XCTAssertEqual(response.display?.choice, ChoiceView(show: true, reason: "確認が要ります"))
        XCTAssertNil(response.queued, "tmux sends the JSON literal null for queued, not a count")
        XCTAssertEqual(response.cursor, PollCursor(raw: "t.abc123.5.2"))
        XCTAssertFalse(response.more)
    }

    // MARK: - §0-b⑤: worker route omits `display` entirely, carries `queued` as a count

    func testWorkerRouteWithDisplayKeyAbsentDecodesDisplayAsNilNotThrow() throws {
        let response = try decode(PollResponse.self, """
        { "items": [], "screen": null, "queued": 3, "cursor": "w.7.2.0", "more": false }
        """)

        XCTAssertNil(response.display, "the worker root has no `display` key at all -- absence, not null")
        XCTAssertEqual(response.queued, 3)
    }

    // MARK: - §2-c: null = held over, for `screen` AND `display.choice` alike

    func testScreenKeyAbsentDecodesAsNilHeldOver() throws {
        let response = try decode(PollResponse.self, """
        { "items": [], "cursor": "", "more": false }
        """)
        XCTAssertNil(response.screen)
    }

    func testScreenKeyPresentButNullDecodesAsNilIdenticallyToAbsent() throws {
        let response = try decode(PollResponse.self, """
        { "items": [], "screen": null, "cursor": "", "more": false }
        """)
        XCTAssertNil(response.screen, "brief §0-b①/§2-c: an explicit JSON null must merge exactly like a missing key, not like \"clear it\"")
    }

    func testDisplayChoiceKeyAbsentDecodesAsNilHeldOver() throws {
        let response = try decode(PollResponse.self, """
        { "items": [], "display": {}, "cursor": "", "more": false }
        """)
        XCTAssertNil(response.display?.choice)
    }

    func testDisplayChoiceKeyPresentButNullDecodesAsNilIdenticallyToAbsent() throws {
        let response = try decode(PollResponse.self, """
        { "items": [], "display": { "choice": null }, "cursor": "", "more": false }
        """)
        XCTAssertNil(response.display?.choice)
    }

    // MARK: - ScreenBody classification (§0-b①): nested one level, 4 known values + fallback

    func testAllFourKnownClassificationValuesDecode() throws {
        for (wire, expected) in [
            ("SENDABLE", ScreenBody.Classification.sendable),
            ("CHOICE", .choice),
            ("UNKNOWN", .unknown),
            ("BUSY", .busy),
        ] {
            let body = try decode(ScreenBody.self, #"{ "screen": "\#(wire)" }"#)
            XCTAssertEqual(body.classification, expected, "wire value \(wire)")
        }
    }

    func testAFutureUnrecognizedClassificationFallsBackWithoutThrowing() throws {
        // A 5th value the server might add later -- must not make an old phone treat
        // the whole poll response as unreadable (same reasoning as `ReadablePoll`'s
        // own unrecognized-`kind` handling).
        let body = try decode(ScreenBody.self, #"{ "screen": "SOMETHING_FUTURE" }"#)
        XCTAssertEqual(body.classification, .unrecognized)
    }

    func testUnrecognizedIsDistinctFromTheLegitimateWireValueUnknownNegativeControl() throws {
        // Brief §0-b①'s own trap: `"UNKNOWN"` is itself one of the 4 real wire
        // values. Collapsing "server said UNKNOWN" and "phone has never heard of
        // this" into the same case would make them indistinguishable in Swift even
        // though the wire keeps them apart.
        let serverSaidUnknown = try decode(ScreenBody.self, #"{ "screen": "UNKNOWN" }"#)
        let phoneNeverHeardOfIt = try decode(ScreenBody.self, #"{ "screen": "TOTALLY_NEW" }"#)
        XCTAssertNotEqual(serverSaidUnknown.classification, phoneNeverHeardOfIt.classification)
    }

    // MARK: - PollItem: message, entries (tmux) vs event (worker, §0-b⑥)

    func testMessageItemWithEntriesDecodesToMessageCase() throws {
        let item = try decode(PollItem.self, """
        { "kind": "message", "seq": 12, "entries": [
          { "role": "user", "text": "a", "display": { "who": "Tom" } }
        ] }
        """)
        guard case .message(let message) = item else { return XCTFail("expected .message, got \(item)") }
        XCTAssertEqual(message.seq, 12)
        XCTAssertEqual(message.entries?.count, 1)
        XCTAssertEqual(message.entries?.first?.text, "a")
    }

    func testMessageItemWithEventInsteadOfEntriesDecodesWithNilEntriesNotThrow() throws {
        // §0-b⑥: the worker route's `event` shape is not modeled -- this must still
        // decode (not throw), with `entries` landing `nil`. `ReadablePoll.check`, not
        // this decode step, is what would separately reject a message item that has
        // neither `entries` nor a plain-object `event` -- that boundary is
        // `PollClientTests`'s to cover, not this file's.
        let item = try decode(PollItem.self, """
        { "kind": "message", "seq": 4, "event": { "type": "assistant_text", "text": "hi" } }
        """)
        guard case .message(let message) = item else { return XCTFail("expected .message, got \(item)") }
        XCTAssertNil(message.entries)
        XCTAssertEqual(message.seq, 4)
    }

    // MARK: - PollItem: gap (§0-b③④⑥)

    func testGapItemWithNoticeDecodesNoticePopulated() throws {
        let item = try decode(PollItem.self, """
        { "kind": "gap", "why": "ring-overflow", "display": { "notice": "少し飛びました" }, "seq": 9 }
        """)
        guard case .gap(let gap) = item else { return XCTFail("expected .gap, got \(item)") }
        XCTAssertEqual(gap.why, .ringOverflow)
        XCTAssertEqual(gap.notice, "少し飛びました")
        XCTAssertEqual(gap.seq, 9)
    }

    /// Brief §0-b④, called out as "the sprint's most dangerous single fact":
    /// `gapNotice("tail-attached")` returns the JSON literal `null` ON PURPOSE -- a
    /// real, benign wire value, not a malformed response. This is the case a naive
    /// `notice: String` (non-optional) port gets wrong.
    func testTailAttachedGapWithNullNoticeDecodesNoticeAsNilNotThrow() throws {
        let item = try decode(PollItem.self, """
        { "kind": "gap", "why": "tail-attached", "display": { "notice": null }, "seq": 3 }
        """)
        guard case .gap(let gap) = item else { return XCTFail("expected .gap, got \(item)") }
        XCTAssertEqual(gap.why, .tailAttached)
        XCTAssertNil(gap.notice, "gapNotice(\"tail-attached\") returning null is benign -- must decode to nil, not throw")
        XCTAssertEqual(gap.seq, 3)
    }

    func testTailAttachedNullNoticeWouldThrowUnderANonOptionalNoticeNegativeControl() throws {
        // Prove the control can actually fail: a `notice: String` (not `String?`)
        // twin type must reject the exact JSON the real `GapItem` accepts above.
        struct NonOptionalNoticeDisplay: Decodable { let notice: String }
        struct NonOptionalNoticeGap: Decodable { let display: NonOptionalNoticeDisplay }
        let json = Data(#"{ "display": { "notice": null } }"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(NonOptionalNoticeGap.self, from: json))
        // ...while the real type, decoding the identical `display.notice: null` shape, does not.
        XCTAssertNoThrow(try decode(PollItem.self, """
        { "kind": "gap", "why": "tail-attached", "display": { "notice": null } }
        """))
    }

    func testGapItemWithDisplayKeyAbsentEntirelyDecodesNoticeAsNil() throws {
        // Brief's "gapItem(why) called with no second argument" family
        // (cursor-too-long/cursor-malformed/route-changed/epoch-mismatch) -- no
        // `display` key at all, not merely a null `notice` inside one.
        let item = try decode(PollItem.self, """
        { "kind": "gap", "why": "cursor-too-long" }
        """)
        guard case .gap(let gap) = item else { return XCTFail("expected .gap, got \(item)") }
        XCTAssertNil(gap.notice)
        XCTAssertNil(gap.seq, "cursor-too-long is one of the 4 values `pollDecision` returns with no seq")
    }

    func testUnrecognizedKindDecodesToUnrecognizedCaseNotThrow() throws {
        let item = try decode(PollItem.self, #"{ "kind": "something-future" }"#)
        guard case .unrecognized(let kind) = item else { return XCTFail("expected .unrecognized, got \(item)") }
        XCTAssertEqual(kind, "something-future")
    }

    // MARK: - GapWhy: 9 known values + fallback

    func testAllNineKnownGapWhyValuesDecode() throws {
        let cases: [(String, GapWhy)] = [
            ("cursor-too-long", .cursorTooLong),
            ("cursor-malformed", .cursorMalformed),
            ("route-changed", .routeChanged),
            ("epoch-mismatch", .epochMismatch),
            ("ring-overflow", .ringOverflow),
            ("tail-attached", .tailAttached),
            ("generation-changed", .generationChanged),
            ("truncated", .truncated),
            ("checkpoint-mismatch", .checkpointMismatch),
        ]
        for (wire, expected) in cases {
            let why = try decode(GapWhy.self, "\"\(wire)\"")
            XCTAssertEqual(why, expected, "wire value \(wire)")
        }
    }

    func testUnrecognizedGapWhyFallsBackWithoutThrowing() throws {
        let why = try decode(GapWhy.self, "\"some-future-reason\"")
        XCTAssertEqual(why, .unrecognized)
    }

    // MARK: - ChoiceView (brief §1-b "D-A": only show/reason modeled)

    // MARK: - N3 (§5-a): a non-optional root `display` must reject what the real type accepts

    func testWorkerRouteWouldFailToDecodeUnderANonOptionalRootDisplayNegativeControl() throws {
        // N3: the real `PollResponse.display` is `PollDisplay?` specifically because
        // the worker route omits the `display` key entirely (§0-b⑤). A twin that
        // makes it non-optional must reject that exact, real shape.
        struct NonOptionalDisplayResponse: Decodable {
            let items: [PollItem]
            let display: PollDisplay
            let cursor: PollCursor
        }
        let workerJSON = #"{ "items": [], "queued": 3, "cursor": "w.7.2.0", "more": false }"#

        XCTAssertThrowsError(try JSONDecoder().decode(NonOptionalDisplayResponse.self, from: Data(workerJSON.utf8)))
        XCTAssertNoThrow(try decode(PollResponse.self, workerJSON), "the real, optional `display` must decode this worker-route body cleanly")
    }

    // MARK: - N4 (§5-a): `screen` is a nested object, not a bare string

    func testScreenFieldIsANestedObjectNotABareStringNegativeControl() throws {
        // N4: the spec's own prose reads `screen === "CHOICE"`, but the wire's
        // `screen` is an object one level up from the classification word
        // (`screen.screen`, §0-b①). A twin that models `screen` as a bare string
        // must fail to decode the real tmux-route shape.
        struct BareStringScreenResponse: Decodable {
            let items: [PollItem]
            let screen: String?
            let cursor: PollCursor
        }
        let tmuxJSON = #"{ "items": [], "screen": { "route": "tmux", "pane": "p", "screen": "CHOICE", "work": "quiet", "windowMs": 0 }, "cursor": "t.a.1.0", "more": false }"#

        XCTAssertThrowsError(try JSONDecoder().decode(BareStringScreenResponse.self, from: Data(tmuxJSON.utf8)))
        let real = try decode(PollResponse.self, tmuxJSON)
        XCTAssertEqual(real.screen?.classification, .choice, "the real type reads the nested screen.screen word, not a top-level bare string")
    }

    func testChoiceViewDecodesShowAndReasonIgnoringUnmodeledFields() throws {
        // `options`/`head`/`buttons`/`digest` are real wire fields this sprint does
        // not model -- their presence must not break the decode.
        let choice = try decode(ChoiceView.self, """
        { "show": true, "reason": "選択が必要です", "options": ["a", "b"], "head": "見出し" }
        """)
        XCTAssertTrue(choice.show)
        XCTAssertEqual(choice.reason, "選択が必要です")
    }
}
