// `cswap list --json` の usage を電話向けの最小形に畳む純関数層(2026-08-29)。
//
// 出典 = claude-swap(艦隊トークンレーンの道具、`~/.local/bin/cswap`)。CodexBar の
// メニューが出している Session / Weekly の数字と**同じ真実**を電話に出す為の物。
// Tom 2026-08-29「使用するアカウントの使用量に対して、CodexBar のような感じで、
// 残りの使用量とか全くないけど、大丈夫?」— 同日、現用口座がセッション上限に当たり、
// 電話が limit の文だけを受け取った(残量が見えない切替は目隠しの切替)。
//
// ★pct は**使用率**(used %)。残量は電話側が 100 - pct で描く(数値の算術は語彙ではない。
//   文言 — countdown 等 — は cswap が作った物をそのまま運ぶ: 語彙を2箇所に分けない)。
// ★トークンレーンの裁定(2026-08-20「切替は Tom のみ・配布は観測のみ」)に対して、
//   この層は**観測のみ**。切替の道(select / next)には一切触れない。
// ★server.mjs に埋めない理由は account.mjs と同じ: listen 無しで単体から呼べる事。

/**
 * 返り値:
 *   status  "ok" = JSON を読み切った / "unreadable" = 読めていない(古い値を使い続ける事)
 *   byEmail { <email>: { usageStatus, sessionUsedPct, weeklyUsedPct,
 *                        weeklyResetsIn, willLastToReset } }
 *
 * ★欄が欠けた account は**行ごと捨てない**。email さえ在れば載せ、無い欄は null —
 *   「測れていない」を「使い切っている/空いている」のどちらにも読ませない。
 */
export function parseCswapUsage(stdout) {
  let d;
  try {
    d = JSON.parse(String(stdout ?? ""));
  } catch {
    return { status: "unreadable", byEmail: null };
  }
  const list = Array.isArray(d?.accounts) ? d.accounts : null;
  if (!list) return { status: "unreadable", byEmail: null };
  const byEmail = {};
  for (const a of list) {
    const email = a?.email;
    if (typeof email !== "string" || email === "") continue;
    const u = a?.usage ?? {};
    const five = u?.fiveHour ?? null;
    const seven = u?.sevenDay ?? null;
    byEmail[email] = {
      usageStatus: typeof a?.usageStatus === "string" ? a.usageStatus : null,
      sessionUsedPct: numOrNull(five?.pct),
      weeklyUsedPct: numOrNull(seven?.pct),
      weeklyResetsIn: typeof seven?.countdown === "string" ? seven.countdown : null,
      willLastToReset: typeof seven?.willLastToReset === "boolean" ? seven.willLastToReset : null,
    };
  }
  return { status: "ok", byEmail };
}

function numOrNull(v) {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
