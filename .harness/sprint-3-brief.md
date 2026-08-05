# Sprint 3 ブリーフ — Conversation 画面(履歴)(2026-08-05 発行)

正本 = `.harness/spec-native-shell-2026-08-05.md` の §2-3 / §3-1 / §4-3 / §5-3 / §6(Day 3 行)。
この file は**その仕様を実装可能な粒度まで落とした指示書**であり、仕様を上書きしない。
仕様と食い違う記述をこの file に見つけたら仕様が正 —— ただし下の「§0. 観測した本物の応答」だけは
**仕様より本物が正**(Sprint 2 §0-b と同じ理由。仕様の散文は既にずれている箇所が在る)。

Day 3 行の全文:

> Conversation 画面: `GET …/history` クライアント、吹き出しUI、`mergeHistory`、`truncated`+「以前を読む」
> DoD: 単体: `mergeHistory` 重複剥がし検査(正常系+「同じ発言2回で剥がしすぎる」既知限界の検査)。
> Simulator: fixture 応答スクリーンショット

---

## §0. 観測した本物の応答(2026-08-05、edith 本番)

`tools/wire-shape.mjs` を edith の中で走らせて取った、`GET /api/sessions/{id}/history?limit=50` の**形**。
値は伏せてある(発言の本文が載るので)。閉じた語彙の鍵だけ値を残した。**39 本すべてを掃いた**。

```
history[]                        ← 中身が在る時
    role      "user" | "assistant" | "tool"
    text      string
    display   { who: "Tom" | "Claude" | "道具" }
truncated     boolean

——— 中身が無い時は**形が2通り在る**(★下の §0-a-1)———
(A) {"history": []}                      ← `truncated` の鍵ごと無い。実測 14 バイト。39本中 1本
(B) {"history": [], "truncated": false}  ← 鍵は在る。                        39本中 1本
```

### §0-a. ここから読み取る、実装に効く事実

1. **★空の履歴には形が2通り在り、片方は `truncated` の鍵ごと無い。**
   出所は `src/server.mjs` の `/history` ハンドラ —— 会話 file が見つからない時だけ
   `json(res, 200, { history: [] })` で**早期に返る**ので、そこだけ `truncated` を積まない。
   実測でも両方が同時に居た(39 本中、(A) が 1 本 / (B) が 1 本)。
   → **裁定: Swift 側は `truncated` を「鍵が無ければ `false`」でデコードする。**
   `Bool?` にはしない —— 電話にとって「鍵が無い」と「false」は**同じ意味**(= 「以前を読む」を
   出さない)であり、そこを optional にすると意味の無い3値が画面の分岐に流れ込む。
   非 optional の `Bool` で書くと (A) で**丸ごとデコードが落ちる**(= 会話が開けない)。
   実装は `decodeIfPresent(Bool.self, forKey: .truncated) ?? false`。
2. **`role` は3種類。吹き出しも3種類要る。**
   API 越しの 39 本では `user` / `assistant` しか出なかったが、これは一覧に載る 39 本が短い
   仲介用の会話ばかりだから(最大 8 項目)。**一覧に載る物だけを見て「2種類しか無い」と読むと外す。**
   サーバの合成(`readHistoryFromPath(…).history.map(withWho)`)をそのまま呼んで
   edith の会話 file を大きい方から 200 本掃いた実測(2026-08-05):

   | `role` | `display.who` | 件数(全 476 項目中) |
   |---|---|---|
   | `user` | `"Tom"` | 236 |
   | `assistant` | `"Claude"` | 130 |
   | **`tool`** | **`"道具"`** | **110(23%)** |

   `tool` を1つ以上含む会話は **200 本中 19 本**。組は上の3つ以外に出なかった。
   `tool` の `text` は `⚙ Bash` の様な**道具名1行**(`sessions.mjs` の `toolNames`)であって
   本文ではない。→ 本文用の吹き出しに流し込まず、細い1行として描く。
3. **`display.who` はサーバが決める(S群)。** `whoOf(role)` の戻り値がそのまま載る。
   Swift 側で `role` から表示名を再導出しない —— 2箇所に持つと、片方だけ直した時に静かにずれる。
   `role` は**描き分けの分岐**にだけ使い、**表示名は `display.who` を描く**。
4. `text` は全項目に在る(欠けは観測されていない)。`display` も全項目に在る。
5. HTTP 500 の本文は `{ "error": "TRANSCRIPT_UNREADABLE", "code": "<errno など>" }`
   (`server.mjs` の catch 節)。`ENOENT` は 500 ではなく **200 + 空**で返る事に注意。

### §0-b. 仕様の散文と本物のずれ(Sprint 2 §0-b と同じ型、別の箇所)

仕様 §2-3 は画面上部のバッジについて `display.routeLabel` と書くが、本物の鍵は **`display.route`**。
**Sprint 3 はバッジを作らない**(§1-b)ので今回は当たらない —— **Sprint 4 への申し送り**として
ここに残す。Sprint 4 の担当は §0-b を読んでから `Decodable` を書く事。

### §0-c. 測っていない事(= この観測の分母)

- **1 MiB を超える会話 file は edith に 1 本も無い**(実測 2026-08-05: 908 本中
  `<0.1MiB`=867 / `0.1-1MiB`=41 / `1MiB` 超 =**0**)。
  `readHistoryFromPath` は既定で 1 MiB 分しか遡らない(`listing.mjs` の `TAIL_MAX`)ので、
  会話が大きく育つと **`limit` を上げても項目が増えない**天井が理論上は在る。
  今の edith では**一度も効いていない**(観測した全件で `truncated:false`、`limit` を
  50/150/500 と上げても項目数は同じ = **limit ではなく会話の短さが律速**)。
  → **この天井を前提に実装しない。** 代わりに §3-b の「効果を観測して判断する」規則で吸収する。
  天井が実際に効き始めたら、それは backend の課題として別に立てる(Sprint 3 の仕事ではない)。
- `blocked` 経路の会話、`paneFault` が立っている時の `/history`、401 の実挙動は**未観測**。

### §0-d. 道具の再実行

`tools/wire-shape.mjs` に **`{id}` の口**を足した(2026-08-05)。会話ごとの口は URL に
session id が要るが、id を手で調べるには一覧の値を一度画面に出すしかない —— それは
この道具が在る理由(値を出さない)を、この道具を使う為に破る事になる。だから**解決を道具の中に
入れて、印字するのは差し込む前の雛形**にした。id は取得と URL 組み立てにしか通らない。

```
H=mail-redacted@example.invalid
D=$(ssh $H 'mktemp -d /tmp/wireshape.XXXXXX')
scp -q rc-backend/tools/wire-shape.mjs "$H:$D/wire-shape.mjs"
ssh $H "cd $D && RC_KEY=\$(cat ~/.rc-backend/api.key) RC_SESSION_INDEX=2 \
        node wire-shape.mjs '/api/sessions/{id}/history?limit=50'; \
        /bin/rm -f $D/wire-shape.mjs; /bin/rmdir $D"
```

★`ssh edith` は**通らない**(`Host key verification failed`)。上の FQDN 形を使う事。
鍵は `RC_KEY` 環境変数経由のみ(argv に置くと `ps` に出る)。edith に恒久物を残さない
(mktemp → 削除 → **不在を確認**)。

---

## §1. スコープ

### §1-a. 作る物

| 物 | 置き場所 | 中身 |
|---|---|---|
| `HistoryClient` | `ios/Sources/Core/HistoryClient.swift` | `GET /api/sessions/<id>/history?limit=N`。`SessionsClient` と同じ形(protocol + struct、`BackendSession`) |
| 履歴のモデル | `ios/Sources/Core/HistoryModels.swift` | `HistoryResponse` / `HistoryEntry` / `EntryRole`(**★`EntryRole` は素の `String: Decodable` enum にしない**。理由と形は §3-a) |
| `MergeHistory` | `ios/Sources/Core/MergeHistory.swift` | C群の移植(§2) |
| `NextHistoryLimit` | 同上 file で可 | C群の移植(§2) |
| `ConversationViewModel` | `ios/Sources/Screens/Conversation/ConversationViewModel.swift` | 取得・状態・「以前を読む」 |
| `ConversationView` | `ios/Sources/Screens/Conversation/ConversationView.swift` | 吹き出し3種 + 上部の題 + 下部のボタン |
| List からの遷移 | `ios/Sources/Screens/List/ListView.swift` | 行タップ → Conversation(`NavigationLink`) |

### §1-b. 作らない物(次のスプリントの領分。手を出したら差し戻し)

- **poll ループ**(Sprint 4)。`live` の取得・SSE・カーソルは一切書かない。
- **composer / 送信**(Sprint 5)。入力欄そのものを置かない。
- **interrupt ボタン**(Sprint 6)。
- **画面上部のバッジ**(`screen` / `activity` / `display.choiceView`)。これらは poll 応答から来る
  ので Sprint 4 と不可分。Sprint 3 の上部は**会話の題だけ**。
- `live` union のデコード(Sprint 2 §1-b の判断をそのまま継続)。

★ただし **`mergeHistory` の呼び出し口だけは今回作る**(§2-d)。理由は同節。

---

## §2. C群の移植 — `mergeHistory` / `nextHistoryLimit`

### §2-a. 出所と、写し取り方

出所は `rc-backend/src/view.mjs`。**C群** = client の持ち物に依存するので Swift 側にも実装が要る
= **JS と Swift の2実装が併存する唯一の場所** = ずれの発生源。だから写し取りは「読んで書き直す」
ではなく、**JS の検査ケースを1件残らず Swift へ移す**事で担保する。

`rc-backend/test/view.test.mjs` の `mergeHistory` のケースは **6件**。全部移す事:

| # | JS 側のケース名 | 中身 |
|---|---|---|
| 1 | 重なりが無ければそのまま繋がる | `[a,b] + [c]` → `[a,b,c]` |
| 2 | ★履歴の末尾とライブの先頭が重なったら剥がす | `[a,b,c] + [b,c,d]` → `[a,b,c,d]` |
| 3 | ライブが丸ごと履歴に含まれていたら何も足さない | `[a,b] + [a,b]` → `[a,b]` |
| 4 | 片方が空でも壊れない | `[] + [a]` / `[a] + []` / 両方 nil |
| 5 | 役割が違えば重なりと見なさない | 本文が同じでも `role` が違えば剥がさない |
| 6 | ★同じ発言を2回した時は剥がしすぎる(**既知限界**) | `[はい,はい] + [はい]` → `[はい,はい]` |

**6 は「直す」のではなく「そう振る舞う事を検査で固定する」**。DoD が名指ししているのはこの件。
理由は JS 側のコメントに在る通り —— 履歴側に id が無く、突き合わせる鍵が `role`+`text` しかない。
取りこぼし(発言が消える)より、剥がしすぎ(重複が1つ減る)の方が軽い、という判断でここに居る。
`/history` が seq を返せる様になったら消せる欠陥、と JS 側に書いてある。Swift 側の検査にも
**「既知限界」と読める名前**を付ける事(`testKnownLimitation_…`)。緑である事が「正しい」ではなく
「承知している」の意味だと、後から読む人に判る形にする。

### §2-b. 落としてはいけない性質

1. **一致の判定は `role` と `text` だけ。`display.who` を混ぜない。**
   JS 側は `{role, text}` しか持たない配列を比べている。Swift 側は `display` も持つ型で比べる事に
   なるので、`Equatable` を素直に合成すると `display` まで比較対象に入る = **JS と違う畳み方**に
   なる。比較は専用の関数か、`display` を除いたキーで行う事。
2. **剥がす長さは「一致する最大の k」**。JS は `k = min(h.count, l.count)` から**降順**に試して
   最初に一致した k で切る。昇順(最小)にすると 6 の代償が消える代わりに 2 が壊れる。**降順**。
3. **入力が nil / 空でも落ちない**(ケース4)。
4. `nextHistoryLimit(current) = min(500, (current ?? 50) + 100)`。**500 で頭打ち**である事が
   §3-b の裁定の根拠なので、`min` を落とさない。

### §2-c. 検査の置き場所

`ios/Tests/Core/MergeHistoryTests.swift` / `ios/Tests/Core/NextHistoryLimitTests.swift`。
既存の C群移植(`RelTimeTests` / `FreshnessTests` / `BackoffTests`)と同じ形にする。

### §2-d. ★呼び出し口は今回作る(`live` が空のまま)

Sprint 3 には poll が無いので `live` は常に空。それでも ViewModel は
**`history` と `live` の2本を持ち、描画用の配列を `mergeHistory(history, live)` で都度計算する**
形にする(仕様 §4-3 の「都度再計算する」)。理由は、Sprint 4 が**データを足すだけ**で済む形にする為。
ここを「Sprint 3 は history をそのまま描く」で作ると、Sprint 4 が描画の構造ごと書き換える事になり、
Sprint 3 の検査が守っていた性質が黙って外れる。

---

## §3. 画面の挙動

### §3-a. 吹き出し(3種)

| `role` | 見え方 | 表示名 |
|---|---|---|
| `user` | 右寄せ・塗り | `display.who`(= 「Tom」) |
| `assistant` | 左寄せ・枠 | `display.who`(= 「Claude」) |
| `tool` | 左寄せ・**1行の細い行**。本文用の吹き出しに入れない | `display.who`(= 「道具」) |

- 表示名は**必ず `display.who` を描く**。`role` から自分で「Tom」を組み立てない(§0-a-3)。

**★未知の `role`(2026-08-05 追記。初版は裁定だけ書いて、それを満たす実装形を要求していなかった)**

`role` が上の3つ以外でも**落とさず**描く。ただし「落とさない」は書き方で決まる:

```swift
enum EntryRole: String, Decodable { case user, assistant, tool }   // ← 禁止
```

これだと未知の `role` を**1件**含むだけで `HistoryResponse` **全体**のデコードが例外で落ちる。
健全な会話まるごとが `.malformedBody` になり、画面は「応答の形が読めません」——
**「画面が真っ白になってはいけない」の別形そのもの**。しかも §3-c が前提にする
「`{history:[]}` は成功 / `malformedBody` は別」の分岐が、この1点で崩れる。

→ **`SessionsModels.swift` の `RouteLabel.Kind` と同じ形**(カスタム `init(from:)` で
未知値を `.unknown` へ倒す)にする。壊れる入力を検査に入れる事:
`{"history":[{"role":"system","text":"hello","display":{"who":"道具"}}],"truncated":false}`。

★重さの比較を残す: `truncated` の鍵欠けは**1フィールド**の話なのに DoD に専用行を作り、
こちらは**応答全体**を巻き込むのに DoD 行が無かった。初版の数え落とし。

**★未知 `role` の見え方 —— 偶然そうなるのではなく、決めた事として書く**

`whoOf` は user/assistant 以外を**全部**「道具」へ倒す(`view.mjs`)。上の2つの規則
(未知は本文の吹き出し / ラベルは必ず `display.who`)を両方守ると、未知 `role` は
**本文の吹き出し + 「道具」ラベル**で出る —— 本物の `tool` 行(細い1行 + 同じラベル)と
**ラベルが同じで形が違う**。この形のまま行く。理由:

- 形は `role` が決める。未知 → **本文の吹き出し**。細い1行にすると長い本文を切る事になり、
  下の「切り詰めない」に反する。
- ラベルは `display.who` のまま。ここで独自ラベルを発明すると**表示名の出所が2つ**になり、
  §0-a-3 が防いでいる物を壊す。見た目の気持ち悪さより、出所が2つになる方が高く付く。
- **その場に一行コメントで理由を書く事**(次に読む人が「バグだ」と直しに来るので)。
- 本文は `text` をそのまま描く。Markdown の解釈や折り返しの独自加工はしない(v1)。
- 長い本文を**切り詰めない**。切り詰めるなら「切り詰めた」と画面に出す(黙って上限を掛けない)。

### §3-b. ★「以前を読む」の裁定(仕様が書いていない所)

> **2026-08-05 改訂。** 初版は「押しても件数が増えなければボタンを引っ込める」と書いていた。
> 外部レビュー(Codex)がこれを3箇所で壊したので**差し替えた**。壊れ方は §3-b-4 に残す ——
> 直った結論だけ読むと、次に同じ形の間違いを踏むので。

仕様 §2-3 は「`truncated:true` の時ボタン。押すと `nextHistoryLimit` で再取得」としか書いていない。
そのまま作ると**押しても何も起きないボタン**が生まれる。道は**3本**在る(初版は2本しか数えていなかった)。

#### §3-b-1. 何を測るか ——「件数」ではなく「一番古い発言」

`readHistoryFromPath` は**新しい方から** `limit` 件返す(`all.slice(-limit)`)。
つまり「以前を読む」が成功したかどうかは、**一番古い発言が更に古い物に変わったか**であって、
**件数が増えたか**ではない。会話は机の上で生きているので、押している間に新しい発言が増える ——
その時、件数は増えても**古い方は1件も増えていない**。

`history` の項目に id は無い(`entriesFromRecord` が作るのは `{role, text}` だけ)。
だから一番古い発言の同一性は **`mergeHistory` と同じ `(role, text)` の一致**で見る。
**新しい鍵を発明しない** —— 等価関係を2つ持つと、片方だけ直した時に静かにずれる。
弱点も同じ物を引き継ぐ(会話の先頭の発言が丸ごと同じだと見分けられない)。承知の上。

#### §3-b-2. 分岐(この順で判定する)

取得の**前**に、その時点の一番古い発言を覚えておく。取得の**後**:

| 条件 | ボタン | 画面に居座る1行 |
|---|---|---|
| `truncated == false` | 出さない | 出さない(これより古い物は無い) |
| `truncated == true` かつ `nextHistoryLimit(current) == current` | **引っ込める** | 「これより古い発言は在りますが、電話には最新 500 件までしか出せません」 |
| `truncated == true` かつ 一番古い発言が**変わらなかった** | **残す**(文言を「もう一度試す」へ) | 「これより古い発言は在りますが、今回は読み込めませんでした」 |
| それ以外 | 「以前を読む」 | 出さない |

- **上限の判定は `nextHistoryLimit` に訊く。view に `500` を直接書かない**(2箇所に上限を持つと、
  片方だけ動いた時に静かにずれる)。
- 1行は**居座る表示**にする。toast にしない —— 消える表示は「古い物が在る」という**状態**を落とす。
- **文言を使い回さない。** 500 に達していない場面で「上限 500 件」と書くのは、
  **観測していない理由を断定する**事。何故読めなかったかは判っていないので、判っていないと書く。
- `truncated:true` は**本当の情報**なので、どちらの文言でも「古い物は在る」を先に言う。
  「遡れません」だけを言うと「もう無い」と読まれる。
- **押している間**: ボタンを無効化し、進行中である事を出す。二重押しで2本の取得が走らない事。

#### §3-b-3. 一度の観測で恒久的に諦めない

3行目の場合でもボタンは**消さない**。一度読めなかった事は「二度と読めない」の証明ではない。
恒久的な断念は、上限に達している時(2行目)だけ —— そこだけは
「要求を増やす方法がもう無い」が**構造として**言えるから。

#### §3-b-4. 初版が壊れていた3点(記録)

初版の裁定は「件数が増えず `truncated` が真のままなら、(1) と同じ文言でボタンを引っ込める」。

| 壊れ方 | 何が起きるか |
|---|---|
| **測る物が違った**(件数) | 押している間に新しい発言が 100 件増えると、件数は 50→150 に増えるのに古い方は1件も増えていない。初版はこれを「成功」と読む = **3本目の道を数え落としていた** |
| **文言が嘘になる** | 250 件で読めなかった時に「上限 500 件」と出す。500 には**達していない**ので、観測していない理由を断定する事になる |
| **一度の観測で恒久的に断念** | 読めなかった理由は判っていない。判っていない物を「もう無理」に変換していた |

★共通の根は1つ: **「観測で判断する」と書いておきながら、観測の対象を取り違えた**。
件数は測りやすいが、測りたい性質(古い方へ進んだか)ではない。
「予測でなく観測」は正しい方針で、その方針だけを見て**観測対象の妥当性を検めなかった**。

### §3-c. 失敗の見せ方

`SessionsFetchError` を使う。**並行する別の分類体系を作らない** —— 2組あると、Sprint 4 以降で
「どちらの言葉で話すか」を毎回決める羽目になる。ただし**共有している分類を拡張する**のは
その逆であって、下の `.notFound` は足す。

**★`.notFound` を足す(2026-08-05 追記。初版は 404 を `.unreachable` に畳んでいた)**

会話ごとの口は **404 が現実に起きる**。source(`src/server.mjs:1072`):

```js
if (!file && !registeredOnly) return json(res, 404, { error: "unknown session" });
```

一覧を撮ってから開くまでの間に会話が消えれば普通に踏む —— Sprint 3 の導線は
「一覧 → 行をタップ → 会話」なので、**一覧が古いのは常態**。
`SessionsClient.swift` の `.unreachable` は「200/401 以外の全ステータス + 到達不能」を畳む判断で、
doc に「List には 403/404 で使える物が無いから」と理由が書いてある ——
**Conversation ではその理由が成り立たない。**

畳んだままにすると、**構造的に絶対直らない状態に、直りうる状態と同じ UI(再試行)を与える**。
これは このスプリントが潰して回っている欠陥(§3-b の「押しても何も起きないボタン」)と**同じ型**。

| 分類 | Conversation 画面での扱い |
|---|---|
| `unauthorized` (401) | Key-entry へ戻す(List と同じ扱い。Sprint 2 §4-b) |
| **`notFound`** (404) | **「この会話はもう在りません(一覧が古いのかもしれません)」+ 一覧へ戻る。★再試行を出さない** |
| `unreachable` | 画面に理由を出し、**再試行ボタン**。会話の題は残す(遷移し直しを強いない) |
| `malformedBody` | 「応答の形が読めません」。**空の会話として描かない**(空と壊れを混ぜない) |
| `cancelled` | 何も出さない(画面を離れた等。失敗として数えない) |

★`{history: []}` は**失敗ではない**。「まだ発言がありません」と書く。空と壊れを同じ籠に入れない。

### §3-d. 読み込み中

初回取得の間は空の画面ではなく読み込み中である事を出す。Sprint 2 の List と同じ作法。

---

## §4. 検査 — 何をどう測るか

### §4-a. 単体(`ios/Tests`)

| 標的 | 測る事 |
|---|---|
| `MergeHistoryTests` | §2-a の 6 ケース全部。★6 は「既知限界」と判る名前で。**+ `role` と `text` が同じで `display.who` だけ違う2件が1件に畳まれる事**(下の ★等値) |
| `NextHistoryLimitTests` | `50→150` / `450→500` / **`500→500`**(§3-b(1) の根拠) |
| `HistoryModelsTests` | ★**`truncated` の鍵が無い本文がデコードでき、`false` になる**(§0-a-1)。★**未知の `role` が来ても応答全体が生き残る**事(§3-a。`{"history":[{"role":"system","text":"hello","display":{"who":"道具"}}],"truncated":false}` を食わせて `history.count == 1`。**「その項目が落ちない」ではなく「応答が落ちない」を測る**)。`tool` 行がデコードできる事 |
| `HistoryClientTests` | `MockURLProtocol` 経由で 200/401/**404**/500/壊れた本文/キャンセルの6経路。`SessionsClientTests` と同じ形。★**404 が `.notFound` になる**事(`.unreachable` に畳まれていない事。§3-c) |
| `ConversationViewModelTests` | ①初回取得 → 描画配列が `mergeHistory` の結果と一致 ②「以前を読む」が `nextHistoryLimit` の値で再取得する ③**`current==500` でボタンが引っ込み、上限の文言が出る** ④**一番古い発言が変わらなければ、ボタンは残ったまま「今回は読み込めませんでした」が出る**(§3-b-2 の3行目)⑤**件数は増えたのに一番古い発言が変わらない**時も④と同じ(= 新しい発言が増えただけ。★これが初版で数え落としていた道)⑥`truncated:false` ならボタンも1行も出ない ⑦401 で Key-entry へ ⑧二重押しで2本走らない ⑨★**`truncated:true` / 上限未達 / 一番古い発言が更新された → 「以前を読む」が出ていて、居座り文は無い** ⑩404 で `.notFound` の文言 + 一覧へ戻る導線が出て、**再試行は出ない** |

★`HistoryModelsTests` の1件目は**この Sprint で一番落としやすい検査**。`truncated` を
非 optional で書いても、鍵が在る本文しか食わせなければ緑になる。**鍵が無い本文を明示的に食わせる事**。

★**⑨は「出ない事」の検査群に対する錨**(2026-08-05 追記)。③〜⑥は全部「引っ込む / 残る /
出ない」を測っていて、**普通に出ている事を測る検査が1本も無かった**。旗を2つ持つ実装
(`showLoadMore` と `showRetry`)を書いて `showLoadMore` を常に false に固定すると、
③⑤⑥は素通りする —— ④は在るのでボタンの存在自体は1本測っているが、それは**失敗経路での存在**
であって、**正常経路で出る事は誰も測っていない**。錨が要る。

★**等値は `display` を見ない**(`MergeHistoryTests`)。`mergeHistory` の一致判定は
`role` と `text` だけで、`display.who` は見ない —— これは JS の写しとして**正しい**
(`view.mjs:23`)。だが Swift の `HistoryEntry` を `Equatable` で自動合成すると `display` まで
比較に入り、**同じ発言が二重に出る**。「合成された等値を使っていない」事を検査で固定する。

### §4-b. Simulator スクリーンショット(DoD)

`RC_UI_FIXTURE` の口を使う(Sprint 2 で作った `SessionsListingFixture` と同じ仕組み)。
新しい値(例: `conversation-3roles`)を **`#if DEBUG` の中だけ**に足す事。Release バイナリに
文字列が残らない事は `ios/tools/ui-fixture-absence-control.sh` が既に見張っている ——
**足した後にこの対照を回す**(commit の門も回すが、赤を先に見ておく)。

撮る画面: `user` / `assistant` / `tool` の3種が同時に写っている事 + 「以前を読む」が出ている事。
headless のみ(`xcrun simctl boot` / `xcrun simctl io … screenshot`)。**`open -a Simulator` は禁止**。

### §4-c. 走らせる物

```
bash ios/tools/build.sh --sim          # xcodebuild test(headless)
bash rc-backend/tools/run-controls.sh  # 対照一式(前景で。背景走行は途中で切れても緑に見える)
```

---

## §5. 引き継いだ制約(破ると commit の門で止まる、または後で高く付く)

1. **HTTP を持つ型は `BackendSession` を取る。`URLSession` を直接持たない。**
   `rc-backend/test/session-guard.test.mjs` が機械で見張っている(N5 = リダイレクト追随で
   Bearer 鍵が外へ出る事故の防止)。
2. **鍵は Keychain のみ。** log にも検査の fixture にも診断行にも書かない。
3. **既定のサーバ host を Swift の source / placeholder / fixture / コメントに書かない。**
4. **★新しく `*-control*.sh` を `ios/tools/` に置くなら `# controls-for:` を2行目に書く。**
   宣言する path は **repo の根からの相対**(`ios/Sources/…`)。`rc-backend` 側の対照は
   `rc-backend` からの相対なので、**基点が木ごとに違う**事に注意。
   宣言が無いと commit が止まる(「未登録の対照は対照ではない」)。
   —— この門が `ios/` を見る様になったのは 2026-08-05 の `f7c341e` から。それ以前は
   ios の対照は commit 時に一度も回っていなかった。
5. **`.harness/progress.md` は Generator の持ち物。** 仕様書 (`spec-*.md`) とこのブリーフは書き換えない。
6. GUI を開かない(Simulator の窓・Xcode・ブラウザ)。実機・シミュレータとも headless。

---

## §6. Definition of Done

- [ ] §4-a の単体が全部緑(`bash ios/tools/build.sh --sim`)
- [ ] §4-b のスクリーンショットが取れている(3種の吹き出し + 「以前を読む」が写っている)
- [ ] `mergeHistory` の 6 ケースが Swift に在り、**6件目が「既知限界」と判る名前**で緑
- [ ] `truncated` の鍵が無い本文でデコードが通り `false` になる検査が在る
- [ ] `nextHistoryLimit(current)==current` でボタンが引っ込み、上限の文言が出る検査が在る
- [ ] **一番古い発言が変わらなかった時**に「今回は読み込めませんでした」が出て、**ボタンは残る**検査が在る
- [ ] ★**件数は増えたが一番古い発言は変わらない**(押している間に新しい発言が増えた)場合の検査が在る
- [ ] 上の2つの文言が**別物**である事(500 に達していない時に「上限 500 件」と書かない)
- [ ] ★**未知の `role` を1件含む本文で、応答**全体**がデコードできる**検査が在る(§3-a)
- [ ] ★404 が `.notFound` になり、Conversation では**再試行を出さない**検査が在る(§3-c)
- [ ] ★正常経路の錨 —— **「以前を読む」が出ていて居座り文が無い**検査(⑨)が在る
- [ ] ★`display.who` だけ違う2件が `mergeHistory` で1件に畳まれる検査が在る
- [ ] `bash rc-backend/tools/run-controls.sh` が**前景で** `red=0 未測定=0`
- [ ] `.harness/progress.md` に、**仕様と食い違った所・判断した所**が書いてある

---

## §7. Sprint 2 からの持ち越し(この Sprint で回収する物)

1. **★`SessionsClientTests` / `SessionsModelsTests` の変異検査**。Sprint 2 の Evaluator が
   「今回は目視のみ。デコード経路を触る Sprint が来たら予算を取って回すべき」と残した。
   **Sprint 3 はデコード経路を増やす**ので、ここで回収する: `HistoryModels` の検査を書く時に、
   同じ手筋で既存2本にも変異を当てる(`truncated` を非 optional にした写し / `role` の未知値で
   落ちる写しを作り、検査が赤くなる事を確かめる)。**緑である事ではなく、壊せば赤くなる事**を見る。
2. `run-controls.sh` は**前景で**回す(背景走行は途中で切れても部分的な緑に見える)。
3. `live` union のデコードは Sprint 4 の領分のまま(Sprint 2 の判断を継続)。

## §8. Sprint 4 への申し送り(今は実装しない)

- §0-b: バッジの鍵は `display.route`(仕様の `display.routeLabel` は古い)。
- 仕様 §5-4 と §5-5 は**別々のカウンタ**を持つ(訂正4)。
- 仕様 §3-6 の「4回目以降」は**閾値 3 が正**。§3-6 の文言どおりに実装しない事。
