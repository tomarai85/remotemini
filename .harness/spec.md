# spec — RC 模倣バックエンド Phase I-1(edith 骨格)

作成: 2026-07-31。上流 = `~/Infra/mobile-work/DESIGN.md`(D3/D4 確定済み)・`REQUIREMENTS.md` §5。
has_design_decisions: **false** — 設計判断は DESIGN.md で確定済み(D3 実測 MULTITURN-OK、D4 統合案)。
本 spec は新しい判断を含まない。D1(器)は branch-independent のため本フェーズに含まれない。

## 目的(1行)

iPhone のブラウザから edith の Claude Code セッションを「一覧 → 選ぶ → 読む → 打つ →
ストリームで返る」まで通す最小バックエンド + 検証用最小ページ。

## スコープ

### In(Phase I-1)

| # | 機能 | 中身 |
|---|---|---|
| 1 | `GET /api/sessions` | `~/.claude/projects/**/*.jsonl` を走査。**`entrypoint:"cli"` のみ**。各行: id / project / title(`ai-title` 行)/ lastPrompt(`last-prompt` 行を tail 側から)/ mtime / 状態(worker 有無 + TUI 保持か) |
| 2 | `GET /api/sessions/:id/history` | jsonl をパースして会話履歴(user/assistant テキスト + tool-use の要約行)を返す。ページング(末尾 N 件) |
| 3 | `POST /api/sessions/:id/messages` | セッションワーカーへ user turn を書く。ワーカー無ければ spawn(`claude-work -p --resume <id> --input-format stream-json --output-format stream-json`)。**TUI 保持セッションは 409**(read-only 設計) |
| 4 | `GET /api/sessions/:id/stream` | SSE。ワーカーの NDJSON イベントを中継(assistant text delta / tool activity / result)。切断→再接続で取りこぼした分は seq 番号で追いつき(リングバッファ) |
| 5 | `POST /api/sessions/:id/interrupt` | ワーカー kill(= 割り込み)。`--resume` で無傷再開できることは実測済み |
| 6 | `GET /api/account` / `POST /api/account/next` | fleet-account の現用表示 / 切替(REQUIREMENTS §4-5) |
| 7 | 認証・bind | tailscale IP のみ bind。bearer トークンファイル(ローテート可、`edith-claude-http.mjs` の型)。キー無し = 401 |
| 8 | 最小テストページ | `GET /` — 一覧 → タップで会話 → 送信 → ストリーム表示の素の HTML/JS(装飾なし。D1 決定用の実物) |

### Out(明示的に含まない)

- UI の質(D1 決定後の Phase I-2)/ プッシュ通知配線 / 多機体(D5)/ hard-stop 通知面
- **TUI 保持セッションへの書き込み**(lost-update 未検証のため 409。衝突テストは別項)
- 本家 slash コマンドの中継(テキストのみ)

## ワーカー管理の契約(D3 の実装規約)

- **1セッション1ワーカー**(Map<sessionId, worker>)。二重 spawn は構造的に不可能にする(排他は Map 到達前の直列化で保証)
- idle 10分で kill(値は定数化)。kill 後の再開はワーカー再 spawn(`--resume`)
- 実行中/入力待ちの真実は**ワーカーのイベントとプロセス状態から**。jsonl の tail から推測しない(Codex 補正)
- ワーカー異常終了(exit≠0)→ セッション状態 `error` としてストリームへ流し、次メッセージで再 spawn(fail-closed: 黙って再試行しない)
- TUI 保持判定: tmux の pane cwd + 生存プロセスから。判定不能時は**保持扱い**(fail-closed 側 = 書かない)

## 品質ゲート(Tom 裁定: 質・正確性 > スピード)

1. **テスト先行**が可能な純関数(jsonl パース / 一覧構築 / SSE seq リングバッファ / TUI 保持判定)は
   fixture ベースの unit test を実装前に書く(tdd-gate の型)
2. ワーカー管理は fake プロセスで状態機械テスト(spawn/idle-kill/異常終了/interrupt)
3. edith 実機 smoke: 使い捨てセッションで 一覧→history→message→stream→interrupt→再開 の全経路
4. **Evaluator agent + Codex review** を実装後に必ず(harness M3 + codex-validation)
5. 配備は edith の新 launchd **ではなく手動起動で smoke まで**(常駐化 = 本番効果は
   検証後の別ステップ。safety-core Gate 1 の対象になるため verifier artifact を添えて行う)

## 検証項目(spec 完了条件)

- [ ] unit: 全 green(パーサ・リング・排他・状態機械)
- [ ] smoke(edith 実機・使い捨てセッション): 8 機能全部の実観測ログ
- [ ] 401 / 409 / ワーカー異常終了 の3異常系を実際に発火させて観測
- [ ] 衝突テスト(lost-update 焦点・使い捨て2プロセス)— **結果は「TUI 保持 409 を外してよいか」の判断材料**。Phase I-1 の合格には含めない(read-only 設計で回避済みのため)
- [ ] WORKLOG.md 更新 + 実装ログ

## 実装メモ

- 言語: Node.js 素の `http`(edith に node あり・依存ゼロで監査しやすい)。dev = Jervis、
  実行 = edith(rsync で配布、athenas の教訓: 実行先でビルドしない → 依存ゼロならこの罠自体が無い)
- 置き場: `~/Infra/mobile-work/rc-backend/`(git init、local-only、テスト緑で auto-commit)
- 参照実装: `edith-claude-http.mjs` の bearer/env-allowlist/EPIPE 処理パターン(コピーでなく参照)
