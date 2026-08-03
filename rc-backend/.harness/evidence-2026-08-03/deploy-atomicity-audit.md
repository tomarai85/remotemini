# 入れ替えの非原子性が**サービスから観測されない**事の確認 (2026-08-03)

Codex の最後の指摘への回答:

> Audit for lazy imports, runtime file reads, templates, or spawned scripts;
> "modules are resident" is safe only if none exist.

私は「走っている node は module をメモリに持っていて rsync 中に `src/` を読み直さない」
という論法で、symlink の貼り替え(原子的な入れ替え)を採らなかった。Codex はその論法の
**前提を測れ**と言った。前提が崩れる経路は4つ在り、全部測った。commit `61f18c8` 時点。

## 1. 動的 import — 無し

```
grep -rn "import(" src/
  src/reqlog.mjs:125,126   ← JSDoc の型注釈 `@param {import("node:http")...}` のみ
```

実行時に module を読む経路は無い。全 import が静的 = 起動時に解決済み。

## 2. 要求時の file 読み — 無し(全部起動時)

配る静的ファイル 6 本は **module 読み込み時に `const STATIC` を組み立てる所で読み切る**:

```js
// src/server.mjs:1281-1291
function asset(name) { return readFileSync(new URL(`./${name}`, import.meta.url)); }
const STATIC = new Map([
  ["/", [asset("app.html"), ...]], ["/frames.mjs", [asset("frames.mjs"), ...]],
  ["/view.mjs", ...], ["/manifest.webmanifest", ...], ["/icon.png", ...],
]);
```

要求を捌く側(`src/server.mjs:756-758`)は `STATIC.has(path)` / `STATIC.get(path)` だけで、
disk を触らない。`DEPLOYED_REV`(`src/server.mjs:55-62`)も起動時の IIFE。

## 3. 実行時に読む path は**全部同期ツリーの外**

| 定数 | 実体 | ツリー内か |
|---|---|---|
| `PROJECTS_DIR` | `~/.claude/projects` | 外 |
| `KEY_DIR` / `KEY_FILE` | `~/.rc-backend` / `~/.rc-backend/api.key` | 外 |
| `HEADS_DIR` | `~/.rc-backend/heads` | 外 |
| `FLEET_ACCOUNT` | `~/fleet-tools/fleet-account` | 外 |

`heads.mjs` / `registry.mjs` / `trust.mjs` の `readFileSync` / `readdirSync` は全部この
4つのどれかの下を読む。`rsync --delete` が触る `/Users/edith/rc-backend/` は読まない。

## 4. 子プロセス — ツリー内の script を起こす経路は無し

`spawn` / `execFileSync` の実引数は `ps` / `tmux` / `claude`(PATH 解決)と
`FLEET_ACCOUNT`(上表の通りツリー外)。**配備で書き換わる場所から script を起こす経路は無い。**

## 結論

4経路とも空 = 入れ替えの窓(実測数秒)に走っているサーバが新旧の混ざった木を読む事は無い。
**ただしこれは「走り続けている限り」の話**で、その窓で node が死んで launchd が起こす形は
別に潰す必要が在った → `tools/rc-backend-launch.sh` の配備中の印(検査 = 同 `-check.sh` の
L/M/N、守りを外した写しで L/L2/L3/M/M3 が赤くなる事まで確認済)。

## この結論が引っくり返る条件(= 将来やってはいけない事)

- `src/` に `await import(...)` を足す
- `asset()` を要求時に呼ぶ形へ変える(静的ファイルのホットリロード等)
- `tools/` の script を server から `spawn` する
- 実行時に読む path を同期ツリーの中へ移す

このどれかをやったら、この audit は無効になり symlink 貼り替えの議論に戻る必要が在る。
