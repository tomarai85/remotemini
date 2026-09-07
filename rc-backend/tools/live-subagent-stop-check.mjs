// live-subagent-stop-check.mjs — 電話の口 `POST /api/sessions/:id/subagents/:agentId/stop` を**本番の机**で、使い捨ての会話にだけ
// 仕事をさせて観測する(対照表 #8 の後半)。3 つの形(`--mode`):
//
//   twin   (既定) 同名の subagent 2 本のうち名指した 1 本だけが止まり、もう 1 本が走り続ける(2026-09-06 に 2 回 0)
//   single 走っている subagent が 1 本だけ。止めると**節の無い空のパネル**になる(実機未測定だった形。driver の `emptyPanel`)
//   shell  親が背景シェル(`run_in_background` の Bash)を持つ横で subagent を止めようとする。裁定(2026-09-07、Codex DON'T SHIP)
//          どおり口は `shells-present` で断り、**1 打も打たない** = agent もシェルも走り続ける。★続けて**対照**: シェルを
//          (pid を名指しで)殺し、同じ口を撃ち直すと今度は止まる = 断りがシェルに由来する事と、断りの文の助言
//          ("Wait for the shell to finish … then try again")が本当である事を同じ会話で見る(Codex 2026-09-07 #6)
//
// ── なぜ在るか ──────────────────────────────────────────────────────────────
// 計画と driver は偽 tmux の模型で緑だが、模型は本物の TUI ではない。単体の緑を「効く」と読まない(2026-08 の教訓:
// gate は unit で 7/7、live で発火 0)。twin は 2 回通ったが、single(空パネル)と shell(断りの実物)は本番で見ていなかった。
//
// 手順(全部 rc-e2e-<数字> の使い捨て会話に閉じる):
//   1. `disposable-session.mjs up`(rc-claude 経由 = 電話と同じ起動)
//   2. `POST /messages` で形ごとの prompt を送る(twin = 同名 2 本 / single = 1 本 / shell = 背景の `sleep 240` + 1 本)
//   3. `GET /subagents` を 10 秒ごとに読み、期待の本数が running になるのを待つ(最長 120 s)
//   4. 目標を選ぶ(twin = 転写の `sleep 13` の行数差 / single・shell = 唯一の running)
//   5. `POST /subagents/<target>/stop {}` → HTTP と本文を記録
//   6. 形ごとの後観測: twin = 目標の転写が凍り peer が伸びる / single = 目標が凍り、机の画面が SENDABLE(パネルが閉じている)/
//      shell = 409 `shells-present`・sent=0、agent の転写が伸び続け、シェルの `sleep 240` が生きている
//   7. 畳む(残った物は畳みで死ぬ)。畳めた事は確かめてから名乗る
//
// 測る物(形ごと。全欄が揃って初めて 0):
//   twin  : two_running=1 target_chosen=1 stop_http=200 stopped=observed target_frozen=1 peer_running=1 torn_down=1
//   single: one_running=1 stop_http=200 stopped=observed observed_via=panel|reopened target_frozen=1 screen_after=SENDABLE torn_down=1
//   shell : shell_seen=1 one_running=1 stop_http=409 reason=shells-present sent=0 pressed_none=1 shell_row_seen=1 agent_running=1
//           shell_alive=1 retry_http=200 retry_stopped=observed target_frozen=1 torn_down=1
//           (pressed_none = 机の鍵列が `/tasks`・Enter・Escape 以外を含まない / shell_row_seen = 机が断りに載せたパネルのシェル行に
//            此の run の nonce が在る = TUI が**此のシェル**の行を出していた / retry_* = シェルを殺した後の撃ち直し)
//
// 終了コード(艦隊の live-* と同じ契約 = test/live-exit-codes.test.mjs):
//   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(鍵・使い捨てが建たない)/ 3 = 測っていない(机に届かない・利用上限の机・上限を訊けない)
//
// 使い方: node rc-backend/tools/live-subagent-stop-check.mjs [--mode twin|single|shell] [--url URL] [--host SSH] [--settle SEC]
//         node rc-backend/tools/live-subagent-stop-check.mjs --verdict <rc> <line>
import { execFileSync } from "node:child_process";

export const MODES = ["twin", "single", "shell"];

/** 判定だけ。純粋(対照が全通り撃つ)。欄は表として読む(丸ごと一致 / 同じ欄が 2 回は矛盾 / kind=ok 必須 / kind=ng は測っていない)。 */
export function verdict(rc, line) {
  const s = String(line || "").trim();
  const fields = new Map();
  let dup = false;
  for (const tok of s.split(/\s+/).filter(Boolean)) {
    const i = tok.indexOf("=");
    if (i <= 0) continue;
    const k = tok.slice(0, i), v = tok.slice(i + 1);
    if (fields.has(k)) dup = true;
    fields.set(k, v);
  }
  const get = (k) => (fields.has(k) ? fields.get(k) : null);
  if (get("kind") === "ng") return 3;
  if (Number(rc) !== 0) return 1;
  if (get("limited") === "limited" || get("limited") === "unknown") return 3;
  if (get("kind") !== "ok" || dup) return 1;
  const mode = get("mode") ?? "twin";
  if (get("torn_down") !== "1") return 1;
  if (mode === "twin") {
    return get("two_running") === "1" && get("target_chosen") === "1" && get("stop_http") === "200" && get("stopped") === "observed"
      && get("target_frozen") === "1" && get("peer_running") === "1" ? 0 : 1;
  }
  if (mode === "single") {
    return get("one_running") === "1" && get("stop_http") === "200" && get("stopped") === "observed"
      && (get("observed_via") === "panel" || get("observed_via") === "reopened") && get("target_frozen") === "1" && get("screen_after") === "SENDABLE" ? 0 : 1;
  }
  if (mode === "shell") {
    return get("shell_seen") === "1" && get("one_running") === "1" && get("stop_http") === "409" && get("reason") === "shells-present"
      && get("sent") === "0" && get("pressed_none") === "1" && get("shell_row_seen") === "1" && get("agent_running") === "1" && get("shell_alive") === "1"
      && get("retry_http") === "200" && get("retry_stopped") === "observed" && get("target_frozen") === "1" ? 0 : 1;
  }
  return 1;
}

function usage() { console.log("usage: live-subagent-stop-check.mjs [--mode twin|single|shell] [--url URL] [--host SSH] [--settle SEC] | --verdict <rc> <line>"); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const PROMPTS = {
  twin: "Launch two general-purpose subagents in parallel right now, in one single message with two Agent tool calls. Use the description `count slowly` for BOTH of them (exactly that text). Subagent one: run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls (never in the background, never combined). Subagent two: the same, but with `sleep 13`. Do not read files. When both return, reply with the single word done.",
  single: "Launch one general-purpose subagent right now with the description `count slowly` (exactly that text). Its job: run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls (never in the background, never combined). Do not read files. When it returns, reply with the single word done.",
  shell: "First, run the shell command `sleep 240.NONCE` with the Bash tool IN THE BACKGROUND (run_in_background: true) and do not wait for it. Then launch one general-purpose subagent with the description `count slowly` (exactly that text). Its job: run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls (never in the background, never combined). Do not read files. When it returns, reply with the single word done.",
};

async function main(argv) {
  if (argv[0] === "--verdict") { process.exit(verdict(argv[1], argv.slice(2).join(" "))); }
  let url = "https://desk.tailnet.example:9443";
  let host = "athenas";
  let settleSec = 30;
  let mode = "twin";
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--url") url = argv[i + 1];
    else if (argv[i] === "--host") host = argv[i + 1];
    else if (argv[i] === "--settle") settleSec = Number(argv[i + 1]);
    else if (argv[i] === "--mode") mode = argv[i + 1];
    else { usage(); process.exit(2); }
  }
  if (!MODES.includes(mode)) { usage(); process.exit(2); }
  const sh = (cmd) => execFileSync("ssh", [host, cmd], { encoding: "utf8", maxBuffer: 8 << 20 }).trim();
  let key = "";
  try { key = sh("cat ~/.rc-backend/api.key"); } catch { console.log("鍵が読めない(= 測れていない)"); process.exit(2); }
  if (!key) { console.log("鍵が空"); process.exit(2); }
  let node = "";
  try { node = sh("command -v node || ls /opt/homebrew/bin/node 2>/dev/null | head -1"); } catch { console.log("遠隔に届かない"); process.exit(3); }
  if (!node) { console.log("遠隔に node が無い"); process.exit(2); }

  let sid = "", tmuxName = "";
  try {
    const out = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs up 2>/dev/null`);
    const lines = out.split("\n").map((l) => l.trim()).filter(Boolean);
    tmuxName = lines.find((l) => /^rc-e2e-[0-9]{6,}$/.test(l)) || "";
    sid = lines.find((l) => /^[0-9a-f]{8}-[0-9a-f-]{20,}$/i.test(l)) || "";
  } catch { console.log("使い捨ての会話が建たない(= 測れていない)"); process.exit(2); }
  if (!sid || !tmuxName) { console.log("使い捨ての id か tmux 名が空"); process.exit(2); }
  console.log(`  ..  : mode=${mode} tmux=${tmuxName} sid=${sid}`);

  const H = { authorization: `Bearer ${key}`, "content-type": "application/json" };
  const getJson = async (path) => { const r = await fetch(`${url}${path}`, { headers: H }); let j = null; try { j = await r.json(); } catch { j = null; } return { status: r.status, json: j }; };
  const postJson = async (path, body) => { const r = await fetch(`${url}${path}`, { method: "POST", headers: H, body: JSON.stringify(body) }); const text = await r.text(); let j = null; try { j = JSON.parse(text); } catch { j = null; } return { status: r.status, json: j, text }; };
  const parts = [`mode=${mode}`];
  const t0 = Date.now();
  const stamp = () => `${Math.round((Date.now() - t0) / 1000)}s`;
  const fail = (step, msg) => Object.assign(new Error(msg), { step });
  let shellPatOuter = "sleep [2]40\\.999999999"; // 空撃ちしない番兵(nonce 未確定の時は何も殺さない)
  const teardown = () => { try { sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`); } catch { /* 最善努力 */ } };

  try {
    // ★nonce: `sleep 240.<6 桁>` は sleep に正当な引数で、ps の引数列に其のまま残る。素の `sleep 240` は他人の物と見分けが付かない
    //   (Codex 2026-09-07 #2)。pgrep のパターンは `[2]40` で自分自身(ssh 先の bash -c の引数)を拾わない。
    const nonce = String(100000 + Math.floor(Math.random() * 900000));
    const shellPat = `sleep [2]40\\.${nonce}`;
    shellPatOuter = shellPat;
    const shellAlive = () => sh(`pgrep -f '${shellPat}' >/dev/null && echo 1 || echo 0`);
    const sent = await postJson(`/api/sessions/${sid}/messages`, { text: PROMPTS[mode].replace("NONCE", nonce), sendId: `stop${Date.now()}` });
    console.log(`  ..  : send HTTP ${sent.status} (${stamp()})`);
    if (sent.status !== 202) throw fail("send", `send refused: ${sent.status} ${sent.text.slice(0, 120)}`);

    const wantRunning = mode === "twin" ? 2 : 1;
    let running = [];
    const deadline = Date.now() + 120_000;
    while (Date.now() < deadline) {
      const s = await getJson(`/api/sessions/${sid}/subagents`);
      running = (s.json?.subagents ?? []).filter((a) => a.state === "running" && a.description === "count slowly");
      if (running.length >= wantRunning) break;
      await sleep(10_000);
    }
    console.log(`  ..  : running=${running.length} (${stamp()})`);
    parts.push(mode === "twin" ? `two_running=${running.length >= 2 ? 1 : 0}` : `one_running=${running.length === 1 ? 1 : 0}`);
    if (running.length < wantRunning) throw fail("activity", "expected subagents never observed running");

    const dir = sh(`ls -d ~/.claude/projects/*/${sid}/subagents 2>/dev/null | head -1`);
    if (!dir) throw fail("transcript", "subagent transcript dir not found on the desk");
    const size = (id) => { const v = sh(`stat -f %z '${dir}/agent-${id}.jsonl' 2>/dev/null || echo ERR`); if (!/^\d+$/.test(v)) throw fail("stat", `stat failed for ${id}: ${v}`); return Number(v); };
    const ids = running.map((a) => a.agentId);
    let target = null, peer = null;
    if (mode === "twin") {
      const count = (id, word) => { try { const v = sh(`grep -c '${word}' '${dir}/agent-${id}.jsonl' 2>/dev/null || echo 0`); return Number(/^\d+$/.test(v) ? v : 0); } catch { return 0; } };
      const lean = ids.map((id) => ({ id, d: count(id, "sleep 13") - count(id, "sleep 12") }));
      const more13 = lean.filter((x) => x.d > 0), more12 = lean.filter((x) => x.d < 0);
      target = more13.length === 1 ? more13[0].id : null;
      peer = more12.length === 1 ? more12[0].id : null;
      parts.push(`target_chosen=${target && peer && target !== peer ? 1 : 0}`);
      console.log(`  ..  : target=${target} peer=${peer} (${lean.map((x) => `${x.id.slice(0, 8)}:${x.d > 0 ? "+" : ""}${x.d}`).join(" ")})`);
      if (!target || !peer || target === peer) throw fail("choose", "could not tell the two subagents apart by prompt");
    } else {
      target = ids[0];
    }
    if (mode === "shell") {
      // 背景シェルが本当に生きているか(親の `sleep 240`)。無ければ此の形は測れていない。
      // ★`[2]40` = pgrep が ssh 先の `bash -c` の引数(此のパターン自身)を拾わない為。素の `'sleep 240'` は自分に当たって常に 1 を返す。
      const alive = shellAlive();
      parts.push(`shell_seen=${alive === "1" ? 1 : 0}`);
      console.log(`  ..  : background shell alive=${alive} (nonce ${nonce})`);
      if (alive !== "1") throw fail("shell", "background shell never observed alive");
    }

    const st = await postJson(`/api/sessions/${sid}/subagents/${target}/stop`, {});
    const stopped = st.json?.stopped ?? null;
    parts.push(`stop_http=${st.status}`);
    if (mode === "shell") {
      parts.push(`reason=${String(st.json?.reason ?? "none")}`);
      parts.push(`sent=${st.json?.sent === true ? 1 : 0}`);
      // ★「断った」と「打っていない」は別の主張(Codex #1)。机の鍵列は driver が打った順の記録 —— パネルを開く 3 打以外が
      //   1 つでも在れば 0。★机が断りに載せたシェル行(`after.shells`)に nonce が在れば、TUI が此のシェルの行を出していた(#3/#5)。
      const keys = Array.isArray(st.json?.keys) ? st.json.keys.map(String) : [];
      const benign = new Set(["-l /tasks", "Enter", "Escape"]);
      parts.push(`pressed_none=${keys.length > 0 && keys.every((k) => benign.has(k)) ? 1 : 0}`);
      const shells = Array.isArray(st.json?.after?.shells) ? st.json.after.shells.map(String) : [];
      parts.push(`shell_row_seen=${shells.some((row) => row.includes(`240.${nonce}`)) ? 1 : 0}`);
      console.log(`  ..  : shells on panel = ${JSON.stringify(shells)}`);
    } else {
      parts.push(`stopped=${stopped === "observed" ? "observed" : String(stopped ?? "none")}`);
      if (st.status !== 200) parts.push(`reason=${String(st.json?.reason ?? "none")}`);
      if (mode === "single") parts.push(`observed_via=${String(st.json?.after?.stopObserved ?? "none")}`);
    }
    console.log(`  ..  : stop HTTP ${st.status} stopped=${stopped} reason=${st.json?.reason ?? "-"} sent=${st.json?.sent} keys=${JSON.stringify(st.json?.keys ?? [])} escapes=${st.json?.escapes ?? "-"} after=${JSON.stringify(st.json?.after ?? null)} (${stamp()})`);

    const t1 = size(target), p1 = peer ? size(peer) : 0;
    await sleep(Math.max(5, settleSec / 2) * 1000);
    const tMid = size(target), pMid = peer ? size(peer) : 0;
    await sleep(Math.max(5, settleSec / 2) * 1000);
    const t2 = size(target), p2 = peer ? size(peer) : 0;
    if (mode === "twin") {
      parts.push(`target_frozen=${t2 === t1 && tMid === t1 ? 1 : 0}`);
      parts.push(`peer_running=${pMid > p1 && p2 > pMid ? 1 : 0}`);
      console.log(`  ..  : target ${t1}->${tMid}->${t2} peer ${p1}->${pMid}->${p2} (${stamp()})`);
    } else if (mode === "single") {
      parts.push(`target_frozen=${t2 === t1 && tMid === t1 ? 1 : 0}`);
      const status = await getJson(`/api/sessions/${sid}/status`);
      const screen = String(status.json?.screen ?? "none");
      const overlay = status.json?.overlay ?? null;
      parts.push(`screen_after=${overlay ? `overlay-${overlay}` : screen}`);
      console.log(`  ..  : target ${t1}->${tMid}->${t2} screen=${screen} overlay=${overlay} (${stamp()})`);
    } else {
      parts.push(`agent_running=${tMid > t1 && t2 > tMid ? 1 : 0}`);
      const alive = shellAlive();
      parts.push(`shell_alive=${alive === "1" ? 1 : 0}`);
      console.log(`  ..  : agent ${t1}->${tMid}->${t2} shell alive=${alive} (${stamp()})`);
      // ── 対照(Codex #6): シェルを pid 名指しで殺し、同じ口を撃ち直す。断りの助言どおり今度は止まる筈。
      //    行が消えるまで TUI が少し掛かるので 10 秒ごと最長 90 秒、`shells-present` 以外が返るまで撃つ。
      try { sh(`pkill -f '${shellPat}' >/dev/null 2>&1 || true`); } catch { /* 下で alive を見る */ }
      await sleep(3000);
      console.log(`  ..  : shell killed by pid pattern, alive now=${shellAlive()} (${stamp()})`);
      let rt = null;
      for (let i = 0; i < 9; i += 1) {
        rt = await postJson(`/api/sessions/${sid}/subagents/${target}/stop`, {});
        if (rt.json?.reason !== "shells-present") break;
        await sleep(10_000);
      }
      parts.push(`retry_http=${rt?.status ?? "none"}`);
      parts.push(`retry_stopped=${rt?.json?.stopped === "observed" ? "observed" : String(rt?.json?.stopped ?? "none")}`);
      if (rt && rt.status !== 200) parts.push(`retry_reason=${String(rt.json?.reason ?? "none")}`);
      console.log(`  ..  : retry HTTP ${rt?.status} stopped=${rt?.json?.stopped} reason=${rt?.json?.reason ?? "-"} keys=${JSON.stringify(rt?.json?.keys ?? [])} after=${JSON.stringify(rt?.json?.after ?? null)} (${stamp()})`);
      const r1 = size(target);
      await sleep(Math.max(5, settleSec / 2) * 1000);
      const rMid = size(target);
      await sleep(Math.max(5, settleSec / 2) * 1000);
      const r2 = size(target);
      parts.push(`target_frozen=${r2 === r1 && rMid === r1 ? 1 : 0}`);
      console.log(`  ..  : after retry target ${r1}->${rMid}->${r2} (${stamp()})`);
    }
  } catch (e) {
    const step = (e && e.step) || "probe";
    console.log(`殻の出力: kind=ng mode=${mode} step=${step}`);
    console.log(`  !!  : ${String(e && e.message || e).split("\n")[0].slice(0, 160)}`);
    console.log("=== 判定 ===");
    teardown();
    process.exit(verdict(1, `kind=ng mode=${mode} step=${step}`));
  }

  let limited = "unknown";
  try { limited = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs limited '${sid}'`) || "unknown"; } catch { /* 訊けない */ }
  let torn = 0, retried = 0;
  try {
    sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`);
    torn = sh(`test -e ~/.rc-backend/panes/${sid}.json && echo present || echo gone`) === "gone" ? 1 : 0;
    if (!torn) {
      retried = 1;
      await sleep(3000);
      try { sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`); } catch { /* 最善努力 */ }
      torn = sh(`test -e ~/.rc-backend/panes/${sid}.json && echo present || echo gone`) === "gone" ? 1 : 0;
    }
  } catch { torn = 0; }
  if (mode === "shell") { try { sh(`pkill -f '${shellPatOuter}' >/dev/null 2>&1 || true`); } catch { /* 残骸は畳みで死ぬ筈。念の為 */ } }
  parts.push(`torn_down=${torn}`);
  parts.push(`torn_retry=${retried}`);
  parts.push(`limited=${limited}`);
  const line = `kind=ok ${parts.join(" ")}`;
  console.log(`殻の出力: ${line}`);
  console.log("=== 判定 ===");
  const rc = verdict(0, line);
  console.log(rc === 0 ? "閉じた(0)" : rc === 3 ? "測っていない(3)" : "赤(1)");
  process.exit(rc);
}

const isMain = process.argv[1] && /live-subagent-stop-check\.mjs$/.test(process.argv[1]);
if (isMain) main(process.argv.slice(2));
