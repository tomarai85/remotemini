# Codex review — `GET /api/sessions/:id/diff`(対照表 #4)— 2026-09-03

- 走らせ方: `codex exec --sandbox read-only --skip-git-repo-check` を Jervis で切り離し起動(150 秒 wrapper は使わない)。
  model gpt-5.6-sol / xhigh。生の log = 同 dir の `codex-diff-review.raw.log`(2604 行、rc=0、約 25 分。
  loop の receipt はこの raw log の sha)。
- 対象: `rc-backend/src/sessiondiff.mjs`、`server.mjs` の `action === "diff"`、`wire.mjs` の `diffBody`、
  `test/sessiondiff.test.mjs`、`test/diff-routes.test.mjs`(f5015fd)。
- 依頼した 5 面: (1) 敵対的 cwd / repo 設定で git が外部プログラムを実行するか、木の外を読むか
  (2) 失敗を空の成功で返す fail-open (3) 切り詰めで数が偽になるか (4) 同時実行・資源
  (5) 検査が守ると言って守っていない物。

## 所見(Codex の言葉を要約。場所は 74815cb 時点の関数名で書く)

| # | 重さ | 何処 | 何が起きるか | 最小の直し |
|---|---|---|---|---|
| 1 | High | `readWorkingDiff` の git 起動 | `core.fsmonitor=/path/payload` が `git diff` の index refresh で**実行される**(Codex が `/usr/bin/true` の子プロセスで再現)。`.gitattributes` の clean/process filter も別経路 | `-c core.fsmonitor=false` / `--ignore-submodules=all` / `GIT_*` 環境変数の掃除。根本は子プロセスの実行を拒む sandbox |
| 2 | High | `server.mjs` の diff handler と `readWorkingDiff` の cwd 検査 | cwd は `existsSync` だけ。`.git` が symlink / gitfile / `core.worktree=/victim` なら**別の dir を diff する**。config include・alternates も木の外へ出る | cwd を正規化、`.git` を repo 設定を信じずに検証(symlink 拒否)、`--git-dir` / `--work-tree` を明示 |
| 3 | High | `parseDiff` と `capFiles` | `parseDiff` が 8 MiB を**全部 materialize してから** `capFiles`。空の追加行は `text === ""` で 0 byte = **byte 上限を全部すり抜ける**(1 byte 上限で空行 10,000 本が残った) | 行ごとに最低コストを課す(記号 + 改行)、上限に達したら保持を止め数だけ数える |
| 4 | High | `server.mjs` の diff handler | GET 1 本ごとに git を起こし、合流も上限も無い。切断しても子は止まらない | cwd ごとの single-flight + 小さな全体 semaphore、飽和は 503、`AbortSignal` を接続 |
| 5 | Medium | `readWorkingDiff` の staged 側の失敗処理 | unstaged が空で `git diff --cached` が失敗すると `files:[], reason:null, truncated:true` = **失敗が成功と見分けられない** | 部分結果は残しつつ `reason: staged.reason`(か `partialReason`) |
| 6 | Medium | `readWorkingDiff` の `run`(maxBuffer)| maxBuffer 切れの部分 stdout を全体として解釈 → 後半の +/- が消え、`totalBytes` は下限でしかない。`wire.mjs` の `diffBody` の註「切っても数は嘘を吐かない」と矛盾。stderr の溢れも同じ扱い | 溢れは error 扱いか、`countsExact:false` を明示 |
| 7 | 検査 | `sessiondiff.test.mjs` の偽 git 検査 | 「外部プログラムは走らない」検査は偽 git で**引数の有無**しか見ない。溢れの検査は数の正しさを見ない。staged 失敗の検査は fail-open を**正として固定**している | 本物の敵対 repo の fixture、同時実行・空行の検査 |

Clean(Codex の言): `core.pager` / `diff.external` / textconv は正しく無効。`diffBody` 自体に写像の欠陥は無い(上流の偽メタデータをそのまま運ぶだけ)。要求した 35 検査は緑。

## 私の読み(2026-09-03)

- 5 と 6 は**約束違反**(封筒の doc が「数は嘘を吐かない」と言っている)。先に直す。
- 3 は 5/6 と同じ「切り詰めの誠実さ」の話。行ごとの最低コストで塞げる。
- 4 は `gitdiff.mjs`(± バッジ)で c351ef7 に入れた `maxInflight` と同じ形で塞げる。
- 1 と 2 は defense-in-depth。cwd は Tom 自身の会話の cwd で、其処に敵対 `.git` が在る = 其の会話の agent が既に乗っ取られている状態。安い所(`core.fsmonitor=false` / `--ignore-submodules=all` / `.git` の symlink 拒否 / `GIT_*` 掃除)だけ入れ、残りは註に書く。
- 7 は 1〜6 の直しに検査を付ける時に一緒に。

## 直した物(同日、c7c099c → main dad0180)

| 所見 | 直し | 検査 |
|---|---|---|
| 5 | staged 失敗 + 読めた物 0 件 → `reason` を名乗る | 偽 git、陰性対照(両側空の成功は reason null) |
| 6 | 溢れた側は `--numstat` で数を取り直す / stderr 溢れは失敗 / `totalBytes` は溢れ時だけ下限と註 | args で答えを変える偽 git、数の一致 |
| 3 | 行の費用 = bytes + 1、`parseDiff` は file ごとに天井まで保持 | 空行 1,000 本 / 1,000 行の保持数 |
| 4 | cwd 合流(`inflight`)+ `MAX_CONCURRENT` = 2 の FIFO | 同時要求の合流、峰の本数 |
| 1 | `-c core.fsmonitor=false` / `--ignore-submodules=all` / `GIT_*` 掃除 | **本物の git**(hook が走る陽性対照 → 走らない陰性) |
| 2 | `.git` symlink → `unsafe_repo`(git を撃たない) | 偽 lstat + 本物の symlink repo。`--work-tree` 明示と cwd 正規化は未(註) |
| 7 | 上の全部 | 変異 5 種 全部 赤 |

同日 午後(loop の REPLAN で起票): 4 の残り = 待機中の abort(切断で順番待ちから外れる。走り始めた git は
`timeoutMs` に任せる)と待ち行列の上限 8 → 503 `busy` を入れた。同日 続けて 2 の残り = `locateRepo` で
cwd を realpath し `.git` を自分で探して `--git-dir` / `--work-tree` を明示(実測: `core.worktree=/victim`
の repo で素の git は victim を読んだ)、設定の filter driver を `cat` に上書き(実測: 素の git は clean
filter を実行した)。残るのは config の include / alternates で**読む**範囲が木の外へ出る道だけ(実行は
伴わない)。7 所見のうち実装で塞いだ物 = 全部。
