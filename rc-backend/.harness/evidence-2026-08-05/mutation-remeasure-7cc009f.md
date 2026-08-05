# 電話側(`ios/`)の変異 13 箇所を HEAD で測り直した記録

- 日付: 2026-08-05
- 測った木: `7cc009f`(電話側の source は `76fbd16` と同一。`76fbd16` が触ったのは計器だけ)
- 走らせ方: 変異は**1本ずつ単独**で植えて `SIM_NAME=iPhone-shots-69 ./tools/build.sh --sim`、
  走行ごとに `git checkout --` で戻す。作業木が汚れていたら植えずに断る。

## なぜ測り直したか

`e6c3acc` は「eval-s2 が生存と報告した3箇所(B / C / F)の穴を塞いだ」と主張していた。
その主張の証拠は **「検査を足した」** であって **「同じ変異が今度は死ぬ」** ではない。
この repo の基準(直しには、それが逆転する事を示す変異が要る)は、直した側にも掛かる。

もう1つ。eval-s2 自身の最終報告に、13 箇所のうち2箇所(L / M)は
**「実測していないので UNVERIFIED」** と書かれていた。母数 13 のうち 11 しか測っていない
一覧を「監査済み」と呼ぶと、残り2つが**測ったふり**の側に混ざる。

## 基準(変異を植えない走行)

| 木 | 計器 | 印字 | 実際 |
|---|---|---|---|
| `7cc009f` | 直す前の `sim-log-summary.sh` | 227件 / 失敗0件 | **230件**(印を行頭で数えていた分、少なく出る) |
| `76fbd16` | 直した後 | **230件 / 失敗0件**(rc=0) | 同左 |

内訳 = 単体 227 + UI 3。基準が緑でない木で変異を測っても、赤が誰の所為か決まらない。

## 13 箇所の判定

「倒れた検査」欄が埋まっている行は、**その検査が現に落ちた**という観測値。
空欄の3行は落ちなかった行で、理由は別に書く。

### 私がこの日に単独で植え直した6箇所

| # | 変異 | 倒れた検査 | 判定 |
|---|---|---|---|
| B | `SessionsClient` `appendingPathComponent("api/sessions")` -> `"api/session"` | `testRequestURLIsApiSessions` | **KILLED** |
| C | 同 `request.httpMethod = "GET"` -> `"POST"` | `testRequestMethodIsGET` | **KILLED** |
| F | `SessionsModels` `String(id.prefix(8))` -> `prefix(7)` | `testDisplayTitleFallsBackToTheIDsFirst8CharactersWhenTitleIsEmpty` | **KILLED** |
| J | 同 `guard let decoded = ... else { return .failure(.malformedBody) }` -> `.unreachable` | `testMalformedBodyIsNotCollapsedIntoUnreachableNegativeControl` / `testStatus200WithUndecodableBodyIsMalformedBodyNotSuccess` | **KILLED** |
| L | 同 `catch let urlError as URLError where .cancelled` の返り値 `.cancelled` -> `.unreachable` | `testCancelledIsNotCollapsedIntoUnreachableNegativeControl` / `testInjectedURLErrorCancelledMapsToCancelledOutcome` / `testRealTaskCancellationMapsToCancelledOutcome` | **KILLED** |
| M | 同 generic `catch` の返り値 `.unreachable` -> `.cancelled` | `testConnectionFailureIsUnreachable` | **KILLED** |

B / C / F = eval-s2 が `d44dcb1` で **生存**と測った3箇所。`e6c3acc` で足した検査が
実際にこの変異を殺す事を、変異を植え直して確認した。

L / M = eval-s2 が **UNVERIFIED**(未実行)としていた2箇所。予測は「検出される」で、
実測もそうなった。予測が当たった事は結論の一部ではない —— 走らせるまでは判定が無かった。

J = eval-s2 が H と**同じ走行**で植えて「0件が倒れた」= 生存に見えた箇所。
単独で植えると2件倒れる。**同じ経路を共有する変異は互いを隠す**という、
eval-s2 自身がその場で書いた教訓の実証になっている。

### eval-s2 の走行から引き継いだ4箇所(私は回していない)

| # | 変異 | 倒れた検査 | 判定 |
|---|---|---|---|
| G | `case 401: return .failure(.unauthorized)` -> `.unreachable` | `testStatus401IsUnauthorized` / `test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl` | KILLED |
| H | `case 200:` -> `case 201:` | `testStatus200DecodesTheRealShapeToSuccess` | KILLED |
| I | `default: return .failure(.unreachable)` -> `.malformedBody` | `testOtherStatusIsUnreachable` | KILLED |
| K | `RouteLabel.Kind(rawValue:) ?? .unknown` -> `?? .tmux` | `testUnrecognizedRouteKindFallsBackToUnknownWithoutFailingDecode` | KILLED |

引き継いだ理由: **殺した変異は自分で証拠を持つ**(倒れた検査の名前が出ている)。
生存の主張は「見えなかった」なので裏取りが要るが、死亡の主張は名指しされた検査が
実際に落ちた記録そのものである。ただし G の 401 は eval-s2 の走行でも単独走行、
H / I / K は3本同時走行だった —— **同時走行の死亡は帰属できるが、同時走行の生存は
帰属できない**(それが J で起きた事)。

### 落ちなかった3箇所(検査の穴ではない)

| # | 変異 | なぜ落ちないか |
|---|---|---|
| D | header field 名 `"Authorization"` -> `"authorization"` | **等価変異**。`setValue(_:forHTTPHeaderField:)` が key を正規化するので、線に乗るバイト列が変わらない。振る舞いが同じ物を検査は区別できないし、するべきでもない |
| E | `guard let http = ... else { return .failure(.unreachable) }` の返り値 -> `.malformedBody` | **到達不能**。`MockURLProtocol.deliver()` は必ず本物の `HTTPURLResponse` を返すので、この `else` に入る道が harness に無い |
| A | `catch is CancellationError` の返り値 `.cancelled` -> `.unreachable` | **この harness からは決定的に踏めない**。今回 L を植えた時に `testRealTaskCancellationMapsToCancelledOutcome` が倒れた事が傍証になる —— 実際の task 取り消しは `URLError.cancelled` として現れており、`CancellationError` の腕は通っていない |

D と E は「検査を足せば殺せる」種類ではない。A は harness を変えれば踏めるかもしれないが、
**踏ませる為だけの検査**は本番の振る舞いを1つも守らない。3件とも穴として数えない。

## 測っている最中に見付けた、これより大きい欠陥

`sim-log-summary.sh` が `Test Case '...' passed/failed` の印を**行頭**で数えていた。
本物の `xcodebuild` は OS の log を**改行を挟まずに**吐くので、印が行の途中に来る。

- 実害の小さい方: 件数が少なく出る(230 -> 227)。
- **実害の大きい方**: 同じ綴りで `failed` も数えているので、**倒れた検査の印が OS log と
  同じ行に乗ると、失敗が0件として数えられる**。その走行は rc!=0 で赤にはなるが、文面は
  「テスト以外の所で落ちている」になり、**倒れた検査の名前を1つも出さない**。
  変異検査では「どの検査が捕まえたか」が成果物なので、これは
  **殺した変異を生存と読む道**である —— つまり、この監査そのものを腐らせ得た欠陥。

直したのが `76fbd16`。対照(`sim-log-summary-control.sh`)が捕まえられなかった理由が
そのまま教訓で、**作り物の log が本物より綺麗**だった(印は必ず行頭に在った)。
⑧(印が行の途中)⑨(始まって終わらない検査)⑨'(skip を消えた検査と誤認しない)を足し、
直す前の版に対して**その3件だけが赤**になる事を確認してある。

受ける側も直した(`6e08a20`)。DoD 2本が `--sim` の 2(測っていない)を赤へ丸めていて、
合計が「未測定を緑に丸めない」と名乗りながら**未測定を赤に丸めて**いた。
併せて、両方の対照が `DOD_FULL=0` でしか回っておらず `build.sh --sim` を呼ぶ分岐を
**43 件の対照が1件も踏んでいなかった**事も塞いだ。

## この記録が間違っているとしたら、どこか

1. **G / H / I / K は私の観測ではない。** 別 session の報告を引き写している。その報告は
   J で1件間違えていた(同時走行の生存を生存と書いた)ので、無条件に信頼できる出所ではない。
   ただし4件とも**死亡**の主張で、死亡は倒れた検査を名指ししている。同型の誤りは起きない。
   疑うなら4件を単独で植え直す —— 1本あたり約4分。
2. **A の「決定的に踏めない」は harness の性質についての主張**であって、本番の
   `CancellationError` が起きないという主張ではない。harness を変えれば覆る。
3. **母数 13 は eval-s2 が選んだ変異点**であって、`SessionsClient` / `SessionsModels` の
   全変異点ではない。ここで言えるのは「選ばれた 13 点のうち 10 点は検査が殺す」まで。
