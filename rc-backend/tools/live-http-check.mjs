#!/usr/bin/env node
// no-control: 実機計器。生きた Claude Code と server が要り、commit 時には回せない
/**
 * HTTP 面(server.mjs)を**本物の Claude Code TUI 相手に**端から端まで1周させる。
 *
 * なぜ要るか: 単体も e2e も偽 tmux 相手で、`server.mjs` が実機で通った事は一度も無い。
 *   注入層(`inject.mjs`)だけは 8/01 に実機で通したが、その上の HTTP 面
 *   (一覧 → 履歴 → 送信 → ストリーム → 割り込み)は電話が実際に叩く経路そのものなのに未駆動。
 *
 * ★この台本は「合格を出す」より「**何が起きるかを測る**」道具として書いてある。
 *   当初ここには「`/stream` は tmux 経路に**何も流れない可能性が高い**」と書いてあった
 *   (`pushToSubscribers` の呼び出しが worker 経路の1箇所だけ、という読みから)。
 *   **実測でこの予想は外れた**(2026-08-02 edith): tail 配信を入れた後は message が 0ms で
 *   1件届く。予想を残したままにすると次の読み手が「流れないのが仕様」と受け取るので消す。
 *   数字は下の SSE の内訳を見る事。
 *
 * 約束(崩さない事):
 *   - 使い捨てセッション名 `rc-e2e-<数字6桁以上>` しか作らない。Tom の実セッションに触る道が無い。
 *   - サーバは **127.0.0.1 固定**。この台本から `RC_BIND` を外に向ける経路を持たない。
 *   - 選択画面(CHOICE)には何も送らない。Enter を送るのは入力欄がある時の本文送信だけ。
 *   - 片付けはサーバ・tmux とも `finally` で必ず走らせ、**不在を確認**してから終わる。
 *   - 写しと証拠は repo の外($TMPDIR)。起動バナーにアカウントのメールが載る。
 *
 * 使い方: node tools/live-http-check.mjs [--cwd DIR] [--bin rc-claude] [--probe "本文"] [--no-send]
 *   ★`--bin` の既定は `rc-claude`。素の `claude` は statusLine を持たない = 登録簿に名乗らないので、
 *     この台本の 2 番目の検査が構造的に通らない。指定した場合は準備段で名指しで止める。
 * 終了コード: 0 = 全項目 OK / 1 = どれかが NG / 2 = 準備段で中断(2026-08-02 まで未実装だった)
 *            **3 = 運ぶ層は通ったが、相手が答えていない**(利用上限)
 *   2 に入る物(= **何も測れていない**回。1 と混ぜない): 実行ファイルが無い / 登録の仕組みが無い /
 *   建てる場所が未信頼 / 起動画面が信頼確認で止まる / 起動画面が上限の告知。
 *   1 は「建って、測って、どれかが赤かった」時だけ。2 と 1 の差は「直す物が在るか」。
 *
 * ★2026-08-02、この台本自身に踏まれて 3 を足した。edith で 16 OK / 0 NG / exit 0 が出た回の
 *   `03-history.json` の assistant 本文が `You've hit your weekly limit · resets 12am` だった。
 *   検査対象は運ぶ層なので緑自体は嘘ではない。だが「16 OK」は「一巡した」と読まれる。
 *   同じ機械を同じ時刻に測った `live-inject-check.mjs` は exit 3 を出していたので、
 *   **二つの計器が同じ機械について逆の事を言う**状態になっていた。読まれ方まで計器の責任。
 */
import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, unlinkSync, writeFileSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  TmuxInjector,
  makeTmuxRunner,
  classifyScreen,
  limitNoticeIn,
  inFlightHintIn,
  tmuxChildEnv,
  COMPOSER_PLACEHOLDER,
} from "../src/inject.mjs";
import { exitCodeFor } from "./exit-codes.mjs";

const HOME = homedir();
const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const TMUX_BIN =
  process.env.RC_TMUX_BIN ||
  (existsSync("/opt/homebrew/bin/tmux") ? "/opt/homebrew/bin/tmux" : "tmux");

/**
 * 注入層に渡すランナー。**`makeTmuxRunner` を経由する**のが要点で、こうすると
 * `run`(飲む)と `runStrict`(投げる)の両方が揃う。一覧は runStrict を通るので、
 * ここを裸の `{ run: tmux }` に戻すと構築の時点で落ちる(= M84 が塞いだ穴)。
 * `quiet:false` は今までと同じ意味(この道具では tmux の失敗はそのまま失敗)。
 */
const injectorRunner = () => makeTmuxRunner({
  tmuxBin: TMUX_BIN,
  exec: (bin, args, opts) => execFileSync(bin, args, { ...opts, maxBuffer: 8 * 1024 * 1024 }),
  quiet: false,
});
const PANE_DIR = process.env.RC_PANE_DIR || join(HOME, ".rc-backend", "panes");
const HEADS_DIR = join(process.env.RC_KEY_DIR || join(HOME, ".rc-backend"), "heads");
const KEY_FILE = join(process.env.RC_KEY_DIR || join(HOME, ".rc-backend"), "api.key");

/**
 * `pgrep -f <針>` に一致した**数だけ**を返す。行そのものは持ち出さない ——
 * `-f` は argv と環境変数を丸ごと吐くので、印字すると鍵や token が紛れる
 * (この艦隊で実際に一度、無関係の `pgrep -lf` が OAuth の secret を印字した)。
 * 数える用途に限れば安全に使える。
 */
const procsMatching = (needle) => {
  try {
    return execFileSync("/usr/bin/pgrep", ["-f", needle], { encoding: "utf8" })
      .trim()
      .split("\n")
      .filter(Boolean).length;
  } catch {
    return 0; // pgrep は一致 0 件で exit 1
  }
};

// ★locale を明示する理由は inject.mjs の PANE_FORMAT 注記(タブが `_` に潰れる)。
const tmux = (args) =>
  execFileSync(TMUX_BIN, args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024, env: tmuxChildEnv() });
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
    // ★既定は `rc-claude`(素の `claude` ではない)。2026-08-02 に実測して直した。
    //   素の `claude` で起動した会話は **statusLine を持たない** = 登録簿に何も書かない。
    //   この台本の 2 番目の検査は「登録簿に名乗る」なので、既定のままでは
    //   **どう転んでも通らない設定**だった(実際 30 秒待って NG になった)。
    //   通らない既定を持つ検査は、赤が出た時に「本当に壊れた」のか
    //   「元から通らない設定だった」のか区別できない = 計器として死んでいる。
    bin: "rc-claude",
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
    // ★期限が無いと、吊った時に waitFor の予算そのものが効かない(waitFor は fn を
    //   await するので、fn が永遠に待つと輪が回らない)。§2.20-a L2。
    req.setTimeout(30_000, () => {
      req.destroy(new Error(`応答が 30 秒返らない: ${method} ${path}`));
    });
    if (payload) req.write(payload);
    req.end();
  });
}

/** SSE を開いて、届いた物に時刻を付けて溜める。閉じるのは呼び手。 */
/**
 * 送信後、**電話が返答に到達できるか**。到達路は2本あり、どちらも設計通り。
 *
 *   message … tail が既に繋がっていて、返答の行がそのまま流れてきた
 *   reread  … 返答が tail の接続より先に着いた回。`server.mjs` の tail は初回に
 *             **末尾へ位置合わせして過去分を流さない**ので、代わりに
 *             `gap{rereadHistory:true}` を投げ、電話に `/history` を読み直させる
 *
 * 判定をここに切り出してあるのは、**陰性対照を当てられる形にする**ため
 * (`test/reply-route.test.mjs`)。「どちらか通ればよい」に緩めた検査が、
 * 本当の壊れ方(= 何も流れず電話が永久に無音)でまだ赤くなるかは、
 * 読んで納得するのではなく撃って確かめる。
 *
 * @returns "message" | "reread" | "none"
 */
export function replyRoute({ assistantMessages = 0, rereadGaps = 0, replyInHistoryAfterGap = false } = {}) {
  if (assistantMessages > 0) return "message";
  if (rereadGaps > 0 && replyInHistoryAfterGap) return "reread";
  return "none";
}

function openStream(port, key, sessionId) {
  /** 握り潰さずに溜める。0 件である事自体も検査の detail に出す(§2.20-a L3)。 */
  const errors = [];
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
      // ★枠は TCP のチャンク境界を跨ぐ。チャンクごとに split すると跨いだ枠が消える
      //   (2026-08-03 §2.20-a L1)。緩衝は **この閉包の中**に置く — 外に出すと
      //   開き直した時に前の残骸が混ざる。
      let buf = "";
      res.on("data", (chunk) => {
        buf += chunk;
        let i;
        while ((i = buf.indexOf("\n\n")) >= 0) {
          const line = buf.slice(0, i).trim();
          buf = buf.slice(i + 2);
          if (!line) continue;
          events.push({ atMs: Date.now() - t0, raw: line, ping: line.startsWith(": ping") });
        }
      });
    },
  );
  // ★60 秒。server は 25 秒ごとに `: ping` を書く(`src/server.mjs` の `: ping` と `25_000`)ので、
  //   60 秒の無音は「暇」ではなく**死**。api() と同じ 30 秒にすると余裕が 5 秒しか
  //   無く偽陽性になる。§2.20-a L2。
  req.setTimeout(60_000, () => {
    errors.push("60 秒 無音(25 秒ごとの ping すら来ない = 繋がっているつもりで死んでいる)");
    req.destroy();
  });
  // ★飲まない。飲んだ理由は検査の detail に出す(§2.20-a L3)。
  req.on("error", (e) => errors.push(String(e?.message || e)));
  req.end();
  return { events, errors, close: () => req.destroy(), status: () => events };
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

/**
 * 飲んだ理由を溜める。**握り潰しを 0 にするのが目的ではない**(§2.20-a-ii)。
 * 出すのは「読めなかった」が「無い」に化ける口だけ。残り 8 箇所は飲むのが正しい。
 */
const swallowed = [];
const swallow = (where, e) => swallowed.push(`${where}: ${String(e?.message || e)}`);

const readPanes = () => {
  try {
    return readdirSync(PANE_DIR).filter((f) => f.endsWith(".json"));
  } catch (e) {
    // 読めない dir を「登録が1件も無い」に化かさない。
    swallow("ペイン登録簿の dir", e);
    return [];
  }
};

let failed = false;
// ★冒頭の「2 = 準備段で中断」は、2026-08-02 まで**どこにも実装が無かった**(0/1 しか出ない)。
//   準備段の中断(登録の仕組みが無い等)と、検査そのものの赤は、読み手の次の手が違う。
let prepAbort = false;
// ★配達は成立したのに相手が答えていない(利用上限)。壊れている(1)とは別の出口 = 3。
//   live-inject-check.mjs が先に踏んだ穴と同じ約束に揃える。
let limitedReply = false;
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
    return (prepAbort = true);
  }
  if (tmuxOk(["has-session", "-t", `=${session}`])) {
    console.error(`同名のセッションが既に在る: ${session}。触らずに止める。`);
    return (prepAbort = true);
  }
  const outDir = join(tmpdir(), `rc-http-${stamp}`);
  if (outDir.includes("/mobile-work/")) {
    console.error(`証拠の置き場が repo の中: ${outDir}`);
    return (prepAbort = true);
  }
  mkdirSync(outDir, { recursive: true });

  // --- 登録の仕組みが在るかを、TUI を建てる**前に**確かめる -------------------
  // ★「30 秒待っても登録が出ない」は、人が次に取る手の違う二つの状態を1文に潰していた:
  //     (a) 登録する仕組みがそもそも起動していない(statusLine を持たない `claude` で建てた)
  //     (b) 仕組みは在るのに書けていない(登録スクリプトの不具合・権限・パス)
  //   (a) を**ここで名指しで**落とす。そうすると step 2 の時間切れは (b) だけを意味する。
  //   2026-08-02: 既定が素の `claude` だったので、この台本は (a) を (b) の顔で報告していた。
  const binPath = opt.bin.includes("/")
    ? (existsSync(opt.bin) ? opt.bin : "")
    : (() => {
        try {
          return execFileSync("/usr/bin/env", ["sh", "-c", `command -v ${JSON.stringify(opt.bin)}`],
            { encoding: "utf8" }).trim();
        } catch {
          return "";
        }
      })();
  if (!binPath) {
    console.error(`起動に使う実行ファイルが見つからない: ${opt.bin}`);
    console.error(`  次の手: rc-claude は ~/.claude/tools/rc-claude(edith へは .claude-sync 経由)。`);
    console.error(`          PATH に無ければ --bin に絶対パスを渡す。`);
    return (prepAbort = true);
  }
  // 登録簿に書けるのは「statusLine を持つ会話」だけ。経路は2つ。
  const viaWrapper = /(^|\/)rc-claude$/.test(binPath);
  const viaSettings = (() => {
    try {
      return !!JSON.parse(readFileSync(join(HOME, ".claude", "settings.json"), "utf8")).statusLine;
    } catch (e) {
      // 読めない設定を「登録の仕組みが無い」と画面に出さない(直下の console.error)。
      swallow("~/.claude/settings.json", e);
      return false;
    }
  })();
  if (!viaWrapper && !viaSettings) {
    console.error(`登録の仕組みが無い状態で建てようとしている(この設定では step 2 は必ず落ちる)`);
    console.error(`  使う実行ファイル : ${binPath}`);
    console.error(`  statusLine の経路: ラッパ=無 / ~/.claude/settings.json=無`);
    console.error(`  次の手: --bin rc-claude で建てる(会話ごとに statusLine を足すラッパ)。`);
    console.error(`          機械全体に効かせるなら settings.json に statusLine を1つ足す(Tom の手作業)。`);
    return (prepAbort = true);
  }

  // --- 建てる場所が**信頼済みか**を、TUI を建てる前に確かめる -------------------
  // ★2026-08-02 に踏んだ: 既定の cwd(= HOME)が未信頼だったので、Claude Code は入力欄でなく
  //   「Is this a project you created or one you trust?」の選択画面で止まった。台本は
  //   90 秒待った末に「上限や信頼確認の可能性」と**当て推量を並べて** exit 1(= 壊れている)を出した。
  //   人が取る次の手は三つとも別物なのに、1つの顔にまとめていた:
  //     信頼が要る(1回答える) / 上限(待つ) / 本当に壊れている(直す)。
  //   信頼は `~/.claude.json` の projects[dir].hasTrustDialogAccepted に載っているので、
  //   90 秒待たずにここで読める。**この台本は選択画面に答えない**(自動化に安全確認を
  //   押させない)。代わりに、信頼済みの dir へ自分で寄せるか、名指しで落ちる。
  const trustedDirs = (() => {
    try {
      const j = JSON.parse(readFileSync(join(HOME, ".claude.json"), "utf8"));
      return Object.entries(j.projects || {})
        .filter(([, v]) => v && v.hasTrustDialogAccepted === true)
        .map(([k]) => k);
    } catch {
      return null; // 読めない = 分からない。**未信頼と決めつけない**
    }
  })();
  let cwdNote = "確かめられなかった(~/.claude.json が読めない)";
  if (trustedDirs) {
    if (trustedDirs.includes(opt.cwd)) {
      cwdNote = "信頼済み";
    } else if (trustedDirs.length > 0) {
      // 既定のまま走らせて必ず止まる台本は計器として死んでいる。信頼済みの所へ寄せて**言う**。
      const picked = trustedDirs.find((d) => d.startsWith("/private/tmp") || d.startsWith("/tmp")) || trustedDirs[0];
      cwdNote = `${opt.cwd} は未信頼 → ${picked} に寄せた(--cwd で指定すれば上書きできる)`;
      opt.cwd = picked;
    } else {
      console.error(`建てる場所が未信頼で、信頼済みの dir が1つも無い: ${opt.cwd}`);
      console.error(`  この状態で建てると Claude Code は入力欄でなく信頼確認の選択画面で止まる。`);
      console.error(`  次の手: その機械で一度手で \`claude\` を起動し、画面を読んだ上で`);
      console.error(`          「1. Yes, I trust this folder」を選ぶ(この台本は選択画面に答えない)。`);
      return (prepAbort = true);
    }
  }

  console.log(`tmux      : ${tmux(["-V"]).trim()}`);
  console.log(`建てる場所: ${opt.cwd}(${cwdNote})`);
  console.log(`登録経路  : ${viaWrapper ? "rc-claude ラッパ" : "settings.json の statusLine"}`);
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
    const injector = new TmuxInjector({ tmux: injectorRunner(), echoBudgetMs: 8000 });
    tmux(["send-keys", "-t", pane, "-l", "--", opt.bin]);
    tmux(["send-keys", "-t", pane, "Enter"]);

    const boot = await waitFor(async () => {
      const t = injector.capture(pane);
      return classifyScreen(t).state === "SENDABLE" ? t : null;
    }, 90_000);
    const bootScreen = boot.v || injector.capture(pane);
    writeFileSync(join(outDir, "00-boot.txt"), bootScreen);
    if (!boot.ok) {
      // ★旧版はここで「上限や信頼確認の可能性」と**当て推量を二つ並べて** exit 1 を出していた。
      //   人の次の手は三つとも別物(答える / 待つ / 直す)。画面は撮ってあるのだから、推量でなく
      //   **読んで名指しする**。準備段で止まった物を「壊れている(1)」の顔で出さない。
      const tail8 = () => bootScreen.trimEnd().split("\n").slice(-8);
      if (limitNoticeIn(bootScreen)) {
        console.error("入力欄まで行かない: 画面に出ているのは**利用上限の告知**。直す物は無い。");
        for (const l of tail8()) console.error(`    ${l}`);
        console.error("  次の手: 上限が解けてから同じ台本を回す(この回は何も測れていない)。");
        return (prepAbort = true);
      }
      if (/Is this a project you created or one you trust\?/.test(bootScreen)) {
        console.error(`入力欄まで行かない: **信頼確認の選択画面**で止まっている(cwd=${opt.cwd})。`);
        console.error("  この台本は選択画面に答えない(自動化に安全確認を押させない)。");
        console.error("  次の手: その機械で一度手で `claude` を起動し、画面を読んだ上で");
        console.error("          「1. Yes, I trust this folder」を選ぶ。以後この台本は素通りする。");
        return (prepAbort = true);
      }
      console.error(`起動 90 秒で入力欄が出ない(state=${classifyScreen(bootScreen).state})。Enter は押さない。`);
      console.error("  画面の末尾:");
      for (const l of tail8()) console.error(`    ${l}`);
      console.error(`  画面全体: ${join(outDir, "00-boot.txt")}`);
      return (failed = true);
    }
    console.log(`起動 ok(${boot.waited}ms)`);

    // --- 2. 登録簿に自分で名乗るまで待つ(statusLine が書く) ------------------
    // ★輪の中で飲むのは正しい(json を書いている最中に読むと必ず落ちる)。正しくないのは
    //   **30 秒で落ちた時に理由が消える**事 —— 「壊れた json が在る」と「そもそも1件も出ない」が
    //   同じ一文になっていた(§2.20-a-ii の「条件付き1」)。最後の理由だけ残して check に混ぜる。
    let lastPaneErr = "";
    const reg = await waitFor(async () => {
      for (const f of readPanes()) {
        if (before.has(f)) continue;
        try {
          const j = JSON.parse(readFileSync(join(PANE_DIR, f), "utf8"));
          if (j.pane === pane) return { id: f.replace(/\.json$/, ""), entry: j };
        } catch (e) {
          lastPaneErr = `${f}: ${String(e?.message || e)}`;
        }
      }
      return null;
    }, 30_000);
    check("登録簿に名乗る", reg.ok, reg.ok
      ? `${reg.v.id}(${reg.waited}ms)`
      // 「無し」も必ず出す = 欄が出ない事と「読めなかった物が無い」を区別する(§2.16)。
      : `30秒で新しい登録が出ない(最後に読めなかった物: ${lastPaneErr || "無し"})`);
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

      // ★2026-08-02、この台本自身に踏まれて足した。edith で 16 OK / 0 NG / exit 0 が出た回の
      //   `03-history.json` を開いたら、assistant の本文が
      //     "You've hit your weekly limit · resets 12am (Asia/Tokyo)"
      //   だった。つまり上の「返答が history に出る」も「SSE の message で届く」も、
      //   **観測としては正しい**(実際に1件届いた)。嘘なのは、それを
      //   「一巡した = 会話が進んだ」と読ませてしまう所。届いたのは上限の告知であって答えではない。
      //   `live-inject-check.mjs` は同じ穴を先に踏んで exit 3 を持っている。こちらだけ
      //   緑を出し続けると、**二つの計器が同じ機械について逆の事を言う**(実際そうなった)。
      //   運ぶ層の検査(配達・SSE・割り込み)は緑のまま — 上限は「送れない」ではないので。
      //   足すのは「相手が答えたか」という別の列と、答えていない時に緑を出さない事。
      const replyText = replied.ok
        ? (replied.v.filter((m) => m.role === "assistant").pop()?.text || "")
        : "";
      //   ★NG(exit 1)には**しない**。「壊れている」と「相手が答えられない」は読み手の次の手が
      //   違う(前者は直す / 後者は待つ)。NG に混ぜると、上限のたびに壊れた顔をする計器になる。
      if (replied.ok) {
        limitedReply = limitNoticeIn(replyText);
        if (limitedReply) {
          note("★相手が答えたか", `答えていない — 返ってきたのは上限の告知: ${replyText.slice(0, 58)}`);
        } else {
          check("★返答が上限の告知ではない(相手が実際に答えた)", true, "告知ではない本文が返った");
        }
      }

      // ★ここが本題: 送った後、**電話は返答を知る事ができるか**。
      // 8/02 の初回は SSE に何も流れず、電話は送信後ずっと無音だった。潰したかったのはその穴。
      //
      // ただし「message で届く」を要求する形は**検査の側が間違っていた**。同じ機械・同じコードで
      // 数分違いの2回が `message 1 件 @0ms`(緑)と `message 0 件 @8s`(赤)に割れた。
      // 競争でも退行でもなく設計 — `src/server.mjs` の `f.tail.poll()`(`過去分は流さない`):
      //   tail は初回に**末尾へ位置合わせして過去分を流さない**(`過去分は流さない`)。
      //   代わりに `gap{rereadHistory:true, why:"tail-attached"}` を投げ、電話に読み直させる。
      // つまり返答が tail の接続より先に着いた回の届け先は message ではなく「gap → 読み直し」。
      // どちらも設計通りの経路なのに、片方だけを緑にする検査は**正しい動作を無作為に赤くする**。
      //
      // 緩める方向なので、緩め過ぎの線を先に引く。検査するのは経路名ではなく到達可能性:
      //   A. message 経路 … role=assistant を含む message が実際に流れた
      //                     (user のこだまだけでは電話は返答を知らないので数に入れない)
      //   B. 読み直し経路 … `rereadHistory:true` の gap が流れ、**その gap を受けた電話がやる事を
      //                     ここで実際にやって**(= `/history` を今もう一度読んで)返答が在る
      //                     ★`replied` の使い回しにしない。あれは gap より前に取った観測で、
      //                       「読み直せば在る」を支えない(この session の頻出欠陥そのもの)。
      //   A も B も無い = 電話は永久に無音 = NG。8/02 の本物の壊れ方はここで赤くなる。
      //
      // 待ち: tail の poll は 700ms 間隔なので、history に出た直後はまだ流れていない事がある。
      // 「今この瞬間に無い」を「来ない」と読み替えない — message 経路に予算を使い切らせてから判定する。
      const dataOf = (e) => {
        const m = /^data: (.*)$/m.exec(e.raw);
        try {
          return JSON.parse(m[1]);
        } catch (err) {
          // 解けない枠を「assistant の本文が来ていない」に化かさない。
          swallow("SSE の枠(本文の判定)", err);
          return null;
        }
      };
      const assistantMsgs = () =>
        stream.events.filter(
          (e) => !e.ping && e.raw.includes("event: message") && (dataOf(e)?.entries || []).some((x) => x.role === "assistant"),
        );
      const gotMsg = await waitFor(async () => (assistantMsgs().length > 0 ? assistantMsgs() : null), 8000, 300);
      const real = stream.events.filter((e) => !e.ping);
      const kind = (name) => real.filter((e) => e.raw.includes(`event: ${name}`));
      note(
        "SSE の assistant 本文を待った時間",
        gotMsg.ok ? `${gotMsg.waited}ms で到着` : "8秒待って到着せず(= 読み直し経路の側を見る)",
      );
      note(
        "SSE の内訳",
        `${Date.now() - t0}ms で 実 ${real.length} 件(message ${kind("message").length} / screen ${kind("screen").length} / gap ${kind("gap").length})`,
      );
      const rereadGaps = kind("gap").filter((e) => dataOf(e)?.rereadHistory === true);
      let replyInHistoryAfterGap = false;
      if (rereadGaps.length > 0) {
        const h = await api(opt.port, key, "GET", `/api/sessions/${sessionId}/history?limit=30`);
        replyInHistoryAfterGap = (h.json?.history || []).some((m) => m.role === "assistant");
      }
      const route = replyRoute({
        assistantMessages: assistantMsgs().length,
        rereadGaps: rereadGaps.length,
        replyInHistoryAfterGap,
      });
      check(
        "★送信後、電話が返答に到達できる(message か、gap 後の読み直しか)",
        route !== "none",
        `経路=${route} / assistant 入り message ${assistantMsgs().length} 件 / 読み直し指示の gap ${rereadGaps.length} 件` +
          `(読み直した結果 ${rereadGaps.length > 0 ? (replyInHistoryAfterGap ? "返答が在った" : "★返答が無かった") : "—"})`,
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
        } catch (err) {
          // ★`{}` は null ですらない**捏造**(変異 P4 と同じ形)。数え方は変えないが、
          //   捏造した事は必ず名乗る。
          swallow("SSE の枠(画面イベント/`{}` に化けた)", err);
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
    // ★2026-08-03 に中身を入れ替えた。前の版は `interrupted === true` を見て
    //   「interrupt が通る」と札を付けていたが、当時の `interrupted` は**押した事実**に
    //   縛られていて常に true だった = 何も測っていない検査が緑を出していた。
    //   今は「押した」と「止まった」が別の値になったので、**止める対象を自分で作って**
    //   から撃つ。作れない状況(--no-send)では作れないと言って形だけ見る。
    if (!opt.send) {
      const intr = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/interrupt`);
      const legal = intr.json?.stopped === null || intr.json?.stopped === "verified" || intr.json?.stopped === "unverified";
      check(
        "interrupt が三値の契約で返る(--no-send のため止める対象は作っていない)",
        intr.status === 200 && legal && intr.json?.interrupted === (intr.json?.stopped === "verified"),
        `status=${intr.status} stopped=${intr.json?.stopped} interrupted=${intr.json?.interrupted}`,
      );
    } else {
      // 長めの本文を投げて、**生成中の印が実際に画面に出るまで待つ**。ここで待たずに
      // 撃つと、答え終わった後のペインを叩いて not-in-flight が返るだけになる。
      const longProbe = "秒という単位の歴史を 500 字程度の平文で。箇条書きにしないで。";
      const fired = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/messages`, { text: longProbe });
      // ★待つ材料を 2026-08-03 に**差し替えた**。初版は footer の `esc to interrupt` が
      //   出るまで待っていたが、この語は `rc-claude`(= statusLine を足す起動ラッパ)を
      //   通すと **0/76 枚**しか出ない(素の `claude` なら 39/75。DESIGN §2.9-X の二腕対照)。
      //   edith のペインは常に `rc-claude` 側なので、初版はこの実機で**構造的に必ず**
      //   「生成中を作れなかった」へ落ちる = 割り込みを一度も測らないまま赤を出す計器だった。
      //   今は判定本体と同じ材料(`classifyScreen().activity`)で待つ。
      // ★内訳は残す。主語の無い赤を作らない為:
      //   `anywhere` = 画面のどこかに `esc to interrupt` が在った回数(素の端末なら増える)、
      //   `footer` = 末尾3行に在った回数、`spinner` = スピナーで観測できた回数。
      //   spinner だけ増えるのが edith の正常。全部 0 なら生成そのものが起きていない。
      let anywhere = 0;
      let footer = 0;
      let spinner = 0;
      let lastShot = "";
      const inflight = await waitFor(async () => {
        const t = injector.capture(pane);
        lastShot = t;
        if (/esc to interrupt/.test(t)) anywhere++;
        if (inFlightHintIn(t)) footer++;
        const from = classifyScreen(t).activityFrom;
        if (from && from !== "hint") spinner++;
        return classifyScreen(t).activity === "observed" ? true : null;
      }, 15000);
      if (!inflight.ok) {
        writeFileSync(join(outDir, "08-no-inflight.txt"), lastShot);
        note(
          "★印が出なかった時の内訳",
          `スピナーで見えた回数=${spinner} / 画面のどこかに esc to interrupt=${anywhere} / 末尾3行=${footer} / 送信=${fired.status} ${fired.json?.delivered} / 画面=${join(outDir, "08-no-inflight.txt")}`,
        );
        for (const l of lastShot.trimEnd().split("\n").filter((x) => x.trim()).slice(-6)) {
          console.log(`    | ${l.replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "<mail>")}`);
        }
      }
      if (!inflight.ok) {
        // ★ここを一律 NG にしない。生成が始まらない理由は2つあって、読み手の次の手が違う:
        //   (a) 上限に当たっている = 相手が答えられない -> 待つ(出口 3)。割り込みは**測れていない**。
        //   (b) それ以外 = 送ったのに動いていない -> 直す(出口 1)。
        //   8/02 にこの計器自身が (a) を緑で通した前科があるので、赤で通すのも同じ間違い。
        if (limitNoticeIn(injector.capture(pane))) {
          limitedReply = true;
          note("★割り込みは測れていない", "上限の告知が出ていて生成が始まらない(壊れているのではない)");
        } else {
          check(
            "★割り込みの前に生成中の状態を作れた",
            false,
            `送信 status=${fired.status} / 15 秒待っても activity=observed にならなかった`,
          );
        }
      } else {
        note("生成中になるまで", `${inflight.waited}ms(送信 status=${fired.status})`);
        const intr = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/interrupt`);
        check(
          "★★interrupt が効く(押しただけでなく、生成が止まったのを画面で確認)",
          intr.status === 200 && intr.json?.interrupted === true && intr.json?.stopped === "verified",
          `status=${intr.status} stopped=${intr.json?.stopped} waitedMs=${intr.json?.waitedMs}`,
        );
        note("止まったと分かるまで", `${intr.json?.waitedMs}ms`);

        // ★陰性対照。止めた直後にもう一度撃つ。同じ経路・同じペインで**違う値**が返る事が、
        //   上の verified が定数でない事の証明になる(止める対象がもう居ない)。
        const again = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/interrupt`);
        check(
          "★陰性対照: 止まった後の再割り込みは not-in-flight(verified を返し続けない)",
          again.status === 200 && again.json?.stopped === null && again.json?.reason === "not-in-flight",
          `status=${again.status} stopped=${again.json?.stopped} reason=${again.json?.reason}`,
        );
      }
    }

    // --- 9. 知らない相手には触らない ------------------------------------------
    const unknown = await api(opt.port, key, "GET", `/api/sessions/00000000-0000-0000-0000-000000000000/status`);
    check("知らない session は 404", unknown.status === 404, `status=${unknown.status}`);

    // --- 10. 「届いたか分からない」を実物で出す ---------------------------------
    // ここまでの送信は毎回 `delivered:"verified"` だった。`unverified` の枝は偽 tmux では
    // 作れるが、**実機では一度も観測されていない** = 電話に出る文面の出所が本物の画面から
    // 出た事を誰も見ていない(Sprint 5 の brief §0-d の2行目)。
    //
    // 起こし方は inject.mjs の非対称そのもの: 本文が入力欄の定型文と**同一**の時だけ、
    // 送信後に定型文が見えても「取り込まれた」と「本文が残っている」の区別が付かない ——
    // その回は verified 側へ倒さない、という規律が入っている。生成中に送れば TUI は
    // 本文をキューへ入れて入力欄に定型文を出すので、判別不能の条件が実機で揃う。
    // ★文字列は `inject.mjs` から import する。此処に写しを置くと、TUI の文言が変わった日に
    //   **写しだけが古くなって台本が黙って測らなくなる**(この案件で既に踏んだ型)。
    // ★起こせなかった回を赤にしない。此処が測っているのは「実機で出せるか」であって、
    //   出せない事はこの経路の故障ではない。緑にもしない = 実測メモで残す。
    if (opt.send && !limitedReply) {
      const long2 = "1 から 40 までの数を、間に読点を入れて順に書き出して。";
      const fired2 = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/messages`, { text: long2 });
      const gen = await waitFor(
        async () => (classifyScreen(injector.capture(pane)).activity === "observed" ? true : null),
        15000,
      );
      if (!gen.ok) {
        note(
          "★unverified は測っていない",
          `生成中の状態を作れなかった(送信 status=${fired2.status} delivered=${fired2.json?.delivered})`,
        );
      } else {
        const amb = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/messages`, {
          text: COMPOSER_PLACEHOLDER,
        });
        if (amb.status === 202 && amb.json?.delivered === "unverified") {
          check(
            "★202 + delivered=unverified の実物(生成中に、定型文と同一の本文を送る)",
            true,
            `status=${amb.status} route=${amb.json?.route} delivered=${amb.json?.delivered}`,
          );
          check(
            "unverified の回にだけ note が付く(電話がそのまま画面へ出す文面)",
            typeof amb.json?.note === "string" && amb.json.note.length > 0,
            `note の文字数=${(amb.json?.note || "").length}`,
          );
          check(
            "★unverified でも display は付く(系統 B の応答契約)",
            typeof amb.json?.display?.text === "string" && amb.json.display.text.length > 0,
            `kind=${amb.json?.display?.kind} keepText=${amb.json?.display?.keepText}`,
          );
          writeFileSync(join(outDir, "10-unverified.json"), JSON.stringify(amb.json, null, 2));
        } else {
          note(
            "★unverified は測っていない",
            `status=${amb.status} delivered=${amb.json?.delivered} = 実機では判別が付いた。緑にはしない`,
          );
        }
        const calm = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/interrupt`);
        note("片付け(生成とキューを止める)", `stopped=${calm.json?.stopped}`);
      }
    }

    // --- 11. ワーカー経路 -------------------------------------------------------
    // 机のペインを**自分で畳んで**から同じ会話へ送る。tmux 経路が消えた会話は
    // `claude-work -p --resume` の子へ落ちる = 「机に無い会話」への唯一の送信路で、
    // 実機で踏んだ事が一度も無い(brief §0-d の3行目)。
    // ★この節より後に tmux 経路の検査を足さない事(ペインはもう無い)。
    // ★子は必ず此処で止める。サーバへ SIGTERM を撃っても子は道連れにならないので、
    //   止め損ねると **Tom の機械に孤児の claude が残る**。止まった事は HTTP の言い分
    //   ではなく `pgrep` の一致数で確かめる(数だけ。行は持ち出さない)。
    if (opt.send) {
      tmuxOk(["kill-session", "-t", `=${session}`]);
      const paneGone = !tmuxOk(["has-session", "-t", `=${session}`]);
      note("ワーカー経路の準備", `使い捨てペインを畳んだ(不在=${paneGone})`);
      const st2 = await api(opt.port, key, "GET", `/api/sessions/${sessionId}/status`);
      if (st2.json?.route !== "worker") {
        // 同じ cwd に別の claude が居ると `unregistered`(= 宛先を確定できない)に落ちる。
        // これは設計どおりの拒否なので、赤ではなく「測れなかった」。
        note(
          "★ワーカー経路は測っていない",
          `ペインを畳んだ後も route=${st2.json?.route} reason=${st2.json?.reason ?? "-"}`,
        );
      } else {
        const w = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/messages`, {
          text: "ok とだけ答えて。",
        });
        check(
          "★ワーカー経路の送信が 202 で通る",
          w.status === 202 && w.json?.accepted === true && w.json?.route === "worker" && Number.isInteger(w.json?.seq),
          `status=${w.status} route=${w.json?.route} seq=${w.json?.seq} reason=${w.json?.reason ?? "-"}`,
        );
        check(
          "ワーカーの 202 にも display が付く(系統 B の応答契約)",
          typeof w.json?.display?.text === "string" && w.json.display.text.length > 0,
          `kind=${w.json?.display?.kind}`,
        );
        writeFileSync(join(outDir, "11-worker.json"), JSON.stringify(w.json, null, 2));
        const stop = await api(opt.port, key, "POST", `/api/sessions/${sessionId}/interrupt`);
        check(
          "ワーカーの子を止められる",
          stop.status === 200 && stop.json?.route === "worker",
          `status=${stop.status} route=${stop.json?.route} interrupted=${stop.json?.interrupted}`,
        );
        const orphan = await waitFor(async () => (procsMatching(sessionId) === 0 ? true : null), 8000);
        check("★ワーカーの子が残っていない", orphan.ok, `一致するプロセス数=${procsMatching(sessionId)}`);
      }
    }

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
    // ★`finally` に置く = 途中で落ちた回でも出る。**「無し」も必ず出す** — 欄が出ない事と
    //   「読めなかった物が無い」事は、読み手から区別が付かない(§2.16 を報告側でもう一度)。
    for (const s of stream?.errors || []) swallowed.push(`SSE の接続: ${s}`);
    note("読めなかった物", swallowed.length ? swallowed.join(" / ") : "無し");
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
    // ★登録簿の残骸を自分で片付ける(2026-08-05 追加)。statusline が書く
    //   `panes/<session_id>.json` と、ワーカー経路が書く `heads/<session_id>.json` は
    //   誰も刈らないので、走らせる度に使い捨て会話の分が Tom の機械へ1件ずつ積もる。
    //   **消すのは自分の session_id と完全一致する物だけ**(他の会話の登録には触らない)。
    if (sessionId) {
      for (const p of [join(PANE_DIR, `${sessionId}.json`), join(HEADS_DIR, `${sessionId}.json`)]) {
        if (!existsSync(p)) continue;
        try {
          unlinkSync(p);
          console.log(`片付け: ${p.replace(HOME, "~")} は ${existsSync(p) ? "★まだ在る" : "不在を確認"}`);
          if (existsSync(p)) failed = true;
        } catch (e) {
          // 消せなかった事を黙らない。残骸は次の走行の観測を汚す。
          console.log(`片付け: ${p.replace(HOME, "~")} を消せない(${e.message})`);
          failed = true;
        }
      }
    }
    console.log(`結果: ${results.filter((r) => r.ok === true).length} OK / ${results.filter((r) => r.ok === false).length} NG / 実測メモ ${results.filter((r) => r.ok === null).length} 件`);
    if (sessionId) console.log(`使い捨て会話の session_id: ${sessionId}(jsonl は ~/.claude/projects/ に残る)`);
    if (limitedReply) {
      // ★緑の数の隣に小さく書いても読まれない。**結論の位置に**置く(inject 側と同じ扱い)。
      console.log(
        `\n★この結果を「一巡した」と読んではいけない: 返ってきた assistant の本文は**利用上限の告知**。` +
          `\n  緑が意味するのは運ぶ層 — 送信が 202 で通り、画面が本文を取り込み、history に反映され、` +
          `\n  SSE に流れ、interrupt が効いた所まで。**会話が進んだ事は確かめていない**。` +
          `\n  上限が解けてから同じ台本をもう一度回す事(それまで exit 0 は出ない)。`,
      );
    }
  }
}

// 終了コードの意味と順序(2 > 1 > 3 > 0)は `tools/exit-codes.mjs` に1本だけ置いてある。
// 三項演算子を此処に直に書くと、この台本の**結論そのもの**が一度も検査されない1行になる ——
// 実機でしか走らない台本なので、順序が入れ替わっても手元では永久に気付かない。
// 8 通り全部と、4本の台本の合意は `test/live-exit-codes.test.mjs` が毎 commit 撃つ。
// ★上限で赤くなり得る枝は、此の台本の側で check ではなく note へ倒してある
//   (★相手が答えたか / ★割り込みは測れていない / ★unverified は測っていない)。
//   倒し忘れると 1 が 3 を隠す =「待てば直る物」を「直す物」として報告する計器になる。
//
// 終了コードは main の外で決める(try の中の return は finally を通って main を抜けるので、
// main の中に置いた process.exit には届かない = 8/01 に live-choice-check.mjs で踏んだ穴)。
// この台本は import もされる(`test/reply-route.test.mjs` が `replyRoute` に陰性対照を当てる)。
// import した側で1周走り出さない様に、**直接叩かれた時だけ** main を回す。
//   - argv[1] は symlink のままで渡る事があるので realpath で揃える。揃えないと symlink 経由の
//     起動で main が黙って走らない = 計器としては最悪の壊れ方(緑も赤も出ずに exit 0)。
//   - 判定不能側の倒し方は**走らせない**。ここが走ると `npm test` の最中に本物の Claude Code を
//     起動してしまう。「黙って何もしない」より「試験の最中に実機を触る」方が高くつく。
const invokedDirectly = (() => {
  const arg = process.argv[1];
  if (!arg) return false; // 直接起動なら必ず在る。無い = 誰かに import された文脈
  const norm = (p) => {
    try {
      return realpathSync(p);
    } catch {
      return p;
    }
  };
  return norm(arg) === norm(fileURLToPath(import.meta.url));
})();
if (invokedDirectly) {
  main().then(() => process.exit(exitCodeFor({ prepAbort, failed, limitedReply })));
}
