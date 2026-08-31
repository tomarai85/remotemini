# Codex 査読 — 役の既定を control へ反転し、名乗りを通り道へ移した(2026-08-31)

SHIP-GATE: `production_adjacent`(task `role-announced-on-the-through-path`)。

## 指摘と対応

| # | 指摘 | 採否 | 実装 / 実測 |
|---|---|---|---|
| 1 | ★**既定を `control` にすると偽陽性が偽陰性へ移る**。刻印が壊れた配布ビルドも `control` になり、**所有者の異常を通知しなくなる**。ビルド工程の欠陥も表面化しにくい | **採用(最重要)。ただし鎖は既に二重に塞がっている** | ①**作れない**: `build.sh` は刻印の直後に読み戻し、期待と違えば `exit 1`(`_role_stamped` の比較)。②**配れない**: `adhoc-ota.sh` は署名済み束の `RCRole` を読み、空でなければ「配る束に役が焼かれている。配らない」で `exit 1`。★之で「壊れた刻印の束が Tom の電話に載る」経路が無い。対照 B7 が②の門の存在を測り、B10 が①の読み戻しを測る。★**沈黙は騒音より悪い**という指摘は正しく、だから此の2つが**反転の前提条件**である事を明記する —— どちらかを外すなら反転も戻す |
| 2 | まだ所有者扱いになる条件(古いビルド / 中央メソッド外 / proxy が落とす / 未知値を UA へ落とす)。根本は「**識別不能なら app**」。未知値は `unknown` にすべき。此のヘッダは自己申告なので認証ではない | **部分採用・一部は意図的に据え置き** | 「中央メソッド外」は今回 潰した(押す場所は 1 file、対照 S8/S9 + 変異で赤)。「識別不能なら app」は**据え置き**: 机の分類語彙(`app/tool/probe/control/none/other`)は sighting・census・帯の3つが読んでおり、`unknown` を足すと其の全部を同時に直す必要が在る。★但し**過大計上は見えるが過少は嘘**(既存の註記 B3)という向きは今回も守っている —— 未知は `app` 側 = Tom として数える。★自己申告である点は同意。此れは計測の分類であって認可ではなく、認可は API 鍵が持つ |
| 3 | 「通り道で1度」は、client ごとに違う役が要る場合を隠しうる | **意図・設計として回答** | 役は**ビルドの身元**であって要求ごとの意図ではない(`project.yml` の Info.plist に焼く物)。よって中央で1度が正しい。★併せて**明示の per-request override は残してある**: 既に `X-RC-Role` が入っている要求は上書きしない(版と同じ規則)。混在が要る日が来ても、其の口は開いている |

## 実測

- 役を押す場所 = `ios/Sources/Core/BackendSession.swift` **1 file**(押印の形で数える)
- 構造対照 `build-header-stamp-control.sh` **9/9**(S8/S9 新設)。★変異(押印を消す)で S8/S9 が赤
- `client-role-controls.sh` **8/8**(B9 は砂場で実際に generate して plist を読む)
- `health-observer-controls.sh` **131/131**。★新設: `client=control` の行では鳴らない +
  **同じ版でも `app` が名乗れば鳴る**(= 前者が「常に 0」の検査でない事の陰性対照)
- iOS 全掃き **759/759**。配る束の実測: `--no-install` の成果物は `RCRole` 空 / 版 117

## 生の走行

```
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 01a057de-5c19-7e42-9a9d-b70bfa6e8151
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Answer from this prompt only. No files, no commands. Under 180 words, adversarial, no praise.

A personal iPhone app talks to a backend on the owner's own Mac mini. The desk's request log classifies each request as client=app (the owner's phone) or client=control (my test/harness builds), using an X-RC-Role header the app sends.

Two false Discord alerts fired because harness builds looked like the owner's phone. Root: builds that bypass the build script inherit a literal placeholder for the role, and the app refuses to send a placeholder, so they announced nothing and fell through to user-agent classification as 'app'.

Two changes: (1) the project's static default for the role is now 'control', and the build script stamps the real value after generation and reads it back — the shipping build gets an empty role, verified on a real signed build. (2) the role header, like the build-number header before it, is now stamped once in the single method every client funnels through, instead of in one client.

Attack:
1. What does defaulting to 'control' make WORSE?
2. What still classifies a harness request as the owner?
3. Is 'stamp once in the through path' hiding a case where a client legitimately needs a different role?
2026-08-31T12:49:46.297392Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T12:49:46.321781Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T12:49:46.784960Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. `control` デフォルトは偽陽性を偽陰性へ移す。スタンプ処理が壊れた実ユーザー向けビルドも `control` になり、所有者の異常を通知しなくなる。さらにビルド工程の欠陥が表面化しにくい。

2. まだ所有者扱いになる条件：

- harness が shipping 設定の空ロールで作られる
- 古いビルドを使う
- ヘッダーが中央メソッド外、リダイレクト、別通信層で欠落する
- proxy/backend がヘッダーを落とす
- backend が空・未知・不正値を user-agent 判定へフォールバックする

根本的には「識別不能なら `app`」が残存リスク。未知値は `unknown` に分類すべき。なお、このヘッダーは自己申告なので認証にはならない。

3. 隠す可能性はある。role が「ビルドの身元」なら中央で一度付与が正しい。role が「個々のクライアント／要求の意図」なら、中央処理による上書きは誤設計。混在が正当なら、明示的な per-request override と許可範囲を定義し、無条件上書きを避けるべき。
tokens used
12,597
1. `control` デフォルトは偽陽性を偽陰性へ移す。スタンプ処理が壊れた実ユーザー向けビルドも `control` になり、所有者の異常を通知しなくなる。さらにビルド工程の欠陥が表面化しにくい。

2. まだ所有者扱いになる条件：

- harness が shipping 設定の空ロールで作られる
- 古いビルドを使う
- ヘッダーが中央メソッド外、リダイレクト、別通信層で欠落する
- proxy/backend がヘッダーを落とす
- backend が空・未知・不正値を user-agent 判定へフォールバックする

根本的には「識別不能なら `app`」が残存リスク。未知値は `unknown` に分類すべき。なお、このヘッダーは自己申告なので認証にはならない。

3. 隠す可能性はある。role が「ビルドの身元」なら中央で一度付与が正しい。role が「個々のクライアント／要求の意図」なら、中央処理による上書きは誤設計。混在が正当なら、明示的な per-request override と許可範囲を定義し、無条件上書きを避けるべき。
```
