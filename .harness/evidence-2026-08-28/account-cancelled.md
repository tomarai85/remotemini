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

## 併せて測った事 —— そして**自分の推測を反証した**

本番のログ(friday、`client=app` 179 件)を経路別に数えた:

| 経路 | 200 | 中断(code=0) |
|---|---|---|
| `/api/sessions` | 80 | **0** |
| `/api/account` | 50 | **30(37.5%)** |

一覧は一度も中断されず、口座だけが 3 回に 1 回以上中断されている。此処で私は
「使う人が設定を叩いた程度では此の頻度と非対称を説明できない」と書き、機序の仮説として
「`ToolbarItem` の中身を SwiftUI が作り直す度に `.task` が切れて張り直される」を立てた。

★**実測したら外れていた。** 専用の simulator(`rc-probe`、Tom のドッグフード機とは別に
建てて計測後に削除)へ計測用の `print` を1行入れた版を入れ、**一切触らずに冷起動**した:

```
root flow:normal
RCPROBE account.load fired          ← 1 回だけ
```

同じ窓のサーバ側(冷起動3回、22:21:04 / 22:21:39 / 22:22:32):

```
GET /api/sessions ... code=200 ms=106 / 112 / 181
GET /api/account  ... code=200 ms=1062 / 188 / 269    ← **中断 0 件**
```

toolbar の作り直しは起きていない。普通の起動で中断は**1件も出ない**。

### では 30 件は何だったか

`/api/sessions` は 106ms、`/api/account` は 188〜1062ms(子プロセスを起こすので長い)。
**アプリが途中で殺された時、飛んでいる確率が桁違いに高いのは長い方**。
それだけで非対称は説明が付く —— 欠陥は要らない。

そして 2026-08-27 の 20:04〜22:00 は、私が実機へ `devicectl install` を繰り返し、
その度に走行中のアプリが終了させられていた時間帯そのもの。
`GET /api/sessions` と `GET /api/account` が**同じミリ秒**に始まって後者だけが
`aborted` で終わる行の並びは、其の形と一致する。

★つまり **30 件は製品の不具合の証拠ではなく、私の作業の巻き添え**だった。
`client=app` の分類に検査走行が混ざる事は同じ file に注記していたのに、
其の注記を自分の推論に適用し損ねた —— 「計器は壊れずに嘘をつく。名前が示す集団と
実際に数えている集団がずれる」の型そのもの。

### 直しの正当性は変わらない

`apply()` の `.cancelled` の欠落は**検査で赤を再現して直した**実在の欠陥で、
Reviewer が特定した経路(読み込み中に口座の欄を叩いて設定を開く)も成立する。
変わったのは**頻度の主張**だけ: 「普通の使用で 3 回に 1 回」ではなく
「読み込み中に其の口を叩いた時」。前者は私が数え違えた。

★残る本物の疑問は別に在る: `/api/account` の初回が **1062ms**(此の計測でも再現)。
`readFleetAccount` が子プロセスを起こす分で、一覧(106ms)の 10 倍。
口座の欄は工具帯に在って一覧を塞がないので画面は止まらないが、
**机の仕事としては重い**。此処は次の的にする価値が在る。
