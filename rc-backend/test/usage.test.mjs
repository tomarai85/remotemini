import { test } from "node:test";
import assert from "node:assert/strict";
import { parseCswapUsage } from "../src/usage.mjs";

// friday の実 `cswap list --json`(2026-08-29)から写した最小の形。
const REAL_SHAPE = JSON.stringify({
  accounts: [
    {
      number: 1, email: "a@example.com", active: false, usageStatus: "ok",
      usage: {
        fiveHour: { pct: 0.0 },
        sevenDay: { pct: 100.0, countdown: "20h 46m", willLastToReset: false },
        scoped: [{ pct: 24.0, name: "Fable" }],
      },
    },
    // usage ごと欠ける行(unavailable)。行を捨てず、欄を null で載せる事。
    { number: 2, email: "b@example.com", active: false, usageStatus: "unavailable" },
    // email の無い行は載せようが無い(鍵が作れない)。
    { number: 3, active: false, usageStatus: "ok" },
  ],
});

test("実物の形を読み切り、欠けた窓は null(0 とも 100 とも混ぜない)", () => {
  const r = parseCswapUsage(REAL_SHAPE);
  assert.equal(r.status, "ok");
  assert.deepEqual(r.byEmail["a@example.com"], {
    usageStatus: "ok",
    sessionUsedPct: 0,
    weeklyUsedPct: 100,
    weeklyResetsIn: "20h 46m",
    willLastToReset: false,
  });
  // unavailable の行: 行は在る、欄は全部 null(「測れていない」)
  assert.deepEqual(r.byEmail["b@example.com"], {
    usageStatus: "unavailable",
    sessionUsedPct: null,
    weeklyUsedPct: null,
    weeklyResetsIn: null,
    willLastToReset: null,
  });
  // email 無しの行は載らない(キーが作れない)— 3行中2行だけになる
  assert.equal(Object.keys(r.byEmail).length, 2);
});

test("読めない出力は unreadable — 空の byEmail を「全口座ゼロ件」として返さない", () => {
  for (const bad of ["", "not json", "{}", JSON.stringify({ accounts: "x" }), null, undefined]) {
    const r = parseCswapUsage(bad);
    assert.equal(r.status, "unreadable", `input=${JSON.stringify(bad)}`);
    assert.equal(r.byEmail, null);
  }
});

test("数値でない pct・文字列でない countdown は null に落ちる(型を素通ししない)", () => {
  const r = parseCswapUsage(JSON.stringify({
    accounts: [{
      email: "c@example.com", usageStatus: "ok",
      usage: { fiveHour: { pct: "80" }, sevenDay: { pct: NaN, countdown: 42, willLastToReset: "yes" } },
    }],
  }));
  // NaN は JSON.stringify で null になるが、文字列 pct は残る — どちらも数値でなければ null
  assert.deepEqual(r.byEmail["c@example.com"], {
    usageStatus: "ok",
    sessionUsedPct: null,
    weeklyUsedPct: null,
    weeklyResetsIn: null,
    willLastToReset: null,
  });
});
