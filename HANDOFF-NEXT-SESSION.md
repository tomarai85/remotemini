# 次セッション厳密ハンドオフ — RC 模倣バックエンド(移動中スマホ作業)

**起動合図**: 「移動中作業のプロジェクトの続き」
**最終更新**: 2026-08-01 03:2x(**注入層を実測に合わせて作り直した地点** = `fd7a5fa`)
**★このファイルで最初に読む所**: §1-C。**前回までの BUSY/キューの設計は撤回済み**で、
古い前提のまま手を入れると存在しない状態を調整する事になる(7/31・8/01 に2回やった)。
**モデル**: Opus 5 で開く。この作業は認証・アクセス制御を含むので Fable 5 は途中で止まる(実測)。

**読む順**: このファイル → `DESIGN.md` §2.9/§2.10/§8 → `WORKLOG.md`(新しい物が上)→
`REQUIREMENTS.md`(出典付き要件)→ `research/` 3本(一次資料)。

---

## 0. 何を作っているか(1段落で正確に)

iPhone から、Mac mini(edith, `desk.tailnet.example` = 10.0.0.0)の中で動いている
Claude Code のセッション群を「一覧 → 選ぶ → 読む → 打つ → ストリームで返る」まで操作する
自前バックエンド + iPhone 用の画面。Anthropic 公式 Remote Control の**設計**を模倣するが製品は
使わない(公式 RC は長寿命トークンで動かない = edith の fleet トークン認証と構造的に非互換。
`research/remote-control-teardown.md` §1・§5 で確定)。

**Tom の確定した要求**(逐語・`REQUIREMENTS.md` に出典付き):
- 「セッションは1つだけではないから Remote control の設計を大きく真似する」(7/31)
- 「返答待ちであれ作業中であれ**いつでも見て、干渉できればいい**」(7/31)← D3/割り込みの根拠
- 「質をめちゃめちゃ高める方が大事、正確性も大事」(7/31)= 工程を省略しない
- アカウント切替が UI から要る(7/28「CodexBar と同じようにスムーズに」)= **あれば嬉しい。本丸ではない**

---

## 1. 設計の芯(ここを取り違えると全部やり直しになる)

### 1-A. 送信経路は2本。TUI が開いていれば**そのペインに注入**する

初期実装の「TUI 保持セッションは 409 で拒否」は Tom 7/31 裁定で**撤回済み**。
外し方は2通りあり、採るのは注入側:

| | 方式 | 判定 |
|---|---|---|
| 旧 | iPhone の送信 = 別プロセスで `claude -p --resume` を起こす | **二重プロセス = lost-update。TUI が開いている時は不採用** |
| **本線** | iPhone の送信 = **動いているその tmux ペインへ send-keys** | 会話は1プロセスのまま。二重実行が原理的に起きない |

`src/worker.mjs`(`-p --resume`)は **「その会話が TUI で開かれていない場合」専用**に降格。

### 1-B. 注入の規約(Codex レビュー確定・verbatim で守る)

1. **本文と Enter を分けて送る**。`tmux send-keys -t <pane> -l -- "$text"` → 別コマンドで
   `tmux send-keys -t <pane> Enter`。一括だと生成中にバッファされ完了後に意図せず送信される。
2. **「今 TUI が入力を受け付けているか」を tmux から確実に知る API は無い**。`capture-pane` の
   照合しか無い(= 補助ではなく**唯一の材料**。だから構造で判定し、外れ方を安全側に倒す。§1-C)。
   **状態不明なら送信しない**(fail-closed)。
3. **割り込みは Escape**。`C-c` は画面状態で入力消去/中断/終了に化けるので緊急停止専用。
   割り込みと本文を連続送信しない。
4. **CHOICE(ツール承認待ち)画面で Enter を押さない**。Escape のみ。

### 1-C. ★画面状態の判定 — **BUSY は存在しなかった**(2026-08-01 実測で設計ごと反転)

**先に結論**: 送信可否は「生成中か」では決めない。**入力欄(composer)が画面に在るか**で決める。
自前の送信キューは撤去した。生成中でも送る。

**なぜ反転したか(この段落が本体)**。BUSY 判定の唯一の材料 `esc to interrupt` を、
実機の生成中の画面で 0.25 秒刻み 240 枚撮って探した → **0 枚**。このビルド(2.1.220)の画面に
その語は出ない。つまり BUSY は一度も成立しておらず、キュー経路は**死んだコード**だった。
7/31 と 8/01 の「修正」は 2 回とも、存在しない状態の閾値を調整していた。
(採取物: `rc-backend/test/fixtures/screens/*.txt` = 実機の現物 8 枚)

**代わりに何を見るか。**

| 見る物 | 定義(構造。文字列一致ではない) | 効果 |
|---|---|---|
| `screen` | `SENDABLE` = `❯` の行が上下を長い `─` の罫線に挟まれ、**viewport の下 8 行以内**に在る / `CHOICE` = 番号付き選択肢が近接2行以上 + カーソル / `UNKNOWN` = どちらでもない | **送信可否はこれだけで決まる** |
| `activity` | スピナーが見えるか(`observed` / `unknown`) | **表示専用。遮断条件に流用しない** |

`activity` を遮断に使えない理由も実測: 6.5 秒の生成中にスピナーが見えたのは 26 枚中 8 枚(**31%**)。
残りは tmux のヒント行が同じ行を占める。→ **「スピナーが無い」は「暇」ではない**。

**倒す方向(この非対称を崩さないこと)**:

| 誤り | 何が起きるか |
|---|---|
| 誤 SENDABLE(実は選択画面) | **Enter が承認や課金の選択になる**。最悪 |
| 誤 UNKNOWN(実は送れた) | 電話に「送りませんでした」と出て、人が画面を見に行く。損失は待ち時間だけ |

→ **分からなければ送らない**。ただし CHOICE の誤検出も詰まりを生むので、CHOICE は
「番号行が近接2行以上 + カーソル」まで絞ってある(電話から `1. …` と送った**本文**で
自分のペインを送信不能にしない為。対照テスト有り)。

**捨てた道具**: 自前キュー(`pending`/`drain`)。生成中に送ると **TUI 自身がキューして次のターンで
処理する**ことを実測(M5)。我々が積む必要は無い上に、プロセスメモリ上のキューは
サーバ再起動で黙って消える(7/31 に実際に 1 件消えた)。

**scrollback を読まない**: `capture-pane` に `-S` を付けない = **viewport だけ**。
過去の行を今の状態と読む失敗の型が構造的に消える(テストで `-S` 不使用を検査している)。

### 1-D. ★宛先は「名乗り」でしか決めない。cwd 一致は同定ではない

外から `session_id → tmux pane` を辿る手は**存在しない**(実測: 対話 claude の
`pane_current_command` は `2.1.220` というバージョン文字列 / jsonl は開きっぱなしでない(lsof=0)/
argv は素の `claude`)。→ **会話自身に名乗らせる**(登録簿)。

cwd 一致で代用してはいけない: 直近7日で `~/.claude` だけに **192会話が同じ cwd**。
1枚しか開いていない時、それが電話で選んだ会話である保証は無く、外れれば**他人の会話が実際に
動き出す**。→ `unregistered` として拒否し、ワーカーにも落とさない(本人である可能性を否定できず、
落とすと lost-update)。文面に直し方を書く:「その画面を `rc-claude` で開き直すと送れます」。

**裏返しの規約(2026-08-01)**: 「登録先のペインが消えた」も**その会話が死んだ証拠ではない**。
rc-claude で開いて登録 → 終了 → 素の `claude --resume` で別ペインに開き直す、という順序を踏むと
登録簿だけが古くなる。ラッパ方式を採っている以上これは例外ではなく通常運転。
→ ワーカーに落とす前に `livePaneNearby()`(同じ cwd に**誰も名乗っていない** claude が居るか)を
通し、在れば `unregistered`。cwd 一致は**同定には弱すぎるが警戒には十分強い** — この非対称が
この関数の全て。名乗り済みのペインは見ない(= 別の会話だと分かっている)。

---

## 2. 実装の現状(`~/Infra/mobile-work/rc-backend/` = git・local only)

node 22/25 両対応、依存ゼロ、`node:http` のみ。**単体 84 / e2e 78、全緑**。
**MBP(Node v22.14.0)と edith(Node v25.9.0)の両方で通してある**(8/1 03:1x)。
edith へは `rsync` → `mktemp -d` の使い捨てコピーで走らせ、検査後に `rm -rf` + `ls` で不在を確認。
**edith に常設物は置いていない**。edith で回したのは commit 直前の作業ツリーで、
その後に触ったのは `.md` だけ = `fd7a5fa` の `src/`・`test/` と同一。

| ファイル | 中身 | テスト |
|---|---|---|
| `src/sessions.mjs` | jsonl から一覧/メタ/履歴を抜く純関数。`entrypoint:"cli"` で絞る | 7 |
| `src/ring.mjs` | SSE 再接続追いつき用リングバッファ(gap 検出) | 6 |
| `src/worker.mjs` | `-p --resume` 経路の状態機械(TUI が無い会話専用) | 10 |
| `src/inject.mjs` | tmux 面。ペイン列挙 / **画面分類** / 3相送信 / Escape | 33 |
| `src/registry.mjs` | 登録簿の読み手。`resolveSessionPane` = 宛先の決定 | 28 |
| `src/server.mjs` | HTTP 面(8エンドポイント + 検証ページ + bearer) | e2e で覆う |
| `test/e2e-local.mjs` | 偽 tmux / 偽 claude-work を注入した実サーバ通し検証 | 78 |
| `test/fixtures/screens/` | **実機の画面 8 枚**(手書き fixture は撤去) | 両方の入力 |
| `test/mutation-controls.py` | **守りを1つずつ壊して検査が気付くか測る** | 10/10 検出 |

### 2-A. 送信は3相(この順序が守りの本体)

1. 分類 → `SENDABLE` でなければ**その場で 409**(Enter を一切押さない)
2. `send-keys -l --` で本文だけ入れる
3. **もう一度画面を撮る** → 選択画面に化けていたら `modal-appeared` で中断 /
   本文が入力欄に載っていなければ `composer-mismatch` で中断。**どちらも Enter を押さない**
4. Enter → 受領確認。入力欄から本文が消えていれば `delivered:"verified"`、
   **入力欄自体が消えていた場合は `"unverified"`**(確かめられなかったので「送れた」と言わない)

Codex は「本文と Enter を1回の呼び出しに纏めろ」と言ってきたが**採らなかった**。
纏めると 3 の再観測が消え、承認画面が割り込んだ時に Enter が入る。往復1回の節約より重い。

### 2-B. 送信を断った理由(電話に日本語で出る。`SEND_REFUSAL` と 1:1)

| reason | いつ | 電話に出る意味 |
|---|---|---|
| `choice` | 送る前から選択画面 | 「Enter が承認や課金の選択になるため送信しません」 |
| `unknown` | 入力欄が見つからない | 「起動中・別画面・ペイン消滅のいずれか。安全側に倒しました」 |
| `modal-appeared` | 本文を入れた**直後**に選択画面 | 「Enter を押さずに中断しました」 |
| `composer-mismatch` | 本文が入力欄に載らなかった | 「Enter は押していません。もう一度お試しください」 |

### 2-C. ★検査が守りを掴んでいる事を、変異で測ってある

**なぜ要るか**: 反転前の suite は 74/74 緑だったのに、検査していた状態(BUSY)は
**一度も画面に出た事が無かった**。緑は守りが働く証拠にならない。
→ `test/mutation-controls.py` = `src/inject.mjs` の守りを 10 通りに壊し、
tempdir に複製して `npm test` + `e2e` を回し、**全部が落ちるか**を表で出す(1つでも生き残れば exit 1)。
初回に **E2E が M4(選択画面の割り込み = 賭け金が最大の守り)を取り逃していた**のが判明し、
対照ペイン `%17` を足して塞いだ。現在 10/10 検出・両機で exit 0。

**edith 側に配ってある物**(`~/.claude` リポジトリに commit 済・edith へは `~/.claude-sync/` 経由):
- `tools/rc-pane-register.sh`(`7a2140e7`)= statusLine として動く最小の登録スクリプト
- `tools/rc-claude`(`52347f09`)= `--settings` で↑を足して `exec claude` するラッパ

**なぜラッパか**: edith の `~/.claude/settings.json` に `statusLine` キーが**無い**(継ぎ目が無い)。
`settings.local.json` は user レベルでは呼ばれず、プロジェクト直下の `.claude/settings.json` は
PreToolUse hook が block(ファイル名判定なので edith 上でも止まる。迂回しない)。
`claude --settings <JSON文字列>` だけが保護対象に触れずに通る。
**このラッパで起動すること自体が「この会話は電話から操作してよい」の意思表示**で、D5 裁定
(remote-mini を on にしたセッションだけ一覧に出れば十分)とそのまま噛み合う。

### 拒否理由(`reason`)の一覧 — 扱いが分岐するので潰さない

| reason | 意味 | 扱い |
|---|---|---|
| `ok` | 登録簿で宛先が確定 | 注入する |
| `none` | tmux に居ない。**かつ同じ cwd に名乗っていない claude も居ない** | ワーカー経路(`-p --resume`)へ |
| `not-claude` | ペインは在るが claude ではない。**かつ同上** | ワーカー経路へ |
| `ambiguous` | cwd 経路で複数候補 | 409 |
| `unregistered` | **有効な登録が無く** cwd に claude が在る(`source` で「未登録」と「登録が古い」を区別) | 409。**ワーカーにも落とさない**。直し方を文面に出す |
| `stale` | 同じペインをより新しい会話が名乗っている | 409。ワーカーにも落とさない |
| `cwd-mismatch` | 登録されたペインの現在地が会話の cwd と違う | 409。同上 |
| `pane-gone` | jsonl もペインも無い | 409(存在しない会話を resume させない) |

---

## 3. ★まだ直していない穴(次に手を入れるならここ)

| 穴 | 影響 | 直し方の当て |
|---|---|---|
| **★実機の tmux へ一度も送信していない** | 緑なのは全部**偽 tmux の上**。画面分類は実機の現物 8 枚に当ててあるが、`send-keys` の往復は誰も通していない | **次の一手はこれ**。使い捨てセッション名で edith に 1 枚立て、SENDABLE→送信→受領確認まで観測する(本物の `work` セッションは触らない) |
| ~~注入キューがプロセスメモリにしか無い~~ **撤去した(8/1)** | — | キューごと消した。生成中は TUI 自身がキューする(実測 M5) |
| ~~Evaluator + Codex の品質ゲート未実施~~ **一巡した(8/1)** | Codex 二次レビュー5件 → 実物に当てて2件採用。その後の反転で規約ごと作り直し、変異10種で検査の実効性を確認 | 残無し(`fd7a5fa` は両機で通し済み) |
| 電話側の画面が無い | 今は素の検証ページのみ | PWA で中身を動かし、触ってから native 判断(Tom 承認済みの順序) |
| **edith に rc-backend の常設が無い**(7/31 の実機検証は `/private/tmp/rc-smoke` の使い捨てコピーで行い、検査後に撤去済 = 現在 edith 上にサーバの実体は無い) | 電話から叩く相手が存在しない。常駐(launchd)と配置先が未決 | 配置先を決める(`~/rc-backend` が素直)→ 同期経路 → launchd。**production 扱いなので safety-core の verifier artifact が要る** |

---

## 4. Tom にしかできない事(全文は `DESIGN.md` §8)

1. **edith の `~/.claude/settings.json` に statusLine を1行**(hook 強制で私は触れない)。
   入れれば全セッションが自動登録され、ラッパ不要になる。**1-D で cwd 経路を塞いだので、
   この1行の重みは上がった**(未登録の会話は注入が一切効かない)。
2. `sudo mkdir -p /Users/tomtim && sudo chown edith:staff /Users/tomtim`(sudo は構造的に不可能)。
   **持ち出し/戻し機能だけが依存**。本体はこれ無しで動く。急がない。
3. **★edith をどの Claude アカウントで走らせるか**。実測: `oauthAccount.emailAddress` =
   `mail-redacted@example.invalid`(会社側)、かつ**週次上限に到達**(解除 8/3 0時 JST)。
   渡米 8/20・client-a 引き渡し進行中を跨ぐと前提が崩れる。推奨 = 個人アカウントへ切替(§8-3)。

---

## 5. 触ってはいけない/蒸し返さない(出典 = `research/requirements-mining.md` §2)

- **本物の tmux `work` セッションで実験しない**(必ず使い捨てセッション名で)
- **BUSY / 自前の送信キューを復活させない**。実測で否定済み(§1-C)。生成中は送ってよい
- **画面 fixture を手書きで足さない**。旧 fixture はコードと同じ誤解を写していたので、
  検査もコードも同時に間違ったまま緑になっていた。増やすなら実機から撮る
- `activity`(スピナー)を送信可否の条件に使わない。**観測率 31%**なので偽の「暇」を作る
- 二重プロセス方式(TUI が開いている会話に `-p --resume` を別に起こす)= lost-update
- `RC_BIND` は 127.0.0.1 のまま(tailnet 公開は §6 セキュリティモデルの Codex sanity が先)
- CHOICE 画面で Enter(Escape のみ)
- mosh / ServerAliveInterval / Termius / App Store Blink(全て却下確定)
- 通知に中身を載せる(「Claude が待っています」固定文のみ = 却下済み)
- edith の `edith-claude-http.mjs`(:11435)を改造起点にする(契約が別物 = OpenAI 形式。
  warm-pool/bearer/env-allowlist の**パターンだけ**参照、コード流用しない)

## 6. 在り処まとめ

| | |
|---|---|
| 設計・要件・作業記録 | `~/Infra/mobile-work/{DESIGN,REQUIREMENTS,WORKLOG}.md` |
| 一次資料 | `~/Infra/mobile-work/research/{remote-control-teardown,asset-survey,requirements-mining}.md` |
| コード | `~/Infra/mobile-work/rc-backend/`(`npm test` = 単体84 / `node test/e2e-local.mjs` = 78 / `python3 test/mutation-controls.py` = 10/10)。**`node --test test/` は動かない。`npm test` を使う** |
| 検査の証跡 | `~/Infra/mobile-work/.harness/feedback/check-2026-08-01-1.md`(証拠表 + 未検証の列挙) |
| 実機の画面(現物) | `~/Infra/mobile-work/rc-backend/test/fixtures/screens/*.txt` — **手書きで足さない**。増やすなら実機から撮る |
| edith 側の道具 | `~/.claude/tools/{rc-pane-register.sh,rc-claude}`(edith では `~/.claude-sync/tools/`) |
| 登録簿の実体 | `~/.rc-backend/panes/<session_id>.json`(mtime = 心拍) |
| 画面判定と宛先決定の設計 | `DESIGN.md` §2.9 / §2.10 |
