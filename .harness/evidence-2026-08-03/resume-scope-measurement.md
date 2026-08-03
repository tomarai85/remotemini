# `claude --resume` が何を鍵に記録を探すか(2026-08-03 15:5x 実測)

設計書 §8-2(= edith 上で `sudo mkdir -p /Users/tomtim`)は、**「resume には両機で同一の絶対パスが要る」** という
前提の上に立っている。その前提は今まで**設計上の仮定であって実測ではなかった**ので、測った。

## 実験系(外部通信ゼロ・Tom の実データに触れない)

- 偽 `HOME` = `<scratchpad>/resume-scope/home`。Tom の `~/.claude` は読み書きしない。
- `ANTHROPIC_BASE_URL=http://127.0.0.1:9` + 偽 API キー → **API 呼び出しは接続段階で死ぬ**。
  実測 `duration_api_ms: 0` / `total_cost_usd: 0` / `usage` 全 0 = 上限も金も消費していない。
- 記録は**本物の生成元から取った**(`run-controls.sh` 冒頭の規則 (1))。手書きの JSONL ではなく、
  本物の `claude 2.1.220` を偽 HOME で1回走らせて吐かせた `9ea169aa-….jsonl`。
- slug の規則も推測せず実測: 起動 cwd の `/` `.` `_` を `-` に置換(`.claude` → `--claude`、
  `_archive` → `-archive`。非 ASCII はそのまま = `-Users-tomtim-個人-f1-package` が実在する)。

## 3本

| # | 役割 | 起動 cwd | 記録の置き場(slug) | 記録の中の `cwd` | 結果 |
|---|---|---|---|---|---|
| 1 | **対照** | `…/alpha` | alpha | alpha | **読めた**(API 段階まで進んだ) |
| 2 | 反証 | `…/beta` | alpha のみ | alpha | `No conversation found with session ID: …` |
| 3 | **本命** | `…/beta` | **beta へ写した** | **alpha のまま** | **読めた**(#1 と同形の出力) |

#2 が在るから #3 が意味を持つ。#2 が無ければ「beta でも読めた」は
「resume は常に何か読む」と区別が付かない。

## 結論

`--resume <sid>` の探索鍵は **起動 cwd から作った slug ディレクトリ名だけ**。
transcript の中の `cwd` フィールドは**照合に使われない**(#3 が全記録 alpha のままで読めた)。

裏付け(バイナリ内の該当コード、`grep -a` で抽出):
- 明示 ID の失敗経路 = `failure_reason: "not_found_explicit_id"` →
  `No conversation found with session ID: ${s.sessionId}`
- 選択画面の失敗経路は別文言 = `No conversations found in this project.`
- 読み込み成功時は `Zk(SA(c.sessionId),"resume", c.fullPath ? dirname(c.fullPath) : null)` =
  **見つかったファイルの実パスから**プロジェクト位置を後付けしている(=先に位置を持っていない)。

## 追測(#1-#3 の後、Codex が「それはまだ証明していない」と名指しした3点を潰した)

Codex の指摘は正当だった: 「記録が**見つかった**」と「過去の会話が**実際に要求へ載った**」は別物で、
私は前者しか測っていなかった。前者だけなら、空の文脈で新しい会話が始まっても同じ観測になる。

### #4 セッション ID の同一性(安い方から)

| | 起動 cwd | `--resume` | 返る `session_id` |
|---|---|---|---|
| A | beta | 有り | `9ea169aa-…` = **元と同一** |
| B(対照) | beta | 無し | `6b0ef322-…` = 別物 |

### #5 追記先(= Codex 未証明項目その2)

`--resume` 後、**写像後 slug の同一 SID ファイルに追記された**。新しいファイルは作られない。

- beta 側 `9ea169aa….jsonl`: 15 行 → **29 行**
- その中の `cwd` 内訳: alpha 8 件 + **beta 8 件**(= 追記分は実 cwd を正しく記録)
- alpha 側の原本: **15 行のまま = 無傷**

これは持ち帰り設計に直接効く —— 写像先から **SID 単位**で引けば良く、slug ディレクトリ全体を
同期する必要が無い(Codex が名指しした「別 SID を巻き込む `--delete` 事故」の予防にもなる)。

### #6 過去の内容が要求に載るか(= Codex 未証明項目その1、本丸)

`127.0.0.1:8799` に偽 API 端点を立て、POST body をそのまま落として 500 を返した(外へは出ない)。
罠が1つ在った: **最初に来るのは `HEAD /api/hello` の疎通確認**で、そこに 500 を返すと本要求まで
進まない。200 を返して初めて `POST /v1/messages` が来る。

| | 起動 cwd | 記録 | 送信 body 中の canary 出現数 |
|---|---|---|---|
| 本命 | delta | gamma の記録を **delta の slug へ写した** | **7 回** |
| 対照 | delta | 履歴無しの新規セッション | **0 回** |

canary = `CANARY-…-4e1c`、この回のプロンプトは `zzz-new-turn`(= canary は**過去からしか来ない**)。
新ターンも 7 回出るので、過去 + 今回が同じ要求に載っている。

**これで「写像後の slug に置けば、過去の文脈ごと resume できる」が実測で閉じた。**

## この結論が言っていない事(= まだ測っていない範囲)

- 応答本体は受けていない(端点が 500 を返す)。言えるのは**要求の組み立てまで**同一、という所まで。
  応答の中身が変わる要因はここには無いが、測ってはいない。
- **過去の記録に残る絶対パスをモデルが再利用する**経路は写像では消えない(Codex 指摘)。
  過去のツール結果に `/Users/tomtim/X/...` が文字列として残り、写像後の機械にそれは存在しない。
  → 対処は「transcript 本文を書き換える」ではない(ユーザ文・コード・ログまで誤変換する)。
  写像するのは **記録の置き場所・同期の実行パス・remote-mini が持つ構造化された経路表**の3つだけ。
- Claude Code の版に依存する(`2.1.220`)。**版が上がったら #1-#3 と #6 を回し直す事**
  (対照込みで自動化済 = `rc-backend/test/remote-mini-root-controls.sh`)。

## これが動かす設計

§8-2 の人間ゲート(`sudo mkdir -p /Users/tomtim` on edith)は、
**宛先パスの写像**(`/Users/tomtim/X` → `/Users/Shared/dev/X`)+
**写像後のパスから作った slug へ記録を置く**、で置き換えられる可能性が出た。
採否は Codex の第2レンズを通してから決める(= 出荷済みツールの契約変更なので設計判断)。
