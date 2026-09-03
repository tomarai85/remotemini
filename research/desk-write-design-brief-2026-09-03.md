# 机への書き込みが要る残りの穴 — 設計 brief(2026-09-03)

対照表(`research/feature-parity-2026-09-01.md`)の absent 行のうち、9/3 時点で残っている 4 つ。
どれも「机の口を増やす」か「裁定に触れる」ので、実装の前に**何を決めるか**を 1 枚にする。
各節の最後は Tom が はい/いいえ で答えられる 1 行。私の推奨を先に書く。

前提となる裁定(変えない): D4 / #17「runtime は読むだけ、自動化に安全確認を押させない」/
slash チップは 3 つだけ(`/compact` `/context` `/model`)/ 押しても送らない(チップ・`@` 補完・写真・
`/model` の 2 段目、全部)/ 机の口を増やす時は `wire-key-agreement` と e2e が両側を縛る。

## #8 subagent / workflow を個別に止める

- 公式: 「Stop one of them from the device, and Claude Code stops that task on your machine」。
- RemoteMini: `interrupt` = pane に Escape を 1 回。単位は**セッション全体**。
- 机から見える物: 転写(subagent の起動は `Agent` の tool_use、終了は `task-notification`)。
  止める手段は Claude Code の**中**の `TaskStop` だけで、外(tmux の pane)から 1 本の subagent だけを
  止める入口が無い。Escape は turn 全体を止める。
- 取れる形:
  1. **何もしない**(Escape = 全部止める、で足りる)。
  2. 「1 本だけ止めたい」を**文で送る**(`TaskStop <id> を実行して` を messages で送る)= 机の口は不要。
     ただし turn の途中(busy)では文が pane に積まれるだけで、実行は次の turn。
  3. 机に `subagents` の口を作り、転写から生きている subagent を一覧にして、止める要求は 2 の文送信に
     変換する(= 見せるのは机、止めるのは Claude Code)。
- 推奨: **1**(今は作らない)。理由: 外から止める入口が Claude Code に無い以上、3 を作っても「文を代わりに
  送る」以上の事は出来ず、それは 2 で手で出来る。裁定「押しても送らない」とも整合(3 は押したら送る)。
- 反証条件: Claude Code が subagent 単位の外部停止(hook / API)を持った日。其の時に 3 を起票する。
- Tom へ: **#8 は「Escape で全部止める」のままで良いですか? はい/いいえ(推奨: はい)**

## #11 任意のディレクトリで新規セッション

- 公式: 「Tap it to pick a directory and start a session there」。
- RemoteMini: `startNear` = 既存の行の**隣**(= 其の会話の cwd)でしか始まらない(`action === "new"`)。
  行が 1 本も無い机では新規に始めようがない。`@` 補完(`paths`)は**既存の会話の cwd の下**だけ歩く。
- 机の口の差分: `new` に `cwd` を受けさせる(書き込み = process の起動、既に在る動詞)。危険は
  「任意の path」= 机の任意の場所で `claude` を起動できる事。allowlist(机の `~/.rc-backend/roots`、
  例 `~/Infra ~/client-a ~/Personal`)の**下**だけ受け、其れ以外は 400 `outside_roots`。
- 電話の口: 一覧の「+」から dir ピッカー。候補は `paths` の口を roots 起点で歩く(既存の口に `root` を
  1 つ足す。読むだけ)。押しても**送らない**規約は「dir を選んだ後に『ここで始める』を押す」で満たす。
- 推奨: **作る**(小さい: 机 2 口の引数 + allowlist、電話は既存の `PathSuggestion` の UI を再利用)。
  理由: 「机に会話が 0 本」の日に電話から何も始められないのは、移動中の道具として穴。
- 反証条件: allowlist の外を受ける実装を e2e が通してしまう(400 の検査を先に置く)。
- Tom へ: **#11 を「roots の下だけ」で作りますか? はい/いいえ(推奨: はい。roots は `~/Infra ~/client-a
  ~/Personal` から)**

## #15 effort を電話から選ぶ

- 公式: `/effort` または端末の effort control。
- RemoteMini: チップは 3 つだけ(裁定)。`/model` は 9/3 に 2 段目(model 名)が付いた。
- 取れる形:
  1. 4 つ目のチップ `/effort` = 裁定「3 つだけ」に触れる。
  2. **チップは増やさず**、入力欄に `/effort` と**打った時だけ** 2 段目(`low / medium / high`)を出す
     (`SlashArgument` の規則に 1 行足すだけ。押しても送らない)。移動中に綴りを 7 文字打つ手間は残る。
  3. `/model` の 2 段目に `effort:` の候補を混ぜる = 語彙が混ざる。却下。
- 推奨: **2**。理由: 裁定に触れず、`/effort` を知っている人には効く。1 は Tom の裁定。
- Tom へ: **`/effort` を 4 つ目のチップにしますか? はい/いいえ(推奨: いいえ、2 で足りる)**

## #32 通知の種別トグル

- 公式: `/config` に 2 つ = Push when Claude decides / Push when actions required。
- RemoteMini: 通知は**机**が鳴らす(`digest-notify.sh` → `~/bin/discord-notify.sh` = Discord)。電話は
  深いリンク(`remotemini://session/<sid>`)を受けるだけで、種別は 1 つ(attention が choice / input)。
- 電話側だけでは作れない(鳴らす判断は机の台本に在る)。机側なら `~/.rc-backend/notify.json` に
  `{"decides": true, "actions": true}` を置いて台本が読む = 机の**設定 file**であって口ではない。
  電話からトグルするなら `settings` の口(書き込み)が要る。
- 推奨: **今は作らない**。理由: Tom が「完了だけ鳴らせ / 判断待ちだけ鳴らせ」と言った事が無く、
  Discord 側でチャンネルを分ける方が既存の道具で済む。
- 反証条件: Tom が通知の種類で困った日。其の時は机の設定 file(電話の口なし)から。
- Tom へ: **#32 は見送りで良いですか? はい/いいえ(推奨: はい)**

## まとめ(Tom の 4 つの はい/いいえ)

| # | 問い | 推奨 |
|---|---|---|
| #8 | Escape で全部止める、のままで良いか | はい |
| #11 | roots の下だけで「任意の dir で新規」を作るか | はい |
| #15 | `/effort` を 4 つ目のチップにするか | いいえ(打った時だけ 2 段目) |
| #32 | 通知の種別トグルは見送りか | はい |
