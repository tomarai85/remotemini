// 電話の要約 fixture が、**机が実際に作れる文**しか名乗っていないか。
//
// ── 何を守るか(2026-09-01)────────────────────────────────────────────────
// `ios/Sources/Core/DigestFixture.swift` の `"line"` は、机の `digestLine()` が
// 吐いた物の写しである事になっている。写しが漂流すると、**サーバに作れない画面**を
// 根拠に電話側の分岐・版面・私の判断が組まれる。
//
// 実際に起きた事: fixture が `— nothing waiting on you.` と名乗っていた。
// `digestLine()` が出す末尾は 4 通りしか無く、其の文字列は**1 つも含まれない**。
// しかも其の項目は `action.level = "none"` で、机なら `— still working.` と言う。
// 画で見ると「Waiting on you」の 2 行下に「nothing waiting on you」が並び、
// **1 画面が正反対の事を言っていた**。私は其れを「本番でも再現する製品の欠陥」と
// 読んで直しかけ、机の実装を読んで初めて**再現し得ない**と判った。
//
// ★同型の前科が在る: `PollFixture.swift` が机より綺麗な選択肢の文を手書きし、
//   実在しない画面を指す分岐が書かれた(`ConversationViewModel` の
//   `interruptDisabledReason` の頭に経緯が残っている)。あの時の対策は
//   「机が作れる物に fixture を釘付けする backend 検査」。**要約の fixture は
//   其の網から漏れていた**ので、同じ形の網を此処に張る。
//
// ── 測り方の限界を先に書く ────────────────────────────────────────────────
// これは**末尾の語形の検査**であって、数値(60m / 1 reply)が正しいかは見ない。
// 頭の部分は窓の集計なので、fixture 側で自由に決めてよい —— 嘘になるのは
// 「机が言えない語形を名乗る」時だけ。だから末尾だけを釘付けにする。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { requireOutside, REPO } from "./subtree.mjs";
import { digestLine } from "../src/digest.mjs";

const FIXTURE = "ios/Sources/Core/DigestFixture.swift";
const GATE = requireOutside(["ios", FIXTURE]);

/** `digestLine()` が出し得る末尾を、**実装を呼んで**作る(手で書き写さない)。 */
function legalTails() {
    const d = { complete: true, window: { minutes: 60 }, counts: {}, tools: [] };
    const levels = [
        { level: "now", reason: "observed" },
        { level: "soon", reason: "observed" },
        { level: "none", reason: "observed" },
        { level: "wat", reason: "unknown" },   // 既定の枝
    ];
    // 頭は捨てて、`— ` から後ろだけを取る。
    return levels.map((a) => {
        const line = digestLine(d, a);
        const i = line.indexOf("— ");
        return line.slice(i);
    });
}

/** fixture の中の `"line":"…"` を全部取り出す。 */
function fixtureLines() {
    const text = readFileSync(join(REPO, FIXTURE), "utf8");
    return [...text.matchAll(/"line":"([^"]*)"/g)].map((m) => m[1]);
}

// ── 錨: そもそも読めているか ─────────────────────────────────────────────
// 下の主張は「全部が合法」= 全称なので、0 件でも緑になる。件数を先に押さえる。
test("要約 fixture の行が読める(以下が空虚でない事)", { skip: GATE.skip }, () => {
    const lines = fixtureLines();
    assert.ok(lines.length >= 3, `"line" が ${lines.length} 本しか取れない = 抽出が壊れている`);
});

test("digestLine() の末尾が 4 通り取れる(実装側の錨)", { skip: GATE.skip }, () => {
    const tails = legalTails();
    assert.equal(new Set(tails).size, 4, "末尾が 4 通りでない = 実装が変わったか抽出が壊れた");
    for (const t of tails) assert.ok(t.startsWith("— "), `末尾の切り出しが失敗: ${t}`);
});

// ── 主張 ──────────────────────────────────────────────────────────────────
test("★fixture の行は、机が作れる末尾しか名乗らない", { skip: GATE.skip }, () => {
    const tails = legalTails();
    // `(reason)` は可変なので、括弧の中身を伏せて比べる。
    const shapes = tails.map((t) => t.replace(/\([^)]*\)/, "(*)"));
    for (const line of fixtureLines()) {
        const i = line.lastIndexOf("— ");
        assert.ok(i >= 0, `末尾の区切り「— 」が無い: ${line}`);
        const shape = line.slice(i).replace(/\([^)]*\)/, "(*)");
        assert.ok(
            shapes.includes(shape),
            [
                `机が作れない文を fixture が名乗っている: ${JSON.stringify(shape)}`,
                `  作れるのは: ${shapes.map((s) => JSON.stringify(s)).join(" / ")}`,
                "  ★これを許すと、サーバに存在しない画面を根拠に電話側の分岐と版面が組まれる。",
            ].join("\n"),
        );
    }
});
