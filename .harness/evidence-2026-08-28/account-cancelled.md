# 口座の欄が「Cancelled」を出していた (2026-08-28)

## 症状(Reviewer が経路まで特定)

読み込み中の口座の欄を叩いて設定画面を開き、一覧へ戻ると、
**口座名の代わりに橙色の「Cancelled」**が残る。次に読み直しが成功するまで消えない。

## 欠陥

`AccountViewModel.swift` の `select()` と `advance()` は `.failure(.cancelled)` を
「見せる価値のある失敗ではない」と明示して畳んでいた:

```swift
case .failure(.cancelled):
    // Not an error worth showing: re-read and let the truth win.
    await load()
```

ところが `load()` が通る `apply()` にだけ其の分岐が無く、総括の枝へ落ちていた:

```swift
case .failure(let error):
    phase = .failed(reason: Self.message(for: error))   // → "Cancelled"
```

`message(for: .cancelled)` は文字列 `"Cancelled"` を返し、`AccountBar` の
`.failed` は**見える橙色の Text** として描く。書いた人は此の場合を畳む必要が在ると
知っていた —— 3 箇所の呼び手のうち **2 箇所にしか配線していなかった**。

## 誰が切っているのか

`load()` の `guard mine == generation else { return }` では防げない。
あれが捨てるのは**新しい操作に追い越された**結果で、此処は追い越しが無い
(世代が進まない)まま自分の Task が切られた場合。

`AccountBar` の `.task { await load() }` は設定画面を押し開ける `NavigationLink` の
上に載っている。だから**其の口を叩く事其れ自体**が飛んでいる読み取りを切る。
`BackendSession.interactiveTimeout` は 20 秒、初回の TLS の握手だけで実測 6030ms ——
初回起動で叩けば普通に間に合う。

## 直し

`apply()` に `.cancelled` を足し、**何もしない**:
- 読めていたなら其の一覧が残る(古いが真)
- 一度も読めていないなら `.loading` のまま。画面が戻れば `.task` が必ずもう一度走るので自分で治る
- `await load()` を此処から呼ばない —— 切られ続ける状況で無限に往復させない

## 実演した赤(直す前)

`testACancelledLoadDoesNotReplaceTheAccountNameWithAFailure`:
```
XCTAssertEqual failed: ("nil") is not equal to ("Optional("team")")
  - 途中で切れただけの読み取りが、読めていた口座名を消した
XCTAssertEqual failed: ("failed(reason: "Cancelled")") is not equal to ("loaded(...current: "team"...)")
```
`testACancelledFirstLoadStaysLoadingInsteadOfShowingAFailure`:
```
XCTAssertEqual failed: ("failed(reason: "Cancelled")") is not equal to ("loading")
  - 一度も読めていない切断が .failed になった = 初回起動で橙が出る
```

直した後: `Executed 26 tests, with 0 failures`。

検査は3本足した。3本目 `testARealFailureStillReachesTheScreen` は**対の検査**で、
`.cancelled` を畳む変更が本物の到達不能まで飲み込んでいない事を測る ——
無いと「全部 `.loading` のまま置く」でも上の2本が緑になる。

負の対照は**新しい file を作らず** `ios/tools/account-ui-control.sh` に A9 として足した。
あの対照は既に `AccountViewModel.swift` を守備範囲に宣言していて、別 file を作れば
守りが二重化して片方が黙って古びる(此の repo が何度も踏んでいる形)。

## 併せて測れた事: 中断は「Tom が叩いた時」だけではない

本番のログ(friday、`client=app` 179 件)を経路別に数えた:

| 経路 | 200 | 中断(code=0) |
|---|---|---|
| `/api/sessions` | 80 | **0** |
| `/api/account` | 50 | **30(37.5%)** |

一覧は一度も中断されず、口座だけが 3 回に 1 回以上中断されている。
しかも `ms=0` の中断が混じる = **投げた瞬間に捨てている**。
「使う人が設定を叩いた」では此の頻度と非対称は説明できない。

★機序は**まだ観測していないので書かない**。仮説は「`ToolbarItem` の中身を
SwiftUI が作り直す度に `.task` が切れて張り直される」だが、確かめていない。
決着させる実験(安い): UI 検査で一覧を出すだけ・一切触らない走行を作り、
差し替えた reader の `current()` が**何回呼ばれるか**を数える。2 回なら仮説は正しい。

★此の中断は画面の問題が消えた後も**机の無駄**として残る。中断された要求でも
`/api/account` の handler は走り、`readFleetAccount` が子プロセスを起こす
(実測 142-156ms)。30 回分は捨てる為だけに起こした子プロセス。

★注意: `client=app` の分類には**私の検査走行も混ざっている**。probe の分類を
足したのが 2026-08-27 で、其れ以前の app 印は電話と検査を区別できない
(20:04-20:21 の 401/404 の poll は私の否定対照そのもの)。
上の比率は其れを承知の上で読む —— 但し `/api/sessions` と `/api/account` の
**非対称**は、同じ走行が両方を叩いている以上、混入では説明できない。
