# 電話側の欠陥掃引(2026-09-08)

机は 9/8 朝に初めて掃いた(`desk-sweep.md`、5 件)。電話は 9/7 に **UI の棚卸し**(見た目と出し方)を
やったが、**欠陥の掃引**は一度も無かった。同じ形で 2 本を独立に走らせた:

| 掃引 | 範囲 |
|---|---|
| state | `ConversationViewModel`(2359 行)・`PollModels`・`BackendSession`・各 Client |
| views | `ConversationView`(2041 行)・`ListView`・`DiffView`・`SettingsView`・`RootView`・`AppState` |

**2 本が独立に、同じ物を最重要として挙げた** —— 危険な確認の行き止まり。範囲も観点も違う 2 本が
同じ所を指したのは、其れが「見て判る」種類の欠陥だという事(推論の一致ではなく、症状の一致)。

---

## 1. 危険な確認が電話から**構造的に**答えられない(両方が HIGH)

`ConversationViewModel.choose(key:)`。`inFlightChoiceKey = key` を「構えるだけ」の枝より**前**に置いていた。
此の印を降ろすのは応答を受ける `applyChoiceAttempt` **だけ**(書き込み箇所を全部当たって確認済み)。
つまり**送らない道では永久に降りない**。

危険な確認(`risk.tier == "danger"`、例: 再帰的な削除)で 1 タップ目を押すと:

- `isChoosing` が立つ → `choiceEnabled` が false → **カードの全ボタンが伏せられる**
- 押した鍵の脇で spinner が回り続ける(送っていないのに)
- 「Sending your choice…」が急ぎの席に居座る
- 「Tap again to confirm」が、**二度と押せないボタン**を指す

3 つの文が互いに矛盾したまま固まる。画面を出入りしても 1 タップ目が同じ所へ戻るので、
**危険な確認には電話から永久に答えられない**。逃げ道は机だけ。

★2026-08-26 に足した「構え」の機能は**検査ゼロ**で出荷されていた(掃引 2 本とも独立に指摘)。
同じ二段構えを `SubagentsViewModel` は検査付きで持っていて、其方には此の穴が無い —— 実装が分岐した。

**直し**: 印は**送ると決まってから**立てる(枝の後ろへ移した)。
規則としては「観測より強い事を言わない」の一例 —— 送っていない物を「送信中」と描かない。
検査 3 本(1 タップ目は行かない・カードは押せるまま / 2 タップ目は確定の指紋を載せて行く /
★否定対照: 危険でないカードは 1 タップで行く)。

## 2. 「名前を変える」「MacBook へ戻す」が押しても何も起きない(views、HIGH)

`ListView` の alert / confirmationDialog が `isPresented` を `renameTarget != nil` から作った
派生 Binding にしていた。button を押すと SwiftUI が閉じる為に `false` を書き戻し、其の setter が
`renameTarget = nil` を実行する。button の action は `Task { … }` を**積むだけ**で本体は次の番に走るので、
其の時には対象が nil —— `guard let target else { return }` で黙って return。
**机の口を一度も叩かない**。alert は閉じるので、成功と画面で見分けが付かない。

★同じ形を `DiffView` が 2026-09-03 に踏んで `presenting:` へ移しており、其の註は
**「`ListView` の rename が同じ形だ」と 2 度名指ししていた**。直しは持って来られていなかった ——
「気付いて書き残す」と「直す」の間に落ちた。

**直し**: `DiffView` と同じ形(`isPresented` は素の Bool、対象は `presenting:`、submit は引数で受ける)。
検査 = `ListRenameUITests`。**断る fixture**(`RC_UI_RENAME_FIXTURE=rejected`)で測る ——
成功する fixture では「呼ばれなかった」と「呼ばれて成功した」が同じ画面になるので、
断らせて「Can't rename」が出るかどうかを口が叩かれた事の観測にする。

---

## 掃引の残り

両方の報告が長くて途中で切れたので、残りの所見(state #2 の `performResync` に世代の守りが無い、
views #3〜#6)は続きを取り寄せて別途処理する。**此処に書いたのは私が自分でコードを当たって確かめた 2 件だけ。**
