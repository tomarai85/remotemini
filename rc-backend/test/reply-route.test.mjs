// `live-http-check.mjs` の `replyRoute` に**陰性対照**を当てる。
//
// なぜ要るか(2026-08-02):
//   元の検査は「返答が SSE の message で届く」。同じ機械・同じコードで数分違いの2回が
//   `message 1 件 @0ms`(緑)と `message 0 件 @8s`(赤)に割れた。原因は退行ではなく設計 —
//   `src/server.mjs` の tail は初回に末尾へ位置合わせして過去分を流さず、代わりに
//   `gap{rereadHistory:true}` で電話に読み直させる。返答が tail の接続より先に着いた回は
//   そちらが正規の届け先になる。だから検査の側を「到達可能性」に**緩めた**。
//
//   緩めた検査には固有の壊れ方がある: 緩め過ぎると、8/02 に実際に起きた壊れ方
//   (SSE に何も流れず電話が送信後ずっと無音)を見逃す。見逃す検査は在っても意味が無い。
//   だから「読んで納得」で済ませず、**緩め過ぎ版を並べて、対照が捕まえる事を機械で確かめる**。
//   ここを試験として置いてあるのは、走らせるのを人が思い出す必要を無くすため
//   (単体の probe 台本にしていたら `npm test` に乗らず、いずれ腐る)。
import test from "node:test";
import assert from "node:assert/strict";
import { replyRoute } from "../tools/live-http-check.mjs";

// 緩め過ぎ版 = 「gap が来たなら電話は読み直せるはず」と**仮定**した物。
// 読み直した結果を見ていない所だけが違う。この1点が本番との差。
const LOOSE = (f) => (f.assistantMessages > 0 || f.rereadGaps > 0 ? "reached" : "none");

const CASES = [
  {
    name: "8/02 の本物の壊れ方 — SSE に何も流れない(電話は永久に無音)",
    facts: { assistantMessages: 0, rereadGaps: 0, replyInHistoryAfterGap: false },
    want: "none",
  },
  {
    name: "gap は来たが、読み直しても返答が無い",
    facts: { assistantMessages: 0, rereadGaps: 1, replyInHistoryAfterGap: false },
    want: "none",
  },
  {
    name: "message は流れたが user のこだまだけ(assistant を含まない)",
    facts: { assistantMessages: 0, rereadGaps: 0, replyInHistoryAfterGap: true },
    want: "none",
  },
  {
    name: "message 経路で届いた",
    facts: { assistantMessages: 1, rereadGaps: 0, replyInHistoryAfterGap: false },
    want: "message",
  },
  {
    name: "読み直し経路で届いた(返答が tail の接続より先に着いた回)",
    facts: { assistantMessages: 0, rereadGaps: 1, replyInHistoryAfterGap: true },
    want: "reread",
  },
];

test("replyRoute: 5 つの場面で経路を取り違えない", () => {
  for (const c of CASES) {
    assert.equal(replyRoute(c.facts), c.want, c.name);
  }
});

test("到達しなかった場面では none を返す(緑にしない)", () => {
  for (const c of CASES.filter((x) => x.want === "none")) {
    assert.equal(replyRoute(c.facts), "none", `緑にしてはいけない場面: ${c.name}`);
  }
});

test("★この対照は緩め過ぎ版を実際に捕まえる(空振りしていない)", () => {
  // 「本番は none、緩め過ぎ版は到達扱い」= その場面が対照として効いている。
  // 0 件なら、上の試験は全部通っていても**緩め過ぎを検出できない**= 対照として死んでいる。
  const caught = CASES.filter((c) => replyRoute(c.facts) === "none" && LOOSE(c.facts) !== "none");
  assert.ok(
    caught.length > 0,
    "緩め過ぎ版と区別が付いていない。この試験は replyRoute を緩めても通り続ける = 対照になっていない",
  );
  assert.equal(caught[0].name, "gap は来たが、読み直しても返答が無い", "捕まえている場面が入れ替わったら読み直す");
});

test("import しただけでは live 検査を起動しない", () => {
  // ここが崩れると `npm test` が本物の Claude Code を起動する。
  // この試験ファイルが最後まで走っている事自体が証拠なので、印だけ残す。
  assert.equal(typeof replyRoute, "function");
});
