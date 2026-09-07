// live-subagent-stop-check.mjs — 電話の口 `POST /api/sessions/:id/subagents/:agentId/stop` が、**本番の机**で同名の
// subagent 2 本のうち**名指した 1 本だけ**を止め、もう 1 本が走り続ける事を、使い捨ての会話にだけ仕事をさせて観測する
// (対照表 #8 の後半 c3)。
//
// ── なぜ在るか(2026-09-06)────────────────────────────────────────────────────
// 停止は「パネルを開く → 印を動かす → 詳細で照合 → x」の打鍵列で、計画(`panelstop.mjs`)と driver
// (`panelstop-driver.mjs`)は偽 tmux の模型で緑だが、模型は本物の TUI ではない(描画の遅れ・詳細画面の形・x の効き目は
// 実機で 1 回も見ていない)。単体検査の緑を「効く」と読まない(2026-08 の教訓: gate は unit で 7/7、live で発火 0)。
// だから本番の机に**同じ説明文で prompt の違う 2 本**を起こし、電話の口で片方を名指して止め、
//   (a) 口が `stopped:"observed"` を返す (b) 止めた方の転写が凍る (c) もう片方の転写は伸び続ける
// を見る。(b)(c) は転写の**大きさの変化**で読む(列挙の生死判定は mtime の鮮度なので、止めた直後は 15 分 running のまま)。
//
// 手順(全部 rc-e2e-<数字> の使い捨て会話に閉じる):
//   1. `disposable-session.mjs up`(rc-claude 経由 = 電話と同じ起動)
//   2. 電話の口 `POST /messages` で「同じ説明文 `count slowly` の subagent を 2 本並列で起こせ(片方は sleep 12 × 10、
//      もう片方は sleep 13 × 10)」を送る
//   3. `GET /subagents` を 10 秒ごとに読み、running が 2 本になるのを待つ(最長 120 s)
//   4. 目標 = 転写に `sleep 13` を含む方(机の転写を ssh で読む)。もう片方が peer
//   5. `POST /subagents/<target>/stop {}` → HTTP と `stopped` / `reason` を記録
//   6. 30 秒置いて 2 本の転写の大きさを比べる: 目標は凍り(差 0)、peer は伸びる(差 > 0)
//   7. 畳む(残った peer は畳みで死ぬ)。畳めた事は確かめてから名乗る
//
// 測る物(全欄が揃って初めて 0):
//   two_running=1    同名 2 本が running で見えた
//   target_chosen=1  prompt で目標を選べた
//   stop_http=200    口が 200 を返した
//   stopped=observed 口が「x を押して同じ詳細が消えた」と言った
//   target_frozen=1  止めた方の転写が 30 秒で伸びなかった
//   peer_running=1   もう片方の転写が 30 秒で伸びた
//   torn_down=1      畳めた
// 断りが返った時は `stop_http=409 reason=<語>` を記録して赤(打鍵が無かった事は口の `sent` が言う)。
//
// 終了コード(艦隊の live-* と同じ契約 = test/live-exit-codes.test.mjs):
//   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(鍵・使い捨てが建たない)/ 3 = 測っていない(机に届かない・利用上限の机)
//
// 使い方: node rc-backend/tools/live-subagent-stop-check.mjs [--url URL] [--host SSH] [--settle SEC]
//         node rc-backend/tools/live-subagent-stop-check.mjs --verdict <rc> <line>
import { execFileSync } from "node:child_process";

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
  if (get("kind") === "ng") return 3;                 // 準備段・机に届かない・活動が起きない = 測っていない
  if (Number(rc) !== 0) return 1;
  if (get("limited") === "limited" || get("limited") === "unknown") return 3;   // 訊けなかった机の緑を閉じたと言わない
  if (get("kind") !== "ok" || dup) return 1;
  const ok = get("two_running") === "1" && get("target_chosen") === "1" && get("stop_http") === "200"
    && get("stopped") === "observed" && get("target_frozen") === "1" && get("peer_running") === "1" && get("torn_down") === "1";
  return ok ? 0 : 1;
}

function usage() { console.log("usage: live-subagent-stop-check.mjs [--url URL] [--host SSH] [--settle SEC] | --verdict <rc> <line>"); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main(argv) {
  if (argv[0] === "--verdict") { process.exit(verdict(argv[1], argv.slice(2).join(" "))); }
  let url = "https://desk.tailnet.example:9443";
  let host = "athenas";
  let settleSec = 30;
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--url") url = argv[i + 1];
    else if (argv[i] === "--host") host = argv[i + 1];
    else if (argv[i] === "--settle") settleSec = Number(argv[i + 1]);
    else { usage(); process.exit(2); }
  }
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
  console.log(`  ..  : tmux=${tmuxName} sid=${sid}`);

  const H = { authorization: `Bearer ${key}`, "content-type": "application/json" };
  const getJson = async (path) => {
    const r = await fetch(`${url}${path}`, { headers: H });
    let j = null; try { j = await r.json(); } catch { j = null; }
    return { status: r.status, json: j };
  };
  const postJson = async (path, body) => {
    const r = await fetch(`${url}${path}`, { method: "POST", headers: H, body: JSON.stringify(body) });
    let j = null; const text = await r.text(); try { j = JSON.parse(text); } catch { j = null; }
    return { status: r.status, json: j, text };
  };
  const parts = [];
  const t0 = Date.now();
  const stamp = () => `${Math.round((Date.now() - t0) / 1000)}s`;
  const fail = (step, msg) => Object.assign(new Error(msg), { step });

  try {
    const prompt = "Launch two general-purpose subagents in parallel right now, in one single message with two Agent tool calls. Use the description `count slowly` for BOTH of them (exactly that text). Subagent one: run the shell command `sleep 12` using the Bash tool, ten times in a row, as ten separate sequential Bash tool calls (never in the background, never combined). Subagent two: the same, but with `sleep 13`. Do not read files. When both return, reply with the single word done.";
    const sent = await postJson(`/api/sessions/${sid}/messages`, { text: prompt, sendId: `stop${Date.now()}` });
    console.log(`  ..  : send HTTP ${sent.status} (${stamp()})`);
    if (sent.status !== 202) throw fail("send", `send refused: ${sent.status} ${sent.text.slice(0, 120)}`);

    let running = [];
    const deadline = Date.now() + 120_000;
    while (Date.now() < deadline) {
      const s = await getJson(`/api/sessions/${sid}/subagents`);
      running = (s.json?.subagents ?? []).filter((a) => a.state === "running" && a.description === "count slowly");
      if (running.length >= 2) break;
      await sleep(10_000);
    }
    console.log(`  ..  : running=${running.length} (${stamp()})`);
    parts.push(`two_running=${running.length >= 2 ? 1 : 0}`);
    if (running.length < 2) throw fail("activity", "two same-description subagents never observed running");

    // 目標 = 転写に sleep 13 を含む方。転写の置き場は机側で探す(projects/<slug>/<sid>/subagents/agent-<id>.jsonl)。
    const dir = sh(`ls -d ~/.claude/projects/*/${sid}/subagents 2>/dev/null | head -1`);
    if (!dir) throw fail("transcript", "subagent transcript dir not found on the desk");
    // 目標 = 転写で `sleep 13` の行数が `sleep 12` より多い方、peer = 其の逆、が**丁度 1 本ずつ**(Codex c3 #10 の後の実測
    //   2026-09-07: 親が書く subagent の prompt には両方の語が出る事が在るので「含む/含まない」では選べない。道具呼び出しの行が
    //   片方に偏る事で見分ける。同数 / 逆転が無い / 2 本とも同じ側なら選ばない)。
    const ids = running.map((a) => a.agentId);
    const count = (id, word) => { try { const v = sh(`grep -c '${word}' '${dir}/agent-${id}.jsonl' 2>/dev/null || echo 0`); return Number(/^\d+$/.test(v) ? v : 0); } catch { return 0; } };
    const lean = ids.map((id) => ({ id, d: count(id, "sleep 13") - count(id, "sleep 12") }));
    const more13 = lean.filter((x) => x.d > 0), more12 = lean.filter((x) => x.d < 0);
    const target = more13.length === 1 ? more13[0].id : null;
    const peer = more12.length === 1 ? more12[0].id : null;
    parts.push(`target_chosen=${target && peer && target !== peer ? 1 : 0}`);
    console.log(`  ..  : target=${target} peer=${peer} (${lean.map((x) => `${x.id.slice(0, 8)}:${x.d > 0 ? "+" : ""}${x.d}`).join(" ")})`);
    if (!target || !peer || target === peer) throw fail("choose", "could not tell the two subagents apart by prompt");

    // 大きさは stat が答えた時だけ数字(失敗を 0 に丸めると「凍った」に化ける)。
    const size = (id) => { const v = sh(`stat -f %z '${dir}/agent-${id}.jsonl' 2>/dev/null || echo ERR`); if (!/^\d+$/.test(v)) throw fail("stat", `stat failed for ${id}: ${v}`); return Number(v); };
    const t0s = size(target), p0s = size(peer);
    const st = await postJson(`/api/sessions/${sid}/subagents/${target}/stop`, {});
    const stopped = st.json?.stopped ?? null;
    parts.push(`stop_http=${st.status}`);
    parts.push(`stopped=${stopped === "observed" ? "observed" : String(stopped ?? "none")}`);
    if (st.status !== 200) parts.push(`reason=${String(st.json?.reason ?? "none")}`);
    console.log(`  ..  : stop HTTP ${st.status} stopped=${stopped} reason=${st.json?.reason ?? "-"} keys=${JSON.stringify(st.json?.keys ?? [])} escapes=${st.json?.escapes ?? "-"} after=${JSON.stringify(st.json?.after ?? null)} (${stamp()})`);

    // 止めた方は**押した直後の大きさ**から一度も伸びない / もう片方は**2 区間とも**伸びる(1 度だけの追記で終わる形を通さない)。
    const t1 = size(target), p1 = size(peer);
    await sleep(Math.max(5, settleSec / 2) * 1000);
    const tMid = size(target), pMid = size(peer);
    await sleep(Math.max(5, settleSec / 2) * 1000);
    const t2 = size(target), p2 = size(peer);
    parts.push(`target_frozen=${t2 === t1 && tMid === t1 ? 1 : 0}`);
    parts.push(`peer_running=${pMid > p1 && p2 > pMid ? 1 : 0}`);
    console.log(`  ..  : target ${t0s}->${t1}->${tMid}->${t2} peer ${p0s}->${p1}->${pMid}->${p2} (${stamp()})`);
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
