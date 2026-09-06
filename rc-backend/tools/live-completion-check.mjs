// live-completion-check.mjs — 「長い作業が終わった」の遷移を、**本番の机**の digest-notify が**記録するだけ**で
// 一度も鳴らさない事を、**使い捨ての会話にだけ**仕事をさせて観測する(対照表 #32)。
//
// ── なぜ在るか(2026-09-06)────────────────────────────────────────────────────
// `digest-notify.sh` は 2026-09-04 に「完了の遷移」の検出を得た(前の刻みで動いていた → 今は入力欄が空で
// 止まっている、要約が完全、仕事が非零)。設計書(`research/notification-push-type-split-2026-09-04.md`)は
// 既定を反転させる前に 3 つの数(頻度 / 窓の長さ / 在席中の割合)を求めるが、friday の登録済み母集団は
// 会話 3 本・うち動くのは phone pane 1 本で、配備から 36 時間で記録は **0 行**(file 自体が無い)。
// 母集団が薄い時、計器が壊れているのか現象が無いのかは区別できない。だから**1 件だけ**遷移を起こし、
// (a) 検出器が其れを記録し (b) 其の記録が通知にならない、を本番で確かめる。之は「計器が生きている」の証明で
// あって、閾値を決める 3 つの数ではない —— 数は実利用が積む。
//
// 手順(全部 rc-e2e-<数字> の使い捨て会話に閉じる):
//   1. `disposable-session.mjs up`(rc-claude 経由 = 電話と同じ起動)
//   2. 電話の口 `POST /api/sessions/:id/messages` で「Bash で sleep NNN をして done と返せ」を送る
//      → 生成中は画面に活動が出る = digest は `attention=none`
//   3. `/digest` を刻み(≥ 1 tick = 150 s)ごとに読み、`none` を 1 回以上見てから `input` に落ちるのを待つ
//   4. launchd の digest-notify が次の刻みで遷移を見る → `~/.rc-backend/digest-completion.log` に
//      `<epoch>\tcompletion\t<sid>\twindow_min=…` が**1 行**現れるのを待つ(最長 2 tick + 余白)
//   5. `digest-notify.log` に其の sid の**鳴らした痕跡が無い**事を見る(記録専用の設計が本番でも保たれている)
//   6. 畳む。畳めた事は確かめてから名乗る(composer-guard と同じ再試行と `torn_retry`)
//
// 測る物(全欄が揃って初めて 0):
//   activity_seen=1     生成中に digest が `none` を返した(= 遷移の「前」が観測できた)
//   stopped_seen=1      其の後 `input` に落ちた(= 遷移の「後」)
//   completion_logged=1 検出器が其の sid の completion 行を書いた
//   window_min=N        記録された窓の長さ(0 より大きい)
//   no_alert=1          同じ sid で通知が鳴っていない
//   torn_down=1         畳めた
// 測らない物(故意): 在席中(presence_fresh)の分岐。之は Tom が机に居る時にしか起きず、起こせない。
//
// 終了コード(艦隊の live-* と同じ契約 = test/live-exit-codes.test.mjs):
//   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(鍵・使い捨てが建たない)
//   3 = 測っていない(机に届かない・利用上限の机で測った緑を閉じたと言わない)
//
// 使い方: node rc-backend/tools/live-completion-check.mjs [--url URL] [--sleep SEC] [--tick SEC]
//         node rc-backend/tools/live-completion-check.mjs --verdict <rc> <line>
import { execFileSync } from "node:child_process";

/** 判定だけ。純粋(対照が全通り撃つ)。
 *  ★欄は**表として読む**(2026-09-06、Codex の指摘 4 点): 部分一致でなく丸ごと / 同じ欄が 2 回出たら矛盾として赤 /
 *    `kind=ok` が無ければ赤 / `kind=ng` はどこに在っても「測っていない」/ `window_min` は数字だけ。 */
export function verdict(rc, line) {
  const s = String(line || "").trim();
  const fields = new Map();
  let dup = false;
  for (const tok of s.split(/\s+/).filter(Boolean)) {
    const i = tok.indexOf("=");
    if (i <= 0) continue;                       // `=` の無い語は欄ではない(無視、鍵と誤読しない)
    const k = tok.slice(0, i), v = tok.slice(i + 1);
    if (fields.has(k)) dup = true;
    fields.set(k, v);
  }
  const get = (k) => (fields.has(k) ? fields.get(k) : null);
  if (get("kind") === "ng") {
    console.log(`  --  : 机に届いていない(${s.slice(0, 80)})—— **測っていない**`);
    return 3;
  }
  if (get("limited") === "limited") {
    console.log("  --  : 机が利用上限。緑を名乗らない = 測っていない");
    return 3;
  }
  let fail = 0;
  if (get("kind") !== "ok") { console.log("  NG  : 殻が kind=ok を名乗っていない"); fail = 1; }
  if (dup) { console.log("  NG  : 同じ欄が 2 回出ている(矛盾した記録は読まない)"); fail = 1; }
  const need = [
    ["activity_seen", "1", "生成中に digest が none を返した(遷移の前が観測できた)"],
    ["stopped_seen", "1", "其の後 input に落ちた(遷移の後)"],
    ["completion_logged", "1", "検出器が其の sid の completion 行を書いた"],
    ["no_alert", "1", "同じ sid で通知が鳴っていない(記録専用が本番でも保たれている)"],
    ["torn_down", "1", "使い捨てを畳めた(机に残していない)"],
  ];
  for (const [k, v, why] of need) {
    const ok = get(k) === v;
    console.log(ok ? `  ok  : ${why}` : `  NG  : ${why} —— 観測できない(${k}=${v})`);
    if (!ok) fail = 1;
  }
  const w = get("window_min");
  if (w !== null && /^\d+$/.test(w) && Number(w) > 0) console.log(`  ok  : 記録された窓の長さ ${w} 分(0 より大きい)`);
  else { console.log("  NG  : 記録された窓の長さが 0 か無いか数字でない(window_min)"); fail = 1; }
  if (fail || rc !== 0) { console.log("→ 完了の記録の確認: 閉じていない"); return 1; }
  console.log("→ 完了の記録の確認: 観測で閉じた");
  return 0;
}

function usage() {
  console.error("usage: node live-completion-check.mjs [--url URL] [--sleep SEC] [--tick SEC] | --verdict <rc> <line>");
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main(argv) {
  if (argv[0] === "--verdict") { process.exit(verdict(Number(argv[1]), argv.slice(2).join(" "))); }
  let url = process.env.RC_LIVE_URL || "https://desk.tailnet.example:9443";
  const host = process.env.RC_LIVE_SSH || "athenas";
  let workSec = 200;   // 生成(= Bash の sleep)を 1 tick より長く保つ
  let tickSec = 150;   // friday の com.fleet.rc-digest-notify の StartInterval(2026-09-06 実測)
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--url") url = argv[i + 1];
    else if (argv[i] === "--sleep") workSec = Number(argv[i + 1]);
    else if (argv[i] === "--tick") tickSec = Number(argv[i + 1]);
    else { usage(); process.exit(2); }
  }
  const sh = (cmd) => execFileSync("ssh", [host, cmd], { encoding: "utf8", maxBuffer: 8 << 20 }).trim();
  const need = (name) => {
    const p = sh(`command -v ${name} || ls /opt/homebrew/bin/${name} 2>/dev/null | head -1`);
    if (!p) { console.log(`遠隔に ${name} が無い(= 測れていない。0 件と読まない)`); process.exit(2); }
    return p;
  };
  let key = "";
  try { key = sh("cat ~/.rc-backend/api.key"); } catch { console.log("鍵が読めない"); process.exit(2); }
  if (!key) { console.log("鍵が空"); process.exit(2); }
  let node = "";
  try { node = need("node"); } catch { console.log("遠隔に届かない"); process.exit(3); }

  let sid = "";
  let tmuxName = "";
  try {
    const out = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs up 2>/dev/null`);
    const lines = out.split("\n").map((l) => l.trim()).filter(Boolean);
    tmuxName = lines.find((l) => /^rc-e2e-[0-9]{6,}$/.test(l)) || "";
    sid = lines.find((l) => /^[0-9a-f]{8}-[0-9a-f-]{20,}$/i.test(l)) || "";
  } catch {
    console.log("使い捨ての会話が建たない(= 測れていない)"); process.exit(2);
  }
  if (!sid || !tmuxName) { console.log("使い捨ての id か tmux 名が空"); process.exit(2); }
  console.log(`  ..  : tmux=${tmuxName} sid=${sid}`);

  const H = { authorization: `Bearer ${key}`, "content-type": "application/json" };
  const post = async (body) => {
    const r = await fetch(`${url}/api/sessions/${sid}/messages`, { method: "POST", headers: H, body: JSON.stringify(body) });
    return { status: r.status, text: await r.text() };
  };
  const digest = async () => {
    const r = await fetch(`${url}/api/sessions/${sid}/digest`, { headers: H });
    if (r.status !== 200) return { attention: `http-${r.status}` };
    try { return await r.json(); } catch { return { attention: "not-json" }; }
  };
  const parts = [];
  const t0 = Date.now();
  const stamp = () => `${Math.round((Date.now() - t0) / 1000)}s`;

  try {
    // 2. 電話の口で仕事を頼む。sleep は Bash の中 = 画面に活動が出続ける。
    const sent = await post({
      text: `Run the shell command sleep ${workSec} with the Bash tool (set the tool timeout above ${workSec * 1000} ms, never in the background), then reply with the single word done.`,
      sendId: `completion${Date.now()}`,
    });
    console.log(`  ..  : send HTTP ${sent.status} (${stamp()})`);
    if (sent.status !== 202) { throw new Error(`send refused: ${sent.status} ${sent.text.slice(0, 120)}`); }

    // 3. 遷移の前(none)→後(input)を digest で見る。刻みは机の tick と無関係に 10 s。
    let activity = 0, stopped = 0;
    const deadline = t0 + (workSec + 4 * tickSec) * 1000;
    while (Date.now() < deadline) {
      const d = await digest();
      const att = String(d.attention || "");
      if (att === "none") activity = 1;
      if (activity && att === "input") { stopped = 1; break; }
      await sleep(10_000);
    }
    console.log(`  ..  : activity=${activity} stopped=${stopped} (${stamp()})`);
    // ★活動を一度も観測できなかった = 遷移の「前」が無い = **測っていない**(赤ではない)。
    //   起こり得る形: 机が仕事を始めなかった / 最初の刻みの前に終わった(sleep が短い)。
    //   赤にすると「検出器が壊れた」と同じ顔になる —— 分けて名乗る(Codex 2026-09-06)。
    if (!activity) throw Object.assign(new Error("activity never observed"), { step: "activity" });
    parts.push(`activity_seen=${activity}`);
    parts.push(`stopped_seen=${stopped}`);

    // 4. 検出器の記録を待つ(最長 2 tick + 余白)。file が無い間は「まだ」であって「無い」ではない。
    let logged = 0, windowMin = -1;
    const logDeadline = Date.now() + (2 * tickSec + 30) * 1000;
    while (Date.now() < logDeadline) {
      const line = sh(`grep -F '\t${sid}\t' ~/.rc-backend/digest-completion.log 2>/dev/null | tail -1 || true`);
      if (line) {
        logged = 1;
        const m = /window_min=(\d+)/.exec(line);
        windowMin = m ? Number(m[1]) : -1;
        break;
      }
      await sleep(15_000);
    }
    parts.push(`completion_logged=${logged}`);
    parts.push(`window_min=${windowMin}`);
    console.log(`  ..  : logged=${logged} window_min=${windowMin} (${stamp()})`);

    // 5. 鳴っていない事を **2 つの根拠**で見る(Codex 2026-09-06: sid の 8 桁だけの grep は
    //    「digest が取れない: <sid8>」等にも当たり、逆に sid を書かない鳴らし方を見落とす):
    //    (a) 鳴らす時の行は `鳴らす: <sid8> attention=…` と決まっている(digest-notify.sh の配達部)
    //    (b) 状態 file の其の sid の `alerted` 旗(鳴らした事の正本。記録専用の経路は触らない)
    const rang = sh(`grep -c '鳴らす: ${sid.slice(0, 8)}' ~/.rc-backend/digest-notify.log 2>/dev/null || true`);
    let flag = "unknown";
    try {
      flag = sh(`/usr/bin/python3 -c 'import json; d=json.load(open("${"$HOME"}/.rc-backend/digest-notify.json")); r=d.get("${sid}") or {}; print(1 if r.get("alerted") is True else 0)' 2>/dev/null`) || "unknown";
    } catch { flag = "unknown"; }
    parts.push(`no_alert=${Number(rang || 0) === 0 && flag === "0" ? 1 : 0}`);
    console.log(`  ..  : ring_lines=${rang || 0} alerted_flag=${flag}`);
  } catch (e) {
    const step = (e && e.step) || "probe";
    console.log(`殻の出力: kind=ng step=${step}`);
    console.log(`  !!  : ${String(e && e.message || e).split("\n")[0].slice(0, 160)}`);
    console.log("=== 判定 ===");
    try { sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`); } catch { /* 最善努力 */ }
    process.exit(verdict(1, `kind=ng step=${step}`));
  }

  let limited = "unknown";
  try { limited = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs limited '${sid}'`) || "unknown"; } catch { /* 訊けない */ }
  let torn = 0;
  let retried = 0;
  try {
    sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`);
    torn = sh(`test -e ~/.rc-backend/panes/${sid}.json && echo present || echo gone`) === "gone" ? 1 : 0;
    if (!torn) {
      retried = 1;
      sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`);
      torn = sh(`test -e ~/.rc-backend/panes/${sid}.json && echo present || echo gone`) === "gone" ? 1 : 0;
    }
  } catch (e) {
    torn = 0;
    console.log(`  !!  : 畳む段で例外 — ${String(e && e.message || e).split("\n")[0].slice(0, 160)}`);
  }
  parts.push(`torn_down=${torn}`);
  parts.push(`torn_retry=${retried}`);

  const line = `kind=ok ${parts.join(" ")} limited=${limited}`;
  console.log(`殻の出力: ${line}`);
  console.log("=== 判定 ===");
  process.exit(verdict(0, line));
}

main(process.argv.slice(2));
