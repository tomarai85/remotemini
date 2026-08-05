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
//     ① 対象 = `ios/Sources/Core/*Client.swift` を全部(一覧を持たない)
//     ② 見るべき次元 = `MockURLProtocol` が持つ記録欄を全部(一覧を持たない)
//   client を足した人も、記録欄を足した人も、書き忘れた瞬間に赤が出る。
//
// ★期待値までは強制しない。「Authorization が付く事」ではなく「header を**見ている**事」
//   だけを見る。healthz の様に認証を付けない口が在っても、正しい検査は
//   「付いていない事」を見る = どちらにせよ記録欄を読む。値を決め打つと、
//   **存在しない区別を固定する検査**を書かせる側に回る(同日、header 名の大小で実際に
//   その一歩手前まで行った。Foundation が正規化するので直す物が無かった)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
// 継ぎ目。陰性対照が**合成した木**へ向けて同じ判定を回す為だけに在る。
// 既定は必ず本物の木で、env が無ければ振る舞いは変わらない。
const REPO = process.env.RC_REQUEST_SHAPE_REPO || dirname(ROOT);
const IOS = join(REPO, "ios");

const CORE = join(IOS, "Sources", "Core");
const CORE_TESTS = join(IOS, "Tests", "Core");
const MOCK = join(IOS, "Tests", "Support", "MockURLProtocol.swift");

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

/** `MockURLProtocol` が持つ記録欄の名前を、その file から導く。 */
export function recordersIn(mockSource) {
  return [...mockSource.matchAll(/^\s*static var (requested\w+|lastRequest\w+)\s*[:=]/gm)]
    .map((m) => m[1])
    .sort();
}

/** client 1本分の判定。読んでいない記録欄の名前を返す(空 = 合格)。 */
export function unobservedDimensions(clientName, testSource, recorders, exempt = {}) {
  const skip = exempt[clientName] || {};
  return recorders.filter((r) => !Object.hasOwn(skip, r) && !testSource.includes(r)).sort();
}

const CLIENTS = existsSync(CORE)
  ? readdirSync(CORE).filter((f) => f.endsWith("Client.swift")).sort()
  : [];

test("★client を1本も見つけられない = 走査が的を外している(空振りで緑にしない)", () => {
  assert.ok(
    CLIENTS.length > 0,
    `${CORE} に \`*Client.swift\` が1本も無い。木が動いたか、走査の場所が古い`,
  );
});

test("★記録欄を1つも見つけられない = 判定の基準が空(全 client が自動で合格になる)", () => {
  assert.ok(existsSync(MOCK), `${MOCK} が無い。この検査の基準はこの file から導いている`);
  assert.ok(
    recordersIn(readFileSync(MOCK, "utf8")).length > 0,
    "MockURLProtocol に `requested*` / `lastRequest*` の記録欄が1つも無い。" +
      "改名したなら、この検査が拾う綴りも一緒に直す事",
  );
});

test("client ごとに、対になる検査 file が在る", () => {
  const missing = CLIENTS.map((f) => basename(f, ".swift"))
    .filter((n) => !existsSync(join(CORE_TESTS, `${n}Tests.swift`)));
  assert.deepEqual(missing, [], "検査 file を持たない client が在る");
});

test("★★各 client の検査が、request の全次元を実際に見ている", () => {
  const recorders = recordersIn(readFileSync(MOCK, "utf8"));
  const bad = [];
  for (const f of CLIENTS) {
    const name = basename(f, ".swift");
    const t = join(CORE_TESTS, `${name}Tests.swift`);
    if (!existsSync(t)) continue; // 上の検査が別途赤くする
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
  // 記録欄の導出そのものも見分けている
  assert.deepEqual(
    recordersIn("    static var requestedURLs: [URL] = []\n" +
                "    static var lastRequestHeaders: [String: String]?\n" +
                "    static var stubQueue: [Stub] = []\n"),
    ["lastRequestHeaders", "requestedURLs"],
  );
});
