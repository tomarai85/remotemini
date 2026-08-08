// ワーカーを**どこで**起こすか(DESIGN §2.22 / §3-V)を `src/server.mjs` の**本文**で押さえる。
//
// ★なぜ静的検査なのか: `src/server.mjs` は import した瞬間に listen する(`server.listen(...)`
//   が module 直下に在る)。単体検査から呼べないので、この層は e2e 越しにしか触れない。
//   e2e は edith が要る = 手元では回らない = 事実上「誰も見ていない」。だから**文面を読む**。
//   これは §2.23 で書いた型(「検出」欄に書いた検査が一度も書かれていなかった)の再発防止側。
//
// ★対照は2段: ①合成した偽物で「述語が区別できる」事、②**本物の文面から1本だけ剥がして**
//   「述語が本物の書き方に当たる」事。②が無いと「自分の書き癖に当たっているだけ」を排除できない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { blockAfter } from "./jssrc.mjs";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "src", "server.mjs");
const real = readFileSync(SRC, "utf8");

const spawnBlock = (s) => blockAfter(s, "spawn: (sessionId, plan) =>");

/** ワーカー経路の route 本文(断り〜202 まで)。 */
function workerRoute(s) {
  const i = s.indexOf("// 机で開かれていない会話");
  if (i === -1) return null;
  const end = s.indexOf('route: "worker", seq });', i);
  return end === -1 ? null : s.slice(i, end);
}

// ---- 要求(1件ずつ落ちる。束ねると「どれが壊れたか」が消える) ----
const REQS = [
  {
    id: "W19 会話の居場所を spawn に渡す",
    why: "plan.cwd を組み立てても spawn options に写さなければ、子は $HOME で開く",
    ok: (s) => {
      const b = spawnBlock(s);
      return !!b && /cwd:\s*plan\.cwd\b/.test(b) && !/cwd:\s*HOME\b/.test(b);
    },
  },
  {
    id: "W20 既定値へ落とさない",
    why: "`|| HOME` は「場所が無い会話」を無音で $HOME 送りにする。断るべき所で通してしまう",
    // ★`plan.cwd` が在る事も要求する。「無い物には既定値も無い」で**空撃ちで緑**になるから
    //   —— 実際 §3-V を当てる前にこの述語だけ緑だった(2026-08-03 の空撃ち)。
    ok: (s) => {
      const b = spawnBlock(s);
      return !!b && /cwd:\s*plan\.cwd\b/.test(b) && !/plan\.cwd\s*\|\|/.test(b);
    },
  },
  {
    id: "W22 起こす直前に**同期で**確かめる",
    why: "spawn より後に確かめると、202 を返した後に死ぬ。非同期の error では間に合わない",
    ok: (s) => {
      const b = spawnBlock(s);
      if (!b) return false;
      const g = b.indexOf("realpathSync(plan.cwd)");
      const sp = b.indexOf("nodeSpawn(");
      return g !== -1 && sp !== -1 && g < sp;
    },
  },
  {
    id: "W21 未信頼は spawn より前に 409 で断る",
    why: "未信頼の場所で先に子を起こすと、電話から答えられない信頼確認の画面が1枚出来る",
    ok: (s) => {
      const b = workerRoute(s);
      if (!b) return false;
      const v = b.indexOf("cwdVerdict(");
      const m = b.indexOf("manager.send(");
      if (v === -1 || m === -1 || v > m) return false;
      return /verdict !== "ok"[\s\S]{0,400}?409/.test(b);
    },
  },
  {
    id: "W21b 判定に使った場所を、そのまま送る側へ渡す",
    why: "検査した場所と起こす場所が別だと、検査が何も守っていない",
    ok: (s) => {
      const b = workerRoute(s);
      return !!b && /manager\.send\([\s\S]{0,300}?cwd:\s*wcwd/.test(b);
    },
  },
  {
    id: "W23 信頼を機械で与えない",
    // ★これは**禁止**なので、破られるまで緑。禁止側の要求は「本物が緑」では何も証明しない
    //   —— 意味を持たせているのは下の対照と変異 W23 の方。
    why: "自動化が信頼確認を代行したら Tom の裁定(自動化に安全確認を押させない)を破る",
    ok: (s) => !/hasTrustDialogAccepted/.test(s),
  },
  {
    id: "spawn 失敗の理由は伏せてから返す",
    why: "生の失敗文には環境の中身が混ざる。電話に素で出さない(src/redact.mjs)",
    ok: (s) => {
      const b = workerRoute(s);
      return !!b && /redact\(String\(e/.test(b);
    },
  },
];

for (const r of REQS) {
  test(`本物が満たす: ${r.id}`, () => {
    assert.ok(r.ok(real), `${r.id} —— ${r.why}`);
  });
}

// ---- 対照① 合成(述語が区別できる事) ----
const FAKE_OK = `
  spawn: (sessionId, plan) => {
    realpathSync(plan.cwd);
    return nodeSpawn(CLAUDE_WORK, ["-p"], { stdio: [], cwd: plan.cwd });
  },
      // 机で開かれていない会話 = ワーカー経路(-p --resume)
      const wcwd = sessionCwd();
      const verdict = cwdVerdict(wcwd);
      if (verdict !== "ok") {
        return json(res, 409, { reason: verdict, error: WORKER_REFUSAL[verdict] });
      }
      let seq;
      try {
        seq = manager.send(sessionId, text, { onEvent: () => {}, cwd: wcwd });
      } catch (e) {
        return json(res, 500, { error: redact(String(e?.message || e)) });
      }
      return json(res, 202, { accepted: true, route: "worker", seq });`;

test("対照①: 合成した合格例は全要求を満たす(述語が厳しすぎない)", () => {
  for (const r of REQS) assert.ok(r.ok(FAKE_OK), `合格例を落とした: ${r.id}`);
});

const FAKES = [
  ["$HOME で開く", (s) => s.replace("cwd: plan.cwd })", "cwd: HOME })"), "W19"],
  ["既定値へ落とす", (s) => s.replace("cwd: plan.cwd })", "cwd: plan.cwd || HOME })"), "W20"],
  ["起こしてから確かめる", (s) => s.replace("realpathSync(plan.cwd);\n    return nodeSpawn", "return nodeSpawn"), "W22"],
  ["断らずに送る", (s) => s.replace(/if \(verdict !== "ok"\) \{[\s\S]*?\}\n/, ""), "W21"],
  ["別の場所を渡す", (s) => s.replace("cwd: wcwd });", "cwd: homedir() });"), "W21b"],
  ["生の失敗文を返す", (s) => s.replace("redact(String(e?.message || e))", "String(e?.message || e)"), "伏せてから"],
];

for (const [name, mutate, hits] of FAKES) {
  test(`対照①: 合成を壊すと「${hits}」が赤(${name})`, () => {
    const broken = mutate(FAKE_OK);
    assert.notEqual(broken, FAKE_OK, "対照が1文字も変わっていない = 対照になっていない");
    const failed = REQS.filter((r) => !r.ok(broken)).map((r) => r.id);
    assert.ok(failed.some((id) => id.includes(hits)), `壊したのに素通り。落ちたのは: ${failed.join(" / ") || "無し"}`);
  });
}

// ---- 対照② 本物の文面から1本だけ剥がす(自分の書き癖に当たっているだけ、を排除) ----
const STRIPS = [
  ["会話の居場所を渡す", (s) => s.replace(/cwd: plan\.cwd \}\);/, "cwd: HOME });"), "W19"],
  ["既定値へ落とさない", (s) => s.replace(/cwd: plan\.cwd \}\);/, "cwd: plan.cwd || HOME });"), "W20"],
  ["同期の確認", (s) => s.replace("realpathSync(plan.cwd);", ""), "W22"],
  ["spawn 前の 409", (s) => s.replace(/if \(verdict !== "ok"\) \{[\s\S]*?\n      \}\n/, ""), "W21"],
];

for (const [name, mutate, hits] of STRIPS) {
  test(`★対照②: 本物から「${name}」を剥がすと ${hits} が赤`, () => {
    const broken = mutate(real);
    assert.notEqual(broken, real, `本物の文面に当たっていない(的が古い): ${name}`);
    const failed = REQS.filter((r) => !r.ok(broken)).map((r) => r.id);
    assert.ok(failed.some((id) => id.includes(hits)), `剥がしたのに素通り。落ちたのは: ${failed.join(" / ") || "無し"}`);
  });
}

test("★信頼一覧へ書ける手段が server.mjs に無い(変異 W23 の的)", () => {
  const route = workerRoute(real);
  assert.ok(route, "ワーカー経路が見つからない");
  for (const bad of ["hasTrustDialogAccepted", "claude.json"]) {
    assert.ok(!real.includes(bad), `信頼一覧を直接触る手段が入った: ${bad}`);
  }
});
