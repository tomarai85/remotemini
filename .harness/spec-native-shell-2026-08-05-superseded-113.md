# spec — 電話の器をネイティブ SwiftUI にする(2026-08-05)

正本は `DESIGN.md` の §2.13「電話の画面 第一版 → 器」。この file は**そこで決まった事を
作業の順番に並べ直した物**で、設計判断を新しく足さない。食い違ったら `DESIGN.md` が正。

この spec を Planner subagent に書かせていない理由: 設計は既に `DESIGN.md` に長文で確定して
いる(D1 の確定・Codex の N1-N6・S/C 割り)。それを知らない subagent に書き直させると、
確定済みの Tom 裁定から**逸れた spec が正本の顔で**出てくる。逸れの検査コストの方が高い。

## Design Decisions

has_design_decisions: false

判断は全て確定済み。内訳と出所:

| 決めた事 | 出所 |
|---|---|
| 器 = ネイティブ SwiftUI(D1) | `DESIGN.md` §2.13 器、2026-08-05 の訂正ブロック |
| v1 = 4機能だけ(一覧 / 履歴+ライブ / 打つ / 割り込む) | Tom verbatim。`REQUIREMENTS.md` |
| `app.html` は捨てず `/` に残す | 同上。tailnet 上の退避経路 |
| 電話から permission 承認は**しない**(D4 不採用) | Tom 裁定「自動化に安全確認を押させない」 |
| SSE は `EventSource` でなく `URLSession.bytes` | `DESIGN.md` §2.13、認証が `Bearer` のみ |
| `view.mjs` を全部は移植しない(S/C 割り) | `DESIGN.md` §2.13 + 2026-08-05 01:44 の訂正3件 |

**Tom ゲートは v1 に1つも無い。** 唯一の真のゲートは push 通知(ワイルドカード profile が
運べない = Apple Developer Portal の作業が要る)で、これは v1 スコープ外。

## 前提として既に通っている物(2026-08-05 実測)

| 事 | 証拠 |
|---|---|
| `xcodegen generate` → `xcodebuild` ビルド | BUILD SUCCEEDED |
| XCTest が走り、壊すと落ちる | TEST SUCCEEDED(1件)→ Info.plist の鍵名を壊して TEST FAILED → 復元 |
| 署名(ワイルドカード profile / entitlement 4本の部分集合) | `codesign --verify --deep --strict` = valid |
| 実機 install | `devicectl device install app` 成功 → uninstall → `info apps` 該当0件 |

つまり**器の配管は既に実測で通っている**。以下は中身だけの話。

## Sprint 1 — サーバに `display` を足す(S 群10本)

**これが全画面の前提**なので最初に置く。`app.html` を1行も触らない事が成立条件。

### 何を作るか

`view.mjs` の S 群10本をサーバ側で呼び、結果を応答に**追加**する。

| 応答 | 足す場所 | 中身 |
|---|---|---|
| `GET /api/sessions` | 各 row に `display` | `routeLabel(row.live)` / `subtitleOf(row)` |
| 〃 | top level に `display` | `scanLine(scan)` |
| 履歴・ライブの各 entry | entry に `display` | `whoOf(entry.role)` |
| `gap` イベント | イベントに `display` | `gapNotice(why)` |
| poll の本文 | `display` | `choiceView(state)` |
| `POST …/messages` | 応答本文に `display` | `sendResult(status, body)` |
| `POST …/interrupt` | 〃 | `interruptResult(status, body)` |
| `POST …/choice` | 〃 | `choiceResult(status, body)` |
| `POST …/queue`(取消) | 〃 | `clearQueueResult(status, body)` |

### 課す条件(`DESIGN.md` の4条件 + 訂正3件)

1. **追加のみ。** 既存フィールドの意味を変えない・消さない。
2. **`display` という名前空間に入れる。** 生データに紛れる兄弟キーとして散らさない。
3. **`app.html` は無改修。** 既存の `test/app-html.test.mjs` が緑のままである事が検査。
   web は今まで通り `/view.mjs` を import して自分で計算する = 実装は1本のまま。
4. **検査は恒真にしない**(訂正3)。既知の fixture を立て、**期待値は検査自身が独立に
   組んだ入力に対する `view.mjs` の戻り値**とする。サーバが実際に渡した引数を期待値の
   材料にしない。掴みたいのは「関数を呼んだか」ではなく「**正しい引数を渡したか**」。
5. **`readablePoll` はサーバに置かない**(訂正1)。送り手は自分の送信の健全性を検めえない。

### 完了条件

- `display` の各フィールドに、上の形の検査が1本ずつ(10本)。
- 既存の検査群が全部緑(`app.html` 側が無傷である事の証明)。
- 変異検査の的が減っていない。

## Sprint 2 — 一覧(機能1)

- `GET /api/sessions` を読んで描く。判断は `display` から取る。
- Swift 側に書く C 群: `relTime` / `freshness`。両方に単体検査。
- 鍵は Keychain(ワイルドカード profile が `keychain-access-groups` を持つ事を確認済 =
  Portal 作業なしで使える)。**鍵を画面にもログにも出さない。**
- 完了条件: 実機で一覧が出る。`freshness` の古さ表示が出る。

## Sprint 3 — 履歴 + ライブ(機能2)

- `GET …/history` → `GET …/stream`(SSE)。**開く順は stream が先、history が後**
  (`mergeHistory` の docstring の理由: 逆順は隙間の発言を消す)。
- Swift 側に書く C 群: `mergeHistory` / `nextAttempt` / `backoffMs` / `nextHistoryLimit` /
  `readablePoll`。全部に単体検査。
- Codex の N1-N6 を全部満たす(`DESIGN.md` の表):
  N1 `.lines` に任せる / N2 バックオフ + `since` + 重複排除 / N3 接続の所有者は store 1つ /
  N4 復帰は**履歴取り直し → 再接続** / N5 リダイレクト禁止 / N6 `statusCode` 先読み。
- 完了条件: 実機で会話が流れる。機内モードに落として戻すと N4 の経路で復帰する。

## Sprint 4 — 打つ(機能3)

- `POST …/messages`。応答の `display` をそのまま出す。
- Swift 側に**新しく**書く判断は1本だけ: `display` が付いていない応答の受け皿
  (訂正2)。`kind:"warn"` / 「確認できませんでした」/ **`keepText: true`** 固定。
  **分からない事を成功に丸めない。** 検査必須。
- 完了条件: 実機から打った文字が机の Claude Code に入る。

## Sprint 5 — 割り込む(機能4)

- `POST …/interrupt`。応答の `display` をそのまま出す。受け皿は Sprint 4 と共通。
- 完了条件: 実機の Escape で机の生成が止まる。

## 期限の配分(Codex、`DESIGN.md`)

出発 2026-08-20。**7日で4機能を実機完成 → 残り8日を実運用と修正。**
Codex が挙げた期限側の失敗モードのうち私が握れるのは**スコープ膨張**なので、
ネイティブ化に合わせて機能を足さない。v1 は4機能のまま。
