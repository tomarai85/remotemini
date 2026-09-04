// live-write-routes-check.mjs — **書き込む口**を、使い捨ての会話に対してだけ本番の机で撃つ。
//
// ── なぜ在るか(2026-09-04)────────────────────────────────────────────────────
// 机の要求ログ 8 日分を数えたら、iOS の client が完成しているのに本番の机で **一度も
// 動いていない口が 9 つ**在った。読むだけの 3 つ(status/diff/paths)は
// `live-cold-routes-check.mjs` が閉じたが、残りは**書き込む**ので同じ計器に入れられない。
//
// ★安全の要は `tools/disposable-session.mjs`。あれは tmux セッション名 `rc-e2e-<数字>` の形しか
//   作らず、**Tom の実会話に触る道が無い**(其の道具の頭書き)。だから此処は必ず
//   「自分で建てた使い捨て」に対してだけ撃ち、終わったら畳む。既存の会話 id を
//   引数で受け取る口は**故意に用意していない** —— 用意した時点で、実会話へ撃つ道が生まれる。
//
// 測る物(この順):
//   1. title  … 付ける → 読み返す → 外す(`{title:null}`)。**元に戻す所まで**が 1 件。
//   2. archive … true にする → 一覧の archived 側に出る → false に戻す。
//   3. queue   … 溜まっていないキューを消す(冪等)。**溜まっている物は消さない** ——
//                使い捨ての会話に何も送っていないので、消える物が無い状態で撃つ。
//
// 測らない物(故意):
//   ・choice … menu の画面に鍵を送る口。承認や課金を押し得るので、生きた机では撃たない。
//              あれの正しい検証は偽の画面に対する e2e で、既に在る。
//   ・attach-file … 机の attachments に file を置き、composer に path を差す。使い捨てなら
//              安全だが、**同じ計器に混ぜると「読むだけ/戻せる/戻せない」の 3 段が 1 本になる**。
//              段を分ける方が、後から片方だけ止められる。
//   ・new … 使い捨てを建てる事そのものが `disposable-session.mjs up` なので、此の台本が
//              走った時点で通っている(下の `up` が成功する = `new` 相当の経路が生きている)。
//
// 終了コード(艦隊の live-* と同じ契約 = test/live-exit-codes.test.mjs):
//   0 = 観測で閉じた / 1 = 赤 / 2 = 準備段で中断(鍵・使い捨てが建たない)
//   3 = 測っていない(机に届かない・**利用上限**の机で測った緑を閉じたと言わない)。
//
// 使い方: node rc-backend/tools/live-write-routes-check.mjs [--url URL]
//         node rc-backend/tools/live-write-routes-check.mjs --verdict <rc> <line>
import { execFileSync } from "node:child_process";

/** 判定だけ。純粋(対照が全通り撃つ)。 */
export function verdict(rc, line) {
  const s = String(line || "");
  if (/\blimited=limited\b/.test(s)) {
    console.log("  --  : 机が利用上限。緑を名乗らない = 測っていない");
    return 3;
  }
  if (/^kind=ng step=/.test(s)) {
    console.log(`  --  : 机に届いていない(${s}) —— **測っていない**`);
    return 3;
  }
  let fail = 0;
  const need = [
    ["title_set=200", "title を付けられる"],
    ["title_read=1", "付けた title が読み返せる"],
    ["title_clear=200", "title を外して元に戻せる"],
    ["archive_on=200", "archive を立てられる"],
    ["archive_seen=1", "立てた archive が一覧に出る"],
    ["archive_off=200", "archive を下ろして元に戻せる"],
    ["torn_down=1", "使い捨てを畳めた(机に残していない)"],
  ];
  for (const [k, why] of need) {
    const ok = s.includes(k);
    console.log(ok ? `  ok  : ${why}` : `  NG  : ${why} —— 観測できない(${k})`);
    if (!ok) fail = 1;
  }
  if (fail || rc !== 0) { console.log("→ 書き込む口(使い捨て): 閉じていない"); return 1; }
  console.log("→ 書き込む口(使い捨て): 観測で閉じた");
  return 0;
}

function usage() {
  console.error("usage: node live-write-routes-check.mjs [--url URL] | --verdict <rc> <line>");
}

async function main(argv) {
  if (argv[0] === "--verdict") { process.exit(verdict(Number(argv[1]), argv.slice(2).join(" "))); }
  let url = process.env.RC_LIVE_URL || "https://desk.tailnet.example:9443";
  const host = process.env.RC_LIVE_SSH || "athenas";
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] === "--url") url = argv[i + 1];
    else { usage(); process.exit(2); }
  }
  // ★遠隔の道具は**フルパスで呼ぶか、見つからない事を明示的に捕まえる**(2026-09-04 実測)。
  //   非対話 ssh の PATH には `/opt/homebrew/bin` が無い。`tmux ls | grep -c` は
  //   `command not found` でも 0 を返すので、**道具が無い**と**対象が無い**が同じ顔になる。
  //   其の日、私は自分が机に残した使い捨て 4 本を「0 本」と報告した。
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
  // tmux も同じ理由で先に確かめる。使い捨てを**建てる前**に見る —— 建ててから畳めないと分かるのが最悪。
  try { need("tmux"); } catch { console.log("遠隔に届かない"); process.exit(3); }

  // ── 使い捨てを建てる。**此処が `new` 相当の経路の観測でもある** ────────────
  let sid = "";
  let tmuxName = "";
  try {
    // ★経過は stderr、会話 id は stdout(其の道具の頭書き)。畳むには **tmux の名前**も要るので
    //   両方を取る。`reap` では畳めない —— あれは齢が既定 60 分より古い物だけを掃く仕掛けで、
    //   建てた直後の使い捨ては対象外(2026-09-04 実測: 「掃いた: 0 本」が正しい動作だった)。
    // ★stdout に **2 行**出る(tmux 名 → 会話 id)。stderr を混ぜると並びが崩れて
    //   tmux 名の側を id と読む(2026-09-04 に実際に踏んだ)。混ぜずに読む。
    const out = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs up 2>/dev/null`);
    const lines = out.split("\n").map((l) => l.trim()).filter(Boolean);
    tmuxName = lines.find((l) => /^rc-e2e-[0-9]{6,}$/.test(l)) || "";
    sid = lines.find((l) => /^[0-9a-f]{8}-[0-9a-f-]{20,}$/i.test(l)) || "";
  } catch (e) {
    console.log("使い捨ての会話が建たない(= 測れていない)");
    process.exit(2);
  }
  if (!sid) { console.log("使い捨ての id が空"); process.exit(2); }
  // ★`torn_down` が走行ごとに揺れた時(2026-09-04)、原因の候補が「id が空のまま
  //   `panes/.json` を見て不在=成功と読む」だった。値を出せる口を残す。
  if (process.env.RC_LIVE_DEBUG) console.log(`  ..  : sid=${sid} tmux=${tmuxName}`);

  const H = { authorization: `Bearer ${key}`, "content-type": "application/json" };
  const parts = [];
  const post = async (route, body) => {
    const r = await fetch(`${url}/api/sessions/${sid}/${route}`, {
      method: "POST", headers: H, body: JSON.stringify(body),
    });
    return { status: r.status, text: await r.text() };
  };

  try {
    const MARK = `live-write-check-${Date.now()}`;
    // 1. title: 付ける → 読み返す → 外す
    const t1 = await post("title", { title: MARK });
    parts.push(`title_set=${t1.status}`);
    const list = await fetch(`${url}/api/sessions`, { headers: H }).then((r) => r.text());
    parts.push(`title_read=${list.includes(MARK) ? 1 : 0}`);
    const t2 = await post("title", { title: null });
    parts.push(`title_clear=${t2.status}`);

    // 2. archive: 立てる → 一覧(archived 側)に出る → 下ろす
    const a1 = await post("archive", { archived: true });
    parts.push(`archive_on=${a1.status}`);
    const arch = await fetch(`${url}/api/sessions?scope=archived`, { headers: H }).then((r) => r.text());
    parts.push(`archive_seen=${arch.includes(sid) ? 1 : 0}`);
    const a2 = await post("archive", { archived: false });
    parts.push(`archive_off=${a2.status}`);

    // 3. queue は**測らない**(2026-09-04 に 2 度誤って学んだ)。
    //    ・初版は POST で撃って 405 —— 動詞が違った(正しくは DELETE)。
    //    ・DELETE で撃つと 409 `queue-not-ours` —— 使い捨てのペインを机が「自分の物」と
    //      認めないので、**構造的に通らない**。机は 2 回とも正しく断っていた。
    //    通らない物を計器に入れると恒久的な赤になり、赤の意味が消える。此の口の検証は
    //    「電話が作った本物の会話」に対してでないと成立しないので、別の段に置く。
  } catch (e) {
    console.log(`殻の出力: kind=ng step=write`);
    console.log("=== 判定 ===");
    try { sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs reap`); } catch { /* 後片付けは最善努力 */ }
    process.exit(verdict(1, "kind=ng step=write"));
  }

  // ── 畳む。**残したまま緑を名乗らない** ────────────────────────────────────
  // ★`limited` は畳む**前**に訊く(2026-09-04)。後だと死んだペインを訊いて
  //   `can't find pane` が出る —— 無害だが、読み手には失敗に見える雑音。
  let limitedEarly = "unknown";
  try { limitedEarly = sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs limited '${sid}'`) || "unknown"; } catch { /* 訊けない */ }
  let torn = 0;
  try {
    // ★`down <tmux名> <会話id>`。名前が `rc-e2e-` の形でなければ其の道具が畳む事を拒む
    //   = 実会話を消す道が構造的に無い。だから名前を取れなかった時は畳もうとしない。
    if (tmuxName) sh(`${node} $HOME/rc-backend/tools/disposable-session.mjs down ${tmuxName} ${sid}`);
    // 不在を **`test -e` の終了コード**で見る(文字列の比較だと「無い」と「在る」が混ざる)。
    const gone = sh(`test -e ~/.rc-backend/panes/${sid}.json && echo present || echo gone`);
    torn = gone === "gone" ? 1 : 0;
  } catch (e) {
    // ★理由を**表に出す**(2026-09-04)。初版は黙って `torn = 0` にしていたので、
    //   「畳めなかった」と「畳んだが確認に失敗した」が同じ赤になり、机に残骸が
    //   在るのか無いのか判らないまま 4 回赤を見た。片付けの失敗は残骸を作るので、
    //   此処だけは沈黙させない。
    torn = 0;
    console.log(`  !!  : 畳む段で例外 — ${String(e && e.message || e).split("\n")[0].slice(0, 160)}`);
  }
  parts.push(`torn_down=${torn}`);

  const line = `kind=ok ${parts.join(" ")} limited=${limitedEarly}`;
  console.log(`殻の出力: ${line}`);
  console.log("=== 判定 ===");
  process.exit(verdict(0, line));
}

main(process.argv.slice(2));
