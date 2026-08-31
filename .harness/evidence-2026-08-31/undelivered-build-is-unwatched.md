# 「出来ているのに配っていない」を見ている物が居ない(2026-08-31 実測)

## 主張

`ota-freshness-check.sh` の **rc=3**(配布は承認に追いついているが、**承認そのものが HEAD より
古い** = 出来ている物がまだ配る対象になっていない)を、**定期に撃つ物が木に1つも無い**。
撃つのは2つだけ:

1. `ios/tools/adhoc-ota.sh` の step 7 —— **配る時**にしか走らない
2. 人が手で撃つ時

つまり「配った直後は必ず緑、その後どれだけ離れても誰も言わない」。

## 之が今まさに起きている

| 何 | 値 | 出所 |
|---|---|---|
| 配布中(friday の manifest) | **105** | `ssh athenas PlistBuddy … manifest.plist` |
| 承認済み(`.ota-approved-build`) | **105** | 手元の記録 |
| HEAD から焼くと | **114+** | `ios/tools/build.sh --print-build-num` |
| Tom の電話 | **≤96**(配布口へ一度も取りに来ていない) | 要求ログに OTA への `client=app` が 0 本 |

08-29 以降の作業(CF-11 の UI 4件・CF-14 の壊れた口座・CF-15 の帯・今日の5件)は
**どれも彼の電話に載る経路に無い**。之は CF-11 で踏んだ形そのもの ——
「私が思い出して言う」しか伝える道が無い状態。

## なぜ既存の機構では届かないか

`health-observer.sh` は `OTA_UNDELIVERED_GRACE`(既定 172800 秒 = 2日)を持っており、
**「出来ているのに配っていない」を鳴らす設計は既に在る**。しかし:

- `health-observer` が常設で走っているのは **friday だけ**
  (`com.fleet.rc-health-observer`、`~/rc-observer/tools/health-observer.sh`、600 秒毎)
- friday では `observer.conf:56-57` が `--local` を渡す
- `--local` は**自分でそう言っている**:
  「★局所では**承認が HEAD に追いついているか**は測っていない(木が要る = Jervis の担当)」
- Jervis に常設で走っている RemoteMini の見張りは `com.tomtim.rc-tunnel-observer` **1本だけ**で、
  其の中身はトンネルの生死 + `parity_observe`(2026-08-31 新設)。**鮮度は見ていない**
  (`launchctl list | grep rc-` = 1 本、`~/Library/LaunchAgents/*.plist` に
   `ota-freshness-check` の言及 0 件、`tunnel-observer.sh` に `ota` の語 0 件)

木は「其れは Jervis の担当」と書き、Jervis には其の担当が居ない。**責任の受け渡しが
片側だけ実装されている**形。

## 検証で潰した誤りの仮説(記録)

- ❌「friday の観測器は存在しない台本を指している」
  → `OTA_CHECK` の既定は `$ROOT/tools/ota-freshness-check.sh`(= `~/rc-observer/…`)で、
    其処に file は無い。**しかし** `observer.conf:56` が
    `$HOME/rc-backend/tools/ota-freshness-check.sh` を明示しており、既定には落ちない。
    状態 file `health-state.json.ota-seen` = `1788129538 ok 0 1 0 1788129538`
    (08-30 17:38 に測って `ok`)。**穴ではない**。
- ❌「配備が観測器の木へ届いていない」
  → friday の `~/rc-backend/tools/ota-freshness-check.sh` は今日の版(見出しが一致)。
    `--local` を実際に撃って `rc=0`「配布 105 >= 承認済み 105」。

## 直し方の形(CF-22 / CF-23 の判断を延長する)

**2本目の見張りは建てない。** `com.tomtim.rc-tunnel-observer` に `parity_observe` と同じ形で
枝を足す —— あれは既に「自分の回線が落ちている時は黙る」判断を持ち、Jervis は実測で
半分の時間オフライン。判断を2箇所に持つと片方だけ直る日が来る。

満たすべき性質(`parity-observer.sh` で既に踏んだ穴を繰り返さない):

1. 自分の回線が落ちている/判らない時は**測らず何も書かない**
2. `unmeasured` の回で**時計を進めない**(進めると半分オフラインの機体では期待間隔が倍)
3. 照合の状態(ok/undelivered)と**観測可能性**(fresh/stale)を別に持つ
4. **状態が変わった時だけ**鳴らす。開発中は rc=3 が殆ど常に真なので、
   常時鳴る警報にすると読まれなくなる → `OTA_UNDELIVERED_GRACE` と同じ猶予を跨いだ時に1回
5. 呼び出しは本体の `if [ "$st" = up ]; then … exit 0; fi` より**前**
   (2026-08-31 に此処で1度踏んだ)
6. 上限つきで走らせる(`run_bounded`)。中で ssh を張るので相手が黙ると返らない
