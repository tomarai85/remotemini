// 線に出る**語彙の値**が両側で一致するか。`wire-key-agreement` の**鍵名**に対する、値の側。
//
// ── なぜ別の検査が要るのか(2026-08-09、S8-26 phase 3 で測って分かった)──────────
// phase 2 を締める時、残る8件(誤り応答4本)も「封筒を builder へ切り出せば同じ手が効く」
// と書きかけて、書かずに `DESIGN.md §2.81` へ「同じ手が効くとは言い切れない、phase 3 で測る」
// と残した。測ったら**効かなかった**:
//   ・電話の `SendClient.Envelope` / `InterruptClient.Envelope` / `ChoiceClient.Envelope` が
//     読む鍵は `display` / `code` (/ `digest`) の3つだけ。
//   ・`display` を足しているのは `server.mjs` の `json()` ただ1箇所で、其処は import 出来ない。
//     しかも `display` の**内容**は既に `test/e2e-local.mjs` の 13-D が、生きたサーバの応答と
//     `sendResult` 等の再計算を突き合わせて測っている(status 違い / 本文違い / 別の口の関数の
//     3種の対照付き)。鍵名の組にしても、其の上に何も足せない。
//   ・`code` は `server.mjs` 上部の凍らせた語彙3つからしか来ない。これは
//     `test/recovery-codes.test.mjs` が**サーバ側だけで**丸ごと守っている。
// → つまり誤り応答で本当に測れていなかったのは鍵名ではなく、**電話が焼き込んでいる文字列の値**
//   だった。`recovery-codes.test.mjs` はその値を意図的に決め打たない(冒頭 20-22 行:
//   値まで固定すると検査が変更の追認機になる)。正しい判断だが、**両側を繋ぐ役は誰も居ない**。
//
// ★此の検査が「追認機」にならない理由。此処も値を決め打たない —— 突き合わせるのは
//   **サーバの値 == 電話の値**であって、リテラルではない。両側を揃えて改名すれば緑のまま通る。
//   片側だけ変えた時にだけ赤くなる。`recovery-codes.test.mjs` が避けた失敗はここでは起きない。
//
// ── 測る面 ──────────────────────────────────────────────────────────────
// 両方の木から**大文字だけの文字列リテラル**(= 線に出る語彙の見た目)を採り、集合を比べる。
// 片側にしか無い語は**許可表に理由を書くまで赤**。増えたら赤、が此処の既定 —— §2.81 で
// `/healthz` に敷いたのと同じ規則を、鍵名ではなく値の面へ適用する。
//
// ★この形を選んだのは、挙動の検査が**片側にしか無い能力**を落とすと実測されているから
//   (`~/.claude/.../method_parity_over_behavior_misses_one_sided_capability.md`)。
//   面(集合)で比べ、正当な差は名前で許可する。
//
// ★実際に1件釣れた(2026-08-09、書いた其の日 —— 初回の走行が赤で出た)。
//   `SessionsListingFixture.swift` の「作業中のセッション」の行が `screen: "MAIN"` を
//   持っていた。サーバの `routeLabel()` が tmux の枝で `screen` に入れるのは
//   `v.screen || ""` = `classifyScreen` の `SENDABLE` / `CHOICE` / `UNKNOWN` だけで、
//   `MAIN` は**どの枝からも出ない**。今日の実害は無い
//   (`SessionRow.display.route.screen` を読む UI が1つも無い)。だが fixture は
//   「人が目で全状態を確かめる為の物」で、其処だけがサーバの語彙の外に居た形
//   = S8-20 / S8-21 で潰した「fixture だけが別の版を持っていた」の3件目。
//
//   ★出所まで辿った(此処が此の1件の本体)。`MAIN` の**種は検査の側に在った** ——
//   `test/fixture-labels-producible.test.mjs` の入力表が `screen: "MAIN"` を6行渡していた。
//   あの検査が見るのは `(short, text)` だけで、`routeLabel` の tmux 枝は `screen` を
//   `=== "CHOICE"` としか比べないので、**入力表の `screen` は何にも効かない** =
//   置き場所の無い placeholder が6行、緑のまま座っていた。効かない欄に在る間は無害だが、
//   写された先(fixture)では「線に出る値」の顔をする。両方直した(入力表は
//   `SENDABLE` / `UNKNOWN` へ)。★教訓は「fixture を直す」ではなく
//   **効かない欄にも本物の語彙しか置かない** —— 効かない事は、其の綴りが正しい事の
//   証明ではない。
//
// ── S8-28 を此処へ畳んだ理由(2026-08-09、投資の側の判断)────────────────────────
// 「電話の検査が持つ『Can't send理由』8語の写しを `WIRE_REASONS` と照合する」は、当初
// **別の検査 file + 専用の対照 suite** で立てる予定だった。着手前に通行量を測って畳んだ:
//   ・`WIRE_REASONS` は生まれてから**一度も変わっていない**(`src/blocked.mjs` は全3 commit)
//   ・電話は `reason` を**一度も描かない**(`PaneFault.reason` の注釈が "Never drawn"、
//     分岐用の enum も持たず `String` のまま)。9個目が生えても電話の画面は何も変わらない
//   ・サーバ側は既に2本が `WIRE_REASONS` を回している(`test/blocked.test.mjs` /
//     `test/view.test.mjs`)ので、語が増えた時に文面の穴が開く方は既に赤くなる
// → 残る穴は1つだけ、**電話の検査の「全部復号できる」という主張が黙って嘘になる**事。
//   語彙の値が両側で一致するかは此の file の主題そのものなので、file を増やさず1本足した。
//   ★「価値が無いからやらない」ではなく「**投資の形を実測に合わせた**」= 新しい media
//     (小文字ハイフンの語彙)は増やすが、file と対照 suite は増やさない。
//
//   `fixture-labels-producible` 側を「`screen` も突き合わせる」形に広げるのは**採らなかった**:
//   あの検査は「其の種類で出しうる (short, text) の集合」を毎回 `routeLabel` に作らせる形で、
//   `screen` を足すには入力表が画面名まで列挙する事になる —— 誰も描かない1欄の為に
//   結合を増やす。値の一致は此の検査の仕事。役割を分けたまま両方が見張る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { ROOT, REPO, REPO_INTACT, requireOutside } from "./subtree.mjs";
import { stripSwiftComments, swiftFiles } from "./swiftsrc.mjs";
import { stripComments } from "./jssrc.mjs";
import { WIRE_REASONS } from "../src/blocked.mjs";

const SWIFT_ROOT = join(REPO, "ios", "Sources");
const SRC_ROOT = join(ROOT, "src");
const SERVER = join(SRC_ROOT, "server.mjs");
const RECOVERY_SWIFT = join(SWIFT_ROOT, "Core", "ResultDisplay.swift");
const POLL_TESTS_SWIFT = join(REPO, "ios", "Tests", "Core", "PollModelsTests.swift");

const NEED = [
  "ios/Sources",
  "ios/Sources/Core/ResultDisplay.swift",
  "ios/Tests/Core/PollModelsTests.swift",
];
const gate = requireOutside(NEED);
const skip = gate.skip;

// --- 採る ---------------------------------------------------------------------

/**
 * 注釈を落とした原文から、**大文字だけの文字列リテラル**を採る。
 *
 * 3文字以上に限るのは `"OK"` の様な2文字の常用語を語彙と読まない為。線に出ている語で
 * 2文字の物は両方の木に1つも無い(2026-08-09 実測)。増えたら此処を下げて許可表で捌く。
 */
export function harvestTokens(src) {
  return new Set([...src.matchAll(/"([A-Z][A-Z0-9_]{2,})"/g)].map((m) => m[1]));
}

function harvestTree(files, strip) {
  const out = new Map();
  for (const f of files) {
    for (const t of harvestTokens(strip(readFileSync(f, "utf8")))) {
      if (!out.has(t)) out.set(t, []);
      out.get(t).push(f);
    }
  }
  return out;
}

function mjsFiles(dir, out = []) {
  for (const e of readdirSync(dir).sort()) {
    const p = join(dir, e);
    if (statSync(p).isDirectory()) mjsFiles(p, out);
    else if (e.endsWith(".mjs")) out.push(p);
  }
  return out;
}

// --- 許可表(片側にしか無い語は、理由を書くまで赤)-------------------------------

/** 電話にしか無い語。**サーバの語彙ではない**物だけがここに居てよい。 */
const PHONE_ONLY = {
  RC_UI_FIXTURE: "電話の環境変数名(UI 検査が fixture 画面を出す為の合図)。線には出ない",
  // ★1つの変数に2つの名前空間を載せた最初の版は、一覧の分岐が口座の名前を
  //   「知らない値」と読んで `normalFlow` へ落ち、ListView に一度も到達しなかった
  //   (2026-08-12、走行のログの `root flow:normal` で確定。UI 検査5本が同じ理由で赤)。
  //   相が直交するなら変数も分ける、が此の2本目が在る理由。
  RC_UI_ACCOUNT_FIXTURE: "電話の環境変数名(口座の相を一覧の相と独立に振る為)。線には出ない",
};

/**
 * サーバにしか無い語。「電話が読まない」ではなく「**電話が読む必要が無い**」理由を書く。
 *
 * ★`AUTH_REQUIRED` と `NO_SUCH_ROUTE` の2つは、電話が敢えて焼いていない事に理由が在り、
 *   その理由は `ResultDisplay.swift` の `RecoveryCode` に既に書かれている。此処の文言は
 *   其れを写した物ではなく**要約**で、正本は向こう側。食い違ったら向こうを読む。
 */
const SERVER_ONLY = {
  AUTH_REQUIRED: "401 は status そのもので分岐が付く。電話は値を見ないと決めている(RecoveryCode の注釈)",
  NO_SUCH_ROUTE: "何処からも分岐しない。契約違反の診断としてしか利用者に届かない(同上)",
  TRANSCRIPT_UNREADABLE: "行の `errorCode`。電話は値で分岐せず `display` を描く(SessionsModels の `PaneFault` と同じ判断)",
  TMUX_UNAVAILABLE: "`blocked` の理由コード。電話は生で出さず、サーバが組んだ文面を描く",
  TMUX_UNREADABLE: "同じく `blocked` の理由コード。描くのはサーバの文面",
  MUTEX_BUSY: "排他の内部語。応答本文には `reason` へ言い換えて出るので、この綴りは線に出ない",
  MUTEX_ABORTED: "同じく排他の内部語。言い換えてから線に出る",
  MUTEX_FN: "排他が内部で使う鍵名。応答には一度も載らない",
  MUTEX_KEY: "同じく排他の内部の鍵名。応答には載らない",
  ENOENT: "Node の errno。診断欄へ寄せてある(`code` ではない = recovery-codes.test.mjs)",
  EACCES: "Node の errno。同じく診断欄で、電話は分岐に使わない",
  EADDRINUSE: "起動失敗時の errno。線が開く前に落ちるので電話へ届く道が無い",
  EPIPE: "書き込み中断の errno。診断欄止まり",
  ETIMEDOUT: "子プロセスの時間切れ errno。診断欄止まり",
  SIGKILL: "子プロセスの止め方。応答には載らない",
  SIGTERM: "同じく子プロセスの止め方。応答には載らない",
  // DELETE は 2026-08-14 に許可表から**降りた**: v2 のキュー取り消しで電話が
  // `URLRequest.httpMethod = "DELETE"` を書く様になり、両側に居る普通の共有語に戻った。
  // (旧註「電話は DELETE を書いていない(行列の取り消しは v1 に無い)」の前提ごと失効。)
};

/**
 * 両側に在ってよい語(= 突き合わせる対象)。此処に列挙はしない —— 集合の交わりが其れで、
 * 手で2つ目の一覧を持たない。`DELETE` は 2026-08-14 まで片側(サーバ)にしか見えず
 * 許可表に理由付きで居た。v2 のキュー取り消しで電話が書く様になった日、dead 判定が
 * **設計通りに赤を出して**表から降ろさせた —— 「届く様になったら赤くなる」と
 * 書いた通りの一部始終で、許可表が追認機でない事の実測1件目。
 */

// --- 復旧語彙の**値**(名前ではない)----------------------------------------------

/**
 * サーバの凍らせた語彙から `code` の**値**を採る。
 *
 * ★名前ではなく値を読むのが此の関数の全部。`server.mjs` では定数名と `code` の値が
 *   偶々同じ綴りなので(`SESSION_NOT_FOUND` = `code: "SESSION_NOT_FOUND"`)、
 *   電話のリテラルを原文へ grep するだけの検査は**値だけ変えた改修を緑で通す**。
 *   下の陰性対照が丁度その形を立てている。
 */
export function serverCodeValues(src) {
  const re = /const\s+([A-Z][A-Z0-9_]*)\s*=\s*Object\.freeze\(\{([^}]*)\}\)/g;
  const out = new Map();
  for (const m of src.matchAll(re)) {
    const code = /\bcode\s*:\s*"([^"]*)"/.exec(m[2]);
    if (code) out.set(m[1], code[1]);
  }
  return out;
}

/**
 * 電話の検査が「サーバが送りうる `blocked` の理由の**全部**」として並べている語を採る
 * (S8-28、2026-08-09)。
 *
 * ★鍵名(`reason:`)では採れない、と測ってから此の形にした。`ios/**` の `reason` 欄に
 *   焼かれている literal を全部採ると `panes-unreadable` / `pane-gone` / `not-claude` に
 *   混ざって `confirm` / `digest-mismatch` / 日本語の1文 / `""` が出てくる ——
 *   **同じ `reason` という鍵名を、`blocked` の理由と選択カードの拒否理由という
 *   別々の語彙が共有している**。鍵名で採る設計は此処で死ぬ。
 *
 * ★そこで錨は**主張している関数の名前**にした。`testEveryBlockedReasonTheServerCanSendDecodes`
 *   は「サーバが送りうる理由は全部復号できる」と名乗っており、其の主張の範囲が此の配列。
 *   関数が消えたり改名されれば空が返り、下の錨(`length >= 6`)が赤くなる。
 *
 * ★開き括弧まで含めて探す事。**書いた其の日に対照が此処を釣った**(2026-08-09) ——
 *   `func ${fn}` だけで探すと、名前の**末尾に語を足した改名**が素通りする
 *   (`...Decodes` は `...DecodesForAllRoutes` の接頭辞なので当たってしまう)。
 *   Swift の検査名に語を足すのは有り触れた改名で、作り話の変異ではない。
 *   接頭辞一致のままなら「其の主張を測っている」ではなく「其の主張で始まる何かを測っている」。
 *
 * ★配列の外まで採らない事(本文には `"route"` / `"blocked"` / `"message"` / `"m"` が在り、
 *   どれも `[a-z-]+` に当たる)。だから最初の `[` から最初の `]` までに限る。
 */
export function phoneBlockedReasons(src, fn = "testEveryBlockedReasonTheServerCanSendDecodes") {
  const at = src.indexOf(`func ${fn}(`);
  if (at < 0) return [];
  const open = src.indexOf("[", at);
  const close = src.indexOf("]", open);
  if (open < 0 || close < 0) return [];
  return [...src.slice(open, close).matchAll(/"([^"\\]+)"/g)].map((m) => m[1]);
}

/** 電話が `RecoveryCode` に焼いている値を採る(`static let <名> = "<値>"`)。 */
export function phoneRecoveryValues(src) {
  const at = src.indexOf("struct RecoveryCode");
  if (at < 0) return new Map();
  const body = src.slice(at, src.indexOf("\n}", at));
  const out = new Map();
  for (const m of body.matchAll(/static\s+let\s+(\w+)\s*=\s*"([^"]*)"/g)) out.set(m[1], m[2]);
  return out;
}

// --- 判定(純関数。対照から直に呼ぶ)---------------------------------------------

/**
 * `side` にしか無い語のうち、許可表に載っていない物(空 = 合格)。
 *
 * ★`side.keys()` を通すのは Map と Set の両方を受ける為(産む側は Map、対照は素の Set)。
 *   `[...map]` は `[鍵, 値]` の組を返すので、素で回すと**全語が片側限定に見えて**赤が出る
 *   —— 書いた其の日に踏んだ(2026-08-09)。判定の中身ではなく、入れ物の読み違い。
 */
export function undeclared(side, other, allow) {
  return [...side.keys()].filter((t) => !other.has(t) && !(t in allow)).sort();
}

/** 効かなくなった許可表の項目(空 = 合格)。両側に在る / どちらにも無い、の2通り。 */
export function deadEntries(allow, side, other) {
  return Object.keys(allow).filter((t) => !side.has(t) || other.has(t)).sort();
}

// --- 走らせる -------------------------------------------------------------------

const PHONE = gate.measured ? harvestTree(swiftFiles(SWIFT_ROOT), stripSwiftComments) : new Map();
const SERVER_TOK = gate.measured ? harvestTree(mjsFiles(SRC_ROOT), stripComments) : new Map();
const where = (m, t) => (m.get(t) || []).map((f) => f.slice(REPO.length + 1)).join(" ");

test("★走査が空振りしていない(両側とも語彙を採れている)", { skip }, () => {
  // 床は実測(2026-08-09: 電話9 / サーバ24)より低く採る。増減で赤くしたいのではなく、
  // **走査そのものが死んだ**時に緑で通さない為の錨。
  assert.ok(PHONE.size >= 6, `電話側の語彙が ${PHONE.size} 語しか採れない。走査か綴りが古い`);
  assert.ok(SERVER_TOK.size >= 15, `サーバ側の語彙が ${SERVER_TOK.size} 語しか採れない。同上`);
});

test("★★電話にしか無い語は、理由を書いた物だけ", { skip }, () => {
  const bad = undeclared(PHONE, SERVER_TOK, PHONE_ONLY).map((t) => `${t} (${where(PHONE, t)})`);
  assert.deepEqual(
    bad, [],
    "サーバが一度も吐かない語を電話が持っている。\n" +
      "  fixture なら「人が目で確かめる画面」だけが本物と違う状態 = S8-20 / S8-21 と同じ型。\n" +
      "  実コードなら、其の分岐は生きたサーバでは一度も通らない。\n" +
      "  サーバの綴りへ寄せるか、線に出ない語である理由を `PHONE_ONLY` へ書く事",
  );
});

test("★★サーバにしか無い語は、理由を書いた物だけ", { skip }, () => {
  const bad = undeclared(SERVER_TOK, PHONE, SERVER_ONLY).map((t) => `${t} (${where(SERVER_TOK, t)})`);
  assert.deepEqual(
    bad, [],
    "電話が知らない語をサーバが吐いている。\n" +
      "  電話が分岐に使うべき語なら電話へ足す。使わないなら**使わない理由**を\n" +
      "  `SERVER_ONLY` へ書く事(「電話が読まないから」は理由ではない)",
  );
});

test("★許可表に死んだ項目が無い(両側に在る / どちらにも無い)", { skip }, () => {
  assert.deepEqual(
    deadEntries(PHONE_ONLY, PHONE, SERVER_TOK), [],
    "`PHONE_ONLY` の項目が実態と合っていない。消えた語か、サーバにも生えた語",
  );
  assert.deepEqual(
    deadEntries(SERVER_ONLY, SERVER_TOK, PHONE), [],
    "`SERVER_ONLY` の項目が実態と合っていない。消えた語か、電話にも生えた語",
  );
});

test("★許可表の理由が空でない(名前だけ並べて通せない)", { skip }, () => {
  const thin = [...Object.entries(PHONE_ONLY), ...Object.entries(SERVER_ONLY)]
    .filter(([, why]) => typeof why !== "string" || why.trim().length < 10)
    .map(([t]) => t);
  assert.deepEqual(thin, [], "理由が空か短すぎる項目が在る。語を1つ許すには1文が要る");
});

test("★★電話が焼いている復旧語彙の**値**を、サーバが実際に吐いている", { skip }, () => {
  const server = serverCodeValues(readFileSync(SERVER, "utf8"));
  const phone = phoneRecoveryValues(readFileSync(RECOVERY_SWIFT, "utf8"));
  assert.ok(server.size >= 3, `サーバの語彙を ${server.size} 個しか採れない = 走査が古い`);
  assert.ok(phone.size >= 1, "電話の RecoveryCode が空 = 走査が古いか型が消えた");
  const values = new Set(server.values());
  const missing = [...phone].filter(([, v]) => !values.has(v)).map(([n, v]) => `${n} = "${v}"`);
  assert.deepEqual(
    missing, [],
    "電話が焼いている値を、サーバの語彙が持っていない。\n" +
      `  サーバが吐く値: ${[...values].sort().join(" / ")}\n` +
      "  電話はこの値で**画面を移す**(一覧へ戻る)ので、片側だけ綴りを変えると\n" +
      "  遷移が黙って死ぬ —— 応答は 404 のまま届き、電話は「戻る」を選ばなくなる",
  );
});

test("★★電話の検査が並べる『Can't send理由』が、サーバの WIRE_REASONS と過不足なく一致する", { skip }, () => {
  const phone = phoneBlockedReasons(readFileSync(POLL_TESTS_SWIFT, "utf8"));
  assert.ok(
    phone.length >= 6,
    `電話側から理由を ${phone.length} 語しか採れない = 関数が改名/削除されたか、配列の形が変わった`,
  );
  assert.deepEqual(
    [...phone].sort(), [...WIRE_REASONS].sort(),
    "電話の検査が並べる理由と、サーバが実際に出しうる理由(`src/blocked.mjs` の `WIRE_REASONS`)が食い違う。\n" +
      "  多い → サーバが一度も出さない語で復号を確かめている(測っているつもりの空振り)。\n" +
      "  少ない → サーバが出しうる語のうち、電話で復号を確かめていない物が在る。\n" +
      "  どちらも**あの検査の名前(『全部復号できる』)が嘘になる**形",
  );
});

test("陰性対照: 判定が見分けている(常に緑を返しているのではない)", () => {
  // 採る側
  assert.deepEqual([...harvestTokens('a("SENDABLE") b("lower") c("X")')], ["SENDABLE"]);
  assert.deepEqual([...harvestTokens('"MIXED_case" "A_B1"')], ["A_B1"]);
  // 片側だけの語を名指す
  const P = new Map([["SENDABLE", []], ["MAIN", []]]);
  const S = new Map([["SENDABLE", []], ["SIGKILL", []]]);
  assert.deepEqual(undeclared(P, S, {}), ["MAIN"]);
  assert.deepEqual(undeclared(P, S, { MAIN: "理由" }), []);
  assert.deepEqual(undeclared(S, P, {}), ["SIGKILL"]);
  // 死んだ許可表を名指す
  assert.deepEqual(deadEntries({ SENDABLE: "x" }, P, S), ["SENDABLE"], "両側に在る語は許可表に要らない");
  assert.deepEqual(deadEntries({ GONE: "x" }, P, S), ["GONE"], "どちらにも無い語は許可表に要らない");
  assert.deepEqual(deadEntries({ MAIN: "x" }, P, S), []);
  // ★★名前ではなく値を読んでいる。**定数名は据え置き、`code` の値だけ変えた**形で、
  //   原文への grep 型の検査は緑を返す(名前が原文に在るから)。此処は赤で正しい。
  const trap = 'const SESSION_NOT_FOUND = Object.freeze({ error: "unknown session", code: "SESSION_MISSING" });';
  assert.deepEqual([...serverCodeValues(trap).values()], ["SESSION_MISSING"]);
  assert.ok(trap.includes("SESSION_NOT_FOUND"), "罠の前提: 定数名は原文に残っている");
  // `code` を持たない定数は語彙ではない
  assert.deepEqual([...serverCodeValues('const A = Object.freeze({ error: "x" });').keys()], []);
  // 電話側の採り方
  const sw = 'struct RecoveryCode: Decodable {\n  let code: String?\n  static let sessionNotFound = "SESSION_NOT_FOUND"\n}\n';
  assert.deepEqual([...phoneRecoveryValues(sw)], [["sessionNotFound", "SESSION_NOT_FOUND"]]);
  assert.deepEqual([...phoneRecoveryValues("struct Other {}")], [], "型が無い木では空 = 上の錨が赤くなる");
  // ★『Can't send理由』の採り方(S8-28)。**配列の外へ出ない**事が此の関数の肝で、
  //   本文の JSON には `route` / `blocked` / `message` が居るので、範囲を誤ると
  //   「サーバが出さない語を電話が持っている」と嘘の赤が出る。
  const blockedFn =
    'func testEveryBlockedReasonTheServerCanSendDecodes() throws {\n' +
    '    for reason in [\n      "not-claude", "stale",\n    ] {\n' +
    '        try decode(#"{ "route": "blocked", "reason": "x", "message": "m" }"#)\n    }\n}\n';
  assert.deepEqual(phoneBlockedReasons(blockedFn), ["not-claude", "stale"]);
  assert.deepEqual(
    phoneBlockedReasons(blockedFn, "testRenamed"), [],
    "錨にした関数名が無ければ空 = 上の `length >= 6` が赤くなる(改名を黙って飲まない)",
  );
  // ★★対照が釣った1件(2026-08-09)。**末尾に語を足した改名**が接頭辞一致で
  //   素通りしていた。求めているのは「あの名前の関数」であって「あの名前で始まる
  //   関数」ではないので、開き括弧まで含めて探す。
  const renamed = blockedFn.replace(
    "func testEveryBlockedReasonTheServerCanSendDecodes(",
    "func testEveryBlockedReasonTheServerCanSendDecodesForAllRoutes(",
  );
  assert.ok(
    renamed.includes("testEveryBlockedReasonTheServerCanSendDecodesForAllRoutes"),
    "罠の前提: 改名が実際に入っている",
  );
  assert.deepEqual(
    phoneBlockedReasons(renamed), [],
    "名前の末尾に語を足した改名を、接頭辞一致で飲んでいる。\n" +
      "  飲むと採れる語は元のまま = 改名した人の新しい主張を、古い名前の主張として測る事になる",
  );
});

// ★逃げ道の錨。上の6本が `gate.skip` で飛べるので、完全な木で**飛んでいない**事を
//   1本だけ主張する。此処が壊れて常に飛ぶ様になれば、この錨が完全な木で赤くなる。
//   判定に使うのは `REPO_INTACT`(= `DESIGN.md` の実在)だけなので、`gate` の壊れ方と独立。
test("この木では『部分木だから測らない』を通っていない", { skip: !REPO_INTACT && "部分木の写し" }, () => {
  assert.equal(gate.skip, false, `親は健在なのに ios を測っていない: ${gate.skip}`);
  assert.deepEqual(gate.missing, [], "木の外の対象が欠けているのに測ると言っている");
});
