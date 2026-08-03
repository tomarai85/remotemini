# Q3(「監視側が壊れています」に**いつから**を載せる)の対照を、直す前の版で赤にした記録

規則(`tools/run-controls.sh` 冒頭 (2)): **直したら、直す前の版で対照が赤になるか個別に見る。**
赤にならない対照はその欠陥について何も測っていない。

`tools/prove-all-controls.sh` / `prove-control.sh` は**変異走行中は断る**(競るので測らない)。
走行が生きている間に測れないと規則が空文になるので、同じ測定を手で通した記録がこれ。
道具が使える様になった後は `prove-control.sh test/health-observer-controls.sh RC_HEALTH_OBS tools/health-observer.sh`
で同じ事が自動で回る(その為の継ぎ目を今回足した)。

## 1. 何を差し替えたか

| 項 | 値 |
|---|---|
| 対照 | `test/health-observer-controls.sh` |
| 継ぎ目 | `$RC_HEALTH_OBS`(今回追加) |
| 守られている file | `tools/health-observer.sh` |
| 旧版 | `git show HEAD:…/tools/health-observer.sh`(= Q3 を入れる直前) |
| 旧版 sha1 | `5fe8adb64792d1eaeaef9a80c5cc1f226a4e475b` |
| 今の版 sha1 | `dabf481e15f3753d324496e6cd09bb0099687f4f` |
| 旧版との差分 | Q3 の3箇所のみ(`OK_MARK` / `last_worked_phrase()` / KIND 0,10,11 での記録)。他の行は同一 |

## 2. 結果

| 版 | 終了コード | 内訳 |
|---|---|---|
| 今の版 | 0 | pass=116 fail=0 |
| 旧版を差し込む | 1 | pass=107 **fail=9** |

倒れた 9 枚は**全部 §11**(Q3 の節)。§1〜§10 の 107 枚は緑のまま
= 巻き添えで赤くなったのではなく、狙った欠陥だけを見分けている。

倒れた内訳:
- 「最後に監視が働けたのは …」が通知の文面に無い(5 枚。11-b / 11-c / 11-d / 11-f の文面検査)
- `--dry-run` の一行にも無い(1 枚。11-g)
- 記録が進まない(3 枚。11-b の正常回 / 11-e の「落ちました」の回 / 11-e の「戻りました」の回)

旧版でも緑のままだった §11 の行は 11-a の負の対照と 11-f の「記録は進んでいない」。
旧版は記録を**そもそも書かない**ので、この2つは旧版でも真になる —— 見分ける役はしていない。
枚数ではなく役割で読む事(この2枚は「新しい版が数字を捏造しない」側の検査)。

## 3. ★途中で1回、差し替えの方が壊れていた(測定の話)

初稿の継ぎ目は「旧版を砂場へ写して `health-step.mjs` も1枚だけ写す」造りだった。結果:

- fail=**28**。§1 から赤で、通知の文面は全部 `監視側が壊れています(設定か引数が不正)`
- 原因は Q3 ではなく `tools/health-step.mjs` が `../src/health.mjs` を読む事。
  砂場に `src/` が無い → node が import で落ちる → `KIND` が想定外 → 判定へ辿り着く前に赤

**28 枚の赤を「よく効いている対照だ」と読むのが、ここでの誤答**だった。狙った欠陥の対照は
6 枚しかないので、22 枚は理由の違う赤。`prove-control.sh` が
「rc>1 は赤と同じ扱いにしない」と書いているのと同じ罠が、rc=1 の側にも在るという事。
**赤の枚数ではなく赤の理由を見る**。是正 = 砂場に `src` を丸ごと繋いで、差分を守られている
file 1枚に閉じ込めた。

## 4. ついでに見つけた `prove-control.sh` 自身の欠陥

③(どの assertion が倒れたかを名指しする)が `^NG` / `^OK` 決め打ちだった。
`test/health-observer-controls.sh` は行頭を字下げする(`  ok  ` / `  NG  `)ので**1行も読めない**。
その時この道具は「倒れた 0 枚 / 倒れなかった 0 枚」と出しながら、結論だけ
`PROVE: 効いている` と書いていた —— 数える道具が 0/0 を平気で返すのは数えていないのと同じで、
しかも③はこの道具の本体。

- 是正: 型を `^[[:space:]]*(NG|ng|OK|ok)[[:space:]]` へ広げ、**両方 0 なら 2(未測定)で止める**
- 対照: `test/prove-control-controls.sh` に P8 / P8b を追加(行の形が読めない砂場を作る)
- その P8 を直す前の `prove-control.sh` に差して確認: **P8 と P8b だけが赤、P1〜P7 は緑**
  (旧版の出力は文字通り `PROVE: 効いている`)

## 5. 再現手順

```bash
cd rc-backend
git show HEAD:rc-backend/tools/health-observer.sh > /tmp/old-observer.sh
bash test/health-observer-controls.sh                       # 今の版 = 0 / pass=116
RC_HEALTH_OBS=/tmp/old-observer.sh \
  bash test/health-observer-controls.sh                     # 旧版 = 1 / fail=9(全部 §11)

git show HEAD:rc-backend/tools/prove-control.sh > /tmp/old-prove.sh
bash test/prove-control-controls.sh                         # 今の版 = 0 / PASS 9
PROVE_SCRIPT=/tmp/old-prove.sh \
  bash test/prove-control-controls.sh                       # 旧版 = FAIL 2(P8 / P8b)
```

注: 対照の通知文面には `hostname -s` が入る(「どの機械から見た話か」を必ず名乗らせている為)。
手元の機械名は Tom の実名を含むので、**実行結果をそのまま repo へ貼らない事**。
この記録に生の文面を写していないのはその為。
