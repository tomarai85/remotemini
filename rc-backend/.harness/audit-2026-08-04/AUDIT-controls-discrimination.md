# 対照の判別力 監査(2026-08-04、外部 4 名・読み取り専用)

4 つの独立した監査 session(disc-audit-A / B / C / D、および disc-A / B / D)が
`test/*-controls.sh` と `tools/*-check.sh` 計 17 本を **読み取りのみ**で審査した。
問いは1つ:「この assert は、守っている物が壊れた時に**赤くなるのか**」。

★**この file は記録であって、修正ではない。**2026-08-04 に Tom の指示で作業を止めた時点の
台帳で、下の指摘は**まだ1つも直していない**。直す時はここに結果を追記する。

## なぜ信用してよいか — 首位が2人から独立に出た

`test/mutation-run-live-controls.sh` の判定文の複製を、**互いを知らない A と B が
別々に首位**に挙げた。私が現物で照合した(この session 実測):

```
test/mutation-run-live-controls.sh:18:PAT='[Pp]ython[0-9.]*( +-[^ ]+)* +[^ ]*mutation-controls\.py'
tools/mutation-run-live.sh:35:      PAT='[Pp]ython[0-9.]*( +-[^ ]+)* +[^ ]*mutation-controls\.py'
```

**バイト単位で同一、定義は2箇所だけ、共有元は無い。**

## 首位: 対照が本体を呼ばずに、自分の写しを検査していた

`tools/mutation-run-live.sh` は「今、変異走行が動いているか」の**唯一の判定器**で、
`deploy-to-edith.sh` の配備拒否ゲートが読む。その対照 5 本のうち **4 本が
`bash "$LIVE"` を一度も呼ばず**、上の複製 regex で `pgrep` するだけ。

一番効くのは 3b 本目 —— **2026-08-02 夜に実際に起きた偽陰性**(`-u` 付きの python を
跨げず、変異走行の最中に配備が通った)の再現検査。**その一本が、本体でなく
写しを見ている。**本体側だけが同じ穴に戻っても、この対照は緑のまま。

この file の冒頭コメント自身が「複製された判定は、片方だけ直して片方が腐る」と
書いている。**その教訓が、対照そのものの形で再演されていた** —— `DESIGN.md` §2.33 の
「死んだ計器は自分の下流の欠陥も隠す」の、計器が**自分の複製を見ている**版。

直し方(両監査が同じ案に収束):
1. `PAT` を手書きせず `LIVE` から動的に抜く。同じ手法が既にこの repo に在る
   (`test/mutation-target-controls.sh` の `ALPHA` を本体から抽出する所)。
2. 各シナリオで `matched()` でなく `bash "$LIVE"` を直接呼ぶ。かつ**他の囮を殺してから**
   —— 今は W/E/R/RU が全部同時に生きているので、旗なしの R が常に本物マッチを供給し、
   広すぎ/狭すぎの退行が埋もれる。

## 残りの指摘(重要度順)

| # | 対象 | 指摘 | 重さ |
|---|---|---|---|
| 2 | `tools/rc-backend-launch-check.sh` L/L2/L3/M/M2/M3 | 配備中マークの守りが赤くなる事の根拠が**コメント一行だけ**(「守りを外した写しで駆動して確かめた」)。今の台本にその変異を再現する実行行が無い | 中 |
| 3 | `test/health-observer-controls.sh` §4 | 「会話の情報が載っていない」が `--inject-fail`(固定文字列)しか通らない。**本物の HTTP 応答本文が理由欄に混ざる退行を見る経路が file 全体に無い** | 中 |
| 4 | `test/fork-check-controls.sh` F5 | 既存 dir 保護をソースの**文字列一致**で見ている。「解除は1回きり」の道具が他人の転写を消し得るので、静的止まりは残存リスクが重い | 中 |
| 5 | `test/mutation-freeze-controls.sh` ①(新規) | 85秒の固定 sleep に進捗同期が無い。速い環境では「汚染が間に合わなかっただけ」を「凍結が効いている」と誤読し得る。**未測定(exit 2)を返す経路が無い** | 中(新規なので優先) |
| 6 | `test/limit-lifted-controls.sh` L3 | `<synthetic>` 除外の固有 regression を検出しない(err=1 を渡すので L4 と同じ経路)。判別させるには `<synthetic>` の**成功**行を書く | 低 |
| 7 | `test/fork-check-controls.sh` F6 | `.claude.json` 非接触を静的 grep で見ている。実行前後の mtime 比較へ置換可能 | 低 |
| 8 | `test/example-artifacts-controls.sh` A3 | `xmllint` 不在の環境で当該検査が**無言で消える**。他 3 本が徹底する「測れない事を明示する」が此処だけ欠けている | 低 |
| 9 | `test/example-artifacts-controls.sh` | 差替口 `RC_EXAMPLE_TOOLS_DIR` が「壊した写しを指す口」と明記されているのに、**一度も発火していない**(器は在るが中身が空) | 低 |
| 10 | `test/mutation-target-controls.sh` L50-57 | heredoc の `rc=$?` 未検査。誤診断側に倒れる(見逃しではない) | 極低 |
| 11 | `tools/rc-backend-launch-check.sh` L4 / `test/env-death-controls.sh` の副検査 | exit code だけを見る行が、誘導が効いた事の sanity check であって分類器を測っていない | 極低 |

## 健全と判定された物(捏造しない為に明記)

- `test/pii-controls.sh` —— 監査 A が「model 級」と評価。実 git を建てて本物の git/grep を通し、
  負の対照(守りを外して赤になる事)も揃っている。C4/C14 が「履歴段」と「作業ツリー段」を
  **片方だけ殺して**測っているのが特に良い。
- `test/child-reaping-controls.sh` —— 負の対照が `assert s2 != s` で**置換が当たったか**まで
  検査していて、空振りした場合に「この対照は何も見分けていない」と自己申告する二重の網。
- `test/verify-script-controls.sh` —— 本物の実行で捕獲した cleanup 台本を取り出し、
  守り有り/無しの両方を走らせて `rm -rf` の宛先ガードを実測。
- `test/deploy-dirt-controls.sh` / `test/mutation-verdict-controls.sh` /
  `test/remote-mini-root-controls.sh` / `test/post-gate-batch-controls.sh` /
  `test/gui-run-controls.sh` —— 指摘なし、または軽微な強度指摘のみ。

## 型として持ち帰る物

3 本の監査が別々に同じ形を指している:

> **対照が「本体を呼ぶ」か「本体を写した物を見る」かは、外から読むと区別が付かない。**
> 付くのは、写しが本体から**乖離した時**だけ —— つまり手遅れになった時だけ。

`DESIGN.md` §2.35-a に書いた「空回りは `file` 単位で数える」と同じ層の話で、
そちらが**同じ file 内の支え**を数える話なのに対し、こちらは**対照と本体の間**の話。
道具化する時は両方見る形にする事。
