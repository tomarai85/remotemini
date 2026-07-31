# 次セッション厳密ハンドオフ — RC 模倣バックエンド(移動中スマホ作業)

**起動合図**: 「移動中作業のプロジェクトの続き」
**最終更新**: 2026-08-01 01:0x(Codex 二次レビューの2件を直し、対照付きで検査した地点 = `8d403b9`)
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
   照合は補助。**状態不明なら送信しない**(fail-closed)。
3. **割り込みは Escape**。`C-c` は画面状態で入力消去/中断/終了に化けるので緊急停止専用。
   割り込みと本文を連続送信しない。
4. **CHOICE(ツール承認待ち)画面で Enter を押さない**。Escape のみ。

### 1-C. ★画面状態の判定 — 過去形と進行形を取り違えると永久に詰まる(2026-07-31 実機で判明)

| 実物の行 | 意味 | 判定 |
|---|---|---|
| `✻ Baking… (12s · esc to interrupt)` | 生成中(進行形) | BUSY |
| `✻ Baked for 0s` | 完了(**過去形**。scrollback に残り続ける) | **BUSY ではない** |

かつて「スピナー記号 + `... for N秒`」を BUSY と読む規則があり、一度でも応答したペインが
**永久に BUSY** になっていた。キューは READY でしか流れないので送った本文は永久に滞留し、
電話から復旧する手段が無い。しかも**週次上限に当たった画面がまさにこの形**。
→ 規則ごと削除。判定材料は `esc to interrupt` **だけ**。
今後 BUSY の変種を実測したら、**過去形を巻き込まない「進行中の形」だけ**を足すこと。

**さらに絞ってある(2026-08-01)**: `state()` は `capture-pane -S -30` = **scrollback 30行**を読む。
そこにこの語が**文章として**出れば BUSY に見える。しかもこの案件自体が Claude Code の割り込みを
扱っているので、応答本文にこの語が出るのは通常運転。→ 判定は**行単位**で、その行に
スピナー記号 or `· esc to interrupt` が在る時だけ BUSY。

倒す方向の根拠(**この非対称を崩さないこと**):

| 誤り | 何が起きるか |
|---|---|
| 誤 BUSY | 我々のキューに滞留。キューは READY でしか流れず、電話から流す手段が無い |
| 誤 READY | Claude Code 自身が入力をキューする = 人が打つのと同じ。CHOICE は先に弾いている |

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

node 22/25 両対応、依存ゼロ、`node:http` のみ。**単体 74 / e2e 70、全緑**(最終確認 8/1 00:5x、
MBP=Node 22。edith=Node 25 での通しは 7/31 23:45 が最後 = `8d403b9` は未検証)。

| ファイル | 中身 | テスト |
|---|---|---|
| `src/sessions.mjs` | jsonl から一覧/メタ/履歴を抜く純関数。`entrypoint:"cli"` で絞る | 7 |
| `src/ring.mjs` | SSE 再接続追いつき用リングバッファ(gap 検出) | 6 |
| `src/worker.mjs` | `-p --resume` 経路の状態機械(TUI が無い会話専用) | 10 |
| `src/inject.mjs` | tmux 面。ペイン列挙 / 画面判定 / 本文+Enter 分離 / Escape | 23 |
| `src/registry.mjs` | 登録簿の読み手。`resolveSessionPane` = 宛先の決定 | 28 |
| `src/server.mjs` | HTTP 面(8エンドポイント + 検証ページ + bearer) | e2e で覆う |
| `test/e2e-local.mjs` | 偽 tmux / 偽 claude-work を注入した実サーバ通し検証 | 70 |

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
| **注入キューがプロセスメモリにしか無い** | サーバ再起動で、電話に「積みました」と返した本文が黙って消える(7/31 に実際に1件消えた) | 登録簿と同じくファイルに落とす。または「積む」をやめて即時拒否に寄せる(BUSY が正しく短命なら積む必要が薄い) |
| ~~Evaluator + Codex の品質ゲート未実施~~ **一巡した(8/1)** | Codex 二次レビュー5件 → 実物に当てて2件採用・修正。対照2本で新規約が効いていることを確認 | 残: `8d403b9` は **edith(Node 25)で未実行**。次に edith に触る時に通す |
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
| コード | `~/Infra/mobile-work/rc-backend/`(`npm test` = 単体74 / `node test/e2e-local.mjs` = 70) |
| edith 側の道具 | `~/.claude/tools/{rc-pane-register.sh,rc-claude}`(edith では `~/.claude-sync/tools/`) |
| 登録簿の実体 | `~/.rc-backend/panes/<session_id>.json`(mtime = 心拍) |
| 画面判定と宛先決定の設計 | `DESIGN.md` §2.9 / §2.10 |
