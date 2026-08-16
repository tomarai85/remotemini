import XCTest
@testable import RemoteMini

/// Decode tests for `SessionsResponse`/`SessionRow` against the REAL observed shape
/// (Sprint 2 brief §0), not the spec's stale prose. The fixtures below are a shrunk
/// version of the 39-session sample the brief's wire-shape observation captured --
/// same field names, same optionality pattern (`fromRegistryOnly` present on only a
/// minority of rows), same `routeLabel()` example values (`rc-backend/src/view.mjs`),
/// reduced to the handful of rows needed to exercise every branch once.
final class SessionsModelsTests: XCTestCase {
    private func decode(_ json: String) throws -> SessionsResponse {
        try JSONDecoder().decode(SessionsResponse.self, from: Data(json.utf8))
    }

    // MARK: - The real shape decodes

    func testDecodesTheRealObservedShape() throws {
        let response = try decode(Self.fourRowFixture)

        XCTAssertEqual(response.sessions.count, 4)
        XCTAssertEqual(response.display.scan, "12本のうち 12本を読み、0本は前の結果を使いました。")
        XCTAssertNil(response.paneFault)
    }

    // MARK: - Brief §0-a-1: `fromRegistryOnly` present on only a minority of rows

    func testFromRegistryOnlyIsOptionalAcrossPresentAndAbsentRows() throws {
        let response = try decode(Self.fourRowFixture)

        XCTAssertEqual(response.sessions[0].fromRegistryOnly, true, "tmux row: key present, true")
        XCTAssertNil(response.sessions[1].fromRegistryOnly, "worker row: key absent -- must not fail decode")
        XCTAssertNil(response.sessions[2].fromRegistryOnly)
        XCTAssertNil(response.sessions[3].fromRegistryOnly)
    }

    // MARK: - Brief §0-a-2: `screen` is `""`, not absent and not null, on the worker route

    func testWorkerRouteScreenIsEmptyStringNotNil() throws {
        let response = try decode(Self.fourRowFixture)
        let worker = response.sessions[1]

        XCTAssertEqual(worker.display.route.kind, .worker)
        XCTAssertEqual(worker.display.route.screen, "", "empty string, decoded as a real (non-nil) value")
    }

    // MARK: - Brief §1-b: an unrecognized `kind` falls back to `.unknown`, decode does not fail

    func testUnrecognizedRouteKindFallsBackToUnknownWithoutFailingDecode() throws {
        let response = try decode(Self.futureKindFixture)

        XCTAssertEqual(response.sessions[0].display.route.kind, .unknown)
        // The rest of the row decoded fine -- only the enum fell back, nothing else broke.
        XCTAssertEqual(response.sessions[0].id, "sess-future")
    }

    // MARK: - Brief §1-b: `paneFault` decodes when present and non-null

    func testPaneFaultDecodesWhenPresent() throws {
        let response = try decode(Self.paneFaultFixture)
        let fault = try XCTUnwrap(response.paneFault)

        XCTAssertEqual(fault.reason, "panes-unreadable")
        XCTAssertEqual(fault.detail, "TypeError: Cannot read properties of undefined (reading 'split')")
        XCTAssertEqual(fault.display?.headline, "帯の見出し")
        XCTAssertEqual(fault.display?.body, "帯の本文")
        // 帯に描くのはサーバの文そのもの。落とし所へ落ちていない事まで見る。
        XCTAssertEqual(fault.bannerDisplay.headline, "帯の見出し")
        XCTAssertEqual(fault.bannerDisplay.body, "帯の本文")
    }

    /// 電話の方が新しい場合(2026-08-08 / 監査 S8-22)。`display` は**任意**でなければ
    /// ならない —— 必須にすると、説明を持たない古いサーバに対して `/api/sessions` の
    /// decode が丸ごと落ち、一覧が出ない上に理由も出ない画面になる。edith が HEAD より
    /// 古い版で走っていたのは実際に観測している。
    func testPaneFaultDecodesWithoutDisplayAndFallsBackToReadableText() throws {
        let response = try decode(Self.paneFaultWithoutDisplayFixture)
        let fault = try XCTUnwrap(response.paneFault, "display が無いだけで応答ごと decode に失敗している")

        XCTAssertNil(fault.display)
        XCTAssertEqual(fault.reason, "panes-unreadable")
        // 錨: 落とし所は空文字ではなく文である。
        XCTAssertTrue(fault.bannerDisplay.headline.contains("pane list"), "実測: \(fault.bannerDisplay.headline)")
        XCTAssertTrue(fault.bannerDisplay.body.contains("Check the desk"), "実測: \(fault.bannerDisplay.body)")
        // 生の値は画面へ出さない。理由コードだけは診断として本文の末尾に残す。
        XCTAssertFalse(fault.bannerDisplay.headline.contains("panes-unreadable"))
        XCTAssertFalse(fault.bannerDisplay.body.contains(fault.detail))
    }

    // MARK: - Brief §1-a: `live` is never decoded, regardless of which route's shape it carries

    func testLiveFieldIsIgnoredRegardlessOfShape() throws {
        for fixture in [Self.liveAbsentFixture, Self.liveTmuxFixture, Self.liveWorkerFixture, Self.liveBlockedFixture] {
            let response = try decode(fixture)
            XCTAssertEqual(response.sessions.count, 1, "decode must succeed the same way whether `live` is absent or carries any route's shape")
        }
    }

    // MARK: - Negative controls (brief §5-a: decode must FAIL, not silently produce an empty screen)

    func testMissingOuterDisplayFailsToDecodeNegativeControl() {
        // If `SessionsResponse.display` were `Optional`, this body would decode to an
        // empty-looking response instead of throwing -- the exact "green but lying"
        // failure mode brief §0's doc comment on `wire-shape.mjs` warns about.
        XCTAssertThrowsError(try decode(Self.missingOuterDisplayFixture))
    }

    func testMissingRowDisplayFailsToDecodeNegativeControl() {
        XCTAssertThrowsError(try decode(Self.missingRowDisplayFixture))
    }

    // MARK: - `displayTitle` (brief §3-a): empty-title fallback, id-prefix(8) truncation.
    // Added 2026-08-05 -- the mutation audit found `displayTitle` had zero coverage
    // despite being rendered from two places in `ListView`.

    private func decodeRow(id: String, title: String) throws -> SessionRow {
        let json = """
        { "id": "\(id)", "title": "\(title)", "updatedAt": "2026-08-05T09:00:00.000Z",
          "display": { "route": { "kind": "tmux", "short": "s", "text": "t", "screen": "" }, "subtitle": "s" } }
        """
        return try JSONDecoder().decode(SessionRow.self, from: Data(json.utf8))
    }

    func testDisplayTitleReturnsTheTitleWhenNonEmpty() throws {
        let row = try decodeRow(id: "sess-0000000001", title: "机で開いているセッション")

        XCTAssertEqual(row.displayTitle, "机で開いているセッション")
    }

    func testDisplayTitleFallsBackToTheIDsFirst8CharactersWhenTitleIsEmpty() throws {
        let row = try decodeRow(id: "sess-0000000001", title: "")

        XCTAssertEqual(row.displayTitle, "sess-000", "truncation rule is exactly 8 characters, not 7 or 9")
    }

    // Brief §3-a's fallback is `String(id.prefix(8))`, not a fixed-length slice --
    // `prefix(8)` on a shorter string returns the whole string rather than crashing
    // or padding. Locking this in means a future rewrite as e.g. `id[0..<8]` (which
    // WOULD crash on a short id) fails this test instead of failing on a real phone.
    func testDisplayTitleWithAnIDShorterThan8CharactersReturnsTheWholeIDWithoutCrashing() throws {
        let row = try decodeRow(id: "abc", title: "")

        XCTAssertEqual(row.displayTitle, "abc")
    }

    // Negative control for the above: both inputs empty must still resolve to an
    // empty string, not a placeholder invented by a future "improvement" (e.g.
    // falling back to a literal "Untitled") that the brief never asked for.
    func testDisplayTitleWithAnEmptyIDAndEmptyTitleIsAnEmptyStringNegativeControl() throws {
        let row = try decodeRow(id: "", title: "")

        XCTAssertEqual(row.displayTitle, "")
    }

    // MARK: - Fixtures (values lifted from `routeLabel()`'s own example strings in view.mjs, not invented)

    private static let fourRowFixture = """
    {
      "sessions": [
        {
          "id": "sess-tmux-0001", "project": "remote-mini", "cwd": "/Users/tomtim/Infra/mobile-work",
          "title": "実装中のセッション", "lastPrompt": "続けて", "turns": null,
          "metadataIncomplete": false, "updatedAt": "2026-08-05T09:00:00.000Z",
          "fromRegistryOnly": true,
          "display": { "route": { "kind": "tmux", "short": "机・動いている", "text": "机で開いている・動いている", "screen": "MAIN" }, "subtitle": "続けて" }
        },
        {
          "id": "sess-worker-002", "project": "remote-mini", "cwd": "/Users/tomtim/Infra/mobile-work",
          "title": "", "lastPrompt": null, "turns": null,
          "metadataIncomplete": true, "updatedAt": "2026-08-05T08:00:00.000Z",
          "display": { "route": { "kind": "worker", "short": "ワーカー", "text": "ワーカー", "screen": "" }, "subtitle": "(直近の発言は読み取り範囲の外)" }
        },
        {
          "id": "sess-choice-003", "project": "remote-mini", "cwd": "/Users/tomtim/Infra/mobile-work",
          "title": "選択待ち", "lastPrompt": "どちらにしますか", "turns": null,
          "metadataIncomplete": false, "updatedAt": "2026-08-05T07:00:00.000Z",
          "display": { "route": { "kind": "choice", "short": "★選択待ち", "text": "机で開いている・★選択待ち(Enter が承認や課金になります)", "screen": "CHOICE" }, "subtitle": "どちらにしますか" }
        },
        {
          "id": "sess-blocked-004", "project": "remote-mini", "cwd": "/Users/tomtim/Infra/mobile-work",
          "title": "宛先不明", "lastPrompt": null, "turns": null,
          "metadataIncomplete": false, "updatedAt": "2026-08-05T06:00:00.000Z",
          "display": { "route": { "kind": "blocked", "short": "送れない", "text": "宛先を確定できません。", "screen": "" }, "subtitle": "(まだ発言がありません)" }
        }
      ],
      "scan": { "scope": "all", "limit": 200, "files": 12, "read": 12, "cached": 0, "examined": 12 },
      "display": { "scan": "12本のうち 12本を読み、0本は前の結果を使いました。" },
      "paneFault": null
    }
    """

    private static let futureKindFixture = """
    {
      "sessions": [
        {
          "id": "sess-future", "project": "remote-mini", "cwd": "/x",
          "title": "未来の経路", "lastPrompt": null, "turns": null,
          "metadataIncomplete": false, "updatedAt": "2026-08-05T09:00:00.000Z",
          "display": { "route": { "kind": "orbital-relay", "short": "?", "text": "?", "screen": "" }, "subtitle": "(まだ発言がありません)" }
        }
      ],
      "display": { "scan": "" },
      "paneFault": null
    }
    """

    /// 説明付き = 今のサーバ(`paneFaultView` を `display` に載せる)。
    ///
    /// `detail` は本番では `e.message` = 自由記述なので、**生の JS エラーらしい形**に
    /// してある。以前は此処が綺麗な日本語1文で、画面に出しても違和感が無い見た目だった
    /// —— それが「fixture の方が本番より良く見える」形(監査 S8-19 / S8-20 / S8-22)。
    private static let paneFaultFixture = """
    {
      "sessions": [],
      "display": { "scan": "" },
      "paneFault": {
        "reason": "panes-unreadable",
        "detail": "TypeError: Cannot read properties of undefined (reading 'split')",
        "display": { "headline": "帯の見出し", "body": "帯の本文" }
      }
    }
    """

    /// 説明**無し** = 電話より古いサーバ。`display` の欠落で `/api/sessions` の
    /// decode 全体が落ちてはいけない(落ちると、一覧が出ない上に理由も出ない)。
    private static let paneFaultWithoutDisplayFixture = """
    {
      "sessions": [],
      "display": { "scan": "" },
      "paneFault": {
        "reason": "panes-unreadable",
        "detail": "TypeError: Cannot read properties of undefined (reading 'split')"
      }
    }
    """

    private static func liveFixture(_ liveJSON: String) -> String {
        let liveField = liveJSON.isEmpty ? "" : "\"live\": " + liveJSON + ","
        return """
        {
          "sessions": [
            {
              "id": "sess-live-0001", "project": "remote-mini", "cwd": "/x",
              "title": "t", "lastPrompt": null, "turns": null,
              "metadataIncomplete": false, "updatedAt": "2026-08-05T09:00:00.000Z",
              \(liveField)
              "display": { "route": { "kind": "tmux", "short": "s", "text": "t", "screen": "" }, "subtitle": "s" }
            }
          ],
          "display": { "scan": "" },
          "paneFault": null
        }
        """
    }

    private static let liveAbsentFixture = liveFixture("")
    private static let liveTmuxFixture = liveFixture(#"{ "route": "tmux", "screen": "MAIN", "activity": "observed" }"#)
    private static let liveWorkerFixture = liveFixture(#"{ "route": "worker", "state": "running", "queued": 2 }"#)
    private static let liveBlockedFixture = liveFixture(#"{ "route": "blocked", "reason": "not-claude" }"#)

    private static let missingOuterDisplayFixture = """
    { "sessions": [], "paneFault": null }
    """

    private static let missingRowDisplayFixture = """
    {
      "sessions": [
        { "id": "x", "project": "p", "cwd": "/x", "title": "t", "lastPrompt": null, "turns": null,
          "metadataIncomplete": false, "updatedAt": "2026-08-05T09:00:00.000Z" }
      ],
      "display": { "scan": "" },
      "paneFault": null
    }
    """
}
