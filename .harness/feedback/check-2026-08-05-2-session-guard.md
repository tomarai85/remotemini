# check 2026-08-05 #2 — Sprint 1 の Evaluator が出した積み残し2件 + 道具の欠陥1件

対象 = `.harness/feedback/sprint-1.md` の Finding 1(Minor)と UNVERIFIED 2件のうち自分で測れる方。
Mode 0(main session が実装 → 対照で殺しに行く)。

---

## 1. Finding 1 — 「守られたセッション」が制約でなく既定値だった

### 指摘の中身

`HealthzClient` / `SessionsAuthProbe` はどちらも

```swift
init(session: URLSession = BackendSession.shared.session)
```

という形だった。既定値は守られたセッション(`RedirectRefusingDelegate` 付き)だが、
**呼ぶ側が素の `URLSession` を渡せば N5(3xx を追わない)は黙って消える**。
しかも実際にそう渡していたのは Sprint 1 のテスト自身で、`MockURLProtocol.makeSession()` が
delegate 無しのセッションを返していた。結果:

| 何が緑だったか | 何を測っていたか |
|---|---|
| `RedirectRefusalTests` 4本 | `BackendSession` **が** delegate を付ける事 |
| `HealthzClientTests` / `SessionsAuthProbeTests` 16本 | client の判定ロジック(delegate **無し**のセッション越し) |

両方緑で、その隙間 —— 「production の client が転送を拒否する道を実際に通る」 —— は
一度も踏まれていない。**緑が2つ在る事は、その間が繋がっている証拠にならない。**

### Evaluator の案を2つとも採らなかった理由

- **案(a)「production の init から注入を外し `@testable` 専用の注入口を足す」= Swift では成立しない。**
  このアプリは単一モジュールで宣言は全部 `internal`。`@testable import` で見える範囲と
  production から見える範囲が**同一**なので、「テストだけが通れる口」という物が作れない。
- **案(b)「3xx を end-to-end で拒否する統合テスト1本」= 穴が閉じない。**
  今の client が拒否する事は示せるが、将来の呼び出し口が素のセッションを渡す道はそのまま残る。
  加えて `RedirectRefusalTests` の冒頭が「`URLProtocol` 越しに 3xx を駆動するのは
  この Foundation 版に固有の未文書挙動なので依存しない」と理由付きで書いてあり、
  それを黙って覆す形になる。

### 採った形 — 型で縛る

`BackendSession` の初期化子は **configuration しか取らない**(delegate は自分で付ける)。
client の引数の型をこれにした:

```swift
init(session: BackendSession = .shared)
```

これで「`BackendSession` を持っている」事が「その全リクエストで N5 が成立する」証明になる。
コンパイラが、既定値では示唆しかできなかった事を強制する。

副次的に、モックも `BackendSession` を返すようになったので、
**ネットワーク層のテスト16本が本物の delegate 越しに走るようになった** —— 指摘された隙間の実体はここ。

### 対照(型の保証にも対照が要る)

`HealthzClient(session: URLSession(configuration: .ephemeral))` を1箇所に植えて build:

```
Tests/Core/HealthzClientTests.swift:13:45: error:
  cannot convert value of type 'URLSession' to expected argument type 'BackendSession'   (rc=65)
```

→ 直す前は通っていた書き方が、コンパイルで落ちる。植えた物は `git checkout --` で撤去、木は綺麗。

---

## 2. 型だけでは届かない半分 — `test/session-guard.test.mjs`

**①の型は既存の client にしか効かない。** Sprint 2-6 は List / 会話 / poll / 送信 / 割り込みで
それぞれ HTTP を足す。新しい file が `URLSession.shared.data(...)` と直に書けば、
型の制約はその道に一切かからない。**poll と送信は bearer 鍵を載せる**ので、
そこで転送を追うのは N5 が防ぐつもりだった漏洩そのものになる。

規則は1行: **`ios/Sources/` の中で `URLSession` という綴りが出てよい file は
`Core/BackendSession.swift` だけ**(`URLSessionConfiguration` は除く)。
正当に要る日が来たら許可一覧に理由を書いて足す —— その手間がそのまま
「これは意図した抜け道です」という記録になる。

### 対照 `test/session-guard-controls.sh` = PASS 5 / FAIL 0

| | 測った事 | 結果 |
|---|---|---|
| ① | 電話側に違反を1件植えると赤(違反した file を名指し) | PASS |
| ② | 植えなければ緑(①が巻き添えでない) | PASS |
| ③ | 注釈の中の言及では赤くならない | PASS |
| ④ | 電話側の木が居ない部分木では緑 | PASS |
| ⑤ | 錨の file が消えると赤(空振りが緑の下に隠れない) | PASS |

- ③が要る理由: この直し自体が `URLSession` に言及する注釈を増やした。ここが赤いと
  検査が鳴り続け、次の人は**検査の方を弱める** —— 守りが緩む一番よくある経路。
- ④が要る理由: 変異走行は `rc-backend/` だけの部分木で回る。そこで赤い造りだと
  走行中の**全件**が「検出」に化け、素通りが丸ごと隠れる(`no-linerefs-controls.sh` と同じ理由)。
- **④は初回に FAIL した。** 対照が砂場に `ios/Sources` を先に作ってしまい、
  「木が居ない」ではなく「錨が居ない」を測っていた。別の物を測って緑を貰う形。
  対照が自分の段取りの誤りを捕まえた。

`tools/run-controls.sh` の一覧に登録済み(未登録の対照は対照ではない、というこの repo の既決)。

---

## 3. 積み残し UNVERIFIED — `SessionsAuthProbeTests` の殺傷力

Evaluator が予算の都合で「読んだだけ、変異では確かめていない」と書いた項。2本植えて確認:

| 変異 | 殺したテスト | 結果 |
|---|---|---|
| `case 401: return .unreachable` | `testStatus401IsUnauthorized` / `test401And5xxAreNotCollapsedIntoOneOutcomeNegativeControl` | 2件で赤 |
| 状態を見ずに常に `.authorized` | 上記2件 + `testOtherStatusIsUnreachable` | 3件で赤 |

殺傷力あり。両方 `git checkout --` で撤去、`git status --short` 綺麗。

---

## 4. 道具の欠陥 — `build.sh --sim` がコンパイル失敗とテスト失敗を潰していた

Evaluator が本論ではなく方法論の註として書いていた物。`xcodebuild test` は
**コンパイル失敗もテスト失敗も同じ `** TEST FAILED **` と同じ exit 65** で報告する。
`| tail -3` はその2つを見分ける材料を捨てていた。

これは見た目の問題ではない。**変異走行で「殺した」と「そもそもコンパイルが通らなかった」が
区別できなくなる** —— 後者は何も測っていないのに、記録は前者と同じ顔をする。

- exit code 自体は落ちていなかった(`set -euo pipefail` が効いていたので rc は伝わる)。
  最初「`exit 0` で握り潰している」と読んだが、それは誤り。壊れていたのは**出力**だけ。
- 見分ける印は**列番号**: swiftc は `file:line:col: error:`、XCTest は `file:line: error:`。
  この形を持つのはログ中でこの2つだけ。
- **同じ夜に自分でも踏んだ**: 変異走行の集計に `grep -c 'error: '` と手で書いたら、
  XCTest の assertion 行を数えて「compile error 2件」と表示した(実際は 0 件)。
  Evaluator が道具を捨てた理由を、道具を迂回して再現した形。

### 対照 = 3通りを実測

| 植えた物 | 出力 | rc |
|---|---|---|
| 何も | `Executed 55 tests, with 0 failures` | 0 |
| 型の合わない宣言1行 | `ビルドが通っていない(コンパイル error 1件)= テストは1件も測っていない` + 該当行 | 65 |
| `case 401` の潰し | `コンパイルは通り、テストが落ちた` + 落ちたテスト名 | 65 |

全文は `build/xcodebuild-sim.log` に残す(切り詰めない)。

---

## 証拠(この check で実際に走らせた物)

| 何を | 結果 |
|---|---|
| `ios/tools/build.sh --sim` | `Executed 55 tests, with 0 failures`, rc=0 |
| `npm test`(rc-backend) | 654 tests / 0 fail |
| `tools/run-controls.sh` | green=31 red=0 未測定=0 |
| `test/session-guard-controls.sh` | PASS 5 / FAIL 0、植えた物の不在も確認 |
| 型の対照 | 素の `URLSession` を渡すとコンパイル error(rc=65) |
| 変異2本(`SessionsAuthProbe`) | 2件赤 / 3件赤 —— どちらも殺された |

## 積み残し(この check では閉じていない)

- **実機 DoD**(Sprint 1 の残り): `devicectl … --console` で `healthz ok:true pid:<n>` を見る。
  Tom の iPhone が要る。
- N5 を 3xx の**実際の応答**で end-to-end に踏む統合テストは**書いていない**。
  `URLProtocol` 越しの転送駆動が未文書挙動である事(`RedirectRefusalTests` の冒頭)を尊重した。
  代わりに置いたのが型の制約と綴りの検査。**この2つは「拒否する」事の証明ではなく
  「拒否しない道が作れない」事の証明**であり、別物である事は自覚している。
