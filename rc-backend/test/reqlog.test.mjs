// `src/reqlog.mjs` = 常設のログに 1リクエスト1行(DESIGN §3-U)。
//
// 測っているのは2つで、重いのは後者:
//   ① 行が**必ず1本出る**(応答の種類によらず。SSE も、頭を書く前に切れた要求も)
//   ② 行に**中身が乗らない**(本文・生のパス・問い合わせ文字列・自由文の理由・長い sessionId)
//
// ★②は「今の実装が漏らさない」だけでは足りない。漏らす形に**戻した時に赤くなる**事まで
//   測る(下の陰性対照)。§2.20 で書いた通り、通った事と何も見ていない事は区別が要る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { EventEmitter } from "node:events";
import {
  attachRequestLog, markResult, noteBody, pathShape, sessionOf, token, errSlug, SESSION_ROUTE_RE,
} from "../src/reqlog.mjs";
import { stripComments } from "./jssrc.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SERVER_SRC = readFileSync(join(ROOT, "src", "server.mjs"), "utf8");
const REQLOG_SRC = readFileSync(join(ROOT, "src", "reqlog.mjs"), "utf8");

const SERVER_CODE = stripComments(SERVER_SRC);

/** 応答の真似。`writeHead` を持つだけの物で足りる(仕掛けが差し替えるのはそこ)。 */
function fakeRes() {
  const r = new EventEmitter();
  r.writeHead = () => r;
  return r;
}

/** 1本の要求を通して、出た行を返す。`body` が在れば `json()` と同じ順で拾わせる。 */
function run({ url, method = "GET", code = 200, body = null, mark = null, abort = false, paths, ua }) {
  const lines = [];
  const res = fakeRes();
  // ★名乗りは渡された時だけ載せる。既定は「名乗り無し」= 今までの 78 件と同じ形。
  const req = ua === undefined ? { url, method } : { url, method, headers: { "user-agent": ua } };
  attachRequestLog(req, res, {
    knownPaths: paths,
    out: (l) => lines.push(l),
    now: () => new Date("2026-08-03T12:00:00.000Z"),
  });
  if (mark) markResult(res, mark);
  if (abort) res.emit("close");
  else {
    if (body) noteBody(res, body);
    res.writeHead(code, {});
  }
  return lines;
}

const KNOWN = new Set(["/", "/icon.png", "/healthz", "/api/sessions", "/api/account", "/api/account/next"]);
const SID = "0a1b2c3d-4e5f-6789-abcd-ef0123456789";

// --- ① 行が必ず1本出る -------------------------------------------------------

test("応答1つにつき行は1本(`writeHead` が合図)", () => {
  const l = run({ url: "/api/sessions", paths: KNOWN });
  assert.equal(l.length, 1);
  assert.match(l[0], /^\[rc-backend\] req 2026-08-03T12:00:00\.000Z GET \/api\/sessions route=- client=none code=200 reason=- ms=\d+$/);
});

test("★頭を書く前に切れた要求も1本出る(code=0 reason=aborted)", () => {
  const l = run({ url: `/api/sessions/${SID}/stream`, abort: true, paths: KNOWN });
  assert.equal(l.length, 1);
  assert.match(l[0], / code=0 reason=aborted /);
});

test("`writeHead` を2回呼んでも行は増えない(500 が SSE の頭の後に来る形)", () => {
  const lines = [];
  const res = fakeRes();
  attachRequestLog({ url: "/api/sessions", method: "GET" }, res, { knownPaths: KNOWN, out: (l) => lines.push(l) });
  res.writeHead(200, {});
  res.writeHead(500, {});
  res.emit("close");
  assert.equal(lines.length, 1);
  assert.match(lines[0], / code=200 /);
});

test("枝が名乗った経路と理由が行に乗る(§3-W が刺さった当の欄)", () => {
  const l = run({ url: `/api/sessions/${SID}/messages`, method: "POST", code: 202,
    body: { accepted: true, route: "tmux", pane: "%7" }, paths: KNOWN });
  assert.match(l[0], / POST \/api\/sessions\/:id\/messages sid=0a1b2c3d route=tmux client=none code=202 /);
});

test("先に名乗った方が勝つ(500 の生の例外文が語彙に流れない)", () => {
  const l = run({ url: "/api/sessions", code: 500, mark: { reason: "internal" },
    body: { error: "ENOENT open /Users/edith/.claude.json" }, paths: KNOWN });
  assert.match(l[0], / code=500 reason=internal /);
  assert.doesNotMatch(l[0], /edith|claude\.json/);
});

// --- ② 行に中身が乗らない ----------------------------------------------------

test("★表に無いパスは `(other)`(生のパスを disk に残さない)", () => {
  assert.equal(pathShape("/../keys/api.key", KNOWN), "(other)");
  assert.equal(pathShape("/api/sessions/x/../../etc/passwd", KNOWN), "(other)");
  const l = run({ url: "/wp-admin/setup-config.php?step=1", paths: KNOWN });
  assert.match(l[0], / GET \(other\) /);
  assert.doesNotMatch(l[0], /wp-admin|setup-config|step/);
});

test("★問い合わせ文字列は丸ごと捨てる(表に在るパスでも)", () => {
  const l = run({ url: "/api/sessions?scope=registered&limit=5", paths: KNOWN });
  assert.match(l[0], / GET \/api\/sessions /);
  assert.doesNotMatch(l[0], /scope|registered|limit|\?/);
});

test("★sessionId は先頭8文字だけ", () => {
  assert.equal(sessionOf(`/api/sessions/${SID}/history`), "0a1b2c3d");
  const l = run({ url: `/api/sessions/${SID}/history`, paths: KNOWN });
  assert.match(l[0], / sid=0a1b2c3d /);
  assert.doesNotMatch(l[0], /4e5f|ef0123456789/);
});

test("★自由文の理由は語彙に当たらず落ちる(本文が漏れる唯一の隙)", () => {
  // 実物の 400 は `bad body: <構文解析器の言い分>`。`:` で弾かれるのが正しい。
  assert.equal(errSlug("bad body: Unexpected token 'h', \"hello\"..."), "");
  assert.equal(token("この会話はまだ発言が無く、開いていたペインも見つかりません。"), "");
  assert.equal(token("送信本文がそのまま入った理由"), "");
  const l = run({ url: `/api/sessions/${SID}/messages`, method: "POST", code: 400,
    body: { error: "bad body: Unexpected token 'h'" }, paths: KNOWN });
  assert.match(l[0], / code=400 reason=- /);
  assert.doesNotMatch(l[0], /hello|Unexpected/);
});

test("実物の定数は語彙に当たる(= 何でも `-` にする網ではない)", () => {
  assert.equal(errSlug("not found"), "not-found");
  assert.equal(errSlug("unauthorized"), "unauthorized");
  assert.equal(errSlug("unknown session"), "unknown-session");
  assert.equal(errSlug("text required"), "text-required");
  assert.equal(errSlug("TRANSCRIPT_UNREADABLE"), "transcript-unreadable");
  for (const t of ["tmux", "worker", "blocked", "pane-gone", "verified", "already-done", "unverified"]) {
    assert.equal(token(t), t, `実物の語彙が落ちる: ${t}`);
  }
});

test("method も表に在る形だけ(外から来る文字列)", () => {
  const l = run({ url: "/", method: "GET /etc/passwd HTTP/1.1", paths: KNOWN });
  assert.match(l[0], / \(other\) \/ /);
  assert.doesNotMatch(l[0], /passwd/);
});

// --- ③ 一覧が古くならない(両方向) ------------------------------------------
//
// ★この検査が本体。ログは静かに古くなる —— 道を1本足しても、ログは新しい道を `(other)` と
//   書き続けるだけで、誰も「壊れた」と気づけない。だから server.mjs の**実物の振り分け**を
//   読んで突き合わせる。行番号ではなく `path === "…"` という**書き方**で当てる(§3-R)。

/** server.mjs が `path === "…"` で振り分けている固定パスを全部拾う。 */
function fixedPathsInServer() {
  return [...SERVER_CODE.matchAll(/\bpath === "([^"]+)"/g)].map((m) => m[1]);
}

/** server.mjs の `LOG_PATHS` に**手書きされている**パス(`STATIC` の展開は含まない)。 */
function listedInLogPaths() {
  const m = /const LOG_PATHS = new Set\(\[([\s\S]*?)\]\);/.exec(SERVER_CODE);
  assert.ok(m, "LOG_PATHS の一覧が見つからない(名前か形が変わった)");
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

test("★振り分けにある固定パスが全部ログの表に在る(足りない = 新しい道が `(other)` に化ける)", () => {
  const missing = fixedPathsInServer().filter((p) => !listedInLogPaths().includes(p));
  assert.deepEqual(missing, [], "server.mjs が振り分けているのにログの表に無い");
});

test("★ログの表に、振り分けに無いパスが残っていない(余る = 消えた道の写し)", () => {
  const dead = listedInLogPaths().filter((p) => !fixedPathsInServer().includes(p));
  assert.deepEqual(dead, [], "ログの表に、server.mjs が振り分けていないパスが在る");
});

test("★会話の道の正規表現は1本しか無い(server.mjs は写しを持たず import する)", () => {
  assert.match(SERVER_SRC, /const m = SESSION_ROUTE_RE\.exec\(path\);/, "振り分けが写しの正規表現に戻っている");
  assert.equal(
    (SERVER_SRC.match(/\/\^\\\/api\\\/sessions\\\//g) || []).length, 0,
    "server.mjs に会話の道の正規表現が再び書かれている(= 一覧が2つ)",
  );
  // 動作名は正規表現から取る(此処に書き写すと、それ自体が3つ目の写しになる)。
  for (const a of /\((history[^)]*)\)/.exec(SESSION_ROUTE_RE.source)[1].split("|")) {
    assert.equal(pathShape(`/api/sessions/${SID}/${a}`, KNOWN), `/api/sessions/:id/${a}`);
  }
});

test("★`json()` が拾い口を通る(呼び口40箇所ではなく唯一の口で拾っている事)", () => {
  const m = /function json\(res, code, obj\) \{([\s\S]{0,900}?)res\.writeHead\(code,/.exec(SERVER_SRC);
  assert.ok(m, "json() の本体が writeHead に届く前に見つからない");
  // ★以前は `noteBody(res, obj);` と**変数名を書き写して**いた。名前は「送った物」の
  //   代理でしかなく、`json()` が `display` を足す様になった時に、名前が合わなくなっただけで
  //   落ちた(2026-08-05)。測るべきは名前ではなく**同一性** —— 本文に組んだ物と、ログに
  //   渡した物が同じ値である事。こう書くと、ログだけが送信前の姿を保存する欠陥も掴める。
  const sent = /const body = JSON\.stringify\((\w+)\);/.exec(m[1]);
  assert.ok(sent, "本文を組む行が writeHead より前に無い");
  assert.match(
    m[1],
    new RegExp(`noteBody\\(res, ${sent[1]}\\);`),
    `json() が「実際に送った物」(${sent ? sent[1] : "?"})を writeHead より前に拾っていない`,
  );
});

test("★仕掛けは try の外(URL の解釈で落ちた要求こそログに要る)", () => {
  assert.match(
    SERVER_SRC,
    /createServer\(async \(req, res\) => \{[\s\S]{0,300}?attachRequestLog\(req, res, \{ knownPaths: LOG_PATHS \}\);[\s\S]{0,20}?try \{/,
    "attachRequestLog が try の中に入っている / 呼ばれていない",
  );
});

test("★ストリームの経路判定が `writeHead` より前(行に route が乗る条件)", () => {
  const m = /if \(action === "stream" && req\.method === "GET"\) \{([\s\S]*?)res\.writeHead\(200, \{/.exec(SERVER_SRC);
  assert.ok(m, "ストリームの枝が見つからない");
  assert.match(m[1], /const found = resolvePane\(\);/, "経路判定が頭の後ろに戻っている");
  assert.match(m[1], /markResult\(res, \{ route: found\.pane \? "tmux" : "worker" \}\);/, "経路を名乗っていない");
});

test("★stderr の尾をログへ書いていない(§2.21-b。画面に出る物を disk に残さない)", () => {
  // ★**実装**を測る。注釈で stderr に言及するのは正しい(何故書かないかを残す為)ので、
  //   散文ごと禁じると「説明を書くと赤くなる」検査になる —— 最初それを書いて落ちた。
  const code = stripComments(REQLOG_SRC);
  assert.doesNotMatch(code, /\bstderr\b/, "reqlog の実装が stderr に触れている");
  assert.doesNotMatch(code, /\btail\b/i, "reqlog の実装が尾を扱っている");
});

test("★行に出る欄は決まった5つだけ(新しい欄が黙って増えない)", () => {
  const m = /out\(\n([\s\S]*?)\n\s*\);/.exec(REQLOG_SRC);
  assert.ok(m, "行を書く口が見つからない(形が変わった)");
  const fields = [...new Set([...m[1].matchAll(/\b([a-z]+)=/g)].map((x) => x[1]))].sort();
  // ★`client` は 2026-08-27 に**宣言して**足した欄。この検査が要求する通り、
  //   「中身が乗らない」の対照(下の3件)を同じ commit で一緒に入れている。
  assert.deepEqual(fields, ["client", "code", "ms", "reason", "route", "sid"],
    "行の欄が増減した —— 増やすなら『中身が乗らない』の検査も一緒に足す事");
});

/**
 * ★2026-08-27 新設。**「誰が叩いたか」の種類だけを残す**事を測る。
 *
 * なぜ要るか(実測): この記録は出所を一切残していなかった。その為
 * 「Tom はこのアプリを開いたのか」に答えるのに、私は自分の作業記録との時刻
 * 突き合わせを 6 回やる羽目になり、それでも Simulator と実機を区別できなかった。
 * 答えが要る問いに記録が答えられないのは、計器が無いのと同じ。
 *
 * ★同時に**端末の指紋を残さない**事も測る。生の User-Agent には型番と OS の版が
 *   入るので、§3-U の「行に中身が乗らない」はここにも掛かる。
 */
test("★電話と機械が行の上で別の語になる(本命)", () => {
  const phone = run({ url: "/api/sessions", ua: "RemoteMini/1.0 CFNetwork/1498.700 Darwin/24.0.0" });
  const robot = run({ url: "/api/sessions", ua: "curl/8.7.1" });
  assert.match(phone[0], / client=app /, "iOS のアプリが機械と同じ顔で記録されている");
  assert.match(robot[0], / client=tool /, "常駐(curl)がアプリと同じ顔で記録されている");
  // ★これが本命。欄そのものを外すと、2 本の行が**区別できない**まま緑になる。
  assert.notEqual(phone[0].replace(/ms=\d+/, ""), robot[0].replace(/ms=\d+/, ""),
    "電話と常駐が同じ行になる —— 誰が叩いたか記録から判らない(2026-08-27 の状態)");
});

test("★生の名乗りは行に出ない(端末の指紋を残さない)", () => {
  const ua = "RemoteMini/1.0 CFNetwork/1498.700 Darwin/24.0.0 iPhone17,1";
  const l = run({ url: "/api/sessions", ua });
  assert.doesNotMatch(l[0], /CFNetwork|Darwin|iPhone17/,
    "生の User-Agent が行に漏れている(端末の型番と OS の版が記録に残る)");
  assert.match(l[0], / client=app /, "分類だけは残っている事");
});

test("知らない名乗りは other へ畳む(開いた語を作らない)", () => {
  const l = run({ url: "/api/sessions", ua: "SomeNewThing/9 (unknown-vendor-string)" });
  assert.match(l[0], / client=other /);
  assert.doesNotMatch(l[0], /SomeNewThing|unknown-vendor/,
    "知らない名乗りがそのまま行へ流れている");
});

/**
 * この repo が**実際に名乗る**理由を src から集める。写しを書かない(= §3-R の型)。
 *
 * 出所は2つ。片方だけ見ると足りない:
 *   ① API の本文の `reason: "…"`(server.mjs / blocked.mjs 等)
 *   ② `cwdVerdict()` の返り値(trust.mjs)—— server.mjs が `reason: verdict` として
 *      そのまま本文へ載せるので、**文字列としては src に1回しか現れない**。
 */
function reasonsInSource() {
  const dir = join(ROOT, "src");
  const out = new Set();
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".mjs"))) {
    const code = stripComments(readFileSync(join(dir, f), "utf8"));
    for (const m of code.matchAll(/reason: *"([^"]+)"/g)) out.add(m[1]);
  }
  const trust = stripComments(readFileSync(join(dir, "trust.mjs"), "utf8"));
  const body = /export function cwdVerdict\(([\s\S]*?)(?=\nexport |\n$)/.exec(trust);
  assert.ok(body, "cwdVerdict が見つからない(名前が変わった)");
  for (const m of body[1].matchAll(/return "([^"]+)"/g)) out.add(m[1]);
  assert.ok(out.size >= 15, `理由の取り出しが壊れている(${out.size}件しか出ない)`);
  return [...out].sort();
}

/**
 * ★**repo が名乗る理由は、1つ残らず行に出る**。
 *
 * これを書く羽目になった経緯: 語彙の網が下線を弾いていた初版は、e2e の実物のログで
 * `route=worker code=409 reason=-` を出した。拒否の理由は定数として在るのに欄だけが空
 * —— **一番読みたい行だけが黙る**形。23件の単体検査も 184件の e2e も全部緑のまま通り、
 * 見つかったのは `RC_E2E_SHOW_LOG=1` で実物を**読んだ**時だった。
 * 読んで直しただけでは同じ穴がまた開くので、ここで留める。
 */
test("★src が名乗る理由は全部ログの語彙に通る(通らない物が1つでも在れば赤)", () => {
  const blank = reasonsInSource().filter((r) => token(r) === "");
  assert.deepEqual(blank, [],
    "この理由でログの欄が空になる。語彙を広げるか、理由の綴りを語彙に合わせる事");
});

test("ログに出る綴りは1通り(下線は寄せる。grep が二度要らない)", () => {
  const both = reasonsInSource().map(token).filter((s) => s.includes("_"));
  assert.deepEqual(both, [], "下線のまま出ている");
  assert.equal(token("cwd_unknown"), "cwd-unknown");
});

// --- 陰性対照 ---------------------------------------------------------------
// 「通った」を「何も見ていない」と区別する。入力は**実物の関数**に食わせる
// (手書きの偽ログを自分で書いて自分で読むと、自分の書き癖にしか当たらない)。

test("陰性対照: 表を渡さないと、表に在る筈のパスも `(other)` になる", () => {
  // = `knownPaths` を渡し忘れた形。上の検査が「常に通る」物でない事の証拠。
  assert.equal(pathShape("/api/sessions", undefined), "(other)");
  assert.equal(pathShape("/api/sessions", KNOWN), "/api/sessions");
});

test("陰性対照: 語彙の網を外すと本文が乗る(網が効いている事の証拠)", () => {
  const raw = (v) => v; // 網を外した実装の代役
  assert.notEqual(raw("bad body: hello"), errSlug("bad body: hello"));
  assert.equal(errSlug("bad body: hello"), "");
});

test("陰性対照: sessionId を切らないと全部出る(切っている事の証拠)", () => {
  assert.notEqual(SID.slice(0, 8), SID);
  assert.equal(sessionOf(`/api/sessions/${SID}/status`).length, 8);
});

test("陰性対照: 一覧の突き合わせが実物を見ている(偽の道を1本足すと落ちる)", () => {
  const fake = [...listedInLogPaths(), "/api/never-dispatched"];
  const dead = fake.filter((p) => !fixedPathsInServer().includes(p));
  assert.deepEqual(dead, ["/api/never-dispatched"], "余った道を見逃す");
});

test("陰性対照: 下線を許しても網は緩んでいない(自由文は依然落ちる)", () => {
  // = 上の「全部通る」を、`token` が何でも通す実装でも満たせてしまう形との区別。
  for (const bad of ["bad body: {\"a\":1}", "cwd unknown", "Cwd_Unknown!", "x".repeat(30), "_lead"]) {
    assert.equal(token(bad), "", `語彙に通ってはいけない物が通った: ${bad}`);
  }
});
