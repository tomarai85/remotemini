# Codex 査読 — 電話が版を名乗った事を1回だけ言う枝(2026-08-31)

SHIP-GATE: `production_adjacent`(task `phone-sighting-observer-branch`)。

## 何を作ったか

friday の `health-observer.sh` に枝を1本。要求ログの `client=app` の行から
**電話が名乗った build** を読み、**今までに言った事が無い版**なら1回だけ知らせる。
「配布口が 115 を配っている」までは机で証明できるが、**電話が実際に何を動かしているか**は
電話が名乗るまで誰にも判らず、人が ssh して grep するしか無かった。

## 実装中に実物で踏んだ欠陥

実ログで走らせたら **「電話が build=1 を名乗った」と鳴った**。1 は build 番号ではない ——
08-31 より前の机が UA の売り物の版を書いていた残骸。
→ 机は起動のたびに `[rc-backend] listening on …` を書くので、**其の最後の行より後**だけを読む。
錨が無い(上限で切られた)時は**黙る** ——「判らない」を「見た」に丸めない。

## 指摘と対応

| # | 指摘 | 採否 | 実装 |
|---|---|---|---|
| 1 | 「最後の版と違うか」で判じると `114 → 115 → 114`(巻き戻し)で **114 を二度 言う** | **採用(実害)** | 憶えるのを**今までに言った版の集合**へ。一度言った版は二度と言わない。追記のみなので壊れ方も単純。対照を1本 追加 |
| 3 | 出し先の終了コードだけでは exactly-once は作れない | **意図・記録** | 言えた時だけ憶える = 出し先が落ちていれば次の回に**もう一度言う**。重複は沈黙よりまし(此の木の他の枝と同じ判断を踏襲) |
| 2 | 「最後の listening-on より後」は**プロセス起動の境界**であって schema の世代ではない。配備しても再起動しなければ破れる | **部分採用** | 今回は配備が必ず再起動を伴う(`deploy-to-friday.sh` が入れ替え後に再起動を観測する)ので成立する。★**撤回条件**: 再起動を伴わない配備経路が出来た時、または log を結合・複製する運用が入った時は、logger が出す明示の schema 版へ移す |
| 1-a | `client=app` / `build=` は詐称できる | **受容(記録)** | 其の口は bearer 鍵が要る。鍵を持つ者は既に机を操作できるので、此処の詐称は新しい権限を与えない |
| 1-b | 上限で切られる直前の1回は失われうる | **受容(記録)** | 出来事の通知なので取り零しは黙るだけ。版を知りたい時は `delivery-check.sh` が要求で答える |
| 1-c | 観測器の同時走行で重複 | **受容** | launchd は同じ label を重ねない。観測器は1本 |

## 実測

- 対照 129/129(1回だけ / 同じ版で黙る / 版が変われば言う / **巻き戻しで二度と言わない** /
  名乗らない行と道具の行では鳴らない / **錨が無ければ黙る** / 空 = 見ない)
- 配備して `observer-parity: 一致 5/5`、配った物の `--dry-run` 自己検査 rc=0
- friday の実ログ: 最後の起動より後に `client=app` が **80 本、版を名乗る物は 0 本**
  = 彼の電話は**今も机と喋っているが 106 未満**。枝は正しく黙っている

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
session id: 01a056d7-615a-75a2-9f09-06a0e76da778
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Answer from this prompt only. No files, no commands. Under 200 words, adversarial, no praise.

A Mac mini runs a 10-minute health observer for a personal iPhone app's backend. I added one branch: say ONCE, to Discord, when the phone announces a build it has not announced before.

Data source: the server's request log. Each line has client=app|tool and build=<n> or build=-. The build field comes from an X-App-Build header the app sends; builds older than 106 do not send it, so they log build=-.

The trap I hit: before today the server wrote the User-Agent's marketing version (1) into that field. Running the branch on the real log fired 'phone announced build=1' — a number that was never a build. Fix: the server writes '[rc-backend] listening on ...' on every start, so the branch only reads lines AFTER the last such line, and stays silent if no such anchor exists (log rotation can remove it).

State: one file holding the last announced build. Notify only when the parsed build differs. Notification is only marked as sent if the notifier exited 0.

Measured on the real desk after deploy: 80 client=app requests since the last restart, 0 announcing a build; branch silent. Controls 128/128, deployed copy matches repo 5/5.

Attack:
1. What makes this branch fire when it should not, or stay silent when it should fire?
2. Is 'lines after the last listening-on' a sound era boundary?
3. Is one-file last-build state enough?
2026-08-31T08:02:31.674931Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T08:02:31.754749Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T08:02:31.909980Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. False fire/silence risks:

- `client=app` and `build=` are spoofable unless authenticated.
- “Differs from last” causes `128 → 129 → 128` to announce 128 twice.
- Multiple phones/build channels can alternate and spam.
- Concurrent observer runs can duplicate notifications.
- Accepted Discord message followed by notifier timeout/nonzero causes retry duplicates.
- State corruption, partial writes, parsing whitespace/junk, or unbounded build values can misfire.
- Log rotation without an anchor intentionally suppresses valid announcements.
- A valid announcement immediately before rotation may be lost.

2. “After last listening-on” is only a process-start boundary, not a trustworthy schema-era boundary. Restarts after the fix make it workable, but deployment without restart, copied/merged logs, delayed writes, anchor-like injected content, or rotation break the assumption. Prefer a structured schema/version marker emitted by the logger and parsed as an exact record.

3. One last-build file is insufficient for “never announced before.” Store a set/history keyed by environment, app identity, and build. Use atomic write/rename plus locking. Exactly-once Discord delivery is impossible using only notifier exit status; use an idempotency key or durable pending/sent transaction state.
tokens used
12,527
1. False fire/silence risks:

- `client=app` and `build=` are spoofable unless authenticated.
- “Differs from last” causes `128 → 129 → 128` to announce 128 twice.
- Multiple phones/build channels can alternate and spam.
- Concurrent observer runs can duplicate notifications.
- Accepted Discord message followed by notifier timeout/nonzero causes retry duplicates.
- State corruption, partial writes, parsing whitespace/junk, or unbounded build values can misfire.
- Log rotation without an anchor intentionally suppresses valid announcements.
- A valid announcement immediately before rotation may be lost.

2. “After last listening-on” is only a process-start boundary, not a trustworthy schema-era boundary. Restarts after the fix make it workable, but deployment without restart, copied/merged logs, delayed writes, anchor-like injected content, or rotation break the assumption. Prefer a structured schema/version marker emitted by the logger and parsed as an exact record.

3. One last-build file is insufficient for “never announced before.” Store a set/history keyed by environment, app identity, and build. Use atomic write/rename plus locking. Exactly-once Discord delivery is impossible using only notifier exit status; use an idempotency key or durable pending/sent transaction state.
```
