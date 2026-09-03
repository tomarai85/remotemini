# Codex review — `/diff` の口の切り出しと busy の fixture(6bb46ff)— 2026-09-03

- 走らせ方: `codex exec --sandbox read-only --skip-git-repo-check`(gpt-5.6-sol / xhigh)。生の log =
  `codex-difftests-review.raw.log`(5593 行、rc=0。loop の receipt は其の sha、2 タスク共通)。

| # | 重さ | 何処 | 何が起きるか | 最小の直し |
|---|---|---|---|---|
| 1 | High | `server.mjs` の `return handleDiffGet(...)` | `await` が無い = 返した Promise の reject を外側の `try/catch` が見ない。`readWorkingDiff` が投げると **500 にならず応答が無い**(http は listener の Promise を捨てる) | `return await handleDiffGet(...)` + `await` を要求する配線検査 |
| 2 | Medium | `DiffFetchingFixture.busyCalls`(process 全体の static) | 同じ process で Diff を閉じて開き直す・2 つ目の view model を作ると、1 回目から sample が返る。`nonisolated(unsafe)` の競合も | `final class` の instance 変数に(`PollFetchingFixture` と同じ形) |
| 3 | Low | 「押しても混んだまま」の UI 検査(削除済み) | 押した後の主張が「押す前から見えている物」だけ = ボタンの動作を空にしても緑 | 削る(busy → sample の検査が動作を守っている) |

Clean(Codex の言): `sessionCwd()` は 1 回評価のまま、`json` / `diffBody` の意味は不変。Node 22 の `close` の挙動は此の
GET 経路では問題なし(req を消費しない、`res.end()` の前に listener を外す)。busy → sample の UI 検査は Try again の
動作を本当に守っている。

## 直し(同日、worktree `diff-tests2`)

| # | 直し | 検査 |
|---|---|---|
| 1 | `return await handleDiffGet(...)` | `diff-routes.test.mjs` が `return await` を要求(`await` を外す変異は赤) |
| 2 | `DiffFetchingFixture` を `final class`、`busyCalls` を instance に | `DiffFixtureTests` 3 本(別 instance は独立) |
| 3 | 冗長な UI 検査を削除 | busy → sample の検査が動作を守る |
