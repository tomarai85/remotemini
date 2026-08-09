# Sprint 6.5(spec §6 Day 7)受入 —— REQUIREMENTS §5 の v1 該当分

測った日: **2026-08-07 00:44**
測った物: `.harness/dod-sprint-6.5.sh`(`DOD_FULL=1`)
負の対照: `.harness/dod-sprint-6.5-controls.sh`
生の出力: `dod-sprint-6.5-full.log` / `dod-sprint-6.5-after-artifact.log` /
`dod-sprint-6.5-controls.log`(同じ dir)

★この表は**手で書いていない**。上の道具の出力から起こしてある。手で書くと
「表に書いた事」と「実際に測った事」が別々に腐る —— この repo は既に踏んでいる
(配備した事を書く場所と、配備待ちだと書いた場所が別だった件、`.harness/progress.md` §4-4)。

★dir 名について: spec §6 の DoD が `.harness/evidence-2026-08-1x/` と書いているので
**その綴りのまま**使う。実際の測定日は 08-07 で、`1x` は spec 起草時の見込み。
綴りを合わせる方を採ったのは、spec の DoD 行と実物が grep で繋がる事の方が重いから。

---

## 1. 結果

**緑 12 / 赤 1 / 未測定 2**(終了コード 1)。

★2回走らせて、2回とも残してある。**10 行目はこの file 自身を見る行**なので、
表を起こした1回目(`dod-sprint-6.5-full.log`、00:40)の時点ではまだ存在せず 未測定 だった
(緑 11 / 赤 1 / 未測定 3)。この file を書いた後の再走(`dod-sprint-6.5-after-artifact.log`、
00:52)で 10 行目が緑になり、他の 14 行は**1文字も変わっていない**。
1回目を消さないのは、消すと「証跡が自分を測る行」がどう埋まったかが辿れなくなるから。
以下の表は再走(00:52)の側。

| 行 | REQUIREMENTS §5 | 判定 | 根拠 |
|---|---|---|---|
| 0 | 照合の土台 | 緑 | log 最大 370 件 / 失敗 0 / 原稿の指紋 `a219aea78e19` が一致 |
| 1-a | #1 一覧が先(実装経路) | 緑 | `normalFlow` は `ListView` のみを出し、会話は `ListView` の `NavigationLink` 経由だけ |
| 1-b | #1 一覧が先(画面の検査) | 緑 | 一覧の3状態(通常・障害・空)3 本が同じ log に passed |
| 2-a | #2 読める・打てる(実装経路) | 緑 | 取得・併合・送信の3つが在り、ViewModel が送信を持っている |
| 2-b | #2 読める・打てる(検査) | 緑 | 3 役の表示・以前を読む・打ち切り印の在無 4 本 |
| 3 | #3 その場で直す | 緑 | BUSY で打ち込む欄と割り込みが**両方生きている**3 本 |
| 5-a | #5 切断を跨ぐ(机の上) | 緑 | 欠落理由9種・欠落通知・自動再同期の1回性・前面復帰の再取得 6 本 |
| 5-b | Day 7 第3脚(再起動を挟む) | 緑 | `rc-backend/test/restart-epoch-controls.sh` を実際に回して 0 |
| 5-c | Day 7 第1・2脚(実回線) | **未測定** | Tom の iPhone が要る。→ `HANDOFF-NEXT-SESSION.md` §4 の **8-b** |
| 6-a | #6 待たされない(定数) | 緑 | 読む 8 秒 / 待つ 30 秒 / 書く 30 秒 と server 側の写し |
| 6-b | #6 待たされない(検査) | 緑 | 定数どうしの関係 + 計器の陰性対照 5 本 |
| 6-c | #6 電話の側の体感 | **未測定** | 私が測った数字は全部 Mac から。→ `DESIGN.md` §8-10 / `HANDOFF` §4 の **8-a** |
| 7 | #7 所有して拡張できる | 緑 | 外部 package 0 / `Package.resolved` 無し / import は Apple 標準のみ |
| 9 | #9 期限性(渡米後も作れる) | **赤** | 日本に残す 2 台**とも**生きた鍵の期限が在る(140 日 / 43 日)。→ `DESIGN.md` §8-5 |
| 10 | 証跡そのもの | 緑(再走で) | この道具を名指しし、引用した 21 種が全部実在し、未測定の行が残っている |

対象外(v1 の外、spec §7 に v2 候補として在る):
- **#4 通知** = wildcard provisioning profile が push の entitlement を運べない。
- **#8 アカウント切替** = v1 にアカウント UI が無い。Tom 逐語の v1 4項目
  「1. 一覧 2. 履歴 + ライブの流れ 3. 打ち込む 4. 割り込む」の外。

---

## 2. 唯一の赤 —— §5-9 は今**成立していない**

§5-9 の主張は「UI は Tailscale 越しの純ソフト = **渡米後も作れる**」。
これを崩す観測可能な条件は1つだけ ——
**日本に置いて行く機械の tailnet 鍵に、生きた期限が在る**事。
鍵が切れた時の復旧はその機械の前での browser 認証なので、渡米後は手が届かない。

実測(機械名は出さない。`tailscale status --json` は LoginName と node key を含む面なので、
`--porcelain` の side / 日数 / 日付だけを読んでいる):

| 日本に残す機械 | 残り | 期限日 |
|---|---|---|
| 1 台目 | 140 日 | 2026-12-25 |
| 2 台目 | **43 日** | **2026-09-19** |

近い方の 2026-09-19 が `DESIGN.md` §8-5 の締切そのもの。**Tom の操作**
(Tailscale 管理画面で 2 台の `Disable key expiry`)。渡米は 08-20 なので、
**やらずに出ると、その 30 日後に日本側へ届かなくなる**。

★測る対象を初版から絞った(同日中の訂正)。初版は `--chain` でこの MBP も数えて
赤を出していたが、**この機械は Tom と一緒に渡米する** —— 手元に在る機械の鍵が切れても
その場で入り直せるので「渡米後も作れる」を崩さない。falsifier は
「日本に置いて行く機械へ届かなくなる」事だけ。§8-5 が名指しするのも日本側 2 台。

---

## 3. 未測定の 2 行 —— 電話が要る。走らせ方を変えても緑にならない

| 行 | 何が要るか | 行き先 |
|---|---|---|
| 5-c | Wi-Fi→セルラー切替 / 機内モード往復 を実機で通す | `HANDOFF` §4 の **8-b**(実機に app が載ってから) |
| 6-c | ホーム画面から開いて最初の画面が出るまでの体感 | `HANDOFF` §4 の **8-a**(見るだけ・Yes/No・**今すぐ**) |

6-c について、机の上で測れる所までは測ってある(Jervis から edith へ):

| 経路 | 実測 |
|---|---|
| 同一接続の使い回し | 10.6 ms |
| 新規接続 | 45〜52 ms |
| **経路が冷えた1回目** | **870 ms** |

電話の数字は0件。8-a の質問は「最初の画面が出るまで**体感で 8 秒より短かったか**(Yes/No、
推奨 = Yes)」で、条件が1つ —— **Wi-Fi を切ってセルラーで、電話をしばらく置いた後**。
温まった経路は必ず Yes を返すので、温まった状態で測ると**何も答えていない事になる**。

Day 7 の3脚のうち**サーバ側(rc-backend 再起動を挟む)は 5-b で閉じている**ので、
実機で赤が出たら原因は電話側だと先に絞れる。

---

## 4. 照合そのものが効く事(負の対照 14 / 14)

緑は「性質が守られている」の証拠ではなく「今の木とこの照合が一致している」の証拠でしかない。
骨抜きの照合も同じ緑を出す。だから性質を実際に壊して、名指しの行が赤(または未測定)に
なる事を測った。**作業木は一切触っていない**(照合表が読む file だけを scratch に複製し、
そこで壊す。走らせる前後で `git status` の差 0 行を観測して確かめてある)。

| 壊した物 | 期待 | 結果 |
|---|---|---|
| 原稿の指紋を書き換える | 0 行目が未測定 | OK |
| 指紋の file を消す | 0 行目が未測定 | OK |
| 指紋を書き換える(下の行を見る) | log 頼りの **5 行が全部**未測定 | OK |
| 通常経路に `ConversationView` を直に置く | 1-a が赤 | OK |
| `normalFlow` の目印を消す | 1-a が**緑にならず**未測定 | OK |
| log から passed の行を1本消す | 1-b が赤 | OK |
| ViewModel から `SendClient` を外す | 2-a が赤 | OK |
| BUSY の検査を1本改名する | 3 が赤 | OK |
| `writeTimeout` に接尾辞を足す | 6-a が赤 | OK |
| `DESIGN.md` §8-10 を消す | 6-c が赤 | OK |
| Apple 標準でない import を足す | 7 が赤 | OK |
| `Package.resolved` を置く | 7 が赤 | OK |
| 未測定の行が無い証跡を置く | 10 が赤 | OK |
| 実在しない検査名を引く証跡を置く | 10 が赤 | OK |

★この対照が**照合側の欠陥を 3 つ捕まえた**(全部直してある):
0. **指紋の判定が下の行へ伝わっていなかった**。0 行目は指紋を見ていたのに、
   log を根拠にする 5 行(1-b / 2-b / 3 / 5-a / 6-b)は 0 行目の判定を見ていなかった。
   照合表の頭には「0 行目が未測定なら下の緑は全部古い木の話」と**註が書いてあり**、
   機械は何もしていない。直す前の造りで実測すると:

   | 指紋を壊した時 | 0 行目 | 1-b / 2-b / 3 / 5-a / 6-b |
   |---|---|---|
   | 直す前 | 未測定 | **緑 5 行**(古い log の話をそのまま緑で出す) |
   | 今 | 未測定 | 未測定 5 行 |

   註は守りではない。上の対照 1・2 は 0 行目しか見ていなかったので、この穴を通した ——
   **対照が緑でも、その隣に対照の無い経路が残る**。

1. `6-a` の定数照合が部分一致だった。`static let writeTimeoutDisabled` が
   `writeTimeout` の在る証拠として通る = **定数を殺す改名を緑のまま素通しする**。
   語の境界を付けた。
2. `1-a` の「含まない」を根拠にする行が、対象を見失った時に黙って緑を出す形だった。
   抜き出しが空なら未測定へ落とす様にした。対照は最初この欠陥を**見逃した**
   (接尾辞を足す改名では目印が残るので抜き出しが成功していた)—— 対照の側も直した。

---

## 5. 引用した検査名(全部実在を照合済み)

一覧: `testListNormalShowsTheListNotTheEmptyOrFaultBanner` /
`testListPaneFaultShowsTheFaultBannerText` / `testListEmptyShowsTheNoConversationsMessage`

履歴と送信: `testThreeRolesShowsAllThreeRolesAndTheLoadEarlierButton` /
`testTruncatedTrueDecodes` / `testTruncatedFalseHidesTheButtonEntirely` /
`testLoadEarlierRefetchesWithNextHistoryLimitValue`

BUSY で干渉できる(Tom の裁定): `testBusyLeavesBothTheComposerAndTheInterruptButtonUsable` /
`testComposerStaysEnabledOnBUSY` / `testInterruptStaysEnabledOnBUSY`

切断を跨ぐ: `testAllNineKnownGapWhyValuesDecode` /
`testGapWithNoticeDrawsTheNoticeAndAlwaysTriggersARefetch` /
`testAutoResyncFiresAtMostOnceUntilAReadableResponseEndsTheEpisodeNegativeControl` /
`testARealBackgroundRoundTripResumesExactlyOnce` /
`testHandleForegroundResumeRefetchesHistoryAndTheRefetchLandsInHistory` /
`testAPeekThatNeverReachesTheBackgroundIsNotAResumeNegativeControl`

待ち時間: `testPollTimeoutIsDerivedFromTheServerConstantNotHandWritten` /
`testInteractiveTimeoutIsShorterThanThePollTimeout` /
`testWriteTimeoutStaysAtThePollLength` /
`testABareRequestDoesNotRecordTheInteractiveTimeout` /
`testReadAndPollDifferOnTheSameSession`

---

## 6. Tom の側に残る事(2 件、どちらも既存の項目に合流済み)

| 何 | どこ | 期限 |
|---|---|---|
| 日本に残す 2 台の tailnet 鍵の期限を無効化(Yes/No、推奨 Yes) | `DESIGN.md` §8-5 | **2026-09-19**(渡米 08-20 より後 = 出る前に済ませる) |
| 電話で最初の画面までの体感(Yes/No、推奨 Yes) | `DESIGN.md` §8-10 / `HANDOFF` §4 の 8-a | 無し。§8-4 / §8-8 と**同じ1回**で片付く |

実回線の 2 脚(5-c)は app が実機に載ってからなので、今の Tom 待ちには数えていない。
