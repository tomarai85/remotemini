# check 2026-08-05-5 — 緑の commit 門を、緑の対照電池と読み違えた

対象: commit A で入った `rc-backend/test/request-shape.test.mjs` が部分木で赤くなる件と、
その修正 (`request-shape.test.mjs` / `prove-control-controls.sh`)。

## 何が起きたか

commit A は `commit-suite-gate: 単体 673/673 緑` を根拠に landing した。
その根拠は**生きた木**で採った物で、commit の後に対照電池を回すと:

```
RUN-CONTROLS: green=41 red=3 未測定=1  (対象 45本、edith専用2本は除外)
  赤: prove-control-controls.sh mutation-freeze-controls.sh copied-tree-controls.sh
  未測定(緑ではない): mutation-verdict-controls.sh
```

赤3のうち2本 (`copied-tree` / `mutation-freeze`) は commit A 由来、
1本 (`prove-control`) は同じ日の未 commit 変更由来。
**「3本とも commit A のせい」と最初に書いたのは誤り**で、内訳は 2 + 1。

## 根本原因 — 門と電池は別の問いを見ている

| | 見る物 | 見えない物 |
|---|---|---|
| commit の門 | 生きた木で単体が緑か | 木を**写して**回す道が壊れていないか |
| 対照の電池 | 各対照が今も見分けているか | (回さなければ何も) |

`copied-tree-controls.sh` と変異走行は `rc-backend/` **だけ**を写す
(`rsync -a --exclude node_modules --exclude .git "$ROOT/" "$DST/"`; 兄弟の `ios/` は写さない)。
`request-shape.test.mjs` は `ios/` を読むので、生きた木で緑・写しで赤。
そして写しが赤だと**変異走行そのものが起動できない** = 一番強い対照が丸ごと死ぬ。

## 直し方 — 先例をそのまま使った

`test/session-guard.test.mjs` が既に同じ判断を持っていた: 木が居ない時は赤でなく
**名指しの「測っていない」**へ倒す。同じ形を4つの検査に入れた。

副次の学び2つ:

1. **「木が無い」と「木は在るのに走査が何も拾わない」を1つの籠に入れない。**
   前者は測る対象がそこに無いだけ、後者は守っているつもりの物が守られていない。
   test 3 (`client ごとに、対になる検査 file が在る`) は木が無いと `CLIENTS` が空 →
   `missing` も空 → **黙って緑**。空振りの緑は「全 client 合格」と見分けが付かないので、
   赤でも緑でもなく名指しの skip を出させる。
2. **範囲を fail-closed に導出すると、砂場の全 fixture が本物の門を要る。**
   `prove-all-controls.sh` が探す範囲を `staged-controls-gate.sh` の `SCAN_SPECS` から
   取り出す形にした結果、門を持たない `prove-control-controls.sh` の砂場では範囲が空 →
   rc=2 で正しく止まった。道具は設計通り、砂場が古い前提のままだった。
   砂場へは**本物の門を複製**する (手で合成しない理由 = `run-controls-controls.sh` R24-R28:
   書式が変わった時、合成側だけが古い形へ緑を返し続ける)。

## 見分けている事の確認 (= 対照が対照である証明)

| 木 | skip 行 | assert |
|---|---|---|
| 本物 | 0 | 5項目とも実際に走る |
| 合成した部分木 (`RC_REQUEST_SHAPE_REPO` 継ぎ目) | 4 (名指し) | 純関数の陰性対照だけが走る・`fail 0` |

「部分木でも緑」だけを見たら、中身が空でも同じ緑が出る。**反転を数えた**。

## 対照 (Mode 0 closing artifact)

```
RUN-CONTROLS: green=45 red=0 未測定=0  (対象 45本、edith専用2本は除外)
  copied-tree-controls.sh        13s  pass=3 fail=0
  run-controls-controls.sh       11s  PASS 31 / FAIL 0
  mutation-freeze-controls.sh   171s  pass=6 fail=0
  mutation-verdict-controls.sh  176s  pass=27 fail=0
```

対象本数が 44 → 45 に増えているのは `prove-all-scope-controls.sh` が登録された事の確認。

## 持ち越し (この commit では直さない)

`tools/pre-commit-gates.sh` の範囲 filter は依然手書きで、`SCAN_SPECS` とは**別の問い**に
答えている (門は「宣言と実体が一致するか」、pre-commit は「今 commit する物が何か」)。
機械的な copy 除去では統一できない。
