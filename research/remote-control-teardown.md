# Claude Code Remote Control — 設計解剖(一次資料)

収集: 2026-07-31、調査サブエージェント(rc-teardown)。出典は明記が無い限り公式 docs
(code.claude.com)。**[UNOFFICIAL]** 印は第三者のリバースエンジニアリングで未検証。
不明な項目は推測せず「不明」と記す。目的 = 自前実装(iPhone → Tailscale → Mac mini)の設計材料。
(注: 前版はセッションクラッシュで §2 途中で切れていた。本版が完全版。)

---

## 1. アーキテクチャ

- **接続方向**: ローカル機からの outbound HTTPS のみ。inbound ポートは一切開けない(公式明記)。
- **機構**(公式の言葉): RC 開始時に Anthropic API へ登録し、仕事をポーリング。別デバイスが
  接続すると、サーバがローカルセッションとクライアントの間をストリーミング接続で中継。
  = CLI とクライアントは直接通信しない。Anthropic のバックエンドが常時ブローカー。
- **転送の安全**: 全トラフィックが TLS。複数の短寿命クレデンシャル(単一目的スコープ・独立失効)。
- **認証要件**: claude.ai の OAuth フルログインのみ。**API キー・長寿命 setup-token は明示的に拒否**。
  Bedrock / GCP / Foundry 不可。`ANTHROPIC_BASE_URL` が api.anthropic.com 以外なら無効(v2.1.196)。
- **データ保存**: 接続中の会話トランスクリプトは **Anthropic サーバに保存**(複数デバイス同期と
  ネットワーク断後の再接続の担保)。**実行と FS アクセスはローカルに留まる**。
  = ハイブリッド: 計算は手元、会話状態は中央永続化。この分割が「再接続」「複数デバイス同期」を
  タダで買っている。自前版はこの分割を採るか、純 P2P にするかを決める必要がある。

### 起動の3形態

| 形態 | コマンド | 挙動 |
|---|---|---|
| サーバモード | `claude remote-control` | ヘッドレス常駐。複数同時セッション(`--capacity` 既定32)。`--spawn worktree` で worktree 毎 |
| 対話+RC | `claude --remote-control` / `--rc` | 通常の対話セッションが遠隔からも操作可(手元と遠隔で同時に打てる) |
| 途中から変換 | セッション内 `/remote-control` / `/rc` | 走行中セッションを履歴ごと RC 化 |

サーバモードのフラグ: `--name`(一覧の表示名)/ `--remote-control-session-name-prefix`
(自動名 `hostname-adjective-noun` の接頭辞、既定 hostname)/ `-c|--continue`・`--session-id`
(v2.1.200+ 再開)/ `--spawn same-dir|worktree|session`(実行中 `w` キーで切替)/
`--capacity N` / `--[no-]create-session-in-dir` / `--verbose` / `--sandbox`。

- セッション URL を出力、**スペースキーで QR コード**表示(電話ペアリング)。
- `/config` の "Enable Remote Control for all sessions" で全セッション自動 RC 化。

## 2. UI 構成要素

**セッション一覧**(claude.ai/code サイドバー / モバイルアプリの Code タブ):
- RC セッションは**コンピュータアイコン + 緑のステータスドット**(ローカルプロセス生存中)
- タイトルの優先順: 明示 `--name` → `/rename` → 履歴の最後の意味あるメッセージ → 自動スラッグ
  (`hostname-adjective-noun` 形式、会話言語にローカライズ)
- cloud セッションは **diff スタット表示**(`+42 -18`)、アーカイブ/削除可。
  RC セッションが同じ diff バッジを持つかは**未確認**

**会話ビュー**:
- Claude のテキスト、tool-use の活動、**subagent/workflow の進捗**が全接続デバイスで同期。
  途中参加デバイスは実行中 subagent をバックフィル(v2.1.208+)
- **diff ビューア**(左ファイル一覧+右差分、行コメント)は Desktop/cloud で明記。
  RC の会話ビューでも同一かは「たぶん同じ、未確認」
- extended thinking の遠隔表示: **言及なし(不明)**
- **添付**: 電話/ブラウザからの画像・ファイルは**ローカル機にダウンロードされ `@file` 参照で渡る**
- トランスクリプト表示モード(Normal/Verbose/Summary)は Desktop の Code タブで明記、RC 側は未確認

## 3. 入力側(遠隔から送れるもの)

- 自由テキスト / 添付
- **slash コマンドはほぼ通らない**(平文として送信される)。遠隔で効く allowlist:
  - 純テキスト出力系: `/compact` `/clear` `/context` `/usage` `/exit` `/recap` 等
  - 引数インライン必須: `/model sonnet` `/effort high` `/fast` `/color` `/rename`
  - `/mcp`(v2.1.166+)・`/config`(v2.1.181+)は面ごとに挙動が違う
  - `/plugin` `/resume` などローカル専用は**不可**(既知の制限、issue #28379)
- **permission 承認**: 遠隔から承認できる(通知文言 "Approve tool calls from your phone" が公式に存在)。
  ボタンの正確なラベル(once/always/deny)は RC 面については**未確認**
- **割り込み/stop**: 遠隔 UI については**未確認**
- **permission モード切替は遠隔から不可**。Bypass は**モバイルから選択自体が不可**(明記)
- **プッシュ通知**: Claude が判断して push(長タスク完了・要判断)。プロンプト内で依頼も可
  ("notify me when tests finish")。`/config` に独立トグル2つ
  ("Push when Claude decides" / "Push when actions required")

## 4. ライフサイクル

- **再接続**: 機体スリープ/回線断 → 復帰時に自動再接続。再構築中の status 更新はキューされ
  回復後に配送(v2.1.207+。以前は再接続中の更新が失われ stale な「実行中」表示が残った)
- **ハードタイムアウト**: 機体は起きているがネット不達 ~**10分**でセッションはタイムアウトし
  **プロセスが exit**。無限リトライではない
- **ローカルプロセスが生存条件**。terminal を閉じる/kill = セッション終了。
  公式自身が「SSH 先で維持するなら tmux/screen」を推奨 = 我々のシナリオそのもの
- **confirm-before-replace**: `--resume` で RC 付きセッションを再開すると記録済み RC セッションへ
  再接続を試み、一時的失敗なら**新セッションを勝手に作らずその旨を言う**
  ("Couldn't reconnect...")。サーバが消滅を確認した時だけ新規作成
  (v2.1.200 で「失敗のたび無言で増殖」を修正)← 真似る価値のある設計
- **複数デバイス同時**: 完全対応(terminal/browser/phone で interchangeably)。
  同時入力の衝突解決は**記載なし**(おそらく chat 的に interleave)
- **1対話プロセス = 1RCセッション**(多重はサーバモードのみ、`--capacity` まで)。
  デバイス数とセッション数は別の軸
- **Ultraplan と排他**(claude.ai/code の「現在のセッション」枠は1つ)
- **Trusted Devices**(beta, Team/Enterprise): デバイス登録(WebAuthn 的)+ 18時間ローリングの
  再認証(Face ID 等)を「見る/操縦する」の条件にする ← tailnet 設計でも真似る価値がある型
  (「リンクを持っている」でなく「登録済みデバイス + 直近の認証」に紐付ける)

## 5. 制約まとめ(公式 verbatim ベース)

1対話1RC / ローカルプロセス必須 / ~10分ネット断で exit / Ultraplan と排他 /
slash 大半不可 / Bedrock 等不可 / **API キー・長寿命トークン不可(フル OAuth 必須)** /
ZDR 組織は RC 自体不可 / telemetry 無効化系 env(`DISABLE_TELEMETRY` 等)で RC も無効化 /
Bypass permissions はモバイルから選択不可

## 6. 隣接機能(混同しない)

| 機能 | 起動 | Claude の実行場所 | 用途 |
|---|---|---|---|
| Dispatch | モバイルからタスク送信 | 自機(Desktop) | 出先から委任 |
| **Remote Control** | claude.ai/code・モバイルから操縦 | **自機(CLI/VS Code)** | 進行中の作業を別デバイスから操縦 |
| Channels | チャットアプリ/自サーバから event push | 自機(CLI) | 外部イベントへの反応 |
| Slack @Claude | チームチャンネル | Anthropic cloud | PR/レビュー |
| Scheduled tasks | cron | CLI/Desktop/cloud | 定期自動化 |

- **Claude Code on the web** = cloud 実行(Anthropic 管理 VM)。RC と同じ claude.ai/code に住むが
  アーキテクチャは正反対(web = cloud 実行、RC = ローカル実行 + cloud 中継 UI)。
  `--teleport` は cloud→local の一方向で、**RC と同じトランスポート層を共用**(公式明記)
- **Channels**: event を走行中セッションへ push する軽量な別型(Telegram/Discord/iMessage 公式、
  MCP-server-as-plugin)。ペアリングコード allowlist 方式。双方向(返信も同経路)。
  RC(セッション全体を操縦・重量級)と補完関係(メッセージ出し入れ・軽量)
- Dispatch 発のセッションは **app 承認が30分で失効**(通常セッションより意図的に狭い blast radius)
  ← 電話起点の自律作業に対する意図的な安全既定として真似る価値あり

## 7. 関連 CLI(公式 CLI リファレンス)

`--remote-control/--rc` / `remote-control`(サブコマンド)/ `--teleport` / `--resume/-r`
(引数なしで picker、bg セッションは `bg` 印 v2.1.144+)/ `--continue/-c` / `--fork-session`
(履歴コピーで新 ID、元は不変 = `/branch` 相当)/ `--session-id`。
`--cloud`/`--teleport` は意図的に `--help` 非表示。

## [UNOFFICIAL] ワイヤプロトコル(frr.dev、単一ソース・未検証)

- 登録: `POST /v1/environments/bridge` → environment_id/secret/org_uuid
  (payload に machine_name / directory / branch / git_repo_url)
- ライブ: `wss://api.anthropic.com/v1/session_ingress/ws/{session_id}`、断時は
  `GET /v1/environments/{env_id}/work/poll` へ自動フォールバック(内部名 "HybridTransport" 説)
- 真似るべき骨格は公式記述と同じ: **一度登録 → 永続双方向チャネル + ポーリング退行、
  ブローカーは中継のみで実行しない**

## 設計への結論

最も意図的に真似るべき決定は **「実行はローカル、会話状態は同期、遠隔 UI は純粋な
view/control 面(計算はしない)」**。それ以外(ポーリング、中央ブローカー、短寿命
クレデンシャル群)は「電話とラップトップが直接届かない」を Anthropic が解いた部分であり、
**Tailscale がそれを既に解いている我々は丸ごと省略できる** — 電話から mini の overlay IP に
直接届くので、登録+ポーリングの半分が不要。自前版は本家より構造的に単純にできる。

さらに決定的な事実が1つ: 本家 RC は **API キー/長寿命トークンでは動かない(フル OAuth 必須)**。
edith の認証はまさに長寿命トークン(fleet 方式・2h 自動フェイルオーバー)なので、
**本家の製品を edith で使う道は構造的に閉じている**。「なぜ真似て作るのか」への回答が
調査から出た: 使いたくても使えない構成で我々は既に運用している。
