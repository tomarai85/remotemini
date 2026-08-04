# Sprint 2 ブリーフ — List 画面(2026-08-05 06:07 JST 発行)

正本 = `.harness/spec-native-shell-2026-08-05.md` の §1-b / §2-2 / §4-2 / §5-2 / §5-4 / §6(Day 2 行)。
この file は**その仕様を実装可能な粒度まで落とした指示書**であり、仕様を上書きしない。
仕様と食い違う記述をこの file に見つけたら仕様が正 —— ただし下の「§0. 観測した本物の応答」だけは
**仕様より本物が正**(仕様の散文が既にずれている。理由は §0-b)。

---

## §0. 観測した本物の応答(2026-08-05 06:0x JST、edith 本番 `e74c50e`)

`tools/wire-shape.mjs` を edith の中で走らせて取った、`GET /api/sessions` の**形**。
値は伏せてある(会話の題・直近の発言・作業 dir が載るので)。閉じた語彙の鍵だけ値を残した。

```
sessions[]  (実測 39 本)
  id                    string
  project               string | null
  cwd                   string
  title                 string
  lastPrompt            string | null
  turns                 number | null
  metadataIncomplete    boolean
  updatedAt             string        (ISO8601)
  fromRegistryOnly      boolean       ★39本中1本にしか無い = optional
  live                  ↓ 経路で形が違う(union)
      tmux   : { route:"tmux",   pane:string, screen:"SENDABLE"…, activity:"unknown"…, limited:boolean }
      worker : { route:"worker", worker:string, state:string, queued:number }
      blocked: { route:"blocked", reason, candidates, source, message }   ← 今回の観測には出ていない
  display                             ← **行ごとの** display(sessions[] の中)
      route   { kind:"tmux"|"worker"|"choice"|"blocked"|"unknown", short:string, text:string, screen:string }
      subtitle string
scan        { scope, limit, files, read, cached, examined }
display     { scan: string }          ← **応答の一番外の** display。行の display と別物・同名
paneFault   null | { reason:string, detail:string }
```

### §0-a. ここから読み取る、実装に効く事実

1. **`live` は union**。tmux 行と worker 行で鍵の集合が違う。1つの struct に optional を並べて
   受けると**デコードは通る**が、経路の取り違えが静かに起きる —— Sprint 1 の `readablePoll` が
   踏んだ `entries`/`event` 取り違えと同じ型。→ **Sprint 2 は `live` をデコードしない**(§1-b 参照)。
2. **`display.route.screen` は worker 経路で `""`**(null ではない)。空文字は「画面が無い」であって
   「不明」ではない。`String?` で受けて nil と "" を混ぜない事。
3. `fromRegistryOnly` は**在ったり無かったり**する。必須で書くと 39 本中 38 本でデコードが落ちる。
4. `paneFault` は正常時 `null`。

### §0-b. 仕様の散文と本物の鍵名がずれている(仕様の方が古い)

| 仕様 §2-2 の書き方 | 本物の鍵 | 出所(`src/server.mjs` の `/api/sessions`) |
|---|---|---|
| `display.routeLabel` | **`display.route`** | `display: { route: routeLabel(live), subtitle: subtitleOf(s) }` |
| `display.scanLine` | **`display.scan`** | `display: { scan: scanLine(scanBody) }` |

仕様は**関数名**(`routeLabel` / `scanLine`)を鍵名のつもりで書いている。散文の名前で `Decodable` を
書くと、鍵が optional なら**デコードは成功して画面だけ空になる** —— 緑のまま嘘をつく形。
本物の鍵名で書く事。

### §0-c. 道具の再実行

```
H=mail-redacted@example.invalid
D=$(ssh $H 'mktemp -d /tmp/wireshape.XXXXXX')
scp -q rc-backend/tools/wire-shape.mjs "$H:$D/wire-shape.mjs"
ssh $H "RC_KEY=\$(cat ~/.rc-backend/api.key) node $D/wire-shape.mjs /api/sessions; \
        /bin/rm -f $D/wire-shape.mjs; /bin/rmdir $D"
```

★`ssh edith` は**通らない**(2026-08-05 実測、`Host key verification failed`)。`~/.ssh/config` に
`Host edith` が無く、known_hosts は FQDN で覚えている。上の FQDN 形を使う事。鍵は `RC_KEY` 環境変数
経由のみ(argv に置くと `ps` に出る)。edith に恒久物を残さない(mktemp → 削除 → **不在を確認**)。

---

## §1. スコープ

### §1-a. 作る物

1. **`SessionsClient`** — `GET /api/sessions` を1回叩き、下のモデルへデコードする。
2. **`SessionsResponse` 系のモデル** — §0 の形に忠実。
3. **C群 Swift 移植 2本** — `relTime(iso, nowMs)` と `freshness(fetchedAtMs, nowMs)`。
4. **List 画面** — 行UI / 一覧下部の `display.scan` / `freshness` の表示 / pull-to-refresh /
   §5-2 の全分岐 / メモリキャッシュ(§4-2 例外)。
5. **RootView の差し替え** — `SignedInPlaceholderView` を List へ。
6. **UI テスト標的**(`RemoteMiniUITests`)と、それを駆動する DEBUG 限定の fixture 口(§4)。

### §1-b. 作らない物(次のスプリントの領分。手を出したら差し戻し)

| 作らない物 | 理由 |
|---|---|
| poll ループ / SSE / 自動更新 | Sprint 4。§2-2 が「**行ごとの poll は張らない**」と明記 |
| Conversation 画面 / `/history` / `mergeHistory` | Sprint 3 |
| 送信 / 割り込み / `sendResult` / `interruptResult` | Sprint 5-6 |
| `§5-5`(配信が読めない)の段階表示 / `unreadableStreak` | **Sprint 4**。訂正4 の領分 |
| §5-4 の**画面横断の共通コンポーネント化** | Sprint 6(「全画面適用」)。今回は List 内で完結させる |
| `live` の union デコード | 描かないから。**描かない物をデコードするのは、間違える事しかできない** |
| `queued` / queue UI | v1 スコープ外(§0-4) |
| ディスク永続化 | §4-2 が明示的に禁止 |

`live` を今回デコードしないのは怠慢ではなく決定である。Sprint 4 が `live` を要る時に、
その時の**本物の形**(3経路の union)を見て enum を起こす方が、今 optional を並べた struct を
置いて後から直すより安全 —— 置いた struct は「動いている」ので誰も見直さない。
★ただし **`display.route.kind` は5値ある**(`tmux`/`worker`/`choice`/`blocked`/`unknown`)。
今回の観測に `choice`/`blocked`/`unknown` は出ていないが、**必ず5値とも描き分けを持つ事**。
未知の `kind` が来た時は `unknown` と同じ見た目に落とし、**デコードを失敗させない**
(古い電話が新しいサーバの語彙で一覧ごと真っ白になる方が害が大きい。`readablePoll` の
「知らない `kind` は捨てて良い」と同じ判断)。

---

## §2. C群の移植 — `relTime` / `freshness`

### §2-a. 出所と、写し取り方

- `relTime`: `rc-backend/src/view.mjs` の `export function relTime(iso, nowMs)`
- `freshness`: `rc-backend/src/view.mjs` の `export function freshness(fetchedAtMs, nowMs)`

Sprint 1 が `readablePoll` で確立した作法を**そのまま踏襲**する:
`ios/Tests/Core/ReadablePollTests.swift` の冒頭コメントのとおり、**`rc-backend/test/view.test.mjs` の
該当ブロックの入力を1件ずつ写して**検査を組む。期待値を自分で考え直さない —— 考え直した瞬間、
JS と Swift が「同じ状況で違う判断を見せる」余地ができる(仕様 §0-4 が C群を drift の起点と
名指ししている理由がこれ)。

対応する JS 側の検査(`rc-backend/test/view.test.mjs`、名前で引く事):
- `relTime は時計に依存せず、粒度ごとに変わる`
- `★一覧の古さ — 60秒で「今」を名乗るのをやめる(画面自身の目盛りに合わせる)`
- `一覧の古さ — 時計がずれて未来を指しても壊れない(relTime と同じ扱い)`

### §2-b. 落としてはいけない性質

| 関数 | 性質 | 落とすと何が起きるか |
|---|---|---|
| `relTime` | パースできない入力 → **空文字**(例外でも "?" でもない) | 行が壊れて一覧ごと落ちる |
| `relTime` | 負の差(時計ずれ)→ 「たった今」 | 未来の日付が出る |
| `relTime` | 60秒未満は全部「たった今」 | `freshness` の閾値の根拠が消える |
| `freshness` | `fetchedAtMs` が 0/未設定 → `{text:"いつ測った値か不明", stale:true}` | **fail-open**。古さの警告だけ消えて値は古いまま |
| `freshness` | 境目は **60秒ちょうどで stale**(59秒は stale でない) | 画面ごとに違う「古い」が起きる |

★`freshness` の不明値を `{text:"", stale:false}` に倒す改変で**必ず赤くなる**検査を持つ事
(`view.mjs` の `freshness` 冒頭コメントが、その改変を綴りごと名指しで警告している
= 一度誰かが倒しかけた形)。

### §2-c. 時計をテストへ渡す

両方とも `nowMs` を引数で受ける純関数として移植する(`Date()` を関数の中で読まない)。
UI 側が「今」を注入する。理由: JS 側が既にそうなっており、そうでないと境目の検査が書けない。

---

## §3. List の挙動

### §3-a. 行(§2-2)

| 要素 | 出所 | 備考 |
|---|---|---|
| 題 | `title`。空/欠けなら **`id` の先頭8桁** | 仕様 §2-2 |
| 副題 | `display.subtitle` | サーバ計算値。**自分で組み立てない** |
| 相対時刻 | `relTime(updatedAt, now)` | C群、Swift 実装 |
| 経路の札 | `display.route.short` | 9-10文字想定の短い札 |
| 経路の短文 | `display.route.text` | 札の下 or 副題の隣 |
| 色/強調 | `display.route.kind` で出し分け | `choice` は**最も強い**強調。Enter が承認や課金になる唯一の状態 |

★`display.route.text` は最長 92 文字になりうる(`view.mjs` の注記)。1行に押し込んで切らない
(切ると「★選択待ち(Enter が承認や課金になります)」の後半が消える)。

### §3-b. 一覧下部

`display.scan` をそのまま1行で出す。加工しない。

### §3-c. 古さ(§2-2 の `freshness`)

一覧が**取れた時刻**を保持し、`freshness(fetchedAt, now)` の `text` を薄く出す。`stale` が真なら強調。
`now` は画面が再描画される度に評価されればよい(タイマーは張らない —— §2-2 が明示的に
「時計での定期取得はしない」)。ただし**画面が前面に戻った時**は再評価する(そうしないと
30分放置した画面が「12秒前の値」と言い続ける)。

### §3-d. 更新契機(§2-2)

初回表示 / pull-to-refresh / フォアグラウンド復帰時。
(「Conversation から戻った直後」は Conversation が存在しないので Sprint 3 で足す。**今回は入れない**)

### §3-e. メモリキャッシュ(§4-2 の唯一の例外)

同一アプリセッション内でのみ、直近に成功した一覧を保持する(stale-while-revalidate)。
**ディスクには一切書かない。** 再取得中も前の一覧を出したまま、上に取得中の印を出す。

---

## §4. §5-2 の分岐 — 4つ全部を実装する

仕様 §6 の Day 2 行は「§5-2 の3分岐」と書くが、§5-2 の表は**4行**ある。4行とも実装する
(スクリーンショットの DoD が3状態なだけで、401 の行を落としてよいという意味ではない)。

| 状況 | 判定材料 | 表示 | a11y id(例) |
|---|---|---|---|
| 真に0件 | `sessions:[]` **かつ** `paneFault == nil` | 「会話がありません」+ `display.scan` | `list.empty` |
| `paneFault` あり | `paneFault.reason` | 一覧の**上**に専用バナー。`reason` と `detail` を出す | `list.paneFault` |
| fetch 失敗 | HTTP 層 | 前回の一覧をグレーアウトして**残す** + 赤バナー + 手動再試行。**空一覧に差し替えない** | `list.unreachable` |
| 401 | HTTP 層 | Key-entry へ強制遷移 | — |

★**`paneFault` が在って、かつ `sessions` も空**の時に「会話がありません」を**重ねない**。
文としては嘘ではない(200 で 0 件は返っている)が、0 件の**理由**は故障の方に在る。
2つ並べると、人は上の赤を「ついでの警告」と読んで下の断定を信じる。
判定の順序を `paneFault` が先、空の文言は後 —— と固定し、検査で押さえる事。

### §4-a. 裁定 — 「1回失敗」と「backend unreachable」を混ぜない

§5-4 は `backend unreachable` を **接続不可・タイムアウト・5xx が連続3回**と定義している。
一方 §5-2 の3行目は「fetch 自体が失敗」で赤バナーと書く。この2つを素直に読むと、
**1回の失敗で「unreachable」と名乗る**事になり、§5-4 の定義と正面から衝突する。

裁定(私が決めた。仕様の穴):

- List の取得に**連続失敗の計数**を持つ。成功が1回でも入ったら 0 に戻す。
- **1〜2回目**: 一覧は残す(グレーアウトはしない)。控えめな1行 +「再試行」。**赤バナーは出さない**。
- **3回目以降**: §5-4 の状態。赤バナー(文言は「backend unreachable」の定義どおり)+ 一覧をグレーアウト。
- どちらの段でも**空一覧に差し替えない**。ここが §5-2 の本体。

★**残す一覧が無い場合**(初回取得がいきなり失敗した時)。上の「一覧は残す」は、
残す物が在る前提の文である。初回は無い。此処を書き落とすと、Generator は
**「会話がありません」**(= 真に0件の画面)に落とす —— 一覧が空なのではなく**届いていない**のに、
「無い」と断言する画面が出る。§5-2 が塞ごうとしている事故そのもの。従って:

| 連続失敗 | 前回の一覧が在る | 前回の一覧が無い(初回) |
|---|---|---|
| 1〜2回 | 一覧を残す + 控えめな1行 + 再試行 | **取得中でも0件でもない第3の状態**: 「まだ取れていません」+ 再試行。空の文言は出さない |
| 3回以降 | 赤バナー + グレーアウト | 赤バナー(グレーアウトする一覧が無いだけ)+ 再試行 |

「会話がありません」を出してよいのは **HTTP 200 が返って `sessions` が空だった時だけ**。
検査で固定する事(§5-a-4 の状態機械に、初回失敗の遷移を1本足す)。

★**何を数え、何を数えないか**(此処を曖昧にすると、健康なサーバで赤が出る)。

| 出来事 | 計数器 |
|---|---|
| 接続不可 / タイムアウト / 5xx | **+1** |
| HTTP 200(`paneFault` の有無に関わらず) | **0 に戻す** |
| 401 | 数えない(Key-entry へ抜けるので、そもそも一覧に留まらない) |
| **取得の取り消し**(`CancellationError` / `URLError.cancelled`) | **数えない** |

★取り消しを数えない理由(Codex 指摘、2026-08-05): pull-to-refresh を素早く3回引くと、
先行の取得が取り消される。素朴な `catch` はこれを失敗として数え、**サーバは全く健康なのに
赤バナーが出る**。画面遷移で `task` が畳まれた時も同じ。取り消しは「届かなかった」の証拠ではない。
検査で1本固定する(取り消しを3回起こしても段が上がらない事)。

★`paneFault` が 0 に戻す理由: あれは **200 が返っている** = サーバには届いている。
届かなさを数える計器に、届いた事を混ぜない。故障は専用バナーが言う(§4 の表)。

根拠は2つ。

(1) §5-4 が「連続3回」という**計器**をわざわざ定義しているのは、電波が1瞬またたぐ度に
赤を出さない為。1回で赤くすると、地下鉄で赤が点滅し続ける = 人は赤を無視する様になる。

(2) **仕様自身が既に同じ形を別の軸で採っている**。§5-5(配信が読めない)の表は
「1-2回 = 画面上端に**静かな**1行(赤バナーではない)」「3回目 = 警告」と段を分けている。
つまり「連続回数で段を分け、赤は最後に取っておく」はこの仕様の作法であって、私の発明ではない。
§5-2 の行は、その作法を**書き忘れた**だけと読むのが自然。

★**仕様の中で閾値が1つずれている**(2026-08-05 に見つけた。裁定: **3** を採る)。

| 場所 | 書いてある事 |
|---|---|
| §5-4(定義の節) | 「接続不可・タイムアウト・5xx が**連続3回**発生した状態(§3-6 と統一)」 |
| §3-6(backoff の節) | 「**3回連続失敗するまでは**目立つエラー表示を出さない。**4回目以降**は §5-4 の表示に切り替える」 |

素直に読むと §3-6 は「3回目でもまだ出さない、4回目から出す」= 閾値4。§5-4 は「3回でその状態」
= 閾値3。**同じ物を指しているのに1つずれている**。

採るのは **3**。理由: (a) §5-2 の3行目は表示の名前を「backend unreachable」と書いており、
その語の**定義**を持つのは §5-4 である。(b) §5-4 自身が「§3-6 と統一」と書いている =
書いた側は2つを同じ数のつもりでいる。数として書かれているのは §5-4 の「3」だけで、
§3-6 の方は「〜まで / 〜以降」という散文の言い回しである。ずれたのは散文の側と読む。

計数器は List の ViewModel に置き、**Sprint 6 が共通コンポーネントへ持ち上げられる形**にしておく
(= 閾値と文言を1箇所に定数で持つ)。持ち上げは Sprint 6 の仕事で、今回はやらない。
★**閾値は名前の付いた定数1つ**で持ち、条件式に数字を直に書かない(例 `unreachableThreshold`)。
Sprint 6 が §5-4 を共通コンポーネントへ持ち上げる時、**探す物が1つである事**が、
上のずれの再発を止める唯一の手段になる。
★Sprint 4 は §3-6 を実装する。**そこで 4 を実装すると List と Conversation で「届かない」の
意味が変わる** —— §5-4 が「1箇所にまとめる」と書いて防ごうとしたのが、まさにこれ。

★★**この計数器を §5-5 の `unreadableStreak` と同じ変数にしない**。仕様の 訂正4 は
「§5-4 と §5-5 は**別の計器**を持つ」事が本体で、比較表(§5-4 vs §5-5)をわざわざ置いている。
数える対象が違う —— §5-4 は**届かなかった回数**(接続不可 / タイムアウト / 5xx)、
§5-5 は**届いたが読めなかった回数**(200 なのに中身が壊れている)。畳むと、200 が返り続ける
限り赤が出ない、あるいは逆に読めない 200 で「サーバに届かない」と嘘を吐く。
Sprint 2 が作るのは**前者だけ**。後者は Sprint 4 の領分で、今回は変数も作らない。

### §4-b. 401 の扱い

`AppState` から資格情報を落として Key-entry へ戻す。**Keychain も消す**(古い鍵を持ったまま
戻ると、Key-entry が「保存済み」と誤認する道ができる)。`CredentialStore.clear()` が既に在る。

---

## §5. 検査 — 何をどう測るか

### §5-a. 単体(`ios/Tests`)

1. `relTime` / `freshness` の移植一致検査(§2-a、JS の入力を写す)。
2. `freshness` の 59/60 秒の境目、および**不明値を fail-open に倒す改変で赤くなる**負の対照。
3. `SessionsClient` のデコード検査 —— **§0 の本物の形をそのまま fixture にする**:
   - 39本の縮小版(tmux 行 / worker 行 / `fromRegistryOnly` 有無)が全部デコードできる。
   - `display.route.screen: ""` が nil に化けない。
   - **未知の `kind`**(例 `"future-kind"`)でデコードが落ちない。
   - `paneFault` 非 null の形。
   - ★**`live` を無視している事を固定する検査**: `live` が丸ごと無い本文、および
     `live` が tmux / worker / blocked のどの形でも、**同じ様にデコードが通る**事。
     今は「書かなければ無視される」で自然に通るが、後から `CodingKeys` を厳格化した
     誰かがここを壊す。無視は**決定**なので、決定として押さえる(Codex 指摘、2026-08-05)。
   - ★負の対照: `display` を落とした本文で**デコードが失敗する**事。**2本要る** ——
     (a) 行の `sessions[].display` を落とした本文、(b) 応答の外側の `display` を落とした本文。
     どちらも本物のサーバは必ず付ける(`/api/sessions` が毎回組み立てている)ので
     **non-optional で受ける**のが正。optional で受けると「静かに空の画面」になる道が残る。
4. ViewModel の状態機械:
   - §4 の4分岐。
   - 連続失敗 1回目 / 2回目 / 3回目の遷移、成功で 0 に戻る事。
   - **前回の一覧が無い(初回)** 側の 1〜2回目 / 3回目(§4-a の表)。
   - **取り消しを3回起こしても段が上がらない**事。
   - **`paneFault` 付きの 200 が計数器を 0 に戻す**事。
   ★負の対照2本: (a) 閾値を1に下げる改変で赤くなる検査、
   (b) 取り消しを失敗として数える改変(`catch` を1本にまとめる)で赤くなる検査。
5. 既存の 55 本は**1本も落とさない**。

### §5-b. UI(`RemoteMiniUITests` — 新規標的)

`project.yml` に `type: bundle.ui-testing` の標的を足し、scheme の test targets に追加する。
`xcodegen` は導入済み(`/opt/homebrew/bin/xcodegen`)、`build.sh` が毎回 `xcodegen generate` を呼ぶ。

**fixture の入れ方(裁定)**: 網を使わない。`#if DEBUG` でのみコンパイルされる fixture 実装を、
起動時の環境変数 `RC_UI_FIXTURE=<状態名>` で差し込む。

- なぜ網を使わないか: 127.0.0.1 の fixture サーバは **ATS** に当たる。
  ★正確に言うと、**localhost サーバが原理的に ATS 例外を要求する訳ではない**(build 設定を
  分ければ Debug だけに例外を置く道は在る。Codex 指摘、2026-08-05)。此処での理由は
  **この project の作りに固有**である: `project.yml` は Info.plist を1つしか持たず、
  「ATS の例外は要らない。**そのまま保て** —— 例外はどこへでも平文を許す」と注記している。
  例外を足せば出荷物に入る。入らない様にするには plist と config を分ける機構が要り、
  それは fixture の protocol 1本より**大きい**。小さい方を採る、というだけの判断。
- なぜ `#if DEBUG` か: 実機の配布は `build.sh` が `-configuration Release` で作る(実測、
  `build.sh` の実機側の `xcodebuild` 行)。DEBUG 限定なら出荷物に fixture の道が1本も無い。
  ★`UI_TESTING` 専用の compilation condition を切る案(Codex)は**採らない**。より狭いのは
  確かだが、config を1つ増やすと `build.sh --sim`(Debug)で撮る DoD のスクリーンショットが
  撮れなくなり、撮る為の config をもう1つ足す事になる。**出荷物から消える**という目的は
  DEBUG で既に達成される。狭さの差は Sprint 6 の候補として `progress.md` に残す事。
- fixture は **プロトコルの実装**であって、`SessionsClient` の中に分岐を作らない。
  ★そのプロトコルは**まだ無い。Sprint 2 が作る**(`SessionsListing` 等、名前は任せる)。
  既存の `HealthzChecking` / `SessionsAuthChecking` と同じ形 —— 1 メソッドの protocol を
  production 側に置き、本番実装と fixture 実装がそれを名乗る。
  ★`SessionsAuthProbe` を流用しない。あれは Key-entry が鍵の正しさを見る為だけの物で、
  本文を捨てている(`(_, response) =`)。自身のコメントが「List の data source は Sprint 2 が持つ」と
  書いており、**役割が違う2つを1つにすると、鍵の検査と一覧の取得が同じ失敗分類を共有する**。
- fixture 中で **ホスト名・URL を一切持たない**(網へ行かないので不要)。仮の鍵は
  `"ui-fixture-key"` の様に一目で偽と判る物にし、**Keychain へは書かない**。

状態: `list-normal` / `list-panefault` / `list-empty`(DoD の3枚)。必要なら `list-401` も。

**負の対照(必須)**: Release ビルドのバイナリに `RC_UI_FIXTURE` の文字列が**無い**事を測る。
かつ Debug のシミュレータ用バイナリには**在る**事も測る(錨。無ければ「探し方が壊れていて
何も見ていない」が緑になる)。`ios/tools/` に検査台本を置き、`rc-backend/tools/run-controls.sh` の
`LOCAL_CTLS` へ登録する(**未登録の対照は対照ではない**、というこの repo の既決)。

★**Release バイナリの作り方**(此処を書かないと Generator が実機ビルドの壁に当たって
この対照を落とす)。**実機も署名も要らない**: シミュレータ SDK で Release を作れる。

```
cd ios
xcodegen generate                                     # build.sh と同じ前段
xcodebuild -project RemoteMini.xcodeproj -scheme RemoteMini -configuration Release \
           -sdk iphonesimulator -derivedDataPath build build
strings build/Build/Products/Release-iphonesimulator/RemoteMini.app/RemoteMini | grep -c RC_UI_FIXTURE   # 期待 0
strings build/Build/Products/Debug-iphonesimulator/RemoteMini.app/RemoteMini   | grep -c RC_UI_FIXTURE   # 期待 1以上(錨)
```

(`ios/tools/build.sh` の `SCHEME=RemoteMini` / `DERIVED=$HERE/build` / `SIM_NAME=iPhone-dogfood` と
同じ値。`--sim` は **Debug しか作らない**ので、Release は上の様に別に叩く)

`grep -c` が 0 の時 `grep` は終了コード1を返す。台本で `set -e` を使うなら**この行で落ちる** ——
「無い事」を測る行が、無いという理由で台本ごと止まる形。数を変数に取ってから比べる事。

★**綴りを探すだけで終わらせない**(Codex 指摘、2026-08-05: 「binary string scanning is brittle」)。
綴りが無い事は、**その道が動かない事**の証拠としては弱い。振る舞いの側でも1本測る:

```
xcrun simctl install <dev> build/Build/Products/Release-iphonesimulator/RemoteMini.app
SIMCTL_CHILD_RC_UI_FIXTURE=list-empty xcrun simctl launch --terminate-existing <dev> com.tomarai.remotemini
# 期待: fixture の一覧は出ない(鍵が無いので Key-entry 画面になる)= 環境変数が無視されている
```

2本の関係: 綴りの検査は**速くて毎回回せる**、振る舞いの検査は**強い**。両方置く。
片方だけにするなら振る舞いの方を残す。

### §5-c. スクリーンショット(DoD)

`ios/tools/shots.sh`(新規)で3状態を撮る。**GUI ウィンドウを開かない**:

```
xcrun simctl boot "iPhone-dogfood"                       # headless。Simulator.app は開かない
xcrun simctl install <dev> build/Build/Products/Debug-iphonesimulator/RemoteMini.app
SIMCTL_CHILD_RC_UI_FIXTURE=list-panefault xcrun simctl launch --terminate-existing <dev> com.tomarai.remotemini
xcrun simctl io <dev> screenshot .harness/evidence-2026-08-05/list-panefault.png
```

★`open -a Simulator` は**禁止**(このセッションの恒久制約)。`sleep` は台本の中でのみ使う
(素の Bash で打つと harness が止める)。

### §5-d. 走らせる物

| 何を | 期待 |
|---|---|
| `./ios/tools/build.sh --sim` | `Executed N tests, with 0 failures`、rc=0。N は 55 より増える |
| `cd rc-backend && npm test` | 654 → 変わらない(rc-backend は触らない) |
| `bash rc-backend/tools/run-controls.sh` | green=全数、red=0、未測定=0 |
| 新しい対照(Release バイナリ) | PASS |

---

## §6. 引き継いだ制約(破ると commit の門で止まる)

1. **HTTP を持つ型は `BackendSession` を受け取る。素の `URLSession` を書かない。**
   `rc-backend/test/session-guard.test.mjs` が `ios/Sources/` 全体を走査して赤にする。
   例外が要るなら ALLOWED に**理由を書いて**足す(足す手間が「意図した抜け道です」の記録になる)。
2. **既定のサーバホストを Swift の source / placeholder / fixture / コメントに一切書かない。**
3. **鍵をログに出さない。** 診断行にも fixture にも入れない。
4. `.harness/progress.md` 以外に**行番号参照を書かない**(`no-linerefs` が赤にする)。
   走査するのは `rc-backend` と `ios` の2本の木で、repo 直下の `.harness/` は範囲外
   (2026-08-05 実測 —— この brief に行番号を5件書いた状態で検査を回し、報告されたのは
   `rc-backend` 側の1件だけだった)。★だが **Swift のコメントに「ファイル名 + コロン + 行番号」を
   書けば赤くなる**。`test/no-linerefs-controls.sh` の対照①が `ios/Sources/` に1件植えて
   赤になる事を毎回測っている。関数名や特徴のある綴りで引く事。
   ★この brief 自身も行番号を全部落とした。範囲外でも、行番号は書いた瞬間から写しで、
   これを読む Generator は**ずれた行**へ案内される。範囲は言い訳にならない。
5. GUI ウィンドウを開かない。実機ビルドは Tom の iPhone が要るので**今回はやらない**。
6. commit は local のみ。push しない。

---

## §7. Definition of Done

- [ ] `./ios/tools/build.sh --sim` が rc=0、失敗0、テスト数が 55 から増えている
- [ ] `run-controls.sh` が全 green(新しい対照2本を含む)
- [ ] `list-normal` / `list-panefault` / `list-empty` の PNG 3枚が
      `.harness/evidence-2026-08-05/` に在る
- [ ] XCUITest がバナー文字列を a11y identifier 経由で確認している
- [ ] `.harness/progress.md` に、決めた事・落とした物・仕様の穴を書いた
- [ ] 未着手 / 積み残しを**名指しで**書いた(「全部できた」と書かない)

---

## §8. 外部レビュー(Codex、2026-08-05)

この brief の3つの裁定を Codex(gpt-5.6-sol / xhigh)に**壊しに掛からせた**。送った問いと
返った答えの全文 = `.harness/evidence-2026-08-05/codex-sprint2-brief-2026-08-05.txt`。判定と、私の応答:

| Codex の指摘 | 私の判定 | 反映先 |
|---|---|---|
| 裁定1(`live` を描かない/デコードしない)は**維持**。ただし「`live` が無くても・どの経路でも同じ様にデコードが通る」検査を1本足せ | **採用**。無視が決定なら、決定として押さえるのが正しい | §5-a-3 の最終行 |
| 裁定2は**書かれた通りでは誤り** —— 初回失敗には残す一覧が無く、1〜2回目の画面が未定義 | **採用**(Codex の回答が届く前に自分でも同じ穴を見つけて塞いでいた。独立に2回出た穴) | §4-a の表 |
| フォアグラウンド復帰の取得は「利用者の明示操作」ではない | **採用**(私が Codex への説明で口を滑らせた箇所。挙動は変えない —— 自動でも3回届かなければ届いていない。数える対象を表で明示した) | §4-a の計数表 |
| **取り消しを失敗として数えるな** | **採用。これは自力で見つけていなかった**。pull-to-refresh を素早く3回で健康なサーバに赤が出る | §4-a の計数表 + §5-a-4 の負の対照(b) |
| localhost サーバが**原理的に** ATS 例外を要求する訳ではない(build 設定を分ける道が在る) | **採用** —— 私の理由付けが強すぎた。決定は変えないが、根拠を「この project の作りに固有」へ書き直した | §5-b |
| `DEBUG` でなく `UI_TESTING` 専用条件を切れ | **却下**。config が増えると DoD のスクリーンショットが撮れなくなり、撮る為の config を更に足す事になる。「出荷物から消える」目的は DEBUG で達成される。狭さの差は Sprint 6 候補として残す | §5-b + `progress.md` |
| バイナリの綴り走査は脆い。**振る舞い**で測れ | **採用(両方置く)**。綴りは速くて毎回回せる、振る舞いは強い。片方だけなら振る舞いを残す | §5-b の末尾 |
| 4つ目の穴: `paneFault` 付きの 200 は「転送失敗でも綺麗な成功でもない」。計数器をどうするか未定義 | **採用**。200 = 届いている → **0 に戻す**。届かなさの計器に届いた事を混ぜない | §4-a の計数表 + §4 の表 |

★8件中7件を採り、1件を理由付きで却下した。**自力で見つけていなかったのは2件**
(取り消しの計数、`paneFault` と計数器の関係) —— どちらも「健康なサーバで赤が出る / 出ない」
という、**出荷してから人の目にしか映らない**型の欠陥である。
