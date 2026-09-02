# 機能パリティ表 — 公式 Remote Control / Claude iOS "Code" タブ 対 RemoteMini

作成 2026-09-01。**Tom は「Native のは使わない」と裁定済み**(`research/requirements-mining.md` §1)。
よってこれは採否の比較ではなく、**写す先の目録**である。

- **公式側** = 2026-09-01 取得。出典 URL を各行に置いた。裏が取れなかった物は推測せず **不明** と書いた。
  判断を最も左右する 5 件(diff 面 / subagent 停止 / `@` 補完 / 承認プロンプトの寿命 / ディレクトリ選択)は
  委譲した取得を鵜呑みにせず、私自身が `code.claude.com` を取り直して原文を確認した。
- **RemoteMini 側** = **コードから**。ドキュメントの記述は根拠に使っていない。全 `file:line` は
  mobile-work の根からの相対で、書く前に実在を確認した。
- この repo は remote 無しで `.harness/push-readiness-check.sh` は NOT READY。
  **外部公開を前提にした案は1つも書いていない**。

## 反映の記録(表の `absent` が `present` へ変わった行)

表本体は 2026-09-01 の観測のまま残す(書き換えると「何が無かったか」の記録が消える)。
反映した行は此処に足す。**表の absent 行数 22 のうち、反映済み = 下の件数**。

| 日 | 行 | 何を入れたか | 根拠(中身の目印) |
|---|---|---|---|
| 2026-09-02 | #2 走査距離 | 1 MiB → 16 MiB(`server.mjs` の `SEARCH_TAIL_MAX`。素の履歴の `TAIL_MAX` とは別に持つ) | `searchHistoryFromPath(target, q, limit, { maxBytes: SEARCH_TAIL_MAX })` |
| 2026-09-02 | #5 一覧の ± バッジ | 数だけ(`+42 −18`)。`gitdiff.mjs` の cache から同期で返し、裏で cwd ごとに取り直す | `SessionRow.Diff` / `RCChip` の `list.diffBadge` |
| 2026-09-02 | #7 進行中の道具 | 「Working · Bash」。転写の末尾が道具の行ならその名前(机の口は増やさない) | `ConversationViewModel.currentTool` |
| 2026-09-02 | #14-16(読むだけ) | `model · branch` を会話の状態帯の下に 1 行。`digestOf` が最新レコードから拾う | `digest.session` / `conversation.sessionRuntime` |
| 2026-09-02 | #10 `@` 補完 | `GET /api/sessions/:id/paths?q=` で cwd の下を**読むだけ**歩く(前方一致・区切りを跨ぐ / 深さ・件数・時間に上限 / 生成木は除外 / 切ったら `truncated`)。電話は 250ms の debounce で撃ち、押しても**送らない** | `completePaths`(`paths.mjs`) / `PathCompletionClient` / `conversation.pathSuggestion` |
| 2026-09-02 | #4 差分の中身 | `GET /api/sessions/:id/diff` で作業木の未コミット差分を返す(`git diff` 2 本のみ、読むだけ。ファイル単位に畳み、天井 3 つ・切っても数は嘘を吐かない。読めない事は 200 + `reason` で返す)。電話は工具帯の ± から push で開く画面(ファイルごとのカード・`staged` チップ・色付き行・静かな空面) | `readWorkingDiff`(`sessiondiff.mjs`) / `DiffClient` / `SessionDiffBody` / `conversation.diff.open` |

反映していない absent 行は、意匠に触れる物(入力欄の造り)と、机の口を新設する物(行コメント #6 /
subagent の個別停止 #8 / model・effort の**選択** #14-15)。#4 が入ったので #6 の置き場は出来た(未着手)。
★#11(任意のディレクトリで新規)は #10 が入っても**自動では片付かない** —— 補完が歩けるのは
既に在る会話の cwd の下だけで、場所を 0 から選ぶ口は机にまだ無い。「作らないと決めた」ではなく
「まだ作っていない」である事を、`ListView.swift` / `NewSessionClient.swift` / `server.mjs` の註にも書いた。

---

## ★訂正(2026-09-01、この表を出した直後)— 下の「上位5件」のうち2件は**欠陥ではなく裁定**

この表は「実装に無い物」を機械的に集めたが、**無い理由が『まだ作っていない』なのか
『作らないと決めた』なのかを分けていない**。実際に2件を取り違えていたので、読む前に此処を読む事。

| 誤って挙げた物 | 実際は | 正本 |
|---|---|---|
| slash チップを公式の全一覧へ広げる(#13-15、上位5件の1位) | **裁定**。註は★3ブロック在り、引用したのは1つ目だけだった。2つ目 =「押しても**送らない**」は写真添付と同じ規約で意図的、3つ目 =「**出すのは移動中に効く 3 つだけ。一覧にすると探す物になる**」 | `ios/Sources/Screens/Conversation/ConversationView.swift` の slash 註(3ブロック全部) |
| 転写のコード等幅化 / markdown 描画(#40) | **裁定**。検出に Markdown 解釈が要り、v1 は解釈しないと決めてある。覆すなら Tom の裁定が要る(座標側が別途 起票済み・重複禁止) | `ios/Sources/Core/HistoryModels.swift の `HistoryEntry.text` の doc「no Markdown interpretation, no truncation in v1」` — `no Markdown interpretation, no truncation in v1` |

**一般則(この表を使う者への引き継ぎ)**: 「実装に無い」を欠陥として挙げる前に、
**コードの註と決定記録に当たり、裁定として記録されていないかを確かめる**。
註を引く時は**ブロックの途中で切らない** —— 前半だけを引くと、裁定が欠陥に見える。

セッション削除(#27)も表から落とす: **作らない**判断であり、作らない事に許可は要らないので
Tom への Yes/No にはしない(一覧から消す要求は archive が満たしている。転写の実削除は不可逆)。

★**表の中で今も生きている観測**(裁定に当たらず、価値が確認された物):
`TAIL_MAX` は定数を書き換えずとも**呼び出し側の `opts.maxBytes`** で上げられる /
diff の口が `SESSION_ROUTE_RE` に無い / `@` 補完の不在が別機能を止めている。
着手順は Tom の回答後に決まる。

★**2026-09-02 の更新**: `@` 補完(#10)は出荷した。よって「不在が #11 を止めている」は
もう成り立たない —— だが **#11 が自動で片付いた訳ではない**。補完が歩けるのは
**既に在る会話の cwd の下**だけで、任意のディレクトリを 0 から選ぶには机側に別の口が要る
(今の動詞表は会話に紐づく道しか持たない)。#11 の註を「作らないと決めた」に読み替えないよう、
`ListView.swift` / `NewSessionClient.swift` / `server.mjs` の3箇所の註も同日に書き直してある。

## `research/remote-control-teardown.md`(2026-07-31)が既に決着させている事 — 繰り返さない

接続の形(ブローカー中継)/ フル OAuth 必須(= 我々の構成では本家が構造的に使えない)/
会話状態の中央保存 / 起動の3形態 / ~10分でタイムアウトして exit。
**3点だけ本書で更新した**: ①slash は「ほぼ通らない」ではなく通る一覧が公式に確定(#13)、
②遠隔からの subagent 停止は「未確認」→ **在る**(#8)、③diff ビューアは「たぶん同じ、未確認」→
**在る**、v2.1.247 以降は `remote-control` サーバ以外でも(#4)。

---

## 表 A — 機能(capability)

| # | 機能 | 公式に在るか(出典/日付) | RemoteMini の状態 | 根拠(file の目印) | 差の中身 |
|---|---|---|---|---|---|
| 1 | 転写の中を検索する | 不明(モバイル/web の会話内検索の記述を見つけられず。端末の `/` 検索は CLI 機能としてのみ確認) | present | ios/Sources/Core/HistoryClient.swift の `func search` | 2026-09-01 出荷。上限 100 件。走査距離に天井が在る(#2) |
| 2 | 転写の走査距離 | 不明(公式に相当する概念の記述なし) | absent(天井が外せない) | rc-backend/src/listing.mjs の `export const TAIL_MAX` | `TAIL_MAX = 1 MiB`。本番は `opts` を渡さないので既定が効く。最長の会話 280 MB に対し到達率 0.36% |
| 3 | 検索結果から本文のその行へ跳ぶ | 不明 | absent | rc-backend/src/sessions.mjs の `export function searchHistoryFromPath` | 机が一致の位置を返していない。返り値は `history/matched/reachedStart/scanned` のみ |
| 4 | 差分(diff)を電話で読む | **在る**。code.claude.com/docs/en/remote-control(2026-09-01 取得、私が直に確認)「a connected device's diff pane shows the diff of your uncommitted changes」。v2.1.247 以降は `remote-control` サーバ以外でも | absent | rc-backend/src/reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表) | 机の動詞表に `diff` が無い。電話から「何が変わったか」を一切見られない |
| 5 | 一覧に差分の ± バッジ | **在る**。code.claude.com/docs/en/claude-code-on-the-web(2026-09-01)「a diff indicator with lines added and removed, like `+42 -18`」 | absent | ios/Sources/Core/SessionsModels.swift の `struct SessionRow` | `SessionRow` に差分の欄そのものが無い |
| 6 | 差分への行コメント | **在る**。同上「leave inline comments on specific lines, and send them to Claude with your next message」 | absent | rc-backend/src/reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表) | #4 の従属。diff が無いので置き場も無い |
| 7 | 進行中の道具の実行が見える | **在る**。remote-control(同、私が直に確認)「the conversation and the progress of subagents and dynamic workflows stay in sync across all connected devices」。保存される転写は「your messages, Claude's responses, and tool activity」 | absent | ios/Sources/Core/HistoryModels.swift の `struct HistoryEntry` | `HistoryEntry` は `role` / `text` / `display.who` の3つだけ。10 分走っている間 電話には `busy` しか出ない |
| 8 | subagent / workflow を個別に止める | **在る**。同上(私が直に確認)「Stop one of them from the device, and Claude Code stops that task on your machine」 | absent | rc-backend/src/server.mjs の `action === "interrupt"` の分岐 | `interrupt` は Escape を1回送るだけで、単位がセッション全体。個別の停止という概念が無い |
| 9 | 留守中に何が起きたかの要約 | 不明(公式に相当する機能の記述なし。push 通知は近いが要約ではない) | present | rc-backend/src/server.mjs の `action === "digest"` の分岐 | **RemoteMini 固有**。読んだ file と書き換えた file を分けて出す |
| 10 | 入力欄で `@` によるパス補完 | **在る**。remote-control(同、私が直に確認)「typing `@` autocompletes file paths from your local project」(端末 UI か電話 UI かは原文が区別しておらず、そこは不明) | absent | ios/Sources/Screens/List/ListView.swift の 「場所を選ぶ画面は作らない」の註 | **この不在が別の機能を止めている** — 同行の註が「`@` のパス補完がまだ無い以上、電話で path を打たせるのは盲打ち」と書き、ディレクトリ選択画面を作らない理由にしている |
| 11 | 任意のディレクトリで新規セッション | **在る**。code.claude.com/docs/en/whats-new/2026-w34(2026-08-17〜21、v2.1.234→239、私が直に確認)「Tap it to pick a directory and start a session there」 | absent | ios/Sources/Screens/List/ListView.swift の `newSessionStarter.startNear(` | `startNear` = 既存の行の**隣**でしか始まらない。行が1本も無い机では新規に始めようがない |
| 12 | 既存の会話と同じ場所で新規セッション | 不明(公式は「ディレクトリを選ぶ」形なので同型の機能が無い) | present | rc-backend/src/server.mjs の `action === "new"` の分岐 | #11 の代替として置かれている。場所は行から継ぐので選ばせない |
| 13 | slash コマンド | **在る、一覧が公式に確定**。remote-control(同)電話/web で動く = `/compact` `/clear` `/context` `/usage` `/exit` `/usage-credits` `/recap` `/reload-plugins`、引数付きで `/model` `/effort` `/fast` `/color` `/rename`、`/mcp`(v2.1.166〜)`/config`(v2.1.181〜)`/autocompact`(v2.1.221〜)。端末専用 = `/plugin` `/resume` | present(3つのみ) | ios/Sources/Screens/Conversation/ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ | `/compact` `/context` `/model` の3つだけ、しかも**押しても送らない**(文へ差すだけ)。同 file の註が「机の側では既に動く、画面に存在が出ていなかっただけ」と実測付きで明言 = **能力差ではなく露出差** |
| 14 | model を電話から選ぶ | **在る**。remote-control(同)「when you pick a model from a connected device, Claude Code runs the session on that model. The terminal's `/model` picker, `/status`, and `/config` show that model」 | absent | ios/Sources/Screens/Conversation/ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ | `/model` の文字列を差し込むだけ。今どのモデルで走っているかも電話に出ない |
| 15 | effort を電話から選ぶ | **在る**。同上「with `/effort` or the device's effort control… Picking a level from the effort control requires Claude Code v2.1.234 or later」 | absent | ios/Sources/Screens/Conversation/ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ | チップの一覧に `/effort` が無い。移動中に重さを上げ下げできない |
| 16 | permission mode が電話に出る | **在る**。whats-new/2026-w34(同)「Remote Control sessions hosted by Desktop or VS Code also show connected devices the session's current permission mode」 | absent | rc-backend/src/server.mjs の `action === "status"` の分岐 | `status` の応答に現用モードの欄が無い。机が bypass で走っているかを電話から知る手段が無い |
| 17 | permission prompt に電話から答える | **在る**。remote-control(同、私が直に確認)「Claude Code keeps permission prompts and `AskUserQuestion` questions open until you answer them」。端末には「Approve tool calls from your phone」の通知 | absent(設計 D4 による意図的な不採用) | rc-backend/src/choice.mjs の 冒頭の Tom 裁定「自動化に安全確認を押させない」= 設計 D4 | **能力差ではなく裁定差**。「電話から permission 承認は採らない」「hard-stop は電話へ通知のみ・承認ボタン無し」。写すかどうかは Tom の判断 |
| 18 | 選択メニューを電話から押す | 部分的に在る(#17 の一部として) | present(許可一覧に一致した画面のみ) | rc-backend/src/choice.mjs の `export function classifyChoice` | 拒否一覧ではなく**許可一覧**。知らない画面は良性と名乗れないので断る。広げ方は「実物を撮って fixture 化」で、一致条件を緩めるのは禁止 |
| 19 | 走行中に送る(キューに積む) | **在る**。remote-control(同)「when you send a prompt from a connected device before the current turn ends, Claude Code queues it」 | present | ios/Sources/Screens/Conversation/ConversationViewModel.swift の `var composerEnabled` | ほぼ同等。積んだ数と経過時間まで出す分、RemoteMini の方が細かい |
| 20 | 積んだ送信を捨てる | 不明(公式に相当する操作の記述なし) | present | rc-backend/src/server.mjs の `action === "queue"` の DELETE 分岐 | **RemoteMini 固有**。走っている番は止めずに待ち行列だけ捨てる |
| 21 | 下書きの保存 | 不明(公式ドキュメントに記述なし) | present | ios/Sources/Screens/Conversation/ConversationViewModel.swift の `draft` の `didSet { draftStore.save(…) }` | 打鍵ごとに会話単位で保存。公式側の造りが不明なので優劣は判定できない |
| 22 | 写真を添付する | **在る**。code.claude.com/docs/en/mobile(2026-09-01、私が直に確認)「Claude sees attached photos directly as part of your message. Claude Code also saves each photo under `~/.claude/uploads/`」 | present | ios/Sources/Core/AttachClient.swift の `func attach` | 机に置いてパスを文へ差す。Enter は打たない(送るかは人が決める規約) |
| 23 | 画像以外のファイルを添付する | **在る**。同上「Other files: Claude Code downloads them to your machine and passes them to Claude as `@` file references」 | absent | ios/Sources/Screens/Conversation/ConversationView.swift の `PhotosPicker(selection: $pickedPhoto, matching: .images, …)` | `PhotosPicker(matching: .images)` = 画像のみ。ログ・PDF・csv を移動中に投げられない |
| 24 | 一覧の検索・絞り込み | 不明(archived の絞り込みのみ確認。grouping / 検索窓の記述は見つからず) | absent | ios/Sources/Screens/List/ListView.swift の `.refreshable { await viewModel.refresh() }` | `.refreshable` は在るが `.searchable` が無い。実測 41 本を目視で探す |
| 25 | セッションの改名 | **在る**。remote-control(同)「When you rename a session from claude.ai or the Claude app, Claude Code also updates the local title」 | present | rc-backend/src/server.mjs の `action === "title"` の分岐 | 同等。長押しと確認ダイアログから |
| 26 | セッションの保管(archive)と復帰 | **在る**。claude-code-on-the-web(同)「hover over the session in the sidebar and select the archive icon」 | present | rc-backend/src/server.mjs の `action === "archive"` の分岐 | 同等。スワイプと長押しの両方に口が在る |
| 27 | セッションの削除 | **在る**。同上「Deleting a session permanently removes the session and its data. This action can't be undone」 | absent | ios/Sources/Screens/Settings/SettingsView.swift の `Text("Sessions removed from the list. Their records stay on the desk…")` | 「Their records stay on the desk and can be restored anytime」= 記録は消えない。Tom 逐語 §9-1 の要求が archive で満たされているかは未確認 |
| 28 | セッションの fork / branch | 不明(端末の `--fork-session` / `/fork` は確認。モバイルから可能かの記述は見つからず) | absent | rc-backend/src/reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表) | 動詞表に fork が無い。ただし公式の電話側の裏が取れていないので写す根拠が弱い |
| 29 | アカウント切替 | 不明(Code タブ内の切替を述べた公式ドキュメントを見つけられず。mobile は「Sign in with the same claude.ai account and organization」とだけ。v2.1.234 の changelog はむしろ「別アカウントへのサインインで走行中セッションが止まる」) | present | rc-backend/src/server.mjs の `/api/account/next` の POST 分岐 | **RemoteMini 優位**。Tom の必須要件(2026-07-28 逐語)に対し、公式に同等物を確認できない。2タップ |
| 30 | 使用量の表示 | **在る**(`/usage` が電話/web で動く。remote-control の一覧) | present | rc-backend/src/usage.mjs の `export function parseCswapUsage` | 設定画面に常設。読めなかった時に 0 へ丸めない |
| 31 | 通知を押して会話へ着地する | **在る**。remote-control(同)「Claude decides when to push… when a long-running task finishes or when it needs a decision from you」 | present | ios/Sources/Core/DeepLink.swift の `handle(_:)`(外から来た URL を受ける唯一の口) | ntfy + `remotemini://session/<id>`。★**鎖の最後が Tom ゲート** = iPhone で topic を購読する事。未了なら届かない |
| 32 | 通知の種別トグル | **在る**。同上 `/config` に2つ = **Push when Claude decides** / **Push when actions required** | absent | ios/Sources/Core/DeepLink.swift の `handle(_:)`(外から来た URL を受ける唯一の口) | 種別が1つしかない。「判断待ち」と「完了」を分けられない |
| 33 | 切断中の欠落を告げて埋める | **在る**。同上「While the connection is rebuilding, Claude Code queues messages, permission prompts, and status updates… and delivers them once the connection recovers」 | present | ios/Sources/Core/MergeHistory.swift の `static func merge` | 同等。公式はサーバモードが約10分で exit するが、こちらは死なない |
| 34 | 机へ届かない事の表示 | 不明(公式ドキュメントに UI の記述なし) | present | ios/Sources/Screens/Shared/UnreachableBanner.swift の `struct UnreachableBanner` | 連続失敗数を出す。公式側の造りが不明なので優劣は判定できない |
| 35 | 長く待っている事の段階表示 | **在る**(端末側)。remote-control(同)「Claude Code shows a **Still working** notification with a **Check in from your phone** link」 | present | ios/Sources/Core/WaitEscalation.swift の `static func stage(elapsedSeconds:)` | **RemoteMini は電話側に出す**。公式のそれは端末側の帯 |
| 36 | 背面から前面へ戻った時の再開 | 不明(公式ドキュメントに記述なし) | present | ios/Sources/Screens/Shared/ForegroundResume.swift の `mutating func shouldResume(newPhase:)` | `ScenePhase` で引き直す。公式側の造りが不明 |
| 37 | 机のプロセスが死んだ時の扱い | 公式は**生存必須**。remote-control(同)「If you close the terminal, quit VS Code, or otherwise stop the `claude` process, the session goes offline」 | present(優位) | rc-backend/src/server.mjs の `/healthz` の分岐 | **RemoteMini 優位**。tmux 常駐なのでアプリを閉じても端末を閉じても走り続ける。公式の一番痛い制約をこちらは持たない |
| 38 | 作業を MacBook へ戻す | 不明(該当機能なし。`--teleport` は cloud→local で別物) | present | rc-backend/src/server.mjs の `action === "return-request"` の分岐 | **RemoteMini 固有**。予約だけ入れ、安全確認が通ってから戻る |
| 39 | 新しい版が出た事の告知 | App Store が担う(公式アプリなので該当機能を持たない) | present | rc-backend/src/ota-published.mjs の `export function publishedBuild` | **RemoteMini 固有**。自作ゆえに必要。配っている実物の manifest を読む(承認記録ではなく) |

## 表 B — 意匠(polish)

機能面より下に置く。**Tom は機能面を重く見ると明言**しており、混ぜると表が使えなくなる。

| # | 機能 | 公式に在るか(出典/日付) | RemoteMini の状態 | 根拠(file の目印) | 差の中身 |
|---|---|---|---|---|---|
| 40 | 転写の markdown 描画 | **在る**。whats-new/2026-w34(2026-08-17〜21)「Your own prompts now render markdown in the transcript, with highlighted code blocks, inline code, and lists」 | absent | ios/Sources/Screens/Conversation/ConversationView.swift の `EntryBubble` が描く `Text(entry.text)`(素の Text = markdown を解釈しない) | 素の `Text`。コードブロックも箇条書きも平文で流れる |
| 41 | 道具出力の折り畳み | 不明(公式ドキュメントに記述なし) | absent | ios/Sources/Screens/Conversation/ConversationView.swift の `EntryBubble` が描く `Text(entry.text)`(素の Text = markdown を解釈しない) | #7 の従属。そもそも道具出力が転写に入っていない |
| 42 | 検索の一致箇所ハイライト | 不明 | absent | ios/Sources/Core/HistoryClient.swift の `func search` | 100 件の結果を目で追う事になる |
| 43 | キーボード上の道具列 | 不明(公式の composer の造りは記述が無い) | absent | ios/Sources/Screens/Conversation/ConversationView.swift の `TextField("Message", text: $viewModel.draft, axis: .vertical)` | `.toolbar(.keyboard)` を持たない。カーソル移動や記号入力の補助が無い |
| 44 | 入力欄が行数で伸びる | 不明 | present | ios/Sources/Screens/Conversation/ConversationView.swift の `TextField("Message", text: $viewModel.draft, axis: .vertical)` | `axis:.vertical` + `.lineLimit(1...5)`。5 行で頭打ち |
| 45 | 話者の表示 | 不明 | present | ios/Sources/Screens/Conversation/ConversationView.swift の `EntryBubble` が描く `Text(entry.display.who)` | `display.who` を机が決めて電話は描くだけ(文言を電話側で作らない規約) |

---

## ★ 測れなかった事 — Tom の一番の不満に対して

Tom の「**入力の UI が全然似ていないかも**」について、**公式側の composer の造りを一次資料で確定できなかった**。
voice 入力 / 下書き保存 / キーボードツールバー / 複数行の扱い、いずれも `code.claude.com/docs/en/mobile` と
`/docs/en/remote-control` の全文に記述が無い。

いま言えるのは **機能の差**(#10 `@` 補完・#13 slash・#14/#15 model と effort・#23 添付)までで、
**見た目の差は1つも測っていない**。表 B の「不明」が4つ並んでいるのはそのため。
推測で写すと的を外すので、実物を見るまで埋めない。

**[UNVERIFIED]**(第三者・未検証): `github.com/anthropics/claude-code` の issue に、モバイルからの画像添付が
動かないという報告が複数(#65868 は「the mobile Claude Code chat input currently has no attach / image button」
として duplicate クローズ、他に #65601 / #62031 / #57882 / #53596 / #42156)。**公式ドキュメントの記述と
食い違う**ので、#22・#23 を写す時は「公式に文書化されている ≠ 実際に動く」を前提にする。

---

## 今日から着手できる上位5件

| 順 | やる事 | 最初に触る file | なぜこれが先か |
|---|---|---|---|
| **1** | ~~**slash チップを公式の一覧に合わせ、送信まで行かせる**(#13 / #14 / #15)~~ **★却下 — 上の「訂正」の表に在る裁定(3 つだけ / 押しても送らない)。此の行は訂正前の記述のまま残っていて、2026-09-02 に此処からレーンを 1 本 誤配した。着手するな** | `ios/Sources/Screens/Conversation/ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ` — 配列 `["/compact","/context","/model"]` | 費用が最小で効果が確実。**能力は既に机に在り、画面に出ていないだけ**だと同行の註が実測付きで明言している。机に一切触らない。`/effort` `/clear` `/context` `/usage` を足し、`/model` `/effort` は引数まで入れたチップにする |
| **2** | **permission mode を `status` に載せて帯に出す**(#16) | `rc-backend/src/server.mjs の `action === "status"` の分岐` — `action === "status"` の分岐 | 読むだけなので設計 D4(#17)の裁定に触れない。机が bypass で走っているかを電話から知る手段が今は無い。1 往復で入る |
| **3** | **diff の口を机に開ける**(#4 → #5 → #6) | `rc-backend/src/reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表)` — `SESSION_ROUTE_RE` に `diff` を追加 | 一番大きい穴。**まず「ファイル名と ± の数」だけ**返す版で価値の大半が出る。cwd は登録簿が既に持っている(`rc-backend/src/listing.mjs`)。#5 のバッジはその副産物 |
| **4** | **ntfy の購読が生きているか測る**(#31 / #32) | `ios/Sources/Core/DeepLink.swift の `handle(_:)`(外から来た URL を受ける唯一の口)` — `handle(_:)` が受ける側、机側は `Notification` hook | 実装ではなく**測定**。ここが死んでいると #1〜#3 が全部「開いた時だけ効く機能」に落ちる。鎖の最後の1段が Tom ゲート(iPhone で topic を購読)なので、生死を先に確定する |
| **5** | **転写の走査距離を上げる**(#2) | `rc-backend/src/listing.mjs の `export const TAIL_MAX`` — `TAIL_MAX = 1024 * 1024` | 出荷したばかりの検索(#1)の実用性を**単独で最も左右する変数**。本番は `opts` を渡さないのでこの既定がそのまま効いており、280 MB の会話に対し到達率 0.36%。`scanned` を画面の線に載せるところまで含めて別 spec |

### Tom に1つだけ確認したい事(Yes/No)

**セッションの「削除」(#27)は要りますか? はい / いいえ**
(推奨: **いいえ** — 逐語 §9-1「いらないセッションを選択して消去できない」は
一覧から消える事を指しており、それは archive が既に満たしている。転写の実削除は不可逆)
