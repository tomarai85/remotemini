# ローディング表示の文言昇格設計 — 一次資料調査

調査対象: SwiftUI アプリ起動直後の無言 `ProgressView()` を、繋がらない時(クライアント側タイムアウト20秒)に
どう文言付きへ昇格させるべきか。二次情報の孫引きを避け、確認できた一次資料と、確認できなかった事を分けて記す。

---

## 1. 応答待ちの体感に関する古典的閾値 — Jakob Nielsen (原典)

**原典**: Jakob Nielsen, *Usability Engineering* (1993), Chapter 5。Web 版記事:
[Response Times: The 3 Important Limits](https://www.nngroup.com/articles/response-times-3-important-limits/) (NN/G)

Nielsen 自身の記事内の逐語引用:

- **0.1 秒**: "about the limit for having the user feel that the system is reacting instantaneously, meaning that no special feedback is necessary except to display the result."
- **1.0 秒**: "about the limit for the user's flow of thought to stay uninterrupted, even though the user will notice the delay." および "Normally, no special feedback is necessary during delays of more than 0.1 but less than 1.0 second, but the user does lose the feeling of operating directly on the data."
- **10 秒**: "about the limit for keeping the user's attention focused on the dialogue. For longer delays, users will want to perform other tasks while waiting for the computer to finish, so they should be given feedback indicating when the computer expects to be done."
- **進捗表示の指針**: "As a rule of thumb, percent-done progress indicators should be used for operations taking more than about 10 seconds."

Nielsen が引用する原典 (孫引きせず記事内の出典表記のみ転記):
- Miller, R. B. (1968) — 人間工学の応答時間研究の源流
- Card, S. K., Robertson, G. G., and Mackinlay, J. D. (1991)

→ **含意**: 10秒は「何もしない」の閾値ではなく「%表示すべき」の閾値。Tom のアプリの20秒タイムアウトは、Nielsen 基準で言えば**すでに「%進捗を見せるべき」領域を2倍超えた場所**にある。無言スピナーで20秒は Nielsen の枠組みには存在しない選択肢。

---

## 2. Apple Human Interface Guidelines — Progress Indicators

**URL**: https://developer.apple.com/design/human-interface-guidelines/progress-indicators

確認方法: 直接 fetch は JS レンダリングのため本文が取得できず(タイトルのみ返却)。
r.jina.ai 経由のテキスト抽出と、サードパーティの HIG ミラー(`tmaasen/apple-dev-mcp` リポジトリ、GitHub raw 経由)の
**2つの独立した経路**で同一の文言が得られたため、内容の一致を確認済み。ただしどちらも Apple 公式ページの直接フェッチではない
点は明記しておく。

逐語引用:

- **Determinate 優先**: "When possible, use a determinate progress indicator." (indeterminate は「何か起きている」しか示せず、
  determinate はユーザーが待つ/後回しにする/諦めるの判断材料になる、という理由付き)
- **Determinate→indeterminate の切替**: "If an indeterminate process reaches a point where you can determine its duration,
  switch to a determinate progress bar."
- **文言ガイダンス(一般)**: "If it's helpful, display a description that provides additional context for the task.
  Be accurate and succinct."
- **曖昧語の禁止**: "Avoid vague terms like loading or authenticating because they seldom add value."
- **スピナーに関しては明確に逆方向の指針**: **"Avoid labeling a spinning progress indicator. Because a spinner typically
  appears when people initiate a process, a label is usually unnecessary."**
- **正確性の重要例**: "Showing 90 percent completion in five seconds and the last 10 percent in 5 minutes can make people
  wonder if your app is still working and can even feel deceptive."
- **スピナーの用途**: "Prefer an activity indicator (spinner) to communicate the status of a background operation or when
  space is constrained. Spinners are small and unobtrusive, so they're useful for asynchronous background tasks."

→ **重要な緊張関係**: Apple の公式指針は「スピナーにラベルを付けるな」であり、これは Tom の設計課題(無言スピナーへの文言追加)と
**正面から対立する**。ただし HIG のこの一文は「操作直後の一般的スピナー」を想定しており、「接続不能かもしれない長時間の
無応答」という異常系については HIG は明示的な指針を持っていない(§4 参照)。この対立は無視せず、設計判断として書き残すべき。

---

## 3. 「無言スピナーを一定時間後に文言付きへ昇格」パターンの実在ガイダンス

**結論から言うと: 特定の秒数を明示した権威あるガイダンス(Apple 公式 / Google Material Design 公式 / NN/G のいずれ)は
確認できなかった。** 存在するのは以下の断片的な実例・二次資料のみ。

- NN/G, [Progress Indicators Make a Slow System Less Insufferable](https://www.nngroup.com/articles/progress-indicators/)
  (Katie Sherwin, 2014-10-26) — 昇格の秒数閾値には触れないが、**説明文言を足すこと自体は明確に推奨**:
  "It can also be helpful to add additional clarity for the user by including text that explains why the user is
  waiting (e.g., 'Loading comments…')."
  同記事は接続品質起因の失敗にも触れている: "spinning gears can be dangerous for data that is loaded from a server,
  simply because the connectivity quality is often beyond the control of the developer." — これは Tom のケース
  (繋がらない=サーバ側でなく接続品質側の問題)に直接該当する警句だが、具体的な対処タイミングの指定は無い。
- [uxpatterns.dev — Loading Indicator Pattern](https://uxpatterns.dev/patterns/user-feedback/loading-indicator) は
  "Escalate to a stronger state if the wait becomes long" という原則を掲げるが、**具体的な秒数は一切明記していない**
  (fetch で確認済み、ミリ秒の閾値・エスカレーション方式とも「未規定」)。
- GOV.UK Design System の公式パターン一覧 (https://design-system.service.gov.uk/patterns/) には
  **ローディング/スピナー専用パターンが存在しない**ことを確認した(パターン一覧を fetch し、3カテゴリのどこにも
  該当項目が無いことを確認)。「GOV.UK Verify のスピナー+説明文言」は個別事例として言及されるのみで、
  デザインシステムの正式パターンではない。
- 「10秒以上で "still loading" 的な文言や中断ボタンを出す」という主張は複数の二次記事(Medium/ブログ)に散見されるが、
  **一次資料での明記は確認できなかった**。Nielsen の「10秒=注意の限界、%表示にすべき」という原則から派生した
  実務上の慣習と考えられる。

→ **確認できなかった事の明記**: 「スピナーを N 秒後に文言付きへ切り替える」という設計そのものを名指しで推奨する
公式ガイドライン(Apple / Google / NN/G)は見つからなかった。これは広く行われている実装パターンではあるが、
**引用可能な一次資料の裏付けを持つ「標準」ではない**。

---

## 4. 逆側の注意点: フラッシュ問題と回避手法

- NN/G Sherwin (2014): **"For anything that takes less than 1 second to load, it is distracting to use a looped
  animation."** さらに "This indicator should be reserved for actions that take between 2-10 seconds." — 
  1秒未満はアニメーション自体が邪魔、2〜10秒がスピナーの本来の適用域という区分。
- Smart Interface Design Patterns (Vitaly Friedman) の記事: "Don't use any loading indicators. They won't be
  perceived in time, and only cause visual noise."(1秒未満は何も出すな)という同趣旨の指針。
  同記事が引用する学術研究: **Nah, F. F-H. (2004), "A study on tolerable waiting time: how long are Web users
  willing to wait?", Behaviour & Information Technology, Vol 23, No 3, pp.153-163**
  (DOI 経由で存在確認済み: https://www.tandfonline.com/doi/abs/10.1080/01449290410001669914 )。
  この研究の知見(検索で確認できた範囲): 情報検索の許容待ち時間はおよそ2秒前後、2秒を境に遅延を知覚し始め、
  15秒を超える遅延は許容されない。Nielsen の10秒枠より一段厳しい実験結果。
- 「遅延表示の閾値」の実務パターンとして広く言及されるのは **200〜300ms 遅延後にスピナー表示**という値(複数の
  実装ブログ・パッケージで見られる、例: `use-debounced-loader`)。ただし出典は実装者コミュニティの経験則であり、
  Nielsen や Apple のような一次ガイドラインではない点に注意。**具体的な数値そのものは一次資料で確認できなかった。**
  この数値は「実務上広く使われている値」として書くべきで、「公式に定められた値」として書くべきではない。
- 「最小表示時間(一度出したら最低 N ms は表示し続けて点滅を防ぐ)」という設計原則自体は複数の実装記事で言及されて
  いるが、**具体的な推奨ミリ秒数を明記した一次資料は確認できなかった**。

---

## この設計に対する推奨閾値 (Tom 向け、一次資料に基づく範囲での結論)

- **0〜0.1秒**: 何も出さない(Nielsen — 即時反応の閾値)。
- **0.1〜1秒**: 依然として何も出さない、または出すとしても文言なしのスピナーのみ(Nielsen の "no special feedback
  necessary" と NN/G の「1秒未満のループアニメは邪魔」が一致)。実測のサーバ応答0.1-0.3秒はこの帯域に収まるため、
  現状の無言 `ProgressView()` は正しい設計。
- **1〜10秒**: 無言スピナーのまま許容範囲内(Nielsen の「1秒で気づくが思考は途切れない」帯域)。Apple HIG は
  この帯域のスピナーへのラベル付けを明示的に非推奨としており、ここで文言を出す一次資料上の根拠は無い。
- **10秒超(=Tom の20秒タイムアウトの前半)**: Nielsen 基準で「注意の限界」を超えており、進捗表示 or 状態説明が
  必要な領域に入る。ただし「何秒でどんな文言に切り替えるか」という具体的な設計は、確認した一次資料のどれも
  規定していない — **ここは一次資料の空白であり、Tom 自身の設計判断で埋める必要がある領域**だと明記する。
  Apple の「スピナーにラベル不要」原則との整合を取るなら、10秒超えの時点で**スピナーの見た目自体を変える
  (進捗バー的な表現、または明確に「接続を確認しています」等の状態メッセージへの切替)**方が、
  「同じスピナーにあとから文言だけ足す」よりも HIG の精神(=ラベルは通常のスピナーには不要、だが determinate/
  状態が変わったら表現も変える)に近い。
