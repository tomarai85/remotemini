// ローカル E2E — 偽 claude-work と**偽 tmux** を注入してサーバの全経路を通す。
// 実 claude・実セッション・実 tmux に一切触れない。実行: node test/e2e-local.mjs
//
// 経路は3つ(DESIGN §2.9 / HANDOFF §1-A):
//   tmux 注入  = 机で開かれている会話。入力欄が実在する時だけ送る(生成中でも送れる)
//   ワーカー   = 開かれていない会話(-p --resume)
//   blocked    = 同じ cwd に claude が複数で特定不能 → どちらにも送らない
// 偽 tmux は send-keys を**全部ログに残す**ので「1文字も送っていない」を実測で言える。
import { spawn, execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, chmodSync, existsSync, rmSync, utimesSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createSseParser, decodeEvent } from "../src/frames.mjs";
import { PANE_SEP } from "../src/inject.mjs";
import { readHead, writeHead } from "../src/heads.mjs";
// ★13-D で使う。サーバと**同じ関数**を読むが、渡す引数は検査が自分で名指しする。
//   同じ関数を使う事自体は恒真ではない —— 恒真になるのは「サーバが渡した物」を期待値の
//   材料にした時。掴みたい欠陥は「呼んでいない」ではなく「**違う物を渡した**」。
import {
  routeLabel, subtitleOf, scanLine, whoOf, gapNotice, choiceView,
  sendResult, interruptResult, choiceResult, clearQueueResult,
} from "../src/view.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SB = mkdtempSync(join(tmpdir(), "rc-e2e-"));
// roots の台帳(対照表 #11)。root = sandbox 自身(会話の cwd も此の下に在る)。
const ROOTS_LEDGER = join(SB, "roots-ledger");
writeFileSync(ROOTS_LEDGER, `# e2e roots\n${SB}\n`);
const PROJ = join(SB, "projects", "-rc-e2e-work");
mkdirSync(PROJ, { recursive: true });
// ★§3-V: ワーカー経路は「会話の居場所が Claude Code に信頼済みか」を見る(src/trust.mjs)。
//   本物の `~/.claude.json` は**読ませない** —— 環境で結果が変わる検査は検査ではない。
//   受理される筈の cwd は**実在する砂場の dir**にする。前は `/Users/Shared/dev/roundtrip`
//   という**この機械に在るとは限らない**文字列で、在っても信頼一覧には無かった
//   (2026-08-03: §3-V を当てた直後、これだけで e2e が 12 件落ちた)。
const CWD_WORK    = join(SB, "work");     // 一覧に在る       → 受理
const CWD_NOTRUST = join(SB, "notrust");  // 実在するが一覧に無い → 409 cwd_untrusted
const CWD_GONE    = join(SB, "gone");     // 一覧に在るが dir が無い → 409 cwd_missing
const TRUST_FILE  = join(SB, "trust.json");
const SID1 = "11111111-1111-1111-1111-111111111111";
// 道具の結果の畳み込み(2026-09-03、queue transcript-tool-output-folds-into-the-entry)専用の
// fixture。SID1 に足さないのは、SID1 の行数(:145 の註)と `histShape` の完全一致検査
// (下の「history has user+assistant+tool」)を壊さない為 —— 別の会話にすれば両方無傷。
const SID_TOOL_OUTPUT = "aaaaaaaa-0000-0000-0000-000000000099";
// 注入経路の fixture。cwd は SID1(/Users/Shared/dev/roundtrip)と必ず別にする —
// 同じにすると既存のワーカー経路テストが注入経路に化けて、何を測ったか分からなくなる。
const SID_READY  = "44444444-4444-4444-4444-444444444444"; // READY のペインがある
const SID_CHOICE = "55555555-5555-5555-5555-555555555555"; // 選択待ちのペインがある
const SID_SHELL  = "66666666-6666-6666-6666-666666666666"; // cwd は合うが素の zsh しか居ない
const SID_AMBIG  = "77777777-7777-7777-7777-777777777777"; // 同 cwd に claude が2つ
const SID_GEN    = "88888888-8888-8888-8888-888888888888"; // 生成中(★8/01 の設計では送れる)
const SID_DEAF   = "99999999-0000-0000-0000-000000000009"; // 本文を送っても画面が動かないペイン
const SID_RACE   = "99999999-0000-0000-0000-00000000000a"; // 本文の直後に選択画面が割り込むペイン
// ★割り込みの継ぎ目(2026-08-03 追加)。この2本は**対**で意味を持つ。
//   単体テストでは `interrupt()` の三値を撃ってあるが、それは注入器の中だけの話で、
//   「電話が受け取る JSON まで実測が届くか」は別の問題。実際 8/02 まで、e2e の割り込み
//   検査は `route`/`pane`/キーしか見ておらず、**押した事だけ**を確かめていた。
//   OK   = Escape で印が消えるペイン   -> stopped:"verified"
//   STUCK= Escape を受けても印が残る    -> stopped:"unverified"(押したが止まっていない)
//   2本とも同じ画面から始まるので、判定を分けているのは**Escape 後の画面だけ**になる。
const SID_INTR_OK    = "99999999-0000-0000-0000-00000000000b"; // 割り込みで実際に止まる
const SID_INTR_STUCK = "99999999-0000-0000-0000-00000000000c"; // 割り込んでも止まらない
// ★選択メニューへの打鍵(§2.29)の対。**電話が受け取る JSON まで**実測を届かせる為に居る。
//   BENIGN = `/model` の選択(実機)         -> 打鍵が飛ぶ
//   PERM   = Bash の許可確認(実機)         -> 409、send-keys は 0 件
//   単体では両方通っているが、e2e に無いと「サーバ側で digest を埋めてしまう」等の
//   HTTP 層だけの緩みが素通りする。実際 8/02 の割り込みが同じ形で緩んでいた。
const SID_PERM = "99999999-0000-0000-0000-00000000000d"; // 許可確認が出ている(打ってはいけない)
const CWD_READY  = "/Users/Shared/dev/ready";
const CWD_CHOICE = "/Users/Shared/dev/choice";
const CWD_SHELL  = join(SB, "shell"); // ★ワーカーへ落ちた後**受理される**必要が在る(一覧に載せる)
const CWD_AMBIG  = "/Users/Shared/dev/ambig";
const CWD_GEN    = "/Users/Shared/dev/busy";
const CWD_DEAF   = "/Users/Shared/dev/deaf";
const CWD_RACE   = "/Users/Shared/dev/race";
const CWD_INTR_OK    = "/Users/Shared/dev/intr-ok";
const CWD_INTR_STUCK = "/Users/Shared/dev/intr-stuck";
const CWD_PERM       = "/Users/Shared/dev/perm";
// ★diff(#4、2026-09-02、扉F)。`sessiondiff.mjs` の頭の註が「配線は `test/e2e-local.mjs` の
//   扉F が実サーバへ HTTP を撃って測る」と書いていたが、其の扉は無かった —— 此処が其れ。
//   git を本当に撃つので**実在する dir**が要る(単体は fake exec で git に触れていない)。
const SID_DIFF          = "99999999-0000-0000-0000-00000000000e"; // 実 git repo・変更あり
const SID_DIFF_NOTREPO  = "99999999-0000-0000-0000-00000000000f"; // 実在する dir だが git 管理外
const CWD_DIFF         = join(SB, "diff-repo");
const CWD_DIFF_NOTREPO = join(SB, "diff-notrepo");
// 登録簿(session_id -> pane)の検証用。**全部同じ cwd に置く** — 登録が無ければ
// 特定不能になる状況を作り、登録があれば1つに定まることを同じ場に並べて見せるため。
const SID_REG_A    = "aaaaaaaa-0000-0000-0000-00000000000a"; // 登録あり -> %20
const SID_REG_B    = "aaaaaaaa-0000-0000-0000-00000000000b"; // 登録あり -> %21
const SID_REG_C    = "aaaaaaaa-0000-0000-0000-00000000000c"; // 登録なし(他が名乗り済み)
const SID_STALE    = "aaaaaaaa-0000-0000-0000-00000000000d"; // %20 を古く名乗っている
const SID_MISMATCH = "aaaaaaaa-0000-0000-0000-00000000000e"; // 登録先ペインの居場所が違う
const CWD_REG   = "/Users/Shared/dev/reg";
const CWD_OTHER = "/Users/Shared/dev/other";
// ★上限の告知が出ている会話(2026-08-02 追加)。分類器(inject)と電話の表示(view)は
// それぞれ単体で撃たれていたのに、**その間の `server.mjs` が JSON に載せる継ぎ目**を
// 読む検査が1本も無かった(実測: `grep -rn limited test/` の全ヒットが `classifyScreen` と
// `routeLabel` の直呼びで、HTTP 応答を読む物はゼロ)。両端が緑でも間で落ちれば人に届かない。
const SID_LIMIT = "aaaaaaaa-0000-0000-0000-000000000012";
const CWD_LIMIT = "/Users/Shared/dev/limited";
// 未登録のまま、その cwd に claude が**1つだけ**居る会話。cwd 一致を同定として使うと
// ここが注入されてしまう(= 他人の会話に本文が入る事故)。設計上ここは必ず拒否する。
const SID_UNREG = "aaaaaaaa-0000-0000-0000-000000000011";
const CWD_UNREG = "/Users/Shared/dev/unreg";
// 「開いただけでまだ一度も発言していない会話」= jsonl が存在しない(2026-07-31 edith 実測)。
// **わざと fixture を作らない** — それがこの状態の定義そのもの。
const SID_FRESH = "aaaaaaaa-0000-0000-0000-00000000000f"; // 登録あり・ペイン %23 が生きている
const SID_GONE  = "aaaaaaaa-0000-0000-0000-000000000010"; // 登録あり・そのペインはもう無い
const CWD_FRESH = "/Users/Shared/dev/fresh";
// ★ワーカーが**死ぬ瞬間**と最後の一行の順序を、本物の子で測る為の2本(2026-08-04、
//   DESIGN §2.35 の未測定の懸念)。ペインは**わざと置かない** —— SID1 と同じで
//   「机の上に開かれていない会話」= ワーカー経路。cwd は信頼一覧に載せて実在させる。
//   分岐の鍵は **cwd**。会話 ID は `--fork-session` / `--resume` で書き換わるが cwd は不変。
const SID_DEATH_LATE = "aaaaaaaa-0000-0000-0000-000000000040"; // 孫が stdout を握ったまま親が先に死ぬ
const SID_DEATH_PART = "aaaaaaaa-0000-0000-0000-000000000041"; // 最後の行が**改行の前**で切れて死ぬ
const CWD_DEATH_LATE = join(SB, "death-late");
const CWD_DEATH_PART = join(SB, "death-part");
// ★孫が**いつ書くか**を検査が持つ為の合図(2026-08-05、13-W-a の揺らぎを根治)。
//   合図が来るまで孫は書かない = 「孫が pipe を握ったまま」の状態を検査側が保てる。
//   直す前は孫が `time.sleep(0.35)` で書いていて、13-W-a の順序が**暗黙の壁時計依存**
//   だった(12-h と同じ病)。経緯と実測はこの file の 13-W-a の頭に書いた。
const DEATH_GATE = join(SB, "death-gate");
// ★「送信待ちが実在する会話」を**作れる様にする**為の1本(2026-08-04、送信待ちの取り消し)。
//   偽ワーカーは既定では即座に echo を返すので、busy の窓が数 ms しか無く、そこへ2本目を
//   届けようとすると**運で結果が変わる検査**になる。運で緑になる検査は、赤にもなる。
//   遅らせる栓(`RC_E2E_WORKER_DELAY_MS`)は**全会話に効く**ので、他の 30 本以上の検査の
//   待ち時間をこの1本の都合で伸ばす事になる。だから死に方と同じく **cwd で分ける**。
const SID_SLOW = "aaaaaaaa-0000-0000-0000-000000000042"; // 応答が遅い = 送信待ちを積める
const CWD_SLOW = join(SB, "slow-queue");
// ★この会話の turn が**終わる時刻を検査が持つ**為の合図(2026-08-05)。`<この path>.<turn番号>`
//   を置くと、偽ワーカーの その turn が答える。理由は 12-h の頭に書いた。
const SLOW_GATE = join(SB, "slow-gate");
const releaseSlowTurn = (n) => writeFileSync(`${SLOW_GATE}.${n}`, "");
// H2(DESIGN §2.18-10)の継ぎ目用。頭が**未登録**の会話と、**登録済み**の会話。
const SID_H2_NEW  = "aaaaaaaa-0000-0000-0000-000000000020"; // 頭なし -> fork する筈
const SID_H2_HEAD = "aaaaaaaa-0000-0000-0000-000000000021"; // 頭あり -> その先端へ resume
const H2_HEAD_ID  = "bbbbbbbb-0000-0000-0000-000000000021"; // 上の枝の先端
const H2_FORK_ID  = "cccccccc-0000-0000-0000-0000000000ff"; // 偽ワーカーが名乗る新 ID
// 鍵の待ち上限。既定(4)のままだと満杯を作るのに6本の要求を**ほぼ同時に**届ける必要があり、
// 負荷が乗ると到着が散って作れない(実測と理由は server.mjs の栓に書いた)。ここを小さくすると
// 必要な本数が減るだけで、測る性質(満杯の時の割り込み)は変わらない。
const MAX_WAITERS = 1;

writeFileSync(join(PROJ, `${SID1}.jsonl`), [
  // ★`permissionMode` を足した(対照表 #16、2026-09-02)。行数は変えない —— :178 の註が
  //   「SID1 は4行、1チャンクで足りる」を前提に読んでいる。
  JSON.stringify({ entrypoint: "cli", cwd: CWD_WORK, type: "user", message: { role: "user", content: "最初の質問" }, permissionMode: "bypassPermissions" }),
  JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "最初の答え" }, { type: "tool_use", name: "Bash", input: {} }] } }),
  JSON.stringify({ type: "ai-title", aiTitle: "検証用の会話" }),
  JSON.stringify({ type: "last-prompt", lastPrompt: "最初の質問" }),
].join("\n"));
writeFileSync(join(PROJ, "22222222-2222-2222-2222-222222222222.jsonl"),
  JSON.stringify({ entrypoint: "sdk-cli", cwd: "/x", type: "user", message: { content: "noise" } }));

// 道具の結果の畳み込み(2026-09-03、queue transcript-tool-output-folds-into-the-entry)。
// `tool_use` に id を持たせ、其の直後の行で `tool_result` を返す —— Claude Code の転写形
// (此の repo に実例が無かったので queue の brief に書かれた形をそのまま採った)。
const TOOL_OUTPUT_MARKER = "E2E_TOOL_OUTPUT_MARKER";
writeFileSync(join(PROJ, `${SID_TOOL_OUTPUT}.jsonl`), [
  JSON.stringify({ entrypoint: "cli", cwd: CWD_WORK, type: "user", message: { role: "user", content: "道具を使って" } }),
  JSON.stringify({
    type: "assistant",
    message: {
      role: "assistant",
      content: [
        { type: "text", text: "取りかかります" },
        { type: "tool_use", id: "toolu_e2e_1", name: "Bash", input: {} },
      ],
    },
  }),
  JSON.stringify({
    type: "user",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_e2e_1", content: `${TOOL_OUTPUT_MARKER}\n2行目` }] },
  }),
  JSON.stringify({ type: "ai-title", aiTitle: "道具の結果" }),
].join("\n"));

const FIXTURED = new Set();
// ★`permissionMode` は既定で**省く**(第4引数を渡した呼び手だけが持つ)。全呼び手に
//   焼くと、対照表 #16 の検体を1つ足す為だけに既存の全 fixture の形が変わってしまう。
function fixture(sid, cwd, title, permissionMode) {
  // ★同じ id を二度書かない。黙って上書きすると、**先に書いた会話の設定が消えた事**が
  //   どこにも出ず、無関係な検査が落ちて原因が id の衝突だと分からなくなる(2026-08-03 に実演)。
  if (FIXTURED.has(sid)) throw new Error(`fixture の id が衝突している: ${sid}(${title})`);
  FIXTURED.add(sid);
  writeFileSync(join(PROJ, `${sid}.jsonl`), [
    JSON.stringify({
      entrypoint: "cli", cwd, type: "user", message: { role: "user", content: "q" },
      ...(permissionMode ? { permissionMode } : {}),
    }),
    JSON.stringify({ type: "ai-title", aiTitle: title }),
  ].join("\n"));
}
fixture(SID_H2_NEW, CWD_WORK, "H2 頭なし");
fixture(SID_H2_HEAD, CWD_WORK, "H2 頭あり");
fixture(SID_READY, CWD_READY, "注入READY", "plan"); // 対照表 #16: tmux 経路の permissionMode 検体
fixture(SID_CHOICE, CWD_CHOICE, "注入CHOICE");
fixture(SID_SHELL, CWD_SHELL, "シェルのみ");
fixture(SID_AMBIG, CWD_AMBIG, "特定不能");
fixture(SID_GEN, CWD_GEN, "生成中");
fixture(SID_DEAF, CWD_DEAF, "画面が動かない");
fixture(SID_RACE, CWD_RACE, "選択画面が割り込む");
fixture(SID_INTR_OK, CWD_INTR_OK, "割り込むと止まる");
fixture(SID_INTR_STUCK, CWD_INTR_STUCK, "割り込んでも止まらない");
fixture(SID_PERM, CWD_PERM, "許可確認が出ている");
for (const sid of [SID_REG_A, SID_REG_B, SID_REG_C, SID_STALE]) fixture(sid, CWD_REG, `登録${sid.slice(-1)}`);
fixture(SID_UNREG, CWD_UNREG, "未登録");
fixture(SID_LIMIT, CWD_LIMIT, "上限に当たっている");
fixture(SID_MISMATCH, CWD_REG, "居場所不一致"); // 会話は CWD_REG。登録先ペインは CWD_OTHER に居る

// ★転写の探索(2026-09-01、§8 の扉E)。**後方読みが 1 チャンクで終わらない長さ**の会話。
//
//   何故 長さが要るか: `readLinesBackward` は 64 KiB ずつ後方へ遡り、file の先頭に
//   着いた時だけ `reachedStart: true` を返す。上の SID1 は 4 行なので最初のチャンクで
//   `pos === 0` に着き、**`searchedToStart` は常に true** —— 之だけを検体にすると、
//   `searchedToStart: true` を焼き付けた実装でも e2e は緑のままになる。
//   0 件の 2 意味(走査した範囲に無い / 会話の頭まで見て無い)は、この案件の核心なので、
//   **両方の値が実際に線へ出る**事を測れる検体を置く。
//
//   仕掛け: 目印は**末尾 3 件だけ**に置き、残りは詰め物。同じ問いを
//     `limit=1`  で撃つ → 最初のチャンクで一致が上限に達し、遡りが**そこで止まる**
//                          = `searchedToStart:false`
//     `limit=500` で撃つ → 上限に届かないので file の先頭まで遡る
//                          = `searchedToStart:true`
//   問いも file も同じで、違うのは `limit` だけ。よって差が出たなら、それは
//   **走査が本当に止まったか**の差以外ではあり得ない。
const SID_SEARCH = "aaaaaaaa-0000-0000-0000-000000000050";
const SEARCH_NEEDLE = "しっぽの目印";
{
  // ★`fixture()` と**同じ衝突の門**を通す(2026-09-01)。此処を素の `writeFileSync` で
  //   書いて、実際に `SID_NOTRUST`(…030)と衝突させた —— 私の 300 行の転写が
  //   2 行の `{"text":"q"}` に静かに上書きされ、探索の検査 3 本が「一致 0 件」で落ちた。
  //   :208 の註が 2026-08-03 に同じ事故を記録している。門を通せば次は名前で止まる。
  if (FIXTURED.has(SID_SEARCH)) throw new Error(`fixture の id が衝突している: ${SID_SEARCH}(探索用)`);
  FIXTURED.add(SID_SEARCH);
  const pad = "x".repeat(400); // 1 行 ≈ 450B。300 行で ≈ 135 KiB > 64 KiB のチャンク
  const lines = [
    JSON.stringify({ entrypoint: "cli", cwd: CWD_WORK, type: "user", message: { role: "user", content: `頭の一言 ${pad}` } }),
  ];
  for (let i = 0; i < 300; i += 1) {
    lines.push(JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: `詰め物 ${i} ${pad}` }] } }));
  }
  for (let i = 0; i < 3; i += 1) {
    lines.push(JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: `${SEARCH_NEEDLE} ${i}` }] } }));
  }
  lines.push(JSON.stringify({ type: "ai-title", aiTitle: "探索用の長い会話" }));
  writeFileSync(join(PROJ, `${SID_SEARCH}.jsonl`), lines.join("\n"));
}

// ★会話の実行環境(2026-09-03、対照表 #14-16)。`/digest` の `session` が**生きた机**から
//   model / gitBranch / contextTokens を運ぶか。単体(`digest-session.test.mjs`)は `digestOf` の
//   扉だけを測る —— 此処で測るのは、転写 → `readRawRecords` → `digestOf` → `digestBody` →
//   HTTP の**配線**。鍵名は `wire-key-agreement` が電話と縛るが、値が実際に線へ出るかは
//   此の 1 本しか見ない。
//   検体は friday の実転写の形(usage の 4 欄、model は message の中、gitBranch は行の上)。
const SID_RUNTIME = "aaaaaaaa-0000-0000-0000-000000000062";
{
  if (FIXTURED.has(SID_RUNTIME)) throw new Error(`fixture の id が衝突している: ${SID_RUNTIME}(実行環境)`);
  FIXTURED.add(SID_RUNTIME);
  const now = Date.now();
  const iso = (msAgo) => new Date(now - msAgo).toISOString();
  writeFileSync(join(PROJ, `${SID_RUNTIME}.jsonl`), [
    JSON.stringify({ entrypoint: "cli", cwd: CWD_WORK, type: "user", timestamp: iso(120_000), gitBranch: "main", version: "2.1.240",
      message: { role: "user", content: "q" } }),
    // 頭の応答: 別の model・大きい文脈。**尾が勝つ**事を測る為に、尾より大きい値を置く。
    JSON.stringify({ type: "assistant", timestamp: iso(90_000), gitBranch: "main", version: "2.1.240",
      message: { role: "assistant", model: "claude-sonnet-4-6", content: [{ type: "text", text: "old" }],
        usage: { input_tokens: 1, cache_creation_input_tokens: 90_000, cache_read_input_tokens: 0, output_tokens: 50 } } }),
    JSON.stringify({ type: "assistant", timestamp: iso(30_000), gitBranch: "main", version: "2.1.240",
      message: { role: "assistant", model: "claude-opus-5", content: [{ type: "text", text: "new" }],
        usage: { input_tokens: 2, cache_creation_input_tokens: 27_124, cache_read_input_tokens: 11_591, output_tokens: 2_624 } } }),
    JSON.stringify({ type: "ai-title", aiTitle: "実行環境の検体" }),
  ].join("\n"));
}

// ★`@` のパス補完(2026-09-02、扉E)。**実在する木**を砂場に建てて、其処を cwd に持つ
//   会話を1本と、cwd を**名乗らない**会話を1本置く。
//
//   何故 e2e が要るか(此の案件の核心): 2026-08-31 に `server.mjs` の新ルートを `const` の
//   宣言より前へ置いて全ルートを壊し、iOS 777 件 + backend 約 1000 件が緑のままだった。
//   捕まえたのは実サーバへ HTTP を撃つ対照 1 本だけ。**配線・順序・登録を変えたのだから、
//   関数の扉(`test/paths.test.mjs`)は証拠にならない。**
//   加えて此の口は `SESSION_ROUTE_RE`(動詞表)への登録が要る = 登録漏れは
//   404 でしか現れず、`completePaths` の検査を何本書いても永遠に緑になる。
const SID_PATHS    = "aaaaaaaa-0000-0000-0000-000000000060";
const SID_PATHS_NO = "aaaaaaaa-0000-0000-0000-000000000061"; // cwd を名乗らない会話
const CWD_PATHS    = join(SB, "paths-work");
{
  mkdirSync(join(CWD_PATHS, "src", "deep"), { recursive: true });
  mkdirSync(join(CWD_PATHS, "node_modules", "left"), { recursive: true });
  mkdirSync(join(CWD_PATHS, ".git"), { recursive: true });
  writeFileSync(join(CWD_PATHS, "README.md"), "x");
  // ★直下に「問いを**含む**が、問いで**始まらない**」名前(2026-09-02、変異 M2)。
  //   根の直下は枝刈りを通らないので、一致の規則そのものへ届く唯一の的になる。
  writeFileSync(join(CWD_PATHS, "old-README.md"), "x");
  writeFileSync(join(CWD_PATHS, "src", "wire.mjs"), "x");
  writeFileSync(join(CWD_PATHS, "src", "widget.mjs"), "x");
  writeFileSync(join(CWD_PATHS, "src", "deep", "wonder.txt"), "x");
  writeFileSync(join(CWD_PATHS, "node_modules", "left", "index.js"), "x");
  writeFileSync(join(CWD_PATHS, ".git", "HEAD"), "x");
}
fixture(SID_PATHS, CWD_PATHS, "補完の木");
{
  // cwd の欄そのものが無い転写。`fixture()` は必ず cwd を書くので手で組むが、
  // 衝突の門は同じ物を通す(:208 の 2026-08-03 の事故と、探索の検体の註と同じ理由)。
  if (FIXTURED.has(SID_PATHS_NO)) throw new Error(`fixture の id が衝突している: ${SID_PATHS_NO}(補完・cwd 無し)`);
  FIXTURED.add(SID_PATHS_NO);
  writeFileSync(join(PROJ, `${SID_PATHS_NO}.jsonl`), [
    JSON.stringify({ entrypoint: "cli", type: "user", message: { role: "user", content: "q" } }),
    JSON.stringify({ type: "ai-title", aiTitle: "作業場所を名乗らない会話" }),
  ].join("\n"));
}

// ---- 偽 tmux ----------------------------------------------------------------
// 実物の観測に合わせてある(2026-07-31 edith):
//   list-panes -F "#{pane_id}<SEP>#{pane_current_command}<SEP>#{pane_tty}<SEP>#{pane_current_path}"
//   → 対話 claude の command は "2.1.220"(バージョン文字列)、素のシェルは "zsh"
// ★区切りは本体から取る(PANE_SEP)。ここに文字列を写すと、本体が区切りを変えた時に
//   この偽物だけが古い区切りを喋り続け、e2e は緑のまま本番だけ壊れる(2026-08-02 の型)。
// ★§3-V の受理側/拒否側を**実在**で作り分ける。`CWD_GONE` は一覧にだけ載せて dir は作らない
//   —— 「一覧に在る」と「今そこに在る」が別物である事を e2e で押さえる為(変異 W22 の的)。
// ★番号は**実物を数えてから**取る。最初 ...21/...22 を当てて `SID_H2_HEAD`(:85)と衝突し、
//   H2 の転写を未信頼の cwd で上書きして H2 の検査2本を落とした(2026-08-03)。
const SID_NOTRUST  = "aaaaaaaa-0000-0000-0000-000000000030";
const SID_CWD_GONE = "aaaaaaaa-0000-0000-0000-000000000031";
for (const d of [CWD_WORK, CWD_SHELL, CWD_NOTRUST, CWD_DEATH_LATE, CWD_DEATH_PART, CWD_SLOW]) mkdirSync(d, { recursive: true });
writeFileSync(TRUST_FILE, JSON.stringify({ projects: {
  [CWD_WORK]:  { hasTrustDialogAccepted: true },
  [CWD_SHELL]: { hasTrustDialogAccepted: true },
  [CWD_DEATH_LATE]: { hasTrustDialogAccepted: true },
  [CWD_DEATH_PART]: { hasTrustDialogAccepted: true },
  [CWD_SLOW]: { hasTrustDialogAccepted: true },
  [CWD_GONE]:  { hasTrustDialogAccepted: true },   // 承諾はしたが dir はもう無い
  [join(SB, "declined")]: { hasTrustDialogAccepted: false }, // 項は在るが false(通してはいけない)
} }));
fixture(SID_NOTRUST, CWD_NOTRUST, "信頼されていない場所");
fixture(SID_CWD_GONE, CWD_GONE, "消えた場所");
fixture(SID_DEATH_LATE, CWD_DEATH_LATE, "死の順序:孫が握る");
fixture(SID_DEATH_PART, CWD_DEATH_PART, "死の順序:改行なし");
fixture(SID_SLOW, CWD_SLOW, "応答が遅い:送信待ち");

// ★diff(#4、扉F)。実 git repo を1本作る —— 単体(`sessiondiff.test.mjs`)は fake exec で
//   git そのものには一度も触れていない。此処は実サーバが実 git を撃つ所まで届かせる為。
mkdirSync(CWD_DIFF, { recursive: true });
mkdirSync(CWD_DIFF_NOTREPO, { recursive: true }); // 実在するが git init しない(git 管理外)
{
  const git = (args) => execFileSync("git", args, { cwd: CWD_DIFF, encoding: "utf8" });
  git(["init", "-q"]);
  git(["config", "user.email", "rc-e2e@example.invalid"]);
  git(["config", "user.name", "rc-e2e"]);
  writeFileSync(join(CWD_DIFF, "app.js"), "const x = 1;\n");
  git(["add", "app.js"]);
  git(["commit", "-q", "-m", "init"]);
  // 未 stage の変更(作業木)。
  writeFileSync(join(CWD_DIFF, "app.js"), "const x = 1;\nconst y = 2;\n");
  // stage 済みの変更(index)。
  writeFileSync(join(CWD_DIFF, "new.txt"), "new file\n");
  git(["add", "new.txt"]);
}
fixture(SID_DIFF, CWD_DIFF, "diff:実 git repo");
fixture(SID_DIFF_NOTREPO, CWD_DIFF_NOTREPO, "diff:git 管理外");
// cwd 欄そのものが無い会話(`fixture()` は必ず cwd を書くので、此処だけ手で書く —
// SID1 の直書きと同じ形)。server.mjs の `!cwd` 早期リターンは、之が無いと一度も通らない。
const SID_DIFF_NOCWD = "99999999-0000-0000-0000-000000000010";
writeFileSync(join(PROJ, `${SID_DIFF_NOCWD}.jsonl`), [
  JSON.stringify({ entrypoint: "cli", type: "user", message: { role: "user", content: "q" } }),
  JSON.stringify({ type: "ai-title", aiTitle: "diff:cwd 欄なし" }),
].join("\n"));

// ★配信(feed)が登録簿を**毎 tick 読み直す**事を測る為だけの会話。
//   登録先を %28 -> %29 に付け替えて、配信が追随するかを見る(13-Z)。
const SID_FEEDREG = "aaaaaaaa-0000-0000-0000-000000000043";
const CWD_FEEDREG = "/Users/Shared/dev/feedreg";
fixture(SID_FEEDREG, CWD_FEEDREG, "配信は登録簿を読み直す");

const PANES = [
  `%10${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys010${PANE_SEP}${CWD_READY}`,
  `%11${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys011${PANE_SEP}${CWD_CHOICE}`,
  `%12${PANE_SEP}zsh${PANE_SEP}/dev/ttys012${PANE_SEP}${CWD_SHELL}`,
  `%13${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys013${PANE_SEP}${CWD_AMBIG}`,
  `%14${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys014${PANE_SEP}${CWD_AMBIG}`, // 同じ cwd に2つめ
  `%15${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys015${PANE_SEP}${CWD_GEN}`,
  `%16${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys016${PANE_SEP}${CWD_DEAF}`,  // 送っても画面が動かない(load-bearing: Enter を出さない対照)
  `%17${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys017${PANE_SEP}${CWD_RACE}`,  // 本文の直後に選択画面が出る
  `%18${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys018${PANE_SEP}${CWD_LIMIT}`, // 上限の告知が出ている(送れるが答えは返らない)
  `%20${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys020${PANE_SEP}${CWD_REG}`,   // 登録簿検証: 同じ cwd に claude が3つ並ぶ
  `%21${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys021${PANE_SEP}${CWD_REG}`,
  `%22${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys022${PANE_SEP}${CWD_OTHER}`, // 居場所不一致の検証用
  `%23${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys023${PANE_SEP}${CWD_FRESH}`, // 未発言の会話が居るペイン(jsonl は無い)
  `%24${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys024${PANE_SEP}${CWD_UNREG}`, // 未登録の会話の cwd に居る唯一の claude
  `%25${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys025${PANE_SEP}${CWD_INTR_OK}`,    // 割り込みで印が消える
  `%26${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys026${PANE_SEP}${CWD_INTR_STUCK}`, // 割り込んでも印が残る
  `%27${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys027${PANE_SEP}${CWD_PERM}`,       // 許可確認が出ている
  `%28${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys028${PANE_SEP}${CWD_FEEDREG}`,    // 13-Z: 付け替え前の登録先
  `%29${PANE_SEP}2.1.220${PANE_SEP}/dev/ttys029${PANE_SEP}${CWD_FEEDREG}`,    // 13-Z: 付け替え後の登録先
].join("\n") + "\n";
// ★2026-08-01: 画面はもう手で書かない。使い捨てセッションから撮った生の capture-pane 出力
// (test/fixtures/screens/)をそのまま使う。前の版はここに手書きの画面を置いていて、
// "✻ Baking… (… esc to interrupt)" という**このビルドに存在しない行**を「実測の形」と
// 称して置いていた。コードと fixture が同じ誤解でできていたので、両方間違ったまま緑だった。
const SCREEN_DIR = join(ROOT, "test", "fixtures", "screens");
const shot = (name) => readFileSync(join(SCREEN_DIR, `${name}.txt`), "utf8");
const SCREENS = {
  "%10": shot("idle-boot"),
  "%11": shot("choice-model-menu"), // 選択メニュー。Enter が既定変更になる実物
  // ★わざと最悪ケースにしてある: **Claude Code の画面と1バイトも違わない**ものを
  //   素の zsh ペイン(command=zsh)に置いてある。画面判定では原理的に区別がつかない。
  //   ここで止めているのは「そのペインで動いているのが claude か」の判定だけ、という対照。
  //   これが素通りすると、cwd の一致だけでシェルに任意の文字列 + Enter を打ち込むことになる。
  "%12": shot("idle-boot"),
  "%13": shot("idle-boot"),
  "%14": shot("idle-boot"),
  "%15": shot("generating-spinner-visible"), // 生成中(スピナーが写っている枚)
  // ★生成中だがスピナーが**写っていない**枚(測り直し後も 1枚あたり 18-39% はこれ = §2.9-X-2)。
  //   ここが SENDABLE でなくなると reason が composer-mismatch でなく unknown になるので、
  //   下の 10-e2 が「スピナーの有無で送信を止めていないか」の回帰検査も兼ねる。
  //   加えて偽 tmux はこのペインだけ画面を更新しない = 本文が載らないペインの再現。
  "%16": shot("generating"),
  // ★本文を送った**直後に**選択画面が割り込むペイン(偽 tmux が %17 だけそう振る舞う)。
  //   分類 → 本文 → Enter の間に modal が出ると Enter が承認/課金になる、という競合の再現。
  "%17": shot("idle-boot"),
  // ★上限の告知が出ている実機の画面(edith 2026-08-02、メールのみ伏せ字)。
  //   入力欄は実在し空なので分類は SENDABLE のまま = 「送れるのに答えが返らない」の再現。
  "%18": shot("limit-reached-edith"),
  "%20": shot("idle-boot"),
  "%21": shot("idle-boot"),
  "%22": shot("idle-boot"),
  "%23": shot("idle-boot"),
  "%24": shot("idle-boot"),
  // ★割り込みの対(2026-08-03)。**2枚とも同じ画面**から始める。edith の実機で撮った、
  //   「生成中だがスピナーが写っていない」枚 = 旧来の材料(スピナー)では BUSY と分からず、
  //   footer の `esc to interrupt` だけが生成中だと言っている状態。ここを起点にすると、
  //   割り込みの判定が**新しい材料を本当に読んでいるか**が e2e で分かる。
  "%25": shot("edith-generating-spinner-hidden"),
  "%26": shot("edith-generating-spinner-hidden"),
  // ★実機の許可確認(edith 2026-08-03)。**電話から1文字も打ってはいけない**画面。
  //   `%11` の `/model` と並べて置いてあるのが要点 — どちらも同じ CHOICE で、
  //   分ける材料は許可一覧に載っているかだけ。片方だけ通る事を e2e で見せる。
  "%27": shot("choice-permission-bash"),
  // 13-Z: 付け替えの前後で**画面の種別が変わる**組にしてある。同じ画面だと
  //   「読み直した」と「凍ったまま」が同値になって何も測れない。
  "%28": shot("idle-boot"),          // -> READY
  "%29": shot("choice-model-menu"),  // -> CHOICE
};
writeFileSync(join(SB, "tmux-panes.txt"), PANES);
for (const [pane, text] of Object.entries(SCREENS)) {
  writeFileSync(join(SB, `screen-${pane.replace("%", "")}.txt`), text);
}
// %17 が本文受信後に化ける先(偽 tmux が読む)
writeFileSync(join(SB, "screen-choice.txt"), shot("choice-model-menu"));
// ★止まり方は**2通りある**(2026-08-03、edith v2.1.220 で両方撮った)。偽 tmux では
//   ペインごとに片方ずつ再現する。ここを1通りにすると、電話から最も多い②が「止まって
//   いない」と報告される回帰を e2e が拾えない。
//   ① 本文が出た**後**に押した場合 = `⎿  Interrupted · …` が 172ms で出る。%25 がこれ。
//   ② 本文が1文字も出ていない内に押した場合 = **番ごと巻き戻る**。入力欄にプロンプトが
//      戻り、`Interrupted` は出ない。%15 がこれ。判定は「印が消えて戻らない」側で通る。
writeFileSync(join(SB, "screen-after-escape.txt"), shot("edith-interrupted"));
writeFileSync(join(SB, "screen-rewound.txt"), shot("edith-interrupt-rewound"));

// 注入経路(§10)の会話は**登録済み**にしておく。cwd 一致だけでは注入しない設計に
// なったため(reason=unregistered)、画面判定 CHOICE/BUSY/READY を測るには先に
// 宛先が確定していなければならない。ここで測りたいのは「宛先が確定した後、画面を見て
// 何を送るか」であって、宛先の決め方(§11 で測る)ではない。
const PANE_DIR_SETUP = join(SB, "keys", "panes");
mkdirSync(PANE_DIR_SETUP, { recursive: true });

// ★登録簿は mtime が心拍。実物の書き手(statusline)は 2 秒ごとに書き直すので、読み側は
//   一定時間更新の無い登録を死んだものとして扱う(registry.mjs HEARTBEAT_TTL_MS)。
//   ここで mtime を固定値で置くと、**テストの経過時間そのものが登録を殺す**。
//   なので実物と同じく心拍を打ち、「どちらが新しいか」だけを相対オフセットで保つ。
//   offset[秒] が大きいほど古い登録。
const REG_BEAT = new Map(); // path -> offsetSec
function beatOnce() {
  const now = Date.now() / 1000;
  for (const [p, off] of REG_BEAT) {
    try { utimesSync(p, now - off, now - off); } catch { /* 消された登録は打たない */ }
  }
}
setInterval(beatOnce, 1000).unref();
/** 登録を置く。offsetSec を渡すと「その分だけ古い」登録として心拍を打ち続ける。 */
function putRegistry(sid, pane, offsetSec = 0) {
  const p = join(PANE_DIR_SETUP, `${sid}.json`);
  writeFileSync(p, JSON.stringify({ session_id: sid, pane, model: "Opus 5" }) + "\n");
  REG_BEAT.set(p, offsetSec);
  beatOnce();
}
for (const [sid, pane] of [[SID_READY, "%10"], [SID_CHOICE, "%11"], [SID_GEN, "%15"], [SID_DEAF, "%16"], [SID_RACE, "%17"], [SID_LIMIT, "%18"],
                           [SID_INTR_OK, "%25"], [SID_INTR_STUCK, "%26"], [SID_PERM, "%27"],
                           [SID_FEEDREG, "%28"]]) {
  putRegistry(sid, pane);
}
const SENT_LOG = join(SB, "tmux-sent.log");
writeFileSync(SENT_LOG, "");
const fakeTmux = join(SB, "fake-tmux");
writeFileSync(fakeTmux, `#!/usr/bin/env python3
import sys, os, json, re
SB = ${JSON.stringify(SB)}
args = sys.argv[1:]
if args and args[0] == "list-panes":
    sys.stdout.write(open(os.path.join(SB, "tmux-panes.txt")).read())
elif args and args[0] == "capture-pane":
    pane = args[args.index("-t") + 1] if "-t" in args else ""
    p = os.path.join(SB, "screen-" + pane.replace("%", "") + ".txt")
    sys.stdout.write(open(p).read() if os.path.exists(p) else "")
elif args and args[0] == "new-window":
    # ★新しい会話を始める口(2026-09-03)。実物は -P -F で window id と pane id を 1 行返す。
    #   引数を全部残す = e2e は -c の値(= 机が受けた cwd)を読んで allowlist を**実測**する。
    #   (此の python は JS のテンプレート文字列の中に居るので、バッククォートを書かない)
    with open(os.path.join(SB, "tmux-new.log"), "a") as f:
        f.write(json.dumps(args, ensure_ascii=False) + "\\n")
    sys.stdout.write("@9 %9\\n")
elif args and args[0] == "send-keys":
    with open(os.path.join(SB, "tmux-sent.log"), "a") as f:
        f.write(json.dumps(args, ensure_ascii=False) + "\\n")
    # ★入力欄を実際に動かす。送信側は「本文が画面に載ったか」を見てから Enter を出すので、
    #   偽 tmux が画面を変えないと、その確認は素通りではなく **失敗** する。
    #   -l -- <text> = 入力欄に載る / Enter = 入力欄が空に戻る、という実物の挙動を最小限で真似る。
    pane = args[args.index("-t") + 1] if "-t" in args else ""
    p = os.path.join(SB, "screen-" + pane.replace("%", "") + ".txt")
    # %16 だけは画面が動かない = 送ったのに入力欄に載らないペイン(実機では起きうる)。
    if os.path.exists(p) and pane != "%16":
        lines = open(p).read().split("\\n")
        idx = None
        for i in range(len(lines) - 1, -1, -1):
            t = lines[i].lstrip()
            # \u276f は入力欄の頭にも**選択カーソル**にも使われる。区別せずに書き換えると、
            # 選択メニューのカーソル行が "\u276f 2" に化けてメニューが別物になり、
            # 「打鍵が効いたか」の判定が偽 tmux の副作用で緑になる(2026-08-03 に踏んだ)。
            # 入力欄だけを動かす = 選択肢の行(\u276f N. ...)は触らない。
            if t.startswith("\\u276f") and not re.match(r"\\u276f\\s*\\d+\\.\\s", t):
                idx = i
                break
        if idx is not None:
            if args[-1] == "Enter":
                lines[idx] = "\\u276f "
            elif "-l" in args:
                lines[idx] = "\\u276f " + args[-1]
            open(p, "w").write("\\n".join(lines))
    # %17 は本文を受け取った直後に選択画面へ化ける = 分類と Enter の間の競合の再現。
    if pane == "%17" and "-l" in args:
        open(p, "w").write(open(os.path.join(SB, "screen-choice.txt")).read())
    # ★Escape の効き目を画面で表す(2026-08-03)。%25 は①(印が出る)、%15 は②(巻き戻る)、
    #   %26 は**わざと化けない** = Escape を受け取っても生成中のまま。3本の違いは
    #   ここだけで、他は同じ。だから割り込みの判定が定数でない事がこの3行で決まる。
    if pane == "%25" and args[-1] == "Escape":
        open(p, "w").write(open(os.path.join(SB, "screen-after-escape.txt")).read())
    if pane == "%15" and args[-1] == "Escape":
        open(p, "w").write(open(os.path.join(SB, "screen-rewound.txt")).read())
sys.exit(0)
`);
chmodSync(fakeTmux, 0o755);
/** これまでに偽 tmux が受け取った send-keys の一覧 */
function sentKeys() {
  if (!existsSync(SENT_LOG)) return [];
  return readFileSync(SENT_LOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}

const ARGV_LOG = join(SB, "worker-argv.log");
function workerArgv() {
  if (!existsSync(ARGV_LOG)) return [];
  return readFileSync(ARGV_LOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}
// ★子が**実際に開いた dir**の窓(§3-V の本丸)。argv とは別 file にする ——
//   `workerArgv()` は 1行 = 配列を前提にしているので、同じ file に別形を混ぜると読み手が壊れる。
//   2026-08-03 の実測で、変異 W19(居場所を spawn に渡さない)を e2e が素通ししていた。
//   引数だけ見ていて **cwd は spawn の option** なので argv には現れないのが原因。
const CWD_LOG = join(SB, "worker-cwd.log");
function workerCwds() {
  if (!existsSync(CWD_LOG)) return [];
  return readFileSync(CWD_LOG, "utf8").split("\n").filter(Boolean);
}
// 子の `os.getcwd()` は symlink を解いた形で返る(砂場は /var -> /private/var)。
// 比べる側も必ず実体にする。片側だけ正規化して偽って落とすのが §2.25 で踏んだ穴。
const rp = (p) => { try { return realpathSync(p); } catch { return p; } };
// ★頭は**出荷する writeHead で**書く。手で JSON を組むと、書式が変わった時に
//   検査だけが古い形で通り続ける(継ぎ目の検査が継ぎ目を跨がなくなる)。
mkdirSync(join(SB, "keys", "heads"), { recursive: true, mode: 0o700 });
writeHead(join(SB, "keys", "heads"), SID_H2_HEAD, H2_HEAD_ID);

// ---- §3-T: fork した会話(祖先 -> 頭)を畳む材料 ------------------------------
// ★枝の続きは**別 file**に書かれ、祖先の file は fork の後 mtime が止まって中身も増えない。
//   だから素の一覧は「行が古くなる」だけでなく、mtime 順 + `limit` で**行ごと消える**。
//   作るのは2組: (a) 頭が生きている祖先 (b) 頭が記録されているのに file が無い祖先。
const SID_FORK_ANC    = "bbbbbbbb-0000-0000-0000-000000000040";
const SID_FORK_HEAD   = "bbbbbbbb-0000-0000-0000-000000000041";
const SID_FORK_ORPHAN = "bbbbbbbb-0000-0000-0000-000000000042";
const SID_FORK_GHOST  = "bbbbbbbb-0000-0000-0000-000000000043"; // file を作らない = 消えた頭
const CWD_FORK = join(SB, "fork-work");
// 実物の枝は `cwd: ~`(§3-V 以前に開いた物)。ここでは祖先と**違う**事だけが要るので
// 一目で分かる値にする。行の cwd がこちらに化けたら 4b が落ちる。
const FORK_BRANCH_CWD = "/枝の記録の居場所";
fixture(SID_FORK_ANC, CWD_FORK, "fork の祖先");
fixture(SID_FORK_ORPHAN, CWD_FORK, "頭が消えた祖先");
// ★頭は **`cli`** で置く。実物の枝は `-p` 起動なので `sdk-cli` になる筈だが、それで置くと
//   「頭の行を落とす」検査が篩(`entrypoint !== "cli"`)のおかげで勝手に緑になり、落とす
//   処理を消しても気付けない。篩に依らず畳み込みだけを測る為に `cli` にする
//   (DESIGN §2.18-4b「`entrypoint` の篩に頼らない」の実装)。
writeFileSync(join(PROJ, `${SID_FORK_HEAD}.jsonl`), [
  JSON.stringify({ entrypoint: "cli", cwd: FORK_BRANCH_CWD, type: "user", message: { role: "user", content: "枝で言った事" } }),
  JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "枝からの返事" }] } }),
  JSON.stringify({ type: "ai-title", aiTitle: "枝の題" }),
  JSON.stringify({ type: "last-prompt", lastPrompt: "枝で言った事" }),
].join("\n"));
writeHead(join(SB, "keys", "heads"), SID_FORK_ANC, SID_FORK_HEAD);
writeHead(join(SB, "keys", "heads"), SID_FORK_ORPHAN, SID_FORK_GHOST);
// ★時刻を**手で置く**。祖先は1時間前、頭は他のどの材料よりも新しい。こうしないと
//   「畳まないと行が消える」状況が机の上で再現できない(材料が全部同時刻になる)。
//   頭が少し先の時刻なのは砂場なので害が無く、代わりに順序が確定する。
const FORK_OLD = Date.now() / 1000 - 3600;
const FORK_NEW = Date.now() / 1000 + 300;
utimesSync(join(PROJ, `${SID_FORK_ANC}.jsonl`), FORK_OLD, FORK_OLD);
utimesSync(join(PROJ, `${SID_FORK_ORPHAN}.jsonl`), FORK_OLD, FORK_OLD);
utimesSync(join(PROJ, `${SID_FORK_HEAD}.jsonl`), FORK_NEW, FORK_NEW);
// ★祖先を**登録簿にも載せる**。`scope=registered`(D5 の既定側)で畳めているかを測る為で、
//   ペインは実在しない `%99` で良い —— 測るのは「絞り込みの網に頭を通したか」だけ。
putRegistry(SID_FORK_ANC, "%99");

const fakeWork = join(SB, "fake-claude-work");
// RC_E2E_WORKER_DELAY_MS = 応答を意図的に遅らせる栓。既定 0。
// これは対照実験用: 遅延を入れても緑のままなら「待ち方」が直っている証拠になる。
writeFileSync(fakeWork, `#!/usr/bin/env python3
import sys, json, os, time, subprocess
DELAY=float(os.environ.get("RC_E2E_WORKER_DELAY_MS","0"))/1000.0
# ★死に方を **cwd で** 分ける(2026-08-04、DESIGN §2.35 を実測にする為)。
#   会話 ID は --fork-session / --resume で書き換わるので鍵に使えない。cwd は不変。
#   realpath で /private/var 等に化けても末尾は変わらないので endswith で見る。
CWD=os.getcwd()
DEATH="late" if CWD.endswith("death-late") else ("part" if CWD.endswith("death-part") else "")
# ★答えるのを**わざと遅らせる**1本(送信待ちを積める会話)。既定 1200ms。
#   DELAY と別物なのは効く範囲が違うから: DELAY は走行中の全会話、これは cwd で選んだ1本だけ。
SLOW=(float(os.environ.get("RC_E2E_SLOW_MS","1200"))/1000.0) if CWD.endswith("slow-queue") else 0.0
# ★★合図待ち(2026-08-05)。此方が既定で、上の SLOW は合図が無い時の落ち処。
#   時計で待つと「走っている番がまだ走っている」が**壁時計の賭け**になる —— 詳細は
#   検査側 12-h の頭に書いた。合図なら turn の終わりを検査が持つので賭けが消える。
#   file の**存在**が合図(中身は見ない)ので、書きかけを読む競合が原理的に無い。
#   30秒で諦めるのは、合図の付け忘れを**固まらせずに赤くする**為。
GATE=os.environ.get("RC_E2E_SLOW_GATE","") if CWD.endswith("slow-queue") else ""
# ★argv を丸ごと残す。継ぎ目(サーバが組む argv)を測る唯一の窓。
LOG=os.environ.get("RC_E2E_ARGV_LOG")
if LOG:
    with open(LOG,"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")
# ★自分が**どの dir で開かれたか**。cwd は spawn の option なので argv には現れない。
CWDLOG=os.environ.get("RC_E2E_CWD_LOG")
if CWDLOG:
    with open(CWDLOG,"a") as f: f.write(os.getcwd()+"\\n")
# 本物の claude は起動直後に system/init で自分のセッション ID を名乗る。
# --fork-session なら**新しい ID**、そうでなければ --resume した ID をそのまま名乗る。
argv=sys.argv[1:]
turn=0
resumed=argv[argv.index("--resume")+1] if "--resume" in argv else ""
mine=os.environ.get("RC_E2E_FORK_ID","f0000000-0000-4000-8000-000000000001") if "--fork-session" in argv else resumed
print(json.dumps({"type":"system","subtype":"init","session_id":mine}),flush=True)
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: msg=json.loads(line)
    except Exception: continue
    if DELAY: time.sleep(DELAY)
    turn+=1
    if GATE:
        deadline=time.time()+30.0
        while not os.path.exists(GATE+"."+str(turn)) and time.time()<deadline:
            time.sleep(0.02)
    elif SLOW: time.sleep(SLOW)
    if DEATH=="late":
        # 孫に stdout を**継承**させてから親だけ先に死ぬ。pipe は孫が握ったままなので
        # \`close\` は来ず \`exit\` だけが来る = §2.18-10(2) が \`exit\` を死の合図に選んだ形。
        # その代償(exit の後にも本文が届く)が本当に起きるかを、此処で本物の子で測る。
        # ★孫が書くのは**合図が置かれてから**(2026-08-05)。以前は 0.35 秒の眠りで、
        #   検査の順序が壁時計の賭けになっていた。合図なら「握ったまま」を検査が保てる。
        #   20 秒で諦めるのは、合図の付け忘れで孫を**永久に居座らせない**為。
        subprocess.Popen([sys.executable,"-u","-c",
            "import os,sys,time,json\\n"
            "g=sys.argv[1]\\n"
            "d=time.time()+20.0\\n"
            "while g and not os.path.exists(g) and time.time()<d: time.sleep(0.02)\\n"
            "sys.stdout.write(json.dumps({'type':'assistant','message':{'role':'assistant',"
            "'content':[{'type':'text','text':'ANCHOR-GRANDCHILD'}]}})+chr(10))\\n"
            "sys.stdout.flush()\\n", os.environ.get("RC_E2E_DEATH_GATE","")])
        print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ANCHOR-PARENT"}]}}),flush=True)
        print(json.dumps({"type":"result","result":"ANCHOR-PARENT"}),flush=True)
        sys.stdout.flush()
        os._exit(0)
    if DEATH=="part":
        print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ANCHOR-BEFORE"}]}}),flush=True)
        # ★最後の1行を**改行なし**で置いて即死。worker.mjs は改行でしか行を切らないので、
        #   この行は entry.buf に残ったまま死を迎える。stderr には flushStderr が在るが
        #   stdout には無い —— 落ちるならその非対称が落とす。
        sys.stdout.write(json.dumps({"type":"result","result":"ANCHOR-NONEWLINE"}))
        sys.stdout.flush()
        os._exit(0)
    txt=msg.get("message",{}).get("content",[{}])[0].get("text","")
    print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"echo:"+txt}]}}),flush=True)
    print(json.dumps({"type":"result","result":"echo:"+txt}),flush=True)
`);
chmodSync(fakeWork, 0o755);
const fakeAcct = join(SB, "fake-fleet-account");
const acctState = join(SB, "fleet-account.current");
// ★偽の `fleet-account`。**本物の出力の形**(`src/account.mjs` 冒頭が写した printf)を出す。
//
//   旧版は `echo account=testacct` の1行だった。それで通っていたのは、机が
//   台本の標準出力を**そのまま素通し**していた頃の話 —— 今は `parseFleetAccount` を
//   通すので、この1行は「読めない出力」に化けて `parseStatus: "no-current-line"` に
//   落ちる。**検査が測っていたのは机の素通しであって、電話が読む形ではなかった**。
//
//   状態を file に持つのは、`/api/account/select` が**観測し直して**返す事
//   (`server.mjs` の `/select` は `execFileSync` の後にもう一度読む)を、
//   e2e から確かめられる様にする為。返り値だけを差し替える stub では、
//   「頼んだ名前をそのまま返しているだけ」の木と見分けが付かない。
writeFileSync(fakeAcct, `#!/bin/sh
STATE=${JSON.stringify(acctState)}
[ -f "$STATE" ] || printf 'team' > "$STATE"
cur=$(cat "$STATE")
case "\${1:-}" in
  "")
    ;;
  --next)
    case "$cur" in
      team) cur=biz ;;
      biz)  cur=sdgs ;;
      *)    cur=team ;;
    esac
    printf '%s' "$cur" > "$STATE"
    ;;
  *)
    cur="$1"
    printf '%s' "$cur" > "$STATE"
    ;;
esac
echo "現用: $cur"
echo "優先順 (.order):"
i=1
for a in team biz sdgs; do
  if [ "$a" = "$cur" ]; then mark="->"; else mark="  "; fi
  if [ "$a" = "sdgs" ]; then have=欠; else have=有; fi
  printf "  %s %d. %-8s トークン:%s\\n" "$mark" "$i" "$a" "$have"
  i=$((i+1))
done
`);
chmodSync(fakeAcct, 0o755);

// ★port は**カーネルに決めさせる**(2026-08-02 に変更)。旧: `8790 + random(0..99)`。
//
// 旧の形が作れた嘘: この 8790-8889 の範囲に**過去の走行が落とした孤児**が居座り得る。
// 実測 — pid 45236 が `$TMPDIR/mut-xsaw2j1a/rc/src/server.mjs` のまま **11時間33分** 8861 を
// 掴んでいた(PPID=1 = 走行が外から止められて孫だけ残った形。親の e2e には
// `finally { sv.kill }` が在るので、親ごと殺された時だけ起きる)。
// 衝突すると bind に失敗 → "listening" が出ない → ここが `server did not start` で throw
// → 要約行 `fail=N` が出ない → **変異台本は exit≠0 だけ見て「検出」と数える**。
// つまり**守れていない変異を守れたと報告する**。1/100 × 76件 = 約53%で1件混ざる計算だった。
// ★向きは片側: 衝突が作れるのは偽の「検出」だけで、偽の「素通り」は作れない。
//
// 0 を渡せばカーネルが空いている port を割り当てるので、この型は原理的に消える。
// 実際に割り当たった番号は起動ログの1行から読む(下の待ち)。
const sv = spawn(process.execPath, [join(ROOT, "src", "server.mjs")], {
  env: {
    ...process.env,
    RC_PROJECTS_DIR: join(SB, "projects"),
    RC_CLAUDE_WORK: fakeWork,
    RC_FLEET_ACCOUNT: fakeAcct,
    RC_KEY_DIR: join(SB, "keys"),
    RC_E2E_ARGV_LOG: ARGV_LOG,
    RC_E2E_CWD_LOG: CWD_LOG,
    RC_PHONE_TRUST_FILE: TRUST_FILE,
    // ★roots の台帳(2026-09-03、対照表 #11)。sandbox 自身を root に 1 行。台帳は要求ごとに読まれるので、
    //   検査は file を消して `no_roots` を測り、書き戻して 202 を測る(再起動を挟まない)。
    RC_ROOTS_FILE: ROOTS_LEDGER,
    // ★添付の置き場(行 #23「非画像の添付」、2026-09-03)。ここを渡さないと `server.mjs` は
    //   `homedir()` 由来の**本物の** `~/.rc-backend/attachments` へ書く —— 検査機で
    //   `mkdirSync` が実際に走る。sandbox の下へ寄せて、他の RC_*_DIR と同じ扱いにする。
    RC_ATTACH_DIR: join(SB, "attachments"),
    // ★echo 待ちの予算を広げる栓(server.mjs 側に理由を書いた)。11-g2 が測る
    //   「鍵が満杯」の窓がこの値ぶんしか続かないので、既定 1500ms だと検査側の
    //   遅れで窓を跨ぐ。6000ms にすると跨げなくなる(下の 12並列で実測)。
    RC_E2E_ECHO_BUDGET_MS: "6000",
    RC_E2E_MAX_WAITERS: String(MAX_WAITERS),
    // ★割り込みの予算。**縮められない**理由がある(2026-08-03 に 400ms から戻した)。
    //   止まりの②(巻き戻り)は積極的な印を残さないので、判定は「印が消えて QUIET_FRAMES
    //   (40枚)連続で戻らない」で通る。1枚 = 偽 tmux の python 起動 ~20ms + poll 25ms ≈ 45ms
    //   なので 40枚 ≈ 1.8s、未 armed で諦める PRE_FRAMES(24枚) ≈ 1.1s。400ms ではどちらも
    //   予算切れになり、②と idle が両方 unverified に落ちて**判定が画面を読まなくなる**。
    //   4000ms = 1.8s の倍以上。丸ごと待つのは「止まらないペイン」(%26)の1本だけ。
    RC_E2E_INTERRUPT_BUDGET_MS: "4000",
    RC_E2E_FORK_ID: H2_FORK_ID,
    // ★`RC_E2E_NO_SLOW_GATE` は**対照専用の栓**。立てると合図を外して昔の時計待ちへ戻る。
    //   `RC_E2E_NO_SLOW_GATE=1 RC_E2E_SLOW_MS=50` で 12-h が赤くなる = 検査が本当に
    //   「走っている番がまだ走っている」に依っていた事の実証。既定(合図あり)では
    //   同じ `RC_E2E_SLOW_MS=50` でも緑のまま = 依存が消えた事の実証。
    RC_E2E_SLOW_GATE: process.env.RC_E2E_NO_SLOW_GATE ? "" : SLOW_GATE,
    // ★13-W-a の孫が「いつ書くか」。空にすると孫は待たずに即書く = 検査が「握ったまま」を
    //   保てなくなるので (2) は落ちる(= この合図が効いている事の栓。本走行では常に置く)。
    RC_E2E_DEATH_GATE: process.env.RC_E2E_NO_DEATH_GATE ? "" : DEATH_GATE,
    // ★`RC_E2E_FORCE_PORT` は**対照専用の栓**。本番経路では絶対に立てない。
    //   これが在るのは、環境死の関門(下)を**本物の bind 失敗**で駆動できる様にする為。
    //   手で書いた文字列で関門を試すと、私が想像した出力しか試せない
    //   — 実際 8/02 にそれで通してしまい、本物の Node のクラッシュ報告で外した。
    RC_PORT: process.env.RC_E2E_FORCE_PORT || "0",
    RC_TMUX_BIN: fakeTmux,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let PORT = 0;
let svlog = "";
sv.stdout.on("data", (c) => (svlog += c));
sv.stderr.on("data", (c) => (svlog += c));

let B = "";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// 固定待ちは使わない。偽ワーカーは別プロセスなので、遅い時は何 ms でも足りない
// (実測 2026-07-31: sleep(800) は10回に1回落ちた)。条件が満たされるまで待つ。
// RC_E2E_WAIT_MS = 待ちの上限を縮める栓(対照実験用)。既定 8000。
const WAIT_MS = Number(process.env.RC_E2E_WAIT_MS || 8000);
async function waitFor(cond, timeoutMs = WAIT_MS, stepMs = 25) {
  const until = Date.now() + timeoutMs;
  for (;;) {
    let v;
    try { v = await cond(); } catch { v = false; }
    if (v) return v;
    if (Date.now() > until) return v; // 落ちる時は check 側に判定させる(理由が出るように)
    await sleep(stepMs);
  }
}

let pass = 0, fail = 0;
function check(name, cond, detail = "") {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}  ${detail}`); }
}

try {
  // サーバ起動待ち。**実際に bind した port をここで確定させる**(RC_PORT=0 で頼んだ為)。
  // 起動ログは `listening on http://127.0.0.1:<番号>` の形。この番号が正。
  let up = false;
  for (let i = 0; i < 50 && !up; i++) {
    await sleep(100);
    const m = /listening on http:\/\/[^:\s]+:(\d+)/.exec(svlog);
    if (m) { PORT = Number(m[1]); up = true; }
  }
  // ★上がらなかった時、**理由が環境側か変異側か**を1語で名乗る(2026-08-02)。
  //   `RC-ENV-DEATH` は変異台本がこれだけを見て走行ごと止める合図。
  //   ここに出すのは「頼んだ port が塞がっていた」等、**測れていない**事が確定する場合だけ。
  //   `RC_PORT=0` にした今、主サーバの EADDRINUSE は原理的にほぼ起きない。
  //   起きたら、それは私の想定が壊れた合図なので、黙って赤にせず走行を止める方が正しい。
  //
  // ★合図は **stdout に、行頭の一語として** 出す。throw の文字列に埋めてはいけない。
  //   理由(2026-08-02 に現物で踏んだ): Node は未捕捉例外の報告に **その throw 文の原文** を
  //   stderr へ写す。合図を原文に書くと、環境死**でない**落ち方(変異でサーバが壊れた等)でも
  //   原文経由で合図が stderr に現れ、変異台本は「環境が死んだ」と読んで**走行ごと止まる**。
  //   実際 78件の走行が対照2(故意に壊した木 = 正しい赤)で即死した。
  //   = 検出器が**自分の原文に一致していた**。判定そのものは正しかったので、
  //     出力の置き場所だけの問題に見えるが、害は「一切測れない」で最大級。
  if (!up || !Number.isInteger(PORT) || PORT <= 0) {
    if (/EADDRINUSE|EACCES/.test(svlog)) {
      console.log("RC-ENV-DEATH bind に失敗した = 環境の都合で測れていない");
    }
    throw new Error(`server did not start:\n${svlog}`);
  }
  B = `http://127.0.0.1:${PORT}`;
  const KEY = readFileSync(join(SB, "keys", "api.key"), "utf8").trim();
  const H = { authorization: `Bearer ${KEY}` };

  // 1. 認証
  check("401 without key", (await fetch(`${B}/api/sessions`)).status === 401);
  check("401 with wrong key", (await fetch(`${B}/api/sessions`, { headers: { authorization: "Bearer nope" } })).status === 401);

  // 1-b. 器の配信(電話の画面 + それが読み込む module)。★総当たりの静的配信を作っていない事も測る。
  {
    const page = await fetch(`${B}/`);
    const html = await page.text();
    check("/ は電話の画面を返す", page.status === 200 && html.includes('id="s-list"'), html.slice(0, 120));
    check("/ は認証を要求しない(鍵を貼る画面そのものなので)", page.status === 200);

    const dbg = await fetch(`${B}/debug`);
    check("/debug に検証ページが残っている", dbg.status === 200 && (await dbg.text()).includes("rc-backend 検証ページ"));

    for (const [p, needle] of [["/frames.mjs", "createSseParser"], ["/view.mjs", "mergeHistory"]]) {
      const r = await fetch(`${B}${p}`);
      const t = await r.text();
      check(`${p} が module として配られる`,
        r.status === 200 && (r.headers.get("content-type") || "").includes("javascript") && t.includes(needle),
        `${r.status} ${r.headers.get("content-type")}`);
    }

    const man = await fetch(`${B}/manifest.webmanifest`);
    const manText = await man.text();
    let manOk = false;
    try { manOk = JSON.parse(manText).start_url === "/"; } catch { /* 下の check が落ちる */ }
    check("manifest が JSON として読める", man.status === 200 && manOk, manText.slice(0, 80));

    const icon = await fetch(`${B}/icon.png`);
    const bytes = new Uint8Array(await icon.arrayBuffer());
    check("icon.png が PNG の形で返る",
      icon.status === 200 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47,
      `${icon.status} ${Array.from(bytes.slice(0, 4))}`);

    for (const bad of ["/src/server.mjs", "/package.json", "/../package.json",
                       "/frames.mjs/../server.mjs", "/keys/api.key", "/app.html"]) {
      const r = await fetch(`${B}${bad}`);
      check(`★表に無いパスは配らない: ${bad}`, r.status === 404, String(r.status));
    }
  }

  // 1-c. 外向きの生存信号(DESIGN §7-P)。**認証の外**に在る唯一の API なので、ここで撃つ。
  //
  // なぜ e2e に置くか(単体にしない理由): 測りたい性質が3つとも**走っているサーバでしか
  // 存在しない**。①鍵無しで通る事 ②答えているのが本物のサーバである事 ③応答に会話の
  // 情報が混ざらない事。`server.mjs` は import すると listen するので単体からは触れず、
  // ここが唯一この3つを同時に見られる場所(`test/blocked.test.mjs` の頭の注記と同じ事情)。
  {
    const hz = await fetch(`${B}/healthz`);           // ★鍵を**付けない**
    const raw = await hz.text();
    check("/healthz は鍵無しで 200(観測者に鍵の複製を持たせない為)",
      hz.status === 200, `status=${hz.status}`);

    let hj = null;
    try { hj = JSON.parse(raw); } catch { /* 下の check が理由付きで落ちる */ }
    check("/healthz は JSON を返す", hj !== null && typeof hj === "object", raw.slice(0, 120));

    if (hj) {
      check("ok:true を名乗る", hj.ok === true, JSON.stringify(hj));
      // ★答えているのが**本物のサーバ**である事。tailscale の受け口や proxy が
      //   200 を返しているだけの状態を「生きている」と読まない為の同定。
      //   `sv.pid` はこの検査が起こした node そのものなので、これが一致する以外に
      //   この値が出る筋が無い。
      check("★pid が実際に起こしたサーバと一致する(別物が 200 を返しているのではない)",
        hj.pid === sv.pid, `body=${hj.pid} spawned=${sv.pid}`);
      check("uptime は 0 以上の整数", Number.isInteger(hj.uptime) && hj.uptime >= 0, String(hj.uptime));

      // 版は「ディスクに在る物」ではなく「**起動時に読んだ物**」。手元には
      // `DEPLOYED-REV` が無いので "unknown"、edith では配備台本が刻んだ短ハッシュ。
      // どちらでも同じ式で言える形にして、値を検査に**手書きしない**。
      const revFile = join(ROOT, "DEPLOYED-REV");
      const wantRev = existsSync(revFile)
        ? (readFileSync(revFile, "utf8").split("\n")[0].trim() || "unknown")
        : "unknown";
      check("version は DEPLOYED-REV の1行目(無ければ unknown)",
        hj.version === wantRev, `body=${hj.version} file=${wantRev}`);

      // ★本命の陰性対照 — 会話の情報が1つも載っていない事。
      //   名前で確かめる(将来 field を足した時に素通りしない)…
      const FORBIDDEN_KEYS = ["session", "sessions", "cwd", "pane", "title", "count", "key", "projects"];
      const gotKeys = Object.keys(hj);
      for (const k of FORBIDDEN_KEYS) {
        check(`  応答に "${k}" という項が無い`, !gotKeys.includes(k), gotKeys.join(","));
      }
      //   …と、**この検査が実際に作った現物**で確かめる(手書きの想定でなく生成元から取る、
      //   run-controls.sh 冒頭の規則(1))。値が偶然一致する事は無い長さの物だけを見る。
      //
      // ★落ちた時の detail に本文を出すかを行ごとに分ける。**秘密を守る検査が、
      //   落ちた時にその秘密を印字してはいけない** —— 鍵の行だけ本文を伏せる。
      //   (最初これを一律 `raw.slice(0,200)` で書いていた = 鍵が混ざった時にだけ
      //    鍵が端末とログに出る形になっていた。守る対象と漏らす経路が同じ行に在った)
      for (const [label, needle, showBody] of [
        ["会話 ID", SID1, true], ["cwd", CWD_READY, true], ["鍵", KEY, false],
      ]) {
        check(`  応答本文に ${label} が現れない`, !raw.includes(needle),
          showBody ? raw.slice(0, 200) : `(本文は伏せる — 鍵が混ざった疑いなので印字しない。長さ=${raw.length})`);
      }
      // 件数も漏らさない(「今日は何本開いていたか」は会話の情報)。
      check("  応答は 4 項だけ(ok / pid / uptime / version)",
        gotKeys.length === 4, gotKeys.join(","));
    }

    // GET 以外は開けない。生存信号は**読む**物であって、外から叩ける口を増やさない。
    for (const method of ["POST", "DELETE"]) {
      const r = await fetch(`${B}/healthz`, { method });
      check(`  ${method} /healthz は 404(生存信号は読み取り専用)`, r.status === 404, `status=${r.status}`);
    }

    // 鍵を付けても**同じ物**が出る(認証の有無で答えが変わらない = 分岐が生えていない)。
    const hz2 = await fetch(`${B}/healthz`, { headers: H });
    const hj2 = await hz2.json().catch(() => null);
    check("鍵を付けても同じ形が返る(認証で分岐していない)",
      hz2.status === 200 && hj2 && hj2.ok === true && hj2.pid === sv.pid,
      `status=${hz2.status}`);
  }

  // 2. 一覧
  const list = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const ids = list.sessions.map((s) => s.id);
  check("listing includes cli session", ids.includes(SID1));
  check("listing excludes sdk-cli noise", !ids.includes("22222222-2222-2222-2222-222222222222"));
  check("title resolved from ai-title", list.sessions.find((s) => s.id === SID1).title === "検証用の会話");

  // 3. history
  const hist = await (await fetch(`${B}/api/sessions/${SID1}/history`, { headers: H })).json();
  // ★`display` だけ落として、**残りは丸ごと**比べる(2026-08-05)。Sprint 1 で
  //   `display.who` が足された時、この行は「全体の一致」を見ていたので落ちた —— 中身は
  //   正しいのに検査だけが赤い形。落とす対象を `display` に限るのは、迷子の欄が他に生えたら
  //   ここで捕まえ続ける為。`display` の中身は 13-D が**引数まで**測るので、此処で一緒に
  //   書き写すと同じ期待値が2箇所に増えて、片方が必ず古くなる。
  // ★`anchor`(2026-09-03、対照表 #3)も落とす —— 値は行の byte 位置で fixture の本文長に依存する。
  //   欄そのものは直下で別に測る(全項目に在り、形が `位置:番号`)。
  const histShape = (hist.history || []).map(({ display, anchor, ...rest }) => rest);
  check("history entries carry an anchor (position:index) — parity #3",
    (hist.history || []).length > 0 && (hist.history || []).every((e) => /^\d+:\d+$/.test(String(e.anchor))),
    JSON.stringify((hist.history || []).map((e) => e.anchor)));
  check("history has user+assistant+tool", JSON.stringify(histShape) ===
    JSON.stringify([
      { role: "user", text: "最初の質問" },
      { role: "assistant", text: "最初の答え" },
      { role: "tool", text: "⚙ Bash" },
    ]), JSON.stringify(hist.history));

  // 3-T. 道具の結果の畳み込み(2026-09-03、queue transcript-tool-output-folds-into-the-entry)—— 扉E。
  //
  // ★何故 実サーバへ HTTP を撃つ必要が在るか: 関数の扉(`test/tool-output.test.mjs`)は
  //   `entriesFromLines` を直に呼んで通っているが、此処が測るのは「配線」——
  //   `/history` のハンドラが実際に其の関数を通しているか、`withWho` の spread が
  //   `output`/`outputTruncated` を落とさずに線まで運ぶか。此のファイル冒頭に在る
  //   前例(2026-08-31 の全ルート死亡・2026-09-01 の `display` 欠落)がどちらも
  //   「関数の扉は緑、実サーバは壊れていた」の形だった。
  {
    const th = await (await fetch(`${B}/api/sessions/${SID_TOOL_OUTPUT}/history`, { headers: H })).json();
    const rows = th.history || [];
    check("★道具の結果: tool_result の行が別途 user entry として出ていない(3件だけ)",
      rows.length === 3 && rows.map((e) => e.role).join(",") === "user,assistant,tool",
      JSON.stringify(rows.map((e) => [e.role, e.text])));
    const toolRow = rows.find((e) => e.role === "tool");
    check("★道具の結果: tool entry に output/outputTruncated が乗り、marker が読める",
      !!toolRow && toolRow.output === `${TOOL_OUTPUT_MARKER}\n2行目` && toolRow.outputTruncated === false && !("outputError" in toolRow),
      JSON.stringify(toolRow));
    check("★道具の結果: 項目は素の履歴と同じく display.who を持つ(電話が復号できる形)",
      !!toolRow && typeof toolRow.display?.who === "string", JSON.stringify(toolRow));

    // 探索は output を見ない(scope) —— marker は output だけに在り、text には無い。
    const sr = await (await fetch(
      `${B}/api/sessions/${SID_TOOL_OUTPUT}/history?q=${encodeURIComponent(TOOL_OUTPUT_MARKER)}&limit=50`, { headers: H })).json();
    check("★道具の結果: 探索は output の中身に当たらない(marker は text ではなく output に在る)",
      sr.matched === 0 && (sr.history || []).length === 0, JSON.stringify(sr).slice(0, 200));
  }

  // 3-S. 転写の探索(`?q=`)—— **扉E**(spec §8)。
  //
  // ★何故 此処に置くのが必須か。2026-09-01 の実測で、`?q=` を **HTTP から叩く検査は
  //   この repo に 1 本も無かった**(`test/history-search.test.mjs` は
  //   `searchHistoryFromPath` を import して直接呼ぶ = 関数の扉)。
  //   2026-08-31 の実例(`server.mjs` の宣言順序の誤りで全ルートが死に、iOS 777 件と
  //   backend 約 1000 件が全部緑のまま、捕まえたのは実サーバへ HTTP を撃つ対照 1 本だけ)が
  //   そのまま当てはまる。**配線を足すのだから、関数の扉の検査は証拠にならない。**
  //
  // ★特に `truncated === !searchedToStart` は、**電話が意図的に読まない鍵**の話なので
  //   Swift 側のどの扉でも赤くならない。此処が唯一の守り手。
  {
    const q = encodeURIComponent("最初");
    const sr = await fetch(`${B}/api/sessions/${SID1}/history?q=${q}&limit=100`, { headers: H });
    const sj = await sr.json();
    check("★探索: 日本語の問いが percent-encode されて往復し、200 で返る",
      sr.status === 200 && Array.isArray(sj.history), `status=${sr.status} ${JSON.stringify(sj).slice(0, 200)}`);
    // 綴りを**その字**で見る。電話の `TranscriptSearchResponse` が必須鍵にしているので、
    // どちらかが改名されれば電話は 200 を `.malformedBody` と読む(= 画面が壊れる)。
    // ★錨(2026-09-03、対照表 #3): 探索の当たりは `anchor` と `fromEnd` を持ち、同じ錨が素の履歴に在る。
    //   電話は `fromEnd + 1` まで limit を伸ばして其の項目を読み込み、`anchor` で其の行へ scroll する。
    {
      const hits = Array.isArray(sj.history) ? sj.history : [];
      const okShape = hits.length > 0 && hits.every((h) => /^\d+:\d+$/.test(String(h.anchor)) && Number.isInteger(h.fromEnd) && h.fromEnd >= 0);
      check("★錨: 探索の当たりは anchor(位置:番号)と fromEnd(末尾から何番目)を持つ", okShape,
        JSON.stringify(hits.slice(0, 2)));
      const deepest = hits.reduce((a, h) => (h.fromEnd > (a?.fromEnd ?? -1) ? h : a), null);
      if (deepest) {
        const hr = await fetch(`${B}/api/sessions/${SID1}/history?limit=${deepest.fromEnd + 1}`, { headers: H });
        const hj = await hr.json();
        const found = (hj.history || []).find((e) => e.anchor === deepest.anchor);
        check("★錨: limit = fromEnd + 1 の履歴に同じ錨の項目が在り、本文が一致する",
          hr.status === 200 && !!found && found.text === deepest.text && !("fromEnd" in found),
          `fromEnd=${deepest.fromEnd} anchor=${deepest.anchor} found=${JSON.stringify(found || null).slice(0, 120)}`);
        const anchors = (hj.history || []).map((e) => e.anchor);
        check("錨: 履歴の錨は全項目に在り一意", anchors.length > 0 && anchors.every((a) => /^\d+:\d+$/.test(String(a))) && new Set(anchors).size === anchors.length,
          `n=${anchors.length}`);
        if (deepest.fromEnd > 0) {
          const short = await (await fetch(`${B}/api/sessions/${SID1}/history?limit=${deepest.fromEnd}`, { headers: H })).json();
          check("錨の対照: limit = fromEnd では其の項目は入らない(fromEnd が 1 ずれていない)",
            !(short.history || []).some((e) => e.anchor === deepest.anchor), "");
        }
      }
    }
    check("★探索: body が `matched` / `searchedToStart` を**その綴りで**持つ",
      typeof sj.matched === "number" && typeof sj.searchedToStart === "boolean",
      JSON.stringify(sj).slice(0, 200));
    check("★探索: 問いを含む行だけが返る(絞り込みが本当に効いている)",
      sj.history.length === 2 && sj.history.every((e) => e.text.includes("最初")),
      JSON.stringify(sj.history));
    check("★探索: `matched` は走査で見つかった総数",
      sj.matched === 2, JSON.stringify(sj.matched));
    // ★★2026-09-01、**実機の机を撃って見つけた欠陥**の守り。
    //   旧のハンドラは `history: r.history` と生で返していて `.map(withWho)` を
    //   通しておらず、探索の項目にだけ `display` が無かった(素の履歴には在る)。
    //   電話の `HistoryEntry.display` は非 optional なので、其の応答は復号ごと落ちる
    //   = 実機で探索すると必ず「読めない形」になる。**出荷前から 100% 壊れていた**。
    //   ★木の中の検体は全部 `display` 付きで組んであったので、誰も気付けなかった。
    //     此の 1 行が、其の穴を検査の側から塞ぐ。
    check("★探索: 項目は素の履歴と同じく `display.who` を持つ(電話が復号できる形)",
      sj.history.length > 0 && sj.history.every((e) => typeof e?.display?.who === "string"),
      JSON.stringify(sj.history[0]));
    // 対照: 素の履歴と**同じ名前**が付く(探索だけ別の名付けをしていない)。
    check("★探索の対照: `display.who` は素の履歴と同じ規則で付く",
      sj.history.every((e) => e.display.who === whoOf(e.role)),
      JSON.stringify(sj.history.map((e) => [e.role, e.display.who])));
    // ★電話が読まない鍵。机側でしか守れない(spec §9 の M7)。
    check("★探索: `truncated` は `searchedToStart` の否定である",
      sj.truncated === !sj.searchedToStart, JSON.stringify({ t: sj.truncated, s: sj.searchedToStart }));

    // `q` 無し = 素の履歴経路。**2 経路が実際に分かれている**事の対照 ——
    // これが無いと、上の主張は「/history が常に matched を返す」でも緑になる。
    const plain = await (await fetch(`${B}/api/sessions/${SID1}/history?limit=100`, { headers: H })).json();
    check("★探索の対照: `q` 無しの応答は `matched` を**持たない**(経路が分かれている)",
      !("matched" in plain) && !("searchedToStart" in plain), JSON.stringify(plain).slice(0, 160));

    // 一致 0 件。頭まで見ているので `searchedToStart` は真 = 電話は言い切ってよい面。
    const none = await (await fetch(
      `${B}/api/sessions/${SID1}/history?q=${encodeURIComponent("存在しない語")}&limit=100`, { headers: H })).json();
    check("★探索: 0 件でも `matched` / `searchedToStart` は付く(短い会話は頭まで見る)",
      none.matched === 0 && none.searchedToStart === true && none.history.length === 0,
      JSON.stringify(none).slice(0, 200));

    // ★★両向き。**問いも file も同じで `limit` だけが違う**ので、差が出たなら
    //   それは「走査が本当に途中で止まったか」以外ではあり得ない。
    const nq = encodeURIComponent(SEARCH_NEEDLE);
    const stopped = await (await fetch(
      `${B}/api/sessions/${SID_SEARCH}/history?q=${nq}&limit=1`, { headers: H })).json();
    const toStart = await (await fetch(
      `${B}/api/sessions/${SID_SEARCH}/history?q=${nq}&limit=500`, { headers: H })).json();
    check("★探索: 一致が上限に達すると遡りは途中で止まる(`searchedToStart:false`)",
      stopped.searchedToStart === false && stopped.truncated === true && stopped.matched >= 1,
      JSON.stringify({ s: stopped.searchedToStart, t: stopped.truncated, m: stopped.matched }));
    check("★探索: 上限に届かなければ会話の頭まで遡る(`searchedToStart:true`)",
      toStart.searchedToStart === true && toStart.truncated === false && toStart.matched === 3,
      JSON.stringify({ s: toStart.searchedToStart, t: toStart.truncated, m: toStart.matched }));
    // ★否定の対照。上の2本が同じ値を返す実装(= 定数を焼いた実装)では此処が落ちる。
    check("★探索の対照: 同じ問いでも `limit` で `searchedToStart` が変わる(定数を焼いていない)",
      stopped.searchedToStart !== toStart.searchedToStart,
      JSON.stringify({ stopped: stopped.searchedToStart, toStart: toStart.searchedToStart }));
  }

  // 3-A. 錨を中心にした窓読み(`?around=`)—— 対照表 #3 の続き(2026-09-03)。
  //
  // ★何故 此処が要るか: 検索は当たりの錨と `fromEnd` を返すが、机の1要求あたりの上限(500件)
  //   より深い当たりには電話は `tooFar` としか言えなかった(search-jump.md)。`?around=` は
  //   其の先 —— 錨さえ渡せば、直接其処を中心にした窓を読める。関数の扉(`test/history-around.test.mjs`)
  //   は通っているが、配線が届いているかは実サーバへ HTTP を撃たないと分からない
  //   (2026-08-31 の全ルート死亡が同じ型で見つかった前例が此のファイルの頭に在る)。
  {
    const q = encodeURIComponent("最初");
    const sr = await fetch(`${B}/api/sessions/${SID1}/history?q=${q}&limit=100`, { headers: H });
    const sj = await sr.json();
    const hit = (sj.history || [])[0];
    check("★窓読みの前提: 検索が当たりを返す(錨付き)",
      !!hit && typeof hit.anchor === "string", JSON.stringify(sj).slice(0, 200));
    if (hit) {
      const ar = await fetch(`${B}/api/sessions/${SID1}/history?around=${encodeURIComponent(hit.anchor)}&limit=6`, { headers: H });
      const aj = await ar.json();
      check("★窓読み: 検索の当たりの錨を中心にした窓が 200 で返り、其の錨を含む",
        ar.status === 200 && Array.isArray(aj.history) && aj.history.some((e) => e.anchor === hit.anchor),
        `status=${ar.status} ${JSON.stringify(aj).slice(0, 200)}`);
      check("★窓読み: `olderAvailable` / `newerAvailable` はその綴りの真偽値で載る",
        typeof aj.olderAvailable === "boolean" && typeof aj.newerAvailable === "boolean",
        JSON.stringify(aj).slice(0, 200));
      check("★窓読み: 応答の `anchor` は要求と同じ値を素通しする(窓が本当に其の錨を中心にした証拠)",
        aj.anchor === hit.anchor, `req=${hit.anchor} got=${aj.anchor}`);
      check("★窓読み: 項目は素の履歴と同じく `display.who` を持つ(電話が復号できる形)",
        aj.history.every((e) => typeof e?.display?.who === "string"), JSON.stringify(aj.history[0]));
    }

    // 捏造された錨(範囲外)。転写が書き換わった/でっち上げの錨を、電話のバグ(bad-anchor)とは
    // 別の状態として正直に断る。
    const gone = await fetch(`${B}/api/sessions/${SID1}/history?around=999999:0`, { headers: H });
    const goneJ = await gone.json().catch(() => null);
    check("★窓読み: 捏造された錨(範囲外)は 409 anchor_gone", gone.status === 409 && goneJ?.reason === "anchor_gone",
      `status=${gone.status} ${JSON.stringify(goneJ)}`);

    // 形の壊れた錨。
    const bad = await fetch(`${B}/api/sessions/${SID1}/history?around=xyz`, { headers: H });
    const badJ = await bad.json().catch(() => null);
    check("★窓読み: 形の壊れた錨は 400 bad_anchor", bad.status === 400 && badJ?.reason === "bad_anchor",
      `status=${bad.status} ${JSON.stringify(badJ)}`);

    // ★F6(2026-09-04、Codex around-review): `q` と `around` を同時に渡すと、旧実装は
    //   `q` を無条件に優先して 200 を返していた(`around` が捏造でも気付かれない)。
    //   意図が消える組み合わせなので、其の場で 400 を返す事。
    const both = await fetch(`${B}/api/sessions/${SID1}/history?q=A&around=garbage`, { headers: H });
    const bothJ = await both.json().catch(() => null);
    check("★F6: `q` と `around` の同時指定は 400 q_and_around",
      both.status === 400 && bothJ?.reason === "q_and_around", `status=${both.status} ${JSON.stringify(bothJ)}`);

    // ★F3(2026-09-04、Codex around-review): `limit` が garbage(非数値・負・巨大)でも
    //   clamp されて壊れない事 —— 旧実装は `limit=bogus` が `NaN` を通し、`entries.length
    //   >= NaN` が常に false で trim が効かなくなる(500件の上限を実質バイパスする)。
    //   `SID_SEARCH`(300件超・チャンク境界を跨ぐ長さ)を的にして、実際に効いている事を測る。
    const searchHit = await (await fetch(
      `${B}/api/sessions/${SID_SEARCH}/history?q=${encodeURIComponent(SEARCH_NEEDLE)}&limit=1`, { headers: H })).json();
    const searchAnchor = (searchHit.history || [])[0]?.anchor;
    check("★F3 の前提: SID_SEARCH の探索が錨付きの当たりを返す",
      typeof searchAnchor === "string", JSON.stringify(searchHit).slice(0, 200));
    if (searchAnchor) {
      // `bogus`/`-1` は既定 50 へ落ちる(窓は其の近辺)。`1e9` は正当な巨大値として
      // 500 まで clamp される(SID_SEARCH は300件超あるので、窓がほぼ全件に育ってよい —
      // 測りたいのは「壊れていない(500 の枠は超えない)」事で、既定と同じ小ささではない)。
      for (const [bogusLimit, maxLen] of [["bogus", 55], ["-1", 55], ["1e9", 500]]) {
        const rL = await fetch(
          `${B}/api/sessions/${SID_SEARCH}/history?around=${encodeURIComponent(searchAnchor)}&limit=${bogusLimit}`,
          { headers: H });
        const jL = await rL.json().catch(() => null);
        check(`★F3: limit=${bogusLimit} は 200 のまま、history が枠(<=${maxLen})に収まる(NaN で壊れない)`,
          rL.status === 200 && Array.isArray(jL?.history) && jL.history.length > 0 && jL.history.length <= maxLen,
          `status=${rL.status} len=${jL?.history?.length}`);
      }
    }
  }

  // 3-P. `@` のパス補完(`/paths`)—— **扉E**(2026-09-02)。
  //
  // 測るのは 3 層:
  //   ① 動詞表に登録されて**届く**(登録漏れは 404 で、`completePaths` の検査は全部緑のまま)
  //   ② 封筒の鍵が `paths` / `truncated` / `reason` の綴りで出る(電話が必須にしている)
  //   ③ 走査の性質(前方一致が区切りを跨ぐ / 除外 / 上限 / 断りの語)が**本物のサーバ越しに**効く
  {
    const get = async (sid, qs) =>
      (await fetch(`${B}/api/sessions/${sid}/paths${qs}`, { headers: H })).json();

    const r = await fetch(`${B}/api/sessions/${SID_PATHS}/paths?q=${encodeURIComponent("src/wi")}`, { headers: H });
    const j = await r.json();
    check("★補完: 動詞表に登録されていて 200 で返る(登録漏れなら此処が 404)",
      r.status === 200 && Array.isArray(j.paths), `status=${r.status} ${JSON.stringify(j).slice(0, 200)}`);
    check("★補完: body が `paths` / `truncated` / `reason` を**その綴りで**持つ",
      Array.isArray(j.paths) && typeof j.truncated === "boolean" && "reason" in j,
      JSON.stringify(j).slice(0, 200));
    check("★補完: 前方一致が区切りを跨ぐ(`src/wi` → `src/wire.mjs`)",
      j.paths.map((p) => p.path).sort().join(",") === "src/widget.mjs,src/wire.mjs",
      JSON.stringify(j.paths));
    check("★補完: 項目は `path` と `kind` の2鍵だけ(大きさも時刻も絶対 path も載せない)",
      j.paths.every((p) => Object.keys(p).sort().join(",") === "kind,path"),
      JSON.stringify(j.paths[0]));
    check("補完: 当たらない問いは 0 件、断りの語は付かない",
      (await get(SID_PATHS, "?q=zzzz")).paths.length === 0 && (await get(SID_PATHS, "?q=zzzz")).reason === null);
    // ★対照: **部分一致ではない**。`old-README.md` は `README` を含むが `README` で
    //   始まらないので出てはいけない。的を**直下**に置くのが要点(深い所は枝刈りが
    //   先に止めるので、一致の規則そのものには届かない —— 2026-09-02 の変異 M2 の実測)。
    const pre = await get(SID_PATHS, `?q=${encodeURIComponent("README")}`);
    check("★補完の対照: 前方一致であって部分一致ではない",
      pre.paths.map((p) => p.path).join(",") === "README.md", JSON.stringify(pre.paths));

    // ★問いが空 = 直下だけ。全走査に化けていないかを、深い物が出ない事で測る。
    const top = await get(SID_PATHS, "");
    check("★補完: 問いが空なら cwd の直下だけ(全走査しない)",
      top.paths.map((p) => p.path).sort().join(",") === "README.md,old-README.md,src"
      && top.truncated === false,
      JSON.stringify(top));
    check("★補完: 直下だけ返す事は打ち切りではない(`truncated` を立てない)",
      top.truncated === false, JSON.stringify(top.truncated));
    check("補完: dir は `kind:\"dir\"` を名乗る(電話が続けて降りられる印)",
      top.paths.find((p) => p.path === "src")?.kind === "dir"
      && top.paths.find((p) => p.path === "README.md")?.kind === "file",
      JSON.stringify(top.paths));

    // ★生成木。名前で当てても出ない = 候補にも降りにも入っていない。
    const nm = await get(SID_PATHS, `?q=${encodeURIComponent("node_modules")}`);
    const dotgit = await get(SID_PATHS, `?q=${encodeURIComponent(".git")}`);
    check("★補完: 生成木は候補に出ない(`node_modules` / `.git`)",
      nm.paths.length === 0 && dotgit.paths.length === 0,
      JSON.stringify({ nm: nm.paths, git: dotgit.paths }));
    check("★補完の対照: 生成木の除外は打ち切りとして数えない",
      nm.truncated === false && dotgit.truncated === false,
      JSON.stringify({ nm: nm.truncated, git: dotgit.truncated }));

    // ★★両向き。**問いも木も同じで `limit` だけが違う**ので、差が出たなら
    //   それは「上限で本当に切ったか」以外ではあり得ない(探索の検体と同じ形)。
    const cut = await get(SID_PATHS, `?q=${encodeURIComponent("src/")}&limit=1`);
    const all = await get(SID_PATHS, `?q=${encodeURIComponent("src/")}&limit=100`);
    check("★補完: 上限に当たると `truncated:true` で正直に名乗る",
      cut.truncated === true && cut.paths.length === 1, JSON.stringify(cut));
    check("★補完: 上限に届かなければ `truncated:false`",
      all.truncated === false && all.paths.length > 1, JSON.stringify(all));
    check("★補完の対照: 同じ問いでも `limit` で `truncated` が変わる(定数を焼いていない)",
      cut.truncated !== all.truncated,
      JSON.stringify({ cut: cut.truncated, all: all.truncated }));

    // ★問いを path として使っていない事。木の外を指しても 0 件で、断りにもならない。
    const esc = await get(SID_PATHS, `?q=${encodeURIComponent("../../etc/passwd")}`);
    check("★★補完: 木の外を指す問いは 0 件(問いを path に組み立てていない)",
      esc.paths.length === 0 && esc.reason === null, JSON.stringify(esc));

    // ★作業場所を名乗らない会話 = 200 + 空 + 語。404 や 500 にしない。
    const noCwd = await fetch(`${B}/api/sessions/${SID_PATHS_NO}/paths`, { headers: H });
    const noCwdJ = await noCwd.json();
    check("★補完: cwd が無い会話は 200 + 空 + `no_cwd`(会話は使えるので断りで割らない)",
      noCwd.status === 200 && noCwdJ.paths.length === 0
      && noCwdJ.truncated === false && noCwdJ.reason === "no_cwd",
      `status=${noCwd.status} ${JSON.stringify(noCwdJ)}`);

    // ★陰性対照: 動詞表は catch-all ではない。1文字違えば 404。
    const typo = await fetch(`${B}/api/sessions/${SID_PATHS}/pathz`, { headers: H });
    check("★補完の対照: 動詞表に無い綴りは 404(表が何でも飲み込む形になっていない)",
      typo.status === 404, String(typo.status));
    // ★POST は **405**(404 ではない)。此の2つの差が、上の 404 と対になって
    //   「道は表に在る / 読む方法しか受けない」を分けて言う —— 両方 404 だと、
    //   登録漏れと方法違いが同じ顔になり、どちらの主張も立たなくなる。
    const posted = await fetch(`${B}/api/sessions/${SID_PATHS}/paths`, { headers: H, method: "POST" });
    check("★補完の対照: 読む口なので POST は 405(= 道は在るが方法が違う)",
      posted.status === 405, String(posted.status));
    const noKey = await fetch(`${B}/api/sessions/${SID_PATHS}/paths`);
    check("★補完: 鍵無しでは答えない(cwd の中身の名前は認証の外へ出さない)",
      noKey.status === 401, String(noKey.status));

    // ★roots の口(2026-09-03、対照表 #11)。会話 id 無しで一覧 → 相対 path で起動 → allowlist の外は 400 →
    //   台帳を消すと 400 no_roots(fail closed が既定側)→ 書き戻すと 202。tmux は偽物(RC_TMUX_BIN)なので
    //   202 は「window を作れと言った」の観測で、実の claude は起きない。
    {
      const jh = { ...H, "content-type": "application/json" };
      const rl = await fetch(`${B}/api/roots`, { headers: H });
      const rj = await rl.json();
      // 札 = home の下なら `~/…`、其れ以外は台帳に書かれた path のまま(root は人が書いた場所で、隠す物ではない)。
      //   此の sandbox は home の外なので札は絶対 path。**其れ以外の**絶対 path が線に出ない事を下の paths で見る。
      const SB_REAL = realpathSync(SB);
      check("★roots: 会話 id 無しで一覧が引ける(index と札だけ、鍵は 2 つ)",
        rl.status === 200 && Array.isArray(rj.roots) && rj.roots.length === 1 && rj.reason === null
        && Object.keys(rj.roots[0]).sort().join(",") === "index,label" && rj.roots[0].index === 0
        // 札は台帳に**書かれた通り**(`labelOf` は書かれた path を使う)。macOS では SB(`/var/…`)と其の realpath
        //   (`/private/var/…`)が違うので両方を許す。
        //   ★Codex 2026-09-03 #4 の後: home の外の root は `…/<basename>` だけ = 絶対 path は線に出ない。
        && (rj.roots[0].label === "…/" + basename(SB) || rj.roots[0].label.startsWith("~"))
        && !JSON.stringify(rj).includes(SB_REAL),
        `status=${rl.status} ${JSON.stringify(rj).slice(0, 200)}`);
      const tmuxNew = () => { try { return readFileSync(join(SB, "tmux-new.log"), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; } };
      const cwdOf = (argv) => argv[argv.indexOf("-c") + 1];
      const rp = await fetch(`${B}/api/roots/0/paths?q=`, { headers: H });
      const pj = await rp.json();
      check("roots: root の直下を dir だけで歩ける(pathsBody の 3 鍵、kind は全部 dir、絶対 path は無い)",
        rp.status === 200 && Array.isArray(pj.paths) && pj.paths.length > 0 && pj.paths.every((p) => p.kind === "dir" && !p.path.startsWith("/"))
        && Object.keys(pj).sort().join(",") === "paths,reason,truncated",
        `status=${rp.status} ${JSON.stringify(pj).slice(0, 200)}`);
      const before = tmuxNew().length;
      const inside = await fetch(`${B}/api/roots/0/new`, { method: "POST", headers: jh, body: JSON.stringify({ path: "projects" }) });
      const ij = await inside.json();
      const after = tmuxNew();
      check("★roots: root の下の相対 path で始まる = 202(cwd は返さない)、tmux が受けた -c は root の下の実体",
        inside.status === 202 && ij.started === true && !("cwd" in ij) && after.length === before + 1
        && cwdOf(after[after.length - 1]) === join(SB_REAL, "projects"),
        `status=${inside.status} ${JSON.stringify(ij)} tmux=${JSON.stringify(after[after.length - 1] || null)}`);
      // ★起動側の合図(Codex #3 の後追い): tmux の command は `RC_PHONE_LAUNCH=1 exec <launcher>` で始まる =
      //   `rc-claude` が物理 cwd を台帳と突き合わせる。此の語が無いと起動側の検査は走らない。
      check("★roots: tmux の command が RC_PHONE_LAUNCH=1 で始まる(起動側の cwd 再検査の合図)",
        after.length > 0 && /^RC_PHONE_LAUNCH=1 exec /.test(String(after[after.length - 1].slice(-1)[0])),
        JSON.stringify((after[after.length - 1] || []).slice(-1)));
      const outside = await fetch(`${B}/api/roots/0/new`, { method: "POST", headers: jh, body: JSON.stringify({ path: "../" }) });
      const oj = await outside.json();
      check("★★roots: root の外を指す相対 path = 400 outside_roots(allowlist が本当に効いている)",
        outside.status === 400 && oj.reason === "outside_roots", `status=${outside.status} ${JSON.stringify(oj)}`);
      const sessOut = await fetch(`${B}/api/sessions/${SID_PATHS}/new`, { method: "POST", headers: jh, body: JSON.stringify({ cwd: tmpdir() }) });
      const soj = await sessOut.json();
      check("★roots: 会話の道の cwd 付きも roots の外なら 400 outside_roots",
        sessOut.status === 400 && soj.reason === "outside_roots", `status=${sessOut.status} ${JSON.stringify(soj)}`);
      const n0 = tmuxNew().length;
      const sessIn = await fetch(`${B}/api/sessions/${SID_PATHS}/new`, { method: "POST", headers: jh, body: JSON.stringify({ cwd: join(SB_REAL, "projects") }) });
      const sij = await sessIn.json();
      const n1 = tmuxNew();
      check("★roots: 会話の道の cwd 付きで roots の下 = 202、tmux の -c は其の dir",
        sessIn.status === 202 && sij.started === true && n1.length === n0 + 1 && cwdOf(n1[n1.length - 1]) === join(SB_REAL, "projects"),
        `status=${sessIn.status} ${JSON.stringify(sij)}`);
      // ★既存の道の回帰(2026-09-03 に発覚: `new` が動詞表に無く、電話の「New session here」は 404 だった)。
      //   本文なし = 会話の cwd で始まる。此の 1 本が無かった 3 日間、handler は在っても届いていなかった。
      const sessPlain = await fetch(`${B}/api/sessions/${SID_PATHS}/new`, { method: "POST", headers: H });
      const spj = await sessPlain.json();
      const n2 = tmuxNew();
      check("★★新規(本文なし): 動詞表に `new` が居て 202、tmux の -c は会話の cwd(2026-08-31〜09-03 は 404 だった)、cwd は返さない",
        sessPlain.status === 202 && spj.started === true && !("cwd" in spj) && n2.length === n1.length + 1
        && cwdOf(n2[n2.length - 1]) === CWD_PATHS,
        `status=${sessPlain.status} ${JSON.stringify(spj)}`);
      // ★file を cwd にしない(Codex #1): 台帳 file 自身は root の下に在る regular file
      const asFile = await fetch(`${B}/api/roots/0/new`, { method: "POST", headers: jh, body: JSON.stringify({ path: "roots-ledger" }) });
      const afj = await asFile.json();
      const nFile = tmuxNew();
      check("★roots: file を指す path = 409 cwd_gone、tmux は撃たない(chdir 失敗時の $HOME fallback を踏ませない)",
        asFile.status === 409 && afj.reason === "cwd_gone" && nFile.length === n2.length,
        `status=${asFile.status} ${JSON.stringify(afj)}`);
      const badBody = await fetch(`${B}/api/roots/0/new`, { method: "POST", headers: jh, body: JSON.stringify({ path: ["projects"] }) });
      check("roots: path が非文字列 = 400 bad_body(root 自身で起動しない)",
        badBody.status === 400 && (await badBody.json()).reason === "bad_body" && tmuxNew().length === n2.length, String(badBody.status));
      const ledger = readFileSync(ROOTS_LEDGER, "utf8");
      rmSync(ROOTS_LEDGER);
      const none = await fetch(`${B}/api/roots/0/new`, { method: "POST", headers: jh, body: JSON.stringify({ path: "projects" }) });
      const nj = await none.json();
      const noneList = await (await fetch(`${B}/api/roots`, { headers: H })).json();
      writeFileSync(ROOTS_LEDGER, ledger);
      const back = await fetch(`${B}/api/roots/0/new`, { method: "POST", headers: jh, body: JSON.stringify({ path: "projects" }) });
      check("★roots: 台帳を消すと 400 no_roots、一覧は 200 + 空 + no_roots、書き戻すと 202(fail closed が既定側)",
        none.status === 400 && nj.reason === "no_roots" && noneList.roots.length === 0 && noneList.reason === "no_roots" && back.status === 202,
        `none=${none.status} ${JSON.stringify(nj)} list=${JSON.stringify(noneList)} back=${back.status}`);
      const far = await fetch(`${B}/api/roots/9/new`, { method: "POST", headers: jh, body: "{}" });
      check("roots の対照: /api/roots/9/new は 404(index が catch-all になっていない)", far.status === 404, String(far.status));
      const noKeyRoots = await fetch(`${B}/api/roots`);
      check("roots: 鍵無しでは答えない", noKeyRoots.status === 401, String(noKeyRoots.status));
    }
  }

  // 3-T. 差分(diff)を電話で読む(#4、2026-09-02)—— **扉F**。
  //
  // ★何故 此処に置くのが必須か。`sessiondiff.mjs` 自身の単体は fake exec で git に
  //   一度も触れておらず、`SESSION_ROUTE_RE` に `diff` の口が本当に開いているかは
  //   HTTP を実サーバへ撃つ検査でしか測れない(2026-08-31 の実例そのもの:
  //   `server.mjs` の宣言順序で全ルートが死んだ時、関数の扉は全部緑のままだった)。
  {
    const dr = await fetch(`${B}/api/sessions/${SID_DIFF}/diff`, { headers: H });
    const dj = await dr.json();
    check("★diff: 実 git repo で 200、reason は null", dr.status === 200 && dj.reason === null,
      `status=${dr.status} ${JSON.stringify(dj).slice(0, 300)}`);
    check("diff: 切っていない(小さい変更なので truncated=false)", dj.truncated === false, JSON.stringify(dj.truncated));
    check("diff: totalBytes は生の diff の量(0 ではない)", typeof dj.totalBytes === "number" && dj.totalBytes > 0,
      JSON.stringify(dj.totalBytes));
    const byPath = Object.fromEntries((dj.files || []).map((f) => [f.path, f]));
    check("diff: 未 stage の変更が `staged:false` で乗る(path に `b/` が残っていない)",
      byPath["app.js"]?.staged === false && byPath["app.js"]?.added === 1 && byPath["app.js"]?.removed === 0,
      JSON.stringify(byPath["app.js"]));
    check("diff: stage 済みの新規 file が `staged:true` で別行に乗る",
      byPath["new.txt"]?.staged === true && byPath["new.txt"]?.added === 1,
      JSON.stringify(byPath["new.txt"]));
    check("★diff: 塊の中身(足した行の文面)まで届く(封筒が hunks を運べている)",
      byPath["app.js"]?.hunks?.[0]?.lines?.some((l) => l.kind === "add" && l.text === "const y = 2;"),
      JSON.stringify(byPath["app.js"]?.hunks));

    // GET 以外は此の分岐に落ちない(読むだけの道 = 書く動詞を受け付けない)。
    const drp = await fetch(`${B}/api/sessions/${SID_DIFF}/diff`, { method: "POST", headers: H });
    check("diff: POST は通らない(読むだけの道)", drp.status !== 200, `status=${drp.status}`);
    // ★同じ会話への連射は合流して全部 200(2026-09-03、順番待ちの上限を足しても同じ cwd は
    //   合流するので busy にならない)。之が 503 になる実装 = 合流が壊れている。
    const burst = await Promise.all(Array.from({ length: 12 }, () => fetch(`${B}/api/sessions/${SID_DIFF}/diff`, { headers: H })));
    check("★diff: 同じ会話への 12 連射は合流して全部 200", burst.every((x) => x.status === 200),
      burst.map((x) => x.status).join(","));

    const nr = await fetch(`${B}/api/sessions/${SID_DIFF_NOTREPO}/diff`, { headers: H });
    const nj = await nr.json();
    check("★diff: git 管理外は 200 + `not_a_repo`(異常ではなく状態として返る)",
      nr.status === 200 && nj.reason === "not_a_repo" && Array.isArray(nj.files) && nj.files.length === 0,
      JSON.stringify(nj));

    const cr = await fetch(`${B}/api/sessions/${SID_DIFF_NOCWD}/diff`, { headers: H });
    const cj = await cr.json();
    check("★diff: cwd 欄の無い会話は 200 + `no_cwd`(server.mjs の早期リターンが実際に通る)",
      cr.status === 200 && cj.reason === "no_cwd" && cj.files.length === 0,
      JSON.stringify(cj));
  }

  // 4. account —— **電話が読む封筒**(`wire.mjs` の `accountBody`)が端から端まで組める事。
  //    旧版は台本の標準出力の素通し1本しか見ておらず、机が解析を挟んだ日に
  //    「読めない出力」へ落ちたまま素通しの期待値だけが残った(2026-08-15 に配布で捕まえた)。
  const acct = await (await fetch(`${B}/api/account`, { headers: H })).json();
  check("account: 台本の出力を読み切ったと名乗る", acct.ok === true && acct.parseStatus === "ok",
    JSON.stringify(acct));
  check("account: 現用は1行目から取る", acct.current === "team", JSON.stringify(acct.current));
  check("account: 出荷済みの版が読む `account` にも現用名が入る", acct.account === "team");
  check("account: 一覧は .order の並びのまま届く",
    JSON.stringify((acct.accounts || []).map((a) => a.name)) === JSON.stringify(["team", "biz", "sdgs"]),
    JSON.stringify(acct.accounts));
  check("account: 現用の行にだけ印が付く",
    (acct.accounts || []).filter((a) => a.active).map((a) => a.name).join(",") === "team");
  // 断り文は `display.blocked` の下に在る(電話も `$0.display.blocked` から読む)。
  // 平らな `blocked` を期待すると、机が正しくても検査だけが赤くなる。
  check("★account: トークンの無い行は**選べない行**として届く(理由の文付き)",
    acct.accounts.find((a) => a.name === "sdgs")?.selectable === false
    && typeof acct.accounts.find((a) => a.name === "sdgs")?.display?.blocked === "string",
    JSON.stringify(acct.accounts?.find((a) => a.name === "sdgs")));
  check("★account: 選べる行の断り文は空(理由が出っ放しにならない)",
    acct.accounts.find((a) => a.name === "team")?.display?.blocked === null);
  check("★account: 読めた時は生出力を載せない(読めなかった時だけの欄)", acct.raw === undefined);

  // 4-b. 名指しの切替(§9-3)。**観測し直した**結果が返る事まで見る ——
  //      頼んだ名前を echo するだけの木とは、状態を持つ台本でなければ見分けが付かない。
  const HJ = { ...H, "content-type": "application/json" };
  const selRes = await fetch(`${B}/api/account/select`, {
    method: "POST", headers: HJ, body: JSON.stringify({ name: "biz" }),
  });
  const sel = await selRes.json();
  check("select: 200 で返る", selRes.status === 200, `status=${selRes.status} ${JSON.stringify(sel)}`);
  check("★select: 台本を動かした**後に読み直した**現用が返る", sel.current === "biz", JSON.stringify(sel.current));
  check("★select: 印も biz の行へ移っている(一覧ごと取り直している)",
    (sel.accounts || []).filter((a) => a.active).map((a) => a.name).join(",") === "biz");

  // 4-c. 選べない行は**台本を叩かずに**断る。断りに理由コードが付く事まで見る ——
  //      電話は文面ではなく `reason` で分岐しない(画面遷移は `code` の担当)が、
  //      理由が空の拒否が1本でも在ると机の側の診断が出来なくなる。
  const refusedRes = await fetch(`${B}/api/account/select`, {
    method: "POST", headers: HJ, body: JSON.stringify({ name: "sdgs" }),
  });
  const refused = await refusedRes.json();
  check("★select: トークンの無い名前は 400 で断る", refusedRes.status === 400, `status=${refusedRes.status}`);
  check("★select: 断りに機械可読の理由が付く", refused.reason === "no-token", JSON.stringify(refused));
  check("★select: 断りに人の読む1文が付く", typeof refused.error === "string" && refused.error.length > 0);
  const afterRefused = await (await fetch(`${B}/api/account`, { headers: H })).json();
  check("★select: 断った後、机の口座は動いていない", afterRefused.current === "biz", JSON.stringify(afterRefused.current));

  // 4-d. 一覧に無い名前も同じ形で断る(白名簿が効いている陽性対照)。
  const unknownRes = await fetch(`${B}/api/account/select`, {
    method: "POST", headers: HJ, body: JSON.stringify({ name: "nosuch" }),
  });
  check("★select: 一覧に無い名前は 400", unknownRes.status === 400);
  check("★select: その理由は unknown-account", (await unknownRes.json()).reason === "unknown-account");

  // 5. SSE 購読(fetch ストリーム)
  const sseCtl = new AbortController();
  const sseChunks = [];
  // ヘッダが返るまで await してから先へ進む。ここで固定 sleep を挟むと、
  // 購読が間に合わない時に「イベントが来ない」と誤診する(理由の分からない赤になる)。
  const sseRes = await fetch(`${B}/api/sessions/${SID1}/stream`, { headers: H, signal: sseCtl.signal });
  const ssePromise = (async () => {
    const reader = sseRes.body.getReader();
    const dec = new TextDecoder();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      sseChunks.push(dec.decode(value));
    }
  })().catch(() => {});

  // 6. メッセージ送信 → 偽ワーカーが echo
  const post = await fetch(`${B}/api/sessions/${SID1}/messages`, {
    method: "POST", headers: { ...H, "content-type": "application/json" },
    body: JSON.stringify({ text: "テスト送信" }),
  });
  check("message accepted 202", post.status === 202);
  await waitFor(() => sseChunks.join("").includes('"type":"result"'));
  const sseText = sseChunks.join("");
  check("SSE carries assistant echo", sseText.includes("echo:テスト送信"), sseText.slice(0, 200));
  check("SSE carries result", sseText.includes('"type":"result"'));

  // 6-b. ★出荷する parser で解けるか。上の3本は生の文字列を includes で見ているだけなので
  //      「バイトが来た」しか言えない。電話が実際に通るのは frames.mjs の経路なので**同じ物**で測る。
  {
    const p = createSseParser();
    const frames = [];
    for (const c of sseChunks) frames.push(...p.push(c));
    const decoded = frames.map(decodeEvent);
    check("★出荷する parser で SSE の枠組みが解ける(電話が通る経路そのもの)",
      decoded.length > 0 && decoded.every((d) => d.ok),
      JSON.stringify(decoded.filter((d) => !d.ok).slice(0, 2)));
    check("ワーカー経路の id は素の整数(tmux の epoch.seq と形が違う = 電話は解釈しない)",
      decoded.every((d) => d.id === "" || /^\d+$/.test(d.id)),
      decoded.map((d) => d.id).join(","));
    check("echo が枠組みを解いた後の本文としても取れる",
      JSON.stringify(decoded.map((d) => d.body)).includes("echo:テスト送信"));
  }

  // 7. status → ready
  const st = await waitFor(async () => {
    const j = await (await fetch(`${B}/api/sessions/${SID1}/status`, { headers: H })).json();
    return j.state === "ready" ? j : false;
  }) || await (await fetch(`${B}/api/sessions/${SID1}/status`, { headers: H })).json();
  check("worker ready after result", st.worker === "running" && st.state === "ready", JSON.stringify(st));
  // ★対照表 #16: ワーカー経路の `status` も同じ1鍵で permissionMode を運ぶ
  //   (SID1 の fixture に `permissionMode: "bypassPermissions"` を焼いた)。
  check("worker 経路の status にも permissionMode が乗る", st.route === "worker" && st.permissionMode === "bypassPermissions",
    JSON.stringify(st));

  // ★対照表 #14-16(2026-09-03): `/digest` の `session` が生きた机から運ぶ。
  //   検体 SID_RUNTIME(上の fixture)は頭が sonnet / 90k、尾が opus / 38,717。
  //   尾が勝つ事・output_tokens(2,624)を足さない事・累計しない事を、値で 1 度に測る。
  const rRt = await fetch(`${B}/api/sessions/${SID_RUNTIME}/digest?minutes=60`, { headers: H });
  const jRt = await rRt.json();
  const sess = jRt.digest?.session;
  check("★digest.session が model / gitBranch を尾の値で運ぶ(頭の sonnet ではない)",
    rRt.status === 200 && sess?.model === "claude-opus-5" && sess?.gitBranch === "main" && sess?.version === "2.1.240",
    JSON.stringify(sess));
  check("★digest.session.contextTokens = 尾の usage の入力 3 種の和(output を足さず、累計もしない)",
    sess?.contextTokens === 2 + 27_124 + 11_591, JSON.stringify(sess));

  // 8. interrupt
  const intr = await (await fetch(`${B}/api/sessions/${SID1}/interrupt`, { method: "POST", headers: H })).json();
  check("interrupt returns true", intr.interrupted === true);
  const st2 = await (await fetch(`${B}/api/sessions/${SID1}/status`, { headers: H })).json();
  check("worker gone after interrupt", st2.worker === "none", JSON.stringify(st2));

  // 8-b. ★H2 の継ぎ目 — サーバが組む argv と頭の登録簿(DESIGN §2.18-10)
  //      単体は `plan` を注入で受け取るので、**サーバが plan を argv に写す所**は
  //      原理的に届かない。W6 と同じ形の穴なので e2e 側で撃つ。
  {
    const send = async (sid) => {
      const r = await fetch(`${B}/api/sessions/${sid}/messages`, {
        method: "POST", headers: { ...H, "content-type": "application/json" },
        body: JSON.stringify({ text: "h2" }),
      });
      return r.status;
    };
    check("H2: 頭なしの会話へ送れる", await send(SID_H2_NEW) === 202);
    const forkArgv = await waitFor(() => workerArgv().find((a) => a.includes(SID_H2_NEW)));
    check("★H2: 頭が無い初回は --fork-session 付きで祖先を resume する",
      Boolean(forkArgv) && forkArgv.includes("--fork-session") &&
      forkArgv[forkArgv.indexOf("--resume") + 1] === SID_H2_NEW,
      JSON.stringify(forkArgv));

    // 子が名乗った新 ID が頭として**ディスクに**残るか。出荷する readHead で読む。
    const head = await waitFor(() => {
      const h = readHead(join(SB, "keys", "heads"), SID_H2_NEW);
      return h === H2_FORK_ID ? h : false;
    });
    check("★H2: fork した子が名乗った ID が頭として保存される(次回はここへ resume)",
      head === H2_FORK_ID, String(head));

    check("H2: 頭ありの会話へ送れる", await send(SID_H2_HEAD) === 202);
    const resumeArgv = await waitFor(() => workerArgv().find((a) => a.includes(H2_HEAD_ID)));
    check("★H2: 頭が有れば fork せず、その枝の先端へ resume する",
      Boolean(resumeArgv) && !resumeArgv.includes("--fork-session") &&
      !resumeArgv.includes(SID_H2_HEAD),
      JSON.stringify(resumeArgv));

    // ★§3-V の本丸。ここまでに起きた子は全部 CWD_WORK の会話なので、開いた dir も CWD_WORK。
    //   変異 W19(居場所を渡さない = HOME で開く)はここで初めて e2e に映る。
    const cwds = await waitFor(() => (workerCwds().length ? workerCwds() : false));
    check("★§3-V: 子は**会話の居場所**で開かれる(HOME ではない)",
      cwds.every((c) => c === rp(CWD_WORK)), JSON.stringify(cwds));
    check("★§3-V: 子の cwd に HOME が1件も現れない(既定値へ落ちていない)",
      !cwds.includes(rp(process.env.HOME || "/")), JSON.stringify(cwds));
  }

  // 9. 異常系: bad body / unknown session
  const bad = await fetch(`${B}/api/sessions/${SID1}/messages`, {
    method: "POST", headers: { ...H, "content-type": "application/json" }, body: "{not json",
  });
  check("bad body -> 400", bad.status === 400);
  check("unknown session -> 404",
    (await fetch(`${B}/api/sessions/99999999-9999-9999-9999-999999999999/history`, { headers: H })).status === 404);

  // ---- 10. 注入経路(旧「TUI保持 → 409」の置き換え) --------------------------
  const send = (sid, text) => fetch(`${B}/api/sessions/${sid}/messages`, {
    method: "POST", headers: { ...H, "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });

  // 10-a. 入力欄のあるペイン → 実際に注入され、本文と Enter が**別コマンド**で出る
  const before = sentKeys().length;
  const rReady = await send(SID_READY, "注入されるはず");
  const jReady = await rReady.json();
  check("SENDABLE pane -> 202 route=tmux", rReady.status === 202 && jReady.route === "tmux" && jReady.pane === "%10",
    JSON.stringify(jReady));
  check("入力欄から本文が消えたので delivered=verified", jReady.delivered === "verified", JSON.stringify(jReady));
  const injected = sentKeys().slice(before);
  check("本文と Enter が別コマンドで届く",
    injected.length === 2 &&
    injected[0][0] === "send-keys" && injected[0].includes("-l") && injected[0].at(-1) === "注入されるはず" &&
    injected[1].at(-1) === "Enter", JSON.stringify(injected));
  check("★scrollback を読んでいない(capture-pane に -S を付けない)",
    !sentKeys().some((c) => c[0] === "capture-pane" && c.includes("-S")));

  // 10-a-2. ★対照表 #16: tmux 経路の `status` は転写から permissionMode を拾う
  //   (SID_READY の fixture に `permissionMode: "plan"` を焼いた)。
  const stReadyRes = await fetch(`${B}/api/sessions/${SID_READY}/status`, { headers: H });
  const stReady = await stReadyRes.json();
  check("tmux 経路の status に permissionMode が乗る(transcript の値をそのまま)",
    stReadyRes.status === 200 && stReady.route === "tmux" && stReady.permissionMode === "plan",
    JSON.stringify(stReady));

  // 10-b. ★陽性対照: 選択待ち画面には 1 文字も送らない(Enter が課金選択になりうる)
  const beforeChoice = sentKeys().length;
  const rChoice = await send(SID_CHOICE, "うっかり送信");
  const jChoice = await rChoice.json();
  check("★CHOICE 画面 -> 409(陽性対照)",
    rChoice.status === 409 && jChoice.screen === "CHOICE" && jChoice.reason === "choice",
    `status=${rChoice.status} ${JSON.stringify(jChoice)}`);
  check("★CHOICE 画面へは send-keys が0件", sentKeys().length === beforeChoice,
    JSON.stringify(sentKeys().slice(beforeChoice)));

  // 10-c. ★陽性対照: cwd は合うが素の zsh しか居ない → 注入せずワーカー経路へ
  const beforeShell = sentKeys().length;
  const jShell = await (await send(SID_SHELL, "シェルに打ち込まれてはいけない")).json();
  // ★`route` だけを見てはいけない —— 409 の断りの本文にも `route: "worker"` が載る。
  //   §3-V を入れた直後、この検査は**拒否されたまま緑**だった(2026-08-03、自分で作った偽の緑)。
  //   「ワーカーへ落ちた」は route と**受理**の両方が揃って初めて言える。
  check("★zsh だけの cwd -> 注入せずワーカーで**受理**される",
    jShell.route === "worker" && jShell.accepted === true, JSON.stringify(jShell));
  check("★zsh ペインへは send-keys が0件", sentKeys().length === beforeShell);
  // ★居場所が**会話ごとに違う**事まで押さえる。ここを H2 と同じ dir にすると、
  //   「常に定数を渡す」当てでも両方緑になってしまう(定数の的は1箇所では作れない)。
  const shellCwd = await waitFor(() => workerCwds().find((c) => c === rp(CWD_SHELL)));
  check("★§3-V: 別の会話は**別の**居場所で開く(cwd は会話ごとの値)",
    shellCwd === rp(CWD_SHELL), JSON.stringify(workerCwds()));

  // 10-c-2. ★§3-V: 未信頼 / 消えた居場所では**子を起こす前に**断る。
  //   起こしてから断ると、電話が答えられない信頼確認の画面を1枚作ってから謝る事になる。
  const beforeTrust = sentKeys().length;
  const jNoTrust = await (await send(SID_NOTRUST, "未信頼の場所へは起こさない")).json();
  check("★未信頼の cwd -> 409 で断る(accepted:false)",
    jNoTrust.accepted === false && jNoTrust.reason === "cwd_untrusted", JSON.stringify(jNoTrust));
  check("★断りに人が読める文が付く(理由コードだけを電話に出さない)",
    typeof jNoTrust.error === "string" && jNoTrust.error.length >= 10, JSON.stringify(jNoTrust));
  const jGone = await (await send(SID_CWD_GONE, "消えた場所へは起こさない")).json();
  check("★一覧に在っても dir が無ければ 409 cwd_missing(「在る」と「今そこに在る」は別)",
    jGone.accepted === false && jGone.reason === "cwd_missing", JSON.stringify(jGone));
  check("★§3-V の断りでも send-keys は0件", sentKeys().length === beforeTrust);

  // 10-d. ★陽性対照: 同 cwd に claude が2つ → どちらにも送らずワーカーにも落とさない
  const beforeAmbig = sentKeys().length;
  const rAmbig = await send(SID_AMBIG, "どっちか分からない");
  const jAmbig = await rAmbig.json();
  check("★特定不能 -> 409 blocked", rAmbig.status === 409 && jAmbig.reason === "ambiguous" && jAmbig.candidates === 2,
    JSON.stringify(jAmbig));
  check("★特定不能で send-keys が0件", sentKeys().length === beforeAmbig);

  // 10-e. ★生成中でも送れる(2026-08-01 の設計反転。旧版はここで待機列に積んでいた)
  //   実測 M5: 生成中に本文+Enter を送っても生成は中断されず、TUI 自身がキューして
  //   次のターンとして処理した。自前のキューはその機能の二重実装だったので撤去した。
  const beforeGen = sentKeys().length;
  const rGen = await send(SID_GEN, "生成中に割り込む");
  const jGen = await rGen.json();
  check("★生成中 -> 202 で実際に送る", rGen.status === 202 && jGen.route === "tmux" && jGen.pane === "%15",
    JSON.stringify(jGen));
  check("★生成中でも本文と Enter が出る", sentKeys().slice(beforeGen).length === 2,
    JSON.stringify(sentKeys().slice(beforeGen)));
  // ★この2本が言っているのは「**この経路には我々の行列が無い**」であって、
  //   「行列という概念が無い」ではない(2026-08-04 に足した §12-h と読み違えない為)。
  //   ワーカー経路には我々の行列が在り、`poll` はその数を載せる。机の会話の `poll` が
  //   載せるのは `null` = **Claude Code 自身が持っている数を観測していない**、という別の事。
  check("キューは存在しない(queued を返さない)", jGen.queued === undefined, JSON.stringify(jGen));
  const stGen = await (await fetch(`${B}/api/sessions/${SID_GEN}/status`, { headers: H })).json();
  check("status は送信可否と進行中を別項目で返す",
    stGen.route === "tmux" && stGen.screen === "SENDABLE" && stGen.activity === "observed" && stGen.queued === undefined,
    JSON.stringify(stGen));

  // 10-e1b. ★★継ぎ目: 分類器が見えている上限が、**HTTP の応答まで届いているか**。
  //   ここが無かった間、上限は inject(分類)と view(表示)の単体でしか測られておらず、
  //   その二つを繋ぐ `server.mjs` の `screenOf` -> `json(res,...)` は素通りだった
  //   (`grep -rn limited test/` の全ヒットが純関数の直呼び / e2e の `live.` は1件で
  //    未登録セッションの `message` だけ)。両端が緑でも間で落ちれば電話には届かない。
  //   ★陰性対照を同じ塊に置く。片方だけだと「常に true を返す」実装でも緑になる。
  const stLim = await (await fetch(`${B}/api/sessions/${SID_LIMIT}/status`, { headers: H })).json();
  check("★上限が status の応答に載る(継ぎ目 = server.mjs の screenOf)",
    stLim.route === "tmux" && stLim.limited === true, JSON.stringify(stLim));
  check("★その時も送信可否は SENDABLE(上限を遮断条件にしていない)",
    stLim.screen === "SENDABLE", JSON.stringify(stLim));
  check("★陰性対照: 上限でないセッションの status は limited=false",
    stGen.limited === false, JSON.stringify(stGen));
  const listLim = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const rowLim = (listLim.sessions || []).find((s) => s.id === SID_LIMIT);
  const rowGen = (listLim.sessions || []).find((s) => s.id === SID_GEN);
  check("★上限が一覧の live にも載る(一覧と個別で別経路を通る)",
    rowLim?.live?.limited === true, JSON.stringify(rowLim?.live));
  check("★陰性対照: 一覧の他の行は live.limited=false",
    rowGen?.live?.limited === false, JSON.stringify(rowGen?.live));

  // 10-e2. ★陽性対照: 本文が画面に載らなかったら Enter を出さない。
  //   send-keys の成功はバイトが届いた証明であって、TUI が受け取った証明ではない。
  const beforeDeaf = sentKeys().length;
  const rDeaf = await send(SID_DEAF, "画面に載らない本文");
  const jDeaf = await rDeaf.json();
  const deafKeys = sentKeys().slice(beforeDeaf);
  check("★本文が載らなければ 409 composer-mismatch",
    rDeaf.status === 409 && jDeaf.reason === "composer-mismatch", `${rDeaf.status} ${JSON.stringify(jDeaf)}`);
  check("★その時 Enter は一度も出ていない",
    deafKeys.length === 1 && !deafKeys.some((c) => c.at(-1) === "Enter"), JSON.stringify(deafKeys));

  // 10-e3. ★★陽性対照(この層で一番高い賭け金): 分類した後・Enter を押す前に選択画面が
  //   割り込んだら、Enter を押さない。押せばそれが承認や課金の選択になる。
  //   「本文と Enter を1回にまとめる」対策を採らなかったのは、まとめても**何も観測しない**から。
  //   ここで測っているのは、間に観測を挟むという選択が実際に効いているか。
  const beforeRace = sentKeys().length;
  const rRace = await send(SID_RACE, "この直後に上限画面が出る");
  const jRace = await rRace.json();
  const raceKeys = sentKeys().slice(beforeRace);
  check("★本文の直後に選択画面 -> 409 modal-appeared",
    rRace.status === 409 && jRace.reason === "modal-appeared", `${rRace.status} ${JSON.stringify(jRace)}`);
  check("★★その時 Enter は一度も出ていない(押せば承認/課金になる)",
    !raceKeys.some((c) => c.at(-1) === "Enter"), JSON.stringify(raceKeys));

  // 10-f. 割り込みは Escape のみ(C-c を出さない)
  const beforeIntr = sentKeys().length;
  const jIntr = await (await fetch(`${B}/api/sessions/${SID_GEN}/interrupt`, { method: "POST", headers: H })).json();
  const intrKeys = sentKeys().slice(beforeIntr);
  check("interrupt は Escape 1回だけ", jIntr.route === "tmux" && intrKeys.length === 1 && intrKeys[0].at(-1) === "Escape",
    JSON.stringify(intrKeys));
  check("C-c は一度も出ていない", !JSON.stringify(sentKeys()).includes("C-c"));

  // 10-f2. ★★押した ≠ 止まった。ここまでの 10-f が確かめていたのは「Escape という
  //   キーが1回出た」までで、**生成が実際に止まったか**は電話に届いていなかった
  //   (8/02 まで `interrupted` は押した事実に縛られていて、常に true だった)。
  //   4本を並べて撃つ。4本の違いは Escape 後の画面だけなので、judgment が画面を
  //   読んでいなければ4本とも同じ値になる = 定数では緑にできない形にしてある。
  //   ①印が出る / ②巻き戻る / 止まらない / そもそも走っていない、の4通り。
  const jIntrOk = await (await fetch(`${B}/api/sessions/${SID_INTR_OK}/interrupt`, { method: "POST", headers: H })).json();
  check("★★止まった①: `Interrupted` の印が増えたら interrupted=true / stopped=verified",
    jIntrOk.interrupted === true && jIntrOk.stopped === "verified" && jIntrOk.route === "tmux",
    JSON.stringify(jIntrOk));

  const jIntrStuck = await (await fetch(`${B}/api/sessions/${SID_INTR_STUCK}/interrupt`, { method: "POST", headers: H })).json();
  check("★★止まらなかった: 印が残ったら interrupted=false / stopped=unverified",
    jIntrStuck.interrupted === false && jIntrStuck.stopped === "unverified" && jIntrStuck.reason === "still-in-flight",
    JSON.stringify(jIntrStuck));

  // ★★止まり②(巻き戻り)。10-f で撃った %15 がこれ。積極的な印は**出ない**ので、
  //   ここが緑になるのは判定が「印が消えて戻らない」側を持っている時だけ。
  //   8/02 まではこの画面を「生成中の印が無いペイン」と読んで not-in-flight を期待して
  //   いた — その期待自体が、スピナーの 5 コマ中 1 コマ(`·`)を取りこぼす規則の産物だった。
  check("★★止まった②: 印が出なくても、消えて戻らなければ stopped=verified",
    jIntr.interrupted === true && jIntr.stopped === "verified", JSON.stringify(jIntr));

  // そもそも走っていないペイン(入力欄で待っているだけ)。押しはするが、止める対象を
  // 観測していない事を明示する。ここが verified になったら判定は画面を読んでいない。
  const jIntrIdle = await (await fetch(`${B}/api/sessions/${SID_READY}/interrupt`, { method: "POST", headers: H })).json();
  check("走っていなければ stopped=null / reason=not-in-flight(押しはする)",
    jIntrIdle.interrupted === false && jIntrIdle.stopped === null && jIntrIdle.reason === "not-in-flight",
    JSON.stringify(jIntrIdle));

  // ★何枚見て決めたのかを**必ず出す**。①以外は枚数を数えて決める判定なので、予算に
  //   対する余白が痩せると、判定が変わる前に「遅くなった」として先に見える。
  console.log(`      [割り込みの所要 ms] ①印=${jIntrOk.waitedMs} ②巻戻=${jIntr.waitedMs} `
    + `止まらず=${jIntrStuck.waitedMs} 未走行=${jIntrIdle.waitedMs} / 予算=4000`);
  check("★②と未走行は予算の 2/3 以内で決まっている(余白が痩せたら判定が変わる前に落ちる)",
    jIntr.waitedMs < 2666 && jIntrIdle.waitedMs < 2666,
    `②=${jIntr.waitedMs} 未走行=${jIntrIdle.waitedMs}`);

  // ★対照の対照: 「止まった」ペインは Escape を**1回だけ**受けている。
  //   確かめが再送になっていたら、割り込みが二重に効く事になる。
  const okKeys = sentKeys().filter((c) => c.includes("%25"));
  check("止まったペインへ出たキーは Escape 1回だけ",
    okKeys.length === 1 && okKeys[0].at(-1) === "Escape", JSON.stringify(okKeys));

  // 10-g. 一覧に経路と画面状態が出る
  const list2 = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const byId = Object.fromEntries(list2.sessions.map((s) => [s.id, s.live]));
  check("一覧: 入力欄のあるペインは tmux/SENDABLE",
    byId[SID_READY]?.route === "tmux" && byId[SID_READY]?.screen === "SENDABLE",
    JSON.stringify(byId[SID_READY]));
  check("★一覧: 選択待ちは CHOICE のまま(電話に出す前に潰さない)",
    byId[SID_CHOICE]?.screen === "CHOICE", JSON.stringify(byId[SID_CHOICE]));
  check("一覧: 特定不能は blocked", byId[SID_AMBIG]?.route === "blocked", JSON.stringify(byId[SID_AMBIG]));
  check("一覧: 開いていない会話は worker", byId[SID1]?.route === "worker", JSON.stringify(byId[SID1]));

  // ---- 10-g2. ★非画像の添付(attach-file、行 #23「非画像の添付」、2026-09-03) --------
  // `attach`(画像)は単体(test/attach.test.mjs)しか撃っていなかった —— HTTP 層(鍵・
  // pane への差し込み・偽 tmux の send-keys ログまで届くか)は attach-file が初めて測る。
  // pane は 10 の頭で確立済みの SID_READY(%10、入力欄が実在する)を再利用する。
  {
    const attachFile = (sid, name, buf, headers) => fetch(
      `${B}/api/sessions/${sid}/attach-file?name=${encodeURIComponent(name)}`,
      { method: "POST", headers: headers ?? H, body: buf },
    );

    check("★鍵が無ければ attach-file も 401",
      (await attachFile(SID_READY, "notes.md", Buffer.from("x"), {})).status === 401);

    const beforeAF = sentKeys().length;
    const rAF = await attachFile(SID_READY, "notes.md", Buffer.from("2026-09-03 の tail\n", "utf8"));
    const jAF = await rAF.json();
    check("★UTF-8 文書 -> 200、申告名がそのまま返る(id.ext ではない)",
      rAF.status === 200 && jAF.name === "notes.md" && jAF.ext === "md" && typeof jAF.attachmentId === "string",
      JSON.stringify(jAF));
    check("★injected は必ず bool、載らなかった時だけ理由が付く(attach と同じ規約)",
      typeof jAF.injected === "boolean"
        && (jAF.injected ? jAF.injectReason === null : typeof jAF.injectReason === "string"),
      JSON.stringify(jAF));
    const afKeys = sentKeys().slice(beforeAF);
    check("★入力欄のあるペインには実際に載る(SID_READY は 10-a で送信済みの窓)",
      jAF.injected === true, JSON.stringify(jAF));
    check("★偽 tmux の send-keys ログに、置いた絶対パス(sandbox 配下)が実在する",
      afKeys.some((c) => c.includes("-l")
        && String(c.at(-1)) === join(SB, "attachments", `${jAF.attachmentId}.${jAF.ext}`)),
      JSON.stringify(afKeys));
    check("★Enter は送っていない(送るかは人が決める。attach と同じ規約)",
      !afKeys.some((c) => c.at(-1) === "Enter"), JSON.stringify(afKeys));

    const rNul = await attachFile(SID_READY, "notes.md", Buffer.from("plain\x00text"));
    const jNul = await rNul.json();
    check("★NUL バイトを含む本文 -> 400 binary(v1 は文書だけ)",
      rNul.status === 400 && jNul.error === "ATTACH_REJECTED" && jNul.reason === "binary", JSON.stringify(jNul));

    const rPng = await attachFile(SID_READY, "notes.md", Buffer.from("89504e470d0a1a0a".repeat(4), "hex"));
    const jPng = await rPng.json();
    check("★PNG バイト -> 400 use-image-door(画像は attach の門を通す)",
      rPng.status === 400 && jPng.error === "ATTACH_REJECTED" && jPng.reason === "use-image-door",
      JSON.stringify(jPng));

    // ★PDF(行 #24「PDF 添付」、2026-09-03)。v1 の文書語彙(sniff せず申告名の拡張子で
    //   決める)と違い、PDF は**唯一の binary 例外**で magic byte だけで見分ける
    //   ——ここで測るのは HTTP 層まで通しても content-type-blind のまま保たれているか
    //   (申告名は信じない: bad-name の対照も併せて撃つ)。
    const PDF_MIN = Buffer.concat([
      Buffer.from("%PDF-1.4\n", "latin1"),
      Buffer.from([0x00, 0x01]),
      Buffer.from("\n%%EOF", "latin1"),
    ]);
    const beforePdf = sentKeys().length;
    const rPdf = await attachFile(SID_READY, "report.pdf", PDF_MIN);
    const jPdf = await rPdf.json();
    check("★PDF magic 入り本文 -> 200、ext === pdf(NUL があっても binary にならない)",
      rPdf.status === 200 && jPdf.ext === "pdf" && jPdf.name === "report.pdf"
        && typeof jPdf.attachmentId === "string",
      JSON.stringify(jPdf));
    const pdfKeys = sentKeys().slice(beforePdf);
    check("★置いた PDF の絶対パス(sandbox 配下、.pdf)が偽 tmux の send-keys ログに実在する",
      pdfKeys.some((c) => c.includes("-l")
        && String(c.at(-1)) === join(SB, "attachments", `${jPdf.attachmentId}.pdf`)),
      JSON.stringify(pdfKeys));

    const rPdfBadName = await attachFile(SID_READY, "notes.txt", PDF_MIN);
    const jPdfBadName = await rPdfBadName.json();
    check("★PDF magic 入り本文を .txt で申告 -> 400 bad-name(申告名は pdf に限定)",
      rPdfBadName.status === 400 && jPdfBadName.error === "ATTACH_REJECTED" && jPdfBadName.reason === "bad-name",
      JSON.stringify(jPdfBadName));
  }

  // ---- 10-h. 選択メニューへの打鍵(§2.29) ------------------------------------
  // 出典: DESIGN D4 + Tom 裁定「自動化に安全確認を押させない」。
  // 単体は test/choice.test.mjs。**此処で測るのは HTTP 層だけの緩み** —
  // 指紋をサーバが埋めていないか、拒否が本当に打鍵0で終わるか、電話が撮り直さずに
  // やり直せるか。8/02 の割り込みは単体が緑のまま HTTP 層で緩んでいた。
  const choose = (sid, body) =>
    fetch(`${B}/api/sessions/${sid}/choice`, {
      method: "POST", headers: { ...H, "content-type": "application/json" }, body: JSON.stringify(body),
    });
  const stChoice = await (await fetch(`${B}/api/sessions/${SID_CHOICE}/status`, { headers: H })).json();
  check("Needs inputの画面には、電話が答えるのに要る材料が全部載る",
    stChoice.choice?.kind === "benign" && stChoice.choice.matcher === "select-model@2" &&
    stChoice.choice.options?.length === 5 && stChoice.choice.keys?.includes("digit") &&
    typeof stChoice.choice?.digest === "string" && stChoice.choice?.digest.length === 16,
    JSON.stringify(stChoice.choice));

  const stPerm = await (await fetch(`${B}/api/sessions/${SID_PERM}/status`, { headers: H })).json();
  check("★★許可確認は CHOICE として出るが、打てる鍵がゼロで出る",
    stPerm.screen === "CHOICE" && stPerm.choice?.kind === "hard-stop" &&
    stPerm.choice.keys.length === 0 && stPerm.choice.matcher === null,
    JSON.stringify(stPerm.choice));

  const beforePerm = sentKeys().length;
  // ★`?.` を落とさない。上の check が既に `stPerm.choice?.kind` で守っているのに此処だけ
  //   素で読んでいた所為で、`choice` が undefined になる変異(§M の M1 = メニュー判定を外す)で
  //   **e2e が TypeError で落ち、要約行(`E2E: pass=… fail=…`)を印字せずに死んでいた**。
  //   赤は出るが**読めない赤**になる = 変異を捕まえたのか検査が死んだのか区別できない
  //   (2026-08-03 の変異走行 197体で、実際に1件だけ此の形で判定不能になった)。
  //   `?.` にすると digest 無しの要求として 400 が返り、下の check が**読める赤**を出す。
  //   ★守る場所は「引数の位置で読む所」全部。`&&` の鎖の中は先頭の `?.` が短絡で守るが、
  //   引数は評価されてしまう(`stChoice.choice?.digest` も同じ理由で全部 `?.` にした)。
  const rPerm = await choose(SID_PERM, { key: "1", digest: stPerm.choice?.digest });
  const jPerm = await rPerm.json();
  check("★★許可確認へ打鍵 -> 409、承認は起きない",
    rPerm.status === 409 && jPerm.reason === "choice-hard-stop", JSON.stringify(jPerm));
  check("★★許可確認へ出た send-keys は0件", sentKeys().length === beforePerm,
    JSON.stringify(sentKeys().slice(beforePerm)));

  // 指紋を持たない要求は 400。サーバが今の画面から埋めてしまうと検査が消える
  // (「電話が見た画面」と「サーバが見た画面」が同じである保証が無くなる)。
  const beforeNoDig = sentKeys().length;
  const rNoDig = await choose(SID_CHOICE, { key: "1" });
  check("★指紋なしの打鍵は 400(サーバが埋めない)", rNoDig.status === 400, String(rNoDig.status));
  const rBadKey = await choose(SID_CHOICE, { key: "y", digest: stChoice.choice?.digest });
  check("受け付けない鍵は 400", rBadKey.status === 400, String(rBadKey.status));
  check("400 の間 send-keys は0件", sentKeys().length === beforeNoDig);

  const rOldDig = await choose(SID_CHOICE, { key: "1", digest: "0000000000000000" });
  const jOldDig = await rOldDig.json();
  check("★古い指紋は 409 で、今の指紋を返す(電話が撮り直さずにやり直せる)",
    rOldDig.status === 409 && jOldDig.reason === "digest-mismatch" && jOldDig.digest === stChoice.choice?.digest,
    JSON.stringify(jOldDig));
  check("古い指紋でも send-keys は0件", sentKeys().length === beforeNoDig);

  // 5択へ `7`。指紋も鍵の種別も正しいのに**その選択肢が無い** = 未定義の打鍵(2026-08-03)。
  const rNoOpt = await choose(SID_CHOICE, { key: "7", digest: stChoice.choice?.digest });
  const jNoOpt = await rNoOpt.json();
  check("★無い番号は 409 で断る(5択へ 7 を流さない)",
    rNoOpt.status === 409 && jNoOpt.reason === "choice-no-such-option", JSON.stringify(jNoOpt));
  check("無い番号でも send-keys は0件", sentKeys().length === beforeNoDig);

  // ★本題: 良性メニューには実際に届く。%11 の画面は動かないので applied は unverified
  //   ——「送った」と「効いた」を分けて返している事も同時に測れる。
  const rOk = await choose(SID_CHOICE, { key: "2", digest: stChoice.choice?.digest });
  const jOk = await rOk.json();
  const okChoiceKeys = sentKeys().slice(beforeNoDig).filter((c) => c.includes("%11"));
  check("★良性メニューへは打鍵が1回だけ届く(literal で 2)",
    rOk.status === 200 && jOk.accepted === true && jOk.route === "tmux" &&
    okChoiceKeys.length === 1 && okChoiceKeys[0].at(-1) === "2" && okChoiceKeys[0].includes("-l"),
    JSON.stringify({ jOk, okChoiceKeys }));
  check("★画面が動かない回は applied=unverified(送信を効果と読まない)",
    jOk.applied === "unverified", JSON.stringify(jOk));
  check("★着地した画面も返る(applied だけでは**どこへ**動いたかが落ちる)",
    jOk.after?.screen === "CHOICE" && jOk.after.choice === "benign", JSON.stringify(jOk.after));
  check("unverified には撃ち直しを止める但し書きが付く",
    typeof jOk.note === "string" && jOk.note.includes("Do not re-send"), JSON.stringify(jOk.note));

  // ★同じ指紋への2発目。電話が `unverified` を「失敗」と読んで撃ち直す形を、
  //   HTTP 層でも断る事の検査(単体は choice.test.mjs、此処は口が緩んでいない事)。
  const beforeRetry = sentKeys().length;
  const rRetry = await choose(SID_CHOICE, { key: "2", digest: stChoice.choice?.digest });
  const jRetry = await rRetry.json();
  check("★★同じ指紋への2発目は 409(1発目が次の画面へ流れない)",
    rRetry.status === 409 && jRetry.reason === "choice-already-sent", JSON.stringify(jRetry));
  check("2発目で send-keys は増えない", sentKeys().length === beforeRetry,
    JSON.stringify(sentKeys().slice(beforeRetry)));

  // ---- 11. 登録簿(session_id -> pane)経路 -----------------------------------
  // 出典: DESIGN §2.10。cwd 一致では会話を特定できない(同 cwd に数十〜数百の会話)。
  // 書き手は ~/.claude/statusline.sh。ここではその出力と同じ JSON を置いて読み側を通す。
  const PANE_DIR = join(SB, "keys", "panes");
  mkdirSync(PANE_DIR, { recursive: true });
  // rank が大きいほど新しい登録(1000 < 2000 < 3000)。実時間では「今から N 秒前」に写す。
  // 絶対時刻を置かない理由は putRegistry のコメント参照 — 固定 mtime は TTL で死ぬ。
  const register = (sid, pane, rank) => putRegistry(sid, pane, rank ? 5 - rank / 1000 : 0);

  // 11-a. 登録が無い状態: 同じ cwd に claude が3つ → 特定不能(= 登録簿が要る理由の実演)
  const beforeNoReg = sentKeys().length;
  const rNoReg = await send(SID_REG_A, "登録が無いので届かないはず");
  const jNoReg = await rNoReg.json();
  check("★登録なし: 同cwdに claude 2つ -> 409 ambiguous", rNoReg.status === 409 && jNoReg.reason === "ambiguous" && jNoReg.candidates === 2,
    JSON.stringify(jNoReg));
  check("★登録なし: send-keys が0件", sentKeys().length === beforeNoReg);

  // 11-b. ★本題: 登録があれば、同じ cwd の会話でも**それぞれ正しいペイン**に届く
  register(SID_REG_A, "%20", 2000);
  register(SID_REG_B, "%21", 2000);
  const beforeA = sentKeys().length;
  const jA = await (await send(SID_REG_A, "Aへ")).json();
  const keysA = sentKeys().slice(beforeA);
  check("★登録あり A -> %20 へ注入(source=registry)",
    jA.route === "tmux" && jA.pane === "%20" && jA.source === "registry", JSON.stringify(jA));
  check("★A の本文は %20 だけに届いた",
    keysA.length === 2 && keysA.every((k) => k[2] === "%20") && keysA[0].at(-1) === "Aへ",
    JSON.stringify(keysA));
  const beforeB = sentKeys().length;
  const jB = await (await send(SID_REG_B, "Bへ")).json();
  const keysB = sentKeys().slice(beforeB);
  check("★登録あり B -> %21 へ注入", jB.pane === "%21", JSON.stringify(jB));
  check("★B の本文は %21 だけに届いた(Aのペインに混ざらない)",
    keysB.length === 2 && keysB.every((k) => k[2] === "%21") && keysB[0].at(-1) === "Bへ",
    JSON.stringify(keysB));

  // 11-c. ★陽性対照: 同じペインをより新しい会話が名乗っている(ペインの使い回し)
  //       古い方に送ると **別の会話に本文が入る**。送らず、ワーカーにも落とさない。
  register(SID_STALE, "%20", 1000); // A(2000)より古く %20 を名乗る
  const beforeStale = sentKeys().length;
  const rStale = await send(SID_STALE, "別の会話に入ってはいけない");
  const jStale = await rStale.json();
  check("★stale -> 409 blocked", rStale.status === 409 && jStale.reason === "stale", JSON.stringify(jStale));
  check("★stale で send-keys が0件", sentKeys().length === beforeStale,
    JSON.stringify(sentKeys().slice(beforeStale)));

  // 11-d. ★陽性対照: 登録先ペインの現在地が会話の cwd と違う → 登録を信じない
  register(SID_MISMATCH, "%22", 2000); // %22 は CWD_OTHER に居る。会話は CWD_REG。
  const beforeMis = sentKeys().length;
  const rMis = await send(SID_MISMATCH, "居場所が違う");
  const jMis = await rMis.json();
  check("★cwd 不一致 -> 409 blocked", rMis.status === 409 && jMis.reason === "cwd-mismatch", JSON.stringify(jMis));
  check("★cwd 不一致で send-keys が0件", sentKeys().length === beforeMis);

  // 11-e. ★陽性対照: 登録の無い会話は、他が名乗り済みのペインを候補にしない
  //       (C は開かれていない。%20/%21 に流したら A/B の会話に混入する)
  const beforeC = sentKeys().length;
  const jC = await (await send(SID_REG_C, "Cは開かれていない")).json();
  check("★登録なし C -> 名乗り済みを除くと候補ゼロ = ワーカー経路", jC.route === "worker", JSON.stringify(jC));
  check("★C で send-keys が0件(A/B のペインに混ざらない)", sentKeys().length === beforeC);

  // 11-f. 一覧と status に由来と理由が出る
  const list3 = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const by3 = Object.fromEntries(list3.sessions.map((s) => [s.id, s.live]));
  check("一覧: A は tmux/%20", by3[SID_REG_A]?.route === "tmux" && by3[SID_REG_A]?.pane === "%20", JSON.stringify(by3[SID_REG_A]));
  check("一覧: stale は blocked(理由つき)", by3[SID_STALE]?.route === "blocked" && by3[SID_STALE]?.reason === "stale",
    JSON.stringify(by3[SID_STALE]));
  check("一覧: cwd 不一致も blocked", by3[SID_MISMATCH]?.reason === "cwd-mismatch", JSON.stringify(by3[SID_MISMATCH]));
  const stA = await (await fetch(`${B}/api/sessions/${SID_REG_A}/status`, { headers: H })).json();
  check("status: A は registry 由来", stA.route === "tmux" && stA.source === "registry", JSON.stringify(stA));

  // 11-g. 割り込みも登録簿で宛先が決まる / 決められない時は止めない
  const beforeIntrA = sentKeys().length;
  const jIntrA = await (await fetch(`${B}/api/sessions/${SID_REG_A}/interrupt`, { method: "POST", headers: H })).json();
  const kIntrA = sentKeys().slice(beforeIntrA);
  check("interrupt: A は %20 へ Escape 1回", jIntrA.pane === "%20" && kIntrA.length === 1 && kIntrA[0][2] === "%20" && kIntrA[0].at(-1) === "Escape",
    JSON.stringify(kIntrA));
  const beforeIntrS = sentKeys().length;
  const rIntrS = await fetch(`${B}/api/sessions/${SID_STALE}/interrupt`, { method: "POST", headers: H });
  check("★interrupt: stale は 409(別の会話を止めない)", rIntrS.status === 409, String(rIntrS.status));
  check("★interrupt: stale で send-keys が0件", sentKeys().length === beforeIntrS);

  // 11-g2. ★送信で鍵が満杯の最中の割り込みは **200 で通り、行列を飛び越える**。
  //   出典: DESIGN §2.18-11。**2026-08-04 に測る物ごと入れ替えた**ので経緯を残す:
  //
  //   旧版(§2.18-2 由来)はここで **409/pane-busy** を測っていた。interrupt が送信と同じ鍵を
  //   取り、かつ待ち上限に数えられていたので、満杯なら Escape は1本も出ない —— そこで 200 を
  //   返すと電話には「止めた」と出るのに実際は止まっていないから、というのが理由。
  //   ★**その 409 自体を §2.18-11 が欠陥と裁定した**: 一番干渉したい瞬間(送信が混んでいる時)
  //   に限って電話の「止める」が黙るのは、Tom の裁定「返答待ちであれ作業中であれいつでも見て、
  //   干渉できればいい」と正面から反する。よって割り込みは**優先で行列の先頭に入り、待ち上限に
  //   数えない**。旧版の3本は「直った物を赤にする」側に立つので、直さず**入れ替えた**。
  //   ★これを**この e2e が最初に教えた**(単体 560/560 は全部緑のまま)。単体は注入器の中しか
  //   見ておらず、409 を返すのは HTTP 経路の分岐なので届かない —— §2.26 と同じ形。
  //
  //   今ここで測る物(§2.18-11 の3点を、HTTP の外から):
  //     ① 満杯でも **断られない**(200)
  //     ② **保持者は待つ**(横取りしない)が、**待っている送信は飛び越える** =
  //        Escape の前に走った送信は**1本だけ**(保持者)。行列の4本は後回し。
  //     ③ **待った事実が値に出る**(`waitedMs > 0` = 鍵が空だったのではない)
  //   ★② の陰性対照は変異 M104(優先の挿入位置を末尾へ戻す)。M104 では行列の4本が先に
  //   走るので Escape の前の送信が 5本になり、この検査だけが赤くなる。
  //
  //   実測(2026-08-04、この検査の keystroke 列):
  //     [["send-keys","%16","-l","--","混雑0"], ["send-keys","%16","Escape"], ["send-keys","%16","混雑1"]]
  //     保持者 → Escape → 行列の1本目。`waitedMs` は 1034ms(= 保持者の echo 予算ぶん)。
  //   ★`混雑0` に Enter が続いていないのは %16 が deaf なペインだから(echo が来ないので
  //   送信は本文だけ置いて予算切れで降りる)。**Escape が本文と Enter の間に落ちた訳ではない**
  //   —— 保持者は鍵を放してから割り込みが走っている(それが `waitedMs` の正体)。
  //
  //   ★鍵を埋める仕掛けは「tmux を遅くする」では作れない(2026-08-02、実測して作り替えた)。
  //   tmux は `execFileSync`(`server.mjs` の `exec: execFileSync`)なので、capture を遅くすると **event loop ごと
  //   止まる**。すると後続の要求はそもそも parse されず、鍵に並ぶ前に順番待ちになる
  //   = 鍵の行列は常に空のまま、6本目が 202 で通ってしまう(初版はこれで4件赤になった)。
  //   鍵が **await をまたいで** 握られる場所は1つだけ: pollScreen の `await sleep(25)`。
  //   だから本文が入力欄に載らないペイン(%16 = SID_DEAF)へ送る。そこは echo が来ないまま
  //   ECHO_BUDGET_MS(1500ms)ぶん poll し続けるので、その間に他の要求が鍵へ並べる。
  //   ★満杯は**待ち時間で作らず、断られた事実で確かめる**(2026-08-02、3度作り替えた末の形)。
  //   経過を残す = 同じ道をもう一度掘らない為:
  //     1版 `sleep(500)` 固定 -> 10回に1回赤。満杯は高々 echo 予算ぶんしか続かないので、
  //        検査プロセス自身が遅れると行列が捌けた後に撃ってしまう。
  //     2版 retry + 「6本目の送信で満杯を確認 -> その後に割り込む」-> 12回中8回赤。
  //        確認した時の満杯と、割り込みが見る満杯が別物。
  //     3版 証人と割り込みを Promise.all で同時に投げる -> 6回中3回赤。
  //        **証人自身が最後の待ち枠を埋める**ので、証人は待ち行列に入って(6秒後に)
  //        composer-mismatch で返り、代わりに一番遅く着いた送信が pane-busy を持って行く。
  //        実測 (RC_E2E_DEBUG_BUSY): `#4 409/pane-busy @649ms` / `証人 409/composer-mismatch @24455ms`。
  //   4版 = ここ。**専用の証人を立てない**。容量(1本が保持 + maxWaiters=4)より1本多く投げ、
  //   「どれか1本が 409 pane-busy で返った」= その瞬間に満杯だった、という**観測**を前提にする。
  //   その直後に割り込みを撃てば、同じ満杯に当たる —— 断られた送信は `mutex.mjs` の `maxWaiters` 判定の
  //   `normalWaiters(q) >= maxWaiters` で **enqueue の前に** 弾かれるので行列を1つも消費せず、
  //   保持中の1本が echo 予算(RC_E2E_ECHO_BUDGET_MS)を使い切るまで満杯は崩れないから。
  //   ★`q.length` ではなく `normalWaiters(q)`(§2.18-11 で通常の待ちだけを数える様に変えた)。
  //   ここで数えているのは**送信**なので上限の効き方は同じ = この仕掛けは生き残っている。
  //   ★循環していない: 満杯の観測は**送信が断られた事**だけで出来ていて、割り込みの結果を
  //   一切見ていない。だから割り込み側をどう変異させても前提は緑のまま、下の本題だけが
  //   赤くなる。逆に満杯が作れなければ前提の検査が赤になる。
  const S16 = join(SB, "screen-16.txt");
  const screen16 = readFileSync(S16, "utf8");
  const drain = async (sends) => {
    // 画面を選択肢に化けさせると送信は即断られるので、行列が予算ぶん待たずに降りる。
    writeFileSync(S16, readFileSync(join(SB, "screen-choice.txt"), "utf8"));
    await Promise.all(sends.map((p) => p.then((r) => r.text()).catch(() => null)));
    writeFileSync(S16, screen16); // 後続の検査に影響させない
  };
  const CAP = 1 + MAX_WAITERS; // 1本が保持 + 待ち上限
  let beforeBusy = 0;
  let jFull = null;
  let rBusy = null;
  let jBusy = null;
  let keysAtIntr = [];
  let tries = 0;
  for (; tries < 3 && !jFull; tries++) {
    beforeBusy = sentKeys().length;
    const busySends = Array.from({ length: CAP + 1 }, (_, i) => send(SID_DEAF, `混雑${i}`));
    // どれか1本が pane-busy で断られた瞬間 = 満杯が観測できた瞬間。
    const seen = new Promise((resolve) => {
      for (const p of busySends) {
        p.then((r) => r.clone().json().catch(() => ({})))
          .then((j) => { if (j?.reason === "pane-busy") resolve(j); })
          .catch(() => {});
      }
    });
    jFull = await Promise.race([seen, sleep(4000).then(() => null)]);
    if (jFull) {
      // 満杯はまだ崩れていない(保持中の1本が予算を使い切るまで空きは出ない)。
      rBusy = await fetch(`${B}/api/sessions/${SID_DEAF}/interrupt`, { method: "POST", headers: H });
      jBusy = await rBusy.json();
      // ★**割り込みが返った瞬間**で切る。`drain()` の後まで待つと、行列の残りが降りた分まで
      //   混ざって「Escape の前に何本走ったか」が測れなくなる(順序の検査は窓の取り方が全て)。
      keysAtIntr = sentKeys().slice(beforeBusy);
    }
    if (process.env.RC_E2E_DEBUG_BUSY) {
      console.log(`  [busy try ${tries}] full=${JSON.stringify(jFull)} intr=${rBusy?.status} keys=${sentKeys().length - beforeBusy}`);
    }
    await drain(busySends);
  }
  // 前提そのものを測る。ここが赤なら、下の3本は「鍵が満杯だったから」の話になっていない。
  check("前提: 鍵が満杯(容量を超えた送信は 409 pane-busy = 積まない)",
    jFull !== null, `${tries}回作ろうとして満杯を観測できず`);
  // ① 満杯でも断られない。旧版はここで 409 を要求していた(§2.18-11 が覆した)。
  check("★interrupt: 鍵が満杯でも断られない(優先は待ち上限に数えない)",
    rBusy?.status === 200, `${rBusy?.status} ${JSON.stringify(jBusy)}`);
  // ② 保持者は待つ / 待っている送信は飛び越える。**Escape の手前に居る送信は保持者1本だけ**。
  //   M104(優先を末尾へ)ではここが 5本になる = この1本だけが赤くなる。
  const escAt = keysAtIntr.findIndex((k) => k.at(-1) === "Escape");
  const sendsBeforeEsc = keysAtIntr.slice(0, Math.max(escAt, 0)).filter((k) => k.includes("-l")).length;
  check("★interrupt: 行列を飛び越える(Escape の前に走った送信は保持者の1本だけ)",
    escAt >= 0 && sendsBeforeEsc === 1,
    `escAt=${escAt} sendsBefore=${sendsBeforeEsc} ${JSON.stringify(keysAtIntr)}`);
  check("★interrupt: Escape はこの窓で1回だけ(連打にならない)",
    keysAtIntr.filter((k) => k.at(-1) === "Escape").length === 1, JSON.stringify(keysAtIntr));
  // ★`jBusy.waitedMs` を「鍵を待った証拠」に使ってはいけない(2026-08-04、書きかけて捨てた)。
  //   `waited` は `#interruptExclusive` の **Escape を押した後の観測 poll** の長さ
  //   (`seen.waited`)であって、鍵の行列で待った時間ではない。実測 1034ms は
  //   PRE_FRAMES(24枚)ぶんの idle 判定に掛かった時間。鍵を一切待たない実装でも >0 になるので、
  //   「待った事の検査」として置くと**何も見分けない緑**になる。鍵を待った事は上の ② が
  //   保持者の本文を Escape の手前に見る事で測っている —— そちらが正しい住所。

  // 11-h. 壊れた登録ファイルがあっても他の会話は生きる(1件で全体を落とさない)
  writeFileSync(join(PANE_DIR, `${SID_REG_B}.json`), '{"session_id":"aaaa');
  const jBroken = await (await fetch(`${B}/api/sessions/${SID_REG_A}/status`, { headers: H })).json();
  check("壊れた登録が1件あっても A は解決できる", jBroken.route === "tmux" && jBroken.pane === "%20", JSON.stringify(jBroken));
  register(SID_REG_B, "%21", 2000); // 後続に影響させない

  // ---- 12. 未発言の会話(jsonl がまだ無い) -----------------------------------
  // 出典: DESIGN §2.10。transcript は最初のメッセージまで作られないので、
  // 「開いて席を立った会話」は jsonl 走査の一覧に出ない = 電話から最初の一言をCan't send。
  // Tom 裁定「返答待ちであれ作業中であれいつでも見て、干渉できればいい」に反するので通す。
  register(SID_FRESH, "%23", 3000);
  register(SID_GONE, "%90", 3000); // %90 は list-panes に存在しない

  const list4 = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const fresh = list4.sessions.find((s) => s.id === SID_FRESH);
  check("★未発言の会話が一覧に出る", !!fresh, JSON.stringify(list4.sessions.map((s) => s.id)));
  check("★未発言: 中身が無いことを名乗る(捏造しない)",
    // 2026-08-16(spec-audit A2): 「(未発言)」は機械の内部語だったので人の言葉に変えた。
    fresh?.title === "New session" && fresh?.turns === 0 && fresh?.lastPrompt === "" && fresh?.fromRegistryOnly === true,
    JSON.stringify(fresh));
  check("★未発言: cwd はペインの現在地", fresh?.cwd === CWD_FRESH, JSON.stringify(fresh));
  check("★未発言: 一覧の live は tmux/%23", fresh?.live?.route === "tmux" && fresh?.live?.pane === "%23",
    JSON.stringify(fresh?.live));
  // ★陽性対照: ペインが消えた登録は一覧に出さない(叩いてもCan't send行を並べない)
  check("★陽性対照: ペインが消えた登録は一覧に出ない", !list4.sessions.some((s) => s.id === SID_GONE),
    JSON.stringify(list4.sessions.map((s) => s.id)));

  // 12-b. jsonl が無くても 404 にしない(履歴は空)
  const rHF = await fetch(`${B}/api/sessions/${SID_FRESH}/history`, { headers: H });
  const jHF = await rHF.json();
  check("★未発言: history は 404 でなく空配列", rHF.status === 200 && Array.isArray(jHF.history) && jHF.history.length === 0,
    `${rHF.status} ${JSON.stringify(jHF)}`);
  // ★F4(2026-09-04、Codex around-review): `around` が在る時、jsonl が無い会話(此処の
  //   `!target` 分岐)は後段の ENOENT 分岐と**同じ形**(anchor/olderAvailable/newerAvailable
  //   付き)を返す事 —— 旧実装は此処だけ `{history:[]}` のまま(電話の
  //   `HistoryAroundResponse` は其の3鍵が非 optional なので復号が落ちる)。
  const rHFA = await fetch(`${B}/api/sessions/${SID_FRESH}/history?around=0:0`, { headers: H });
  const jHFA = await rHFA.json().catch(() => null);
  check("★F4: 未発言(jsonl無し)+ around は around 形の空応答(200, anchor/olderAvailable/newerAvailable 付き)",
    rHFA.status === 200 && Array.isArray(jHFA?.history) && jHFA.history.length === 0 &&
      jHFA.anchor === "0:0" && jHFA.olderAvailable === false && jHFA.newerAvailable === false,
    `${rHFA.status} ${JSON.stringify(jHFA)}`);
  const stF = await (await fetch(`${B}/api/sessions/${SID_FRESH}/status`, { headers: H })).json();
  check("★未発言: status は tmux/registry", stF.route === "tmux" && stF.pane === "%23" && stF.source === "registry",
    JSON.stringify(stF));

  // 12-c. 本題: 電話から最初の一言が %23 に届く
  const beforeF = sentKeys().length;
  const jF = await (await send(SID_FRESH, "最初の一言")).json();
  const keysF = sentKeys().slice(beforeF);
  check("★未発言: 最初の一言が %23 へ注入される",
    jF.route === "tmux" && jF.pane === "%23" && jF.source === "registry", JSON.stringify(jF));
  check("★未発言: 本文は %23 だけに届いた",
    keysF.length === 2 && keysF.every((k) => k[2] === "%23") && keysF[0].at(-1) === "最初の一言",
    JSON.stringify(keysF));

  // 12-d. ★陽性対照: jsonl も無くペインも無い = 掴めるものが無い。
  //       ワーカー(-p --resume)に落とすと存在しない会話を再開しようとする。落とさない。
  const beforeG = sentKeys().length;
  const rG = await send(SID_GONE, "掴む先が無い");
  const jG = await rG.json();
  check("★陽性対照: 未発言+ペイン消失 -> 409 pane-gone(ワーカーに落とさない)",
    rG.status === 409 && jG.reason === "pane-gone" && jG.route === "blocked", `${rG.status} ${JSON.stringify(jG)}`);
  check("★陽性対照: pane-gone で send-keys が0件", sentKeys().length === beforeG);
  const rIG = await fetch(`${B}/api/sessions/${SID_GONE}/interrupt`, { method: "POST", headers: H });
  check("未発言+ペイン消失の interrupt は落ちず「止める物が無い」", rIG.status === 200 && (await rIG.json()).interrupted === false);

  // 12-f. ★ストリームの `screen` 事象を初めて検査する(2026-08-02)
  //   測って分かった穴: `grep -rln 'screenBody|event: "screen"' test/` = **0件**、
  //   `grep -rn '"gone"' test/` = **0件**。`/stream` を購読している検査は在ったが、
  //   見ていたのは `message` 事象だけ。だから `route:"gone"`(産む所1・使う所0の死んだ
  //   経路名 = 電話には「状態不明」としか出ない)が誰にも見られずに生き残っていた。
  //
  //   ★到達条件を実装から確かめてある: `/stream` は**購読時**に `resolvePane()` して
  //   ペインが無ければワーカー経路に落ちる(server.mjs の `if (found.pane)`)。つまり
  //   「最初から消えている会話」ではこの枝に入らない。入るのは**購読中に消えた**時だけ。
  //   よって生きている %23 で購読してから、偽 tmux の一覧から %23 を抜く。
  {
    const ctl = new AbortController();
    const chunks = [];
    const sres = await fetch(`${B}/api/sessions/${SID_FRESH}/stream`, { headers: H, signal: ctl.signal });
    const pump = (async () => {
      const reader = sres.body.getReader();
      const dec = new TextDecoder();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(dec.decode(value));
      }
    })().catch(() => {});
    // 出荷する parser で解く(生の文字列 includes だと「バイトが来た」しか言えない)。
    const screens = () => {
      const p = createSseParser();
      const out = [];
      for (const c of chunks) out.push(...p.push(c));
      return out.filter((e) => e.type === "screen").map(decodeEvent).filter((d) => d.ok).map((d) => d.body);
    };
    await waitFor(() => screens().length > 0, 3000);
    const first = screens()[0] || {};
    check("★購読直後に今の画面が1件来る(tmux 経路)", first.route === "tmux" && first.pane === "%23",
      JSON.stringify(first));
    // ★窓は溜まった枚数ぶん。固定値だと1枚しか撮っていないのに 5.6 秒見たと主張する
    //   (画面はこれをそのまま「N秒 動く印なし」と出すので、そのまま嘘になる)。
    check("★購読直後の windowMs が観測枚数ぶん(4倍の窓を主張しない)",
      first.windowMs === 1400, `windowMs=${first.windowMs}`);

    // ここでペインを消す。偽 tmux は毎回 tmux-panes.txt を読み直すので即座に効く。
    writeFileSync(join(SB, "tmux-panes.txt"),
      PANES.split("\n").filter((l) => !l.startsWith("%23" + PANE_SEP)).join("\n"));
    const blocked = () => screens().find((s) => s.route !== "tmux");
    await waitFor(() => !!blocked(), 4000);
    const b = blocked() || {};
    check("★購読中にペインが消えたら blocked を流す(死んだ経路名 gone を残さない)",
      b.route === "blocked" && b.reason === "pane-gone", JSON.stringify(b));
    // ★これが本体。`blocked` と名乗るだけの**嘘の文**を通さない。
    //   `blockedMessage()` には pane-gone の枝が無く、既定は cwd 不一致の文だった:
    //   「登録されたペインの現在地(不明)が、この会話のフォルダと一致しません。」
    //   画面が消えた事と現在地がずれた事は別の事実で、後者は「開き直せば直る」と読める。
    check("★pane-gone の説明が cwd 不一致の文にすり替わっていない(既定に落ちる嘘の対照)",
      typeof b.message === "string" && !/doesn't match this session's/.test(b.message), JSON.stringify(b.message));
    check("★pane-gone の説明が画面消失の事を言っている",
      /can't be found|closed/.test(String(b.message)), JSON.stringify(b.message));

    writeFileSync(join(SB, "tmux-panes.txt"), PANES); // 後続に影響させない
    ctl.abort();
    await pump;
  }

  // 12-g. ★long-poll(電話の本線)。2026-08-04
  //
  //   なぜ SSE でなく此処が本線か: iPhone Safari が `fetch` の本文を逐次で渡すかは
  //   **実機でしか測れない**(§8-4 = 人の門)。検出器を書けばその検出器の正しさが同じ
  //   測れない一点に載る = `mutex.mjs` の「到達しない守り」。完了した応答は中継も browser も
  //   溜め込めないので、構造で正しい方を採った。
  //
  //   ★此処で初めて測る物: **poll と poll の隙間に起きた gap が消えない**事。
  //   従来 gap は id 無しで流れるだけだったので、購読が切れている間に起きた「読み直せ」は
  //   誰にも届かず消えていた —— 電話は古い履歴を正しいと信じたまま走り続ける。
  {
    const pollUrl = (sid, q) => `${B}/api/sessions/${sid}/poll?${new URLSearchParams(q)}`;
    const poll = async (sid, q) => {
      const r = await fetch(pollUrl(sid, q), { headers: H });
      return { r, j: await r.json() };
    };

    // --- tmux 経路 ---
    const p1 = await poll(SID_FRESH, { wait: "0" });
    check("★poll は完了した JSON を返す(中継も browser も溜め込めない形)",
      p1.r.status === 200 && p1.j.route === "tmux" && typeof p1.j.cursor === "string",
      JSON.stringify(p1.j).slice(0, 200));
    check("★poll の応答は握られない(cache-control: no-store)",
      /no-store/.test(String(p1.r.headers.get("cache-control"))), String(p1.r.headers.get("cache-control")));
    check("栞は経路が読める形(電話は中身を解釈しない)", p1.j.cursor.startsWith("t."), p1.j.cursor);

    // ★世代の印が**連番でない**事を測る。ここを測らないと、直したと言っている欠陥
    //   (再起動後に最初の feed がまた `1` を取り、再起動前の栞 `1.50` が偶然一致して
    //    `ring.since(50)` が空 = 「追いついた」と黙って嘘をつく)を守る物が1つも無い。
    //   ★正直に言うと、これは**跨ぎの一意性そのものの証明ではない**。process を跨いで
    //     測っていないので、証明しているのは (a) 印が連番の見た目をしていない事
    //     (b) 同じ process 内の別の会話で値が違う事 —— 連番と固定値という現実的な
    //     退化の2つを殺せる網であって、乱数性の証明ではない。過大に読まない。
    const tokOf = (c) => String(c).split(".")[1];
    check("★世代の印が連番の見た目をしていない(8桁の16進)", /^[0-9a-f]{8}$/.test(tokOf(p1.j.cursor)), tokOf(p1.j.cursor));

    // ★**同じ tmux 経路の別の会話**と比べる。feed の印は会話ごとなので、此処が同じなら
    //   固定値へ退化している。ワーカー経路の印(`w.`)は manager に1つなので比較対象に
    //   ならない —— 出所の違う2つを並べても、それは何も測っていない。
    const pOther = await poll(SID_CHOICE, { wait: "0" });
    check("★同じ経路の別の会話は別の世代の印を持つ(固定値へ退化していない)",
      pOther.j.route === "tmux" && tokOf(p1.j.cursor) !== tokOf(pOther.j.cursor),
      `${pOther.j.route}: ${tokOf(p1.j.cursor)} vs ${tokOf(pOther.j.cursor)}`);

    // ここで転記が現れる。tail が後から取り付くと、電話が撮った /history との継ぎ目が
    // 見えないので「読み直せ」が要る。**その合図が次の poll まで生き残るか**が本題。
    writeFileSync(join(PROJ, `${SID_FRESH}.jsonl`), [
      JSON.stringify({ entrypoint: "cli", cwd: CWD_FRESH, type: "user", message: { role: "user", content: "poll用" } }),
      JSON.stringify({ type: "ai-title", aiTitle: "poll 経路" }),
    ].join("\n"));

    let gapSeen = null;
    let cur = p1.j.cursor;
    for (let i = 0; i < 6 && !gapSeen; i++) {
      const p = await poll(SID_FRESH, { cursor: cur, wait: "1500" });
      cur = p.j.cursor;
      gapSeen = (p.j.items || []).find((it) => it.kind === "gap");
    }
    check("★poll と poll の隙間に起きた gap が届く(id 無しで流して消えていた物)",
      !!gapSeen && gapSeen.why === "tail-attached", JSON.stringify(gapSeen));
    check("★その gap は順序を持っている(= ring に載った = 再生できる)",
      !!gapSeen && Number.isInteger(gapSeen.seq), JSON.stringify(gapSeen));

    const again = await poll(SID_FRESH, { cursor: cur, wait: "0" });
    check("★一度渡した gap を栞の先で二度渡さない(読み直しが永久に続かない)",
      !(again.j.items || []).some((it) => it.kind === "gap" && it.why === "tail-attached"),
      JSON.stringify(again.j.items));

    const forged = await poll(SID_FRESH, { cursor: "t.deadbeef.99.0", wait: "0" });
    check("★別の世代の栞では繋がない(再起動を跨いだ「追いついた」の嘘を塞ぐ)",
      (forged.j.items || []).some((it) => it.kind === "gap" && it.why === "epoch-mismatch"),
      JSON.stringify(forged.j.items));
    const crossed = await poll(SID_FRESH, { cursor: "w.deadbeef.99.0", wait: "0" });
    check("★経路が入れ替わった栞では繋がない(seq の空間が別物)",
      (crossed.j.items || []).some((it) => it.kind === "gap" && it.why === "route-changed"),
      JSON.stringify(crossed.j.items));

    // --- ワーカー経路 ---
    const w1 = await poll(SID1, { wait: "0" });
    check("ワーカー経路の poll は route=worker、栞は w.", w1.j.route === "worker" && w1.j.cursor.startsWith("w."),
      JSON.stringify(w1.j).slice(0, 160));
    // ★世代の印は manager に1つ。連番だと再起動後の最初の manager がまた同じ値を取る。
    check("★ワーカー側の世代の印も連番の見た目をしていない(8桁の16進)",
      /^[0-9a-f]{8}$/.test(String(w1.j.cursor).split(".")[1]), String(w1.j.cursor).split(".")[1]);
    const wCross = await poll(SID1, { cursor: "t.deadbeef.5.0", wait: "0" });
    check("★tmux の栞をワーカー経路に持ち込んでも「追いついた」にしない",
      (wCross.j.items || []).some((it) => it.kind === "gap"), JSON.stringify(wCross.j.items));

    // ★保留が**出来事で起きる**事。時間切れで返るだけなら long-poll ではなく短周期の
    //   ポーリングで、電話の電池と回線をただ食う。
    const t0 = Date.now();
    const held = poll(SID1, { cursor: w1.j.cursor, wait: "8000" });
    await new Promise((r) => setTimeout(r, 150)); // 保留が登録されるまで
    await fetch(`${B}/api/sessions/${SID1}/messages`, {
      method: "POST", headers: { ...H, "content-type": "application/json" },
      body: JSON.stringify({ text: "poll を起こす" }),
    });
    const hp = await held;
    const elapsed = Date.now() - t0;
    check("★保留中の poll が出来事で起きる(時間切れ待ちではない)",
      (hp.j.items || []).length > 0 && elapsed < 7000, `elapsed=${elapsed} items=${(hp.j.items || []).length}`);

  }

  // 12-h. ★送信待ちの取り消し(2026-08-04)。
  //
  //   単体検査は `queueView` / `dropQueued` を**別々に**測っている。此処で初めて測るのは
  //   その2つの継ぎ目 —— poll が載せる数と、DELETE が捨てる数が**同じ物を指しているか**。
  //   継ぎ目が外れていても、単体はどちらも緑のまま通る(数の出所が server、捨てる側が
  //   worker なので、片方だけ直すと気付けない)。
  //
  //   ★いちばん大事な1行は「捨てても**走っている番は生き残る**」。此処が壊れると、人が
  //   「取り消す」と読んだボタンが生成中の turn を殺す —— しかも電話には成功と出る。
  //
  //   ★★2026-08-05 の根治。此処は一度 `queued=1`(期待 2)で崩れて原因未特定のまま置いて
  //   あった。真因は**壁時計の賭け**: 初版は「走っている番は 1200ms 走り続ける」を暗黙の
  //   前提にして、その窓の中に 3往復の HTTP と node の間合いを全部入れていた。窓を跨ぐと
  //   worker の `entry.queue.shift()` が行列から1本引き出すので `queued` が 2 -> 1 -> 0 と減る。
  //   実測(`RC_E2E_SLOW_MS=50`)で 12-h だけが赤くなり、この形である事を確かめた。
  //   直し方は定数を大きくする事**ではない**(それは賭け金を増やしただけ)。turn が終わる
  //   時刻を検査の側が持つ —— `releaseSlowTurn(n)` を置くまで偽ワーカーは答えない。
  {
    const qUrl = (sid) => `${B}/api/sessions/${sid}/queue`;
    const pollOf = async (sid) => (await (await fetch(`${B}/api/sessions/${sid}/poll?wait=0`, { headers: H })).json());

    // --- 机で開かれている会話(tmux 経路)---
    const pt = await pollOf(SID_FRESH);
    // ★`null` である事を測る。`=== null` でなく `!= null` で書くと **欄そのものが無い**
    //   場合も通ってしまい、「知らない」を運ぶ器が消えた事に気付けない。
    check("★机の会話の送信待ちは `null`(0 ではない = 観測していない事を数にしない)",
      "queued" in pt && pt.queued === null, `queued=${JSON.stringify(pt.queued)} route=${pt.route}`);
    const dt = await fetch(qUrl(SID_FRESH), { method: "DELETE", headers: H });
    const dtj = await dt.json();
    check("★机の会話の送信待ちは電話から捨てない(409 / queue-not-ours)",
      dt.status === 409 && dtj.reason === "queue-not-ours", `${dt.status} ${JSON.stringify(dtj).slice(0, 160)}`);

    // --- ワーカー経路。応答が遅い会話へ3本送って、2本を待たせる ---
    const s1 = await (await send(SID_SLOW, "走る番")).json();
    check("送信待ちの土台: 1本目はワーカー経路で受理される",
      s1.accepted === true && s1.route === "worker", JSON.stringify(s1).slice(0, 160));
    await send(SID_SLOW, "待つ番A");
    await send(SID_SLOW, "待つ番B");

    const pw = await pollOf(SID_SLOW);
    // ★ここが「数の出所は持ち主」の実測。事象を数える実装だと `user_queued` が2件出た後も
    //   降ろした時に何も出ないので、捨てた後まで 2 のまま張り付く。
    check("★ワーカー経路の poll が送信待ちの数を載せる(1本走り、2本待つ)",
      pw.route === "worker" && pw.queued === 2, `queued=${JSON.stringify(pw.queued)}`);

    const d1 = await fetch(qUrl(SID_SLOW), { method: "DELETE", headers: H });
    const d1j = await d1.json();
    check("★待っている送信を捨てられる(捨てた数を名乗る)",
      d1.status === 200 && d1j.dropped === 2 && d1j.route === "worker",
      `${d1.status} ${JSON.stringify(d1j)}`);

    const pw2 = await pollOf(SID_SLOW);
    check("★捨てた後の数は 0(電話が自分で引き算していない = server が言い直す)",
      pw2.queued === 0, `queued=${JSON.stringify(pw2.queued)}`);

    const d2 = await fetch(qUrl(SID_SLOW), { method: "DELETE", headers: H });
    const d2j = await d2.json();
    check("★空の行列を捨てても失敗にしない(0 は「無かった」で嘘ではない)",
      d2.status === 200 && d2j.dropped === 0, `${d2.status} ${JSON.stringify(d2j)}`);

    // ★捨てた事は EventRing に残る。電話が繋ぎ直した時に「その turn は届かなかった」と
    //   名指しで拾える為 —— 揮発させると、切断中に捨てた分が誰にも知られず消える。
    const ringQ = (await pollOf(SID_SLOW)).items || [];
    const dropped = ringQ.filter((it) => it.kind === "message" && it.event?.type === "user_dropped");
    check("★捨てた turn は1件ずつ名指しで残る(切断中でも後から拾える)",
      dropped.length === 2 && dropped.every((it) => it.event.reason === "user_cleared")
      && dropped.map((it) => it.event.text).join(",") === "待つ番A,待つ番B",
      JSON.stringify(dropped.map((it) => [it.event.text, it.event.reason])));

    // ★★走っている番は**生きている**。取り消しは行列だけを触る(止めるのは interrupt)。
    //   此処まで来て初めて1本目を放す。上の数の検査は全部「まだ走っている」が前提なので、
    //   放す位置がこの検査の意味を決める(前へ動かすと数の検査が測れなくなる)。
    releaseSlowTurn(1);
    let echoed = false;
    await waitFor(async () => {
      const items = (await pollOf(SID_SLOW)).items || [];
      echoed = items.some((it) => it.kind === "message"
        && String(it.event?.message?.content?.[0]?.text ?? "") === "echo:走る番");
      return echoed;
    });
    check("★★取り消しても走っている番は死なない(取り消す ≠ 止める)", echoed,
      `echo:走る番 が出たか=${echoed}`);

    const g = await fetch(qUrl(SID_SLOW), { headers: H });
    check("GET /queue は 405(行列は消す口しか無い。数は poll が載せる)", g.status === 405, String(g.status));

    // --- 12-h-2. 保留中の poll を**起こす条件**。自分の diff を読み直して出た欠陥の的 ---
    //   初版は捨てた件数に関わらず `wakeWorkerPolls` を呼んでいた。捨てた時は emit 側が
    //   既に起こしているので二度目は空振り、捨てなかった時は**出来事ゼロで保留を起こす**
    //   = 電話が空の 200 を受けて即座に張り直す。長待ち受けを選んだ理由を自分で壊す形。
    //   ★両側を測る。片側(起きる事)だけだと、無条件へ戻す変更が緑のまま通る。
    const holdPoll = (sid, cursor, wait) =>
      fetch(`${B}/api/sessions/${sid}/poll?cursor=${encodeURIComponent(cursor)}&wait=${wait}`, { headers: H })
        .then((r) => r.json());

    await send(SID_SLOW, "走る番2");
    await send(SID_SLOW, "待つ番C");
    const curHeld = (await pollOf(SID_SLOW)).cursor;
    const tWake = Date.now();
    const heldQ = holdPoll(SID_SLOW, curHeld, 6000);
    await sleep(150); // 保留が登録されるまで
    const d3 = await (await fetch(qUrl(SID_SLOW), { method: "DELETE", headers: H })).json();
    const hq = await heldQ;
    const wakeMs = Date.now() - tWake;
    check("★捨てた事で保留中の poll が起きる(電話は張り直さずに知る)",
      d3.dropped === 1 && wakeMs < 5000
      && (hq.items || []).some((it) => it.kind === "message" && it.event?.type === "user_dropped"),
      `dropped=${d3.dropped} ms=${wakeMs} items=${JSON.stringify((hq.items || []).map((it) => it.event?.type))}`);

    // 走っている番が終わるまで待つ。待たずに次を測ると、echo が保留を**正当に**起こして
    // 「起きなかった筈」が偶然赤くなる —— 測っている物と違う理由で色が変わる検査になる。
    releaseSlowTurn(2); // 上の 12-h-2 も「走る番2 がまだ走っている」に依っていた
    await waitFor(async () => ((await pollOf(SID_SLOW)).items || []).some((it) =>
      String(it.event?.message?.content?.[0]?.text ?? "") === "echo:走る番2"));

    const curIdle = (await pollOf(SID_SLOW)).cursor;
    const tIdle = Date.now();
    const heldIdle = holdPoll(SID_SLOW, curIdle, 700);
    await sleep(150);
    const d4 = await (await fetch(qUrl(SID_SLOW), { method: "DELETE", headers: H })).json();
    const hi = await heldIdle;
    const idleMs = Date.now() - tIdle;
    check("★★捨てる物が無い時は保留を起こさない(空の 200 で電話に張り直させない)",
      d4.dropped === 0 && (hi.items || []).length === 0 && idleMs >= 600,
      `dropped=${d4.dropped} ms=${idleMs} items=${JSON.stringify(hi.items)}`);
  }

  // 12-e. 登録簿にも jsonl にも居ない ID は今まで通り 404
  check("登録も jsonl も無い ID -> 404",
    (await fetch(`${B}/api/sessions/aaaaaaaa-0000-0000-0000-0000000000ff/status`, { headers: H })).status === 404);

  // ---- 13. ★未登録の会話には、cwd が一致しても注入しない -------------------
  //
  // ここが今回いちばん危ない経路。SID_UNREG の cwd には claude のペインが %24 の
  // **1つだけ**居るので、素朴に cwd で引くと「1つに定まった」と読めてしまう。
  // だがそれは同定ではない: 実測で ~/.claude だけに192会話が同じ cwd を共有しており、
  // 今そこに開いている1枚が電話で選んだ会話である保証はどこにも無い。外れた時の
  // 結果は「他人の会話に本文と Enter が入り、実際に動き出す」= 取り返しがつかない。
  // 拒否が正しい(2026-07-31 Codex 同意)。
  const beforeUnreg = sentKeys().length;
  const rUnreg = await send(SID_UNREG, "他人の会話に入ってはいけない本文");
  const jUnreg = await rUnreg.json();
  check("★未登録+同cwdに claude 1つ -> 409 unregistered(推測で注入しない)",
    rUnreg.status === 409 && jUnreg.reason === "unregistered", `status=${rUnreg.status} ${JSON.stringify(jUnreg)}`);
  check("★陽性対照: そのペインへ send-keys が0件", sentKeys().length === beforeUnreg,
    JSON.stringify(sentKeys().slice(beforeUnreg)));
  check("★拒否文が直し方(rc-claude)を含む", typeof jUnreg.error === "string" && jUnreg.error.includes("rc-claude"),
    JSON.stringify(jUnreg.error));
  // ワーカーにも落ちていないこと。落とすと同じ会話を2プロセスが読む(lost-update)。
  check("★unregistered はワーカー経路にも落ちない", jUnreg.route === "blocked", JSON.stringify(jUnreg));
  const stUnreg = await (await fetch(`${B}/api/sessions/${SID_UNREG}/status`, { headers: H })).json();
  check("status も unregistered を返す", stUnreg.route === "blocked" && stUnreg.reason === "unregistered",
    JSON.stringify(stUnreg));
  const lsUnreg = (await (await fetch(`${B}/api/sessions`, { headers: H })).json()).sessions
    .find((s) => s.id === SID_UNREG);
  check("一覧でも blocked/unregistered として見える", lsUnreg?.live?.reason === "unregistered",
    JSON.stringify(lsUnreg?.live));
  check("一覧の blocked 行が**文面**を持つ(電話が理由コードを生で出さずに済む)",
    typeof lsUnreg?.live?.message === "string" && lsUnreg.live.message.length > 10,
    JSON.stringify(lsUnreg?.live));
  check("★一覧の文面と、送信を断った時の文面が同一(出所が1つ)",
    jUnreg.error === lsUnreg?.live?.message,
    `${JSON.stringify(jUnreg.error)} vs ${JSON.stringify(lsUnreg?.live?.message)}`);

  // 12-b. 走査の絞り込み(?limit= / ?scope=)— ここまで検査ゼロだった
  {
    // ★2026-08-02 に契約を変えた。旧: `limit` = **開く file の上限**(= 走査の費用の栓)。
    //   新: `limit` = **返す会話の件数**。理由は実機の分布で、机の上では絶対に出ない:
    //     edith  jsonl 642本のうち adapter の `sdk-cli` が 636本、`cli` は 6本。
    //            mtime 順で最初の `cli` は **113本目** → 旧契約では `limit=100` でも一覧は 0本。
    //     MBP    1,644本中 `cli` 318本、最初の `cli` は 1本目 → **MBP では永久に露見しない**。
    //   費用の栓を外した訳ではない: 最悪(1件も該当が無い)= 全 file の meta を読む =
    //   実測 edith 30ms / MBP 1,059ms。`scan.examined` に何本開いたかを毎回出す。
    const l1 = await (await fetch(`${B}/api/sessions?limit=1`, { headers: H })).json();
    const scanned1 = l1.sessions.filter((s) => !s.fromRegistryOnly);
    check("?limit= は**会話の件数**として効く(file の件数ではない)",
      l1.scan.limit === 1 && scanned1.length === 1, JSON.stringify(l1.scan) + " / " + scanned1.length);
    check("★埋まったら読むのをやめる(全部は開かない)",
      l1.scan.examined > 0 && l1.scan.examined < l1.scan.files, JSON.stringify(l1.scan));

    // ★edith と同じ形の再現 = 該当しない会話(sdk-cli)が新しい方に大量に居る状態。
    //   旧実装はここで `limit` 件ぶん sdk-cli を開いて全部捨て、**0本**を返した。
    //   ★id の頭は `0adabe70`(= adapter)。**既存 fixture と被らない語**である事が要る:
    //   最初 `9999…` にしたら 12番の登録簿だけの会話(`99999999-0000-…`)に当たり、
    //   陽性対照が「混ざっている」と赤を出した。対照が実装ではなく自分の名前選びを
    //   捕まえた形で、赤の出所を読まずに実装を直していたら間違った修正をしていた。
    for (let i = 0; i < 5; i++) {
      const np = join(PROJ, `0adabe70-0000-0000-0000-00000000000${i}.jsonl`);
      writeFileSync(np, JSON.stringify({ entrypoint: "sdk-cli", cwd: "/adapter", type: "user", message: { content: `adapter ${i}` } }));
      // ★雑音は**枝の頭より新しく**置く。§3-T の畳み込みで祖先が頭の時刻を名乗る様に
      //   なった為、素のままだと祖先が1本目に来て雑音が一度も読まれず、下の
      //   `examined >= 6`(= 読み飛ばした事が計器に出る)が**前提ごと**消える。
      //   新しくしておくと、検査3 は「より新しい雑音を越えて祖先が枠を取る」に強くなる。
      utimesSync(np, FORK_NEW + 60, FORK_NEW + 60);
    }
    const lNoise = await (await fetch(`${B}/api/sessions?limit=1`, { headers: H })).json();
    const scannedN = lNoise.sessions.filter((s) => !s.fromRegistryOnly);
    check("★新しい方が全部 sdk-cli でも cli の会話が返る(edith の分布の再現)",
      scannedN.length === 1, JSON.stringify(lNoise.scan) + " / " + JSON.stringify(scannedN.map((s) => s.id)));
    check("★その為に雑音を読み飛ばした事が計器に出る",
      lNoise.scan.examined >= 6, JSON.stringify(lNoise.scan));
    check("★陽性対照: sdk-cli は一覧に出ない(混ぜない)",
      !lNoise.sessions.some((s) => String(s.id).startsWith("0adabe70")), JSON.stringify(lNoise.sessions.map((s) => s.id)));

    const lr = await (await fetch(`${B}/api/sessions?scope=registered`, { headers: H })).json();
    const rids = lr.sessions.map((s) => s.id);
    check("?scope=registered は登録簿に居る会話だけを返す",
      lr.scan.scope === "registered" && !rids.includes(SID1), rids.join(","));

    const lall = await (await fetch(`${B}/api/sessions?scope=なんでも`, { headers: H })).json();
    check("知らない scope は既定(all)に落ちる",
      lall.scan.scope === "all" && lall.sessions.map((s) => s.id).includes(SID1), JSON.stringify(lall.scan));

    // ★§2.12 で測った正直さが HTTP まで出ている事。中で正直でも外に出さなければ同じ。
    const row = lall.sessions.find((s) => s.id === SID1);
    // ★`row` を素で触らない(2026-08-03)。行が1つ消えるだけで走行ごと落ちて、以降の
    //   検査が**一度も走らない**。変異 P12 が実際にここで台本を殺し、素通り0でも
    //   「捕まえたのか検査が死んだのか」が写しを読むまで確定しなかった。
    //   落ちない = 赤が出る。計器は落ちるより赤を出す方が強い。
    check("一覧の行が metadataIncomplete を名乗る",
      typeof row?.metadataIncomplete === "boolean", JSON.stringify(row ?? null).slice(0, 200));

    // ★§3-T 検査3(並び)。ここに置くのは、edith の分布(新しい方が全部 `sdk-cli`)を
    //   作っているのがこの block だけだから。机の分布では差が出ずに素通りする。
    //   祖先の file は1時間前で止まっていて、頭だけが全材料中いちばん新しい。
    //   → 畳んでいれば `limit=1` の1枠は**祖先**が取る。畳みを `sort` の**後**に置くと
    //     (変異 P10)祖先はここで落ちる = 電話から見て「送った会話が消えた」。
    const lFork = await (await fetch(`${B}/api/sessions?limit=1`, { headers: H })).json();
    const forkIds = lFork.sessions.filter((s) => !s.fromRegistryOnly).map((s) => s.id);
    check("★§3-T 3: 頭が新しければ祖先が `limit` の1枠を取る(行が消えない)",
      forkIds.length === 1 && forkIds[0] === SID_FORK_ANC, JSON.stringify(forkIds));
  }

  // ---- 12-c. §3-T fork した会話は「頭」を見る -------------------------------
  // 出荷済みの欠陥。今の電話は、机で fork した会話の**現在**を持っていない。
  {
    const all = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
    const row = all.sessions.find((s) => s.id === SID_FORK_ANC);

    // 検査1: 枝の側の現在が祖先の行に出る
    check("★§3-T 1: 祖先の行に**頭の** lastPrompt が出る",
      Boolean(row) && row.lastPrompt === "枝で言った事", JSON.stringify(row));
    check("★§3-T 1: 祖先の行の updatedAt は**頭の** mtime(祖先の古い時刻ではない)",
      Boolean(row) && Math.abs(Date.parse(row.updatedAt) - FORK_NEW * 1000) < 2000,
      String(row && row.updatedAt));
    // 陰性対照。差し替えは**読み手の仕事**であって、file が書き換わった訳ではない。
    // ここが赤なら上の2本は「畳めた」証拠にならない(材料の方が動いている)。
    check("★§3-T 陰性対照: 祖先の file 自身は古いまま(材料が動いていない)",
      Math.abs(statSync(join(PROJ, `${SID_FORK_ANC}.jsonl`)).mtimeMs - FORK_OLD * 1000) < 2000,
      String(statSync(join(PROJ, `${SID_FORK_ANC}.jsonl`)).mtimeMs));

    // 検査2: 頭そのものは行として出ない / 陽性対照 = 頭を持たない会話は出る
    check("★§3-T 2: 頭そのものの file は行として出ない(枝が別会話として湧かない)",
      !all.sessions.some((s) => s.id === SID_FORK_HEAD),
      JSON.stringify(all.sessions.map((s) => s.id).filter((i) => String(i).startsWith("bbbbbbbb"))));
    check("★§3-T 2 陽性対照: 頭を持たない普通の会話は出る(全部落とす実装で緑にならない)",
      all.sessions.some((s) => s.id === SID_READY), String(all.sessions.length));

    // 検査4: 頭の file が消えている → 祖先の値で行が**残る**
    const orphan = all.sessions.find((s) => s.id === SID_FORK_ORPHAN);
    check("★§3-T 4: 頭の file が無い会話は祖先の値で行が残る(消さない)",
      Boolean(orphan) && orphan.title === "頭が消えた祖先", JSON.stringify(orphan));

    // 検査4b: 所属は祖先のまま。丸ごと頭から採ると `~` に化ける
    check("★§3-T 4b: 行の cwd / project は**祖先のまま**(枝の記録の cwd に化けない)",
      Boolean(row) && row.cwd === CWD_FORK && row.project === "-rc-e2e-work", JSON.stringify(row));
    check("★§3-T 4b: 題も祖先のまま(メタを丸ごと頭から採っていない)",
      Boolean(row) && row.title === "fork の祖先", String(row && row.title));

    // 検査5: /history の引き先
    const hj = await (await fetch(`${B}/api/sessions/${SID_FORK_ANC}/history?limit=50`, { headers: H })).json();
    const hText = JSON.stringify(hj.history);
    check("★§3-T 5: /history が**頭**を読む(fork の後の番が出る)",
      hText.includes("枝で言った事") && hText.includes("枝からの返事"), hText.slice(0, 200));
    const hOrphan = await (await fetch(`${B}/api/sessions/${SID_FORK_ORPHAN}/history?limit=50`, { headers: H })).json();
    check("★§3-T 5: 頭の file が無ければ祖先を読む(500 にも空にもしない)",
      Array.isArray(hOrphan.history) && hOrphan.history.length > 0, JSON.stringify(hOrphan).slice(0, 200));
    const hPlain = await (await fetch(`${B}/api/sessions/${SID_READY}/history?limit=50`, { headers: H })).json();
    check("★§3-T 5 陰性対照: 頭を持たない会話は今まで通り自分の転写を読む",
      Array.isArray(hPlain.history) && hPlain.history.length > 0 && !JSON.stringify(hPlain.history).includes("枝で言った事"),
      JSON.stringify(hPlain).slice(0, 160));
    const hHead = await (await fetch(`${B}/api/sessions/${SID_FORK_HEAD}/history?limit=50`, { headers: H })).json();
    check("★§3-T 罠2: 頭を直接引くと**頭の**中身が返る(取り違えていない)",
      JSON.stringify(hHead.history).includes("枝からの返事"), JSON.stringify(hHead).slice(0, 200));

    // ★罠1(変異 P14 の的): `scope=registered` でも畳めている事。登録簿は**祖先の id しか
    //   持たない**ので、`only` を走査の前に `registered ∪ {頭の id}` へ広げないと、
    //   頭の file が「開く前に」落ちて畳めない。しかも黙って古い行が出るだけなので、
    //   `scope=all` の検査だけ書いていると**一番使う経路が測られないまま緑**になる。
    const lreg = await (await fetch(`${B}/api/sessions?scope=registered`, { headers: H })).json();
    const rrow = lreg.sessions.find((s) => s.id === SID_FORK_ANC);
    check("★§3-T 罠1: scope=registered でも祖先の行に**頭の**現在が出る",
      Boolean(rrow) && rrow.lastPrompt === "枝で言った事", JSON.stringify(rrow));
    check("★§3-T 罠1 陽性対照: その時も頭そのものは行として出ない",
      !lreg.sessions.some((s) => s.id === SID_FORK_HEAD),
      JSON.stringify(lreg.sessions.map((s) => s.id)));
  }

  // ---- 13-D. ★サーバが語を持つ(`display`)= Sprint 1 の継ぎ目 --------------
  //
  // 出所: DESIGN §2.13「器」+ .harness/spec-native-shell-2026-08-05.md の Sprint 1。
  // 電話の器をネイティブにすると `view.mjs` は移植できない(JS と Swift)。移植せずに
  // 済ませる為に、**画面に出す語をサーバが組んで応答に足す**(S 群)。此処で測るのは
  // その継ぎ目 —— 単体は `view.mjs` の中だけ、静的検査は文字列だけを見ていて、
  // 「サーバが**何を渡したか**」には原理的に届かない。
  //
  // ★測るのは「呼んだか」ではなく「**正しい引数を渡したか**」(spec の訂正3)。
  //   だから各項目に対照を付ける: **間違えやすい方の引数**では同じ値にならない事。
  //   対照が同値で赤が出たら、疑うのは実装ではなく此の検査 —— その fixture では
  //   本命の比較が何も測っていない(= 恒真)という意味。
  {
    const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
    const strip = (o) => {
      const r = { ...(o || {}) };
      delete r.display; // サーバが `fn(code, obj)` に渡したのは `display` を足す**前**の本文
      return r;
    };
    // 本命(期待と一致)と対照(間違った引数では一致しない)を1本にまとめる。
    // 分けて書くと、対照だけが緑で本命が落ちた時と、その逆とで読み手が数を数える羽目になる。
    const argCheck = (name, actual, expected, wrongs) => {
      const same = eq(actual, expected);
      const vacuous = wrongs.filter(([, v]) => eq(actual, v)).map(([n]) => n);
      check(
        name,
        same && vacuous.length === 0,
        same
          ? `★対照が同値(この fixture では何も測れていない): ${vacuous.join(" / ")}`
          : `actual=${JSON.stringify(actual)} expected=${JSON.stringify(expected)}`,
      );
    };

    // --- 一覧 ---
    const dl = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
    const rowTmux = dl.sessions.find((s) => s.live && s.live.route === "tmux");
    check("13-D 土台: 一覧に tmux 経路の行が居る(赤なら以下の行の検査は空)",
      Boolean(rowTmux), JSON.stringify(dl.sessions.map((s) => s.live?.route)));
    if (rowTmux) {
      argCheck("★行の `display.route` は **`row.live`** から組む(行を丸ごと渡していない)",
        rowTmux.display?.route, routeLabel(rowTmux.live),
        [["行を丸ごと", routeLabel(rowTmux)], ["引数なし", routeLabel(undefined)]]);
    }
    const rowSaid = dl.sessions.find((s) => s.lastPrompt);
    check("13-D 土台: 発言の在る行が居る(`subtitleOf` の枝を分ける材料)",
      Boolean(rowSaid), String(dl.sessions.filter((s) => s.lastPrompt).length));
    if (rowSaid) {
      argCheck("★行の `display.subtitle` は **行そのもの**から組む(`live` ではない)",
        rowSaid.display?.subtitle, subtitleOf(rowSaid),
        [["live", subtitleOf(rowSaid.live)], ["引数なし", subtitleOf(undefined)]]);
    }
    argCheck("★一覧の `display.scan` は **走査の計器**から組む(行ではない = 会話ごとに配らない)",
      dl.display?.scan, scanLine(dl.scan),
      [["行", scanLine(dl.sessions[0])], ["引数なし", scanLine(undefined)]]);

    // --- 履歴 ---
    const dh = await (await fetch(`${B}/api/sessions/${SID1}/history`, { headers: H })).json();
    const eUser = (dh.history || []).find((e) => e.role === "user");
    check("13-D 土台: 履歴に user の行が居る", Boolean(eUser), JSON.stringify(dh.history).slice(0, 160));
    if (eUser) {
      argCheck("★履歴の `display.who` は **`entry.role`** から組む(entry を丸ごと渡していない)",
        eUser.display?.who, whoOf(eUser.role),
        [["entry を丸ごと", whoOf(eUser)], ["引数なし", whoOf(undefined)]]);
    }

    // --- poll: gap ---
    const pollD = async (sid, q) =>
      (await (await fetch(`${B}/api/sessions/${sid}/poll?${new URLSearchParams(q)}`, { headers: H })).json());
    /** `pollUntilScreen` が何回撃ったかの置き場。Symbol = サーバの本文と衝突しない。 */
    const POLL_SPEND = Symbol("pollUntilScreen.spend");
    /** 赤の本文の末尾に足す一言。緑の時は誰も読まないので、出るのは失敗した時だけ。 */
    const pollSpend = (r) => {
      const s = r && typeof r === "object" ? r[POLL_SPEND] : undefined;
      if (!s) return " [撃ち直しの記録なし = この道具を通っていない]";
      return s.exhausted
        ? ` [撃ち直し ${s.rounds}/${s.tries} 回を**使い切った** = 待ち足りない可能性がある。直すなら回数を増やす(眠りを足すのではない)]`
        : ` [撃ち直し ${s.rounds}/${s.tries} 回で来た]`;
    };
    /**
     * 画面が1枚来るまで poll を撃ち直す。**眠って待たない**為の道具。
     * 保留中の poll は `feedBroadcast` が起こすが、起こす口は screen 専用ではない ——
     * 配信の1 tick 目は転写に繋いだ印(`tail-attached` の gap)を出すので、
     * 待ち受けは**画面より先に**その item で返ってくる。1回で諦めると `screen: null`。
     * 栞を繋いで撃ち直すので、遅い機械は回数ではなく**待つ時間**が伸びるだけ。
     * `want` を渡すと「その画面が来るまで」。来なければ回数を使い切って最後の物を返す
     * (= 呼び側の check が赤くなる。ここで投げない = 何が来たかを検査文に出す為)。
     *
     * ★**使い切った事を赤の本文に出す**(2026-08-06)。初版は最後に来た物だけを返して
     *   いたので、赤は「その画面には成らなかった」としか読めなかった —— 実際には
     *   「10 回撃って成らなかった」と「1 回目で諦めた(呼び方を間違えた)」と
     *   「回数は残っているが別の枝で抜けた」が**同じ顔**になる。壊れているのか
     *   測れていないのかを赤の本文で分けられないと、次に直す人は待ち時間を伸ばす
     *   band-aid へ引き寄せられる(正しい直し方は回数を増やす事で、眠りではない)。
     *   欄は Symbol に置く: サーバの本文と綴りが衝突しない上に、`JSON.stringify` にも
     *   乗らないので**既存の検査文は1文字も変わらない**(出るのは赤の時だけ)。
     */
    const pollUntilScreen = async (sid, { cursor, tries = 10, wait = "2000", want } = {}) => {
      let r = { cursor, screen: null };
      let rounds = 0;
      for (let i = 0; i < tries; i++) {
        rounds++;
        r = await pollD(sid, { ...(r.cursor ? { cursor: r.cursor } : {}), wait });
        if (r.screen && (!want || want(r.screen))) {
          if (r && typeof r === "object") r[POLL_SPEND] = { rounds, tries, exhausted: false };
          return r;
        }
      }
      if (r && typeof r === "object") r[POLL_SPEND] = { rounds, tries, exhausted: true };
      return r;
    };
    // 世代の合わない栞 = 必ず gap(12-g で実測済み)。`tail-attached` と違って**文面が出る**側
    // なので、`null` を返す枝と取り違えずに済む。
    const pg = await pollD(SID_FRESH, { cursor: "t.deadbeef.99.0", wait: "0" });
    const gapIt = (pg.items || []).find((it) => it.kind === "gap");
    check("13-D 土台: 文面の出る gap が1件来る",
      Boolean(gapIt) && gapIt.why !== "tail-attached", JSON.stringify(pg.items));
    if (gapIt) {
      argCheck("★gap の `display.notice` は **`why`** から組む(item を丸ごと渡していない)",
        gapIt.display?.notice, gapNotice(gapIt.why),
        [["item を丸ごと", gapNotice(gapIt)], ["引数なし", gapNotice(undefined)]]);
    }
    // ★SSE 側の gap も撃つ(2026-08-05、変異検査で穴が出た)。初版は poll の gap しか
    //   測っていなくて、`SSE_SPEAKS.gap` を丸ごと消す変異が**緑のまま生き残った**。
    //   `sendEvent` の gap の呼び口は4箇所あり、そこが黙って欄無しになる = 電話が
    //   `undefined` を出す。張り直しに古い印を渡すと必ず gap が1本来るので、それで撃つ。
    {
      const gctl = new AbortController();
      const gres = await fetch(`${B}/api/sessions/${SID_FRESH}/stream`, {
        headers: { ...H, "last-event-id": "deadbeef.99" }, signal: gctl.signal,
      });
      const gp = createSseParser();
      const gEvents = [];
      const grd = gres.body.getReader();
      const gdec = new TextDecoder();
      const gdone = (async () => {
        for (;;) {
          const { done, value } = await grd.read();
          if (done) break;
          gEvents.push(...gp.push(gdec.decode(value)));
          if (gEvents.some((e) => e.type === "gap")) break;
        }
      })().catch(() => {});
      await gdone;
      gctl.abort();
      const gb = gEvents.filter((e) => e.type === "gap").map(decodeEvent).filter((d) => d.ok).map((d) => d.body)[0];
      check("13-D 土台: 古い印で張り直すと SSE が gap を1本返す",
        Boolean(gb) && typeof gb.why === "string", JSON.stringify(gb));
      if (gb) {
        argCheck("★SSE の gap にも `display.notice` が載る(呼び口4箇所を口1つで賄っている)",
          gb.display?.notice, gapNotice(gb.why),
          [["本文を丸ごと", gapNotice(gb)], ["引数なし", gapNotice(undefined)]]);
      }
    }

    // --- poll と SSE: 選択待ちの面 ---
    // ★登録に依る検査を**先に**置く(2026-08-05、実測して並べ替えた)。登録簿は mtime が
    //   心拍で、読み側は `HEARTBEAT_TTL_MS = 15_000` を超えた登録を死んだ物として扱う。
    //   初版はこの下の「転写に足して待つ」節を先に置いていて、其処が最悪 8×1500ms 待つ
    //   ので、余裕が3秒しか無かった。実際に1回、`SID_CHOICE` が `unregistered` に落ちて
    //   選択の面の検査が赤くなった(同じ回で 12-h の行列も崩れた)。以後の3回は緑だが、
    //   **緑が続いた事は余裕が在る証明ではない**ので、待つ節を後ろに回して依存を消した。
    // ★★2026-08-05 追記: 並べ替えでも足りない。ここは「**遥か上で建てた配信がまだ生きている**」
    //   に賭けていた —— `POLL_LEASE_MS = 30_000` を過ぎて誰も見ていなければ `stopFeedIfIdle`
    //   が `f.screen` を `null` にするので、間の節が 30 秒を超えた機械では `screen: null` が返る
    //   (loadavg 90 で実測)。賭けを外す: 1本目で**建て直し**、2本目は**長待ち受け**で
    //   1枚撮れるまで起こされるのを待つ。遅い機械は長く待つだけで、赤にはならない。
    await pollD(SID_CHOICE, { wait: "0" });
    const pc1 = await pollUntilScreen(SID_CHOICE);
    check("13-D 土台: 選択待ちの画面が1枚来る",
      Boolean(pc1.screen) && pc1.screen.screen === "CHOICE",
      JSON.stringify(pc1.screen).slice(0, 160) + pollSpend(pc1));
    if (pc1.screen) {
      argCheck("★poll の `display.choice` は **画面の本体**から組む(poll の本文ではない)",
        pc1.display?.choice, choiceView(pc1.screen),
        [["poll の本文", choiceView(pc1)], ["引数なし", choiceView(undefined)]]);
    }
    const pc2 = await pollD(SID_CHOICE, { cursor: pc1.cursor, wait: "0" });
    // ★これが訂正2の本体。`choiceView` は純関数だが、**その材料が毎回来るとは限らない**。
    //   毎回 `show:false` を載せると、画面が変わっていない poll が電話の持っている
    //   選択待ちの面を消す —— 承認待ちが黙って画面から消えるのが最悪の形。
    check("★★画面が変わっていない poll は `choice` も `null`(電話が持つ選択待ちの面を消さない)",
      pc2.screen === null && Boolean(pc2.display) && pc2.display.choice === null,
      JSON.stringify({ screen: pc2.screen, display: pc2.display }));

    // --- 13-Z: 配信は登録簿を**毎 tick 読み直す**(写しを握らない) ------------------
    // ★2026-08-05 の実測で見つけた本番の欠陥の栓。配信の timer は最初に建てた1本が
    //   生き続けるので、poll の「1リクエストにつき1回だけ読む」写しをそこへ渡すと、
    //   `registryCtx` の `now` だけが進んで mtime は凍る = 15 秒(HEARTBEAT_TTL_MS)後に
    //   その会話は永久に `unregistered` に見えた。電話には「ペイン登録をしていないため、
    //   宛先を確定できません」が出続ける —— 登録は 2 秒ごとに打たれているのに。
    // ★時間を待つ形にはしない(それは同じ病気の再発明)。**登録先を付け替えて**、
    //   配信が追随するかで測る。凍っていれば古いペインの画面を出し続ける。
    // ★眠って待たない。`feedBroadcast` は保留中の poll を必ず起こすので、**長待ち受けで**
    //   1枚目を受け取る。眠りで待つと「その機械で 1.4 秒に間に合ったか」を測る事になる
    //   (実測 2026-08-05: loadavg 90 の機械で 2 秒の眠りが足りず `null` が返った)。
    await pollD(SID_FEEDREG, { wait: "0" }); // ここで配信が建つ(最初の1枚はまだ撮れていない)
    const fz1 = await pollUntilScreen(SID_FEEDREG);
    check("13-Z 土台: 登録された会話の画面が1枚来る(登録先の %28 から撮れている)",
      Boolean(fz1.screen) && fz1.screen.pane === "%28" && fz1.screen.screen === "SENDABLE",
      JSON.stringify(fz1.screen).slice(0, 160) + pollSpend(fz1));
    putRegistry(SID_FEEDREG, "%29"); // 登録先を付け替える(心拍は打ち続ける = 生きた登録)
    // 「%29 が来るまで」撃ち直す。★`windowMs` は観測窓が埋まるまで tick ごとに伸びるので、
    // **画面が変わった = 付け替わった**ではない(1回で判定すると %28 のまま版だけ上がった
    // 枚を掴む)。凍った写しを握っていれば %29 は永久に来ないので、回数を使い切って赤。
    // ★待つ時間を延ばしても壊れる側には倒れない(凍った写しは待つほど古くなるだけ)。
    const fz2 = await pollUntilScreen(SID_FEEDREG, { cursor: fz1.cursor, want: (s) => s.pane === "%29" });
    check("★★配信は登録簿を毎 tick 読み直す(付け替えに追随して %29 の選択画面になる)",
      Boolean(fz2.screen) && fz2.screen.pane === "%29" && fz2.screen.screen === "CHOICE",
      JSON.stringify(fz2.screen).slice(0, 200) + pollSpend(fz2));

    {
      const cctl = new AbortController();
      const cchunks = [];
      const cres = await fetch(`${B}/api/sessions/${SID_CHOICE}/stream`, { headers: H, signal: cctl.signal });
      const cpump = (async () => {
        const rd = cres.body.getReader();
        const dec = new TextDecoder();
        for (;;) {
          const { done, value } = await rd.read();
          if (done) break;
          cchunks.push(dec.decode(value));
        }
      })().catch(() => {});
      const cScreens = () => {
        const p = createSseParser();
        const out = [];
        for (const c of cchunks) out.push(...p.push(c));
        return out.filter((e) => e.type === "screen").map(decodeEvent).filter((d) => d.ok).map((d) => d.body);
      };
      await waitFor(() => cScreens().length > 0, 3000);
      const sb = cScreens()[0] || {};
      check("13-D 土台: SSE の screen が1件来る(選択待ち)", sb.screen === "CHOICE", JSON.stringify(sb).slice(0, 160));
      argCheck("★SSE の `screen` にも `display.choice` が載る(poll と同じ材料・同じ関数)",
        sb.display?.choice, choiceView(strip(sb)),
        [["引数なし", choiceView(undefined)]]);
      cctl.abort();
      await cpump;
    }

    // --- 応答そのものが語を持つ4口 ---
    // 対照は3種: **status を渡していない** / **本文を渡していない** / **別の口の関数**。
    // 3つ目が要るのは、4本とも 409 では文面が `b.error` で揃ってしまい、口を取り違えても
    // 気付けない形が実在するから(此処の fixture はその形を避けて選んである)。
    const rSend = await fetch(`${B}/api/sessions/${SID_CHOICE}/messages`, {
      method: "POST", headers: { ...H, "content-type": "application/json" },
      body: JSON.stringify({ text: "display 検査(選択待ちなので断られる)" }),
    });
    const jSend = await rSend.json();
    argCheck("★`POST …/messages` の `display` は **その応答の status と本文**から組む",
      jSend.display, sendResult(rSend.status, strip(jSend)),
      [["status 違い", sendResult(599, strip(jSend))],
       ["本文違い", sendResult(rSend.status, { ...strip(jSend), error: "★対照★" })],
       ["別の口の関数", interruptResult(rSend.status, strip(jSend))]]);

    const rIntrD = await fetch(`${B}/api/sessions/${SID_READY}/interrupt`, { method: "POST", headers: H });
    const jIntrD = await rIntrD.json();
    argCheck("★`POST …/interrupt` の `display` も同じ",
      jIntrD.display, interruptResult(rIntrD.status, strip(jIntrD)),
      [["status 違い", interruptResult(599, strip(jIntrD))],
       ["本文なし", interruptResult(rIntrD.status, null)],
       ["別の口の関数", sendResult(rIntrD.status, strip(jIntrD))]]);

    const rChD = await choose(SID_CHOICE, { key: "1" }); // 指紋なし = 400。send-keys は0件
    const jChD = await rChD.json();
    argCheck("★`POST …/choice` の `display` も同じ",
      jChD.display, choiceResult(rChD.status, strip(jChD)),
      [["status 違い", choiceResult(599, strip(jChD))],
       ["本文違い", choiceResult(rChD.status, { ...strip(jChD), error: "★対照★" })],
       ["別の口の関数", interruptResult(rChD.status, strip(jChD))]]);

    // ★此処だけ **200** の口を撃つ。最初は `SID_FRESH` の 409(`queue-not-ours`)で書いて
    //   いて、それは赤くなった —— 409 では `clearQueueResult` も `interruptResult` も
    //   `{kind:"refused", text: b.error}` に潰れるので、**口を取り違えても同じ値**になる。
    //   赤は実装ではなく fixture の欠陥の報せで、直すのは対照ではなく撃つ場所の方。
    //   200 なら「取り消す送信は残っていませんでした。」対「Nothing was running to stop.」で
    //   割れる。既に空にしてある行列をもう一度捨てるだけなので、他の検査の状態も動かさない。
    const rQD = await fetch(`${B}/api/sessions/${SID_SLOW}/queue`, { method: "DELETE", headers: H });
    const jQD = await rQD.json();
    check("13-D 土台: 行列の取り消しが 200 で返る(409 だと下の対照が効かない)",
      rQD.status === 200, `status=${rQD.status} ${JSON.stringify(jQD)}`);
    argCheck("★`DELETE …/queue` の `display` も同じ",
      jQD.display, clearQueueResult(rQD.status, strip(jQD)),
      [["status 違い", clearQueueResult(599, strip(jQD))],
       ["本文違い", clearQueueResult(rQD.status, { ...strip(jQD), dropped: 7 })],
       ["別の口の関数", interruptResult(rQD.status, strip(jQD))]]);

    // --- poll と SSE: message の `who`。転写に1行足して、同じ追記を両方で受ける ---
    // ★**待つ節はこの block の最後**。上の注記の通り、待っている間に他の会話の登録が
    //   心拍の窓から落ちる。ここまで来れば登録に依る検査は済んでいるので、待って良い。
    const sctl = new AbortController();
    const schunks = [];
    const sres = await fetch(`${B}/api/sessions/${SID_FRESH}/stream`, { headers: H, signal: sctl.signal });
    const spump = (async () => {
      const rd = sres.body.getReader();
      const dec = new TextDecoder();
      for (;;) {
        const { done, value } = await rd.read();
        if (done) break;
        schunks.push(dec.decode(value));
      }
    })().catch(() => {});
    const sseOf = (type) => {
      const p = createSseParser();
      const out = [];
      for (const c of schunks) out.push(...p.push(c));
      return out.filter((e) => e.type === type).map(decodeEvent).filter((d) => d.ok).map((d) => d.body);
    };

    const freshPath = join(PROJ, `${SID_FRESH}.jsonl`);
    let curD = (await pollD(SID_FRESH, { wait: "0" })).cursor; // tail を取り付けてから足す
    writeFileSync(freshPath, `${readFileSync(freshPath, "utf8").replace(/\n?$/, "\n")}${JSON.stringify({
      type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "display 検査の返事" }] },
    })}\n`);
    let msgIt = null;
    let tailGap = null;
    // 追記は**張る前**に済ませてあるので、普通は1回目で来る。回数を8から4へ、待ちを
    // 1500 から 800 へ落としても取りこぼさない(実測 4回中4回が1回目)。最悪 3.2 秒。
    for (let i = 0; i < 4 && !msgIt; i++) {
      const p = await pollD(SID_FRESH, { cursor: curD, wait: "800" });
      curD = p.cursor;
      for (const it of p.items || []) {
        if (it.kind === "message" && Array.isArray(it.entries)) msgIt = it;
        if (it.kind === "gap" && it.why === "tail-attached") tailGap = it;
      }
    }
    check("13-D 土台: poll が message を1件運ぶ", Boolean(msgIt), JSON.stringify(msgIt).slice(0, 160));
    if (msgIt) {
      const e0 = msgIt.entries[0];
      argCheck("★poll の message も `display.who` を **`role`** から組む",
        e0.display?.who, whoOf(e0.role),
        [["entry を丸ごと", whoOf(e0)], ["引数なし", whoOf(undefined)]]);
    }
    if (tailGap) {
      // ★`gapNotice` は此処だけ `null` を返す。**欄ごと消えていない**事まで測る ——
      //   欄が無い事と「出す文面が無い」事は別で、前者は電話側で `undefined` を踏む。
      check("★`tail-attached` は欄を持ったまま文面が `null`(出さないと欄が無いを混ぜない)",
        "display" in tailGap && tailGap.display.notice === null, JSON.stringify(tailGap));
    }
    await waitFor(() => sseOf("message").length > 0, 3000);
    const sMsg = sseOf("message")[0];
    check("13-D 土台: SSE も同じ追記を message として運ぶ", Boolean(sMsg), JSON.stringify(sMsg).slice(0, 160));
    if (sMsg && Array.isArray(sMsg.entries)) {
      const s0 = sMsg.entries[0];
      argCheck("★SSE の message にも `display.who` が載る(口は `sendEvent` の1つだけ)",
        s0.display?.who, whoOf(s0.role),
        [["entry を丸ごと", whoOf(s0)], ["引数なし", whoOf(undefined)]]);
    }
    sctl.abort();
    await spump;
  }

  // ---- 13-b. ★二重起動は「読める一行」を残して落ちる ----------------------
  //
  // 常設(launchd)にすると、これを読むのは移動中の Tom で手元に機械は無い。
  // 素の node は `uncaughtException` 経由で `fatal: Error: listen EADDRINUSE ...`
  // という一行しか出さない。何が起きたのか・何を確かめればいいのかが要る。
  // 実測の動機: MBP に残っていた残骸 702個のうち 11個が「fixture は全部あるのに
  // api.key が無い」= サーバが起動に失敗した回だった(2026-08-02)。
  {
    const dup = spawn(process.execPath, [join(ROOT, "src", "server.mjs")], {
      env: { ...process.env, RC_PROJECTS_DIR: join(SB, "projects"), RC_CLAUDE_WORK: fakeWork,
             RC_FLEET_ACCOUNT: fakeAcct, RC_KEY_DIR: join(SB, "keys"), RC_PORT: String(PORT),
             RC_PHONE_TRUST_FILE: TRUST_FILE, RC_E2E_CWD_LOG: CWD_LOG, RC_TMUX_BIN: fakeTmux },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let dupLog = "";
    dup.stdout.on("data", (c) => (dupLog += c));
    dup.stderr.on("data", (c) => (dupLog += c));
    const code = await Promise.race([
      new Promise((r) => dup.once("exit", (c) => r(c))),
      sleep(6000).then(() => { dup.kill("SIGKILL"); return "timeout"; }),
    ]);
    check("★二重起動は落ちる(半端に上がらない)", code === 1, `exit=${code} ${dupLog.slice(0, 300)}`);
    check("★その理由が一行で出る(ポートが埋まっている事+確かめ先)",
      /Cannot start/.test(dupLog) && /duplicate rc-backend/.test(dupLog), JSON.stringify(dupLog.slice(0, 300)));
    check("★陽性対照: 二重起動は listening を名乗らない", !dupLog.includes("listening"), dupLog.slice(0, 200));
    // 先に上がっている方は生きたまま = 後から来た方に道を譲らせない。
    check("★先に上がっている方は無傷", (await fetch(`${B}/api/sessions`, { headers: H })).ok);
  }

  sseCtl.abort();
  await ssePromise;

  // ---- 13-U. ★常設のログに 1リクエスト1行が**実際に**残る(DESIGN §3-U) ------
  //
  // なぜ e2e で測るか: `test/reqlog.test.mjs` は偽の `res` を通すので、**部品が正しい**事しか
  // 言えない。§3-U が答えたい問いは「本番のログに残るか」で、それは本物のサーバの stdout を
  // 読むまで判らない —— 仕掛け忘れ・try の中に入れた・launchd が stdout を捨てている、
  // どれも部品の検査は全部緑のまま通る。ここまでの走行で数十本の要求を通してある。
  const reqLines = svlog.split("\n").filter((l) => l.includes("[rc-backend] req "));
  check("★ログに 1リクエスト1行が残っている", reqLines.length >= 10, `req 行=${reqLines.length}`);
  check("送信の行に method / パスの型 / 結果コードが揃う",
    // ★`build=` は 2026-08-30 に足した欄。行を末尾まで固定したまま新しい形へ張り直す ——
    //   欄が増えたからと `$` を外すと、以後は行末に何が付いても通る検査になる。
    //   ★此処を直し忘れて掃引が赤くなった。単体 991/991 も門が回した対照も緑だった ——
    //     此の主張だけが e2e に居たから。緑はそれが測った範囲しか言わない。
    reqLines.some((l) => / POST \/api\/sessions\/:id\/messages sid=\S+ route=\S+ client=\S+ build=\S+ code=\d+ reason=\S+ ms=\d+$/.test(l)),
    reqLines.filter((l) => l.includes("/messages")).slice(-1)[0] || "(送信の行が無い)");
  check("★ストリームの行に経路が乗る(§3-W が刺さった当の欄)",
    reqLines.some((l) => /\/api\/sessions\/:id\/stream .*route=(tmux|worker) /.test(l)),
    reqLines.filter((l) => l.includes("/stream")).slice(-1)[0] || "(ストリームの行が無い)");
  // ★道を1本足した時、ログの表を直し忘れると新しい道は `(other)` として積まれ、
  //   **ログが静かなだけ**で誰も気づかない(reqlog.mjs の見出しが言っている当の型)。
  //   電話の本線がその静かな穴に落ちていないかを、経路の欄まで含めて測る。
  check("★poll の行が道として畳まれ、経路の欄も埋まっている(`(other)` に落ちていない)",
    reqLines.some((l) => /\/api\/sessions\/:id\/poll .*route=(tmux|worker) /.test(l)),
    reqLines.filter((l) => l.includes("/poll")).slice(-1)[0] || "(poll の行が無い)");
  // ★補完の道も**畳まれている**事(2026-09-02)。`reqlog.mjs` の表は振り分けと共有なので、
  //   届いている以上ここも埋まっている筈 —— だが「届く」と「記録に道として残る」は
  //   `pathShape` を経由するかどうかで別々に壊れうるので、別に測る。
  //   同時に、問いに打った path(`src/wi`)が1文字もログへ写っていない事も測る:
  //   此の口は**外から来た任意の文字列**を受ける唯一の新しい道で、`?` 以降を捨てる規則が
  //   効いていなければ、cwd の中身の名前が常設のログへ流れ込む。
  check("★補完の行が道として畳まれている(`(other)` に落ちていない)",
    reqLines.some((l) => /\/api\/sessions\/:id\/paths /.test(l)),
    reqLines.filter((l) => l.includes("/paths")).slice(-1)[0] || "(補完の行が無い)");
  check("★補完: 断った行が理由を名乗る(`no_cwd` が `reason=` に出る)",
    reqLines.some((l) => /\/api\/sessions\/:id\/paths .*code=200 reason=no-cwd /.test(l)),
    reqLines.filter((l) => l.includes("/paths")).slice(-1)[0] || "(補完の行が無い)");
  check("★★補完: 打った問いがログに1文字も出ていない",
    !svlog.includes("src/wi") && !svlog.includes("node_modules") && !/req .*q=/.test(svlog),
    "補完の問い(= 利用者が打った文字列)がログに複製されている");
  // ★陰性対照は「`(other)` が1本も無い」ではない —— それは表が**何でも飲み込む**時にも
  //   通ってしまう(最初にそう書いて、無関係な 404 の行で落ちて気付いた)。表が道を
  //   見分けている事を言うには、知らない道が**ちゃんと `(other)` に落ちる**方を測る。
  check("★陰性対照: 表に無い道は `(other)` のまま(表が何でも飲み込む形になっていない)",
    reqLines.some((l) => / \(other\) /.test(l)),
    "知らない道まで畳まれている = 道の表が catch-all になっている");
  // ★以下3つが本体。「1行残る」より「中身が残らない」の方が取り返しがつかない。
  check("★送った本文がログに出ていない", !svlog.includes("テスト送信"), "本文がログに複製されている");
  check("★sessionId は先頭8文字だけ(全部は出ない)",
    !svlog.includes(SID1) && reqLines.some((l) => l.includes("sid=11111111")), "全長の sessionId がログに在る");
  check("★問い合わせ文字列がログに出ていない",
    !/req .*(scope=registered|limit=)/.test(svlog), "?以降がログに複製されている");
  // ★断った行が**なぜ断ったか**を名乗る。空欄で断られた行はログとして最も無価値
  //   —— 何が起きたかだけ判って、原因だけが判らない。単体検査は偽の `res` を通すので
  //   「実装が名乗れる」までしか言えず、**枝が名乗り忘れている**形はここでしか出ない。
  const mute409 = reqLines.filter((l) => / code=409 reason=- /.test(l));
  check("★409 の行に理由が乗る(理由の欄が空の拒否が1本も無い)",
    mute409.length === 0, mute409[0] || "");
  check("壊れた本文の 400 も理由を名乗る(生の例外文は使わずに)",
    reqLines.some((l) => /code=400 reason=bad-body/.test(l)), "bad-body が名乗られていない");
  // 実際の見た目を人が確かめる口。既定では出さない(緑の走行に 5 行足す意味が無い)。
  if (process.env.RC_E2E_SHOW_LOG === "1") {
    // 末尾5行ではなく**形ごとに1本**。同じ形が何十本も出るので、末尾を見ても種類が判らない。
    const seen = new Map();
    for (const l of reqLines) {
      const k = l.replace(/^.*req \S+ /, "").replace(/sid=\S+ /, "").replace(/ ms=\d+$/, "");
      if (!seen.has(k)) seen.set(k, l);
    }
    console.log(`--- ログの実物(${reqLines.length}行 / 形は${seen.size}種)---`);
    for (const l of seen.values()) console.log(l);
    console.log("---");
  }

  // ---- 13-W. ★ワーカーの死と「最後の一行」の**順序**を本物の子で測る ---------
  //
  // DESIGN §2.35 が「懸念だが未測定」として残していた問い:
  //   **`worker_closed` は、最後の本文が電話に届く前に着き得るか。**
  // 単体検査では出ない。偽のワーカーは同期に流れるので、順序が構造ではなく
  // 台本で決まってしまう。だから e2e に**本物の OS の子を起こす台**を作る。
  //
  // 測る先は ring の seq。electron でも SSE でもなく此処なのは、**電話が実際に読む物**が
  // `eventsSince`(= poll の items)だから。UI の見た目ではなく届く順序そのものを見る。
  //
  // ★先に素の `child_process` で測った(2026-08-04、探り 52 回):
  //   平坦な子(書いて即 `os._exit`)では 1MB 積んでも事象ループを 120ms 塞いでも
  //   **逆転は 0/52**。libuv は読める stdio を先に流してから `exit` を出す。
  //   つまり §2.35 が想定していた「単純な取りこぼし」は**起きない**。
  //   起きるのは下の2つ —— どちらも想定とは別の機構だった。
  {
    const ringOf = async (sid) => {
      const r = await fetch(`${B}/api/sessions/${sid}/poll?wait=0`, { headers: H });
      const j = await r.json();
      return (j.items || []).filter((it) => it.kind === "message").map((it) => ({ seq: it.seq, ev: it.event }));
    };
    const textOf = (e) => String(e?.ev?.message?.content?.[0]?.text ?? "");
    const seqOfText = (ring, t) => (ring.find((e) => textOf(e) === t) || {}).seq;
    const seqOfType = (ring, t) => (ring.find((e) => e?.ev?.type === t) || {}).seq;

    // --- 13-W-a. 孫が pipe を握ったまま親が先に死ぬ ---------------------------
    //
    // ★2026-08-05、揺らぎを根治した。直す前の (2) は「孫の行は worker_closed の**後**に
    //   届く」を**孫の 0.35 秒の眠り**で作っていた。これは 12-h と同じ**暗黙の壁時計依存**:
    //   死の合図(親の exit)は素の node で 27ms、孫の行は 400ms —— 差は充分に見えるが、
    //   その 370ms の間サーバの事象ループが塞がると、既に読める孫の行が exit の callback
    //   より先に処理されて順序が入れ替わる。実測(同じ commit・同じ木):
    //     この repo の木で 9/10 赤 / /private/tmp の写しで 1/6 赤
    //   = **結果が機械の混み具合で決まっていた**。緑が「取引を守った」なのか
    //   「たまたま間に合った」なのか言えない検査は、検査の顔をした賭けである。
    //   (git bisect は 1 走 1 判定なので、この種の検査では**嘘の犯人**を指す。
    //    最初 69fd70d を「最初の赤」と出したが、そこでも 1/5 で赤だった = 犯人ではない。)
    //
    // ★見分けたい物は元から順序ではない。「**孫が pipe を握ったままでも死の合図が出る**」
    //   —— つまり合図が `close` ではなく `exit` である事、これだけが discriminator である。
    //   合図が `close` なら、孫が握っている限り worker_closed は**永久に来ない**。
    //   だから孫の筆を検査側が握る(合図の file を置くまで書かない)。壁時計の賭けが消え、
    //   discriminator は残る。
    const jLate = await (await send(SID_DEATH_LATE, "死の順序を測る")).json();
    check("★死の順序(孫): ワーカー経路で受理される", jLate.accepted === true && jLate.route === "worker",
      JSON.stringify(jLate));
    const asShape = (r) => (r || []).map((e) => `${e.seq}:${e.ev?.type}${textOf(e) ? "/" + textOf(e) : ""}`).join(" ")
      || "(ring が空 = 待っていた行が来なかった)";
    // 孫はまだ書いていない(合図を置いていない)。この状態で死の合図が来るのを待つ。
    const ringDead = await waitFor(async () => {
      const r = await ringOf(SID_DEATH_LATE);
      return r.some((e) => e?.ev?.type === "worker_closed") ? r : false;
    });
    const shapeD = asShape(ringDead);
    const sParent = seqOfText(ringDead || [], "ANCHOR-PARENT");
    const sClosed = seqOfType(ringDead || [], "worker_closed");
    check("★死の順序(孫): 死んだ事は `worker_closed` として届く",
      typeof sClosed === "number", shapeD);
    // (1) 親自身の最後の行は**死の前**に届く。= 平坦な取りこぼしは起きていない。
    check("★実測: 親が書いた最後の行は worker_closed より**前**(平坦な取りこぼしは無い)",
      typeof sParent === "number" && typeof sClosed === "number" && sParent < sClosed, shapeD);
    // (2) ★discriminator。孫が pipe を握ったまま(= まだ1文字も書いていない)worker_closed が
    //   届いた。合図を `close` に替えたら此処は**時間切れで**赤くなる —— 孫が握る限り
    //   `close` は来ないので。順序ではなく「合図の出所」を直に見ている。
    //   これは欠陥ではなく**明示した取引**(§2.18-10(2)): 順序より死の検知を採った。
    //   此処が赤くなる = その取引を誰かが黙って裏返した合図。理由ごと読み直す事。
    check("★実測: 孫が pipe を握ったまま worker_closed が届く(死の合図は close ではない)",
      typeof sClosed === "number" && !(ringDead || []).some((e) => textOf(e) === "ANCHOR-GRANDCHILD"),
      shapeD);
    // 此処で孫に筆を渡す。以降に届く本文は**確実に死の後**の物である。
    writeFileSync(DEATH_GATE, "");
    const ringLate = await waitFor(async () => {
      const r = await ringOf(SID_DEATH_LATE);
      return r.some((e) => textOf(e) === "ANCHOR-GRANDCHILD") ? r : false;
    });
    const shape = asShape(ringLate);
    const sGrand = seqOfText(ringLate || [], "ANCHOR-GRANDCHILD");
    // (3) 順序は崩れても**中身は落ちない**。此処が守られている限り、電話は栞を
    //   進め直せば必ず読める(表示の並べ替えは view 側の仕事 = 判断は view にしか置かない)。
    //   ★死んだ後の子の行を ring が受け付けるか、は構造の問い(合図の file とは無関係)。
    check("★死の後に届いた本文も ring から**失われない**(栞で必ず拾える)",
      typeof sGrand === "number" && typeof sClosed === "number" && sGrand > sClosed, shape);

    // --- 13-W-b. 最後の行が**改行の前**で切れて死ぬ ---------------------------
    //
    // 本物で起き得る形: idle 回収の kill / 上限で落とされる / クラッシュ。
    // `worker.mjs` は改行でしか行を切らないので、改行の無い最後の行は entry.buf に残る。
    // stderr には死の時に `flushStderr` が在るのに、stdout には**何も無い**。
    const jPart = await (await send(SID_DEATH_PART, "改行の前で死ぬ")).json();
    check("★死の順序(改行なし): ワーカー経路で受理される", jPart.accepted === true && jPart.route === "worker",
      JSON.stringify(jPart));
    const ringPart = await waitFor(async () => {
      const r = await ringOf(SID_DEATH_PART);
      return r.some((e) => e?.ev?.type === "worker_closed") ? r : false;
    });
    const shapeP = asShape(ringPart);
    check("★改行なし: その手前の行はちゃんと届いている(子は確かに書いた)",
      (ringPart || []).some((e) => textOf(e) === "ANCHOR-BEFORE"), shapeP);
    check("★改行なし: 死んだ事は届く", (ringPart || []).some((e) => e?.ev?.type === "worker_closed"), shapeP);
    // ★2026-08-04 に**直した**。以前は此処が「載らない」を記録する検査で、
    //   §2.45 が「赤くなったら直った合図。直す時は期待値ごと書き換える事」と書いていた。
    //   当ては §2.45 が名指しした形そのもの: `worker.mjs` の死の処理で `entry.buf` を流す
    //   (= stderr 側の `flushStderr` と同じ形)。`WorkerManager._flushStdout` が其れ。
    //   流し込みは**死の合図より先**に出す —— 順序が逆だと、電話は `worker_closed` を見て
    //   会話を畳んだ後に本文を受け取る事になる。
    //
    // ★空振り防止(§2.44 の O1/O2 と同じ対): 「無い」を測る前に、**同じ当て方で
    //   「在る」を捉えられる**事を先に言う。ここを対にしないと、欄の名前を書き間違えた
    //   だけでこの検査は永久に緑 —— 直した日にも緑のまま通り、直った事に誰も気付かない。
    //   見る先は 13-W-a 側の `result`(改行付きで確かに届いた1本)。
    const seer = (r, v) => (r || []).some((e) => e?.ev?.result === v);
    check("★空振り防止: 同じ当て方で、改行付きで届いた `result` は**捉えられる**",
      seer(ringLate, "ANCHOR-PARENT"), shape);
    const lostLine = seer(ringPart, "ANCHOR-NONEWLINE");
    check("★実測: 改行の無い最後の行も ring に**載る**(死の間際に buf を流す)",
      lostLine === true, `落ちている(= 直りが効いていない) ${shapeP}`);
    // ★順序まで見る。「載る」だけなら、死の合図の**後**に生えても緑になってしまう。
    const iLine = (ringPart || []).findIndex((e) => e?.ev?.result === "ANCHOR-NONEWLINE");
    const iDead = (ringPart || []).findIndex((e) => e?.ev?.type === "worker_closed");
    check("★実測: その行は `worker_closed` より**前**に載る(畳んだ後に本文が生えない)",
      iLine >= 0 && iDead >= 0 && iLine < iDead, `line=${iLine} closed=${iDead} ${shapeP}`);
  }

  // ---- 14. ★SIGTERM で速やかに降りる(電話が SSE を1本張ったまま) ----------
  //
  // `server.close()` は**既存接続を切らない**。電話が `/stream` を開いているだけで
  // callback が来ず、launchd は既定 20 秒待って SIGKILL する = 常設(Phase P)にすると
  // 再起動のたびに毎回 20 秒払う。ここは「繋ぎっぱなしの電話」を実際に作ってから測る。
  // ★このブロックはサーバを**殺して**終わるので、必ず一番最後に置く。
  const liveCtl = new AbortController();
  const liveRes = await fetch(`${B}/api/sessions/${SID1}/stream`, { headers: H, signal: liveCtl.signal });
  check("停止測定用の SSE が開いている(この接続が close を塞ぐ)", liveRes.ok, `status=${liveRes.status}`);
  const t0 = Date.now();
  const exited = new Promise((r) => sv.once("exit", () => r(Date.now() - t0)));
  sv.kill("SIGTERM");
  const took = await Promise.race([exited, sleep(9000).then(() => -1)]);
  check("★SSE を張ったままでも SIGTERM で降りる(launchd の 20 秒 SIGKILL を毎回払わない)",
    took >= 0 && took < 6000, `took=${took}ms`);
  liveCtl.abort();
} finally {
  sv.kill("SIGTERM");
}
console.log(`\nE2E: pass=${pass} fail=${fail}`);

// 後片付け。★2026-08-02: ここが無かったせいで `rc-e2e-*` が MBP に 664個・edith に
// 364個(65MB)積み上がっていた。**失敗した時だけ残す** — 落ちた時に中を見られなく
// なる方が損なので。消す前に自分が作った物である署名を照合する = 外れた物を消さない関門。
// ★署名に選ぶのは**この検査自身が必ず書く物**(fake-tmux / projects)。`keys/api.key` は
//   サーバが起動に成功した時だけ書く物なので、署名にすると起動に失敗した残骸が
//   「他人の物」に見える(2026-08-02 実測: 702個中11個がそれで弾かれた)。
if (fail === 0) {
  const mine = SB.includes("rc-e2e-") && existsSync(join(SB, "fake-tmux")) && existsSync(join(SB, "projects"));
  if (mine) rmSync(SB, { recursive: true, force: true });
  else console.log(`(片付けを見送り: 署名が一致しない ${SB})`);
} else {
  console.log(`調べる材料は残してある: ${SB}`);
}
process.exit(fail === 0 ? 0 : 1);
