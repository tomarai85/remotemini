# body の記録欄が効いている事 —— 変異を植えて赤を一度見た(2026-08-05)

Sprint 5 ブリーフ §3-a の 3 本目:

> body の記録欄が**効いている**事: 本文を変える変異を1つ植えて、検査が赤くなる事を
> 一度実際に見る(§0-c ⑦-1)。**緑を数えても記録欄の生死は分からない。**

他の 3 本(`display` 握り潰し / 404 の 2 つの `code` / `keepText` の見分け)は
検査文そのものが対照になっているので緑で足りる。この 1 本だけは
「検査が赤くなるのを見る」以外に確かめる方法が無いので、実際に壊して測った。

## 1. 植えた変異

`ios/Sources/Core/SendClient.swift` の要求本文の構造体だけを書き換える:

```swift
    private struct RequestBody: Encodable {
        let text: String
        enum CodingKeys: String, CodingKey { case text = "message" }   // ← 足した1行
    }
```

線に出る形が `{"text":"…"}` から `{"message":"…"}` へ変わる。
**送るか送らないかは変えていない** —— 変えたのは本文の中身だけ。
記録欄が死んでいれば(= 記録が常に `nil`、あるいは記録はするが誰も読まない)、
この変異は 290 本すべてを緑のまま通り抜ける。

## 2. 走らせた物と結果

`ios/tools/build.sh --sim`(headless、GUI は開かない)。

| 木 | 結果 |
|---|---|
| 変異前(基準) | **テスト 290件 実行 / 失敗 0件** |
| 変異後 | **テスト 290件 実行 / 失敗 2件** |
| 変異を戻した後 | ソースは `git status` 清潔(`git checkout --` で復帰) |

赤くなった 2 本は、`xcodebuild` の出力から逐語で
(★`file:行` の前置きは**落としてある** —— 行番号は動くので錨にならない。
錨は検査名と、下に写した `assert` 式そのもの):

```
error: -[SendClientTests
  testRequestIsAPOSTToTheMessagesPathWithTheBearerKeyAndTheTextAsJSON] :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional("こんにちは")")

error: -[SendClientTests testTextIsSentUntrimmed] :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional("  padded  ")")
```

落ちたのはどちらも `XCTAssertEqual(decoded?["text"], …)` の行。
`"message"` へ改名した結果 `["text"]` が引けず `nil` になった = **記録欄を通って
値が届いており、その値が本当に判定に効いている**。

## 3. ★赤が 2 本に**絞られた**事が本体

288 本は緑のまま。つまりこの対照は
「何かを壊すと何かが赤くなる」ではなく **body の次元だけを見ている検査が
body の変異にだけ反応した**、を示している。全体が赤くなる変異(例えば送信自体を
消す)では、記録欄が生きている証拠にならない —— 別の次元の検査が拾っただけかもしれない。

## 4. ★同じ file の中に既に在った「負の対照」は、この変異を**素通しした**

`SendClientTests.swift` には元から
`testTwoDifferentTextsProduceTwoDifferentRecordedBodiesNegativeControl` が在り、
「2 つの違う本文が 2 つの違う記録を作る」を主張している。
これは**この変異では赤くならない**(失敗した 2 本に入っていない)。当然で、
`{"message":"first"}` と `{"message":"second"}` は依然として非 nil で互いに異なる。

- あの対照が測っているのは **記録器が動いているか**(`httpBody` を読んで常に `nil` を
  記録する版を殺す為に書いた)。
- 今回の変異が測っているのは **鍵の名前が判定に縛られているか**。

同じ「負の対照」という名前でも**測っている性質が違う**。
検査文の中に置ける対照は前者まで。後者は木を一度壊す以外に取れない。
——「対照が在る」で安心すると、対照が答えていない次元がそのまま残る。

## 5. 一般化 —— 相対の性質は改名を素通しする

検査文の中に書ける対照が主張できるのは、多くの場合**相対の性質**である:
「入力を変えたら記録も変わる」。相対の性質は鍵の改名で壊れない ——
`{"message":"first"}` と `{"message":"second"}` は依然として互いに異なるからだ。

一方、線に何が乗るかは**絶対の性質**である:「鍵は `text` であって `message` ではない」。
これを縛っているのは `decoded?["text"]` と書いた 2 行だけで、その 2 行が本当に
縛れているかは、鍵を改名して赤くなるのを見る以外に確かめようが無い
(`JSONDecoder().decode([String: String].self, …)` は `{"message":…}` でも**成功する** ——
落ちるのは索引の側)。

**器具の健全性は器具の外から測る。** 同じ形は `port-coverage.py` が構造入力を
機械照合できない件(13/13 が「機械では突き合わせられない」)にも出ている。

## 6. DoD への効き / 測っていない事

ブリーフ §5 の 1 行目「`SendClient` が `POST` / 正しい path / `Authorization` /
`{text}` body を出す(**4 次元とも記録欄で観測**)」の、**body 次元**の裏付けがこれ。

★残り 3 次元(method / path / header)には**同種の変異を植えていない**。
ブリーフ §3-a が名指ししたのが body だけなのでそれに従った。
3 次元とも同じ検査の中で `requestedURLs.last?.path` / `requestedMethods.last` /
`lastRequestHeaders?["Authorization"]` / `…["Content-Type"]` を等値で見ているが、
「その等値が本当に効いているか」は今回**測っていない** = 未測定として残す。
