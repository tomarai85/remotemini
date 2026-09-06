<!-- session: 2026-09-06 11:xx -->

# Progress — `classifyScreen` が agent panel と其の詳細画面を行で見分ける(2026-09-06)

Mode 2 (Quick)。Spec = `.harness/spec-2026-09-06-panel-states.md`。Loop task = `subagent-panel-state-fixtures-landed`。
Generator(worktree)は口座の session limit で起動直後に落ちた(2 回目、回復 14:40 CDT)ので、主セッションが
実装し、Evaluator は Codex(inline)で代替した。

## Milestone 1: 状態 + fixture + 検査 — Done

- `rc-backend/src/inject.mjs`: `panelStateOf(text)`(PANEL = `Background` + 節の見出し + 繋いだ footer / DETAIL =
  `<型> › <説明>` + `tokens` の数の行 + `Progress|Prompt` + `← to go back` の footer)、`overlayOf(state)`
  (線の形: panel の 2 状態は `UNKNOWN` + `overlay`)、`classifyScreen` は menu → **panel → composer** の順。
  `#typeLiteralGuarded` は `panel` / `detail` で断る。`#sendExclusive` は `s0.state.toLowerCase()` のままで同じ語になる。
- `rc-backend/src/server.mjs`: `screenOf` が `overlayOf` を通す(`screen` は UNKNOWN のまま、`overlay` が足される)。
  `SEND_REFUSAL` に `panel` / `detail`(閉じ方まで書いた文)。
- `rc-backend/test/fixtures/panel/`: 両機の画面 10 枚 + README(口座のメール無し、手で編集しない)。
- `rc-backend/test/inject-panel-state.test.mjs` 10 本: PANEL/DETAIL の陽性、閉じた・走行中の陰性を固定、echo 行が
  在っても SENDABLE と読まない、80 桁の footer 2 行目を消すと PANEL でなくなる(繋ぎを測る)、Background だけ /
  節だけでは PANEL にならない、`overlayOf` の線の形、注入器が打鍵 0 で断る(send と typeLiteralExclusive の両経路)。

## 仕様からの意図的なずれ(2 点、理由つき)

1. **状態名 `PANEL_DETAIL` → `DETAIL`**。`send-refusal-vocabulary.test.mjs` は `@returns` の状態名を /[A-Z]+/ で
   拾い、小文字にして `SEND_REFUSAL` の鍵(/[a-z][a-z-]*/)と 1:1 に照合する。下線の入る名前は其の台帳が名指し
   できない。台帳を緩める代わりに名前を合わせた。
2. **断りの語 `panel-open` → `panel` / `detail`**。同じ理由(状態名の小文字 = 断りの語、が台帳の規則)。

## 台帳が止めた所

- `wire-vocabulary-agreement`: `PANEL` / `DETAIL` を「サーバにしか無い語」として理由つきで登録(線には
  `overlayOf` の言い換えしか出ない)。

## 観測

desk suite 1355/1355(+10)/ inject.test + inject-serial + send-refusal-vocabulary 全緑 / wire 台帳と wire-shape・
wire-key の対照は commit 前の走行を gate が再確認。Codex(inline)の所見は commit 前に取り込む(下の追記)。

## 追記 — Codex(inline、fixture 込み)の所見を取り込んだ

FAIL(`.harness/evidence-2026-09-06/codex-panel-review.md`)。1 点目「`overlayOf` が二重定義」は私のプロンプトが
同じ関数を 2 回貼った跡で、木では 1 回(検査で確認)。残りは全部本物:
- **画面全体から語を拾うと、転写に panel の文が引用されただけの画面を PANEL と読んで本物の composer を隠す**
  (= 9/5 の「正常まで断る」の型)。両機の fixture 10 枚を見ると overlay の画面には `▔▔▔` の区切りが必ず 1 本、
  閉じた・走行中の画面には 0 本。だから**最後の区切りより下だけ**を見て、其の下に composer が在れば overlay
  ではないと読む。先行する引用(区切り込み)/ 詳細画面の引用 / 先行する `Background` の 3 つを検査に足した。
- 節の見出しを 7 行の窓で探していた(scroll hint と `Team:` の塊で偽陰性)→ 区切りの下なら何行目でも可。
検査 10 → 15。

## 未着手(理由)

- 5 行の上限と scroll hint(`↓ N more`)、`Team:` の塊: fixture が無い(測定は最大 3 行)。設計文の「次の fixture」。
- 詳細画面の Prompt が空の場合: 未観測。
