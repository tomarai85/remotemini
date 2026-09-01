<!-- session: 2026-09-01 15:30 -->
# progress — 会話の転写を電話から探す(spec-2026-09-01-transcript-search.md)

所有者 = 本ファイルのみ。共有の `.harness/progress.md` は触っていない。

## Codex 委譲の評価(実装前に実施)

**結論: 委譲しない(Layer A に形式上 1 つ当たるが、当てない方が安い)。**

- 当たった条件: 「新規実装 100 行超」(実測 = 製品 約 330 行 + 検査 約 780 行)。
- 当てなかった理由 —— この作業の費用は**行数ではなく制約の読み合わせ**に在る:
  1. 変更点が既存の閉ループへ**触れない事**が最大の要求(§6 の着地の輪)。
     `overlay` と差し替えの差は 1 行だが、判断の材料は `ConversationView` の
     220 行ぶんの註釈と 2026-08-31 の失敗記録の中に在る。
  2. 検査は**変異表(§9)から逆算して**書く必要が在り、「どの扉が何を守れないか」が
     設計そのもの。生成物のレビュー費用が生成の節約を上回る。
  3. 註釈が日英混在の repo 固有の規約(理由・実測値・撤回条件を本文に置く)を持つ。
- 記録の場所: `/tmp/claude-codex-evaluated-<SID>` に `evaluated:<epoch>` を書いた。

## Milestone 1: 転写の探索(v1)

- Status: **Done**(受け入れ条件を満たし、変異 11 行すべてで赤を実測)。★但し**実機の机は未配備** = 実機ではまだ使えない(下の §実機)。
- 走行モード: bounded。**この spec の範囲は全て実装済み、妥協した点は §「やっていない事」に列挙。**

### Files Changed

**電話(製品)**
- `ios/Sources/Core/HistoryModels.swift`
  — `TranscriptScanCoverage`(enum)/ `TranscriptSearchResponse`(Decodable)を新設。
    `matched` と `searchedToStart` は**必須鍵**、`truncated` は**復号しない**。
    `HistoryResponse.truncated` が緩く受けてよい理由と**逆向き**である事を doc に書いた。
- `ios/Sources/Core/HistoryClient.swift`
  — `HistoryFetching` に `search(…)` を追加。`fetch(…)` から `query:` 引数を**削除**。
    URL 組み立て・method・`Bearer`・待ち時間・status 写像は私有 `get<T>` に 1 本化し、
    2 つの口で共有(違うのは復号先の型だけ)。
- `ios/Sources/Core/HistoryFixture.swift`
  — `search` を実装。机の機構(チャンク 32 / 窓 120 / 一致が上限でチャンク末に停止)を写す。
    fixture 状態 `conversation-search`(240 行)と `conversation-search-unreachable` を追加。
- `ios/Sources/Core/PollFixture.swift` — 新状態 2 つを 3 箇所の switch に追加(静かな状態にした)。
- `ios/Sources/Screens/Conversation/ConversationViewModel.swift`
  — `TranscriptSearchState` / `TranscriptSearchFailure` / `TranscriptSearchResults` を新設。
    `searchState` / `search(query:)` / `applySearch(…)` / `cancelSearch()` / `searchLimit = 100`。
- `ios/Sources/Screens/Conversation/ConversationView.swift`
  — `.searchable(isPresented:placement: .navigationBarDrawer(.always))` + `.onSubmit(of: .search)`。
    結果の面を転写に **`overlay`** で重ね、探索中は composer と `loadEarlierFooter` を描かない。

**机(backend)**
- `rc-backend/src/wire.mjs` — `historySearchBody({entries, matched, reachedStart})` を切り出し。
  ★**振る舞いは 1 つ変わる**(当初「不変」と書いたのは偽。実機を撃って判明。下の §実機 参照):
  探索の項目に `display.who` が付く様になる = 旧のハンドラが `.map(withWho)` を通していなかった欠陥の修正。
- `rc-backend/src/server.mjs` — 探索の 2 枝(探した / file が無い)を両方その封筒へ通す。

### Tests Added

- `ios/Tests/Core/TranscriptSearchResponseTests.swift`(新規、11 本)— 扉A。実機で観測した body を検体に持つ 2 本を含む。
- `ios/Tests/Core/HistoryClientTests.swift`(追記、17 本)— 扉A。要求の形・待ち時間・status 7 分岐・陰性対照 3 本。
- `ios/Tests/Screens/Conversation/ConversationViewModelTests.swift`(追記、21 本)— 扉B。
- `ios/UITests/ConversationSearchUITests.swift`(新規、10 本)— 扉C。
- `rc-backend/test/e2e-local.mjs`(追記、12 件)— **扉E**。実サーバへ HTTP。
- `rc-backend/test/wire-key-agreement.test.mjs`(追記)— 扉F。`TranscriptSearchResponse` を `PAIRS` に登録。

### 検査の結果(実測)

| 走行 | 結果 |
|---|---|
| `bash ios/tools/build.sh --sim` | **834 件 実行 / 失敗 0**(1 件 skip = 既存) |
| `rc-backend` `node test/e2e-local.mjs` | **pass=297 / fail=0** |
| `rc-backend` `npm test` | 1004 件中 **fail 2** —— どちらも**私の変更が原因ではない**(下記) |

**`npm test` の赤 2 件について(嘘の完了報告をしない為に明記):**
`bar-is-composer-only.test.mjs` の 2 本。原因は**親セッションの未 commit の意匠変更**で、
`ConversationView.swift` から `Rectangle().fill(.bar)` が消えた事(同 file の
2026-09-01 の hunk。`git show HEAD:…` には在る)。
証明: 同検査の `RC_VIEW_ROOT` の継ぎ目を使い、**私の探索の追加を全部 残したまま**
親の 1 行(`RCTheme.surface` → `.bar`)だけ戻した写しを読ませると **5/0 で緑**。
= 赤の原因は私の差分に無い。私は親のレーンの意匠判断を書き換えていない。

## 変異表(§9)—— 植えて、実際に赤が出る事を観測した記録

各行 = 変異を実際に植てて撃ち、**倒れた検査の名前とメッセージまで**見た。すべて事後に原状復帰し、
残渣が無い事を grep で確認済み(`_ = trimmed` / `decodeIfPresent(… .matched)` / `isCapped: Bool { false }` /
`scannedToStart` 等 すべて 0 件)。

| # | 植えた変異 | 倒れた検査(扉)| 出たメッセージ |
|---|---|---|---|
| M1 | `HistoryClient.search` の `URLQueryItem(name:"q",…)` を削除 | `testSearchRequestCarriesTheQueryAsQParam` / `testSearchCarriesAJapaneseQueryPercentEncoded`(A、2 件) | `("nil") is not equal to ("Optional("boot")")` / URL が `?limit=100` だけ |
| M2 | `matched` の `decode` → `decodeIfPresent ?? 0` | `testSearchBodyWithoutMatchedIsMalformedNotSuccess`(A、1 件) | `XCTAssertNil failed: "TranscriptSearchResponse(history: [], matched: 0, …)"` |
| M3 | `.emptyWhole` を `.emptyBounded` へ写像(case を畳む) | `testZeroMatchesAfterReachingTheStartIsEmptyWhole` / `testTheTwoZeroMeaningsAreNotCollapsedNegativeControl`(B、2 件)**+** `testEmptyWholeSaysThereIsNoMatchAnywhere`(C) | `("emptyBounded") is not equal to ("emptyWhole")` / `XCTAssertNotEqual failed … 言い切れない物を言い切っている` |
| M4 | `overlay` を差し替えに化かす(探索中に転写を階層から外す) | `testLandingReadoutIsUnchangedAcrossASearch`(C) | `("settled -58.0 … first=76.7 corr=4 … v=427.3") is not equal to ("settled 0.3 … first=2314.3 corr=1 … v=457.7")` ★**着地の輪が回り直した事が読み出しの数字で出た** |
| M5 | 探索中も composer を描く | `testComposerAndLoadEarlierAreAbsentWhileSearching`(C、3 件) | `探しながら机へ送れる` / `探索中に転写の窓(currentLimit)が黙って動く道が開いている` |
| M6 | 机の `searchedToStart` → `reachedStart` | `wire-key-agreement`(F、1 件)**+** `e2e-local`(E、6 件) | 鍵名 drift / `body が matched / searchedToStart を**その綴りで**持つ` |
| M7 | 机の `truncated: !reachedStart` → `truncated: reachedStart` | **`e2e-local` のみ**(E、3 件)。`wire-key-agreement` は **8/0 で緑のまま** | `truncated は searchedToStart の否定である {"t":true,"s":true}` |
| M8 | fixture が問いを無視して固定 3 行を返す | `testSearchNarrowsToTheTypedTerm` / `testDifferentQueriesProduceDifferentCountsNegativeControl`(C、5 件) | `("3 matches") is not equal to ("10 matches")` / 予期の `1 matches` が 15 秒 来ない |
| M9 | `interactiveTimeout` → `writeTimeout` | `testSearchUsesTheInteractiveTimeout` **+** `testRequestUsesTheInteractiveTimeout`(A、2 件) | `("[30.0]") is not equal to ("[20.0]")` |
| M10 | `isCapped` を `false` に固定 | `testCappedResultsAnnounceTheCap`(B)**+** `testCappedResultsSayTheyAreCappedAndThatTheScanStoppedEarly`(C) | `120 件 見つけて 100 件しか返していないのに『全部見せている』の顔になっている` |
| **M11**(spec に無い。実機の欠陥から起こした行)| `historySearchBody` の `entries.map(withWho)` → `entries`(= **旧の実機の姿**)| `★探索: 項目は素の履歴と同じく display.who を持つ`(E) | `{"role":"user","text":"最初の質問"}` ← **実機で観測したのと同じ形が再現した** |

### 変異表について、spec の予想と実測がずれた 2 点(丸めずに書く)

1. **M1 の扉E は赤くならない。** spec は「A **+** E」と書いているが、E(`e2e-local`)は
   机へ HTTP を撃つ検査なので、**電話側の 1 行を消しても原理的に赤くならない**。
   2 つの扉は同じ綴り `q` の**別の側**を守っている(A = 電話が組み立てる / E = 机が受け取る)。
   実測 = M1 で倒れたのは A の 2 本のみ。表の「両方 赤」は誤りで、正しくは「両側に 1 本ずつ要る」。
2. **M2 で倒れるのは 1 本だけ。** `testAPlainHistoryBodyDoesNotDecodeAsASearchResponse` と
   `HistoryClientTests.testSearchStatus200WithoutMatchedIsMalformedBody` は緑のまま ——
   素の履歴 body は `matched` と `searchedToStart` の**両方**を欠くので、片方を緩めても
   もう片方が復号を落とす。2 つの必須鍵が独立に効いている事の裏付けで、穴ではない。

### §8-b の陰性対照(扉F が「今日の綴りを追認するだけの器」でない事)

- Ⓐ 机側だけ改名(`searchedToStart` → `reachedStart`)→ `wire-key-agreement` **赤**(drift 検出)。
- Ⓑ **両側を揃えて**改名(机 `scannedToStart` + Swift `CodingKeys`)→ `wire-key-agreement` **8/0 緑**。
  = この検査は綴りの固定ではなく**両側の一致**を測っている。両方とも実行して観測、事後に復元済み。

## ★★実機の机を撃って見つけた欠陥 —— この機能は**出荷前から 100% 壊れていた**

依頼文が許した「本番の机へ GET だけ」を実際に使って判った、この作業で一番重い発見。

**観測(friday:9443 / 2026-09-01、GET のみ):**

```
探索      GET …/history?q=の&limit=1  → {"role":"assistant","text":"四回目も同じ…"}
素の履歴  GET …/history?limit=1        → {"role":"assistant","text":"クリーンです。","display":{"who":"Claude"}}
```

**探索の項目にだけ `display` が無い。** 旧のハンドラは `history: r.history` と生のまま返し、
素の履歴が通る `.map(withWho)` を通していなかった(`git show HEAD:rc-backend/src/server.mjs` の探索分岐 `history: r.history`)。
電話の `HistoryEntry.display` は**非 optional** なので、この応答は復号ごと落ちる ——
実機で探索すると必ず `The desk's answer wasn't in a form this app can read.` になる。
`HistoryClient` を書いても `ViewModel` を書いても、**画面には一度も結果が出なかった**。

**なぜ木の中の誰も捕まえられなかったか(此処が本題):**
fixture も、私が書いた検体 body も、`e2e` の期待値も、**全部 `display` を入れて組んである**。
検体は自分が知っている形しか名乗らない。832 件の iOS 検査と 297 件の e2e が全部 緑でも、
「机が本当に何を吐くか」は 1 件も測っていなかった。実機へ 1 回 GET を撃つまで見えない欠陥。

**直し:** `historySearchBody` が `.map(withWho)` を通す(素の履歴と同じ 1 本の道)。
→ **`wire.mjs` の doc に最初「振る舞いの変更はゼロ」と書いたのは偽**だったので訂正した。
   この切り出しは**振る舞いを 1 つ変える** = 探索の項目に `display.who` が付く。

**守り(2 つの扉に 1 本ずつ、両方 赤を実測):**
- 扉E `e2e-local.mjs`「探索の項目も `display.who` を持つ」+ 対照「素の履歴と同じ規則で付く」
- 扉A `TranscriptSearchResponseTests.testEntriesWithoutDisplayDoNotDecodeTheShapeTheRealDeskWasSending`
  (**実測した body そのもの**を検体にした)+ 陰性対照 1 本

**まだ終わっていない事(Tom の行動が要る):**
直したのは**この作業木の `rc-backend`**。**実機の机はまだ旧のコードで動いている**ので、
今 電話から探索しても壊れたままである。配備は production への外部影響なので、
本セッションの範囲(GET のみ)の外に置いた。**配備するまでこの機能は実機で使えない。**

## 検査が教えた製品の欠陥 2 件(spec を書いた時点では見えていなかった)

どちらも「実装してから検査を書いた」ではなく、**検査が赤で出したので直した**もの。

1. **回り続ける独楽**(`ConversationViewModel`)。
   spec §2-c の表は `.unauthorized` を「`searchState` は触らない」と書いており、私は
   `applySearch` の中で触らない事だと読んだ。しかし `search()` は既に `.running` を置いた後で、
   結果を持たない終わり方(鍵の失効 / 会話の消失 / 契約違反 / 取り消し)では
   **面が永久に `Searching…` のまま**になる。実測 =
   `testUnauthorizedEscalatesAndLeavesTheSearchFaceAlone` と `testCancelledLeavesTheFaceWhereItWas` が赤。
   → 直し: `loadEarlier()` の `stateBeforeAttempt` と**同じ形**で面を退避し、
   その 4 つの終わり方で戻す。呼び出し全体を通して面が変わらない = 表の意図を満たす。

2. **結果の面から出られない**(`ConversationView`)。
   spec は `.searchable` が取り消しを常に用意する前提で書かれていたが、**偽だった**:
   `displayMode: .always` の "Cancel" は**入力中しか出ない**。`\n` で確定すると Cancel が消え、
   `isPresented` は真のまま —— composer も「以前を読む」も隠してあるので、**会話が使えなくなる**。
   実測 = `testTheDraftSurvivesOpeningAndCancellingASearch` が「Cancel が 5 秒 現れない」で赤。
   → 直し: 面が自分で出口を持つ(`conversation.search.close` = "Done")。
   併せて、まだ何も探していない間の**空の板**に案内を 1 行置いた(`conversation.search.hint`)。

## spec から意図的に外れた点(= 増やした物。すべて理由付き)

| 追加 | 識別子 | 理由 |
|---|---|---|
| 結果の面の出口 | `conversation.search.close` | 上記 2。spec の前提(`.searchable` が Cancel を出し続ける)が実測で偽 |
| 探す前の案内 | `conversation.search.hint` | 面は `isSearchPresented` の間ずっと出るので、空白の板になる時間が在る |
| 見出し行 | (識別子なし) | spec §3 の「上端に 1 本の区切りと見出し行」 |

## やっていない事(v1 の範囲外。spec §10 のまま、+ 実測で足した 1 件)

- 結果から転写のその行へ**跳ぶ**(机が位置を返していない。面の脚に理由を 1 行 出している)
- 一致箇所のハイライト / 行の折り畳み / 全会話横断の検索 / 索引・キャッシュ・結果の保持
- 正規表現・語境界・AND/OR / `role` や日付での絞り込み
- **走査距離を伸ばす**(`maxBytes` 1 MiB / `scanned` を線へ載せる)= 別 spec。
  ★Tom への報告事項(質問ではない): 探索が見るのは転写の**末尾 1 MiB だけ**。同 repo の実測で
  一番長い会話は 280 MB なので到達距離は最悪 0.36%。だから画面は既定で「見つかりません」と
  言い切らない(S4 / S6)。**この機能の実用性を最も左右する変数はここ**。
- **UI 検査の 1 点**: 結果の行が「押せない」事は目視の設計であって、検査で測っていない
  (押せる見た目を出していない事を機械で測る手を持っていない)。

## Setup Instructions

- iOS ビルド + 全検査: `RC_XCODE_TREE_LOCK_WAIT_S=1500 bash ios/tools/build.sh --sim`
- 机の検査: `cd rc-backend && npm test` / `node test/e2e-local.mjs`
- 画面を手で見る: `RC_UI_FIXTURE=conversation-search` /
  `RC_UI_FIXTURE=conversation-search-unreachable` で `--sim-app`
- 依存の追加: **無し**(新しい package も pod も入れていない)

## Evaluation History

- 走行 1(実装直後): コンパイル error 1 件 → 修正。
- 走行 2: 832 件中 6 件 赤。内訳 = 私の欠陥 2 件(上記)/ 私の検査の錨の誤り 3 件
  (一番下の転写行を「読み込み完了」の錨にしていた。混んだ走行で 15 秒に間に合わない)/
  環境 1 件(`AttachButtonUITests` が実机へ届かず `conversation.retry` を見ていた。
  次の走行では同じ検査が緑 = 私の差分と無関係)。
- 走行 3: **832 件 / 失敗 0**。
- 走行 4(実機の欠陥を受けて検査 2 本 追加後): **834 件 / 失敗 0**、`e2e` 297/0。
- 変異走行 13 本(M1–M11 + 扉F の Ⓐ/Ⓑ): すべて狙った検査が赤くなる事を観測。
