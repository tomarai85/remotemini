# edith 既存資産の棚卸し — 自前 Remote Control 実装に向けて

調査: 2026-07-31、subagent(read-only)。全項目 edith 上で実地確認(SSH `mail-redacted@example.invalid`)。
推測は「推測」と明記。ファイルパス+行番号は確認時点のもの。

前提として読んだ文脈: `~/Infra/mobile-work/REQUIREMENTS.md`(§4 未決事項)、
`~/Infra/mobile-work/research/remote-control-teardown.md`(本家 RC の設計解剖)。
結論を先に一行で: **「本家 RC 相当のバックエンド」は edith に存在しない。あるのは (a) 全く別用途の
HTTP アダプタ、(b) セッション実体そのもの(jsonl)、(c) `-p --resume --output-format stream-json` で
既存セッションに1メッセージ足して streaming 応答を得る手段 — の3点。(c) が唯一、直接再利用できる。**

---

## 1. ポート 8643 の正体 — 依頼にあった「python3 プロセス」の特定

**依頼文の推測(HTTP アダプタでは)は外れていた。ここが今回いちばん重要な訂正。**

```
lsof -nP -iTCP:8643 -sTCP:LISTEN
  python3.1 42679 edith ... TCP 10.0.0.0:8643 (LISTEN)
ps -p 42679
  /Users/edith/Projects/edith/hermes-home/.venv/bin/python -m hermes_cli.main -p jervis gateway run --replace
launchctl list | grep -i edith
  42679  1  com.edith.jervis-gateway
```

- 正体 = `com.edith.jervis-gateway`。**Hermes-agent フレームワーク**(edith の別プロジェクト
  `~/Projects/edith/hermes-home/`、Python venv)の `jervis` プロファイル用 api_server。
- plist: `~/Projects/edith/services/com.edith.jervis-gateway.plist:3-27`。コメントに「JervisGlass
  voice client (MBP) が POST する、Discord 無しの常時稼働 gateway」「Bearer 認証は
  `/Users/edith/.edith/jervis-api-server.key`」「`com.edith.claude-adapter`(:11435)に依存 =
  先に立ち上がっている必要」と明記。
- plist ヘッダに「(DRAFT — NOT loaded; launchctl load is Tom-gated)」とあるが、**実際には稼働中**
  (`launchctl list` に PID 42679 で載っている)。ドキュメントが古いか、Tom が別途 load 済み。
- **今回の RC 構想とは無関係**。iPhone → Claude Code セッション操作の話に、この gateway が絡む所は無い。
  ただし「edith 上で 8643 を使う python の常駐プロセスがある」事実は今後 RC 用ポートを選ぶ際に
  衝突回避として覚えておく価値はある。

## 2. `edith-claude-http.mjs` — 依頼の本命だったが、用途が違う

`~/Projects/edith/bin/edith-claude-http.mjs`(42418 バイト、`com.edith.claude-adapter` として
PID 42698 で稼働中、`127.0.0.1:11435` 限定 listen)。

**何のためのプログラムか**(冒頭コメント `edith-claude-http.mjs:2-31`):
Hermes(EDITH の脳)に、Tom の Claude **サブスク**を OpenAI 互換の LLM プロバイダとして食わせるための
シム。Hermes 側は `provider:"custom", base_url:"http://127.0.0.1:11435/v1"` として叩く。
中身は `claude -p` を spawn し、テキスト応答を Hermes の tool_calls 形式へ再整形する
「TOOL-CALL ADAPTER」(`:164-179`)。**Claude Code の対話セッションを一覧・操作する API ではない。**

- **公開エンドポイントは2つだけ**(`grep 'app\.\|createServer\|listen('` の実測、`:675,689,692,812`):
  `GET /v1/models` と `POST /v1/chat/completions`(コメントに「non-streaming v0」と明記)。
  セッション一覧・resume・履歴取得に相当する API は無い。
- 認証: ローテート可能な bearer key ファイル(`~/.edith/shim.key`、`:57-67`)。実測で
  `curl 127.0.0.1:11435/v1/models` → `{"error":{"message":"unauthorized",...}}`(キー無しで弾かれる
  = 生きている・fail-closed が機能している証拠)。
- サブスク限定の保証: 起動時に `ANTHROPIC_API_KEY` 等メータリング系 env が1つでもあれば起動拒否
  (`meteringVarsPresent`/`startupRefuseReason`、`:77-101`)。spawn 環境もアローリストで組み直す
  (`buildSpawnEnv`、`:103-129`)。この設計思想(サブスクのみで課金経路を構造的に閉じる)は
  RC バックエンドでもそのまま踏襲する価値がある。
- **WARM-POOL**(`:26-31, 349-`、`EDITH_WARM_POOL=1` で有効化): `claude` を
  `--output-format stream-json` で事前に spawn しておき、`${model} ${system}` でバケット化、
  1リクエスト使い切りで破棄。狙いは cold-start のレイテンシ削減。**この「system prompt 別に
  プロセスを温めておく」設計は、後述(§4)で実測した cache-miss による 2〜3 秒の TTFT を
  RC 側でも潰すための直接のヒントになる。**
- `--append-system-prompt` で Hermes の SOUL を Claude Code 自身のシステムプロンプトより
  優先させるテクニック(`:16-24`)も、もし RC 側で「アシスタント人格を差し替えたい」局面が来れば
  再利用できる。

**評価**: コードの**パターン**(Node.js + spawn + bearer 認証 + ローテート可能キー + warm pool +
アローリスト env)は上質で再利用に値するが、**セッション一覧/選択/resume という中核機能そのものは
ゼロから書く必要がある**。この adapter を改造の起点にするのは筋が悪い(全く違う契約
= OpenAI chat/completions 形式であり、Claude Code のネイティブ `--resume`/jsonl 形式とは無関係)。

## 3. セッションの実体 — `~/.claude/projects/` の構造

```
~/.claude/projects/ 配下(edith, 2026-07-31 実測)
  -                                              312 jsonl   ← cwd "/" 起点
  -Users-edith-Projects-edith                    113 jsonl   ← EDITH 自身の SDK 駆動ログ
  -Users-edith                                    36 jsonl   ← 同上(cwd /Users/edith)
  -Users-edith-Projects-edith-tools-mail-cards      5 jsonl
  -Users-Shared-dev-roundtrip                       3 jsonl   ← ★人間が対話で使っている実セッション
  -Users-Shared-dev-transplant-test                 3 jsonl
  -Users-Shared-dev                                 3 jsonl
  -Users-edith-Projects-edith-tools-memory-loop     1 jsonl
  -Users-edith-Projects                             1 jsonl
  -Users-rai-auto-mation-client-a...                0 jsonl
  -Users-tomtim                                     0 jsonl
```

**重要な発見(推測ではなく jsonl の `entrypoint` フィールドで確認済み)**:
edith 上の `~/.claude/projects/` には性質の異なる2種類のセッションが混在している。

- `entrypoint:"sdk-cli"` = EDITH エージェント自身が Claude Agent SDK 経由で動かした自動化ログ
  (`-Users-edith-Projects-edith`(113件)・`-Users-edith`(36件)・おそらく `-`(312件)もここ)。
  中身は `queue-operation` / dispatch 承認待ちの下書きなど、EDITH の内部運用記録であって
  「Tom が phone から見たい会話」ではない。
- `entrypoint:"cli"` = 人間がターミナルで対話した実セッション。実測は
  `-Users-Shared-dev-roundtrip/ac686843-...jsonl:8`(`"entrypoint":"cli","cwd":"/Users/Shared/dev/roundtrip"`)。
  `tmux list-panes -a` で確認した現在の tmux セッション `work`(2026-07-28作成)のカレントディレクトリも
  同じく `/Users/Shared/dev/roundtrip`(pane_current_command が Claude Code のバージョン文字列
  "2.1.220" を表示 = 対話 TUI が前面で動いている状態と一致)。これが REQUIREMENTS.md に言う
  「到達範囲=1本のみ」の実体。
- **RC UI 実装への含意**: 一覧表示の対象は `entrypoint` で絞る必要がある。EDITH 自身の
  sdk-cli ログまで一覧に出すと、Tom が phone から見たい「自分の対話」がノイズに埋もれる。
  逆に言えば `entrypoint:"cli"` かつ最近更新の project だけを候補にすれば実用的な一覧になる。
  (★REQUIREMENTS.md の「edith のセッション数=11」という7/30実測値とは合わない — 現在は
  上記の通り数百件ある。おそらく7/30時点は `entrypoint:"cli"` だけで絞った数、または
  EDITH 自身の自動化ログがその後増えた。**この差分の原因は未確認 — 推測で埋めない**。)

**タイトル/最終更新メタデータの取り出し方**(実測、テストセッションで確認 — 詳細は§4):
- 各会話について、通常メッセージ行とは別に **`{"type":"ai-title","aiTitle":"<生成タイトル>"}`**
  という1行が非同期で追記される(実測: `~/.claude/projects/-private-tmp-rc-asset-survey-test/
  322828d7-248e-4f75-a3f1-de45b90ac348.jsonl:13`)。これが `--resume` picker のタイトル欄の出所と
  推測される(picker の内部実装までは未確認 = **推測**)。Haiku モデルで生成されていると見られる
  (同リクエストの `modelUsage` に `claude-haiku-4-5-20251001` が計上されていた — 推測混じり)。
- `{"type":"last-prompt","lastPrompt":"...",...}` 行が各ターン後に更新される = 「最後の意味ある
  メッセージ」を安く取得したいなら、jsonl 全体をパースせず**この行だけ tail から探す**のが軽い。
- ファイルの `mtime`(`ls -la` の更新日時)がそのまま「最終更新」に使える。実装コストゼロ。
- `bridge-pointer.json`(`-Users-Shared-dev-roundtrip/bridge-pointer.json`)は
  `{"sessionId":"session_...","environmentId":"env_...","source":"standalone","pid":4043,...}` という
  別種のファイルで、Claude Code on the web / cloud 連携(teardown 資料 §6 の "Claude Code on the web")
  の登録情報らしき内容(**推測**、中身の仕様は未確認)。RC 自作には直接関係なさそう。

## 4. `claude -p --resume <id> --output-format stream-json` の実測

**REQUIREMENTS.md/teardown が未検証としていた「既存セッションに1メッセージ足して streaming で
返答を得る」を、edith 上に新規テストセッションを1つ作って実測した(既存セッションへの書き込みは
一切していない)。**

手順と結果:
```
SID=$(uuidgen); claude-work -p "Reply with exactly: TEST1" --session-id "$SID" --output-format json
  -> account=sdgs / {"result":"TEST1",...,"session_id":"<SID>",...}   (新規セッション作成、成功)

claude-work -p "Reply with exactly: TEST2" --resume "$SID" --output-format stream-json --verbose
  -> NDJSON ストリーム: {"type":"system","subtype":"init",...}
                      → {"type":"assistant","message":{...,"content":[{"type":"text","text":"TEST2"}]},...}
                      → {"type":"rate_limit_event",...}
                      → {"type":"result","result":"TEST2",...}
```

- **動く。`--resume` で前ターンの文脈を引き継ぎ、`stream-json` で NDJSON の逐次イベントを吐く。**
  チャット UI のバックエンドが「1メッセージ = 1プロセス起動、stdout を行単位で読んでフロントへ
  中継」という設計で作れることを裏付ける実測。
- セッション jsonl 側にも `entrypoint:"sdk-cli"`(`-p` は SDK と同じ扱いになる。対話 TUI の
  `entrypoint:"cli"` とは別。実測: `.../322828d7-...jsonl:9,18`)、`promptSource:"sdk"` として
  正しく追記された。既存の対話セッション向け jsonl フォーマットと完全互換。
- **未検証・重要なリスク**: 上のテストは「一度も対話 TUI で開いていない、`-p` 専用セッション」に
  対してのみ行った。**「今まさに tmux 内で対話 TUI が掴んでいるセッション ID」に対して
  同時に `-p --resume` を打つとどうなるか(ファイルロック競合・履歴破損・二重書き込み)は
  未確認**。teardown 資料が言う本家 RC の大前提「1対話プロセス=1RCセッション」はここでも
  効いている可能性が高く、実装前に一度だけ、使い捨てのセッションで衝突テストをする価値がある。
- **コスト/レイテンシの実測値**(`-p` 呼び出し1回あたり、キャッシュ未ヒット時):
  - TTFT 約2.3〜3.2秒。system prompt(CLAUDE.md・約40個の skill 説明・agent 一覧)の
    キャッシュ作成に `cache_creation_input_tokens` 約31,000 トークンかかっていた
    (`total_cost_usd` 換算で1回 $0.19 相当 — **これは API 従量課金ではなくサブスク内の
    参考値換算**。`claude-work` は `CLAUDE_CODE_OAUTH_TOKEN` = setup-token 経由でサブスク消費
    であり、per-use 課金ではない。ただし応答の `rate_limit_info` に
    `"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":
    "org_level_disabled"` とあり、**5時間ウィンドウのレート制限に食い込む** — 頻繁な
    `-p --resume` ポーリングは Tom 本人の対話利用と同じ枠を奪い合う)。
  - この cache-miss の原因は `"cache_miss_reason":{"type":"system_changed",...}` — 呼び出しごとに
    system prompt(CLAUDE.md 等)が変わったと判定されキャッシュが効いていない。§2 の
    warm-pool の発想(system 文字列をキーにプロセスを温存)がここでも効くはずで、RC 実装では
    「メッセージが来るたびプロセスを新規 spawn」ではなく、**system prompt 固定のプロセスを
    再利用する / cache TTL 内に次のメッセージを送る**設計にしないと、毎回3秒+のレイテンシと
    レート制限消費を払うことになる。
- 使ったアカウント: `account=sdgs`(`~/個人/heartbeat/tokens/claude-token-sdgs`
  → `.claude-oauth-token` シンボリックリンク先と実測一致)。`README-AUTH-LANES.md`
  記載のレーンAが実際に機能していることも同時に確認できた。

**後片付け**: `/tmp/rc-asset-survey-test` の削除を試みたが、edith 側のフックに
`[goal-loop] recursive rm under HOME blocked in unattended loop (irreversible)` でブロックされた
(自律ループ内の再帰 rm を止める安全策 — 正しい挙動)。よって **テスト成果物は edith 上に残っている**:
- `/tmp/rc-asset-survey-test/`(スクラッチディレクトリ)
- `~/.claude/projects/-private-tmp-rc-asset-survey-test/322828d7-248e-4f75-a3f1-de45b90ac348.jsonl`
  (今回作った使い捨てテストセッション。中身は "TEST1"/"TEST2" の往復のみ、機微情報なし)
Tom の判断で削除するか、次の実装検証にそのまま使うか選べる。

## 5. `~/fleet-tools/claude-work` と `~/fleet-tools/phone-shell`

- **`phone-shell`**(`~/fleet-tools/phone-shell`、2026-07-29導入): iPhone(Termius)の SSH 鍵の
  forced command。対話ログインなら `tmux -u new-session -A -D -s work` を強制(既存クライアントを
  `-D` で追い出す = 同時に1台しか繋げない設計)。sftp/scp や mosh-server は素通し。tmux が
  無ければ生シェルへフォールバック。**このスクリプト自体は「常に固定の tmux セッション名 `work`
  1本」に縛る作りなので、複数セッションを選ばせる RC UI を作るなら phone-shell 側の変更(または
  phone-shell を経由しない別の入口)が要る** — REQUIREMENTS.md §4-1 の未決とも符合する。
- **`claude-work`**(`~/fleet-tools/claude-work`): `claude` を直接呼ばず、これ経由で呼ぶための
  ラッパー。heartbeat 側の `~/個人/heartbeat/.claude-oauth-token`(symlink)から
  `CLAUDE_CODE_OAUTH_TOKEN` を読んで export、`ANTHROPIC_API_KEY` を明示的に unset してから
  `exec claude "$@"`。**RC バックエンドが `claude -p --resume` を叩く時は、素の `claude` ではなく
  必ずこの `claude-work` を経由すべき**(fleet の認証切替・failover の恩恵をタダで受けられる。
  自前で二重に token 管理を書く必要がない、という設計思想がコード内コメントに明記されている)。
- **`README-AUTH-LANES.md`**(`~/fleet-tools/README-AUTH-LANES.md`): レーンA(setup-token、
  保守されている正本)とレーンB(Keychain `/login`、腐る・使うな)を明記。レーンAが実際に
  機能していることは今回の実測(`account=sdgs`)で裏付けられた。対話 TUI 経由(非 `-p`)での
  `claude-work` 使用は「未実測」と明記されており(`README-AUTH-LANES.md` 内)、今回も対話 TUI 側は
  検証していない(`-p` のみ実測)。

## 6. まとめ表 — 何が使えて、何が無いか

| 資産 | 状態 | RC 自作への再利用性 |
|---|---|---|
| `edith-claude-http.mjs`(:11435) | 稼働中・健全(bearer 認証で弾かれることまで確認) | 契約が違う(OpenAI chat/completions)。セッション一覧/resume API 無し。**warm-pool・bearer rotation・allowlist env の設計パターンだけ**流用価値あり |
| port 8643 (jervis-gateway) | 稼働中 | **無関係**(Hermes/JervisGlass 用。今回の誤同定を訂正済み) |
| `~/.claude/projects/*.jsonl` | 実データ確認済み | セッション一覧のデータソースそのもの。ただし `entrypoint` で人間対話とEDITH自動化を選別する処理が必須 |
| `ai-title` / `last-prompt` 行 | 実測で存在確認 | タイトル・最終メッセージ取得の正攻法。picker 内部の完全な仕様は未確認 |
| `claude -p --resume --output-format stream-json` | 実測で動作確認 | **これが本命**。1メッセージ=1プロセスの chat UI backend がそのまま組める。ただし cache-miss レイテンシ(2-3秒)とレート制限消費の設計対策が要る。稼働中セッションへの同時アクセス安全性は未検証 |
| `claude-work` | 実測で動作確認(account=sdgs) | RC backend は素の `claude` でなく必ずこれ経由にする |
| `phone-shell` | 稼働中(tmux "work"固定) | 複数セッション対応には改修必須。現状は1本固定の設計 |
| heartbeat token lane | 実測で整合確認 | そのまま前提にしてよい。触る必要なし |

## 未確認のまま残した論点(推測で埋めていない)

1. `--resume` picker がタイトル/一覧をどう並べているかの内部実装(`ai-title`/`last-prompt`/mtime を
   組み合わせている「らしい」までが実測、正確なソートロジックは未確認)。
2. 対話 TUI が掴んでいるセッションに対して外部から `-p --resume` を打った時の安全性(今回は
   意図的に未対話の使い捨てセッションでのみ検証。実セッションでの検証は要・別途合意)。
3. `claude-work` を対話 TUI モード(非 `-p`)で使った場合の挙動(README 自身が「未実測」と明記)。
4. REQUIREMENTS.md の「edith セッション数=11」(7/30計測)と今回観測した数百件との差分の原因。
