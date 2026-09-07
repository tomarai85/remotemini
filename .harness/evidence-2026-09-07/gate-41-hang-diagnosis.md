# commit の門(gate-41)が 20 分止まった件 —— 読み取り専用の診断(2026-09-07、subagent)

## 事象
5 つ目の状態 `stopped` の commit(後に gate-42 で `0ac6775` として通った)で、pre-commit の `commit-suite-gate.sh` → `npm test` →
`node --test test/**/*.test.mjs` が 20 分以上 進まなかった。子 `node test/panel-stop-driver.test.mjs`(pid 86062)は 0% CPU で event loop が
kevent で待機(`gate-41-hang-node-sample.txt`)、runner(pid 85593)は生存、suite の一時 log は別ファイルの "ok 135" で止まっていた。
同じ file は単独で 2 秒(33 検査)。殺した直後に `--test-timeout=45000 --test-concurrency=6` で全 suite が 1527/1527、撃ち直した gate-42 も通った。

## 診断(subagent、ファイルを読んだ事実と知識を分けて)
1. 捕捉: `commit-suite-gate.sh` は `eval "$SUITE_CMD" > "$OUT" 2>&1` = **ファイルへの redirect**。門の script 自身が pipe で詰まる道は無い。
   ただし node の `--test` は file ごとに子 process を起こし、子の結果を親が内部の channel で受けて整形する —— 其処は repo の外。
2. 並列度・上限: `package.json` の test script に `--test-timeout` も `--test-concurrency` も**無い**(既定 = 上限なし / CPU 数)。
   此の機は論理 CPU 15、検査 file は 95。
3. `panel-stop-driver.test.mjs` 自身: 全ての `inj()` が `sleep: async () => {}`(実時計なし)+ 同期の偽 tmux。`pollScreen` は `Date.now()` の
   予算で必ず抜ける(有界の busy-poll)。imported source に `setInterval/setTimeout/unref` は constructor の既定(此処では上書き)以外に無い。
   → 此の file の非同期が無限に待つ道は無い。
4. 知識(未検証): node の `--test` は file ごとの process 分離で、子は親に結果を送る channel を親が drain する必要がある。15 並列 × 95 file の
   負荷で「終わった子が親に読まれるのを idle で待つ」形は、観測(kevent・0%・親生存)と整合する。macOS で `node --test` の高並列の
   遅延/停滞の報告は一般に在るが、此の node/OS 版の特定 issue 番号は持っていない。
5. 最小の処置: `commit-suite-gate.sh` の suite 実行に **watchdog**(例 5-10 分)を掛け、切れたら `node --test` の process 木
   (pid / state / %cpu / command)を dump してから exit 2(「測れなかった」= script の既存の哲学)。補助として test script に
   `--test-timeout=45000`(1 検査の hang は捕まえるが、今回の様な runner の channel の停滞は捕まえない)。
   対照: 決して解決しない promise を await する使い捨ての検査 file を置いて全 suite を回し、watchdog が発火して正しい pid を名指す事を見る。

MOST LIKELY CAUSE: node test-runner の process 分離 / 並列の contention(親が子の channel を drain するのが遅れる)。confidence: medium。

## 此処までの処置
- gate-41 は殺した(commit は作られていない)。同じ staged 内容で gate-42 が通った。
- 処置候補(watchdog + dump + 対照)は round 12 の Planner の brief に載せた(発見型の 1 枠)。
