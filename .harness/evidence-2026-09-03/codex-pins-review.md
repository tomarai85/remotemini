# Codex review — `/diff` が読む repo の自前決定(2436e17)— 2026-09-03

- 走らせ方: `codex exec --sandbox read-only --skip-git-repo-check`(gpt-5.6-sol / xhigh)。生の log =
  `codex-pins-review.raw.log`(1469 行、rc=0。loop の receipt は其の sha)。

| # | 重さ | 何処 | 何が起きるか | 最小の直し |
|---|---|---|---|---|
| 1 | High | `filterOverrides` | driver 名が**空**(`filter..clean` + 属性 `filter=`)だと `(.+)` が拾わない。名前に `=` が在る(`[filter "x=y"]`)と `-c filter.x=y.clean=cat` は git が最初の `=` で割るので効かない | 空や `=` を含む driver 名が在れば **fail-closed**(`unsafe_repo`)。または `GIT_CONFIG_COUNT/KEY_n/VALUE_n` で渡す |
| 2 | High | 設定の列挙(`git config --list --name-only`)の `catch` | 失敗(8 MiB 超の出力 = maxBuffer 等)で上書きを**全部捨てて進む** = `git diff` は其の設定で filter を走らせる | 列挙の失敗は `git_failed`。driver 数と上書きの総 bytes に上限 |
| 3 | High | `locateRepo` の gitfile | `gitdir: /victim/.git` を「dir で在る」だけで受ける = 被害者の index/staged を差分として晒す。`/m` の正規表現は `garbage\ngitdir: …` も通す(git は通さない) | gitfile は 1 行きっかり(1 MiB 上限)、行き先の `gitdir` file(worktree の逆リンク)が此の `.git` を指す時だけ受ける。submodule は当面 `unsafe_repo` |
| 4 | Medium | `locateRepo` の遡り | cwd が bare repo(`/outer/vendor.git`)や `/outer/.git/objects` の中でも、上へ遡って**外側の repo** を読む | 遡る前に `dir` 自身が git dir(`HEAD` + `objects` + `refs`)なら `unsafe_repo` |
| 5 | Low | 同 | 64 段で `not_a_repo` | root まで遡る(`dirname(dir) === dir` で必ず止まる) |

検査の穴(Codex の言): 通常名の clean filter しか通していない(process filter / 空・`=` の driver なし)。

Clean(Codex の言): git 2.50.1 で `filter.X.process=` は process filter を本当に無効にし clean/smudge へ落ちない。
config の列挙は `include.path` / `includeIf` を辿る。attributes file 自体は実行しない。普通の submodule、
`.git` symlink の拒否、大文字小文字を区別しない FS、realpath で解決した symlink の親は問題なし。

## 直し(同日、worktree `git-pins2`)

| # | 直し | 検査 |
|---|---|---|
| 1 | 空 / `=` を含む driver 名は fail-closed(`unsafe_repo`)、driver 数の上限 32 | 単体 + 本物の git で `filter..clean` と `filter.x=y.clean` を作り、読まない・marker が出来ない |
| 2 | 列挙の失敗は `git_failed`、diff を撃たない | 偽 git で列挙を落とし、diff の呼び出し 0 |
| 3 | gitfile: 1 MiB 上限、1 行きっかり、`<gitdir>/gitdir` の逆リンクが此の `.git` を指す時だけ受ける(submodule は当面 unsafe_repo) | 偽 fs で正 / 別 gitfile / 無し / ゴミ / 1 MiB 超、本物の git で被害者を指す gitfile |
| 4 | 遡る前に `dir` 自身が git dir(`HEAD` + `objects` + `refs`)なら `unsafe_repo` | 本物の git で `.git/objects` の中と bare repo |
| 5 | 段数の上限を外す | 偽 fs で 70 段 |

変異 4 種(空/`=` を通す・列挙が落ちても進む・逆リンクを見ない・git dir の中から遡る)全部 赤。
