// 401 / 404 は**電話が文言でなく遷移を決める**唯一の応答なので、意味が機械で見分けられるか。
//
// 経緯 (2026-08-05): 契約を書き出す為に `json(res, 4xx, …)` を数えたら、404 が3箇所・
// 意味は2種類在った(`/api/` 以外の道 / `/api/` だが道が無い / セッション id が不明)。
// 電話側は `case 404: return .notFound` で**status だけ**を見ていたので、前2つ —— つまり
// **client が組み立てた path が間違っている**場合 —— を「セッションが見つかりません、
// 一覧へ戻る」と表示していた。利用者は消えていないセッションを探しに行かされる。
//
// ★これが単なる文言の粗さで済まない理由。request の path は同じ日の変異監査で
//   「`api/sessions` → `api/session` に変えても 214 件が緑」と実測された、この repo で
//   一番守りの薄い所である。そこへ「消えたのはセッションの方だ」という説明を被せると、
//   **一番出やすいバグを、一番それらしい嘘で隠す**組み合わせになる。
//
// 契約 (Codex 助言 2026-08-05 を受けて明文化):
//   client は表示文言を status / 本文から独自に導出せず `display` を描く。
//   但し 401(認証要求)と `code: SESSION_NOT_FOUND`(対象不在)だけは、表示判断ではなく
//   **復旧・遷移の制御**として扱ってよい。除外の根拠は「実装上そこに在るから」ではなく
//   **操作処理より手前の、プロトコル / 資源解決の結果だから**。
//
// ★この検査が見るのは「意味が語彙に載っているか」だけで、**文字列の値は決め打たない**。
//   値まで固定すると、意味を1つ足す度に此処を書き換える事になり、検査が変更の追認機に
//   なる。見たいのはそこではなく「呼び口で意味を発明していないか」である。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SERVER = join(ROOT, "src", "server.mjs");

/**
 * 遷移を決める status の一覧。**此処だけが手書き**で、理由が在る:
 * 「どの status を復旧制御に使うか」は観測ではなく**契約の決定**なので、木から導けない。
 * 代わりに、決めた事が守られているかは以下の検査が全部機械で見る。
 */
const RECOVERY_STATUSES = ["401", "404"];

/** `json(res, <status>, <第3引数>)` を拾う。第3引数は行末まで取って括弧と `;` を落とす。 */
export function recoveryEmissions(src, statuses = RECOVERY_STATUSES) {
  const re = new RegExp(`json\\(\\s*res\\s*,\\s*(${statuses.join("|")})\\s*,\\s*([^\\n]*)`, "g");
  return [...src.matchAll(re)].map((m) => ({
    status: m[1],
    arg: m[2].replace(/\)\s*;?\s*$/, "").trim(),
  }));
}

/**
 * 呼び口で意味を**発明している**物を返す(空 = 合格)。
 * 語彙 = 大文字の識別子1個。`{ error: "…" }` のような直書きは、名前が付いていない =
 * 誰も「これは新しい意味だ」と気付けない形なので落とす。
 */
export function inventedAtCallSite(emissions) {
  return emissions.filter((e) => !/^[A-Z][A-Z0-9_]*$/.test(e.arg));
}

/**
 * 応答本文へ `code` を**直書き**している `json(res, …)` の行を返す(空 = 合格)。
 *
 * ★`code` が復旧語彙**だけ**の物である事は、電話がこの鍵で画面を移す以上、契約の一部。
 *   2026-08-05 に実測した実例: 履歴の 500 が `code: String(e.code || e.message)` を
 *   返しており、`e.code` を持たない例外では **`e.message` がそのまま線に出ていた**
 *   (Node の fs 由来の文面は path を含む)。名前が同じというだけで、電話から見た
 *   `code` の意味が2つになっていた。診断は別の欄(`errno`)へ寄せた。
 */
export function jsonCallSites(src) {
  return src.split("\n").filter((l) => /json\(\s*res\s*,/.test(l)).map((l) => l.trim());
}

export function codeWrittenAtCallSite(src) {
  return jsonCallSites(src).filter((l) => /\bcode\s*:/.test(l));
}

// ★書きかけて**捨てた**検査を此処に残す(同じ物をまた書かない為)。
//   `json(res, …)` の本文へ `e.message` が入る口を全部禁じる検査を足したら5件当たった:
//     /api/account の 500 x2 ・ `bad body:` x2 ・ 最外の 500。
//   だが5件とも既に**明示的に反対の判断**が書かれていた —— 自由文は `markResult` の語彙
//   (= 艦隊のログへ出る面)からは外し、応答本文(= 認証済み・tailnet 内・読むのは Tom 本人)
//   には残す、と。新しい根拠を持たずにその判断を裏返す検査だったので落とした。
//   唯一違いうる `/api/account` の 500 も、その endpoint は**成功時に account 自体を返す**ので
//   誤りの側で新しく漏れる物が無い。
//   ★本当の欠陥は「`e.message` が線に出る」ではなく「**電話が分岐に使う欄**へ自由文が入る」で、
//     それは `code` の話。上の `codeWrittenAtCallSite` が既に丸ごと禁じている。

/** 語彙の定義のうち `code:` を持たない物の名前を返す(空 = 合格)。 */
export function vocabularyWithoutCode(src, names) {
  return [...new Set(names)].filter((n) => {
    const m = new RegExp(`const\\s+${n}\\s*=\\s*([^\\n]*)`).exec(src);
    return !m || !/\bcode\s*:/.test(m[1]);
  }).sort();
}

const SRC = readFileSync(SERVER, "utf8");
const EMISSIONS = recoveryEmissions(SRC);

test("★遷移を決める応答を1件も拾えない = 走査が的を外している(空振りで緑にしない)", () => {
  assert.ok(
    EMISSIONS.length > 0,
    `${SERVER} に \`json(res, ${RECOVERY_STATUSES.join("/")}, …)\` が1件も無い。` +
      "口が変わったか、この検査の綴りが古い",
  );
});

test("★★遷移を決める応答は、呼び口で意味を発明していない", () => {
  const bad = inventedAtCallSite(EMISSIONS).map((e) => `${e.status}: ${e.arg}`);
  assert.deepEqual(
    bad, [],
    "呼び口に本文を直書きした 401/404 が在る。\n" +
      "  電話はこの status で**画面を移す**ので、意味が1つ増えた事に誰も気付かないまま\n" +
      "  既存の遷移(鍵入力 / 一覧へ戻る)に合流する = 別の理由の失敗を別の説明で表示する。\n" +
      "  `src/server.mjs` 上部の語彙(AUTH_REQUIRED / SESSION_NOT_FOUND / NO_SUCH_ROUTE)へ\n" +
      "  名前付きで足すか、新しい意味なら新しい名前を足す事",
  );
});

test("★語彙は全部 `code` を持つ(電話が繋ぐ鍵は文言ではなくこれ)", () => {
  const names = EMISSIONS.map((e) => e.arg).filter((a) => /^[A-Z][A-Z0-9_]*$/.test(a));
  assert.ok(names.length > 0, "語彙を1つも拾えない = 上の検査が既に赤いはず");
  assert.deepEqual(
    vocabularyWithoutCode(SRC, names), [],
    "`code` を持たない語彙が在る。電話は `error` の**文言**では繋がない —— 文言を直した\n" +
      "  瞬間に動いているサーバで電話が壊れる。機械が読む鍵は `code` の側に置く事",
  );
});

test("★404 の意味が2つ以上在る事を、実際に見分けている", () => {
  const names404 = [...new Set(EMISSIONS.filter((e) => e.status === "404").map((e) => e.arg))];
  // ★数を決め打たない(「今は2種類」を固定すると、3つ目を足す変更を検査が拒む)。
  //   見たいのは「複数在るのに1つの名前へ潰していない」事だけ。
  const count404 = EMISSIONS.filter((e) => e.status === "404").length;
  if (count404 <= 1) return; // 意味が1つしか無いなら見分ける物が無い
  assert.ok(
    names404.length > 1,
    `404 が ${count404} 箇所在るのに語彙が ${names404.length} 個 (${names404.join(", ")})。\n` +
      "  全部同じ名前に潰すと、電話は「セッションが消えた」と「道が無い」を区別できない",
  );
});

// ★下の2件は「該当が無い」形の判定なので、走査そのものが空振りしていないかを先に錨で留める。
//   `json(res, …)` の口が1つも取れていないなら、両方とも**中身が空だから緑**になる。
const CALL_SITES = jsonCallSites(SRC);

test("★応答の口を1件も拾えない = 走査が的を外している(下の検査が空振りで緑になる)", () => {
  assert.ok(
    CALL_SITES.length >= 10,
    `${SERVER} から \`json(res, …)\` を ${CALL_SITES.length} 件しか拾えない。` +
      "応答を作る口の綴りが変わったか、この検査が古い",
  );
});

test("★`code` は復旧語彙だけの物(応答本文へ直に `code` を書いている口が無い)", () => {
  assert.deepEqual(
    codeWrittenAtCallSite(SRC), [],
    "`json(res, …)` の呼び口が本文へ `code` を直書きしている。\n" +
      "  電話はこの鍵で**画面を移す**ので、別の意味(errno / 内部の分類 / 自由文)を同じ名前で\n" +
      "  流すと、遷移の判断が壊れる。診断値は別の欄(`errno` 等)へ寄せ、`code` は\n" +
      "  `src/server.mjs` 上部の凍らせた語彙からしか来ない状態を保つ事",
  );
});

test("陰性対照: 判定が見分けている(常に緑を返しているのではない)", () => {
  // 呼び口の直書きは名指しされる
  const inline = "return json(res, 404, { error: \"not found\" });";
  assert.deepEqual(inventedAtCallSite(recoveryEmissions(inline)).length, 1);
  // 語彙なら通る
  const named = "return json(res, 404, NO_SUCH_ROUTE);";
  assert.deepEqual(inventedAtCallSite(recoveryEmissions(named)), []);
  // 拾う側そのものも見分けている: 対象外の status は拾わない
  assert.deepEqual(recoveryEmissions("json(res, 409, FOO);"), []);
  assert.deepEqual(recoveryEmissions("json(res, 401, BAR);"), [{ status: "401", arg: "BAR" }]);
  // `code` の有無を見分けている
  const withCode = "const A = Object.freeze({ error: \"x\", code: \"A\" });";
  const noCode = "const B = Object.freeze({ error: \"x\" });";
  assert.deepEqual(vocabularyWithoutCode(withCode, ["A"]), []);
  assert.deepEqual(vocabularyWithoutCode(noCode, ["B"]), ["B"]);
  // ★定義が**在るのに見つからない**時も「持っていない」側へ倒す(綴りが古い時に緑にしない)
  assert.deepEqual(vocabularyWithoutCode("", ["C"]), ["C"]);
  // 呼び口の `code` 直書きを見分けている
  assert.deepEqual(
    codeWrittenAtCallSite('json(res, 500, { error: "X", code: String(e.code) });').length, 1,
  );
  // 語彙を**渡すだけ**の呼び口は直書きではない(定義側の `code:` を誤検知しない)
  assert.deepEqual(codeWrittenAtCallSite("json(res, 404, NO_SUCH_ROUTE);"), []);
  assert.deepEqual(
    codeWrittenAtCallSite('const A = Object.freeze({ error: "x", code: "A" });'), [],
  );
  // 診断を別の欄へ寄せた形は通る
  assert.deepEqual(
    codeWrittenAtCallSite('json(res, 500, { error: "X", errno: errnoOf(e) });'), [],
  );
  // ★診断値を `code` へ入れる形は落ちる(= `errno` へ寄せた変更が、名前だけの言い換えで
  //   はなく実際に判定を通す為の物だった事の確認)
  assert.equal(
    codeWrittenAtCallSite('json(res, 500, { error: "X", code: String(e.code || e.message) });')
      .length, 1,
  );
  // 錨そのものも見分けている: 口が無い木では 0 を返す(= 上の錨が実際に赤くなる)
  assert.deepEqual(jsonCallSites("const x = 1;"), []);
});
