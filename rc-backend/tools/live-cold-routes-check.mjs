// live-cold-routes-check.mjs — **本番の机で一度も叩かれていない口**を、読むだけで実際に撃つ。
//
// ── なぜ在るか(2026-09-04 の実測)────────────────────────────────────────────
// 机の要求ログ 8 日分(2026-08-27〜09-04、電話からの 1,172 件)を数えたら、電話が実際に
// 叩いていたのは **8 種類だけ**だった:
//   /api/account 477 / /api/sessions 450 / poll 158 / history 38 / digest 32 /
//   messages 11 / interrupt 5 / account/select 1
// 一方、iOS 側の client が完成している口のうち **9 つが 0 件** —— diff / status / paths /
// title / archive / clearQueue / choice / attach-file / new。検査は緑で、e2e も緑だが、
// **偽 tmux と作り物の机**を通っているだけで、本番の机では一度も走っていなかった。
//
// ★之は「壊れている」の証拠ではない。実際 2026-09-04 に手で撃ったら 3 口とも 200 で返った
//   (diff は 36,471 byte の実データ)。**沈黙は不在の証拠であって故障の証拠ではない** ——
//   撃つまでどちらか分からない、という状態が問題だった。此の台本は其の状態を無くす。
//
// 測る物 = 読むだけの口(GET)が本番の机で 200 を返し、**形が電話の型と噛み合う**か。
// 測らない物 = 書き込む口(new / title / archive / choice / clearQueue / attach-file)。
//   あれらは机に副作用を作るので、同じ計器には入れない。別の判断が要る。
//
// 終了コード(艦隊の live-* と同じ契約 = test/live-exit-codes.test.mjs):
//   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(鍵・会話が無い)
//   3 = 測っていない(机に届かない・会話が 0 本・**利用上限**の机で測った緑を閉じたと言わない)。
//
// 使い方: node rc-backend/tools/live-cold-routes-check.mjs [--url URL] [--sid ID]
//         node rc-backend/tools/live-cold-routes-check.mjs --verdict <rc> <line>
import { execFileSync } from "node:child_process";

const EXIT = { closed: 0, red: 1, aborted: 2, unmeasured: 3 };

/** 判定だけ。純粋(対照が全通り撃つ)。 */
export function verdict(rc, line) {
  const s = String(line || "");
  if (/\blimited=limited\b/.test(s)) {
    console.log("  --  : 机が利用上限。読むだけの口だが机の状態が普通でない = 測っていない");
    return 3;   // 上限 = 測っていない。★数字で書く(定数に隠すと live census の静的検査が見えない)
  }
  if (/^kind=ng step=/.test(s)) {
    console.log(`  --  : 机に届いていない(${s}) —— **測っていない**`);
    return 3;
  }
  let fail = 0;
  for (const r of ["status", "diff", "paths"]) {
    const ok = new RegExp(`\\b${r}=200\\b`).test(s);
    console.log(ok ? `  ok  : ${r} が 200 で返る` : `  NG  : ${r} が 200 でない`);
    if (!ok) fail = 1;
  }
  // 形の確認: 電話の型が要求する鍵が在るか(200 だが空の body、を緑にしない)
  for (const [k, why] of [["shape_status=1", "status に screen が在る"],
                          ["shape_diff=1", "diff に files が在る"],
                          ["shape_paths=1", "paths に paths が在る"]]) {
    // ★欄は丸ごと一致(2026-09-06: `includes("x=1")` は `x=10` にも当たる。completion 計器の対照が捕まえた)。
    const ok = new RegExp("(^|\\s)" + k.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "(\\s|$)").test(s);
    console.log(ok ? `  ok  : ${why}` : `  NG  : ${why.replace("在る", "無い")}(200 だが中身が噛み合わない)`);
    if (!ok) fail = 1;
  }
  if (fail || rc !== 0) { console.log("→ 冷たい口(読むだけ): 閉じていない"); return EXIT.red; }
  console.log("→ 冷たい口(読むだけ): 観測で閉じた");
  return EXIT.closed;
}

function usage() {
  console.error("usage: node live-cold-routes-check.mjs [--url URL] [--sid ID] | --verdict <rc> <line>");
}

async function main(argv) {
  if (argv[0] === "--verdict") { process.exit(verdict(Number(argv[1]), argv.slice(2).join(" "))); }
  let url = process.env.RC_LIVE_URL || "https://desk.tailnet.example:9443";
  let sid = "";
  const host = process.env.RC_LIVE_SSH || "athenas";
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--url") url = argv[i + 1];
    else if (argv[i] === "--sid") sid = argv[i + 1];
    else { usage(); process.exit(2); }
  }
  const sh = (cmd) => execFileSync("ssh", [host, cmd], { encoding: "utf8" }).trim();
  if (!sid) {
    // 登録簿の一番新しい会話。id は印字しない。
    try {
      sid = sh("ls -t ~/.rc-backend/panes/*.json 2>/dev/null | head -1 | xargs -n1 basename | sed 's/\\.json$//'");
    } catch { sid = ""; }
  }
  if (!sid) { console.log("登録簿に会話が無い(机に会話が 0 本)= 測れていない"); process.exit(EXIT.unmeasured); }
  let key = "";
  try { key = sh("cat ~/.rc-backend/api.key"); } catch { console.log("鍵が読めない"); process.exit(EXIT.aborted); }
  if (!key) { console.log("鍵が空"); process.exit(EXIT.aborted); }

  const parts = [];
  const shapes = [];
  for (const [route, shapeKey] of [["status", "screen"], ["diff", "files"], ["paths", "paths"]]) {
    try {
      const res = await fetch(`${url}/api/sessions/${sid}/${route}`, {
        headers: { authorization: `Bearer ${key}` },
      });
      const text = await res.text();
      parts.push(`${route}=${res.status}`);
      let ok = 0;
      try { ok = Object.prototype.hasOwnProperty.call(JSON.parse(text), shapeKey) ? 1 : 0; } catch { ok = 0; }
      shapes.push(`shape_${route}=${ok}`);
    } catch (e) {
      console.log(`殻の出力: kind=ng step=${route}`);
      console.log("=== 判定 ===");
      process.exit(verdict(1, `kind=ng step=${route}`));
    }
  }
  // 上限の告知は訊くだけ(読むだけの口なので赤を隠さない、live-search-check と同じ扱い)
  let limited = "unknown";
  try {
    const node = sh("command -v node || ls /opt/homebrew/bin/node 2>/dev/null | head -1");
    limited = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs limited '${sid}'`) || "unknown";
  } catch { limited = "unknown"; }
  const line = `kind=ok ${parts.join(" ")} ${shapes.join(" ")} limited=${limited}`;
  console.log(`殻の出力: ${line}`);
  console.log("=== 判定 ===");
  process.exit(verdict(0, line));
}

main(process.argv.slice(2));
