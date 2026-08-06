// 電話側の各 client が**どんな request を出すか**を、検査が実際に見ているか。
//
// 経緯 (2026-08-05): 別セッションの変異監査が `SessionsClient.swift` へ単点変異を
// 植えた所、request の path を `api/sessions` → `api/session` に変えても、
// `httpMethod` を `"GET"` → `"POST"` に変えても、214 件が全部緑のまま通った。
// 検査が返り値の分岐だけを見ていて、**線の上に何を出すか**を一度も見ていなかった。
//
// 実測した当時の状態(client 4本 x 記録欄):
//   Healthz  URL 0 / header 0     History  URL 1 / header 1
//   Poll     URL 3 / header 1     Sessions URL 0 / header 1
//   method に至っては Mock が記録欄すら持っていなかった = 全 client 揃って盲。
//
// ★直し方を「足りない検査を書く」で終わらせない理由。History と Poll は URL を見ていて
//   Sessions と Healthz は見ていない —— **規約は既に在って、守るかどうかが手書き**
//   だった、という形である。同じ夜に同じ形を4回踏んでいる(DESIGN §2.18-10)。
//   なので此処は、**どの client を見るか**も**何を見せるか**も木から導出する:
//     ① 対象 = `ios/Sources/` で `URLRequest` を**組み立てている** file を全部(一覧を持たない)
//     ② 見るべき次元 = `MockURLProtocol` が持つ記録欄を全部(一覧を持たない)
//   client を足した人も、記録欄を足した人も、書き忘れた瞬間に赤が出る。
//
// ★①が最初 `Sources/Core/*Client.swift` だった事で、この検査自身が同じ穴を持っていた
//   (2026-08-06 に判明)。`SessionsAuthProbe.swift` は綴りが `…Probe` なので走査に
//   一度も掛からず、**bearer 鍵を載せた request** の URL / method / body が全部
//   無監視のまま緑だった —— 「守りが無い」ではなく「守りが**届かない**」、この file が
//   書かれた元の finding と同じ形である。名前で選ぶのをやめ、**その file が実際に
//   `URLRequest` を作っているか**で選ぶ形に変えた。`…Poller` でも `…Uploader` でも
//   掛かるので、次に同じ抜け方はしない。
//
// ★期待値までは強制しない。「Authorization が付く事」ではなく「header を**見ている**事」
//   だけを見る。healthz の様に認証を付けない口が在っても、正しい検査は
//   「付いていない事」を見る = どちらにせよ記録欄を読む。値を決め打つと、
//   **存在しない区別を固定する検査**を書かせる側に回る(同日、header 名の大小で実際に
//   その一歩手前まで行った。Foundation が正規化するので直す物が無かった)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
// 継ぎ目。陰性対照が**合成した木**へ向けて同じ判定を回す為だけに在る。
// 既定は必ず本物の木で、env が無ければ振る舞いは変わらない。
const REPO = process.env.RC_REQUEST_SHAPE_REPO || dirname(ROOT);
const IOS = join(REPO, "ios");

const SOURCES = join(IOS, "Sources");
const TESTS = join(IOS, "Tests");
const MOCK = join(TESTS, "Support", "MockURLProtocol.swift");

/**
 * 記録欄を読まなくてよい client と、その理由。
 *
 * ★空で始める。空のまま在るのは「今は例外が無い」を**書き残す**為で、
 *   例外が要る日に「名前と理由を書く以外の道が無い」形にしておくのが目的。
 *   ここに足す時は、なぜその次元を見なくてよいのかを書く事。
 *   「まだ書いていない」は理由ではない。
 */
const EXEMPT = {
  // 例: "HealthzClient": { lastRequestHeaders: "この口は認証を付けない設計であり…" }
};

/** 木を下って `.swift` を全部集める。 */
export function swiftFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...swiftFiles(full));
    else if (entry.endsWith(".swift")) out.push(full);
  }
  return out;
}

/**
 * 行頭が注釈の行は読み飛ばす。注釈で `URLRequest` に言及するのは正当で、
 * 実際この file を直した時に増えたのがまさにその注釈である。
 * (出所は `test/session-guard.test.mjs` の同じ判断)
 */
function isComment(line) {
  const t = line.trim();
  return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*");
}

/**
 * 「request を組み立てている file」を**綴りでなく振る舞い**で選ぶ。返すのは型名
 * (= file 名から `.swift` を落とした物)で、`<型名>Tests.swift` が対になる検査。
 */
export function requestBuildersIn(sourceFiles) {
  return sourceFiles
    .filter(({ text }) =>
      text.split("\n").some((line) => !isComment(line) && /URLRequest\(url:/.test(line)))
    .map(({ name }) => name)
    .sort();
}

/** `MockURLProtocol` が持つ記録欄の名前を、その file から導く。 */
export function recordersIn(mockSource) {
  return [...mockSource.matchAll(/^\s*static var (requested\w+|lastRequest\w+)\s*[:=]/gm)]
    .map((m) => m[1])
    .sort();
}

/**
 * client 1本分の判定。読んでいない記録欄の名前を返す(空 = 合格)。
 *
 * ★注釈行は数えない(2026-08-06)。初版は file 全文に対する `includes` で、
 *   「`requestedTimeouts` が何を証明して何を証明しないかは …」と**注釈に書いただけ**の
 *   file が合格していた。実際にこの検査を直している最中に、自分が足した doc 注釈で
 *   assertion 抜きの合格を作れる事に気付いた —— 綴りの出現を観測と読む形で、
 *   この repo が「数えるのは一致であって存在ではない」と何度も呼んでいる物と同じ。
 */
export function unobservedDimensions(clientName, testSource, recorders, exempt = {}) {
  const skip = exempt[clientName] || {};
  const code = testSource.split("\n").filter((l) => !isComment(l)).join("\n");
  return recorders.filter((r) => !Object.hasOwn(skip, r) && !code.includes(r)).sort();
}

/**
 * 電話側の木そのものが**居ない**時(= `rc-backend/` だけを写した部分木。変異走行と
 * `test/copied-tree-controls.sh` がこの形で回す)は、赤ではなく**測っていない**。
 *
 * ★「木が無い」と「木は在るのに走査が何も拾わない」を1つの籠に入れない。前者は測る対象が
 *   此処に無いだけで、後者は走査が的を外している = 守っているつもりの物が守られていない。
 *   混ぜると、部分木で回る全ての道(変異走行を含む)がこの file だけの理由で赤になり、
 *   走行そのものが起動できなくなる —— 実際に 2026-08-05 の commit A でそれを出した。
 *   出所は `test/session-guard.test.mjs` の同じ判断(そちらが先行)。
 */
const IOS_PRESENT = existsSync(IOS);
function skipIfPartialTree() {
  if (IOS_PRESENT) return false;
  console.log(`測っていない: 電話側の木が居ない (${IOS}) = 部分木で回されている`);
  return true;
}

const CLIENTS = existsSync(SOURCES)
  ? requestBuildersIn(
      swiftFiles(SOURCES).map((f) => ({ name: basename(f, ".swift"), text: readFileSync(f, "utf8") })))
  : [];

/** 型名 → 対になる検査 file。`Tests/` の何処に置いても拾う(木の形を固定しない)。 */
const TEST_FILES = existsSync(TESTS)
  ? new Map(swiftFiles(TESTS).map((f) => [basename(f, ".swift"), f]))
  : new Map();

test("★request を組み立てる file を1本も見つけられない = 走査が的を外している(空振りで緑にしない)", () => {
  if (skipIfPartialTree()) return;
  assert.ok(
    CLIENTS.length > 0,
    `${SOURCES} に \`URLRequest(url:\` を書いている file が1本も無い。` +
      `木が動いたか、綴りが変わったか、走査の場所が古い`,
  );
});

test("★記録欄を1つも見つけられない = 判定の基準が空(全 client が自動で合格になる)", () => {
  if (skipIfPartialTree()) return;
  assert.ok(existsSync(MOCK), `${MOCK} が無い。この検査の基準はこの file から導いている`);
  assert.ok(
    recordersIn(readFileSync(MOCK, "utf8")).length > 0,
    "MockURLProtocol に `requested*` / `lastRequest*` の記録欄が1つも無い。" +
      "改名したなら、この検査が拾う綴りも一緒に直す事",
  );
});

test("request を組み立てる file ごとに、対になる検査 file が在る", () => {
  // ★ここは木が無いと `CLIENTS` が空 → `missing` も空 → **黙って緑**になる。
  //   空振りの緑は「全 client 合格」に見えるので、名指しで測っていないと言わせる。
  if (skipIfPartialTree()) return;
  const missing = CLIENTS.filter((n) => !TEST_FILES.has(`${n}Tests`));
  assert.deepEqual(missing, [], "検査 file を持たない request 組み立て file が在る");
});

test("★★各 client の検査が、request の全次元を実際に見ている", () => {
  if (skipIfPartialTree()) return;
  const recorders = recordersIn(readFileSync(MOCK, "utf8"));
  const bad = [];
  for (const name of CLIENTS) {
    const t = TEST_FILES.get(`${name}Tests`);
    if (!t) continue; // 上の検査が別途赤くする
    const un = unobservedDimensions(name, readFileSync(t, "utf8"), recorders, EXEMPT);
    if (un.length) bad.push(`${name}: ${un.join(", ")}`);
  }
  assert.deepEqual(
    bad, [],
    "request の或る次元を一度も見ていない検査が在る。\n" +
      "  その次元は今、変異を植えても赤くならない = 実質守られていない。\n" +
      "  検査を足すか、EXEMPT に**理由付きで**名指しするか、どちらかを必ず選ぶ事",
  );
});

test("陰性対照: 判定が見分けている(常に緑を返しているのではない)", () => {
  const R = ["lastRequestHeaders", "requestedURLs"];
  // 読んでいない次元は名指しされる
  assert.deepEqual(unobservedDimensions("X", "XCTAssertEqual(1, 1)", R), R);
  // 片方だけ読んでいれば、残りだけが出る
  assert.deepEqual(
    unobservedDimensions("X", "MockURLProtocol.requestedURLs.last", R),
    ["lastRequestHeaders"],
  );
  // 両方読んでいれば空
  assert.deepEqual(
    unobservedDimensions("X", "requestedURLs lastRequestHeaders", R),
    [],
  );
  // ★免除は client ごと。片方に書いた1行がもう片方にも効くと、書いた覚えの無い client が
  //   黙って範囲外になる —— 今夜 no-linerefs の除外一覧で潰したのと同じ形。
  const ex = { A: { requestedURLs: "理由" } };
  assert.deepEqual(unobservedDimensions("A", "", R, ex), ["lastRequestHeaders"]);
  assert.deepEqual(unobservedDimensions("B", "", R, ex), R);
  // ★注釈で綴りを出しただけでは「見ている」にならない。code の行なら通る。
  assert.deepEqual(
    unobservedDimensions("X", "    /// requestedURLs と lastRequestHeaders の話\n", R),
    R,
  );
  assert.deepEqual(
    unobservedDimensions("X", "    /// requestedURLs の話\n    XCTAssertEqual(MockURLProtocol.requestedURLs.count, 1)\n", R),
    ["lastRequestHeaders"],
  );
  // 記録欄の導出そのものも見分けている
  assert.deepEqual(
    recordersIn("    static var requestedURLs: [URL] = []\n" +
                "    static var lastRequestHeaders: [String: String]?\n" +
                "    static var stubQueue: [Stub] = []\n"),
    ["lastRequestHeaders", "requestedURLs"],
  );
});

/**
 * 対象の導出が**名前でなく振る舞い**で選んでいる事。
 *
 * ★これが此処に在る理由は具体的な失敗である。2026-08-06 まで導出は
 *   `*Client.swift` という**綴り**で、`SessionsAuthProbe.swift` は bearer 鍵付きの
 *   request を出しながら一度も検査されていなかった。綴りに戻す変更は、この repo で
 *   一番起きやすい退行(「名前で括るのが簡単だから」)なので、合成した木で名指しする。
 */
test("陰性対照: 対象の導出は綴りでなく `URLRequest` を作っているかで選ぶ", () => {
  const synthetic = [
    // 名前が `Client` で終わらなくても、作っていれば選ばれる ← 塞いだ穴そのもの
    { name: "SessionsAuthProbe", text: "        var request = URLRequest(url: u)\n" },
    // 名前が `Client` で終わっても、注釈で言及しているだけなら選ばれない
    { name: "QuietClient", text: "        // var request = URLRequest(url: u) の様に書く\n" },
    // 何も作らない file は当然選ばれない
    { name: "SessionsModels", text: "struct Sessions: Decodable {}\n" },
  ];
  assert.deepEqual(requestBuildersIn(synthetic), ["SessionsAuthProbe"]);

  // 1本も作っていない木は空を返す = 上の「空なら赤」の検査が意味を持つ
  assert.deepEqual(requestBuildersIn([{ name: "OnlyModels", text: "struct A {}" }]), []);
});
