# 検査記録 — 二次レビュー由来の2規約(2026-08-01)

対象コミット: `8d403b9` 「二次レビューの2件を直す: BUSY を行単位に絞り、古い登録でワーカーを起こさない」
実行機: MBP(Jervis)、Node 22。

## 何を確かめたか

回帰スイートが緑であることは「壊していない」証拠であって「新しい規約が効いている」証拠ではない。
そこで**新規約を1つずつ壊し、狙った検査だけが赤くなるか**を見た(負の対照)。
対照が落ちない検査は、その規約を守っていない。

## 対照1 — BUSY の行単位判定を、元の「語の出現だけ」に緩める

```js
// 戻した内容
- for (const line of text.split("\n")) { ... SPINNER.test(line) || /·\s*esc to interrupt/ ... }
+ if (/esc to interrupt/i.test(text)) return "BUSY";
```

結果: `# tests 74 / pass 72 / fail 2`

```
not ok 5 - ★「esc to interrupt」が**文章として**画面に残っているだけなら BUSY にしない
not ok 6 - ★スピナー記号が折り返しで消えても、中黒区切りが残っていれば BUSY と読む
```

狙った2件だけが落ちた。他の72件は緑のまま = 判定の**形**に当たっており、たまたま通っていた
文字列に当たっているのではない。

## 対照2 — `livePaneNearby()` を常に false にする

```js
- if (!cwd) return false;
+ return false; // MUTANT
```

結果: `# tests 74 / pass 72 / fail 2`

```
not ok 34 - ★登録時のペインが消えたが、同じ cwd に名乗っていない claude が居る -> ワーカーを起こさない
not ok 37 - ★シェルに戻っていて、かつ同じ cwd に名乗っていない claude が居る -> ワーカーも起こさない
```

両方とも `reason` が `unregistered` から `none` / `not-claude` に戻る = **ワーカーが起きる経路**。
これがそのまま lost-update の入口なので、対照は事故そのものを再現している。

## 復元後

`git status --porcelain` = 空、`# tests 74 / pass 74 / fail 0`、E2E `pass=70 fail=0`。

## この検査で**捕まえられない**もの(正直に残す)

- 実機の画面の変種。BUSY の形は Claude Code の TUI 次第で、fixture は実測を写したものだけが
  証拠になる(2026-07-31 に一度、自分の誤解を写した fixture で緑にしている)。
- 注入キューの永続性。プロセスメモリにしか無いので、サーバ再起動は単体でも E2E でも見ていない。
  既知の穴として DESIGN.md に記載済み。
- 同時実行(電話とターミナルから同時に送る)。単一プロセス内の逐次呼び出ししか測っていない。
