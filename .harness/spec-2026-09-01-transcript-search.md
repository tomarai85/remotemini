# spec — 会話の転写を電話から探す(iOS 側 UI)v1

作成: 2026-09-01。所有者 = **本ファイルのみ**。共有の `.harness/spec.md` は触らない(並行セッション有り)。
上流 = 実装の実測(`rc-backend/src/server.mjs` の `action === "history"` 分岐 /
`rc-backend/src/sessions.mjs` の `searchHistoryFromPath` / `rc-backend/src/listing.mjs` の `readLinesBackward` /
`ios/Sources/Screens/Conversation/*` / `ios/Sources/Core/History*.swift`)、
`DESIGN.md:1379`(検索は未実装の一覧に載っている)、
`rc-backend/test/history-search.test.mjs`。

**判断が割れる点は §11 `## Design Decisions` に集約した(`has_design_decisions: true`)。**
本文はその決定に依存する箇所へ `→ D-x` で参照を張ってある。

---

## 0. 実測した前提 —— 依頼文に無い、設計を変える3つの事実

依頼文の記述はすべて再現できた(大小無視 / 日本語可 / `matched >= limit` で停止 /
`searchedToStart` で 0 件の 2 意味を分ける)。その上で、**依頼文に書かれていない事実が3つ**
出てきて、いずれも画面の設計を動かす。先に置く。

### 0-1. ★走査は「最後の 1 MiB」で切れる。会話の頭まで見る事は事実上ほぼ無い

`server.mjs` の探索分岐は `searchHistoryFromPath(target, q, limit)` を **`opts` 無し**で呼ぶ。
`opts.maxBytes` が `undefined` なので `readLinesBackward` は既定値へ落ちる:

| 定数 | 値 | 出典 |
|---|---|---|
| `TAIL_CHUNK` | 64 KiB | `rc-backend/src/listing.mjs` の `export const TAIL_CHUNK` |
| `TAIL_MAX` | **1 MiB** | `rc-backend/src/listing.mjs` の `export const TAIL_MAX`(註「後方へ遡る上限。これを超えたら incomplete と言う」) |

一方 `readHistoryFromPath` の doc が実測を書いている —— **一番長い会話は 280 MB**。
つまり探索が見るのは最悪 **0.36%**。3 時間走ったセッションで「どこで転けたか」を探す、という
`searchHistoryFromPath` の doc が掲げる動機に対して、**現状の到達距離は転写の末尾 1 MiB しかない**。

画面への含意は 2 つ、どちらも重い:

1. **`searchedToStart: true`(= 会話の頭まで見た)は、短い会話でしか出ない。**
   だから「見つかりません」と言い切れる場面は稀で、**既定の 0 件は "走査した範囲に無かった" の方**。
   之を「見つかりません」に丸めた瞬間、電話は毎回 嘘をつく。
2. **電話は「どこまで見たか」を数で言えない。** ルートは `searchHistoryFromPath` の返す
   `scanned`(走査バイト数)を**転送していない**(返すのは `history` / `matched` / `truncated` /
   `searchedToStart` の 4 つだけ)。`HistoryEntry` にも位置も時刻も無い。
   → 文面から**数量・時刻・件数の目安を全部落とす**。言えるのは「頭までは見ていない」だけ。

  (サーバへ `scanned` を足す / `maxBytes` を上げるのは本 spec の範囲外。§10 に候補として残す。)

### 0-2. `truncated` が探索応答では**別の意味**を運んでいる —— 現状の型は当てると壊れる

素の履歴では `truncated` = 「これより前が在る」。探索では `truncated: !r.reachedStart` =
「最初まで見ていない」。**同じ鍵、別の意味**。サーバ側はこの上書きを註釈で明言していて意図的。

ところが電話側の `HistoryResponse.truncated` は **`loadEarlierState` を決める入力**である
(`ConversationViewModel.resolveLoadEarlierState`)。探索応答を `HistoryResponse` で受けると、
`truncated` が「以前を読む」ボタンの状態へ流れ込む。**探索の走査距離が、転写の読み進みボタンを動かす。**

さらに `HistoryClient.fetch(…, query:)` は**既に存在し、`q` を組み立てて送っている**
(`ios/Sources/Core/HistoryClient.swift` の `fetch` が受ける `query:` 引数)。今日この口を呼ぶ本番経路は無いが、口は開いている。

→ **v1 の第一歩は「探索応答を `HistoryResponse` で受けない」型の分離**。§2-a。

### 0-3. `q` を送る経路は、iOS 側の検査に**1件も触れられていない**

- `grep -rn 'q=' ios/Tests ios/Sources` の結果は `HistoryClient.swift` の `query:` 経路 **1 件のみ**。
- `ios/Tests/Core/HistoryClientTests.swift` に `query` を渡す検査は無い(`limit=150` を見る
  `testRequestURLCarriesSessionIDAndLimit` はあるが `q` は見ていない)。
- `rc-backend/test/history-search.test.mjs` は `searchHistoryFromPath` を **import して直接呼ぶ**。
  = 関数の扉。**`?q=` を HTTP から叩く検査は 1 本も無い**(`e2e-local.mjs` は `/history` を
  8 箇所 叩くが、`q` 付きは 0)。

2026-08-31 の実例(iOS 777 件 + backend 1000 件が全部緑のまま、`server.mjs` の宣言順序の誤りで
全ルートが死んでいた。捕まえたのは**実際にサーバを起動して HTTP を叩く** `account-nonblocking-controls.sh`
1 本だけ)がそのまま当てはまる。**配線を足すのだから、関数の扉の検査は証拠にならない。** §8。

---

## 1. この画面が何であるか(と、何でないか)

**在る物**: 転写の末尾 1 MiB を対象に、大小を無視した部分一致で絞り、一致した発話を新しい順に並べる面。
**無い物**: 転写のその行へ跳ぶ機能(→ §5、原理的に今日は作れない)。全文検索。索引。ハイライト。

一言で言うと **「読む為の面」ではなく「在ったか無かったかを、嘘をつかずに答える面」**。
`searchHistoryFromPath` の doc が自分で「設計の中心は速く探す事ではなく、見つからないを正直に言う事」
と書いていて、電話側もその一文に従う。

---

## 2. 機能

### Feature 2-a: 探索応答を運ぶ型を、履歴とは別に立てる

- 説明: `TranscriptSearchResponse: Decodable` を新設する。鍵は `history` / `matched` /
  `searchedToStart` の 3 つ。**`truncated` は復号しない**(§0-2。探索文脈では `!searchedToStart` の
  写しでしかなく、2 本置けば必ず片方が先に古くなる。読まない理由を型の doc に書く)。
- 分類は `Bool` のまま画面へ流さず、**enum で受ける**(規約 1):

  ```
  enum TranscriptScanCoverage: Equatable {
      case wholeConversation   // searchedToStart == true
      case boundedScan         // searchedToStart == false
  }
  ```

- ★**`matched` と `searchedToStart` は必須鍵**。`decodeIfPresent ?? …` にしない。
  理由が `HistoryResponse.truncated` と**逆向き**である事を doc に書く:
  `truncated` は「鍵の不在」と「false」が電話にとって同じ意味だから緩く受けてよい。
  `matched` の不在は **「このサーバは探索していない」**(= 素の履歴経路が返った)であって、
  どの値とも違う。緩く受けると **直近の履歴窓を「一致」として描く** —— 一番出してはいけない嘘。
- Acceptance Criteria:
  - [ ] `{"history":[],"matched":0,"searchedToStart":true}` が `.wholeConversation` / `matched == 0` に復号する
  - [ ] `{"history":[…],"matched":7,"searchedToStart":false}` が `.boundedScan` / `matched == 7` に復号する
  - [ ] **陰性対照**: `matched` を落とした body は復号に**失敗**する(`.success` にならない)
  - [ ] **陰性対照**: `searchedToStart` を落とした body は復号に**失敗**する
  - [ ] `truncated` を含む body も含まない body も同じ結果へ復号する(読んでいない事の対照)
  - [ ] 未知の `role` は `.unknown` へ落ちて復号は成功する(`HistoryEntry` の既存規約の継承確認)

### Feature 2-b: `HistoryClient` に探索の口を足し、履歴の口から `query` を**外す**

- 説明: `HistoryFetching` に
  `search(baseURL:apiKey:sessionID:limit:query:) async -> Result<TranscriptSearchResponse, SessionsFetchError>`
  を足す。**同じ `HistoryClient` struct・同じ URL 組み立ての私有ヘルパを共有**する
  (`HistoryClient` の doc「口は 1 本、引数で分ける」が禁じているのは *client 型を 2 本置く事*
  であって、同じ型の中で戻り値の形が違う 2 メソッドが 1 本の request builder を共有する形は
  その趣旨に合致する)。
- ★同時に `fetch(…, query:)` の `query` 引数を**削除**する。残すと「`HistoryResponse` の
  `truncated` が探索文脈の意味で入ってくる」経路が生きたままになる(§0-2)。
  今日この引数へ非 nil を渡す本番経路は無く、影響は `HistoryFetchingFixture` と
  `ConversationViewModelTests` の二重体 2 箇所のみ。
- 送信規約は既存の口と揃える: `Bearer` header / `GET` / body 無し /
  `BackendSession.interactiveTimeout`(= 20s、`ios/Sources/Core/BackendSession.swift` の同名 static)。
- 空白のみの問いは送らない(既存 `HistoryClient.swift` の `fetch` 冒頭の trim 判定を引き継ぐ)。
- Acceptance Criteria(規約 2 = URL / method / header / body **+ 待ち時間**):
  - [ ] URL の query が `limit=<N>` と `q=<percent-encoded>` の両方を持つ
  - [ ] 日本語の問い(`こんにちは`)が percent-encode されて往復し、`matched` が返る
  - [ ] method が `GET`、request body が空
  - [ ] `Authorization: Bearer <key>` が付く
  - [ ] `timeoutInterval == BackendSession.interactiveTimeout`
  - [ ] 空白のみの問いでは `q` が**付かない**
  - [ ] 状態写像: 200→`.success` / 401→`.unauthorized` /
        404+`SESSION_NOT_FOUND`→`.notFound` / 404+他 code→`.contractViolation` /
        200+復号不能→`.malformedBody` / 接続失敗→`.unreachable` / 取り消し→`.cancelled`
  - [ ] **陰性対照**: 上の 7 分岐が 1 つに畳まれていない事を、既存
        `HistoryClientTests` の `…NegativeControl` 群と同じ形で 3 本以上

### Feature 2-c: ViewModel に探索の状態機械を置く

- 説明: `ConversationViewModel` に `@Published private(set) var searchState: TranscriptSearchState`
  を足す。**既存の `history` / `live` / `truncated` / `currentLimit` / `loadEarlierState` を
  一切書き換えない**(探索は転写の窓を動かさない)。

  ```
  enum TranscriptSearchState: Equatable {
      case idle
      case running(query: String)
      case results(TranscriptSearchResults)   // matched > 0
      case emptyBounded(query: String)        // matched == 0 && coverage == .boundedScan
      case emptyWhole(query: String)          // matched == 0 && coverage == .wholeConversation
      case failed(TranscriptSearchFailure, query: String)   // .unreachable / .malformedBody のみ
  }

  struct TranscriptSearchResults: Equatable {
      let query: String
      let rows: [HistoryEntry]        // 新しい順(§4-c、D-D)
      let matched: Int                // 走査範囲で見つかった総数
      let coverage: TranscriptScanCoverage
      var isCapped: Bool { matched > rows.count }
  }
  ```

- ★**`emptyBounded` と `emptyWhole` を 1 つの case に畳まない。** 依頼文の設計の核心であり、
  畳んだ瞬間に「見つかりません」と言い切れない物を言い切る形になる。畳みを防ぐ陰性対照を置く。
- ★**探索の行に `MergeHistory.merge` を通さない。** `live` は転写の末尾に来る追記で、
  探索結果と混ぜる意味が無い。`entries` computed(`MergeHistory.merge(history, live)`)は
  転写専用のまま。
- 失敗の振り分け(→ D-E):
  | 失敗 | 行き先 | 理由 |
  |---|---|---|
  | `.unauthorized` | `onUnauthorized()` | 鍵の話。会話も含めて全部が使えない |
  | `.notFound` | `phase = .notFound` | 会話そのものが消えた。`applyLoadEarlier` と同じ扱い |
  | `.contractViolation` | `applyContractViolation(_:)` | 再試行で治らない。既存の全面表示に合流 |
  | `.unreachable` | `.failed(.unreachable, …)` | **探索の面の中**。転写は生きている。再試行を出す |
  | `.malformedBody` | `.failed(.malformedBody, …)` | 同上。探索応答の形は履歴応答の形と別物なので、転写の健康を否定しない |
  | `.cancelled` | 何もしない | 「新しい要求が結果を持つ」— `applyInitial` の既存規約 |
- ★**多重発火の防止**: `isSearching` の同期フラグ(`await` の前に立てる)で二重起動を止める。
  `loadEarlier()` の `isFetchingEarlier` と同じ形。
- Acceptance Criteria:
  - [ ] `matched: 3 / searchedToStart:false` → `.results`、`rows.count == 3`、`coverage == .boundedScan`
  - [ ] `matched: 0 / searchedToStart:false` → `.emptyBounded`
  - [ ] `matched: 0 / searchedToStart:true` → `.emptyWhole`
  - [ ] **陰性対照**: 上の 2 つを同一視する変異(片方を他方へ写像)で赤くなる検査が在る
  - [ ] `matched: 120 / rows.count: 100` → `isCapped == true`
  - [ ] 探索の前後で `history` / `truncated` / `currentLimit` / `loadEarlierState` が**不変**
  - [ ] 探索中に poll が `live` を伸ばしても、`searchState.rows` は変わらない
  - [ ] `.unauthorized` は `onUnauthorized()` を呼ぶ(`searchState` は触らない)
  - [ ] `.notFound` は `phase` を `.notFound` にする
  - [ ] 探索が走っている間の 2 回目の起動は要求を 1 本に保つ

### Feature 2-d: 画面 —— 検索欄と結果の面

- 説明: `ConversationView` に `.searchable` を付け、検索が有効な間だけ結果の面を
  **転写の上に `overlay` として重ねる**(転写は階層から**外さない**。理由 §6)。
- 置き場所(→ D-A): `.searchable(text:placement: .navigationBarDrawer(displayMode: .always))`。
  この画面は既に `.navigationBarTitleDisplayMode(.inline)` なので、`.always` にすると
  **ナビ周りの高さが常に一定**になり、着地の輪が測る `viewportHeight` が探索の開閉で動かない。
- 発火(→ D-B): **`.onSubmit(of: .search)` のみ。打鍵ごとには撃たない。** 根拠は §7。
- 検索が有効な間、**composer と `loadEarlierFooter` を描かない**。
  - composer を残すと、探しながら机へ送れてしまう(送信ボタンが結果の面の下で生きる)。
  - `loadEarlierFooter` を残すと、探索中に `currentLimit` と `history` が黙って動く。
  - ★下書きは失われない —— `ConversationViewModel.draft` は `didSet` で打鍵ごとに
    `draftStore` へ書かれる(`ConversationViewModel.swift` の `@Published var draft` の didSet)。面を消しても値は残る。
- poll は**止めない**。`stopPolling()` は `body` の `.onDisappear` の持ち物のままにする。
- Acceptance Criteria:
  - [ ] 検索欄に語を入れて submit すると、その語を含む行だけが並ぶ(fixture の面で確認)
  - [ ] submit するまで要求が 1 本も飛ばない(打鍵では飛ばない)
  - [ ] 検索が有効な間、`conversation.composerField` / `conversation.sendButton` /
        `conversation.loadEarlier` が**存在しない**
  - [ ] 下書きを打ってから検索 → 取り消し で、下書きが composer に残っている
  - [ ] 検索を取り消すと結果の面が消え、転写が元の位置のまま見えている

### Feature 2-e: 5 つの面の文言(規約 1 = 言い換えない / 分類は型で受ける)

既存の Conversation 画面の文字列は英語(`"Load earlier"` / `"Try again"` /
`"Older messages exist, but the phone shows at most the latest 500"`)。それに揃える。

**独立した事実は独立した行に置く**(`statusBanners` の既存規約「3 つは互いに独立、各々が単独で出る」
と同じ)。1 行に詰めると、片方だけが真の時に嘘が混ざる。

| # | 条件 | 出る物 | identifier |
|---|---|---|---|
| S1 | `.running` | `Searching…` + 進捗 | `conversation.search.busy` |
| S2 | `.results` 常に | `<matched> matches` | `conversation.search.summary` |
| S3 | `.results` かつ `isCapped` | `Showing the newest <rows.count>.` | `conversation.search.shownCap` |
| S4 | `.results` かつ `coverage == .boundedScan` | `The search stopped before the start of this conversation.` | `conversation.search.boundedScan` |
| S5 | `.emptyWhole` | `No match anywhere in this conversation.` | `conversation.search.emptyWhole` |
| S6 | `.emptyBounded` | `No match in the part that was searched. The search stopped before the start of this conversation.` | `conversation.search.emptyBounded` |
| S7 | `.failed(.unreachable)` | `Couldn't reach the desk.` + `[Try again]` | `conversation.search.failed` / `conversation.search.retry` |
| S8 | `.failed(.malformedBody)` | `The desk's answer wasn't in a form this app can read.` + `[Try again]` | 同上 |

★ S4 / S6 は**数量も時刻も言わない**(§0-1: 電話は `scanned` を持っていない)。
★ S5 だけが言い切りの文。`.wholeConversation` の時にしか出ない。
★ S3 と S4 は**独立**。両方真なら 2 行とも出る。
★ どの面から来たか: S1 は `.idle` から submit で。S2-S6 は S1 から。S7/S8 は S1 から。
  取り消しは**どの面からでも** `.idle` へ戻る(結果は捨てる。保持しない = §10)。

---

## 3. 結果の行の描き方

- 本文は **`EntryBubble` をそのまま再利用**する。転写と結果で本文の描画器を 2 本置くと、
  片方だけ古くなる(`entriesFromRecord` を 1 本にしている机側の判断と同じ)。
- 面の地は転写と**別の材質**にする。★`.bar` の灰色は敷かない —— `ConversationView` の
  §2.63 の裁定で、この画面の灰色は「電話の道具」を意味する材質として既に予約されている。
  結果の面は転写と同じ地の上に、**上端に 1 本の区切りと見出し行**を置いて所属を示す。
- **ハイライトしない**(→ D-C)。ハイライトには電話側で `range(of:options:.caseInsensitive)` を
  引く必要が在り、それは机の照合規則(`toLowerCase().includes`)の **2 本目の実装**になる。
  食い違った日、行は出るのにハイライトが無い = 「誤検出」に見える。
- **行を短く切らない**(`lineLimit` を付けない)。付けると、一致箇所が見えている範囲の外に
  在る行が「誤検出」に見える。`HistoryModels.swift` の「no truncation in v1」を継承する。
- 行は**押せない**。押せる見た目(chevron / タップ時の反転)を出さない。理由は §5。

---

## 4. 数と並び

| 項目 | 値 | 理由 |
|---|---|---|
| `limit` | **100**(→ D-D) | 机の上限は 500(`server.mjs` が `Math.min(…, 500)`)。1 MiB の窓に 500 一致は現実に起き、その時 payload が携帯回線に重い。100 なら 1 画面ぶんの往復で収まり、超過分は S3 が正直に名乗る |
| 並び | **新しい順**(→ D-D) | 机は古い順で返す(`all.slice(-limit)`)ので電話側で反転する。動機が「どこで転けたか」= 直近の一致なので、一番役に立つ行が最上段に来る。**副次的に重要**: 一番上から始まる面は下端へ寄せる機構を要らなくする = 着地の輪に一切触れない(§6) |
| 一致の規則 | 机に任せる | 電話は照合を実装しない(§3) |

★`matched >= limit` でも `maxBytes` 到達でも `searchedToStart:false` になり、**線の上に
区別が無い**。だから S4 / S6 の文は「なぜ止まったか」を言わない。言えるのは「頭までは見ていない」だけ。

---

## 5. 結果からその行へ戻れるか —— **戻れない。v1 では作らない**

作れない理由は好みではなく、線に情報が無いから:

1. `HistoryEntry` は `role` / `text` / `display.who` の 3 つだけ。**id も位置も時刻も無い。**
2. ルートは `searchHistoryFromPath` の `scanned` を転送していない。
3. 電話側で `MergeHistory.sameRoleAndText` を使って `history` の中を引く手は在るが、
   - 一致が読み込み済みの窓(既定 50 件)の中に在る場合しか当たらない ——
     **探索が要る場面ほど当たらない**(窓の外を探すのが目的なので)。
   - 同じ本文が複数在れば最初の 1 件に当たる。`ConversationViewModel.sameOldest` の doc が
     この弱点(`mergeHistory` case 6)を既に名指ししている。
   - 結果として「跳べる行と跳べない行が混在する面」になり、しかも**跳び先が間違っている事が在る**。
     押した先が違う行である UI は、押せない UI より悪い。

→ **行は押せない**。押せない事の説明を面の脚に 1 行置く:
`Results can't jump into the transcript yet — the desk doesn't say where each match sits.`
(identifier `conversation.search.noJumpNote`)。
機能を出さない事と、出さない理由を黙る事は別。

跳べる様にする道は §10 に残す(机が各一致に位置を付けて返す)。

---

## 6. 着地(初回の最下部への寄せ)を壊さない —— これが本 spec で一番硬い制約

`ConversationView` は 2026-08-31 に 1 セッションを費やして安定させた**閉じた輪**を持っている:

```
onPreferenceChange(ContentMetrics) ─┐
onPreferenceChange(ViewportHeight) ─┴→ [門: initialLandingPending] → contentMetrics 代入
    → distanceToBottom → reassertLanding → proxy.scrollTo(bottomAnchor) → layout → preference …
```

終端は `distanceToBottom <= 0.5`。栓は `maxLandingCorrections = 12` と
`maxStalledLandingPasses = 3`。門(`guard initialLandingPending`)は**代入の前**に在り、
着地が終わると `contentMetrics` / `viewportHeight` は**凍結する**。

### 6-a. だから探索は「重ねる」。「差し替える」を採らない(→ D-A)

`if isSearching { results } else { transcript }` にすると、取り消しで転写の `ScrollView` の
`.onAppear` が再発火 → `armInitialLanding()` → **`landingCorrections` と
`firstLandingDistance` がリセットされ、着地が最初からやり直しになる**。
上へ遡って読んでいた人は取り消した瞬間に下端へ引き戻される。

`overlay` なら転写は階層に残り、`.onAppear` は再発火しない。門は既に閉じているので、
背後で layout が続いても `@State` は書かれない。

### 6-b. 壊れていない事の測り方 —— 既に在る計器を使う

`ConversationView` は `conversation.landingDistance` という accessibility 要素に
`landingReadout`(`settled <残り pt> <hog> first=… corr=… <sab> h=… top=… v=…`)を出している。
門のおかげでこの値は着地後**凍る**。したがって:

- [ ] **検索の開閉を跨いで `conversation.landingDistance` の `accessibilityValue` が
      バイト単位で同一である。** `corr=` が増えず、`first=` が変わらない事が、
      「着地の輪が再起動していない」の直接の証拠。
- [ ] 検索が有効な間に `tailToken` が進んでも(poll の追記)、取り消し後の転写は下端に居る
- [ ] 検索欄は `.always` なので、開閉で `v=`(viewportHeight)が変わらない

★**陰性対照**: 上の差し替え版(`if isSearching { … } else { … }`)を注入すると、
`corr=` が 0 に戻り `first=` が変わって、この検査が赤くなる。
赤くならなければ、測っているのは着地ではない。

---

## 7. 打鍵ごとに撃たない —— 負荷の根拠(依頼文の★に対する回答)

依頼文は「毎打鍵で撃つ設計を採るならその負荷の根拠を書け」と求めている。**採らない**。
根拠を、机の実測値から 4 つ:

1. **机の 1 回あたりの仕事は「最大 1 MiB の後方読み + その全行の `JSON.parse`」。**
   `entriesFromLines` は走査した全行を毎回 parse する(`done` の判定でも parse する)。
   64 KiB チャンク × 最大 16 回 + 1 MiB ぶんの JSON 構文解析が、**打鍵ごと**に走る。
   同じ機械で Claude Code のセッションが走っている(それがこの製品の存在理由)。
2. **日本語の入力で最悪化する。** IME の未確定文字列は打鍵ごとに変わり、その大半は
   **どこにも一致しない** = `matched` が `limit` に届かない = **毎回 1 MiB を読み切る**。
   一致が多い問いほど早く止まる設計なので、**負荷は「まだ意味を成していない文字列」で最大**になる。
3. **順序保証の機構を丸ごと新設する事になる。** `interactiveTimeout` は 20 秒。
   携帯回線で 8 打鍵すれば最大 8 本が同時に飛び、**返る順は送った順ではない**。
   古い応答が新しい結果を上書きしない様にするには「最新の要求だけが結果を持つ」札が要る。
   `HistoryClient` は `.cancelled` を返す口を持ち `applyInitial` は
   「a newer request owns the outcome」で無視するが、**探索にはその札がまだ無い**。
   打鍵ごとに撃つ設計は、この機構を作る費用を丸ごと払う —— 払う先は速さではなく、
   「まだ意味を成していない文字列で机を焼く」事である。
4. **debounce は 2 の解にならない。** IME の変換中の停止は普通に 300ms を超える。
   止まる度に未確定文字列で撃つ。

→ **submit のみ**。加えて **最小文字数の門は置かない**(日本語の 1 文字は正当な問い。
机は空だけを拒む —— `searchHistoryFromPath` の「空の問いを全件一致にしない」)。

---

## 8. 検査は**どの扉から入るか**(規約 5)

| 扉 | 何が守れて、何が守れないか | 本 spec で足す物 |
|---|---|---|
| **A. Swift 関数**(`ios/Tests/Core`) | 復号・写像・状態機械。**配線と URL の実体は守らない** | `TranscriptSearchResponseTests`(2-a)/ `HistoryClientTests` への探索群(2-b) |
| **B. Swift ViewModel**(`ios/Tests/Screens`) | 状態遷移と不変条件。**View の描画は守らない** | `ConversationViewModelTests` への探索群(2-c) |
| **C. 実アプリの画面**(`ios/UITests`、`RC_UI_FIXTURE` 経由・network stub 無し) | 描画・識別子・composer の消滅・**着地の読み出し** | `ConversationSearchUITests`(新規) |
| **D. backend 関数**(`history-search.test.mjs`) | 絞り込みと `reachedStart` の意味。**ルートは守らない** | 既存のまま(足さない) |
| **E. backend HTTP**(サーバを起動して叩く) | **ルートの配線・鍵名・`q` の綴り・`truncated` と `searchedToStart` の関係** | **`e2e-local.mjs` に `?q=` の往復を追加(本 spec の必須項)** |
| **F. 木を跨ぐ突き合わせ** | 鍵名の drift / request の形 / 秒数の写し | `wire-key-agreement.test.mjs` の `PAIRS` に新型を登録 |

### 8-a. 扉 E が必須である理由

§0-3 の通り、`?q=` を HTTP から叩く検査は**今日 0 本**。
2026-08-31 の実例(全ルート死亡・iOS 777 件と backend 約 1000 件が全部緑・
唯一の検出者が HTTP を叩く対照 1 本)が
そのまま当てはまる。`e2e-local.mjs` は既にサーバを起動して `/history` を叩いているので、
**そこに 1 本足すのが最も安い正しい場所**。

扉 E で見る事(関数の扉では原理的に見えない物だけ):
- [ ] `GET /api/sessions/<id>/history?q=<語>&limit=100` が 200 で返る
- [ ] body が `matched` / `searchedToStart` を**その綴りで**持つ
- [ ] `truncated === !searchedToStart` が成り立つ(電話が読まない鍵なので、**机側でしか守れない**)
- [ ] `q` 無しの応答が `matched` を**持たない**(2 経路が実際に分かれている)
- [ ] 日本語の問いが percent-encode されて往復する

### 8-b. 扉 F の前提 —— 机側に小さな純粋 refactor が 1 つ要る(→ D-F)

`wire-key-agreement.test.mjs` は **サーバの builder を実行して**出た鍵と、
Swift の `CodingKeys` を突き合わせる。素の履歴は `historyBody({entries, truncated})`
(`rc-backend/src/wire.mjs` の `withWho`)を通っているので組める。
**探索の分岐は `json(res, 200, { … })` を直書き**していて builder が無い =
実行して鍵を採る側が存在しない。

規約 4(新しい `Decodable` は「突き合わせる検査」か「突き合わせない理由」のどちらかに入れる)を
**突き合わせる側**で満たすには、`wire.mjs` に
`historySearchBody({ entries, matched, reachedStart })` を切り出し、ルートをそれ経由にする
(**振る舞いの変更ゼロ**)。その上で `PAIRS` に
`{ swift: "TranscriptSearchResponse", builders: ["historySearchBody"], at: "" }` を足す。

- [ ] `TranscriptSearchResponse` が `PAIRS` に居る(`UNPAIRED` 送りにしない)
- [ ] **陰性対照**: 机側の `searchedToStart` を `reachedStart` へ改名すると drift が赤くなる
- [ ] **陰性対照**: 両側を**揃えて**改名した木は緑のまま(検査が今日の綴りを追認するだけの器に
      なっていない事。`wire-vocabulary-agreement-controls.sh` の Ⓐ/Ⓑ と同じ形)

### 8-c. fixture(`HistoryFetchingFixture`)の更新

現状の fixture は `query` を受けて実物と同じ絞り方をするが、**`truncated: false` を返す**
(= `HistoryResponse` しか無かったので当然)。新型に移す時、fixture は
**`matched` と `coverage` を実際に計算して返す**事。固定値を返すと、面が「探した振り」で緑になる
(fixture 自身の doc がその危険を既に書いている)。

- [ ] UI の面で 5 状態(S2/S3/S4 の組・S5・S6・S7)が**全部到達可能**な fixture 状態が在る
- [ ] `.emptyWhole` と `.emptyBounded` を**別々に**出せる(片方しか出せない fixture は、
      §2-c の核心の検査を UI の扉から不能にする)

---

## 9. 変異表 —— 「この行を壊すと、どの検査が赤くなるか」

各行は **陰性対照の対**(規約 6)。狙った検査**だけ**が赤くなる事まで確認する
(`port-coverage-controls.sh` が「倒れた項の名前まで見る」のと同じ)。

| # | 壊す行 | 壊し方 | 赤くなる検査(扉) | 何を掴んでいるか |
|---|---|---|---|---|
| M1 | `HistoryClient.search` の `URLQueryItem(name:"q",…)` | 行ごと削除 | `HistoryClientTests.testSearchRequestCarriesTheQueryAsQParam`(A) **+** `e2e-local` の `?q=` 往復(E) | `q` が線に乗る事。A だけだと綴りの実体は守れない |
| M2 | `TranscriptSearchResponse` の `matched` の復号 | `decode` → `decodeIfPresent ?? 0` | `…testSearchBodyWithoutMatchedIsMalformedNotSuccess`(A、陰性対照) | 「探索していないサーバの応答を一致として描かない」 |
| M3 | `TranscriptSearchState` | `.emptyWhole` を `.emptyBounded` へ写像(case を畳む) | `ConversationViewModelTests.testTheTwoZeroMeaningsAreNotCollapsedNegativeControl`(B) **+** `ConversationSearchUITests`(C、`conversation.search.emptyWhole` が見つからない) | 依頼文の核心。0 件の 2 意味 |
| M4 | `ConversationView` の探索の重ね方 | `overlay` → `if isSearching { … } else { transcript }` | `ConversationSearchUITests.testLandingReadoutIsUnchangedAcrossASearch`(C) | 着地の輪が再起動していない事(§6) |
| M5 | `ConversationView` の composer の条件 | 探索中も composer を描く | `…testComposerAndLoadEarlierAreAbsentWhileSearching`(C) | 探しながら送れてしまう形 |
| M6 | `server.mjs` の応答の鍵名 | `searchedToStart` → `reachedStart` | `wire-key-agreement`(F、drift) **+** `e2e-local`(E) | 鍵名の写しが両側で一致する事(規約 3) |
| M7 | `server.mjs` の `truncated: !r.reachedStart` | `truncated: r.reachedStart` | `e2e-local` の `truncated === !searchedToStart`(E) **のみ** | **電話が意図的に読まない鍵**。机側の扉でしか守れない。ここが赤くならない構成は扉 E を持っていない |
| M8 | `HistoryFetchingFixture` の探索分岐 | 問いを無視して固定の 3 行を返す | `ConversationSearchUITests.testSearchNarrowsToTheTypedTerm`(C) | 面が「探した振り」で緑にならない事 |
| M9 | `HistoryClient.search` の `timeoutInterval` | `interactiveTimeout` → `writeTimeout` | `HistoryClientTests.testSearchUsesTheInteractiveTimeout`(A) | 規約 2 の「待ち時間も見る」 |
| M10 | `TranscriptSearchResults.isCapped` | `matched > rows.count` → `false` | `…testCappedResultsAnnounceTheCap`(B) **+** C(`conversation.search.shownCap` 不在) | 「全部見せている」と嘘をつかない事 |

★ M7 は表の中で唯一 **A/B/C/D のどの扉でも赤くならない**。それが扉 E を必須にしている根拠そのもの。

---

## 10. やらない事(v1 の範囲外 —— 明示)

- **結果から転写のその行へ跳ぶ**(§5。机が位置を返していない)
- **一致箇所のハイライト**(§3。照合規則の 2 本目の実装になる)
- **結果行の折り畳み / 一致行だけの抜き出し**(机が offset を返していない)
- **走査距離を伸ばす**(`maxBytes` を 1 MiB から上げる / `scanned` を線へ載せる)。
  §0-1 の通りこれは**この機能の実用性を最も左右する変数**だが、机側の変更であり、
  応答時間と机の負荷の実測を伴う。**別 spec**。
- **全会話を跨ぐ検索**(一覧画面からの横断)。ルートが会話ごとにしか無い
- **索引 / キャッシュ / 結果の保持**。取り消したら結果は捨てる。再入力で撃ち直す
- **正規表現・語境界・AND/OR**。机は部分一致 1 種類しか持たない
- **`role` や日付での絞り込み**。線に日付が無い
- **探索中の割り込み(interrupt)・選択カードへの応答**。面が重なっている間は触れない。
  取り消せば即座に触れる(poll は止めていない)
- **サーバ側の探索実装の変更**。唯一の例外が §8-b の builder 切り出し(振る舞い不変)

---

## 11. Design Decisions

- has_design_decisions: **true**
- **裁定(2026-09-01、main session): D-A 〜 D-G すべて推奨どおりで確定。Tom には出さない。**
  - 理由: 7 件とも技術的根拠つきの推奨が付いており、Tom ゲート(金銭 / 外部への不可逆な送信 /
    法務 / 物理 / Tom しか持たない資格情報 / 純粋な好み)に該当する物が 1 件も無い。
    推奨のある選択肢を並べて渡すのは menu-dumping であって判断の委譲ではない。
  - ★ただし **Tom へ「報告」する事実が 1 件在る(質問ではない)**: 探索は転写の
    **末尾 1 MiB しか見ない**(`sessions.mjs` の `searchHistoryFromPath` が `readLinesBackward` を呼び、`listing.mjs` 側で `maxBytes ?? TAIL_MAX` に落ちる。
    サーバは `opts` 無しで呼ぶ)。同 repo の実測で一番長い会話は 280 MB なので、
    到達距離は最悪 0.36%。**機能が約束する物が変わる**ので、画面の文言でも
    「見つかりません」と言い切らない事を S2/S3 で強制する。
- decisions:
  - **D-A 検索欄の置き方と結果の重ね方**: `.searchable(.navigationBarDrawer(displayMode: .always))` + 転写に `overlay` vs ツールバーの虫眼鏡ボタン + 自前の検索欄 vs `.searchable(.automatic)`(スクロールで畳む) -- **推奨: `.always` + `overlay`**。`.always` はナビ周りの高さを一定に保ち、`.automatic` の畳み込みが起こす viewport の変動を **2026-08-31 に安定させたばかりの着地の輪**へ持ち込まない。`overlay` は転写を階層に残すので `.onAppear` が再発火せず、着地がやり直しにならない(§6)。自前の欄は取り消しボタン・クリア・音声入力を全部書き直す事になる。代償: 検索欄が常に 1 行ぶん場所を取る。
  - **D-B 発火の契機**: submit のみ vs 毎打鍵(debounce 付き) -- **推奨: submit のみ**。机は打鍵ごとに最大 1 MiB の後方読みと全行 `JSON.parse` を行い、**未確定の日本語入力(=どこにも一致しない)で負荷が最大**になる。加えて `interactiveTimeout` 20 秒下での多重飛行は「最新の要求だけが結果を持つ」札を新設させる。速さの為でなく、意味を成していない文字列で机を焼かない為(§7)。
  - **D-C 一致箇所のハイライト**: 出さない vs 電話側で `caseInsensitive` 検索して出す vs 机が offset を返す -- **推奨: v1 は出さない**。電話側で引くと机の照合規則(`toLowerCase().includes`)の 2 本目の実装になり、食い違った日「行は出るのにハイライトが無い」= 誤検出に見える面ができる。机が offset を返す案は正しいが机側の変更(§10)。
  - **D-D 件数と並び**: `limit=100` + 新しい順 vs `limit=500`(机の上限)+ 古い順(机の並びのまま) -- **推奨: 100 + 新しい順**。1 MiB の窓に 500 一致は現実に起きる(1 一致あたり 2 KiB)ので 500 は携帯回線に重い。超過は S3 が正直に名乗る。新しい順は動機(直近の転倒点)に一致し、**副次的に「下端へ寄せる機構が要らない」= 着地の輪に触れない**。代償: 転写と並びの向きが逆になる。
  - **D-E 探索の失敗が画面全部を取るか**: `.unreachable`/`.malformedBody` は探索の面の中に留める vs 既存 `applyInitial` と同じく `phase` を書き換えて全面表示にする -- **推奨: 面の中に留める**。転写は既に読めていて生きている。探索応答は履歴応答と**別の形**なので、その復号失敗は転写の健康を否定しない。`.unauthorized` / `.notFound` / `.contractViolation` は逆に全面へ escalate する(鍵・会話の消失・再試行で治らない契約違反は探索固有の話ではない)。
  - **D-F 机側の builder 切り出し**: `wire.mjs` に `historySearchBody(…)` を切り出してルートを通す(振る舞い不変)vs 切り出さず新型を `wire-key-agreement` の `UNPAIRED` に理由付きで置く -- **推奨: 切り出す**。規約 4 を「突き合わせる検査」側で満たせる。`UNPAIRED` は鍵名の drift を**測らない**箱で、探索応答の鍵は今まさに新設する物なので、生まれた日から無監視にするのは筋が悪い。代償: iOS 側の spec なのに机を 1 箇所触る(純粋な移動、振る舞いの差分ゼロ)。
  - **D-G 探索中の poll の扱い**: 止めない vs 探索の間だけ止める -- **推奨: 止めない**。止めると cursor が進まず、取り消した瞬間に gap 復帰の経路(`maybeAutoResync` / `latestGapNotice`)を無駄に踏む。重ねる設計(D-A)なら転写は階層に残るので `tailToken` の追従もそのまま働き、取り消した時に最新が見えている。
