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
   仲介用の会話ばかりだから(最大 8 項目)。transcript を直接読むと **25 項目中 13 が `tool`**
   だった(実測 2026-08-05、edith の会話 file 908 本中で最大の 3 本目)。
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
| 履歴のモデル | `ios/Sources/Core/HistoryModels.swift` | `HistoryResponse` / `HistoryEntry` / `EntryRole` |
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
- `role` が上の3つ以外だった時は**落とさず** `assistant` と同じ形で描く。`SessionsModels.swift` の
  `RouteLabel.Kind` が unknown へ倒すのと同じ判断 —— 古い電話が新しいサーバを見た時に
  画面が真っ白になってはいけない。
- 本文は `text` をそのまま描く。Markdown の解釈や折り返しの独自加工はしない(v1)。
- 長い本文を**切り詰めない**。切り詰めるなら「切り詰めた」と画面に出す(黙って上限を掛けない)。

### §3-b. ★「以前を読む」の裁定(仕様が書いていない所)

仕様 §2-3 は「`truncated:true` の時ボタン。押すと `nextHistoryLimit` で再取得」としか書いていない。
そのまま作ると**押しても何も起きないボタン**が生まれる道が2本在る。両方塞ぐ事。

**(1) 上限に達している時**
`nextHistoryLimit(500) == 500` で、サーバ側も `limit` を 500 で頭打ちにする
(`Math.min(Number(...), 500)`)。つまり `current == 500` で押すと**同じ 500 件を取り直して
`truncated:true` のまま**になる。
→ **裁定: `nextHistoryLimit(current) == current` の時はボタンを出さず、**
**「これ以上は電話から遡れません(上限 500 件)」と書く。**
判定は `nextHistoryLimit` に訊く事。**view に `500` を直接書かない**(2箇所に上限を持つと、
片方だけ動いた時に静かにずれる)。

**(2) 押しても件数が増えなかった時**
サーバ側には byte の天井も在る(§0-c。今の edith では効いていないが、会話が育てば効く)。
→ **裁定: 再取得の結果、項目数が増えず `truncated` が真のままなら、(1) と同じ文言を出して**
**ボタンを引っ込める。**
「上限は 500 件だから」という**予測**ではなく「押したが増えなかった」という**観測**で判断する形に
する事 —— 天井の理由が将来変わっても、この規則は正しいまま働く。

**押している間**: ボタンを無効化し、進行中である事を出す。二重押しで2本の取得が走らない事。

### §3-c. 失敗の見せ方

`SessionsFetchError` と**同じ 4 分類**を使う(`unreachable` / `unauthorized` / `malformedBody` /
`cancelled`)。新しい分類を作らない —— 分類が2組あると、Sprint 4 以降で「どちらの言葉で話すか」を
毎回決める羽目になる。

| 分類 | Conversation 画面での扱い |
|---|---|
| `unauthorized` (401) | Key-entry へ戻す(List と同じ扱い。Sprint 2 §4-b) |
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
| `MergeHistoryTests` | §2-a の 6 ケース全部。★6 は「既知限界」と判る名前で |
| `NextHistoryLimitTests` | `50→150` / `450→500` / **`500→500`**(§3-b(1) の根拠) |
| `HistoryModelsTests` | ★**`truncated` の鍵が無い本文がデコードでき、`false` になる**(§0-a-1)。`role` の未知値が落ちない事。`tool` 行がデコードできる事 |
| `HistoryClientTests` | `MockURLProtocol` 経由で 200/401/500/壊れた本文/キャンセルの5経路。`SessionsClientTests` と同じ形 |
| `ConversationViewModelTests` | ①初回取得 → 描画配列が `mergeHistory` の結果と一致 ②「以前を読む」が `nextHistoryLimit` の値で再取得する ③**`current==500` でボタンが消える** ④**件数が増えなければボタンが消える**(§3-b(2)) ⑤401 で Key-entry へ ⑥二重押しで2本走らない |

★`HistoryModelsTests` の1件目は**この Sprint で一番落としやすい検査**。`truncated` を
非 optional で書いても、鍵が在る本文しか食わせなければ緑になる。**鍵が無い本文を明示的に食わせる事**。

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
- [ ] `nextHistoryLimit(current)==current` でボタンが消える検査が在る
- [ ] 再取得しても件数が増えない時にボタンが消える検査が在る
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
