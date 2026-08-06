// 電話側の HTTP が、転送を拒否するセッション以外を通っていないか。
//
// 経緯 (2026-08-05, Sprint 1 の Evaluator が Finding 1 として出した):
//   `HealthzClient` / `SessionsAuthProbe` は `init(session: URLSession = ...)` という形で、
//   既定値だけが守られたセッションだった。**既定値は制約ではない** —— 呼ぶ側が素の
//   `URLSession` を渡せば N5(3xx を追わない)は黙って消える。しかも実際にそう渡していたのは
//   Sprint 1 のテスト自身で、モックが delegate 無しのセッションを返していたため、
//   ネットワーク層のテストは N5 を**一度も踏んでいなかった**。両方緑で、その隙間が見えない。
//
// 直し方は2段階で、この検査は2段目:
//   ① 型で縛る  = client の引数を `BackendSession` にした。素のセッションは**コンパイルが通らない**。
//   ② この検査  = そもそも `URLSession` を自分で作る/掴む file が現れたら赤にする。
//
// ★①だけでは足りない理由: Sprint 2-6 は List / 会話 / poll / 送信 / 割り込みで
//   それぞれ HTTP を足す。新しい file が `URLSession.shared.data(...)` と直に書けば、
//   ①の型はその道に一切かからない。poll と送信は bearer 鍵を載せるので、
//   そこで転送を追うのは N5 が防ぐつもりだった漏洩そのものになる。
//   守りが「無い」のではなく「**届かない**」欠陥は緑の顔で素通りする —— 同じ形を
//   `no-linerefs.test.mjs` が 8/05 に踏んでいる(走査が ios の木に届いていなかった)。
//
// 規則は1行: **`ios/Sources/` の中で `URLSession` という綴りが出てよい file は1つだけ**。
//   (`URLSessionConfiguration` は除く —— 設定を組み立てて `BackendSession(configuration:)` に
//    渡すのは正しい使い方で、そこに delegate を選ぶ余地は無い)
//   将来これが正当に要る日が来たら、下の許可一覧に**理由を書いて足す**。
//   足す手間がそのまま「これは意図した抜け道です」という記録になる。
//
// ★限界(承知の上): 走査は行単位で、行頭が `//` `*` `/*` の行は読み飛ばす。注釈の中で
//   `URLSession` に言及するのは正当だから(この直し自体がその注釈を増やした)。
//   ブロック注釈の中に code を隠せば抜けられるが、それはコンパイルが通らない。
//
// ★木が居ない時は緑で抜ける(赤ではない)。変異走行は `rc-backend/` だけの部分木で回るので、
//   ここが赤い造りだと走行中の**全件**が「検出」に化ける。測っていない事は下で名指しで出す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = dirname(ROOT);
const SOURCES = join(REPO, "ios", "Sources");

/** 綴りが出てよい file。**理由を書かずに足さない事**。 */
const ALLOWED = new Map([
  ["Core/BackendSession.swift", "ここが唯一の生成点。delegate を引数に取らず自分で付けるので、この型を持っている事が N5 の証明になる"],
]);

/** `URLSessionConfiguration` は除く。それ以外の `URLSession*` は全部拾う。 */
const FORBIDDEN = /URLSession(?!Configuration)/;

function swiftFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) out.push(...swiftFiles(full));
    else if (entry.endsWith(".swift")) out.push(full);
  }
  return out;
}

/** 行頭が注釈の行は読み飛ばす(注釈で言及するのは正当)。 */
function isComment(line) {
  const t = line.trim();
  return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*");
}

function scan() {
  const hits = [];
  for (const file of swiftFiles(SOURCES)) {
    const rel = relative(SOURCES, file);
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      if (isComment(line) || !FORBIDDEN.test(line)) return;
      hits.push({ rel, line: i + 1, text: line.trim() });
    });
  }
  return hits;
}

test("電話側で URLSession を掴んでよいのは BackendSession だけ", () => {
  if (!existsSync(SOURCES)) {
    // 部分木。0 に丸めず、測っていない事を名前で出す。
    console.log(`測っていない: 電話側の木が居ない (${SOURCES}) = 部分木で回されている`);
    return;
  }

  const hits = scan();
  const stray = hits.filter((h) => !ALLOWED.has(h.rel));
  assert.deepEqual(
    stray.map((h) => `${h.rel}:${h.line}  ${h.text}`),
    [],
    "この file が自分でセッションを掴むと、転送を拒否する delegate を通らない道が1本できる。" +
      "BackendSession を受け取る形に変えるか、正当なら test/session-guard.test.mjs の ALLOWED に理由を書いて足す",
  );
});

/**
 * 要求を組み立てる file と、待ち時間を載せる file が**一致**するか(2026-08-06)。
 *
 * 経緯: REQUIREMENTS §5-6 の実測で、全要求が1本の 30 秒を共有していた事が
 * 「接続は通るが応答が来ない網で 30 秒の白画面」として出た。読む側だけ 8 秒に分けたが、
 * その1行は **client 7 本にそれぞれ手で書いた行**なので、8 本目の client を足して
 * 書き忘れても既存のテストは全部緑のまま通る。
 *
 * ★「1本でも在るか」で見ない理由: この repo は同じ形を 2026-08-06 に踏んでいる —
 *   `verify-script-controls.sh` の C7 は「採点される足が1本でも在るか」しか見ておらず、
 *   6本目を足して採点を書き忘れた回を素通しした。**数えるのは一致であって存在ではない**。
 */
test("要求を組み立てる file は全部、待ち時間を自分で載せている", () => {
  if (!existsSync(SOURCES)) {
    console.log(`測っていない: 電話側の木が居ない (${SOURCES}) = 部分木で回されている`);
    return;
  }

  const builds = new Set();
  const declares = new Set();
  for (const file of swiftFiles(SOURCES)) {
    const rel = relative(SOURCES, file);
    for (const line of readFileSync(file, "utf8").split("\n")) {
      if (isComment(line)) continue;
      if (/URLRequest\(url:/.test(line)) builds.add(rel);
      if (/\.timeoutInterval\s*=/.test(line)) declares.add(rel);
    }
  }

  // 空振り防止。走査が何も見つけない形になったら、下の deepEqual は [] === [] で緑になる。
  assert.ok(
    builds.size > 0,
    "要求を組み立てる file が 0 本 = 走査が木に届いていない。この検査は測定になっていない",
  );

  assert.deepEqual(
    [...builds].filter((f) => !declares.has(f)).sort(),
    [],
    "この file は URLRequest を作るのに待ち時間を載せていない。session の既定(pollTimeout=30秒)に" +
      "落ちるので、利用者が空白の画面で 30 秒待つ道が1本増える。" +
      "読む物なら BackendSession.interactiveTimeout、送る物なら writeTimeout を載せる",
  );
});

test("許可した file が実際に走査に掛かっている(検査が空振りしていない)", () => {
  if (!existsSync(SOURCES)) return; // 上のテストが名指しで報告済み

  // 空振り防止。木が動いたり file が改名されたりして走査が何も見なくなると、
  // 上のテストは「違反 0 件」で緑になる —— 0 件が緑の下に隠れる形そのもの。
  // 許可した file が**実際に綴りを含んでいる事**を錨にすれば、魔法の数字を持たずに済む。
  const hits = scan();
  for (const [rel, why] of ALLOWED) {
    assert.ok(
      hits.some((h) => h.rel === rel),
      `許可一覧の ${rel} が走査に掛からない(存在しない/改名された/綴りが消えた)。` +
        `許可した理由は「${why}」。錨が消えた以上、上のテストの緑は何も意味していない`,
    );
  }
});
