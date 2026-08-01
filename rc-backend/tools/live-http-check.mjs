#!/usr/bin/env node
/**
 * HTTP 面(server.mjs)を**本物の Claude Code TUI 相手に**端から端まで1周させる。
 *
 * なぜ要るか: 単体も e2e も偽 tmux 相手で、`server.mjs` が実機で通った事は一度も無い。
 *   注入層(`inject.mjs`)だけは 8/01 に実機で通したが、その上の HTTP 面
 *   (一覧 → 履歴 → 送信 → ストリーム → 割り込み)は電話が実際に叩く経路そのものなのに未駆動。
 *
 * ★この台本は「合格を出す」より「**何が起きるかを測る**」道具として書いてある。
 *   特に `/stream` は、tmux 経路のセッションに対して**何も流れない可能性が高い**
 *   (`pushToSubscribers` の呼び出しが worker 経路の1箇所だけ = server.mjs:461)。
 *   そこを「仕様です」と断定せず、**実測して数字で残す**。
 *
 * 約束(崩さない事):
 *   - 使い捨てセッション名 `rc-e2e-<数字6桁以上>` しか作らない。Tom の実セッションに触る道が無い。
 *   - サーバは **127.0.0.1 固定**。この台本から `RC_BIND` を外に向ける経路を持たない。
 *   - 選択画面(CHOICE)には何も送らない。Enter を送るのは入力欄がある時の本文送信だけ。
 *   - 片付けはサーバ・tmux とも `finally` で必ず走らせ、**不在を確認**してから終わる。
 *   - 写しと証拠は repo の外($TMPDIR)。起動バナーにアカウントのメールが載る。
 *
 * 使い方: node tools/live-http-check.mjs [--cwd DIR] [--bin "claude"] [--probe "本文"] [--no-send]
 * 終了コード: 0 = 全項目 OK / 1 = どれかが NG / 2 = 準備段で中断
 */
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { TmuxInjector, classifyScreen } from "../src/inject.mjs";

const HOME = homedir();
const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const TMUX_BIN =
  process.env.RC_TMUX_BIN ||
  (existsSync("/opt/homebrew/bin/tmux") ? "/opt/homebrew/bin/tmux" : "tmux");
const PANE_DIR = process.env.RC_PANE_DIR || join(HOME, ".rc-backend", "panes");
const KEY_FILE = join(process.env.RC_KEY_DIR || join(HOME, ".rc-backend"), "api.key");

const tmux = (args) => execFileSync(TMUX_BIN, args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
const tmuxOk = (args) => {
  try {
    tmux(args);
    return true;
  } catch {
    return false;
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const out = {
    cwd: HOME,
    bin: "claude",
    port: 8790 + (process.pid % 200), // 既定 8787 とぶつけない。127.0.0.1 のみ。
    probe: "1+1 は? 数字だけ答えて。",
    send: true,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cwd") out.cwd = argv[++i];
    else if (a === "--bin") out.bin = argv[++i];
    else if (a === "--port") out.port = Number(argv[++i]);
    else if (a === "--probe") out.probe = argv[++i];
    else if (a === "--no-send") out.send = false;
    else throw new Error(`知らない引数: ${a}`);
  }
  return out;
}

/** 素の http で叩く(依存を増やさない。fetch でもよいが SSE で結局 http を使うので揃える)。 */
function api(port, key, method, path, body) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        method,
        path,
        headers: {
          ...(key ? { authorization: `Bearer ${key}` } : {}),
          ...(payload ? { "content-type": "application/json", "content-length": payload.length } : {}),
        },
      },
      (res) => {
        let buf = "";
        res.setEncoding("utf8");
        res.on("data", (c) => (buf += c));
        res.on("end", () => {
          let json = null;
          try {
            json = JSON.parse(buf);
          } catch {
            /* HTML など */
          }
          resolve({ status: res.statusCode, body: buf, json });
        });
      },
    );
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

/** SSE を開いて、届いた物に時刻を付けて溜める。閉じるのは呼び手。 */
function openStream(port, key, sessionId) {
  const events = [];
  const t0 = Date.now();
  const req = httpRequest(
    {
      host: "127.0.0.1",
      port,
      method: "GET",
      path: `/api/sessions/${sessionId}/stream?since=0`,
      headers: { authorization: `Bearer ${key}`, accept: "text/event-stream" },
    },
    (res) => {
      res.setEncoding("utf8");
      res.on("data", (chunk) => {
        for (const raw of chunk.split("\n\n")) {
          const line = raw.trim();
          if (!line) continue;
          events.push({ atMs: Date.now() - t0, raw: line, ping: line.startsWith(": ping") });
        }
      });
    },
  );
  req.on("error", () => {});
  req.end();
  return { events, close: () => req.destroy(), status: () => events };
}

async function waitFor(fn, budgetMs, everyMs = 400) {
  const t0 = Date.now();
  for (;;) {
    const v = await fn();
    if (v) return { ok: true, v, waited: Date.now() - t0 };
    if (Date.now() - t0 >= budgetMs) return { ok: false, v, waited: Date.now() - t0 };
    await sleep(everyMs);
  }
}

const readPanes = () => {
  try {
    return readdirSync(PANE_DIR).filter((f) => f.endsWith(".json"));
  } catch {
    return [];
  }
};

let failed = false;
const results = [];
const check = (name, ok, detail) => {
  console.log(`${ok ? "OK " : "NG "} ${name}(${detail})`);
  results.push({ name, ok, detail });
  if (!ok) failed = true;
};
const note = (name, detail) => {
  console.log(`--  ${name}: ${detail}`);
  results.push({ name, ok: null, detail });
};

async function main() {
  const opt = parseArgs(process.argv.slice(2));
  const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 14);
  const session = `rc-e2e-${stamp}`;
  if (!/^rc-e2e-[0-9]{6,}$/.test(session)) {
    console.error(`使い捨てのセッション名ではない: ${session}`);
    return (failed = true);
  }
  if (tmuxOk(["has-session", "-t", `=${session}`])) {
    console.error(`同名のセッションが既に在る: ${session}。触らずに止める。`);
    return (failed = true);
  }
  const outDir = join(tmpdir(), `rc-http-${stamp}`);
  if (outDir.includes("/mobile-work/")) {
    console.error(`証拠の置き場が repo の中: ${outDir}`);
    return (failed = true);
  }
  mkdirSync(outDir, { recursive: true });

  console.log(`tmux      : ${tmux(["-V"]).trim()}`);
  console.log(`セッション: ${session}(使い捨て)`);
  console.log(`サーバ    : 127.0.0.1:${opt.port}(この台本は外向き bind を持たない)`);
  console.log(`証拠      : ${outDir}\n`);

  let server = null;
  let stream = null;
  let sessionId = null;

  try {
    // --- 1. 使い捨ての本物 TUI を建てる ---------------------------------------
    const before = new Set(readPanes());
    tmux(["new-session", "-d", "-s", session, "-x", "120", "-y", "40", "-c", opt.cwd]);
    const pane = tmux(["list-panes", "-t", `=${session}`, "-F", "#{pane_id}"]).trim().split("\n")[0];
    const injector = new TmuxInjector({ tmux: { run: tmux }, echoBudgetMs: 8000 });
    tmux(["send-keys", "-t", pane, "-l", "--", opt.bin]);
    tmux(["send-keys", "-t", pane, "Enter"]);

    const boot = await waitFor(async () => {
      const t = injector.capture(pane);
      return classifyScreen(t).state === "SENDABLE" ? t : null;
    }, 90_000);
    writeFileSync(join(outDir, "00-boot.txt"), boot.v || injector.capture(pane));
    if (!boot.ok) {
      console.error("起動 90 秒で入力欄が出ない。上限や信頼確認の可能性。Enter は押さない。");
      return (failed = true);
    }
    console.log(`起動 ok(${boot.waited}ms)`);

    // --- 2. 登録簿に自分で名乗るまで待つ(statusLine が書く) ------------------
    const reg = await waitFor(async () => {
      for (const f of readPanes()) {
        if (before.has(f)) continue;
        try {
          const j = JSON.parse(readFileSync(join(PANE_DIR, f), "utf8"));
          if (j.pane === pane) return { id: f.replace(/\.json$/, ""), entry: j };
        } catch {
          /* 書き込み途中 */
        }
      }
      return null;
    }, 30_000);
    check("登録簿に名乗る", reg.ok, reg.ok ? `${reg.v.id}(${reg.waited}ms)` : "30秒で新しい登録が出ない");
    if (!reg.ok) return;
    sessionId = reg.v.id;
    writeFileSync(join(outDir, "01-registry.json"), JSON.stringify(reg.v.entry, null, 2));

    // --- 3. サーバを 127.0.0.1 で起こす ---------------------------------------
    server = spawn(process.execPath, [join(ROOT, "src", "server.mjs")], {
      env: { ...process.env, RC_BIND: "127.0.0.1", RC_PORT: String(opt.port) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const serverLog = [];
    server.stdout.on("data", (d) => serverLog.push(String(d)));
    server.stderr.on("data", (d) => serverLog.push(String(d)));

    const up = await waitFor(async () => {
      try {
        const r = await api(opt.port, null, "GET", "/");
        return r.status ? r : null;
      } catch {
        return null;
      }
    }, 15_000, 300);
    check("サーバが起きる", up.ok, up.ok ? `GET / -> ${up.v.status}(${up.waited}ms)` : "15秒で応答しない");
    if (!up.ok) return;

    const key = readFileSync(KEY_FILE, "utf8").trim();

    // --- 4. 認証 ---------------------------------------------------------------
    const noAuth = await api(opt.port, null, "GET", "/api/sessions");
    check("鍵無しは 401", noAuth.status === 401, `status=${noAuth.status}`);

    // --- 5. 一覧に自分が出るか -------------------------------------------------
    const list = await api(opt.port, key, "GET", "/api/sessions");
    const mine = (list.json?.sessions || []).find((s) => s.id === sessionId);
    check("一覧が返る", list.status === 200, `status=${list.status} 件数=${(list.json?.sessions || []).length}`);
    check("一覧に自分が出る", !!mine, mine ? `route=${mine.live?.route} screen=${mine.live?.screen}` : "見つからない");
    check(
      "経路が tmux(注入側)",
      mine?.live?.route === "tmux",
      `route=${mine?.live?.route} source=${mine?.live?.source}`,
    );
    writeFileSync(join(outDir, "02-sessions.json"), JSON.stringify(list.json, null, 2));

    // --- 6. status / history --------------------------------------------------
    const st = await api(opt.port, key, "GET", `/api/sessions/${sessionId}/status`);
    check("status が画面から取れる", st.status === 200 && st.json?.route === "tmux", `${st.status} ${JSON.stringify(st.json?.screen ?? st.json?.route)}`);
    const h0 = await api(opt.port, key, "GET", `/api/sessions/${sessionId}/history?limit=30`);
    check("history が返る", h0.status === 200 && Array.isArray(h0.json?.history), `件数=${h0.json?.history?.length}`);

    // --- 7. ストリームを開いてから送る ----------------------------------------
    stream = openStream(opt.port, key, sessionId);
    await sleep(600);

    if (!opt.send) {
      note("送信", "--no-send のため省略");
    } else {
      const t0 = Date.now();
      const sent = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/messages`, { text: opt.probe });
      check(
        "送信が 202 で通る",
        sent.status === 202 && sent.json?.accepted === true,
        `status=${sent.status} route=${sent.json?.route} delivered=${sent.json?.delivered}`,
      );
      check("届いた事を verified で返す", sent.json?.delivered === "verified", `delivered=${sent.json?.delivered}`);

      // 画面に本文が入ったか(HTTP の言い分でなく tmux の実物で見る)
      const seen = await waitFor(async () => injector.capture(pane).includes(opt.probe.slice(0, 8)) || null, 8000);
      note("画面に本文が見えるか", seen.ok ? `見えた(${seen.waited}ms)` : "8秒では見えず(取り込み済みで消えた可能性)");

      // 返答が history に反映されるまでの時間を**測る**
      const replied = await waitFor(async () => {
        const h = await api(opt.port, key, "GET", `/api/sessions/${sessionId}/history?limit=30`);
        const arr = h.json?.history || [];
        return arr.some((m) => m.role === "assistant") ? arr : null;
      }, 90_000, 1500);
      check("返答が history に出る", replied.ok, replied.ok ? `${replied.waited}ms で反映` : "90秒で assistant が出ない");
      if (replied.ok) {
        writeFileSync(join(outDir, "03-history.json"), JSON.stringify(replied.v, null, 2));
      }

      // ★ここが本題: tmux 経路で SSE に中身が流れるか。
      // 初回(8/02)は **0 件** = 電話側は送信後ずっと無音だった。tail 配信を入れた後は
      // message が流れる。数えるだけでは退行に気付けないので、種類ごとに検査する。
      // tail の poll は 700ms 間隔なので、history に出た直後にはまだ流れていない事がある。
      // 「今この瞬間に無い」を「来ない」と読み替えない — 予算を決めて待ってから判定する。
      const gotMsg = await waitFor(
        async () => stream.events.some((e) => e.raw.includes("event: message")) || null,
        8000,
        300,
      );
      const real = stream.events.filter((e) => !e.ping);
      const kind = (name) => real.filter((e) => e.raw.includes(`event: ${name}`));
      note("SSE の message を待った時間", gotMsg.ok ? `${gotMsg.waited}ms で到着` : "8秒待って到着せず");
      note(
        "SSE の内訳",
        `${Date.now() - t0}ms で 実 ${real.length} 件(message ${kind("message").length} / screen ${kind("screen").length} / gap ${kind("gap").length})`,
      );
      check(
        "★返答が SSE の message で届く",
        kind("message").length > 0,
        `message ${kind("message").length} 件`,
      );
      // gap は2種類あり、意味が正反対なので混ぜない。
      //   epoch-mismatch = 初回購読を壊れた再開と読み違えた欠陥(8/02 に潰した)。出たら NG。
      //   tail-attached  = 履歴を撮った後に jsonl が生まれた時の**正直な**継ぎ目。出てよい。
      const gaps = kind("gap").map((e) => (/"why":"([^"]+)"/.exec(e.raw) || [, "?"])[1]);
      check(
        "初回の購読を壊れた再開として扱わない(since=0)",
        !gaps.includes("epoch-mismatch"),
        `gap の内訳=[${gaps.join(",")}]`,
      );
      const screens = kind("screen").map((e) => {
        const m = /data: (.*)$/m.exec(e.raw);
        try {
          return JSON.parse(m[1]);
        } catch {
          return {};
        }
      });
      check(
        "画面イベントが1枚ごとの明滅で溢れない",
        screens.length <= 4,
        `screen ${screens.length} 件 / work=${[...new Set(screens.map((s) => s.work))].join(",")}`,
      );
      writeFileSync(join(outDir, "04-sse.json"), JSON.stringify(stream.events, null, 2));
    }

    // --- 8. 割り込み -----------------------------------------------------------
    const intr = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/interrupt`);
    check("interrupt が通る", intr.status === 200 && intr.json?.interrupted === true, `status=${intr.status} route=${intr.json?.route}`);

    // --- 9. 知らない相手には触らない ------------------------------------------
    const unknown = await api(opt.port, key, "GET", `/api/sessions/00000000-0000-0000-0000-000000000000/status`);
    check("知らない session は 404", unknown.status === 404, `status=${unknown.status}`);

    writeFileSync(join(outDir, "09-server.log"), serverLog.join(""));
  } catch (e) {
    console.log(`★落ちた: ${e.stack || e.message}`);
    failed = true;
  } finally {
    try {
      stream?.close();
    } catch {
      /* ignore */
    }
    if (server) {
      server.kill("SIGTERM");
      await sleep(700);
      if (server.exitCode === null && server.signalCode === null) server.kill("SIGKILL");
      console.log(`片付け: サーバ pid=${server.pid} -> exit=${server.exitCode} sig=${server.signalCode}`);
    }
    tmuxOk(["kill-session", "-t", `=${session}`]);
    const gone = !tmuxOk(["has-session", "-t", `=${session}`]);
    console.log(`片付け: ${session} は ${gone ? "不在を確認" : "★まだ在る"}`);
    if (!gone) failed = true;
    console.log(`結果: ${results.filter((r) => r.ok === true).length} OK / ${results.filter((r) => r.ok === false).length} NG / 実測メモ ${results.filter((r) => r.ok === null).length} 件`);
    if (sessionId) console.log(`使い捨て会話の session_id: ${sessionId}(jsonl は ~/.claude/projects/ に残る)`);
  }
}

// 終了コードは main の外で決める(try の中の return は finally を通って main を抜けるので、
// main の中に置いた process.exit には届かない = 8/01 に live-choice-check.mjs で踏んだ穴)。
main().then(() => process.exit(failed ? 1 : 0));
