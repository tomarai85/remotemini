# 機能差分の棚卸し — 公式 Remote Control / Claude iOS "Code" タブ 対 RemoteMini

作成 2026-09-01。**Tom は「Native のは使わない」と裁定済み**(`requirements-mining.md` §1)。
よってこれは採否の比較ではなく、**写す先の目録**である。並びは「Tom の一日がどれだけ変わるか」。

- 公式側の事実 = 2026-09-01 に取得。全行に出典 URL と、それを支える**原文の一文**を置いた。
  裏が取れなかった項目は推測せず **不明** と書き、何を探したかを §6 に列挙した。
- RemoteMini 側の事実 = **コードから**。ドキュメントの記述は根拠に使っていない(`file:行` で示す)。
- 委譲した取得の結果を鵜呑みにしていない。**最も判断を左右する 5 件**(diff 面 / 承認プロンプト /
  subagent 停止 / `@` 補完 / ディレクトリ選択)は私自身が `code.claude.com` を取り直して原文を確認した。

---

## 1. `remote-control-teardown.md`(2026-07-31)が既に決着させている事 — ここでは繰り返さない

あの文書は**アーキテクチャ**の解剖であって、機能の目録ではない。既に決着している事:

| 論点 | teardown の結論 | 本書での扱い |
|---|---|---|
| 接続の形 | ローカルからの outbound のみ、Anthropic がブローカー、TLS + 短寿命クレデンシャル群 | 再論しない。Tailscale で解決済み |
| 認証 | フル OAuth 必須、API キー・長寿命トークンは明示的に拒否 → **edith/Friday の構成では本家が構造的に使えない** | 再論しない。「なぜ真似て作るか」の回答は済んでいる |
| 会話状態の置き場 | Anthropic サーバに保存(再接続と複数デバイス同期の担保) | 再論しない。我々は机自身が兼ねる |
| 起動の3形態・CLI フラグ | `remote-control` / `--rc` / セッション内 `/remote-control` | 再論しない |
| ~10 分でタイムアウトして exit | 公式明記 | 再論しない |
| slash の大半が通らない | 「ほぼ通らない」と要約 | **本書で更新する** — 現在は通る一覧が公式に列挙されており、teardown の要約より広い(§3 F5) |
| 遠隔からの割り込み/stop | 「未確認」 | **本書で決着** — subagent/workflow は端末から止められる(§3 F2) |
| diff ビューアが RC の会話面にも在るか | 「たぶん同じ、未確認」 | **本書で決着** — 在る。v2.1.247 以降は `remote-control` サーバ以外でも(§3 F1) |
| permission 承認の button ラベル | 「未確認」 | ラベルは今も **不明**。ただし「答えるまで開いたままにする」は確認できた(§3 F4) |

---

## 2. RemoteMini が今日 実際に持っている面(コードから)

### 机(`rc-backend`)の口 — これが能力の上限

`reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表)` の正規表現が全てを決めている。ここに無い動詞は電話から呼べない。

```
GET  /healthz                       server.mjs の `/healthz` の分岐
GET  /api/sessions                  server.mjs の `/api/sessions` の GET 分岐   一覧 + 机の scan + 更新通知 + paneFault
GET  /api/account                   server.mjs の `/api/account` の GET 分岐   現用アカウント + 順位 + 使用量
POST /api/account/select            server.mjs の `/api/account/select` の POST 分岐
POST /api/account/next              server.mjs の `/api/account/next` の POST 分岐
/api/sessions/<id>/{ history | messages | stream | poll | interrupt |
                     status | choice | queue | title | archive |
                     return-request | digest | attach }        reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表)
```

動詞ごとの実体:

| 口 | できる事 | できない事 |
|---|---|---|
| `history` GET | 転写を末尾から `limit`(最大500)。`q=` で検索(2026-09-01 新規) | 位置を返さない = 跳べない。走査は**末尾 1 MiB のみ** |
| `messages` POST | tmux の pane に本文を打って Enter | 添付の同時送信は無い(パスを差すだけ) |
| `poll` / `stream` | 画面の分類(`sendable`/`busy`/`choice`/`unknown`)+ 選択カード + 待ち行列数 | 道具の実行内容は載らない |
| `interrupt` POST | **Escape だけ**。C-c は送らない。止まった事を観測してから `interrupted:true` | プロセスの kill は無い |
| `choice` POST | **許可一覧**に一致した良性メニューだけ押す | 未知の画面は必ず断る(`choice.mjs` 冒頭、設計 D4) |
| `attach` POST | 写真を机に置き、パスを文へ差す | Enter は打たない。画像以外は口が無い |
| `title` / `archive` | 改名 / 一覧から外す | **削除は無い**(記録は机に残る) |
| `return-request` | 持ち出したセッションを MacBook へ戻す予約 | — |
| `digest` GET | 留守中に何が起きたかを1画面に畳む | — |

### 電話(`ios/Sources`)の面

画面は5枚 — `List` / `Conversation` / `KeyEntry` / `Settings` / `ArchivedList`。
`accessibilityIdentifier` は 108 個(一意)。入力まわりの実体だけ抜くと:

| 部品 | 実装 | 制限 |
|---|---|---|
| 入力欄 | `TextField(axis:.vertical)` + `.lineLimit(1...5)` | `ConversationView.swift の `TextField("Message", text: $viewModel.draft, axis: .vertical)`` |
| 下書きの保存 | 打鍵ごとに `UserDefaults` へ、会話ごと | `ConversationViewModel.swift の `draft` の `didSet { draftStore.save(…) }`` |
| 走行中の送信 | **できる**(机が次ターンとして扱う)。待ち行列の帯と経過時間が出る | `ConversationViewModel.swift の `var composerEnabled`` |
| 添付 | `PhotosPicker(matching: .images)` | `ConversationView.swift の `PhotosPicker(selection: $pickedPhoto, matching: .images, …)`` — 画像のみ |
| slash | `/compact` `/context` `/model` の3チップ。**押しても送らない**、文へ差すだけ | `ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ` |
| 割り込み | `stop.circle`。机が動いていると判った時だけ濃く描く | `ConversationView.swift の `Task { await viewModel.interrupt() }` の割り込みボタン` |
| 転写内検索 | `.searchable` + 結果面を overlay。上限 100 件 | `ConversationView` / 2026-09-01 出荷 |
| 一覧の操作 | 長押し = Rename / Archive / New session here /(持ち出し中のみ)Return。左右スワイプ = Return / Archive | `ListView.swift の 行の `.contextMenu`-403` |
| アカウント | 現用の表示 + `Next account`(2タップ) | `SettingsView.swift の `Text("Next account")``、机の `fleet-account` を叩く |

会話の1項目が持つ情報は **`role` / `text` / `display.who` の3つだけ**(`HistoryModels.swift の `struct HistoryEntry`-135`)。
道具の呼び出しも、思考も、添付も、構造としては存在しない。ここが §3 の F1・F2 の根である。

---

## 3. 差分表 — 機能(capability)

採点 = **価値**(Tom の一日がどれだけ変わるか)× **確度**(公式の記述の確かさ × 効果の読みの確かさ)÷ **費用**(実装量)。
すべて 1–5。値が大きいほど先。

| # | 機能 | 公式に在るか(出典 / 取得日) | RemoteMini に在るか(根拠) | 差の中身 | 電話だけ / 机も要る | 実装の当たり | 価 × 確 ÷ 費 |
|---|---|---|---|---|---|---|---|
| **F1** | **差分(diff)を電話で読む** | **在る**。`code.claude.com/docs/en/remote-control` 2026-09-01(私が直に確認)—「when the session's directory is in a git repository, a connected device's **diff pane** shows the diff of your uncommitted changes… Before v2.1.247, Claude Code reported the diff to connected devices only in sessions served by `claude remote-control`.」作業樹が綺麗なら「your branch's changes since it diverged from the default branch」。claude.ai/code 側は `+42 -18` の印と**行コメント**も(`/docs/en/claude-code-on-the-web`) | **無い**。`reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表)` の動詞表に `diff` が無く、`HistoryEntry` は本文の文字列しか持たない(`HistoryModels.swift の `struct HistoryEntry``) | 一番大きい穴。`measured-plan` の実測「iPhone 縦は34字で折れる/差分は横画面必須」は**生ターミナルの40桁の話**で、構造化した diff 面はその制約ごと消す。今は「何が変わったか」を電話から一切見られない | **机も要る**(机で `diff` を計算して返す) | `SESSION_ROUTE_RE` に `diff` を足す。cwd は登録簿が既に持っている(`listing.mjs`)。`git -C <cwd> diff --numstat` + patch を JSON 化 → 電話に新しい画面。まず**ファイル名と ± の数だけ**の版で価値の大半が出る | 5×5÷3 = **8.3** |
| **F2** | **道具の実行が進行中に見える** | **在る**。同上 —「the conversation and the progress of **subagents** and **dynamic workflows** stay in sync across all connected devices」/「the device shows any subagents and workflows the session already has running in the background. **Stop one of them from the device**, and Claude Code stops that task on your machine.」/ 保存される転写は「your messages, Claude's responses, and **tool activity**」。v2.1.251(2026-08-28)で前景 subagent の道具呼び出しの実時間配信を追加 | **無い(進行中は)**。`poll` が返すのは画面の分類 4 種だけ(`PollModels.swift`)。**留守中については解けている** — `digest.mjs` が転写 JSONL を読んで「読んだ file / 書き換えた file / 使った道具」を出す | 10 分走っている間、電話には `busy` しか出ない。何を触っているか、暴走していないかが判らない。止める判断の材料が無い | **机も要る** | `digest.mjs` の解析器を**「直近 N 秒」窓**で `poll` の応答に載せる。読む対象も分類器も既に在るので、窓を変えるだけ。停止側は既存の `interrupt`(Escape)で足りる | 5×5÷3 = **8.3** |
| **F3** | **入力欄で `@` によるパス補完** | **在る**。同上 —「typing `@` autocompletes file paths from your local project」(端末側 UI か電話側 UI かは原文では区別されていない = そこは**不明**) | **無い**。しかも**この不在が別の機能を止めている**: `ListView.swift の 「場所を選ぶ画面は作らない」の註` の註が「`@` のパス補完がまだ無い以上、電話で path を打たせるのは盲打ちを強いる」と書いて、ディレクトリ選択の画面を作らない理由にしている | 電話でパスを打つのは実質不可能(40桁・IME・打鍵コスト)。実セッションの絶対パス密度は 51MB で 6,868 回(`measured-plan` §1-5)= 会話の主語がパスなのに、電話からはその主語を打てない | **机も要る** | 机に `GET /api/sessions/<id>/paths?q=` を新設し、登録簿が持つ cwd の下を `fd`/`ls` で引く。電話は composer の上に候補の行を出し、押したら差し込む(slash チップと同じ規約 = 送らない) | 5×5÷3 = **8.3** |
| **F5** | **slash コマンドを実際に送れる形にする** | **在る、しかも一覧が公式に確定している**。同上 — 電話/web で動く: `/compact` `/clear` `/context` `/usage` `/exit` `/usage-credits` `/recap` `/reload-plugins`、引数付きで `/model` `/effort` `/fast` `/color` `/rename`、`/mcp`(v2.1.166〜)`/config`(v2.1.181〜)`/autocompact`(v2.1.221〜)。**端末専用**は `/plugin` `/resume` | **3つだけ、かつ送らない**。`/compact` `/context` `/model` を**文へ差し込むだけ**(`ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ`)。同 file の註が明言 —「机の側では既に動く。机の拒否規則(`deny.mjs`)も先頭の `/` を弾かない事を実測した。つまり能力は前から在って、画面に存在が出ていなかっただけ」 | **能力差ではなく露出差**。一番安く一番効く行 | **電話だけ** | 配列 `["/compact","/context","/model"]` を公式の一覧に合わせて増やす。`/model` `/effort` は引数まで入れたチップにする。1 file・数行 | 4×5÷1 = **20.0** |
| **F4** | **承認・質問に電話から答える** | **在る**。同上 —「Claude Code keeps **permission prompts** and **`AskUserQuestion`** questions open **until you answer them**」(他種の dialog は既定5分で `dialogExpiry`)。端末には「**Approve tool calls from your phone**」の通知が出る。mode は `/docs/en/mobile` 2026-09-01(私が直に確認)—「Remote Control sessions offer Manual, Accept edits, and Plan. You can't select Bypass permissions from the app」 | **設計で断っている**。`choice.mjs` 冒頭 = 設計 D4「電話から permission 承認は採らない」「hard-stop は電話へ通知のみ・承認ボタン無し」。**許可一覧**に一致した良性メニューだけ押せる(`conversation.choiceButton`) | **能力差ではなく裁定差**。写すかどうかは Tom の判断。価値は割り引く必要がある — 机の設定では permission prompt はほぼ出ない(`measured-plan` §1-2)。効くのは `AskUserQuestion` と選択メニューの側で、そこは既に一部通っている | **机も要る**(許可一覧の拡張) | 設計を覆さずに効く道 = **許可一覧を実物の画面で広げる**(撮って fixture 化 → matcher 追加)。`choice.mjs` の註が広げ方の手順を明記している。「一致条件を緩めて増やす」は禁じられている | 5×3÷4 = **3.8**(裁定待ち) |
| **F6** | **model / effort を電話から選ぶ** | **在る**。同上 —「when you pick a model from a connected device, Claude Code runs the session on that model. The terminal's `/model` picker, `/status`, and `/config` show that model」/ effort は「the device's effort control」で、v2.1.234 以降 | **無い**。`/model` の**文字列を差し込む**だけ。今どのモデル・どの effort で走っているかも電話に出ない | 移動中に「重い問いだから Opus に上げる / 軽いから下げる」が出来ない。現用モデルが判らないのはコスト面の盲点でもある | **電話だけ**(送信は既存の `messages` で足りる) | `/model sonnet` `/effort high` まで含めたチップにし、**送信まで行く**(現行は差すだけ)。現用の表示は `poll` が既に読んでいる statusline から抜く(`tools/hint-statusline-control.mjs`) | 4×5÷2 = **10.0** |
| **F7** | **任意のディレクトリで新規セッション** | **在る**。`code.claude.com/docs/en/whats-new/2026-w34`(2026-08-17〜21、v2.1.234→239。私が直に確認)—「Any machine running `claude remote-control` now shows up as a **device card** at the top of the Code tab」「**Tap it to pick a directory and start a session there.**」 | **部分的**。`New session here` は**既存の行の隣**でしか始められない(`ListView.swift の `newSessionStarter.startNear(``)。行が1本も無い机では新規に始めようがない | 「移動中に思い付いた別件を始める」が出来ない。ただし F3(パス補完)を解かないと電話でのパス入力が盲打ちになる = **F3 の従属** | **机も要る** | F3 の `paths` 口に相乗り。一覧の上に机のカードを置き、押すとディレクトリを選ばせて `new` を撃つ。`NewSessionClient` は既に在る | 4×5÷3 = **6.7** |
| **F9** | **通知の粒度 —— と、鎖の最後が止まっている件** | **在る**。同上 —「Claude decides when to push. It typically sends one when a long-running task finishes or when it needs a decision」。`/config` に2トグル(**Push when Claude decides** / **Push when actions required**)。端末で打鍵中は抑制、`CLAUDE_CLIENT_PRESENCE_FILE` で拡張可 | **在るが細かさが無い**。ntfy + `remotemini://session/<id>`(`DeepLink.swift の `handle(_:)`(外から来た URL を受ける唯一の口)`)。トグル無し。在席中の抑制は入っている(`cf41905`)。★**鎖の最後が Tom ゲート** — iPhone で ntfy の topic を購読する事(`REQUIREMENTS.md` §5-4)。未了なら上の全部が届かない | 「気付く」の層。ここが死んでいると F1〜F7 が全部「開いた時だけ効く機能」に落ちる | **両方**(机の hook + 電話の購読) | **最初にやるのは実装ではなく測定** — 購読が生きているか。生きていれば、机の `Notification` hook を2種(判断待ち / 完了)に割って topic を分ける = ntfy 側でトグルになる | 4×5÷2 = **10.0** |
| **F10** | **permission mode が電話に出る** | **在る**。w34 「Remote Control sessions hosted by Desktop or VS Code also show connected devices the session's **current permission mode**」(v2.1.234) | **無い** | 机が bypass で走っているかを電話から知る手段が無い。**読むだけ**なので D4 の裁定に触れない | **机も要る**(読み取りのみ) | `status` の応答に現用の permission mode を1つ足し、会話の帯に出す。既存の帯の枠(`standingStatusSlot`)に入る | 3×5÷1 = **15.0** |
| **F8** | **一覧の検索・絞り込み** | **不明**。`claude-code-on-the-web` に在るのは「filtering for **archived** sessions」だけ。grouping / 検索窓の記述は見つからなかった | **無い**。`GET /api/sessions` は実測 41 本を返す(`REQUIREMENTS.md` §5-6) | 41 行から目的の会話を探すのが目視。**公式にも無いらしい**ので「写す」ではなく「先に作る」側 | **電話だけ** | `ListView` に `.searchable` を足す。会話内検索で通ったのと同じ型(`ConversationView` 2026-09-01)。机は要らない | 4×2÷2 = **4.0** |
| **F11** | **添付が写真だけ** | **在る**。`/docs/en/mobile` 2026-09-01(私が直に確認)—「**Photos**: Claude sees attached photos directly as part of your message. Claude Code also saves each photo under `~/.claude/uploads/` and tells Claude the saved file path」「**Other files**: Claude Code downloads them to your machine and passes them to Claude as `@` file references」。カメラ撮影とライブラリの区別は**不明**。★[UNVERIFIED, github.com] 添付が壊れているという利用者の報告が複数(#65868 等) | **画像のみ**。`PhotosPicker(matching: .images)`(`ConversationView.swift の `PhotosPicker(selection: $pickedPhoto, matching: .images, …)``)。カメラ・Files・貼り付けの口は無い | ログ/PDF/csv を移動中に投げられない | **両方**(机の受けは bytes なので軽い) | `.fileImporter` を並べる。`attach.mjs` は bytes を受けるだけなので、拡張子の白名簿を広げれば通る | 3×5÷2 = **7.5** |
| **F13** | **転写内検索の到達距離** | **不明**。端末の `/` 検索は CLI 機能としてのみ確認。モバイル/web の会話内検索の記述は見つからなかった | **在るが浅い**。2026-09-01 出荷。走査は**末尾 1 MiB のみ**。同 repo で最長の会話は 280MB = 最悪の到達率 **0.36%**(`.harness/progress-2026-09-01-transcript-search.md`) | 出荷した本人が「この機能の実用性を最も左右する変数はここ」と書いている。**公式との差ではなく自分の穴** | **机も要る** | `maxBytes` を上げ、`scanned` を線に載せる。本人が別 spec と明記済み | 3×5÷3 = **5.0** |
| **F12** | **セッションを消す** | **在る(web)**。`claude-code-on-the-web` —「Deleting a session permanently removes the session and its data. This action can't be undone」 | **archive のみ**。`SettingsView.swift の `Text("Sessions removed from the list. Their records stay on the desk…")`` —「Their records stay on the desk and can be restored anytime」 | Tom 逐語 §9-1「いらないセッションを選択して消去することのできない問題」。**ただし逐語は「一覧から消す」で、archive が既にそれを満たしている可能性が高い**。転写の実削除は不可逆で、要求されているかが確かでない | **机も要る** | 作る前に **Yes/No を1つ聞く**(§5 に置いた)。実装するなら `archive` の隣に `delete`、二段確認 | 3×3÷2 = **4.5** |
| **F14** | **検索結果から転写のその行へ跳ぶ** | **不明** | **無い**。机が位置を返していないため。面の脚に理由を1行出している | 見つけた後、文脈が読めない | **机も要る** | `searchHistoryFromPath` に索引位置を返させ、`history` の窓をその位置に合わせて開く | 2×5÷2 = **5.0** |
| **F15** | **セッションの fork / branch** | **端末では在る**(`--fork-session` / `/fork`)。**モバイルから可能かは不明** | **無い** | 「今の会話を壊さずに試す」が電話から出来ない | **机も要る** | `--fork-session` を worker に渡す口。ただし公式の電話側の裏が取れていないので、写す根拠が弱い | 2×2÷4 = **1.0** |

### 差が **無い / RemoteMini が上** の行(写す必要が無い事を確定させる為に載せる)

| # | 機能 | 公式 | RemoteMini | 判定 |
|---|---|---|---|---|
| **F16** | 切断と再接続 | 「While the connection is rebuilding, Claude Code **queues** messages, permission prompts, and status updates… and delivers them once the connection recovers」。サーバモードは約10分で諦めて **exit** | `PollCursor` + `MergeHistory` + 欠落の告知(`conversation.gapNotice`)+ 待ち行列の帯と経過時間 + `UnreachableBanner` + `ReachabilityMeter` | **ほぼ同等。上限は RemoteMini が上**(10分で死なない) |
| **F17** | 背面・長時間 | 「**Local process must keep running**… If you close the terminal, quit VS Code, or otherwise stop the `claude` process, the session goes offline」 | 机の tmux 常駐なので、**アプリを閉じても端末を閉じても走り続ける** | **RemoteMini 優位**。公式の一番痛い制約をこちらは持たない |
| **F18** | アカウント切替 | Code タブ内の切替は **不明**(公式ドキュメントに記述を見つけられず)。むしろ v2.1.234 の changelog は「signing this computer in to a **different** claude.ai account or organization now **stops** the running session」 | 電話から机の OAuth を切り替える(`AccountBar` + `Settings`、2タップ。`fleet-account` を叩く) | **RemoteMini 優位**。Tom の必須要件(2026-07-28 逐語「CodexBar と同じように」)に対し、**公式に同等物が確認できない** |
| **F19** | 留守中ダイジェスト | 該当機能の記述なし(push 通知が近いが要約ではない) | `digest.mjs` — 何が起きたか・読んだ file と書き換えた file・今 人を待っているか(読めなければ `unknown`) | **RemoteMini 固有** |
| **F20** | MacBook へ戻す | 該当なし(`--teleport` は cloud→local で別物) | `return-request` + 一覧の左スワイプ | **RemoteMini 固有** |
| **F21** | 配布と更新の告知 | App Store | `ota-published.mjs` + 一覧の更新帯 + 後で(snooze) | **RemoteMini 固有**(自作ゆえに必要な機能) |

---

## 4. 差分表 — 意匠(polish)

機能面より下に置く。**Tom は機能面を重く見ると明言**しており、混ぜると表が使えなくなる。

| # | 意匠 | 公式 | RemoteMini | 差の中身 | 費用 |
|---|---|---|---|---|---|
| **P1** | 転写の markdown 描画 | w34「Your own prompts now **render markdown** in the transcript, with highlighted code blocks, inline code, and lists, the same way replies do」 | 素の `Text`。コードブロックも箇条書きも平文 | 電話でコードを読む時に一番効く。**F1(diff)が入るなら同時にやる** | 2 |
| **P2** | 道具出力の折り畳み | **不明**(公式の記述を見つけられず) | そもそも道具出力が転写に無い(F2) | F2 の従属 | — |
| **P3** | 検索の一致箇所ハイライト | **不明** | 無い(出荷時に範囲外と明記) | 100 件の結果を目で追う事になる | 1 |
| **P4** | 入力欄の高さとキーボード上の道具列 | **不明**(公式の composer の造りは記述が無い) | `1...5` 行で伸びる。キーボード上のツールバーは無い | 長文を書く時に窮屈。ただし**公式の造りが不明なので「似ていない」の中身を測れていない** | 2 |
| **P5** | 一覧の情報密度 | device カード + 計算機アイコン + 緑の点 + `+42 -18` の印 | カード + 経路ラベル + 机/持ち出しの印 + 更新時刻 | 差分の印(`+42 -18`)が無い = F1 の副産物として付いてくる | 1 |
| **P6** | 送信中・待機中の文言 | 「**Still working**」+「**Check in from your phone**」(端末側) | `sendInFlightNotice` / `queueStrip` / `WaitEscalation` — 既に厚い | **RemoteMini の方が細かい**。写す物は無い | — |

★ Tom の「入力の UI が全然似ていない」については、**公式側の composer の造りを一次資料で確定できなかった**
(voice / draft 保存 / キーボードツールバー / 複数行の扱い、いずれも記述無し)。
今この表で言えるのは **機能の差(F3 `@` 補完・F5 slash・F6 model/effort・F11 添付)** までで、
見た目の差は測っていない。測るには実物の画面が要る = §5 の 5 番目。

---

## 5. 今日から着手できる上位5件

| 順 | やる事 | 最初に触る file | なぜこれが先か |
|---|---|---|---|
| **1** | **slash チップを公式の一覧に合わせ、送信まで行かせる**(F5 + F6) | `ios/Sources/Screens/Conversation/ConversationView.swift の `ForEach(["/compact", "/context", "/model"])` の slash チップ`(配列 `["/compact","/context","/model"]`) | 費用が最小で効果が確実。**能力は既に机に在り、画面に出ていないだけ**だと同 file の註が実測付きで明言している。机に一切触らない |
| **2** | **permission mode を `status` に載せて帯に出す**(F10) | `rc-backend/src/server.mjs の `action === "status"` の分岐`(`action === "status"`) | 読むだけなので D4 の裁定に触れない。机が bypass で走っているかを電話から知る手段が今は無い。1 往復で入る |
| **3** | **diff の口を机に開ける**(F1) | `rc-backend/src/reqlog.mjs の `export const SESSION_ROUTE_RE`(動詞表)`(`SESSION_ROUTE_RE` に `diff` を追加) | 一番大きい穴。**まず「ファイル名と ± の数」だけ**返す版で価値の大半が出る。cwd は登録簿が既に持っている |
| **4** | **ntfy の購読が生きているか測る**(F9) | 机側 `~/.claude/settings.json` の `Notification` hook →`~/fleet-tools/ntfy-notify.sh` | 実装ではなく**測定**。ここが死んでいると F1〜F7 が全部「開いた時だけ効く機能」に落ちる。鎖の最後の1段が Tom ゲート(iPhone で topic を購読)なので、生死を先に確定する |
| **5** | **公式アプリの composer を実際に見て、意匠の差を測る** | (実装ではない)`research/` に画面の観測を1本 | 「入力の UI が全然似ていない」の**中身を私は今も持っていない**。公式ドキュメントに composer の造りの記述が無く、推測で写すと的を外す。Tom は公式を使わない裁定だが、**見る**のは裁定に触れない |

### Tom に1つだけ確認したい事(Yes/No)

**セッションの「削除」は要りますか? はい / いいえ**
(推奨: **いいえ** — 逐語 §9-1 は「一覧から消せない」であって、それは archive が既に満たしている。
転写の実削除は不可逆で、机の記録ごと消える)

---

## 6. 確認できなかったもの(推測で埋めていない項目)

公式側で裏が取れず **不明** と書いた項目と、探した先:

| 項目 | 探した先 |
|---|---|
| 電話の composer の造り(voice 入力 / 下書き保存 / キーボードツールバー / 複数行) | `code.claude.com/docs/en/mobile`、`/docs/en/remote-control` を全文取得。記述なし |
| `@` 補完が**電話の composer に**出るのか、端末だけか | 同上。原文は「Use your full local environment remotely」の項に置かれており、面を区別していない |
| diff 面のファイル一覧の構造・シンタックスハイライト | `/docs/en/claude-code-on-the-web` を全文取得。diff の存在は在るが UI の内訳は無し |
| 承認ボタンの実際の文言(once / always / deny) | `/docs/en/permissions` を全文取得。CLI の Yes/No 用語のみ |
| カメラ撮影とライブラリの区別 | `/docs/en/mobile`、`/docs/en/remote-control`。どちらも "Photos" とだけ |
| 一覧の grouping / 検索 | `/docs/en/claude-code-on-the-web`、`/docs/en/mobile`。archived の絞り込みのみ |
| **Code タブ内のアカウント / 組織の切替** | `code.claude.com` を横断検索。Code タブ固有の記述は見つからず。`/docs/en/mobile` は「Sign in with the same claude.ai account and organization you use for Claude Code」とだけ |
| モバイル/web の会話内検索・跳躍・折り畳み・verbose/summary の切替 | `/docs/en/remote-control`、`/docs/en/mobile`、`/docs/en/claude-code-on-the-web`、`whats-new` 索引 |
| Code タブ内の「実行中」表示の視覚要素(push 通知・端末側の帯とは別に) | 同上 |
| Week 35 以降の週次まとめ | `code.claude.com/docs/en/whats-new` の索引を直に取得。**Week 34(8/17–21)が最新**で、それ以降は未公開 |
| モバイルからの fork / branch | `whats-new` 内の `/fork` は CLI 機能としてのみ記載 |

**[UNVERIFIED]**(第三者・未検証):
`github.com/anthropics/claude-code` の issue に、モバイルからの画像添付が動かないという報告が複数
(#65868 は「the mobile Claude Code chat input currently has no attach / image button」として duplicate クローズ、
他に #65601 / #62031 / #57882 / #53596 / #42156)。**公式ドキュメントの記述と食い違う**ので、
F11 を写す時は「公式に文書化されている ≠ 実際に動く」を前提にする。

**取得の経路について**: §3 の中でも判断を最も左右する 5 件(F1 diff 面 / F2 subagent 停止 /
F3 `@` 補完 / F4 承認プロンプトの寿命 / F7 ディレクトリ選択)は、委譲した取得の結果を鵜呑みにせず
**私自身が `code.claude.com` を取り直して原文の一文を確認した**。それ以外の行は委譲側の引用に依っており、
URL と原文は付いているが私の再取得は経ていない。
