# Codex 査読 — `tools/deploy-to-edith.sh`(2026-08-03)

対象: `rc-backend/tools/deploy-to-edith.sh`(書き直した直後、**一度も走らせていない**版)
役割指定: 反論役。同意・要約・褒め言葉は要らない、見落としと失敗経路だけ。
模型: `codex-quick.sh` 既定(gpt-5.6-sol xhigh)、`CODEX_QUICK_TIMEOUT=900`

## 1回目は失敗している(= これは査読ではない)

`CODEX_QUICK_TIMEOUT=420` で「ファイルを読んでください」形式で投げた 1 本目は
420 秒で殺され、wrapper が自分の banner を書いた:

```
[codex-quick TIMEOUT 420s — do NOT treat as PASS; proceed on own judgment and log it]
```

**この banner は査読ではない。** 「Codex を通した」と数えると、実際には誰も読んでいない物を
「2 つ目のレンズを通した」と記録する事になる。2 本目は (a) 台本の全文を prompt に
埋め込んで探索を無くし、(b) 上限を 900 秒に上げた。24,769 tokens で返ってきた。

## 指摘と、私の検証結果

**★重要**: Codex の指摘をそのまま採らない。5 件のうち **1 件は結論が外れていた**(Q5)。
各項目は台本の実物 / edith の実測に当ててから採否を決めている。

| Q | 指摘 | 検証 | 採否 |
|---|---|---|---|
| Q1 | `REMOTE_RESTART` に `set -e` が無く、戻しの rsync 失敗を無視して MARK を消し、混ざった木を kickstart する | **確認**(実物 319-417 行に `set -e` も `set -u` も無い / 405 行の rsync は rc を見ていない) | 採用 |
| Q2 | 7200 秒の「取り直し」は `at` の上書きでしかなく並走する。`release_lock` は持ち主を見ずに消すので 1 本目が 2 本目の錠を外す | **確認**(135 行 / 153 行) | 採用 |
| Q3 | remote の `trap` は ssh 切断で走る保証が無い。持ち主を見ないので他の配備の印も消せる | **確認**(258 行 / 324 行)。ただし「走る保証が無い」側は launcher の 180 秒無視で受け止め済み | 部分採用(持ち主の分だけ) |
| Q4 | step 6 の rsync も失敗を無視するので、刻印だけ届いた部分更新でも step 7/8 が両方緑になる | **確認**(285 行、`REMOTE_SWAP` は `set -u` のみ)。`DEPLOYED-REV` は名前順で早いので先に届く | 採用 |
| Q5 | 冷間再起動後の復旧を検査していない。自動ログイン不成立や plist 登録不良なら停電後に戻らない | **指摘は当たり、結論は外れ**。edith を実測したら鎖は既に繋がっていた | 形を変えて採用 |

### Q5 の実測(2026-08-03、`ssh edith@10.0.0.0`)

| 項目 | 観測値 |
|---|---|
| FileVault | `is Off` = 起動時に解錠を人に求めない |
| `autoLoginUser` | `edith` |
| plist の在り処 | `/Users/edith/Library/LaunchAgents/com.edith.rc-backend.plist`(`/Library/` 側には無い) |
| RunAtLoad / KeepAlive | `true` / `true` |
| `pmset autorestart` | `1` |
| `pmset sleep` / `disksleep` | `0` / `0`(`sleep prevented by powerd`) |
| uptime | 7 days, 18:43 |

つまり「停電 → 通電 → 自動起動 → 自動ログイン → LaunchAgent が load → RunAtLoad で起動」
は既に成立している。**Codex の言う壊れ方は今日は存在しない。**

残る本物の問題は別の所に在る: この 6 つはどれか 1 つ落ちるだけで
「停電 = 二度と戻らない」に変わるのに、**落ちた事に気付く場所が無い**。
2026-08-20 以降 edith に物理で触れないので、気付けない事がそのまま終わりになる。
→ step 9b として配備の度に 4 点(FileVault / 自動ログイン / RunAtLoad / autorestart)を
観測して警告する。門にはしない(自動ログインが切れている事はコードを配る妨げにならない)。

## 実際に入れた変更

1. **錠に持ち主を入れた**(Q2): `$LOCK/owner` に `deploy-<host>-<pid>-<epoch>` を書く。
   `release_lock` は**自分の札の時だけ**外す。取り直しは札を書いてから読み直し、
   競り負けた側が降りる。加えて `assert_lock_owner` を step 6 と step 8 の直前に置いた
   —— 本番の木を書く段で錠を持っていない配備は、そこで止まる。
2. **`REMOTE_SWAP` を `set -eu` にした**(Q4)。加えて複製の rsync が落ちたら
   `mv` せずに終わる(= 半端な複製に名前を付けない)、入れ替えの rsync が落ちたら
   その場で複製から 3 回まで戻す。
3. **`REMOTE_RESTART` の戻しの rsync の rc を見る**(Q1)。3 回試して駄目なら `exit 3`。
   ここで嘘の `exit 2`(「本番は前の版のまま = 安全」)を返すのが一番害が大きい。
   `set -e` はこの段には**足していない** —— `verify` が非零を返す事で分岐する設計なので、
   `set -e` は正常な分岐を中断に化けさせる。
4. **印を持ち主で守る**(Q3): 印の中身を `<epoch> <owner>` にし、trap は自分の印だけ外す。
   launcher は印の **mtime** しか見ない(`rc-backend-launch.sh:58` = `stat -f %m`)ので
   中身を変えても壊れない、を確認済み。
5. **step 9b を足した**(Q5 由来)。実測で走る事を確認済み(4 点とも緑)。

## 採らなかった指摘

- Q3 の「ssh 切断で trap が走らない」→ 印が残る側は launcher が 180 秒で無視するので
  詰まらない。ここを塞ぐと「配備台本が落ちるとサーバが二度と上がらない」に変わる。
  ★ただし裏返すと**印が守るのは 180 秒だけ**で、混ざった木を止める仕掛けではない。
  台本の中にもそう書いた(過信しない為)。

## 未検証で残る所(正直に)

- **この台本はまだ一度も走っていない**。`DEPLOYED-REV` = `0750a48`(2026-08-03T02:35:03+09:00 刻印)
  で、書き直したのは同日 15:29。上の修正は全て `bash -n` と step 9b の実走だけが根拠。
- 変異の走行(197 件)が終わるまで `src/` が凍っているので、初回の実走はその後。

---

## 走行の生の頭(= 誰がいつ何で読んだかの証拠)

```
Reading additional input from stdin...
OpenAI Codex v0.144.3
--------
workdir: /Users/tomtim/Infra/mobile-work/rc-backend
model: gpt-5.6-sol
provider: openai
approval: never
sandbox: read-only
reasoning effort: xhigh
reasoning summaries: none
session id: 019fc6e4-44b2-7450-b2ab-9d9ae72734b1
--------
user
```

## 返答の全文(prompt の反響部分は除く)

```
codex
Q1. `REMOTE_RESTART` に `set -e` がなく、戻しの `rsync` 失敗を無視して MARK を消し、混在した木を kickstart します。
`DEPLOYED-REV` だけ先に戻れば、混在コードでも旧版を名乗って verify が緑になります。電源断なら MARK が残り、180秒後に部分復旧木が起動します。

Q2. 7200秒後の処理は「奪取」ではなく同じ錠の `at` を上書きするだけなので、1本目と2本目が同時に走ります。
1本目の `release_lock` は所有者確認なしで2本目の `at` とディレクトリを消し、3本目まで侵入可能にします。

Q3. SSH切断時の remote `EXIT` trap 実行は保証できません。shell が終了処理できれば消え、SIGKILL・電源断なら残ります。
消えれば部分 rsync 中でも起動可能、残れば180秒後に launcher が無視します。また trap は所有権なしで別配備の MARK も消せます。

Q4. 作れます。step 6 の本番向け `rsync` も失敗を無視するため、刻印だけ転送済みの部分更新でも step 7へ進みます。
新プロセスが起動できれば `/healthz` は同じ刻印を返すため、混在コードでも両方緑になります。

Q5. 冷間再起動後の復旧です。現在ロード済みの `gui/501` job を kickstart するだけで、再起動後の自動ロードを検査していません。
自動ログイン不成立や plist 登録不良なら、電源断後にサーバが戻らず、渡米後は物理復旧できません。
tokens used
24,769
Q1. `REMOTE_RESTART` に `set -e` がなく、戻しの `rsync` 失敗を無視して MARK を消し、混在した木を kickstart します。
`DEPLOYED-REV` だけ先に戻れば、混在コードでも旧版を名乗って verify が緑になります。電源断なら MARK が残り、180秒後に部分復旧木が起動します。

Q2. 7200秒後の処理は「奪取」ではなく同じ錠の `at` を上書きするだけなので、1本目と2本目が同時に走ります。
1本目の `release_lock` は所有者確認なしで2本目の `at` とディレクトリを消し、3本目まで侵入可能にします。

Q3. SSH切断時の remote `EXIT` trap 実行は保証できません。shell が終了処理できれば消え、SIGKILL・電源断なら残ります。
消えれば部分 rsync 中でも起動可能、残れば180秒後に launcher が無視します。また trap は所有権なしで別配備の MARK も消せます。

Q4. 作れます。step 6 の本番向け `rsync` も失敗を無視するため、刻印だけ転送済みの部分更新でも step 7へ進みます。
新プロセスが起動できれば `/healthz` は同じ刻印を返すため、混在コードでも両方緑になります。

Q5. 冷間再起動後の復旧です。現在ロード済みの `gui/501` job を kickstart するだけで、再起動後の自動ロードを検査していません。
自動ログイン不成立や plist 登録不良なら、電源断後にサーバが戻らず、渡米後は物理復旧できません。
```
