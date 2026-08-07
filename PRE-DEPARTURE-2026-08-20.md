# 渡米前に Tom がやる3件 — 手順書(2026-08-07 起票 / 出発 2026-08-20)

私が代行できない3件だけを、打つ物・確かめ方・戻し方の形で置く。
判断の根拠と却下した代案は `DESIGN.md` の §8-5 / §8-11 / §8-1 に在る。此処は**やり方だけ**。

所要は合計 **5分程度**。1 は渡米前に必須、2 と 3 は渡米前が望ましい。

---

## 1. tailnet 鍵の失効を無効化(edith と friday の2台)★最優先

**期限**: friday = 2026-09-19(残り43日) / edith = 2026-12-25(残り140日)。
**2台同時に、渡米前にやる。** edith の方が期限は先だが、渡米後はどちらも物理で触れない。

**なぜ私にできないか**: control plane 側の設定で、`tailscale set` に期限の flag が無い
(edith の Tailscale 1.98.5 で実測、subcommand 一覧にも無い)。admin console か API token でしか触れない。

**やる事**:

1. Tailscale の admin console を開く → **Machines**
2. `edith` の行 → **Disable key expiry**
3. `friday` の行 → 同じく **Disable key expiry**

**成功の確かめ方**: 私が `tailscale status --json` から両機の期限を読めるので、
押し終わったら「押した」とだけ言ってくれれば私が観測して報告する。
(Tom 側で見るなら、admin console の当該行に期限の表示が出なくなる)

**戻し方**: いつでも1クリックで再度有効化できる。

**切れると何が起きるか**: tailnet から落ちる。**復旧用の ssh も同じ経路なので同時に死ぬ**
= 遠隔で戻す手が無い。渡米先から edith に触る道が全部消える。これが最優先の理由。

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

## 3. edith の `~/.claude/settings.json` に statusLine を1行

**なぜ私にできないか**: `settings.json` の編集は hook で全面 block。
判定が **basename 一致**なので、edith 側の `/Users/edith/.claude/settings.json` も同じく私からは書けない。迂回しない。

**やる事**: edith の `~/.claude/settings.json` に次の1行を足す。

```json
"statusLine": { "type": "command", "command": "bash ~/.claude-sync/tools/rc-pane-register.sh", "refreshInterval": 2 }
```

**成功の確かめ方**: 足した後に edith で Claude Code の会話を1つ開けば、
その会話が名乗りを上げて `/api/sessions` の一覧に出る。私が一覧を見て確認できる。

**なぜ重みが上がっているか**: 未登録の会話には注入が一切効かない(§2.10)。
つまりこの1行が無い会話は、**電話から見えないし打ち込めない**。

---

## この3件が終わったら残るのは1つ

電話を1回開いて**見るだけ**の3点(§8-4 流れがその場で出るか / §8-8「送る」ボタンが見えるか /
§8-10 待ち時間)。変更は無く、1往復で3件片づく。

## 私の側の現状(2026-08-07 実測)

- 対照の全掃引 `green=64 / red=0 / 未測定=0`
- iPhone アプリ headless simulator build 成功・test **384件 / 失敗 0件**
- edith の常駐 `com.edith.rc-backend` PID 574 稼働中
