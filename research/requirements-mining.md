# 移動中スマホ作業 — 要件採掘 (過去 .md 群からの一次資料集成)

作成: 2026-07-31。read-only 調査。**新しい解釈は加えない** — 引用・事実・出典を並べただけ。
目的: Tom は「要件はもう散々話してある」と明言 → 散在する言葉を出典付きで集約する。

読んだ対象:
- `~/.claude/plans/mobile-work-handoff-2026-07-28/`(measured-plan.md / REQUIREMENTS.md / spec.md — 全部)
- `~/.claude/projects/-Users-tomtim/memory/` の project_blink_selfbuild_2026_07_30.md / HANDOFF-2026-07-29-mobile-work.md / feedback_no_iphone_in_jervisglass_path.md / feedback_jervisglass_multi_entry_not_disconnect_iphone.md / feedback_edith_family_bypass_allows_all_fully_handsfree.md / user_work_pattern_mobile.md / HANDOFF-2026-07-16-life-agent-transition.md
- `~/.claude/plans/HANDOFF-edith-split-brain-2026-07-07.md`
- `~/.claude/projects/-Users-tomtim-Infra-mobile-work/memory/HANDOFF-2026-07-31-mobile-work.md`(現行)
- grep 追加: project_claude_anywhere_foundation_2026_06_13.md / project_mbp_remote_claude_construct.md / ref_mbp_remote_work_setup.md / project_multi_terminal_ios_resume.md

---

## 1. Tom の逐語の要求・好み(引用可能な形)

| 引用 | 日付 | 出典 |
|---|---|---|
| 「**普通の Claude code、Native Claude Code App とおんなじイメージ**」 | 2026-07-29 発言、2026-07-30 に本人が意味を明示的に訂正 | `HANDOFF-2026-07-29-mobile-work.md` §0、`project_blink_selfbuild_2026_07_30.md` §1 |
| ↑の訂正: 「これは『Claude 公式アプリを使う』ではなく『公式アプリと同じ使用感を生ターミナルで得る』の意」(前セッションのハンドオフが付けた「= 生のターミナル」という解釈は**Tomの言葉ではない**と本人が訂正) | 2026-07-30 | `project_blink_selfbuild_2026_07_30.md:38` |
| 「**俺は Claude Code 複数使ってるから、CodexBar と同じようにアカウントの変更もスムーズにできなければならない**」 | 2026-07-28 | `~/.claude/plans/mobile-work-handoff-2026-07-28/spec.md` Sprint 4 節 |
| 「**自分で作ればいいのでは**」(iOS アプリの自作可否を問うた) | 2026-07-28 | `spec.md` Sprint 2 節「iPhone 側にアプリを自作しない理由」 |
| 「**割に合わないは関係ない。完璧なものが無いなら作る**」(Tom 裁定) | 2026-07-30 | `project_blink_selfbuild_2026_07_30.md` §4 |
| 「**Native のは使わない**」(Anthropic Remote Control について) | 明示発言・日付記載なし(2026-07-29〜30系文脈) | `project_blink_selfbuild_2026_07_30.md` §7 表 |
| Termius を「**過去に使って嫌いだった**」(本人談) | 2026-07-30 | `project_blink_selfbuild_2026_07_30.md` §7 表 |
| 「**全部1から相互認識の差がないか確認しよう**」(前セッションを止めた発言) | 2026-07-31 未明 | `HANDOFF-2026-07-31-mobile-work.md` 冒頭 |
| 「**MBP を常用機から降ろすのは本末転倒**」(Tom 裁定) | 2026-07-28 | `spec.md` §0(rev.3)、`measured-plan.md` §11 でも参照 |
| 期限 = 渡米 **2026-08-20**(回答済み) | 2026-07-28 | `REQUIREMENTS.md` §8 項目2「回答済 2026-07-28」 |
| 移動中のアカウント切替が「**必要**」と明言済み | 2026-07-28 以前 | `measured-plan.md` §11 項目5 |
| 「**どんどんやれ**」(実機投入の GO 指示) | 2026-07-31 | `HANDOFF-2026-07-31-mobile-work.md` §7-5 |
| Multi-Terminal iOS(表示名 Helix)を**却下**。リポジトリの `PersonalPresets.swift` への追記も差し戻し済み | 日付記載なし(2026-07-29〜30系文脈) | `project_blink_selfbuild_2026_07_30.md` §7 表 |
| Remote Control を明示却下:vendor-closed = 自分の skills/機能を足せない / 「connecting」接続待ちで作業が止まる / 自分のアプリ・ターミナルを自由に作れない。「**所有して拡張する**」大前提に反する | 2026-06-13 | `project_claude_anywhere_foundation_2026_06_13.md` §「方向の確定事項」 |
| 「移動している最中(= MBPを開けない時間帯)に、スマホから対話しながら作業を進めたい」「進捗を見るだけ」でも「投げておくだけ」でもなく**対話で進めたい方** | 2026-07-28 本人明言 | `user_work_pattern_mobile.md` §「Tom がやりたいこと」 |

## 2. 過去に却下された物と却下理由(蒸し返し防止)

| 却下対象 | 理由 | 出典 | 現在の状態 |
|---|---|---|---|
| iOS アプリを自作する | (当初)無料署名は7日失効、継続には Apple Developer Program $99/年。差額はApple署名家賃 | `REQUIREMENTS.md` §3 | **★後に前提が崩れて覆った**(§4 参照) |
| セッションを機械間で移送する機構 | ベンダーもOSSも解いていない。Anthropic自身「ローカルのプロセスが動き続けていなければならない」と明記。Tomは既に毎セッション HANDOFF-*.md で同じことをやっている | `REQUIREMENTS.md` §3 | 維持。移送でなく「起動時に読む」方式で確定 |
| 双方向の常時同期 | 生きたgitツリーに向けると `.git` が壊れる実例あり | `REQUIREMENTS.md` §3 | 維持 |
| 正本を守るリース/ロック機構 | 非所有側を機械的に書込不能にしないリースは誤った安心を与えるだけ。レーンの所属で守る方針に | `REQUIREMENTS.md` §3、`measured-plan.md` §9(rev.3で撤回を再確認) | 維持。「規律ではなく所属で守る」 |
| MBP を常用機から降ろす | Tom 裁定 2026-07-28 | `REQUIREMENTS.md` §3、`spec.md` §0 | 維持 |
| 通知に中身(パス・コード・エラー)を載せる | 「Claude が待っています」で足りる。中身を載せなければ守るものが無くなる | `REQUIREMENTS.md` §3 | 維持・実装済み(固定文のみ) |
| Anthropic 公式 Remote Control | vendor-closed / 拡張不可 / 接続待ちで作業停止 / 「所有して拡張する」大前提違反(Tom明示 2026-06-13)。ただし設計の参考としては有効 | `project_claude_anywhere_foundation_2026_06_13.md`、`project_blink_selfbuild_2026_07_30.md` §7 | 不採用維持。「併用。置き換えではない」という位置づけも一時あった(`HANDOFF-2026-07-29` §4) |
| tmux 単体(cross-host resume の解として) | 単一ホスト multi-attach は可だが cross-host/cross-device の session resume は不可 = continuity 要件を満たせない。Tom自身もtmuxに違和感表明 | `project_claude_anywhere_foundation_2026_06_13.md` | tmux は「作業を守る土台」としては採用(edith常駐)。移送の解としては不採用のまま |
| Termius | Tom が過去に使って嫌いだった(本人談 2026-07-30) | `project_blink_selfbuild_2026_07_30.md` §7 | 不採用確定 |
| App Store 版 Blink | 使う前に支払いを要求される | `project_blink_selfbuild_2026_07_30.md` §7 | 不採用確定 |
| Multi-Terminal iOS(Helix) | Tom が却下 | `project_blink_selfbuild_2026_07_30.md` §7 | 不採用・削除済み |
| SideloadFix.dylib(有志スクリプトの第三者注入) | Tom の SSH 秘密鍵を持つアプリに検証していない第三者バイナリを埋めない(**これはTomの却下ではなくAI側の判断**、要注意) | `project_blink_selfbuild_2026_07_30.md` §2-5 | 不採用(自己判断) |
| ServerAliveInterval の有効化 | keepalive 失敗時に teardown しない実装なので復旧機能にならず、既知の libssh バグだけ買う(Codex判定+AI同意) | `project_blink_selfbuild_2026_07_30.md` §4-E | 蒸し返さない |
| mosh(の追求) | 実機で確定的に失敗(UDP到達するがmoshだけ60秒で無接続タイムアウト)。autostartループができたので優先度低下 | `project_blink_selfbuild_2026_07_30.md` §5、`HANDOFF-2026-07-31` §4 | 蒸し返さない(未解決のまま優先度を下げた、放棄ではない) |

## 3. 過去に確定した制約・実測値(再測定不要)

| 項目 | 値 | 出典 |
|---|---|---|
| iPhone 縦画面(40桁) | 34字超で単語途中折り返し。**表示されるだけでレビュー不可** | `measured-plan.md` §1-1 |
| 実用の下限 | **60桁**で折り返し消失 | 同上 |
| 差分レビューの結論 | **横画面必須。縦は読む・打つ用** | 同上 |
| tmux スクロールバック | **機能しない**(alternate screen のため `history_size=1`)。代替は Claude Code 自身の PgUp/PgDn | 同上 |
| 承認プロンプト | Tom の設定では出ない(主要ツール全面許可・`ask`空)。`--permission-mode manual` でも編集・rm -rf が無確認で実行された(実測) | `measured-plan.md` §1-2 |
| PgUp/PgDn | tmux を**実測PASS**で通過する。ソースにも実装確認(`blink-uio.min.js`) | `measured-plan.md` §1-1、`project_blink_selfbuild_2026_07_30.md` §2-1 |
| edith ハード | M4/10コア/RAM16GB(空き88%/swap0.00M)/ディスク空き115GB/load 1.9 | `measured-plan.md` §1-3 |
| edith 無人復帰 | FileVault OFF + autologin → 再起動後も無人で戻る | 同上 |
| edith `/Users` | root所有。sudoなしで `/Users/tomtim` 作れない。`/Users/Shared` は書ける | 同上 |
| edith Tailscale | デーモン2本重複稼働(後に整理・所有側確定) | `measured-plan.md` §1-3、rev.3版でも同様の指摘 |
| MCP実依存(30日) | Gmail 468 / Slack(stdio)193 / Slack(account連携)158 / Drive 60 / Calendar 41 | `measured-plan.md` §1-6 |
| GUI必須(edithに載らない、30日) | Roblox Studio 1283 / DaVinci 965 / Blender 595 / computer-use・xcodebuild・chrome 180/172/141 | 同上 |
| 結論 | ツール使用はGUI依存が支配的(3,000回超 対 レーン用920回)。「電車でPaperlings」は部分的にしかできない | 同上 |
| Termius 無料枠 | Starter に mosh 含む(公式料金比較表)。ED25519鍵生成・ホスト保存(ローカルvault)も無料枠。ただし**Tom自身が過去に嫌って不採用**(§2参照) | `measured-plan.md` §1-9 |
| ntfy | iOS無料アプリ。トピック名が実質パスワード | 同上 |
| Tailscale iOS の電池 | 未解決の既知問題(2026-03-20再検証、主因はexit node経由=該当せず) | 同上 |
| 実セッションの絶対パス密度 | 51MBで6,868回、9.7MBで4,608回。90%超が作業ディレクトリパス | `measured-plan.md` §1-5 |
| 日本語入力 | WebView経由でiOSのIMEがそのまま効く構造。**解決済み**(composition→onIME配線あり) | `project_blink_selfbuild_2026_07_30.md` §2-2 |
| 署名の有効期限 | **1年有効(2027-06-06)**。「7日失効」は過去の証明書誤読と判明済み | 同上 §2-3 |
| mosh | 実機で確定的に失敗。素のUDPは両方向とも到達するが mosh だけ60秒でタイムアウト | 同上 §5、`HANDOFF-2026-07-31` §4 |
| remote-mini の実運用上限 | 両機に**同一絶対パス**が要る。実測: edith に `/Users/tomtim` 無し、`/Users/Shared/dev` はある。Tomの実プロジェクトは全部 `/Users/tomtim/` 配下 = **2026-07-31時点で持ち出せる実案件ゼロ** | `HANDOFF-2026-07-31-mobile-work.md` §7-1 |
| ライフサイクル実機検証(7通り) | cold launch / 悪ホスト失敗+差替 / 76秒背面→前面 / edith側観測 / サーバ側切断→4秒復帰、まで実測PASS。**未検証**: キーバー実タップ・日本語IME実入力・build5の実機動作 | 同上 §2、§3 |
| Tom の働き方 | MBPを持ち歩く主力機。iPhoneテザリング常用(外での回線はiPhoneのSIM)。電池駆動が主(AC時0回のスリープ記録) | `user_work_pattern_mobile.md` |

## 4. 要件として読めるが解釈が混じっている記述(出典に「解釈」と明記されている物)

| 記述 | 出典の自己申告 |
|---|---|
| 「作業は edith の中で走り、iPhone は窓に徹する」 | 「**設計をそう組んだのは私であって Tom の要件ではない**」と明記(`HANDOFF-2026-07-31-mobile-work.md` §0) |
| 渡米直後の移動期間は使えない(edithが箱の中) | 「推測」と自己申告(同上) |
| 寮のネットが落ちたら手が無い | 「未検討」と自己申告(同上) |
| Termius / App Store版 / Remote Control の却下が今も有効か | 「**数日前の判断で今も有効かは未確認**」と明記(同上) |
| REQUIREMENTS.md §4 の空欄4つ(4-1: 開いた瞬間に何が出るべきか A固定1部屋/B会話一覧/Cチャット/Dネイティブ自作、4-2: 「Native Claude Code Appとおんなじイメージ」の合格条件、4-3: Macの172セッションに電話から届きたいか、4-4: UIの言語) | 「**私が埋めてはいけない**」と明記(`HANDOFF-2026-07-31-mobile-work.md` §0「REQUIREMENTS.md の空欄4つ」)。REQUIREMENTS.md 本体側にも同じ空欄が現存 |
| レーン所属の方針(A/B/Cのうち B を推奨) | 「私の推奨」であって Tom 裁定ではないと明記(`REQUIREMENTS.md` §8 項目1、`spec.md` §0) |
| 「edith で走らせる価値のある作業が実際にどれだけあるか」を数えていない | rev.3 の「この計画の最も弱い点」として自己申告(`spec.md` §12) |
| Tom がこのレーンで実際に作業した事があるかは**未回答**(「無いなら要件は二人とも想像」) | `HANDOFF-2026-07-31-mobile-work.md` §0「特にTomにしか答えが無い3つ」の質問0-7として提示、Tom 未回答のまま |
| 「移動中」「作業」の具体(電車/カフェ/ベッド/機内/教室移動、コードを読む/差分承認/指示出し/落ちたジョブを直す) | 同上、質問0-4・0-5として提示、**Tom 未回答** |

## 5. 隣接文脈(別プロジェクトだが同じ嗜好パターンとして参考になる Tom の発言)

以下は JervisGlass(音声グラス)レーンの話で**この移動中スマホ作業レーンとは別件**。ただし Tom の一般的な嗜好パターンとして構造が似ているため記録する。

- 「iPhone は BT しか使わないでしょ、何度も言ってる。**毎回自分で起動するのは論外、native で使えないと意味ない**」(Tom 2026-06-18、`feedback_no_iphone_in_jervisglass_path.md`)。→ 手動トリガーが必須の設計を Tom は一貫して拒否するパターン。
- 「Edith も Friday も Jervis も全部、**Bypass Permissions ON が許可してるものは全部許可することにしてる**」(Tom 2026-06-17、`feedback_edith_family_bypass_allows_all_fully_handsfree.md`)。confirm が要るのは hard-stop(不可逆破壊/金銭/法務/production/個人データ/外部送信)だけ、という一般原則。
  - **注意**: この一般原則と、移動中スマホ作業レーン固有の決定「**危険な操作はスマホから承認しない**」(`measured-plan.md` §3-6、`REQUIREMENTS.md` §6-1、死んだソケット越しの承認が別文脈で解釈されうるため)は、両方とも一次資料に確定事項として存在する。**両立するかどうかは未整理**(死んだソケット問題はhard-stop云々と別軸の理由=通信の完全性の話であり、bypassPermissions原則と矛盾はしていない可能性が高いが、明示的にこの2つを突き合わせた記述は見つからなかった)。

## 6. 関連(蒸し返し不要な経緯確認用)

- Edith 機の split-brain 問題(`HANDOFF-edith-split-brain-2026-07-07.md`)は **2026-07-08 に別件として解消済み**。athenas → Edith機への正式移行が完了しており、本レーンの前提(edith = 10.0.0.0 が現行ホスト)と整合。移動中スマホ作業レーン自体への直接要件は無し。
- Life-Agent(`HANDOFF-2026-07-16-life-agent-transition.md`)は個人データ境界の話で、移動中スマホ作業レーンへの直接要件なし(FROZEN案件・別レーン)。
- `project_claude_anywhere_foundation_2026_06_13.md` は 2026-06-13 に AGI 議論待ちで **PAUSED**。continuity の定義(a: 会話resume+タスク投入 / b: 生きたMBP実行を直接操作)が未確定のまま止まっている。後続の測定版計画(2026-07-28〜)はこの (a) 寄りの方向で実質的に進んでいるが、**PAUSEの解除がいつ・どう決まったかを明記した記述は見つからなかった**。
- `project_mbp_remote_claude_construct.md`(2026-05-04)は MBP自体を遠隔端末化する5段階Tier構想。後の方針(edithをホストにする)とは異なる古い設計で、Helix拡張前提。現行レーンとは別の古い試み。
