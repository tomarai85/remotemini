// live-composer-guard-check.mjs — 「人の下書きが残った入力欄へ電話から送ると何が起きるか」を、
// **本番の机**に対して、**使い捨ての会話にだけ**撃って観測する。
//
// ── なぜ在るか(2026-09-04 の Critical、配備の検証)──────────────────────────
// `#sendExclusive` は画面が SENDABLE かだけを見て、入力欄が空かを見ずに**追記して Enter**を
// 押していた。机に `deploy production` が残った状態で電話から `run tests` を送ると
// `deploy productionrun tests` が走る。送信後の確認は「印が現れ入力欄が空になった」を
// 見るので、電話には**成功が返り得た** —— 確認していたのは足した分であって全文ではない。
//
// ★配備の前に本番で実測した(2026-09-04 21:44、使い捨ての `rc-e2e-…`):
//     ❯ deploy production            ← 人の下書きを再現
//     POST …/messages {"text":"run tests"}
//     → HTTP 202 {"delivered":"verified","display":{"kind":"ok","text":"Sent"}}
//   合成された命令が通り、電話には「Sent」が返った。**之が直った事の証明は、
//   同じ手順で 409 `composer-busy` が返る事**でしか出来ない。単体検査は偽の tmux に
//   対する物なので、本番の TUI が同じ形を出すかは別の問いとして残る。
//
// ★安全の要は `tools/disposable-session.mjs`(tmux 名 `rc-e2e-<数字>` しか作らない)。
//   既存の会話 id を受け取る口は**故意に用意していない** —— 用意した時点で Tom の
//   実会話へ打鍵する道が生まれる。終わったら必ず畳み、畳めなければ表に出す。
//
// 測る物:
//   1. 人の下書きが在る入力欄へ送ると **409 `composer-busy`**(打鍵0)
//   2. 其の断りが**電話に出せる文**を持つ(`error` が空でない)
//   3. 断った後も**下書きが入力欄に残っている**(消していない)
//   4. 下書きを消せば同じ会話へ**普通に送れる**(壁を作っただけではない)
//
// 測らない物(故意):
//   ・`composer-raced`(撮影〜Enter の間に人が打つ形)。外から狙って起こすには
//     机の TUI へ ms 単位で割り込む必要が在り、其の割り込み自体が此の計器の
//     測っている物より危うい。単体側(`inject.test.mjs`)が変異で押さえている。
//
// 終了コード(艦隊の live-* と同じ契約 = test/live-exit-codes.test.mjs):
//   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(鍵・使い捨てが建たない)
//   3 = 測っていない(机に届かない・**利用上限**の机で測った緑を閉じたと言わない)
//
// 使い方: node rc-backend/tools/live-composer-guard-check.mjs [--url URL]
//         node rc-backend/tools/live-composer-guard-check.mjs --verdict <rc> <line>
import { execFileSync } from "node:child_process";

/** 判定だけ。純粋(対照が全通り撃つ)。 */
export function verdict(rc, line) {
  const s = String(line || "");
  if (/\blimited=limited\b/.test(s)) {
    console.log("  --  : 机が利用上限。緑を名乗らない = 測っていない");
    return 3;
  }
  if (/^kind=ng step=/.test(s)) {
    console.log(`  --  : 机に届いていない(${s})—— **測っていない**`);
    return 3;
  }
  let fail = 0;
  const need = [
    ["refused=409", "人の下書きが在れば断る(合成された命令を作らない)"],
    ["reason=composer-busy", "断りの理由が composer-busy"],
    ["message=1", "断りが電話に出せる文を持つ"],
    ["draft_kept=1", "断った後も下書きが残っている(消していない)"],
    ["after_clear=202", "下書きを消せば普通に送れる(壁を作っただけではない)"],
    ["torn_down=1", "使い捨てを畳めた(机に残していない)"],
  ];
  for (const [k, why] of need) {
    const ok = s.includes(k);
    console.log(ok ? `  ok  : ${why}` : `  NG  : ${why} —— 観測できない(${k})`);
    if (!ok) fail = 1;
  }
  if (fail || rc !== 0) { console.log("→ 入力欄の持ち主の確認: 閉じていない"); return 1; }
  console.log("→ 入力欄の持ち主の確認: 観測で閉じた");
  return 0;
}

function usage() {
  console.error("usage: node live-composer-guard-check.mjs [--url URL] | --verdict <rc> <line>");
}

async function main(argv) {
  if (argv[0] === "--verdict") { process.exit(verdict(Number(argv[1]), argv.slice(2).join(" "))); }
  let url = process.env.RC_LIVE_URL || "https://desk.tailnet.example:9443";
  const host = process.env.RC_LIVE_SSH || "athenas";
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--url") url = argv[i + 1];
    else { usage(); process.exit(2); }
  }
  // ★遠隔の道具はフルパスで呼ぶか、不在を明示的に捕まえる(2026-09-04 実測)。
  //   非対話 ssh の PATH に `/opt/homebrew/bin` は無く、`command not found` は
  //   counter を通すと「対象 0 件」と同じ顔になる。
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
  let tmux = "";
  try { node = need("node"); tmux = need("tmux"); } catch { console.log("遠隔に届かない"); process.exit(3); }

  let sid = "";
  let tmuxName = "";
  try {
    // stdout に 2 行(tmux 名 → 会話 id)。stderr を混ぜると並びが崩れる。
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
    const r = await fetch(`${url}/api/sessions/${sid}/messages`, {
      method: "POST", headers: H, body: JSON.stringify(body),
    });
    return { status: r.status, text: await r.text() };
  };
  const parts = [];
  const DRAFT = "deploy production";

  try {
    const pane = sh(`${tmux} list-panes -t ${tmuxName} -F '#{pane_id}' | head -1`);
    if (!pane) { console.log("ペインが取れない"); process.exit(2); }

    // 1. 人が机で打った下書きを再現する。**Enter は押さない**。
    sh(`${tmux} send-keys -t ${pane} -l -- ${JSON.stringify(DRAFT)}`);
    await new Promise((r) => setTimeout(r, 1500));

    // 2. 電話から送る。合成された命令が走ってはいけない。
    const refused = await post({ text: "run tests", sendId: `guard${Date.now()}` });
    parts.push(`refused=${refused.status}`);
    let body = {};
    try { body = JSON.parse(refused.text); } catch { /* 読めなければ空のまま */ }
    if (body && typeof body.reason === "string") parts.push(`reason=${body.reason}`);
    parts.push(`message=${body && typeof body.error === "string" && body.error.length > 20 ? 1 : 0}`);

    // 3. 断った後も下書きが残っているか(消していない事の確認)。
    await new Promise((r) => setTimeout(r, 800));
    const screen = sh(`${tmux} capture-pane -t ${pane} -p`);
    parts.push(`draft_kept=${screen.includes(DRAFT) ? 1 : 0}`);

    // 4. 下書きを消せば普通に送れる(断りが行き止まりでない事)。
    //    ★Escape は入力欄を空にする(此の repo の実測)。承認画面では撃たない ——
    //      使い捨ての会話は起動直後で選択待ちにならないので、此処では安全。
    sh(`${tmux} send-keys -t ${pane} Escape`);
    await new Promise((r) => setTimeout(r, 1200));
    const ok = await post({ text: "hello", sendId: `guard${Date.now()}b` });
    parts.push(`after_clear=${ok.status}`);
  } catch (e) {
    console.log(`殻の出力: kind=ng step=probe`);
    console.log("=== 判定 ===");
    try { sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`); } catch { /* 最善努力 */ }
    process.exit(verdict(1, "kind=ng step=probe"));
  }

  // ★`limited` は畳む**前**に訊く(死んだペインを訊くと雑音が出る)。
  let limited = "unknown";
  try { limited = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs limited '${sid}'`) || "unknown"; } catch { /* 訊けない */ }
  let torn = 0;
  try {
    sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`);
    torn = sh(`test -e ~/.rc-backend/panes/${sid}.json && echo present || echo gone`) === "gone" ? 1 : 0;
  } catch (e) {
    torn = 0;
    console.log(`  !!  : 畳む段で例外 — ${String(e && e.message || e).split("\n")[0].slice(0, 160)}`);
  }
  parts.push(`torn_down=${torn}`);

  const line = `kind=ok ${parts.join(" ")} limited=${limited}`;
  console.log(`殻の出力: ${line}`);
  console.log("=== 判定 ===");
  process.exit(verdict(0, line));
}

main(process.argv.slice(2));
