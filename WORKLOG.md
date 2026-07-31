# WORKLOG — 移動中スマホ作業(RC 模倣レーン)

追記専用。作業の区切りごとに1エントリ。目的 = コンテキスト悪化・クラッシュ・セッション交代が
あっても、ここを読めば「今どこで、次に何か」が分かる状態を常に保つ(Tom 指示 2026-07-31:
「設計に関連するものは全部 .md に保存して、定期的に記すことを忘れないで」)。

書式: `## YYYY-MM-DD HH:MM — 見出し` / 何をした / 証拠 / 次の一手。新しい物が上。

---

## 2026-08-01 00:5x — 二次レビューで2件。どちらも「1回目の直しが浅かった」型(`8d403b9`)

`52b42d8` に対して Codex で二次レビューをかけた。指摘5件のうち、**私が実際にソースを読んで
再現経路を確認できた2件**を直した(Codex は `codex-quick.sh` 経由 = ファイルを読ませていないので、
指摘は推論。鵜呑みにせず1件ずつ実物に当てた。3件目は Codex の説明した機序が実際の経路と違い、
別の機序で成立していた)。

### 1. BUSY 判定に、同じ形の穴がまだ残っていた

前回「スピナー記号 + 過去形」の規則を消して `esc to interrupt` の出現だけにした。だが
`state()` は `capture-pane -S -30` = **scrollback 30行**を読む。そこにこの語が**文章として**
出れば BUSY に見える。そしてこの案件自体が Claude Code の割り込みを扱っている =
応答本文にこの語が出るのは仮定ではなく通常運転。

→ 判定を行単位にし、その行が進行中の形(スピナー記号 or `· esc to interrupt`)かまで見る。

方向を決めたのは代償の非対称: 誤 BUSY = 我々のキューに滞留して電話から流す手段が無い /
誤 READY = Claude Code 自身が入力をキューする(人が打つのと同じ)。**締める側に倒す**。

### 2. 「登録先のペインが消えた」は「その会話が死んだ」ではない

古い登録を見て無条件に `none` / `not-claude` を返し、ワーカー(`-p --resume`)に落としていた。
実際に起きる順序: rc-claude で開いて %12 を登録 → 終了 → 素の `claude --resume` で %99 に
開き直す。登録簿だけが古くなり、会話は %99 で生きている。ここでワーカーを起こすと
同じ会話を2プロセスが触る = lost-update(この設計が最初に潰した敵そのもの)。

→ `livePaneNearby()`: 「同じ cwd に、**誰も名乗っていない** claude が居るか」を先に見て、
在れば落とさず `unregistered` にする。cwd 一致は同定には弱すぎるが警戒には十分強い、という
非対称がこの関数の全て。名乗り済みのペインは見ないので、登録が行き渡るほど静かになる。

### 証拠

- 単体 74/74、E2E 70/70(MBP・Node 22)
- 新規約を1つずつ壊す対照2本。どちらも**狙った2件だけ**が赤(他72件は緑):
  `.harness/feedback/check-2026-08-01-mutation.md`
- BUSY を絞った副作用で旧テスト2つが赤くなったが、これは規約の変更であって回帰ではない。
  E2E の `%15` fixture は `✻ Brewed for 12s` + 裸の `esc to interrupt` = **実在しない画面**
  (完了行と生成中の行は同時に出ない)。前回と同じ「自分の誤解を写した fixture」を
  もう1つ抱えていた。実測の行に差し替え済み。

### 事故: 作業ツリーの衝突(自分の手順の誤り。再発防止のため残す)

mutation 検査を任せた背景 subagent に「該当箇所を一時的に壊してよい(必ず戻すこと)」と
明示的に許可したまま、**同じ作業ツリーで自分も src/ を編集していた**。agent の
「HEAD へ戻す」が私の未コミット変更を消した(src 2ファイル + test 3ファイル)。
検知 = system reminder のファイル内容が編集前に戻っていた → `git status --porcelain` と
`grep -c` で確認。復旧 = 全編集を再適用。**ファイルを壊す agent を走らせている間、同じツリーを
自分で編集しない。壊すなら scratchpad の複製で**。今回は再適用後すぐコミットして固定した。

### 次の一手

- 注入キューの永続化(Codex の唯一の推奨。既知の穴の筆頭)
- edith への常設配置 + launchd(production 扱い = verifier artifact 必須)
- iPhone 画面(PWA)

---

## 2026-07-31 23:43 — 実機の煙で誤りが2つ出た。両方直して edith に反映(`52b42d8`)

テストが全部緑のまま、実機に本文を通したら**2件とも実害のある誤り**だった。両方とも
「テストを書いた自分の思い込みと、コードの思い込みが同じだった」ために緑だった類。

**誤り1 — 一度でも喋ったペインが永久に BUSY になる**

`inject.mjs` に「スピナー記号 + `... for N秒`」を BUSY と読む規則があった。これが捕まえていたのは
生成中の行ではなく**完了行**:

| 実物 | 意味 |
|---|---|
| `✻ Baking… (12s · esc to interrupt)` | 生成中(進行形) |
| `✻ Baked for 0s` | 完了(**過去形**。scrollback に残り続ける) |

完了行は消えないので、一度でも応答したペインは以後ずっと BUSY。キューは READY でしか流れないので
**送った本文は永久に滞留し、電話から復旧する手段が無い**。実測: 画面は入力待ち、`/status` は BUSY、
POST は `queued:true`、`grep -c` でペイン内 **0件**。しかも週次上限に当たった画面がまさにこの形
= 渡米中に必ず踏む。→ 規則ごと削除し、判定材料を `esc to interrupt` **だけ**にした。

**誤り2 — cwd 一致で「たぶんこの会話だろう」と注入していた**

`candidates===1`(その cwd に claude のペインが1枚)を `ok` として本文+Enter を送っていた。だが
直近7日で `~/.claude` だけに **192会話が同じ cwd** を共有している。1枚しか開いていない時、それが
電話で選んだ会話である保証はどこにも無く、外れれば**他人の会話が実際に動き出す**。
→ 新しい拒否 `unregistered` を追加。ワーカー(`-p --resume`)にも落とさない(その会話本人である
可能性を否定できず、落とすと同じ会話を2プロセスが触る = lost-update)。文面に直し方まで書く:
「その画面を `rc-claude` で開き直すと送れるようになります」。

**Codex(gpt-5.6-sol xhigh)に先に当てた**。両方とも提案どおりの回答:
「`candidates===1` は同定ではない」/「規則3は削除。別の広いスピナー一致で置き換えないこと」。

**検査**: 単体 69/69・e2e 70/70(MBP=Node 22 / edith=Node 25 の両方)。mutation 対照4本すべて
弁別的 — 旧スピナー規則を戻すと**新規2件だけ**が落ち、cwd の `ok` を戻すと単体2+e2e6 が落ちて
出力に事故そのものが出る(`send-keys -t %24 -l -- "他人の会話に入ってはいけない本文"` + Enter)。

**live 再検証(edith)**: `%18` が READY に戻り本文を受理(1件)。実在の会話 `ac686843` は
`blocked/unregistered` を返し、Tom の実 `work` ペイン `%0` への到達は全マーカーで0件。
検査後 edith は原状復帰(`work` のみ・rc-backend プロセス無し・登録簿空)。

**この過程で見つかった、まだ直していない2件**(DESIGN.md §2.10「既知の穴」/ §8):
1. 注入キューが**プロセスメモリにしか無い**。サーバ再起動で、電話に「積みました」と返した本文が
   黙って消える(この session で実際に MARK_SECOND が1件消えた)。
2. edith の Claude アカウントは `~/.claude.json` の `oauthAccount.emailAddress` =
   **`mail-redacted@example.invalid`(会社側)**で、**週次上限に到達**(解除 8/3 0時 JST)。
   渡米・引き渡しを跨ぐと前提が崩れる。Tom 判断事項として §8-3 に推奨つきで置いた。

**次の一手**: (a) キューの永続化、(b) Evaluator + Codex レビュー、(c) 電話側の画面(PWA)。

## 2026-07-31 23:18 — edith で live 実証 + 「まだ発言していない会話」を通した

**1. edith には statusLine の継ぎ目が無かった**(初回 live smoke が空振りした真因)。
`~/.claude/settings.json` に `statusLine` キーが無い機械では、スクリプトを配っても1件も登録されない。

| 経路 | 実測 | 判定 |
|---|---|---|
| edith の `~/.claude/settings.json` に1行 | 未実施 | **本筋。Tom の手作業**(hard boundary / hook 強制) |
| `~/.claude/settings.local.json` | statusLine が呼ばれない | user レベルでは効かない。ファイル撤去済 |
| プロジェクト直下 `.claude/settings.json` | PreToolUse hook が block | ファイル名判定なので edith 上でも止まる。迂回しない |
| `claude --settings <JSON>` | **通る** | 保護対象に一切触れない。これを採用 |

→ 作った物2つ(`~/.claude` リポジトリに commit 済):
- `tools/rc-pane-register.sh`(`7a2140e7`)= statusLine として動く最小の登録スクリプト
- `tools/rc-claude`(`52347f09`)= `--settings` で↑を足して `exec claude` するラッパ

**live 実証(edith)**: 同じ cwd で `rc-claude` を2つ起動 → `%16` / `%17` をそれぞれ自分で登録。
画面右下に `Sonnet 5 | /Users/Shared/dev/roundtrip [rc %16]` を目視。登録ファイルの mtime が
6秒で `1785506639 → 1785506645`(心拍として使える)。検査後 edith は原状復帰。

**2. jsonl は最初のメッセージまで作られない**(edith 実測。開いて4分放置してもファイルが無い)。
一覧は jsonl 走査なので、**開いて席を立った会話は電話から見えない = 最初の一言を送れない**。
Tom 裁定「いつでも見て干渉できればいい」に対する穴だったので塞いだ(`03f6493`)。

- 一覧: 登録があり `ok` の時だけ足す。ペイン消失 / not-claude / stale は**出さない**
  (叩いても送れない行は、無い行より悪い)
- title = `(未発言)`、turns 0、cwd = ペインの現在地。中身が無いので捏造しない
- history は 404 でなく `200 {history: []}`。messages は jsonl もペインも無ければ `409 pane-gone`
  (ワーカーに落とすと存在しない会話を `-p --resume` しようとする)
- ついでに登録簿の読みを1リクエスト1回に(書き手が2秒ごとに書くので、2回読むと食い違いうる)

**検査**: `npm test` 66/66(registry 24件)/ e2e 64/64 を5回連続で緑。
mutation 対照3本 — 採否ガードを消すと専用の3件だけ落ち、一覧合流を外すと4件、
jsonl 不在の許容を外すと6件。いずれも戻すと緑(検査が効いている証拠)。

**次の一手**: rc-backend を edith に置いて、実登録された会話に対して全エンドポイントを叩く。

**Tom 依頼(1件・私は触れない)**: edith の `/Users/edith/.claude/settings.json` に
```json
"statusLine": { "type": "command", "command": "bash ~/.claude-sync/tools/rc-pane-register.sh", "refreshInterval": 2 }
```
を追加。入れば `rc-claude` ラッパ無しで全セッションが登録対象になる。入れなくてもラッパで回る。

---

## 2026-07-31 22:4x — ★宛先問題を解いた: 会話が自分のペインを名乗る(実装+検査 完了)

§2.9 で本線が tmux 注入になった後に残っていた穴 = **iPhone で選んだ会話が今どのペインに居るか
バックエンドが知る手段が無い**。これを塞いだ。設計の全文 = DESIGN.md §2.10。

**外から辿る手は存在しないことを実測で確定**(edith):

| 手掛かり | 実測値 | 判定 |
|---|---|---|
| cwd 一致 | 直近7日で `~/.claude` 192件・`~` 78件が同じ cwd | 絞れない(複数開くのが常態) |
| `pane_current_command` | **`2.1.220`**(バージョン文字列) | `claude` でも `node` でもない |
| jsonl を掴む pid | `lsof` = 0 | transcript は開きっぱなしでない |
| argv | 素の `claude` | セッション ID が乗らない |

→ 会話自身に名乗らせる以外に手が無い。

**書き手** = `~/.claude/statusline.sh` に rc-backend ブロックを挿入(SID 確定の直後)。
tmux 内の時だけ `~/.rc-backend/panes/<session_id>.json` を原子的に置く。
statusline を選んだ理由 = TUI と同じプロセス系から呼ばれるので `$TMUX_PANE` が確実に居る
(SessionStart hook は同じ保証を持たない)。バックアップ = `statusline.sh.bak.20260731-215416-pre-rcpane`、
やめる時はブロックごと削除で原状復帰。

**Tom の手元の見た目が変わっていないことの証拠**: 編集前(.bak)と編集後を同一コマンド内で
交互に5往復実行 → 出力は毎回バイト一致・stderr 0 バイト。
(1回目の「出力が変わった」は私の計測ミス。statusline は実行中の Bash タスク名を描くので
別々に走らせれば当然ずれる。交互実行に直して解消。)

**読み手** = `rc-backend/src/registry.mjs`。原則は**登録簿を信じ切らない**。
`ok` / `none` / `not-claude` / `ambiguous` / `stale` / `cwd-mismatch` の6状態に分け、
決められない3つ(ambiguous / stale / cwd-mismatch)は 409 でワーカーにも落とさない
(落とすと同じ会話を2プロセスが触る = §2 の敵2 lost-update)。

**検査(全て実測)**:
- `npm test` 59/59(registry 17件を追加)。cwd フォールバックは実物の `resolvePane` を呼ぶ
- **mutation 6/6**: 各ガードを1つずつ壊すと赤が正確に1件ずつ(検査が効いている証拠)
- e2e 51/51 を10回連続。同じ cwd に claude 2つを置き、実サーバ越しに双方が自分のペインへ届く
- **session_id ガードの対照**: 非16進 SID `zz` でガード有り0件 / ガード無し1件
  (最初に置いた対照は空虚だった — ガードを外しても失敗する対照は何も証明しない。作り直した)
- **flake の根治**: e2e 10回中1回落ちた3件を再現 → 原因は製品でなく**テストの固定待ち**(800ms)。
  条件待ちに置換。対照 = 偽ワーカーに1500ms 遅延を入れ、待ち上限8000で 51/51 /
  待ち上限800(旧相当)で狙った3件だけ赤。診断の裏取り完了。

コミット `00762cd`。

### 次の一手
edith 実機での smoke(git 同期が edith に届いた後、使い捨て tmux セッションで
`~/.rc-backend/panes/<sid>.json` が正しいペインで生えるか)。その後 iPhone 画面。

## 2026-07-31 20:0x — ★訂正: mini は手詰まりではない(枯渇しているのは Opus 枠だけ)

前エントリで「mini の Claude が応答できない = 設計の前提が不成立」と書いたが**言い過ぎ。訂正する**。
4トークンを read-only で個別実測(切替はしていない):

| アカウント | 判定 | 根拠 |
|---|---|---|
| team | 使用不可 | `is_error:true` |
| biz  | 使用不可 | `is_error:true` |
| **sdgs** | **生存** | `is_error:false` / 2.8s / result="Hi Tom. Jervis online…" |
| **tom**  | **生存** | `is_error:false` / 2.5s / result="こんにちは、Tom。…" |

**両方とも `modelUsage` は `claude-sonnet-5`。** つまり:
- 単発 `-p` は Sonnet 5 で通る = **アカウントは生きている**
- 対話 TUI で出た "You've hit your weekly limit" は**既定モデル(Opus)の週次枠**の話
- failover ログの「上位は全て不能」は team/biz について**正確**だった(誤報ではない)

→ **8/3 を待つ必要はない。iPhone レーンは Sonnet で今日から成立する。**

### 設計への反映
「CodexBar と同じ機能」(Tom 7/28)の中身が具体化した。iPhone 画面に出すべきは
**アカウント名だけでは足りない**:
1. 現用アカウント
2. **使用中モデル**(Sonnet で通る/Opus は枯渇、が実際に起きる分岐)
3. 上限到達の有無とリセット日時
4. 切替ボタン

机なら CodexBar で見えるが移動中は見る手段が無い = このレーン固有の必須要件。

### 手法上の教訓(次に同じ失敗をしないため)
`is_error` を見ずに文字列パターンだけで生死判定して「全滅」と読みかけた。
判定は**構造化フィールドを最優先**、文字列マッチは補助。
また edith に `timeout` は無い(Mac 側で掛ける)、`claude -p` は `< /dev/null` 必須
(stdin 警告が判定文字列を汚す)— この2つは既知だが今回また踏んだ。

## 2026-07-31 19:4x — ★対話 TUI への注入が実機で成立・同時にアカウント枯渇を発見

**Opus 5 に切替後、止まっていた 1-C の残り半分を実測。**

### 成立したこと(設計の中核が確定)
使い捨て tmux セッションで対話 claude を起動し、外部から
`send-keys -l -- "<本文>"` → 別コマンドで `Enter` を送ったところ、
**入力欄に文字が入り送信まで到達**(capture-pane で `❯ Reply with exactly: INJECTED_OK` を確認)。
→ **HANDOFF §1-A の tmux 注入方式は実機で成立**。「動いているその Claude に iPhone から
話しかける」が設計として確定した。二重プロセス方式は完全に不要。

### 同時に発見した重大な事実(前提が1つ崩れた)
応答の代わりにこれが出た:
```
You've hit your weekly limit · resets Aug 3 at 12am (Asia/Tokyo)
What do you want to do?
 ❯ 1. Stop and wait for limit to reset
   2. Switch to usage credits
   3. Upgrade your plan
```
**edith の現用アカウント sdgs が週次上限に到達**(リセット 8/3)。さらに:
- `token-failover.log` は2時間ごと正常稼働だが中身が全て `ok active=sdgs・上位は全て不能`
  = team/biz は既に落ちており、**切り替える先が無い**(.order は team→biz→sdgs→tom、
  tom のトークンは 7/26 配置のまま未検証)
- `.pool-thin` フラグは**立っていない** = 枯渇検知が実態に追いついていない疑い(要調査)

→ **mini 側 Claude が応答できない状態**。iPhone から送っても返らない。設計の前提
「mini の Claude が応答できる」が今は不成立。

### 設計への反映(変更ではなく追加)
1. **上限到達画面は「送ってはいけない状態」の実例**。ここに本文や Enter を送ると
   `2. Switch to usage credits` を選びかねない = **課金に触る誤爆**。
   HANDOFF §1-B-2 の「状態不明なら送らない(fail-closed)」の必要性が実物で裏付けられた。
   承認/選択待ち画面の検知は**必須**であって nice-to-have ではない。
2. **iPhone 画面にアカウント状態表示が必須**(Tom 7/28 要求「CodexBar と同じように」の中身)。
   机なら CodexBar を見れば分かるが、移動中は見る手段が無い = このレーン固有の必要性。
   表示すべき: 現用アカウント / 残量または上限到達 / リセット日時 / 切替ボタン。
3. 誤爆防止の実装線: 選択肢待ち画面を検知したら **Enter を送らない**。
   Escape のみ許可(Codex 規約 §1-B-3 と整合)。

**後片付け**: 検証セッションは kill 済み、選択肢は何も選んでいない(プラン変更・課金は発生せず)。
`/tmp/rc-tui-test` が edith に残存(空の作業 dir、機微なし)。

## 2026-07-31 18:5x — 割り込み実装の途中(次セッションへ引き継ぎ点)

- Tom 裁定確定: 「返答待ちでも作業中でも iPhone からいつでも見て干渉できる」。
  → 409(TUI 保持セッションは書き込み拒否)は**外す**方針。二重プロセスでなく
  「動いているその Claude 自身に入力を送る」= tmux への send-keys 注入方式に切り替える。
- **次の一手 = 使い捨て TUI セッションで send-keys 注入が届くかの実測**(本物の work には触れない)。
  検証コマンドは組んだが未実行(このセッションは Fable 5 でセキュリティ系作業がブロックされ停滞)。
- rc-backend の現状: sessions/ring/worker + server.mjs + E2E 実装済み。unit 23緑、E2E 16中15緑。
  唯一の赤 = 「TUI 保持 → 409」の陽性対照。これは 409 を外す方針で作り替えるので、
  そのまま直せばよい(server.mjs の isTuiHeld / messages ハンドラ)。
- **推奨: 次はセッションを再起動して Opus 5 で続ける**(settings.json 固定 = 再起動で自動)。
  起動合図「移動中作業のプロジェクトの続き」。
- Tom の手が要る保留: edith に sudo mkdir /Users/tomtim(急ぎでない・持ち出しのみ後回し)。

## 2026-07-31 18:0x — D3 確定(実測+Codex 補正)・設計フェーズ実質完了

- codex-d3 は300秒 timeout(exit 124)だが推論ブロック4つを回収、3つが設計に入った:
  (1) 成否の中核はセッション単位の排他と「実行状態を jsonl から推測しない」
  (2) 既存 warm-pool は --resume 済み会話の cache を温めない(私の流用想定への訂正)
  (3) 同一セッション2端末 resume は公式に interleave 仕様 → 衝突テストの主眼は lost-update
- **中核仮定を edith 実測で立証**(/tmp/multiturn-test.py・使い捨てセッション 1b5c9362):
  1ワーカー(-p --resume --input-format stream-json)に2ターン → MULTITURN-OK、
  cache_creation 31k→19-20 tokens、TTFR 2.27→1.81s、exit 0
- **D3 確定 = セッション常駐ワーカー方式**(1セッション1ワーカー = 排他が構造で成立、
  割り込み = kill、10分断問題はクラスごと消滅)。DESIGN.md D3 行に証拠つきで記載
- D1(器)は「バックエンドは両分岐で同一 = branch-independent に先行実装」と整理
- 次 = spec.md(Phase I-1: edith 上のバックエンド骨格 — 一覧 API / ワーカー管理 / ストリーム中継)

## 2026-07-31 17:4x — 要件採掘の受領・REQUIREMENTS §4 充填完了

- req-mining 完了(`research/requirements-mining.md`)。設計を変えた発見3つ:
  1. RC 製品の却下理由が 2026-06-13 に明文で存在(vendor-closed・拡張不可・connecting 待ち
     =「所有して拡張する」違反)→ 合格条件 6/7 に昇格
  2. **アカウント切替は逐語の必須要件**(2026-07-28「CodexBar と同じようにスムーズに」)
     → REQUIREMENTS §4-5 新設、DESIGN §2 に行追加(土台 = fleet-account 実装済み)
  3. 承認まわりの一次資料の張り合い(全許可ハンズフリー原則 2026-06-17 vs
     「危険操作はスマホから承認しない」破棄前 §6-1)→ D4 統合案: 通常ハンズフリー+
     hard-stop は通知のみ・承認ボタン無し。本家の「電話から承認」は不採用。設計書全体を整合済み
- REQUIREMENTS §4-2/4-3/4-4 を出典付きで充填、§5 合格条件9項を起草(各行に出典)。
  4-2 で出典間の食い違い1件を検出し明記(mining 行20 vs REQUIREMENTS §1 の 7/30 訂正の読み。
  操作的には 7/31 RC 指示が優先)
- Phase R 完了。残り: codex-d3(D3 アーキテクチャの第二の目)が返れば DESIGN 確定 → spec.md

## 2026-07-31 17:2x — 調査②受領・D3 の材料確定

- asset-survey2 完了(`research/asset-survey.md`、edith 実測)。要点:
  - **本命確定**: `claude -p --resume <id> --output-format stream-json` が実測で動く
    = 1メッセージ1プロセスの chat UI backend が組める
  - 設計上の敵2つ: cache-miss TTFT 2.3〜3.2秒+5hレート枠消費(warm-pool の型で対策)/
    稼働中 TUI セッションへの同時 -p は未検証(TUI 保持分は読み取り専用に倒す+実装前に衝突テスト)
  - 一覧は `entrypoint:"cli"` で選別(EDITH の sdk-cli 自動化ログ数百件が混在)。
    タイトル= `ai-title` 行、最終メッセージ= `last-prompt` 行、最終更新= mtime
  - 8643 の誤同定を訂正(jervis-gateway = 無関係)。Claude 呼び出しは必ず claude-work 経由
  - edith 上に残ったテスト痕跡: `/tmp/rc-asset-survey-test/` と使い捨てセッション jsonl 1本
    (TEST1/TEST2 のみ、機微なし。フックが rm を正しくブロックしたため残存 — 次の衝突テストに流用可)
- DESIGN.md §2 を実測で充填。D3 の私の傾き = 都度駆動+jsonl tail(読み取り専用)。
  **決定前に Codex sanity 実行中**(質問4本: 応答中切断/2連投/実行中誤検知/warm-pool 成立性/kill 整合性/A を捨てる将来リスク)。
- req-mining はまだ実行中。REQUIREMENTS §4 の充填はその受領後。

## 2026-07-31 17:0x — セキュリティモデル起草

- DESIGN.md §6.5 追加: 4層(tailnet / デバイス+紛失時失効 / 端末固有トークン / edith 厳格権限)。
  本家から採る安全線3つ(Bypass 遠隔不可・承認短寿命・会話ステートを外に出さない)。
  未決2点は未決と明記(L3 トークン形式・承認カード粒度)。実装前に Codex sanity 必須と記載。
- 実行中のまま: asset-survey2 / req-mining(ディスク直書き)。

## 2026-07-31 16:5x — クラッシュ復旧 + 要件方針の転換

- **方向確定(Tom)**: Remote Control の**設計**を大きく真似る。製品は edith で構造的に使えない
  (長寿命トークン拒否・調査①で確定)ので自前実装。質・正確性 > スピード。
- **クラッシュ被害査定**: 調査①(RC 解剖)は受領済み → `research/remote-control-teardown.md` に
  完全版で固定(前版は39行で途切れていた)。調査②(edith 資産)は死亡 → `asset-survey2` として
  再投入(結果をディスク直書きする指示つき)。他は全て無傷。
- **要件方針の転換(Tom)**: §4 の空欄は「Tom に聞く」から「過去の会話・.md 群から出典付きで
  組み立てる」へ。採掘エージェント `req-mining` 投入(出力 = `research/requirements-mining.md`)。
- **DESIGN.md**: §1(何を真似るか)を調査①で充填。決定軸 D1-D5 のうち **D3(セッション駆動形)が
  本丸**で、調査②の実測(`claude --resume -p` + stream-json で既存セッションに1往復足せるか)待ち。
- 実行中: `asset-survey2` / `req-mining`(いずれも background、ディスクへ直書き)。
- 別件: build 6 は電話に配備済み・未起動(Tom のロック解除待ち)。edith tmux clients=0 確認済み。

## 2026-07-31 16:3x — RC 設計調査の受領

- 調査①(rc-teardown)完了。要点: outbound-only + 中央ブローカー中継 / 会話状態は
  Anthropic サーバ持ち(それが再接続・複数デバイス同期の担保)/ 遠隔からの slash はほぼ不可 /
  承認は電話から可・Bypass 切替は不可 / 10分ネット断で exit / confirm-before-replace。
- **決定的事実**: RC は API キー・長寿命トークンを明示拒否 = edith(fleet トークン)では
  本家製品が使えない。「なぜ作るか」が調査から確定。
- Tailscale 直結の我々は中央ブローカー+登録/ポーリングを丸ごと省略できる(本家より単純にできる)。

## 2026-07-31 16:0x — build 6 実機配備

- iPhone が devicectl paired だったので差分ビルド→install→配置→読み戻し md5 一致まで完了。
  launch のみ Locked で拒否 = 残る物理ゲートは Tom のロック解除+タップ1動作。
- キット改善: known_hosts が参照ゼロの孤児だったのを配線 / 接続先を MagicDNS 名へ
  (`desk.tailnet.example`、`edith-ip` の逃げ道つき)。詳細 = blink-selfbuild/README.md Build 6 節。

## 2026-07-31 昼 — レーン再開・基礎測定

- remote-mini の実用上の上限を実測: 両機同一絶対パスが条件だが edith に `/Users/tomtim` が無く、
  **今日時点で持ち出せる実案件ゼロ**。作るには Tom の sudo 1回(分岐 a)か
  `/Users/Shared/dev` 運用(分岐 b)。→ この分岐は RC 模倣設計の D5(一覧スコープ)に吸収された。
- 電話の着地点 = tmux work = `/Users/Shared/dev/roundtrip`(信頼済み・Claude Code 稼働中)を実測。
