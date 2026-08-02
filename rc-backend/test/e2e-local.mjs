// ローカル E2E — 偽 claude-work と**偽 tmux** を注入してサーバの全経路を通す。
// 実 claude・実セッション・実 tmux に一切触れない。実行: node test/e2e-local.mjs
//
// 経路は3つ(DESIGN §2.9 / HANDOFF §1-A):
//   tmux 注入  = 机で開かれている会話。入力欄が実在する時だけ送る(生成中でも送れる)
//   ワーカー   = 開かれていない会話(-p --resume)
//   blocked    = 同じ cwd に claude が複数で特定不能 → どちらにも送らない
// 偽 tmux は send-keys を**全部ログに残す**ので「1文字も送っていない」を実測で言える。
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, chmodSync, existsSync, rmSync, utimesSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createSseParser, decodeEvent } from "../src/frames.mjs";
import { PANE_SEP } from "../src/inject.mjs";
import { readHead, writeHead } from "../src/heads.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SB = mkdtempSync(join(tmpdir(), "rc-e2e-"));
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
const CWD_READY  = "/Users/Shared/dev/ready";
const CWD_CHOICE = "/Users/Shared/dev/choice";
const CWD_SHELL  = join(SB, "shell"); // ★ワーカーへ落ちた後**受理される**必要が在る(一覧に載せる)
const CWD_AMBIG  = "/Users/Shared/dev/ambig";
const CWD_GEN    = "/Users/Shared/dev/busy";
const CWD_DEAF   = "/Users/Shared/dev/deaf";
const CWD_RACE   = "/Users/Shared/dev/race";
const CWD_INTR_OK    = "/Users/Shared/dev/intr-ok";
const CWD_INTR_STUCK = "/Users/Shared/dev/intr-stuck";
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
  JSON.stringify({ entrypoint: "cli", cwd: CWD_WORK, type: "user", message: { role: "user", content: "最初の質問" } }),
  JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "最初の答え" }, { type: "tool_use", name: "Bash", input: {} }] } }),
  JSON.stringify({ type: "ai-title", aiTitle: "検証用の会話" }),
  JSON.stringify({ type: "last-prompt", lastPrompt: "最初の質問" }),
].join("\n"));
writeFileSync(join(PROJ, "22222222-2222-2222-2222-222222222222.jsonl"),
  JSON.stringify({ entrypoint: "sdk-cli", cwd: "/x", type: "user", message: { content: "noise" } }));
const FIXTURED = new Set();
function fixture(sid, cwd, title) {
  // ★同じ id を二度書かない。黙って上書きすると、**先に書いた会話の設定が消えた事**が
  //   どこにも出ず、無関係な検査が落ちて原因が id の衝突だと分からなくなる(2026-08-03 に実演)。
  if (FIXTURED.has(sid)) throw new Error(`fixture の id が衝突している: ${sid}(${title})`);
  FIXTURED.add(sid);
  writeFileSync(join(PROJ, `${sid}.jsonl`), [
    JSON.stringify({ entrypoint: "cli", cwd, type: "user", message: { role: "user", content: "q" } }),
    JSON.stringify({ type: "ai-title", aiTitle: title }),
  ].join("\n"));
}
fixture(SID_H2_NEW, CWD_WORK, "H2 頭なし");
fixture(SID_H2_HEAD, CWD_WORK, "H2 頭あり");
fixture(SID_READY, CWD_READY, "注入READY");
fixture(SID_CHOICE, CWD_CHOICE, "注入CHOICE");
fixture(SID_SHELL, CWD_SHELL, "シェルのみ");
fixture(SID_AMBIG, CWD_AMBIG, "特定不能");
fixture(SID_GEN, CWD_GEN, "生成中");
fixture(SID_DEAF, CWD_DEAF, "画面が動かない");
fixture(SID_RACE, CWD_RACE, "選択画面が割り込む");
fixture(SID_INTR_OK, CWD_INTR_OK, "割り込むと止まる");
fixture(SID_INTR_STUCK, CWD_INTR_STUCK, "割り込んでも止まらない");
for (const sid of [SID_REG_A, SID_REG_B, SID_REG_C, SID_STALE]) fixture(sid, CWD_REG, `登録${sid.slice(-1)}`);
fixture(SID_UNREG, CWD_UNREG, "未登録");
fixture(SID_LIMIT, CWD_LIMIT, "上限に当たっている");
fixture(SID_MISMATCH, CWD_REG, "居場所不一致"); // 会話は CWD_REG。登録先ペインは CWD_OTHER に居る

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
for (const d of [CWD_WORK, CWD_SHELL, CWD_NOTRUST]) mkdirSync(d, { recursive: true });
writeFileSync(TRUST_FILE, JSON.stringify({ projects: {
  [CWD_WORK]:  { hasTrustDialogAccepted: true },
  [CWD_SHELL]: { hasTrustDialogAccepted: true },
  [CWD_GONE]:  { hasTrustDialogAccepted: true },   // 承諾はしたが dir はもう無い
  [join(SB, "declined")]: { hasTrustDialogAccepted: false }, // 項は在るが false(通してはいけない)
} }));
fixture(SID_NOTRUST, CWD_NOTRUST, "信頼されていない場所");
fixture(SID_CWD_GONE, CWD_GONE, "消えた場所");

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
                           [SID_INTR_OK, "%25"], [SID_INTR_STUCK, "%26"]]) {
  putRegistry(sid, pane);
}
const SENT_LOG = join(SB, "tmux-sent.log");
writeFileSync(SENT_LOG, "");
const fakeTmux = join(SB, "fake-tmux");
writeFileSync(fakeTmux, `#!/usr/bin/env python3
import sys, os, json
SB = ${JSON.stringify(SB)}
args = sys.argv[1:]
if args and args[0] == "list-panes":
    sys.stdout.write(open(os.path.join(SB, "tmux-panes.txt")).read())
elif args and args[0] == "capture-pane":
    pane = args[args.index("-t") + 1] if "-t" in args else ""
    p = os.path.join(SB, "screen-" + pane.replace("%", "") + ".txt")
    sys.stdout.write(open(p).read() if os.path.exists(p) else "")
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
            if lines[i].lstrip().startswith("\\u276f"):
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
import sys, json, os, time
DELAY=float(os.environ.get("RC_E2E_WORKER_DELAY_MS","0"))/1000.0
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
resumed=argv[argv.index("--resume")+1] if "--resume" in argv else ""
mine=os.environ.get("RC_E2E_FORK_ID","f0000000-0000-4000-8000-000000000001") if "--fork-session" in argv else resumed
print(json.dumps({"type":"system","subtype":"init","session_id":mine}),flush=True)
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: msg=json.loads(line)
    except Exception: continue
    if DELAY: time.sleep(DELAY)
    txt=msg.get("message",{}).get("content",[{}])[0].get("text","")
    print(json.dumps({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"echo:"+txt}]}}),flush=True)
    print(json.dumps({"type":"result","result":"echo:"+txt}),flush=True)
`);
chmodSync(fakeWork, 0o755);
const fakeAcct = join(SB, "fake-fleet-account");
writeFileSync(fakeAcct, "#!/bin/sh\necho account=testacct\n");
chmodSync(fakeAcct, 0o755);

// ★port は**カーネルに決めさせる**(2026-08-02 に変更)。旧: `8790 + random(0..99)`。
//
// 旧の形が作れた嘘: この 8790-8889 の範囲に**過去の走行が落とした孤児**が居座り得る。
// 実測 — pid 45236 が `T/mut-xsaw2j1a/rc/src/server.mjs` のまま **11時間33分** 8861 を
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
  check("history has user+assistant+tool", JSON.stringify(hist.history) ===
    JSON.stringify([
      { role: "user", text: "最初の質問" },
      { role: "assistant", text: "最初の答え" },
      { role: "tool", text: "⚙ Bash" },
    ]), JSON.stringify(hist.history));

  // 4. account
  const acct = await (await fetch(`${B}/api/account`, { headers: H })).json();
  check("account passthrough", acct.account === "account=testacct");

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

  // 11-g2. ★送信で鍵が満杯の最中の割り込みは 409。「押したのに止めていない」を 200 で返さない。
  //   出典: DESIGN §2.18-2。interrupt は送信と**同じ鍵**を取るので、満杯なら Escape は
  //   1本も出ない。そこで 200 を返すと電話には「止めた」と出るのに実際は止まっていない
  //   = 画面の見た目と機械の状態が食い違う。ここは 11-g の 409 とは別物で、あちらは
  //   「宛先が決まらない」、こちらは「宛先は決まったが今は押せない」。
  //
  //   ★鍵を埋める仕掛けは「tmux を遅くする」では作れない(2026-08-02、実測して作り替えた)。
  //   tmux は `execFileSync`(server.mjs:206)なので、capture を遅くすると **event loop ごと
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
  //   その直後に割り込みを撃てば、同じ満杯に当たる —— 断られた送信は `mutex.mjs:140` の
  //   `q.length >= maxWaiters` で **enqueue の前に** 弾かれるので行列を1つも消費せず、
  //   保持中の1本が echo 予算(RC_E2E_ECHO_BUDGET_MS)を使い切るまで満杯は崩れないから。
  //   ★循環していない: 割り込みが常に 200 を返す変異でも「どれかが pane-busy」は成立するので
  //   前提は緑のまま、下の本題だけが赤くなる(= W6 型の変異は捕まる)。逆に満杯が作れなければ
  //   前提の検査が赤になる。
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
    }
    if (process.env.RC_E2E_DEBUG_BUSY) {
      console.log(`  [busy try ${tries}] full=${JSON.stringify(jFull)} intr=${rBusy?.status} keys=${sentKeys().length - beforeBusy}`);
    }
    await drain(busySends);
  }
  // 前提そのものを測る。ここが赤なら、下の 409 は「鍵が満杯だったから」ではない。
  check("前提: 鍵が満杯(容量を超えた送信は 409 pane-busy = 積まない)",
    jFull !== null, `${tries}回作ろうとして満杯を観測できず`);
  check("★interrupt: 鍵が満杯の時は 409(200 で「止めた」と名乗らない)", rBusy?.status === 409, String(rBusy?.status));
  check("★interrupt: 理由は pane-busy / interrupted:false",
    jBusy?.reason === "pane-busy" && jBusy?.interrupted === false, JSON.stringify(jBusy));
  check("★interrupt: 断ったのだから Escape は1本も出ていない",
    !sentKeys().slice(beforeBusy).some((k) => k.at(-1) === "Escape"),
    JSON.stringify(sentKeys().slice(beforeBusy).filter((k) => k.at(-1) === "Escape")));

  // 11-h. 壊れた登録ファイルがあっても他の会話は生きる(1件で全体を落とさない)
  writeFileSync(join(PANE_DIR, `${SID_REG_B}.json`), '{"session_id":"aaaa');
  const jBroken = await (await fetch(`${B}/api/sessions/${SID_REG_A}/status`, { headers: H })).json();
  check("壊れた登録が1件あっても A は解決できる", jBroken.route === "tmux" && jBroken.pane === "%20", JSON.stringify(jBroken));
  register(SID_REG_B, "%21", 2000); // 後続に影響させない

  // ---- 12. 未発言の会話(jsonl がまだ無い) -----------------------------------
  // 出典: DESIGN §2.10。transcript は最初のメッセージまで作られないので、
  // 「開いて席を立った会話」は jsonl 走査の一覧に出ない = 電話から最初の一言を送れない。
  // Tom 裁定「返答待ちであれ作業中であれいつでも見て、干渉できればいい」に反するので通す。
  register(SID_FRESH, "%23", 3000);
  register(SID_GONE, "%90", 3000); // %90 は list-panes に存在しない

  const list4 = await (await fetch(`${B}/api/sessions`, { headers: H })).json();
  const fresh = list4.sessions.find((s) => s.id === SID_FRESH);
  check("★未発言の会話が一覧に出る", !!fresh, JSON.stringify(list4.sessions.map((s) => s.id)));
  check("★未発言: 中身が無いことを名乗る(捏造しない)",
    fresh?.title === "(未発言)" && fresh?.turns === 0 && fresh?.lastPrompt === "" && fresh?.fromRegistryOnly === true,
    JSON.stringify(fresh));
  check("★未発言: cwd はペインの現在地", fresh?.cwd === CWD_FRESH, JSON.stringify(fresh));
  check("★未発言: 一覧の live は tmux/%23", fresh?.live?.route === "tmux" && fresh?.live?.pane === "%23",
    JSON.stringify(fresh?.live));
  // ★陽性対照: ペインが消えた登録は一覧に出さない(叩いても送れない行を並べない)
  check("★陽性対照: ペインが消えた登録は一覧に出ない", !list4.sessions.some((s) => s.id === SID_GONE),
    JSON.stringify(list4.sessions.map((s) => s.id)));

  // 12-b. jsonl が無くても 404 にしない(履歴は空)
  const rHF = await fetch(`${B}/api/sessions/${SID_FRESH}/history`, { headers: H });
  const jHF = await rHF.json();
  check("★未発言: history は 404 でなく空配列", rHF.status === 200 && Array.isArray(jHF.history) && jHF.history.length === 0,
    `${rHF.status} ${JSON.stringify(jHF)}`);
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
      typeof b.message === "string" && !/現在地.*一致しません/.test(b.message), JSON.stringify(b.message));
    check("★pane-gone の説明が画面消失の事を言っている",
      /見つかりません|閉じられた/.test(String(b.message)), JSON.stringify(b.message));

    writeFileSync(join(SB, "tmux-panes.txt"), PANES); // 後続に影響させない
    ctl.abort();
    await pump;
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
    check("★その理由が日本語の一行で出る(ポートが埋まっている事+確かめ先)",
      /起動できません/.test(dupLog) && /二重/.test(dupLog), JSON.stringify(dupLog.slice(0, 300)));
    check("★陽性対照: 二重起動は listening を名乗らない", !dupLog.includes("listening"), dupLog.slice(0, 200));
    // 先に上がっている方は生きたまま = 後から来た方に道を譲らせない。
    check("★先に上がっている方は無傷", (await fetch(`${B}/api/sessions`, { headers: H })).ok);
  }

  sseCtl.abort();
  await ssePromise;

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
