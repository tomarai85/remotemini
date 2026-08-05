# Sprint 4 ブリーフ — poll ループ(ライブ更新)(2026-08-05 12:30 発行)

対象: 仕様 `.harness/spec-native-shell-2026-08-05.md` の §6 スプリント表 Day 4 の行。
すなわち §3 全体(transport / cursor / 1回の応答の処理 / 読めない応答の計器 / 接続の所有 /
N4 復帰 / backoff / redirect 拒否)+ §4-3(gap)+ §5-5(段階表示)。

**このブリーフは仕様に優先する。** 下の §0-b は仕様の散文と本物の応答のずれを列挙した物で、
7件ある。散文どおりに書くと**デコードは通るのに画面が嘘をつく**形が3つ含まれる。
仕様側を直せる物は既に直してある(commit `3a2c987` / `e736d80` の訂正表)が、今回見つけた
7件は**まだ仕様に反映していない** — このブリーフが正本。

---

## §0. 観測した本物の応答(2026-08-05 12:20 頃、edith 本番)

道具は `rc-backend/tools/wire-shape.mjs`。**値は出さず形だけ**取る(会話の題や発言が
出力に載らない)。edith には置きっぱなしにせず `mktemp -d` に置いて走らせ、削除して
不在を確認した。会話は一覧の 39 本。

### §0-a. 取れた形(逐語)

**空の poll**(`cursor=` / `wait=0`、何も起きていない):

```
{ "items": {"<empty>": 0}, "screen": "null", "display": {"choice": "null"},
  "route": "\"tmux\"", "queued": "null", "cursor": "string", "more": "boolean" }
```

**gap を含む poll**(`cursor=NOT-A-CURSOR` を送って `cursor-malformed` を起こした):

```
{ "items": { "<count>": 1, "kind": "\"gap\"", "why": "string",
             "display": { "notice": "string" } },
  "screen": { "route": "\"tmux\"", "pane": "string", "screen": "\"SENDABLE\"",
              "work": "string", "windowMs": "number" },
  "display": { "choice": { "show": "boolean", "reason": "\"\"", "head": {"<empty>":0},
                           "options": {"<empty>":0}, "buttons": {"<empty>":0},
                           "digest": "string" } },
  "route": "\"tmux\"", "queued": "null", "cursor": "string", "more": "boolean" }
```

ここから読み取れる、実装に効く事実:

- 応答の根は7鍵(tmux)。`items` / `screen` / `display` / `route` / `queued` / `cursor` / `more`。
- `screen` は**変わった時だけ**中身が載り、変わっていなければ `null`(= 据え置き)。
  `display.choice` が**まったく同じ規則**で動く事も観測で確認できた(1回目は両方 `null`、
  2回目は両方中身あり)。仕様 §2-3 の記述と実物が一致している数少ない箇所。
- `queued` は tmux では常に `null`。`0` ではない(机の TUI が持つ待ち行列は観測できない)。

### §0-b. 仕様の散文と本物のずれ(**7件**。ここが今回の本体)

**① `screen` は文字列ではなくオブジェクト。分類は `screen.screen`。**
仕様 §5-3 の表は `screen==="CHOICE"` / `screen==="UNKNOWN"` と書くが、wire の `screen` は
`{route, pane, screen, choice?, work, windowMs}`。分類語は**入れ子の中**に居る。
散文どおりに `screen == "CHOICE"` と書くと**常に偽**になり、CHOICE 画面で composer が
開いたままになる(= 送れないのに送れる様に見える)。正しくは `screen.screen == "CHOICE"`。
出所: `screenBody()`(`server.mjs` の `screen: s.screen` を組む所)。

**② `activity` は poll の screen 本体に**無い**。仕様 §4-1 の型が違う。**
仕様の `ConversationState` は `activity: "observed"|"unknown"?` を持つが、poll が運ぶのは
`screen.work: "observed"|"quiet"` —— **名前も語彙も違う**。`screenOf()` は
`{screen, activity, limited}` を返すが、`screenBody()` は `activity` を
`f.work.push(s.activity === "observed")` に畳んでから捨てており、`limited` も落としている。
つまり poll 経路から `activity` / `limited` は**取れない**。
`windowMs` を必ず一緒に読む事: この窓は購読直後に短く、溜まるまで伸びる。定数 5600 を
仮定すると立ち上がりで「5.6秒 動く印なし」と嘘を出す(`screenBody()` のコメントが
その事故を名指ししている)。

**③ gap の `why` は5種ではなく9種。**
仕様 §4-3 は「`pollDecision` が返しうる `why` は5種」と書くが、`pollDecision`
(`tail.mjs:94-108`)が返すのは**4種**(`cursor-too-long` / `cursor-malformed` /
`route-changed` / `epoch-mismatch`)。残りは別の出所から来る:

| `why` | 出所 | `seq` |
|---|---|---|
| `cursor-too-long` / `cursor-malformed` / `route-changed` / `epoch-mismatch` | `pollDecision` | 無し |
| `ring-overflow` | resume 分岐の頭で `gapItem("ring-overflow")` | 無し |
| `tail-attached` | `feedGap` → ring → resume 再生 | **有り** |
| `generation-changed` / `truncated` / `checkpoint-mismatch` | `feedGap(f, r.error)` → ring → resume 再生 | **有り** |

`why` を Swift の `enum` で閉じるなら**未知値の受け皿を必ず持つ**事。上の9種は今日の実装の
全域だが、`r.error` 経由なので `JsonlTail` が種別を1つ増やせば増える。

**④ ★`display.notice` は `null` になり得る。ここが今回いちばん危ない。**
`gapNotice(why)` は `view.mjs:320-323`:

```js
export function gapNotice(why) {
  if (!why || why === "tail-attached") return null;
  return `流れに切れ目がありました(${why})。履歴を読み直しました。`;
}
```

`tail-attached` に対して **`null` を返す**。サーバは `gapItem()` でこれをそのまま載せるので、
wire には `{kind:"gap", why:"tail-attached", display:{notice:null}, seq:N}` が流れうる。

仕様 §4-3 はこう書いている ——「poll の世界では gap 項目は**常に本物の切れ目**。Swift 側の
`gapNotice` 移植は抑制ロジックを持たない単純版(`why` があれば必ず表示)とする」。
**これは2重に誤り**で、素直に従うと2つの事故が同時に起きる:

1. `notice` を非 optional の `String` で書く → `tail-attached` の gap で**デコードが落ちる**
   → 仕様 §3-3 step 2 により「読めない応答」として数えられる → §5-5 の
   「配信の形が読めません」が出る。**良性の合図が偽の警報になる。**
2. 「`why` があれば必ず表示」を字義どおりに実装 → 電話に `tail-attached` という
   生の理由コードが出る。仕様 §5-3 が別の箇所で禁じている「理由コードを生で出さない」に
   自分で違反する。

**裁定**: `notice: String?` とし、**`null` なら何も描かない**。抑制は既にサーバ側で
効いている(`gapNotice` は S群 = サーバが計算する)ので、Swift 側に判断は要らない ——
要るのは `null` を「文言なし」として**尊重する**事だけ。`why` は表示に使わず、
記録(ログ)にのみ使う。

なお「`tail-attached` が実際に電話の栞より後に ring へ積まれるか」は競合であり、
**測っていない**(§0-c)。ただし optional にする対応は競合がどちらに転んでも正しく、
費用は `?` 一文字なので、測定を待たずに決める。

**⑤ 根の `display` は worker 経路に存在しない。**
tmux の return は `display: { choice: ... }` を積むが、worker の return は
`{items, screen: null, route:"worker", queued: <数>, cursor, more}` で **`display` 鍵ごと無い**。
`display` を非 optional で書くと worker 会話が丸ごとデコード不能になる。
併せて `queued` の型も経路で変わる: tmux = 常に `null` / worker = **数**。

**⑥ gap 項目の `seq` は有無が変わる**(上の表)。`seq` を非 optional にすると
`pollDecision` 由来の gap で落ちる。`kind:"message"` は両経路とも常に `seq` を持つ。

**⑦ `ReadablePoll` は `Decodable` を消費できない。二度読みが要る。**
Sprint 1 が出した `ios/Sources/Core/ReadablePoll.swift` は
`JSONSerialization.jsonObject(with:)` の緩い木(`[String: Any]`)を取る。これは意図的で、
理由はその file の冒頭コメントに書いてある(デコードに失敗した時点で壊れた形は捨てられて
しまい、この検査が見るべき物が残らない)。
仕様 §3-3 は step 2 でデコード → step 3 で判定、と読める順序で書いてあるが、
**移植済みの関数はデコード後の型を受け取れない**。実際の順序は:

```
Data → JSONSerialization → ReadablePoll.check(木)
     → true なら同じ Data を JSONDecoder で型へ
     → false なら型にせず、状態を据え置き、cursor も進めない
```

同じ `Data` を2回読む。これは無駄ではなく、**検査の対象が「デコードを通った物」ではなく
「届いた物」だから**成立している。1回にまとめようとした瞬間に検査の意味が消える。

### §0-c. 測っていない事(= この観測の分母)

正直に置く。ここを黙ると、下の実装指示が観測に裏打ちされている様に読まれる。

1. **`kind:"message"` を wire で一度も観測できていない。** 39本すべて静止しており、
   `wait=4000` で6本を突いても `items` は空のままだった。形は `server.mjs` の構築箇所
   (tmux = `entries: e.data.entries.map(withWho)` / worker = `event: e.data`)と
   `withWho()` から**読んだ**物であって、観測ではない。
   → **実機 DoD でここを取る**(§7)。生きた会話に poll を張って `items` に message が
   載る事を1回でも見るまで、この形は「読んだ」止まり。
2. **worker 経路の応答を一度も見ていない。** 39本すべて tmux。worker の
   `{event, queued:<数>, display 無し}` は全部コード読み。
3. **`tail-attached` が電話の栞より後に積まれる競合を測っていない**(④で述べたとおり、
   裁定は競合に依存しないので止まらない)。
4. 段階2への昇格(10秒)・自動取り直しは**未実装なので当然未観測**。仕様の初期値のまま作り、
   実機で調整する前提。
5. 実物のメッセージを起こす手段(`tools/live-inject-check.mjs`)は在るが**今回は回していない**。
   Tom の購読枠を1つの形の為に使う判断をしなかった。実機 DoD で自然に発生する分を使う。

### §0-d. 道具の再実行

```bash
D=$(ssh mail-redacted@example.invalid 'mktemp -d')
scp -q rc-backend/tools/wire-shape.mjs "mail-redacted@example.invalid:$D/"
ssh mail-redacted@example.invalid "cd $D && RC_KEY=\$(cat ~/.rc-backend/api.key) \
  node wire-shape.mjs '/api/sessions/{id}/poll?cursor=&wait=0'"
# 終わったら消して不在を確認する事(edith に置きっぱなしにしない)
```

`RC_SESSION_INDEX=<n>` で一覧の何本目か選ぶ。**鍵を argv に置かない**(`ps` に出る)。

---

## §1. スコープ

### §1-a. 作る物

1. **`PollClient`**(`ios/Sources/Core/`)— `GET …/poll?cursor=&wait=` の1往復。
   §0-b ⑤⑥ を反映した `Decodable` 一式(`PollResponse` / `PollItem` / `ScreenBody` /
   `ChoiceView` / `GapItem`)。**`ReadablePoll` を通してから型にする**(§0-b ⑦)。
2. **`PollLoop`**(actor)— 表示中の Conversation につき1つ。`more:true` の即時再 poll、
   `wait` の使い分け、`cancel()`、backoff(既存 `Backoff.swift` を使う)。
3. **`UnreadableMeter`** — `unreadableStreak` / `lastReadableAt` と段階(0/1/2)の算出。
   **§3-6 の `attempt` とは別の型・別の値**(§3)。
4. **gap 処理** — `notice` が非 null の時だけ描く。cursor 空リセット + `/history` 取り直し。
5. **N4 復帰** — `scenePhase` `.background`→`.active` で fresh fetch。
6. `ConversationViewModel` への配線と `ConversationView` の段階表示(静かな1行 / 警告+2ボタン)。

### §1-b. 作らない物(手を出したら差し戻し)

- **composer(送信)は Sprint 5**。`POST …/messages` を書かない。
- **interrupt は Sprint 6**。`POST …/interrupt` を書かない。
- `display.choice` の選択肢・ボタンを**描かない**(D-A)。保持して `reason` をバッジに出すだけ。
- `queued` を UI に出さない(v1 スコープ外)。**ただし型は経路差を正しく持つ**(§0-b ⑤)。
- `rc-backend/` を触らない。今回サーバ側の変更は**無い**。§0-b は全部 Swift 側の話。

---

## §2. poll ループの設計

### §2-a. 1往復の順序(これ以外の順序を採らない)

1. `HTTPURLResponse.statusCode` を**本文より先に**見る。200 以外は本文をデコードせずエラーへ。
2. 200 → `JSONSerialization` で木にする。ここで失敗 = 「読めない」1回(§3)。
3. `ReadablePoll.check(木)` が偽 = 「読めない」1回(§3)。**型にしない。**
4. 真 → 同じ `Data` を `JSONDecoder` で型へ。ここで失敗も「読めない」1回。
5. 型が取れた → merge。**ここで初めて** `unreadableStreak = 0` / `lastReadableAt = now`。
6. `cursor` を応答の値で更新。**2〜4 で止まった時は cursor を進めない。**
7. `more == true` なら `wait=0` で即座に次の往復。偽なら `wait=20000`。

`wait` は 20000(サーバ上限 `POLL_MAX_WAIT_MS` と同値)。
`URLRequest.timeoutInterval` は **30秒**(サーバの保留上限より必ず大きく)。ここを
20秒以下にすると、正常な「何も起きなかった」がタイムアウト = 通信エラーとして数えられ、
静かな会話ほど「backend unreachable」になる。

### §2-b. 所有権

poll ループの所有者は**表示中の Conversation 画面につき1つの actor**。List 画面は
poll を張らない。画面が閉じたら `URLSessionTask` を明示的に `cancel()` する。
`cancel()` 由来の失敗を backoff の失敗として数えない事(`URLError.cancelled` を除外)——
数えると、画面を開閉するたびに「接続が不安定」に見える。

### §2-c. `screen` と `display.choice` の据え置き

どちらも `null` = **据え置き**であって「消えた」ではない。`null` を受けたら**前の値を保つ**。
`screen` を `null` で上書きすると、静かな poll が1回来ただけで CHOICE 画面の判定が消え、
composer が開く。両者を**同じ1箇所**で扱う事(片方だけ据え置く実装は必ずずれる)。

---

## §3. 「読めない応答」の計器(仕様 §3-3a / §5-5)

### §3-a. 2つの計器を混ぜない

| | 数える物 | 増える条件 | 0 に戻る条件 |
|---|---|---|---|
| `attempt`(§3-6、既存 `Backoff`) | HTTP の失敗 | 接続不可・タイムアウト・5xx | 5秒(`HEALTHY_MS`)より長く開いた接続の後 |
| `unreadableStreak`(§3-3a) | **200 で届いたのに読めない** | §2-a の 2/3/4 で止まった | **merge まで通った**時 |

**片方をもう片方で代用しない。** 混ぜた瞬間、200 で返る壊れた配信が「接続は健全」に見える。
これは仕様 §5-5 が名指ししている失敗で、今回の負の対照(§5)はここを撃つ。

### §3-b. 段階と表示

| `unreadableStreak` | 表示 | composer / interrupt |
|---|---|---|
| 0 | 通常 | 有効 |
| 1-2 | 上端に**静かな**1行(赤ではない):「最新の配信を読めませんでした。`<HH:mm:ss>` 時点の画面です。再試行中…」 | **有効のまま** |
| 3 以上、または `>= 1` のまま `lastReadableAt` から10秒経過(先に来た方) | 「配信の形が読めません — 更新が止まっています」+ `[再試行]` `[読み直す]` | **有効のまま** |

時刻は `lastReadableAt` を必ず出す。「いつの画面か」を言えないと人は古い画面をライブと読む。

**composer と interrupt を止めない**理由は仕様 §3-3a に書いてあるとおり2つ:
(1) Tom の要件は「いつでも見て、**干渉できれば**いい」。(2) 送信可否はサーバが送信の瞬間に
自分でペインを読み直して判定しており、電話の古い `screen` に依存していない。
`#sendExclusive` は撮り直した本文を `classifyScreen` にかけ `SENDABLE` でなければその場で
送らずに返し(`inject.mjs:883-886`)、入力欄に本文が載る前に選択画面が出れば
`modal-appeared` で送らずに返す(`inject.mjs:912`)。
**fail-closed はサーバ側で既に成立している。**

### §3-c. 自動の取り直しは1エピソードに1回だけ

段階2へ入った瞬間に、N4 と**同じ**手順を1回だけ自動実行(`/history` 取り直し → cursor を
空へ → 画面再構築 → poll 再開)。2回目以降は `[読み直す]` を人が押した時のみ。
`unreadableStreak` が 0 に戻った時点でエピソード終了、権利が回復する。

上限を置く理由: サーバの形そのものが壊れている場合、取り直しても同じ壊れた形が返る。
上限が無いと移動中の細い回線で history 再取得のループになる。

**cursor は全段階で進めない。** N回拒否したら飛ばす、はやらない —— 飛ばした窓の中身は
「今まさに介入が必要な状態」である可能性が最も高い。復帰は**飛ばす**のではなく**取り直す**。

---

## §4. gap の扱い(§0-b ③④ の適用)

1. `display.notice` が**非 null の時だけ**会話に切れ目の行を描く。`null` なら何も描かない。
2. `why` は**画面に出さない**。ログにのみ残す(理由コードを生で出さない)。
3. `notice` を描いたかに関わらず、gap を受けたら **cursor を空へ戻して `/history` を撮り直す**。
   `tail-attached`(`notice == null`)でも取り直しは要る —— その合図の意味が
   「継ぎ目が見えないので一度読み直せ」だから(`feedGap` の呼び口のコメントが逐語でそう言う)。
   **表示するかと、読み直すかは別の判断。** ここを1つにすると `tail-attached` で
   取り直しが起きず、`/history` 撮影から購読開始までの間に書かれた行が黙って消える。
4. gap は**メッセージと同じ応答に同居し得る**(resume 分岐は `ring-overflow` の gap を
   積んでから message を積む)。「gap が来たら items の残りを捨てる」実装にしない事。
   順序どおりに処理する。

---

## §5. 検査(`ios/Tests/`)

`ios/Sources/Core/` に閉じ込め、`XCTest` から検査する(SwiftUI / UIKit を import しない)。
既存の `ios/Tests/Support/MockURLProtocol.swift` を使う。

### §5-a. 必須の負の対照(**これが無い検査は受け取らない**)

| # | 負の対照 | 何が壊れたら赤くなるべきか |
|---|---|---|
| N1 | `unreadableStreak` を `attempt` と**同じ値に繋ぐ**改変で赤くなる検査を1本 | 計器を1本に畳む改変。段階表示だけを検査すると、表示を出しつつ数え口を共有する実装が通る |
| N2 | `display.notice` を**非 optional** にした写しで赤くなる検査 | §0-b ④。`{"notice":null}` を含む gap 項目でデコードが落ちる事を固定する |
| N3 | 根の `display` を**非 optional** にした写しで赤くなる検査 | §0-b ⑤。worker 経路の応答(`display` 鍵なし)で落ちる |
| N4 | `screen` を**文字列として**比較する写しで赤くなる検査 | §0-b ①。`screen.screen == "CHOICE"` でなければ CHOICE を検出できない事を固定 |
| N5 | `screen: null` を**上書き**として扱う改変で赤くなる検査 | §2-c。据え置きが消える |
| N6 | 「読めない」応答で **cursor が進む**改変で赤くなる検査 | §3-c。介入が要る窓を黙って捨てる |
| N7 | 自動取り直しの**1回上限を外す**改変で赤くなる検査 | §3-c。細い回線での再取得ループ |

### §5-b. 状態機械の検査(スタブ `URLProtocol` で駆動)

最低限この分岐:

1. 正常(items に message、cursor 更新、`unreadableStreak` 0 のまま)
2. `more:true` → `wait=0` の即時再 poll が**実際に飛ぶ**事(2回目のリクエストの
   クエリを見る。1回で止まるとバックログが排出されない)
3. `screen` のみ変化(items 空、screen 非 null、`display.choice` 非 null)→ 据え置きが更新される
4. `readablePoll` 判定が偽 → **適用しない / cursor 進めない / streak +1**
5. gap(`notice` あり)→ 描く + 取り直し
6. gap(`notice` null、`tail-attached`)→ **描かない** + **取り直しは起きる**(§4-3)
7. gap + message が同じ応答に同居 → 両方処理される(§4-4)
8. worker 経路の応答(`display` 無し / `queued` が数 / item が `event`)→ デコードが通る
9. 401 → poll を止めて Key-entry へ(Keychain は消さない)
10. 302 → 追随しない(既存 `RedirectRefusalTests` の手筋を poll 経路でも1本)

### §5-c. 段階遷移の検査(§3-b)

読めない 200 を 1/2/3 回連続で流した時の段階(0→1→1→2)、`lastReadableAt` から10秒での
段階2昇格、読めた応答1回での 0 復帰、cursor が全段階で不変、自動取り直しが1エピソードに
1回だけ発火する事。**時刻は注入する**(`Date()` を直に呼ぶと10秒の検査が書けない)。

### §5-d. 走らせる物

```bash
./ios/tools/build.sh --sim          # headless。GUI を開かない
cd rc-backend && bash tools/run-controls.sh   # 前景で
```

`run-controls.sh` は**前景で**回す(背景走行は途中で切れても部分的な緑に見える)。

---

## §6. 引き継いだ制約(破ると commit の門で止まる、または後で高く付く)

1. **HTTP は `BackendSession` 経由のみ。** 直に `URLSession.shared` を使わない。
2. **既定のサーバ host を Swift のどこにも書かない**(source / placeholder / fixture / コメント)。
3. **鍵は Keychain のみ。** ログにも fixture にも診断行にも出さない。
4. **GUI ウィンドウを開かない。** Simulator は `xcrun simctl` の headless 経路のみ。
   `open -a Simulator` / Xcode を起動しない。
5. **`.harness/spec-*.md` を書き換えない**(Generator の持ち物ではない)。気付いたずれは
   `progress.md` に書く。
6. **`rc-backend/` を触らない**(今回サーバ変更は無い)。
7. 行番号での引用を**まだ書き足しているファイル**(`server.mjs` / `DESIGN.md`)へ向けない。
   落ち着いた module(`view.mjs` / `tail.mjs` / `inject.mjs`)なら行番号でよい。
   **機械が見ている範囲を正確に**: `test/no-linerefs.test.mjs` の `SCAN_EXT` は
   `.mjs` / `.sh` / `.py` / `.swift` の**4つだけ**。**`.md` は走査対象外**なので、
   仕様・ブリーフ・`progress.md` の中の引用は**誰も機械では見ていない** = 書き手の責任。
   Swift の**注釈**に書く引用は機械が見る(`.swift` は対象)ので、そこは規則どおり書けば
   赤が教えてくれる。散文の側は自分で照合する事。
   (この行自体、2026-08-05 に「機械が見ている」と誤って書いて実測で訂正した物。
   道具が守っている範囲を確かめずに「守られている」と書くのが、この repo で
   いちばん高く付く嘘。)
8. `progress.md` は Generator の持ち物。`spec.md` / `.harness/feedback/*` は書かない。

---

## §7. Definition of Done

(a) `ios/Tests` の該当検査が green + (b) 客観的検証コマンドの出力、の**両方**。

| # | 行 | 測り方 |
|---|---|---|
| 1 | 単体一式 | `./ios/tools/build.sh --sim` exit 0、件数が Sprint 3 の 150 より増えている |
| 2 | §5-a の負の対照7本が**効く** | 各改変を植えて赤、戻して緑。`progress.md` に表で記録 |
| 3 | §5-b の10分岐が在る | 検査名で識別できる |
| 4 | §5-c の段階遷移 | 同上 |
| 5 | `run-controls.sh` | 前景で緑(未測定があるならその理由も) |
| 6 | Simulator 証跡 | 読めない 200 を返す fixture で段階1・段階2のスクリーンショット2枚。`lastReadableAt` の時刻文字列が画面に出ている事を Accessibility identifier で確認 |
| 7 | **★実機で `kind:"message"` を1回でも観測する** | 生きた会話に poll を張り、`items` に message が載った事をログ1行で示す。**§0-c 1 の宿題を here で閉じる** |
| 8 | 実機 N4 | バックグラウンド→フォアグラウンド後に `history refetched before poll resumed` が1行出る |
| 9 | `progress.md` | 決定・除外・発見を記述 |

7 と 8 は Tom の実機が要る。**それ以外は全部この机で閉じる。**

---

## §8. Sprint 3 からの持ち越し(この Sprint で回収する)

1. **`NextHistoryLimitTests.swift` の `450` を `480` にする。** JS 側
   (`view.mjs` の `nextHistoryLimit` の検査)は `480` を使っている。Sprint 3 の Evaluator の
   言葉: 「機能的には等価だが逐語ではない。恒久的に受理した差し替えとして帳簿に残すより、
   1行直して閉じる方が良い」。**1行。`ios/Tests/` は Generator の持ち物なので今回やる。**
2. `port-coverage.py` は `mergeHistory` を**構造的に測れない**(照合できる literal が 0)。
   `mergeHistory` に触るなら JS と Swift を**人が並べて読む**しかない。道具の緑を
   根拠にしない事。今回 `mergeHistory` 本体は触らない予定なので、触ったらこの規律を思い出す。

Sprint 3 の Evaluator が挙げた残り2件は**もう閉じている**(このブリーフ発行時点で実測):
`mutation-verdict-controls.sh` = `pass=27 fail=0` / `mutation-freeze-controls.sh` = `pass=6 fail=0`。

---

## §9. Sprint 5 への申し送り(今は実装しない)

- 送信(`POST …/messages`)の応答は**系統B の `display`** = `{kind, text, keepText?}`、
  `kind ∈ {ok, warn, refused, error}`。4つの動作端点(messages / interrupt / queue / choice)
  すべてで**同じ形**。Swift の型は1つで足りる。`display.sendResult` は**存在しない**
  (仕様 §0-4 の訂正表を見る事)。
- CHOICE 時に composer を無効化する判定は `screen.screen == "CHOICE"`(§0-b ①)。
  Sprint 4 で `screen` の型が正しく入るので、Sprint 5 はそれを読むだけ。
- `queued` は tmux で `null` / worker で数(§0-b ⑤)。v2 でキュー UI を作る時、
  `null`(観測できない)と `0`(待っていない)を**混同しない**。
