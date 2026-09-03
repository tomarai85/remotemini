# spec — 対照表 #11「任意のディレクトリで新規セッション」(roots の下だけ)

Tom 裁定 2026-09-03: **作る。roots allowlist の下だけ**。台帳 = 机の `~/.rc-backend/roots`。
既に在る物 = `rc-backend/src/roots.mjs`(`loadRoots` / `resolveUnderRoots` / `RC_ROOTS_FILE`)+
`rc-backend/test/roots.test.mjs`(9 件、変異 3 件を殺し済)。**此の spec は其れを使うだけで、書き直さない。**

## Goal

1. 机に会話が **0 本**でも、電話から新しい会話を始められる。
2. 始められる場所は台帳の root の**下だけ**。台帳が無い / 空 = **何処も受けない**(fail closed)。
3. 線に**絶対 path を出さない**。root は `index` + 札(`~/Infra`)、其の下は root からの相対 path。
4. 「押しても送らない」を守る = dir を押すのは**降りる**だけ。起動は明示の Start ボタン 1 つ。

## Wire contract

口の形の判断(1 段落): 会話に**紐づかない**口を 3 本新設する。既存の `paths` に `root=` を足す案は、
道が会話 id を要求するので**会話 0 本の机で使えない** —— 此の機能が埋める穴そのものが埋まらない。
index で指すのは、札(`~/Infra`)を鍵にすると台帳の綴り替えで壊れ、絶対 path を鍵にすると
**線に机の地図が出る**から。index は `loadRoots()` の並び順(台帳の行順)で、要求ごとに読み直す。

| 道 | 方法 | 本文 / 問い | 返り |
|---|---|---|---|
| `/api/roots` | GET | — | 200 `{ roots: [{index, label}], reason }`。台帳が無い/空 = 200 `{roots: [], reason: "no_roots"}` |
| `/api/roots/<i>/paths` | GET | `?q=&limit=` | 200 `pathsBody`(`paths` / `truncated` / `reason`)。**dir だけ**。範囲外の `i` = 404 |
| `/api/roots/<i>/new` | POST | `{"path": "<相対 or 空>"}` | 202 `{started, window, pane}`。外 = 400 `outside_roots` / 無い = 409 `cwd_gone` / 台帳空 = 400 `no_roots` / 範囲外 = 404 |
| `/api/sessions/<id>/new` | POST | 本文なし = **現状のまま** / `{"cwd": "<絶対 or ~/…>"}` | 202 `{started, window, pane, cwd}`(現状) / 外 = 400 `outside_roots` / 台帳空 = 400 `no_roots` / 無い = 409 `cwd_gone` |

- 一覧の口だけ「200 + 空 + 語」で、起動の口は 4xx。一覧は**答えられている**(受ける場所は 0 件)ので
  断りではない。起動は**受けなかった**ので断り。`paths` の口が 200 + 語で答えるのと同じ判断。
- 分類は全部 `reason`。`code` は 401/404 の**復旧語彙専用**なので此の 4 本では一度も書かない。
  範囲外 index の 404 にも `code` を置かない(電話は status で `.rootGone` に落とす)。
- 202 は**絶対 cwd を返さない**(`/api/roots/<i>/new`)。会話 id はまだ無いので現状同様に一覧を引き直す。
- 本文の `path` が絶対 / `~` 始まり = 400 `outside_roots`(此の口の契約は相対 path 1 通り)。

## Desk changes

- **`rc-backend/src/reqlog.mjs`**(道の表は写しを持たない):
  - `export const ROOTS_ROUTE_RE = /^\/api\/roots\/(\d{1,3})\/(paths|new)$/;`
  - `pathShape` に 1 段足す: `SESSION_ROUTE_RE` の後で `ROOTS_ROUTE_RE` を当て、`/api/roots/:i/<動作>` へ畳む。
  - `/api/roots` は**固定 path** なので regex ではなく `LOG_PATHS` 側で覚える。
- **`rc-backend/src/paths.mjs`**: `completePaths(root, q, opts)` に `opts.dirsOnly`(既定 false)。
  push の直前に `if (dirsOnly && kind !== "dir") continue;` の 1 行だけ。呼び分けを route 側で
  「多めに取って後で削る」形にしないのは、其れをすると `limit` と `truncated` が嘘になるから。
  会話側の `paths` の口は既定(false)のまま = **挙動不変**。
- **`rc-backend/src/rootsroute.mjs`**(新設。`diffroute.mjs` と同じ理由 = server.mjs は import で listen
  するので単体から呼べない。偽 req/res で叩ける形に切り出す):
  - `handleRootsList({ res, json, loadRoots })` → `rootsBody`。
  - `handleRootsPaths({ res, index, q, limit, json, loadRoots, completePaths, pathsBody })`。
  - `handleRootsNew({ req, res, index, json, loadRoots, resolveUnderRoots, readBody, startWindow })`。
    `startWindow(cwd)` = tmux を撃つ関数を server.mjs から渡す(此の module は tmux を知らない)。
  - `loadRoots()` は**要求ごとに**呼ぶ(caching しない)。台帳は 32 行以内の人が書く file で、
    机で 1 行足した直後に電話から見えるべき物。e2e が台帳を消して `no_roots` を測れるのも此の性質。
- **`rc-backend/src/wire.mjs`**: `rootsBody({ roots, reason })` → `{ roots: roots.map((r, i) => ({ index: i, label: r.label })), reason: reason ?? null }`。
  **`path` を載せない**のが此の関数の全部(`pathItem` が 2 鍵しか載せないのと同じ判断)。
- **`rc-backend/src/server.mjs`**:
  - `import { loadRoots, resolveUnderRoots, ROOTS_OUTSIDE, ROOTS_NONE, ROOTS_CWD_GONE } from "./roots.mjs";`
    と `handleRoots*` / `rootsBody` / `ROOTS_ROUTE_RE`。
  - 振り分けは **`const m = SESSION_ROUTE_RE.exec(path)` の 404 より前**(約 1434 行)、認証の後。
    `if (path === "/api/roots" && req.method === "GET")` を字面で書く(`LOG_PATHS` の両向き検査が此の
    字面と対になる)+ `ROOTS_ROUTE_RE.exec(path)` の分岐。
  - `LOG_PATHS`(約 2487 行)に `"/api/roots"` を追加。
  - `action === "new"`(約 1478 行): 先頭で本文を読む。`readBody` を `/api/account/select`(約 1385 行)と
    同じ形で包む —— `BodyTooLarge` → `tooLarge(req, res, e)`、その他の parse 失敗 → 400
    `{ error: "cwd required", reason: "bad_body" }`。本文が空 / `cwd` 無し = **今までの道**(会話の cwd)。
    `cwd` 在り = `loadRoots()` → `resolveUnderRoots(roots, body.cwd)` → ok なら其の `cwd` で起動、
    さもなくば `reason` を其のまま 400(`outside_roots` / `no_roots`)・409(`cwd_gone`)へ写す。
  - tmux の window 名は現状のまま `phone-new-<base36>`(回復用の `phone` と分ける規約を保つ)。

## Phone changes

- **`ios/Sources/Core/RootsModels.swift`**(新設)
  - `struct DeskRoot: Decodable, Equatable { let index: Int; let label: String }`
  - `struct RootsResponse: Decodable, Equatable { let roots: [DeskRoot]; let reason: String? }`
    (`reason` だけ省略可。`PathCompletionResponse` と同じ判断)
  - `enum StartInRootOutcome: Equatable { case started, outsideRoots, noRoots, cwdGone, rootGone, deskRefused, unauthorized, unreachable }`
    + `var text: String`(`NewSessionOutcome.text` の流儀。`.started` は
    「Starting — it will appear in the list shortly.」を再利用する)。
  - `enum WireCode`(電話が**分岐に使う語だけ**): `outsideRoots = "outside_roots"` /
    `noRoots = "no_roots"` / `cwdGone = "cwd_gone"` / `tmuxFailed = "tmux_failed"`。
  - `static func from(status:reason:)`: 202 → `.started` / 401 → `.unauthorized` /
    404 → `.rootGone` / 400 は `reason` で `outsideRoots` / `noRoots` に割る / 409 → `.cwdGone` /
    既定は `tmux_failed` なら `.deskRefused`、他は `.unreachable`。
- **`ios/Sources/Core/RootsClient.swift`**(新設): `protocol RootsBrowsing { list / paths / start }`。
  `BackendSession` を使う(素の `URLSession` は `session-guard.test.mjs` が commit の門で落とす)。
  読む 2 本 = `interactiveTimeout`、`start` = `writeTimeout`。`paths` は `PathCompletionResponse` を再利用。
- **`ios/Sources/Core/RootsFixture.swift`**(新設、`#if DEBUG`。`DiffFixture.swift` と同じ形):
  `final class RootsBrowsingFixture: RootsBrowsing`、`enum State: String`
  - `roots-sample` = root 2 本(`~/Infra` に `ios` / `rc-backend` / `research` の 3 dir、`~/Personal` は空)
  - `roots-none` = `{roots: [], reason: "no_roots"}`
  - `roots-outside` = 一覧と補完は `roots-sample` と同じ、`start` だけ `.outsideRoots` を返す
- **`ios/Sources/Screens/List/DirectoryPickerView.swift`**(新設、sheet):
  root の一覧 → 押すと其の下の dir 一覧 → 更に押すと降りる → 「Start here」で起動。
  現在地は root の札 + 相対 path で出す(絶対 path は電話にも来ない)。上へ 1 段戻る道を置く。
  `no_roots` の面は空表と 1 文(「No directories are allowed on the desk yet.」)。結果は 1 行の notice。
- **`ios/Sources/Screens/List/ListView.swift`**: `.toolbar` の
  `ToolbarItem(placement: .topBarTrailing)`(約 139 行)に **`+` を 1 マス**足す(AccountBar の隣)。
  `rootsBrowser: RootsBrowsing = RootsClient()` を init に足す —— **既定値を持たせる**のは
  `newSessionStarter` と同じ理由(呼び出し 2 箇所を触らずに済ませ、fixture 側だけ古い口が残る形を避ける)。
  行の長押しの「New session here」は**残す**(場所が既に決まっている道は最短のまま)。
- **`ios/Sources/RootView.swift`**: fixture 分岐に `RootsBrowsingFixture(state:)`、本物側に `RootsClient()`。
  fixture の面に本物の口を 1 つも残さない(`RC_UI_FIXTURE` が名乗らなければ回る fixture へ落とす)。
- **accessibility identifiers**: `list.newSession`(工具帯の `+`)/ `roots.sheet` / `roots.root.<index>` /
  `roots.entry.<相対 path>` / `roots.up` / `roots.start` / `roots.here` (現在地の文字列) /
  `roots.empty` / `roots.notice`。

## Tests and controls

**机 — `rc-backend/test/roots-routes.test.mjs`**(偽 req/res + server.mjs の字面。名前は此の綴りで作る)
1. `★到達できる: /api/roots/:i/paths と /api/roots/:i/new が ROOTS_ROUTE_RE に当たる`
2. `★到達できる: /api/roots が LOG_PATHS に居て、server.mjs が同じ字面で振り分けている`
3. `★roots の道は SESSION_ROUTE_RE の 404 より前に居る`
4. `GET /api/roots: 札と index だけ返す(絶対 path を本文に一度も出さない)`
5. `GET /api/roots: 台帳が無い = 200 + 空 + no_roots`
6. `GET /api/roots/:i/paths: root 起点で dirsOnly で歩き、pathsBody の 3 鍵で返す`
7. `GET /api/roots/:i/paths: 範囲外の index は 404(code を置かない)`
8. `POST /api/roots/:i/new: root の下 = 202 started/window/pane、本文に cwd を出さない`
9. `★POST /api/roots/:i/new: root の外へ抜ける相対 path = 400 outside_roots`
10. `POST /api/roots/:i/new: 絶対 path / ~ 始まりの本文 = 400 outside_roots`
11. `POST /api/roots/:i/new: 無い dir = 409 cwd_gone`
12. `★POST /api/roots/:i/new: 台帳が空 = 400 no_roots(fail closed)`
13. `POST /api/sessions/:id/new: 本文なしは今までどおり会話の cwd で起動する`
14. `★POST /api/sessions/:id/new: cwd 付きは roots の外なら 400 outside_roots`
15. `POST /api/sessions/:id/new: 本文が読めない / 64KB 超は 400・413(台本を一度も呼ばない)`

**机 — 既存 file への追記**
- `rc-backend/test/reqlog.test.mjs`: `★roots の道の正規表現は 1 本しか無い(server.mjs は写しを持たない)`
- `rc-backend/test/paths.test.mjs`: `dirsOnly: file を落としても limit と truncated が嘘にならない`
- `rc-backend/test/wire.test.mjs`: `rootsBody: index と label の 2 鍵だけ(path を載せない)`
- `rc-backend/test/wire-vocabulary-agreement.test.mjs`: `outside_roots` / `no_roots` / `cwd_gone` は
  **電話が読む**ので SERVER_ONLY へは足さない(`RootsModels.swift` の `WireCode` に居る事で通る)。
  走査が新しい大文字の字面を拾ったら、其の時だけ SERVER_ONLY に 1 行の理由付きで足す。

**机 — e2e(`rc-backend/test/e2e-local.mjs`)**
- 起動 env(約 715-740 行)に `RC_ROOTS_FILE: ROOTS_LEDGER`(= `join(SB, "roots-ledger")`)。台帳の中身は
  sandbox の `projects` の親を 1 行。`paths` の塊(約 1050-1115 行)の直後に `get(...)` / `check(...)` で:
  - `★roots: 会話 id 無しで一覧が引ける(index と label だけ、絶対 path は出ない)`
  - `★roots: root の下の相対 path で始まる = 202`
  - `★★roots: root の外を指す相対 path = 400 outside_roots(allowlist が本当に効いている)`
  - `★roots: 台帳を消すと 400 no_roots、書き戻すと 202(fail closed が既定側)` — 台帳を消して
    測れるのは `loadRoots()` を要求ごとに呼ぶから。**再起動を挟まない**。
  - `roots の対照: /api/roots/9/new は 404(index が catch-all になっていない)`

**電話 — `ios/Tests/Core/RootsClientTests.swift`**(`RootsClientTests`)
- `testRootsResponseDecodesIndexAndLabelOnly`
- `testMissingRootsKeyFailsDecodingInsteadOfShowingAnEmptyList`
- `testStartOutcomeMapsStatusAndReason`(202/400 の 2 語/409/404/401/既定)
- `testUnknownReasonOn400FallsBackToUnreachableRatherThanStarted`

**電話 — `ios/UITests/NewSessionPickerUITests.swift`**(`NewSessionPickerUITests`、fixture 1 状態 = 1 検査)
- `testPickingADirectoryDrillsDownAndOnlyStartHereStarts`(`roots-sample`。dir を押しても
  `roots.notice` が出ない = 「押しても送らない」の対照を含める)
- `testNoRootsShowsTheEmptyFaceInsteadOfAnEmptyList`(`roots-none`)
- `testOutsideRootsRejectionIsShownAsText`(`roots-outside`)

**変異(route 層。両方 `roots-routes.test.mjs` の 9 と 12 が赤くなる事を実測する)**
- M1: `handleRootsNew` から `resolveUnderRoots` の呼び出しを外し、`join(root, body.path)` を其のまま
  tmux の `-c` に渡す → 検査 9 / e2e の `outside_roots` が赤。
- M2: `outside_roots` の応答を 400 から 200 に変える → 検査 9 が赤(語だけ見て status を見ない検査を弾く)。
- M3: `loadRoots()` が空の時に `[{label:"~", path: homedir()}]` を既定として置く → 検査 12 が赤。
- M4: `rootsBody` に `path` を足す → 検査 4 と wire の検査が赤。

## Deploy and operator steps

1. **台帳を先に作る**(配備の前。`tools/deploy-to-friday.sh` は設定 file を撒かない)。
   Friday で `~/Infra` と `~/Personal` は在り、`~/client-a` は無く、`~/.rc-backend/roots` も無い(2026-09-03 実測)。
   ```
   ssh athenas 'mkdir -p ~/.rc-backend && [ -e ~/.rc-backend/roots ] || cat > ~/.rc-backend/roots <<EOF
   ~/Infra
   ~/client-a
   ~/Personal
   EOF'
   ```
   `[ -e ] ||` を外さない = **既存の台帳を上書きしない**。`~/client-a` は今 無いので `loadRoots` が
   落とす(`dropped` に出る)が、Tom の裁定どおり 3 行で書く —— dir が出来た日に手を入れずに効く。
2. `ssh athenas 'cat ~/.rc-backend/roots'` で中身を目で確認。
3. `bash rc-backend/tools/deploy-to-friday.sh`(Friday のみ。edith へは配らない)。
4. 配備後の観測 1 行: `curl -s -H "Authorization: Bearer <key>" https://<friday>:9443/api/roots` が
   `{"roots":[{"index":0,"label":"~/Infra"},{"index":1,"label":"~/Personal"}],"reason":null}` を返す事。

## Design Decisions

- has_design_decisions: false
- 理由: 機能の可否(作る / roots の下だけ / roots は `~/Infra ~/client-a ~/Personal`)は 2026-09-03 に
  Tom が裁定済み。此処で決めた 4 件 —— ① 会話に紐づかない 3 本の口(会話 0 本の机で使える唯一の形)、
  ② index で root を指す(札は綴り替えで壊れ、絶対 path は地図を線に出す)、③ `completePaths` に
  `dirsOnly` を 1 行足す(route 側で削ると `limit` と `truncated` が嘘になる)、④ 一覧の口だけ
  200 + 語で起動の口は 4xx —— は全部**設計の内側**で、Tom の判断を要する分岐が無い。

## Out of scope

- 電話から台帳を編集する口。台帳は机の operator が書く物で、**電話から allowlist を広げられる口を
  作ると allowlist の意味が消える**。
- 一覧と起動の間に台帳が入れ替わった時の照合(`root` の札を本文で往復させる形)。窓は数秒で、
  ズレても**別の allowlist 済み root で始まる**だけ = 安全側の外れ方。要る日に足す。
- file の作成 / 新しい dir を電話から作る事。此の口は**在る場所を選ぶ**だけ。
- edith への配備、`~/Infra` 以外の機体の台帳、roots の下の cwd を後から変える口。
- `paths` の口(会話側)の挙動変更。`dirsOnly` の既定は false で、既存の `@` 補完は 1 バイトも変わらない。
