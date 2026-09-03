# Codex review — `/diff` の順番待ち(abort・上限 503)afacd1e — 2026-09-03

- 走らせ方: `codex exec --sandbox read-only --skip-git-repo-check`(gpt-5.6-sol / xhigh)。生の log =
  `codex-abort-review.raw.log`(6892 行、rc=0。loop の receipt は其の sha)。
- 判定: 実害のある指摘 1 件(High)+ 検査の弱さ 4 件。

| # | 重さ | 何処 | 何が起きるか | 最小の直し |
|---|---|---|---|---|
| 1 | High | `readWorkingDiff` の合流(`inflight`)と `withSlot` の signal | 呼び手のキャンセルと cwd 単位の共有処理が**同じ Promise**に結合。席が埋まり A が `/same` で待機、B が合流、A が abort → **B も `aborted`** になり git は走らない。逆に B(や走行中の A)の切断は無視される | 合流者ごとに自分の signal で `aborted` を返し、共有の走行は**全員が居なくなった時だけ**待ち行列から外す |
| 2 | Medium | `DiffClient` の 503 → `.success` | 画面は「読めた」状態になり再試行の導線が無い。`DiffView` は「Pull to try again」と言うが `.refreshable` が無い | `.refreshable` を付けるか、文言を変える |
| 3 | Medium | `diff-abort-and-saturation.test.mjs` の「合流者は signal を無視」 | 欠陥 1 を**正として固定** | abort した合流者だけ即 `aborted`、共有 git と生存者は成功、待機中の先客が abort しても生存する合流者は成功、の検査へ |
| 4 | Medium | 同 file の口(server.mjs)の検査 | 正規表現だけ。`onClose` を空にしても listener を解除しなくても通る | EventEmitter の req/res で挙動を測る(handler を切り出せるなら) |
| 5 | Low | 同 file の `Promise.all` | `within()` の外 = 孤児化した Promise で hang | `within()` で包む |
| 6 | Low | 既定 8 の検査 | 定数の値だけ。動作検査は `maxWaiting: 2` を明示 → 既定を 2 に変えても通る | override なしで 8 件待ち、9 件目が busy の検査 |

Clean(Codex の言): FIFO の順序、`running` の増減、待機 listener の解除、reject 後の `inflight.finally`。
`req.close` は切断時に発火し正常応答の前に `finally` で解除される = keep-alive の漏れも二重処理も無い。

## 直し(同日、worktree `diff-abort2`)

| # | 直し | 検査 |
|---|---|---|
| 1 | `inflight` の entry を `{ac, subscribers, promise}` にし、要求ごとに `subscribe`: 自分の signal が鳴れば自分だけ `aborted`、共有の走行を行列から外すのは**最後の 1 人が去った時だけ**。既に全員去った entry(`ac.signal.aborted`)には合流させず新しく走る | 合流者が abort → 本人だけ aborted・先客成功 / 待機中の先客が abort → 合流者は待ち続けて成功 / 全員去れば git 0 本・後から来た要求は古い aborted を貰わない |
| 2 | `busy` の空面に「Try again」ボタン(`diff.retry`、`viewModel.load()`)。文言を「Wait a moment and try again」に | fixture `diff-busy` / `diff-busy-then-sample` + `DiffUITests` 2 本(押すと sample が出る = 効いた) |
| 3 | 上の 3 検査に置き換え(旧「合流者は signal を無視」は削除) | — |
| 4 | 口の本体を `src/diffroute.mjs` の `handleDiffGet` に切り出し、`server.mjs` は委ねるだけ | `diff-route-handler.test.mjs` 7 本(偽の req/res で実際に通す)、変異 4 種 赤 |
| 5 | `Promise.all` を `within()` で包んだ | — |
| 6 | override なしで 8 件待ち、9 件目が busy の動作検査 | — |

走行中に本人が去った場合の意味を確定: 本人には `aborted`(書く相手が居ない = 口は何も書かない)、git は止めず
同乗者が結果を貰う。旧検査の「本人にも null」は誤った期待だった。
