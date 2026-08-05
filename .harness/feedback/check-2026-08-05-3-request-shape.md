# 2026-08-05 — 変異監査が出した「生存6本」の検算と、その裏に在った5件目の同じ形

対象: `ios/Sources/Core/*Client.swift` とその検査。契機は別セッション(`eval-s2`)の
変異監査で、`d44dcb1`(Sprint 2 の code)へ単点変異を植えて回した結果の報告。

## 受け取った報告と、額面で受け取らなかった理由

報告は「生存6本、いずれも検査が捕まえていない」。6本を1つの結論で括っているのが
引っ掛かった —— 生存には少なくとも3種類あって、直し方が全部違う。

1. 検査が書かれていない(= 書けば捕まる)
2. 捕まえるべき差が**存在しない**(= 等価変異。書くと害になる)
3. fixture / 本番のどちらからも到達しない(= 書く価値が無い)

括ったまま渡すと、次に読む人が 2 と 3 にも検査を書きに行く。

## 検算の結果

| 変異 | 生存の真因(実測) | 分類 |
|---|---|---|
| B `api/sessions` → `api/session` | `SessionsClientTests` が `requestedURLs` を **0回**読む。`HistoryClientTests` は 1回、`PollClientTests` は 3回読む | **本物の穴** |
| C `httpMethod` `"GET"` → `"POST"` | `MockURLProtocol` が method の**記録欄を持たない**。全 client 共通 | **本物の穴・範囲は報告より広い** |
| F `displayTitle` `prefix(8)` → `prefix(7)` | どの検査も `displayTitle` を読まない(参照は `ListView` の描画2箇所のみ) | **本物の穴** |
| D `"Authorization"` → `"authorization"` | Foundation が正規化する | **等価変異** |
| E `HTTPURLResponse` guard の else | Mock の応答生成口は1箇所で必ず `HTTPURLResponse`。本番でも http(s) には常に来る | **到達不能** |
| A `CancellationError` 節の返り値 | 検査自身の注釈が「この harness では決定的に強制できない」と明記 | 既知の非決定 |

D は推測で片付けずに測った。`swiftc` で 10 行:

```
URLRequest.setValue("Bearer k", forHTTPHeaderField: "authorization")
→ allHTTPHeaderFields の key は ["Authorization"]
→ 小文字 "authorization" では引けない (nil)
```

source をどちらの綴りで書いても線の上に出るバイトは同一。`SessionsClientTests` は現に
header を見ているのに赤くならなかったのは、**捕まえるべき差が無かった**から。ここに
検査を足させていたら、存在しない区別を固定する検査が1本増えていた。

内訳は `生存 6` ではなく **`本物の穴 3 / 等価変異 1 / 到達不能 1 / 既知の非決定 1`**。

## 裏に在った物 —— 今夜5件目の同じ形

穴を3つ埋めれば済む話ではなかった。`requestedURLs` を読む回数を client ごとに数えると:

| client | `requestedURLs` | `lastRequestHeaders` |
|---|---|---|
| `HealthzClient` | **0** | **0** |
| `HistoryClient` | 1 | 1 |
| `PollClient` | 3 | 1 |
| `SessionsClient` | **0** | 1 |

History と Poll は見ていて、Sessions と Healthz は見ていない。**規約は既に在って、
守るかどうかが client ごとの手書きだった**。今夜これで5回目 —— 検査の届く範囲が、
守られる側の木から導出されず、人の手で書かれた一覧に依存している形。

そして数えて初めて `HealthzClient` が出てきた。監査も私も client は3本だと思っていた。
**手書きの一覧が実在と食い違う事を、手書きの一覧を読んでいる限り発見できない。**

## 直す層

足りない検査を書くのは小さい方の半分。`rc-backend/test/request-shape.test.mjs`
(未 landing、下記)は一覧を1つも持たない:

- 対象 = `ios/Sources/Core/*Client.swift` を全部列挙
- 次元 = `MockURLProtocol` の `static var` のうち綴りが `requested…` / `lastRequest…`
  の物を全部列挙
- 規則 = 各 client の検査 file がその次元を**全部**読んでいる事
- 例外は名前と理由を書いた一覧のみ(今は空。空のまま置くのは「例外が無い」を
  書き残す為で、要る日に理由を書く以外の道を残さない為)

client を足した人も記録欄を足した人も、書き忘れた瞬間に赤が出る。**method の記録欄が
足された瞬間、4本全部がその次元を読んでいるかを問われる側に回る**のが要点で、
これは今の一覧に method が載っていない事を検査自身が知らなくても成り立つ。

期待値までは強制しない。「Authorization が付く事」ではなく「header を**見ている事**」
だけを見る。healthz が認証を付けない口なら、正しい検査は「付いていない事」を見る =
どちらにせよ記録欄を読む。値を決め打つと、上の D と同じ罠を検査の側に作る事になる。

## 現状(閉じていない)

未 landing の状態で本物の木へ回した結果:

```
HealthzClient: lastRequestHeaders, requestedURLs
SessionsClient: requestedURLs
```

陰性対照(5本目)は緑 —— 読んでいない次元は名指しし、片方だけ読んでいれば残りだけを
出し、両方読んでいれば空を返し、免除は client を跨がない。

**`rc-backend/test/` にはまだ置いていない。** 置けば `npm test` が赤になり、commit の門が
全部止まる。門を緩めて先に入れるのは、自分が詰まった時に基準を下げる形なので採らない
(`doc-linerefs.test.mjs` が同じ理由で隣の検査を狭めるのを断っている)。検査は無傷のまま、
**入る順番だけ**を修正と同じ commit に合わせる。

修正は `gen-s4` へ出した。範囲: Mock に method の記録欄を足す(綴りは `requested…`)、
client 4本の検査を全次元へ揃える、`displayTitle` に検査を書く。D と E には
**検査を足さない**事を理由付きで指示済み(黙って落とすと見落としに見えるので、
判断として `progress.md` に残させる)。
