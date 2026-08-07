# 渡米前に Tom がやる3件 — 手順書(2026-08-07 起票 / 出発 2026-08-20)

私が代行できない3件だけを、打つ物・確かめ方・戻し方の形で置く。
判断の根拠と却下した代案は `DESIGN.md` の §8-5 / §8-11 / §8-1 に在る。此処は**やり方だけ**。

所要は合計 **5分程度**。**1 だけが渡米前に必須**。2 は渡米前が望ましい。
3 は実測の結果 **任意に格下げ**した(2026-08-07、理由はその項に)—— 代わりに
「渡米中に手で開く会話は `rc-claude` で開く」という**打つ物が無い1行**が効く。

---

## 1. tailnet 鍵の失効を無効化(**5台全部**)★最優先

**訂正(2026-08-07、実測)**: 起票時に「edith と friday の2台」と書いたが、**間違い**。
`tailscale status --json` で数えたら、期限が付いているのは **5台全部**だった:

| OS | 残り | 効く物 |
|---|---|---|
| macOS | 43日 | |
| macOS | 43日 | |
| **iOS** | **99日** | **Tom の iPhone** |
| macOS | 139日 | edith |
| macOS | 170日 | |

**iPhone を落としていたのが致命的だった。** 電話も tailnet の1ノードなので、
**電話側の鍵が切れれば edith が無事でも届かない**。しかも気付くのは空港かホテル。
edith だけ直しても片側しか直っていない。

**5台全部やる。** 1台1クリック、副作用は無い。

**期限の見方**: 上の表は `bash rc-backend/tools/departure-survivability-check.sh` が
毎回数え直す(機器名は出さない設計なので、どの行がどの機械かは admin console 側で見る)。

**なぜ私にできないか**: control plane 側の設定で、`tailscale set` に期限の flag が無い
(edith の Tailscale 1.98.5 で実測、subcommand 一覧にも無い)。admin console か API token でしか触れない。

**やる事**:

1. Tailscale の admin console を開く → **Machines**
2. **各行**の `...` → **Disable key expiry**(5行とも。iPhone の行を飛ばさない)

**成功の確かめ方**:

```
bash rc-backend/tools/departure-survivability-check.sh
```

→ 「期限付き 0 台 / 全 5 台」かつ終了コード 0 になれば済んでいる。
押し終わったら「押した」とだけ言ってくれれば私が撃って報告する。

**戻し方**: いつでも1クリックで再度有効化できる。

**切れると何が起きるか**: tailnet から落ちる。**復旧用の ssh も同じ経路なので同時に死ぬ**
= 遠隔で戻す手が無い。渡米先から edith に触る道が全部消える。これが最優先の理由。

**旅程に重なっている(2026-08-07 実測)**: 最短の失効まで残り **42 日** = 2026-09-19 前後。
8/20 出発 + 旅程 30 日の帰国と**ほぼ同じ日**。「43日あるから余裕」ではなく、
**旅程の末端に食い込んでいる**。旅程が数日伸びれば渡米中に切れる。

---

## 2. 渡米中だけ edith の macOS 自動更新を停止(sudo が要る)

**なぜ私にできないか**: `/Library/Preferences` への書き込みに sudo が要る。
私の環境では sudo が**構造的に不可能**(遠慮ではなく制約)。

**やる事(どちらか一方)**:

- GUI: システム設定 → 一般 → ソフトウェアアップデート → 自動アップデート →
  「macOS アップデートをインストール」を **off**
- CLI:
  ```
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticallyInstallMacOSUpdates -bool false
  ```

**成功の確かめ方**:

```
defaults read /Library/Preferences/com.apple.SoftwareUpdate.plist AutomaticallyInstallMacOSUpdates
```

→ `0` が返れば off。

**戻し方(帰国後)**: 同じコマンドの `-bool false` を `-bool true` に。
この項は**渡米期間だけ**の話なので、戻すのを前提にしている。

**賭けている一点**: 「更新の再起動が自動ログインを解除しない」。
復帰の実績3回は**素の再起動**の実績であって、**更新の再起動の実績ではない**。
無人の機械が自分で再起動して構成を変え得る方が、3週間パッチが遅れるより重い、というのが私の判断。
edith の面は tailnet 限定(funnel ではない = 公開されていない)ので、後者の側は軽い。

---

## 3. edith の `~/.claude/settings.json` に statusLine を1行(**任意 — 渡米の前提ではない**)

**訂正(2026-08-07、実測)**: 起票時に「この1行が無い会話は電話から見えないし打ち込めない」と
書いたが、**誇張だった**。測った値:

| 測った物 | 結果 |
|---|---|
| edith の `settings.json` の `statusLine` | **無い**(今も) |
| それでも `work:phone` は | 生存・登録簿の心拍 0 秒前 |
| `/api/sessions?scope=registered` の tmux 経路 | **1 件** |
| 再起動の後に戻す物 | `com.edith.rc-phone-window` が `RC_PHONE_CMD=/Users/edith/.local/bin/rc-claude` を明示 |

理由は `rc-claude` ラッパが `--settings` で**起動のたびに注入している**から。だから
`settings.json` を触らなくても鎖④(登録簿に載る)は成立していて、**無人再起動の後も
同じ経路で戻る**。同じ線引きは `DESIGN.md` §8-1 の 2026-08-04 の訂正に既に在った。

**では何が本当に効くのか(こちらが渡米前の1行)**:

> **渡米中に手で開く会話は `claude` ではなく `rc-claude` で開く。**

素の `claude` で開いた会話だけが電話から見えない。`rc-claude` は edith の PATH に在る
(`/Users/edith/.local/bin/rc-claude`)ので、打ち方が変わるだけで手間は同じ。

**この項目をやると何が変わるか**: 素の `claude` で開いた会話**も**自動で載るようになる。
つまり「打ち間違えた時の保険」。**格上げであって、前提条件ではない。**

**なぜ私にできないか**: `settings.json` の編集は hook で全面 block。
判定が **basename 一致**なので、edith 側の `/Users/edith/.claude/settings.json` も同じく私からは書けない。迂回しない。

**やる事**: edith の `~/.claude/settings.json` に次の1行を足す。

```json
"statusLine": { "type": "command", "command": "bash ~/.claude-sync/tools/rc-pane-register.sh", "refreshInterval": 2 }
```

**成功の確かめ方**: 足した後に edith で **素の `claude`** で会話を1つ開けば、
その会話が名乗りを上げて `/api/sessions` の一覧に出る。私が一覧を見て確認できる。
(`rc-claude` で開くと元から載るので、この項目の検証にならない)

**やらなかった時の逃げ道**: 渡米先からでも Blink 経由で ssh して開き直せる。回復可能。

---

## この3件が終わったら残るのは1つ

電話を1回開いて**見るだけ**の3点(§8-4 流れがその場で出るか / §8-8「送る」ボタンが見えるか /
§8-10 待ち時間)。変更は無く、1往復で3件片づく。

## 出発の直前(8/19 目安)に、この1行を撃つ

```
bash rc-backend/tools/departure-survivability-check.sh
```

3週間の無人耐久を機械で測り直す。**手で測った物は 8/19 の保証にならない** ——
OS 更新が `sleep` を戻す・deploy が plist を置き換える・誰かが FileVault を入れる、
どれも起きる。終了コードは 0=緑 / 1=赤 / 2=未測定(2 を緑と読まない)。

測る中身: 停電から戻る鎖 7 項目(`coldboot-chain.sh` を edith 上で呼ぶ)+
常駐が今動いている事 + 面が 401 を返す事 + 空き容量 + tailnet の鍵の期限 +
**鎖②③ を戻す2つの job が launchctl に居る事** +
**今この瞬間 tmux 経路で打ち込める相手が何件居るか**。

後ろの2つは 2026-08-07 に足した。それまでこの検査は鎖①(サーバが上がる)しか見ておらず、
**`DESIGN.md` §6 が名指しで警告している誤読(「サーバが上がった = 電話が使える」)を
検査自身が犯していた**。①だけ緑で②③④が死んだ状態が「読めるが送れない」。

## 私の側の現状(2026-08-07 実測)

- 対照の全掃引 `green=65 / red=0 / 未測定=0`(渡米前検査の対照は 25 項目)
- iPhone アプリ headless simulator build 成功・test **384件 / 失敗 0件**
- edith の常駐 `com.edith.rc-backend` 稼働中(最後の終了コード 0)
- 鎖②③ の job 2つとも launchctl に居る(終了コード 0)。tmux 経路で話せる相手 **1 件**
- 3週間の無人耐久 = **赤 1 件のみ**。それが上の項目1(tailnet の鍵)。他は全部緑
- その赤の中身: 期限付き **5 台**、最短 **残り 42 日** = 2026-09-19 前後。
  8/20 出発 + 旅程 30 日の帰国とほぼ同じ日に切れる。**旅程の末端に重なっている**
