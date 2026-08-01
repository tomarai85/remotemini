// ローカル E2E — 偽 claude-work と**偽 tmux** を注入してサーバの全経路を通す。
// 実 claude・実セッション・実 tmux に一切触れない。実行: node test/e2e-local.mjs
//
// 経路は3つ(DESIGN §2.9 / HANDOFF §1-A):
//   tmux 注入  = 机で開かれている会話。入力欄が実在する時だけ送る(生成中でも送れる)
//   ワーカー   = 開かれていない会話(-p --resume)
//   blocked    = 同じ cwd に claude が複数で特定不能 → どちらにも送らない
// 偽 tmux は send-keys を**全部ログに残す**ので「1文字も送っていない」を実測で言える。
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync, chmodSync, existsSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SB = mkdtempSync(join(tmpdir(), "rc-e2e-"));
const PROJ = join(SB, "projects", "-Users-Shared-dev-roundtrip");
mkdirSync(PROJ, { recursive: true });
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
const CWD_READY  = "/Users/Shared/dev/ready";
const CWD_CHOICE = "/Users/Shared/dev/choice";
const CWD_SHELL  = "/private/tmp";
const CWD_AMBIG  = "/Users/Shared/dev/ambig";
const CWD_GEN    = "/Users/Shared/dev/busy";
const CWD_DEAF   = "/Users/Shared/dev/deaf";
const CWD_RACE   = "/Users/Shared/dev/race";
// 登録簿(session_id -> pane)の検証用。**全部同じ cwd に置く** — 登録が無ければ
// 特定不能になる状況を作り、登録があれば1つに定まることを同じ場に並べて見せるため。
const SID_REG_A    = "aaaaaaaa-0000-0000-0000-00000000000a"; // 登録あり -> %20
const SID_REG_B    = "aaaaaaaa-0000-0000-0000-00000000000b"; // 登録あり -> %21
const SID_REG_C    = "aaaaaaaa-0000-0000-0000-00000000000c"; // 登録なし(他が名乗り済み)
const SID_STALE    = "aaaaaaaa-0000-0000-0000-00000000000d"; // %20 を古く名乗っている
const SID_MISMATCH = "aaaaaaaa-0000-0000-0000-00000000000e"; // 登録先ペインの居場所が違う
const CWD_REG   = "/Users/Shared/dev/reg";
const CWD_OTHER = "/Users/Shared/dev/other";
// 未登録のまま、その cwd に claude が**1つだけ**居る会話。cwd 一致を同定として使うと
// ここが注入されてしまう(= 他人の会話に本文が入る事故)。設計上ここは必ず拒否する。
const SID_UNREG = "aaaaaaaa-0000-0000-0000-000000000011";
const CWD_UNREG = "/Users/Shared/dev/unreg";
// 「開いただけでまだ一度も発言していない会話」= jsonl が存在しない(2026-07-31 edith 実測)。
// **わざと fixture を作らない** — それがこの状態の定義そのもの。
const SID_FRESH = "aaaaaaaa-0000-0000-0000-00000000000f"; // 登録あり・ペイン %23 が生きている
const SID_GONE  = "aaaaaaaa-0000-0000-0000-000000000010"; // 登録あり・そのペインはもう無い
const CWD_FRESH = "/Users/Shared/dev/fresh";

writeFileSync(join(PROJ, `${SID1}.jsonl`), [
  JSON.stringify({ entrypoint: "cli", cwd: "/Users/Shared/dev/roundtrip", type: "user", message: { role: "user", content: "最初の質問" } }),
  JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "最初の答え" }, { type: "tool_use", name: "Bash", input: {} }] } }),
  JSON.stringify({ type: "ai-title", aiTitle: "検証用の会話" }),
  JSON.stringify({ type: "last-prompt", lastPrompt: "最初の質問" }),
].join("\n"));
writeFileSync(join(PROJ, "22222222-2222-2222-2222-222222222222.jsonl"),
  JSON.stringify({ entrypoint: "sdk-cli", cwd: "/x", type: "user", message: { content: "noise" } }));
function fixture(sid, cwd, title) {
  writeFileSync(join(PROJ, `${sid}.jsonl`), [
    JSON.stringify({ entrypoint: "cli", cwd, type: "user", message: { role: "user", content: "q" } }),
    JSON.stringify({ type: "ai-title", aiTitle: title }),
  ].join("\n"));
}
fixture(SID_READY, CWD_READY, "注入READY");
fixture(SID_CHOICE, CWD_CHOICE, "注入CHOICE");
fixture(SID_SHELL, CWD_SHELL, "シェルのみ");
fixture(SID_AMBIG, CWD_AMBIG, "特定不能");
fixture(SID_GEN, CWD_GEN, "生成中");
fixture(SID_DEAF, CWD_DEAF, "画面が動かない");
fixture(SID_RACE, CWD_RACE, "選択画面が割り込む");
for (const sid of [SID_REG_A, SID_REG_B, SID_REG_C, SID_STALE]) fixture(sid, CWD_REG, `登録${sid.slice(-1)}`);
fixture(SID_UNREG, CWD_UNREG, "未登録");
fixture(SID_MISMATCH, CWD_REG, "居場所不一致"); // 会話は CWD_REG。登録先ペインは CWD_OTHER に居る

// ---- 偽 tmux ----------------------------------------------------------------
// 実物の観測に合わせてある(2026-07-31 edith):
//   list-panes -F "#{pane_id}\t#{pane_current_command}\t#{pane_tty}\t#{pane_current_path}"
//   → 対話 claude の command は "2.1.220"(バージョン文字列)、素のシェルは "zsh"
const PANES = [
  `%10\t2.1.220\t/dev/ttys010\t${CWD_READY}`,
  `%11\t2.1.220\t/dev/ttys011\t${CWD_CHOICE}`,
  `%12\tzsh\t/dev/ttys012\t${CWD_SHELL}`,
  `%13\t2.1.220\t/dev/ttys013\t${CWD_AMBIG}`,
  `%14\t2.1.220\t/dev/ttys014\t${CWD_AMBIG}`, // 同じ cwd に2つめ
  `%15\t2.1.220\t/dev/ttys015\t${CWD_GEN}`,
  `%16\t2.1.220\t/dev/ttys016\t${CWD_DEAF}`,  // 送っても画面が動かない(load-bearing: Enter を出さない対照)
  `%17\t2.1.220\t/dev/ttys017\t${CWD_RACE}`,  // 本文の直後に選択画面が出る
  `%20\t2.1.220\t/dev/ttys020\t${CWD_REG}`,   // 登録簿検証: 同じ cwd に claude が3つ並ぶ
  `%21\t2.1.220\t/dev/ttys021\t${CWD_REG}`,
  `%22\t2.1.220\t/dev/ttys022\t${CWD_OTHER}`, // 居場所不一致の検証用
  `%23\t2.1.220\t/dev/ttys023\t${CWD_FRESH}`, // 未発言の会話が居るペイン(jsonl は無い)
  `%24\t2.1.220\t/dev/ttys024\t${CWD_UNREG}`, // 未登録の会話の cwd に居る唯一の claude
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
  // ★生成中だがスピナーが**写っていない**枚(実測 M3: 生成中の 69% はこれ)。
  //   ここが SENDABLE でなくなると reason が composer-mismatch でなく unknown になるので、
  //   下の 10-e2 が「スピナーの有無で送信を止めていないか」の回帰検査も兼ねる。
  //   加えて偽 tmux はこのペインだけ画面を更新しない = 本文が載らないペインの再現。
  "%16": shot("generating"),
  // ★本文を送った**直後に**選択画面が割り込むペイン(偽 tmux が %17 だけそう振る舞う)。
  //   分類 → 本文 → Enter の間に modal が出ると Enter が承認/課金になる、という競合の再現。
  "%17": shot("idle-boot"),
  "%20": shot("idle-boot"),
  "%21": shot("idle-boot"),
  "%22": shot("idle-boot"),
  "%23": shot("idle-boot"),
  "%24": shot("idle-boot"),
};
writeFileSync(join(SB, "tmux-panes.txt"), PANES);
for (const [pane, text] of Object.entries(SCREENS)) {
  writeFileSync(join(SB, `screen-${pane.replace("%", "")}.txt`), text);
}
// %17 が本文受信後に化ける先(偽 tmux が読む)
writeFileSync(join(SB, "screen-choice.txt"), shot("choice-model-menu"));

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
for (const [sid, pane] of [[SID_READY, "%10"], [SID_CHOICE, "%11"], [SID_GEN, "%15"], [SID_DEAF, "%16"], [SID_RACE, "%17"]]) {
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
sys.exit(0)
`);
chmodSync(fakeTmux, 0o755);
/** これまでに偽 tmux が受け取った send-keys の一覧 */
function sentKeys() {
  if (!existsSync(SENT_LOG)) return [];
  return readFileSync(SENT_LOG, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
}

const fakeWork = join(SB, "fake-claude-work");
// RC_E2E_WORKER_DELAY_MS = 応答を意図的に遅らせる栓。既定 0。
// これは対照実験用: 遅延を入れても緑のままなら「待ち方」が直っている証拠になる。
writeFileSync(fakeWork, `#!/usr/bin/env python3
import sys, json, os, time
DELAY=float(os.environ.get("RC_E2E_WORKER_DELAY_MS","0"))/1000.0
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

const PORT = 8790 + Math.floor(Math.random() * 100);
const sv = spawn(process.execPath, [join(ROOT, "src", "server.mjs")], {
  env: {
    ...process.env,
    RC_PROJECTS_DIR: join(SB, "projects"),
    RC_CLAUDE_WORK: fakeWork,
    RC_FLEET_ACCOUNT: fakeAcct,
    RC_KEY_DIR: join(SB, "keys"),
    RC_PORT: String(PORT),
    RC_TMUX_BIN: fakeTmux,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let svlog = "";
sv.stdout.on("data", (c) => (svlog += c));
sv.stderr.on("data", (c) => (svlog += c));

const B = `http://127.0.0.1:${PORT}`;
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
  // サーバ起動待ち
  let up = false;
  for (let i = 0; i < 50 && !up; i++) { await sleep(100); up = svlog.includes("listening"); }
  if (!up) throw new Error(`server did not start:\n${svlog}`);
  const KEY = readFileSync(join(SB, "keys", "api.key"), "utf8").trim();
  const H = { authorization: `Bearer ${KEY}` };

  // 1. 認証
  check("401 without key", (await fetch(`${B}/api/sessions`)).status === 401);
  check("401 with wrong key", (await fetch(`${B}/api/sessions`, { headers: { authorization: "Bearer nope" } })).status === 401);

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
  check("★zsh だけの cwd -> 注入しない(ワーカー経路)", jShell.route === "worker", JSON.stringify(jShell));
  check("★zsh ペインへは send-keys が0件", sentKeys().length === beforeShell);

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

  sseCtl.abort();
  await ssePromise;
} finally {
  sv.kill("SIGTERM");
}
console.log(`\nE2E: pass=${pass} fail=${fail}`);
process.exit(fail === 0 ? 0 : 1);
