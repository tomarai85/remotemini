# Codex 査読 — 本体の配備が観測器の木も運ぶ(2026-08-31)

SHIP-GATE: `production_adjacent`(task `observer-tree-rides-the-backend-deploy`)。

## 何をしたか

`deploy-to-edith.sh` は `~/rc-backend/` しか運ばない。観測器は別 dir(`~/rc-observer/`)・
別 label なので**配備の守備範囲の外**に落ちており、其の死角で friday の
`health-observer.sh` は repo より 139 行・22 日 古いまま動き、毎日 誤報を投げた(CF-7 / H-4)。

配線は env の連鎖に1本足すだけ(`RC_OBSERVER_DEPLOY`)。★`exec` の連鎖そのものは
触らない —— 2026-08-26 に2回踏んだ形(連鎖の途中の註記で上半分が捨てられる)。
呼ぶのは `wl_run`(帳尻に出すが配備の終了コードには使わない)。

## 指摘と対応

| # | 指摘 | 採否 | 実装 / 判断 |
|---|---|---|---|
| 1 | 観測器の同期の失敗を門にしないのは正しい。**但し警告の道具が本当に非ゼロを吸う事**が前提 | **採用(前提を実測)** | `rc-backend/tools/warn-ledger.sh` の頭が「`wl_run` は**常に 0 を返す**(門ではないので、呼び側の `set -e` を殺さない)」と契約を書いており、実装も其の通り。前提は満たされている(★行番号では引かない —— 行はずれる) |
| 2 | 本体が先・観測器が後なので、**両立の窓**と「本体は新しく観測器は古い/途中」の分裂状態が出来る | **受容(記録)** | 窓は数十秒。観測器と本体は別 process で API を共有しない(観測器は healthz を外から叩くだけ)ので、版の非互換で壊れる面が無い。★撤回条件: 観測器が本体の内部 API を読む様になったら順序を入れ替える |
| 3 | 「置き去りに出来ない」は**言い過ぎ**。之が保証するのは「此の経路を使い、変数が空でない時に**試みる**」だけ。成功・label B の再起動・版の一致・警告が読まれる事・手で配った場合は保証しない | **部分採用(言い方を直す/一部は既に別の物が見る)** | ★**対照は配線を証明する物で、収束を証明する物ではない** —— 其の通りなので commit に明記する。★但し収束は**別の層が既に見ている**: `deploy-observer-to-friday.sh` 自身が配った後に `observer-parity-check.sh` を回して 5/5 を出し(自己申告ではない独立の測り手)、さらに 2026-08-31 に足した `parity_observe` が**日に1回**其の一致を見張る。つまり 試みる(此の変更)→ 直後の照合(既存)→ 定期の照合(今日)の3段。**手で配った場合**だけが残る穴 |

## 実測

- 新設対照 7/7(C1-C7)。★陰性対照: 連鎖に註記を1行差すと **C2/C3 が赤**
- 既存 `deploy-to-friday-controls.sh` 8/8(F7 = 連鎖に註記を挿すと届く数が 11 → 5 に減る)
- ★対照自身の抽出の誤りを1つ直した: 連鎖の終端行を**出力してから**打ち切っていたので、
  連鎖の1つ上の註記が混ざり C3 が誤って赤くなった。実装は正しく、検査が1行多かった

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
session id: 01a05770-7fd3-7fb3-94e0-18de42b84a9a
--------
user
DO NOT read any files or run any commands — answer purely from this prompt; everything you need is inline. Be concise and direct.
Answer from this prompt only. No files, no commands. Under 180 words, adversarial, no praise.

A Mac mini runs two things from one repo: a backend (~/rc-backend, launchd label A) and a health observer (~/rc-observer, launchd label B). The backend deploy script only ever carried the backend. That blind spot once left the observer 22 days stale, and it sent a false alarm to the owner every day until someone noticed.

Change: the backend deploy now also runs the observer deploy at the end. Wiring: the machine-specific wrapper passes one more variable through an env chain that ends in exec; the shared deploy script runs it only when that variable is non-empty, via the existing warning-lane helper so a failure is reported but does NOT fail the backend deploy or trigger rollback.

Controls (7, no live desk needed) check: the variable is in the chain, inside the exec chain, the chain has no blank/comment line splitting it (that exact bug bit twice), the shared script executes it rather than merely naming it, empty means skip, it is not a gate, and the target exists.

Attack:
1. Is not gating on observer sync failure right?
2. What ordering or partial-failure case does this create?
3. What does 'the observer cannot be left behind' still not cover?
2026-08-31T10:49:46.930970Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T10:49:47.786802Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
2026-08-31T10:49:48.895781Z ERROR rmcp::transport::worker: worker quit with fatal: Transport channel closed, when Auth(AuthorizationRequired)
codex
1. Correct: observer sync failure is explicitly non-gating. Backend deploy remains successful, with no rollback, provided the warning helper truly absorbs the observer command’s non-zero exit.

2. Backend is deployed first, then observer. This creates a compatibility window and a split-success state: backend new, observer old or partially deployed. Retries may also run against already-updated backend state.

3. “Cannot be left behind” is overstated. This only guarantees an attempt when this deploy path is used and the variable is non-empty. It does not guarantee:

- Observer deployment succeeds or completes atomically.
- Label B restarts and runs the intended revision.
- Observer/backend versions are compatible.
- Warning delivery is noticed or acted on.
- Direct/manual backend deployments invoke the observer.
- Empty or incorrectly populated variables cannot silently skip it.
- Observer logic/configuration cannot continue producing false alarms.

The control proves wiring, not convergence. A real guarantee needs post-deploy revision/health verification plus durable alerting or retry on observer failure.
tokens used
4,170
1. Correct: observer sync failure is explicitly non-gating. Backend deploy remains successful, with no rollback, provided the warning helper truly absorbs the observer command’s non-zero exit.

2. Backend is deployed first, then observer. This creates a compatibility window and a split-success state: backend new, observer old or partially deployed. Retries may also run against already-updated backend state.

3. “Cannot be left behind” is overstated. This only guarantees an attempt when this deploy path is used and the variable is non-empty. It does not guarantee:

- Observer deployment succeeds or completes atomically.
- Label B restarts and runs the intended revision.
- Observer/backend versions are compatible.
- Warning delivery is noticed or acted on.
- Direct/manual backend deployments invoke the observer.
- Empty or incorrectly populated variables cannot silently skip it.
- Observer logic/configuration cannot continue producing false alarms.

The control proves wiring, not convergence. A real guarantee needs post-deploy revision/health verification plus durable alerting or retry on observer failure.
```
