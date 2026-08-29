// 会話画面の灰色の帯(`.bar`)は composer だけの物で、「以前を読む」には敷かれていないか。
//
// ── 何を守るか(2026-08-08、監査 X-3)────────────────────────────────────────
// この画面で `.bar` は材質であると同時に**意味**を持っている: 灰色の地に居る物は
// 「電話の道具」で、白い地に居る物は「机から来た中身」。転写を遡る入口である
// 「以前を読む」に灰色を敷いていた頃、それは composer の道具として読めていた。
//
// 撮った3枚での実測(当てる前):
//   帯の上端 y = 2212 / 「以前を読む」の文字の y = 2267  → 文字は帯の**中**
//   行の地: ボタン 246 / composer 247 / 転写 255         → ボタンは composer と同色
//
// ── なぜ**この形**の検査なのか(限界を先に書く)─────────────────────────────
// これは**バイトの検査であって、描かれた画素の検査ではない**。XCUITest は色も材質も
// 読めないので、「灰色に見えない事」を実行時に測る道はこの repo に無い。測れるのは
// 「灰色を敷く修飾子が、その View の中に書かれていない事」まで。
//
// それでも置く理由は X-1 と同じで、実測に基づく: あれは判定も文言も正しく単体も
// 全部緑のまま、画面上でだけ間違っていた欠陥だった。撮って直しても、次に誰かが
// 画面の下端を「揃える」時に黙って戻る。戻った事を commit の門で言える形にしておく。
//
// 負の対照: `ios/tools/bar-material-control.sh`(4本)。
// ★書き始めた時、此処には「対照は書かない —— 赤くなる検査が此処に無いので、対照の
//   顔をした空回りになる」と書いていた。手で変異を植てみたら**当の検査が赤くなり**、
//   前提が偽だと判ったので撤回した。赤くなる物が在るのに対照を置かないのは、
//   設計判断ではなくただの省略。この訂正の順序ごと記録として残す。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { requireOutside, REPO, REPO_INTACT } from "./subtree.mjs";

const VIEW = "ios/Sources/Screens/Conversation/ConversationView.swift";
const GATE = requireOutside(["ios", VIEW]);

// 綴りを組み立てる。この file 自身の中に探している綴りが素で現れると、走査を
// 自分自身に向けた時に自分を捕まえる(no-linerefs.test.mjs と同じ配慮)。
// ★2026-08-29: composer の帯が**系ごとに2つの綴り**になった。glass の系では
//   `.background(.bar)` を捨て、ガラスの面(material の Rectangle + 髪の毛1本の縁)に
//   替えた —— Tom「灰色の帯が洗練されていない」。非 glass の系は `.bar` のまま
//   (`Rectangle().fill(.bar)`)なので、綴りが `.background(` から `.fill(` へ動いた。
//   守る不変条件は変わらない:**帯は composer だけの物で、「以前を読む」には敷かれない**。
//   だから検査は綴りを1つ追うのをやめ、**帯を作る2つの手段の両方**を測る。
const BAR = ".fill(" + ".bar)";
// glass の系で帯を作る材質。composer 以外にも出る綴り(道具チップ・入力欄)なので
// **数では押さえない** —— footer に入っていない事だけを測る。
const GLASS_BAR = ".ultraThin" + "Material";
const FOOTER_DECL = "private var loadEarlierFooter: some View {";

const source = () => readFileSync(join(REPO, VIEW), "utf8");

/**
 * `loadEarlierFooter` の本体を、宣言行から中括弧の深さが 0 に戻るまでで切り出す。
 *
 * 文字列 literal の中の中括弧は数に入れてしまうが、この View の文言に中括弧は
 * 1つも無い(下の錨が両端を実名で押さえるので、壊れれば錨が赤くなる)。
 */
function footerBlock(text = source()) {
    const lines = text.split("\n");
    const start = lines.findIndex((l) => l.includes(FOOTER_DECL));
    if (start < 0) return null;
    let depth = 0;
    const out = [];
    for (let i = start; i < lines.length; i += 1) {
        out.push(lines[i]);
        for (const ch of lines[i]) {
            if (ch === "{") depth += 1;
            else if (ch === "}") depth -= 1;
        }
        if (i > start && depth === 0) return out.join("\n");
    }
    return null;
}

// ── 錨① 切り出しが本当に当たっている ──────────────────────────────────────
// 下の主張は「入っていない」= 否定だけなので、切り出しが空を返しても緑になる。
// だから件数ではなく**両端を実名で**押さえる —— 頭は入口の文言、尻は最後の識別子、
// そして次の View の識別子が**入っていない**事(= 早すぎず遅すぎず終わっている)。
test("loadEarlierFooter の切り出しが両端とも合っている", { skip: GATE.skip }, () => {
    const block = footerBlock();
    assert.ok(block, `${FOOTER_DECL} が見つからない = 以下は何も測っていない`);
    assert.ok(block.includes("Load earlier"), "入口の文言が切り出しに入っていない");
    assert.ok(
        block.includes("conversation.loadEarlierCeiling"),
        "上限の枝まで届いていない = 切り出しが早く終わっている",
    );
    assert.ok(
        !block.includes("conversation.gapNotice"),
        "次の View まで飲み込んでいる = 切り出しが遅く終わっている",
    );
});

// ── 錨② 探している綴りが、そもそもこの file に在る ────────────────────────
// 修飾子ごと改名・撤去されると「footer に入っていない」は中身を見ずに緑になる。
// 錨が落ちた日に直すのは実装ではなく、この検査が探している綴りの方。
test(`${BAR} は会話画面の何処かに在る`, { skip: GATE.skip }, () => {
    assert.ok(
        source().includes(BAR),
        `${BAR} が会話画面から消えた。composer の帯ごと無くなったのか、綴りが変わったのか`,
    );
});

// ★同じ錨を glass の系にも張る(2026-08-29)。片方だけ錨が在ると、glass 側の帯を
//   誰かが消した日に「footer に入っていない」が中身を見ずに緑になる。
test(`${GLASS_BAR} は会話画面の何処かに在る`, { skip: GATE.skip }, () => {
    assert.ok(
        source().includes(GLASS_BAR),
        `${GLASS_BAR} が会話画面から消えた。glass の系の帯ごと無くなったのか、綴りが変わったのか`,
    );
});

// ── 主張 ──────────────────────────────────────────────────────────────────
test("灰色の帯は composer だけ —— 「以前を読む」には敷かれていない", { skip: GATE.skip }, () => {
    const text = source();
    const block = footerBlock(text);
    assert.ok(!block.includes(BAR), [
        "「以前を読む」に灰色の帯が戻っている(監査 X-3)。",
        "  この画面で灰色は「電話の道具」の意味を持つので、敷くと転写を遡る入口が",
        "  composer の道具として読める。DESIGN.md の 2.63 に撮った時の数が在る。",
    ].join("\n"));
    // 会話画面に残ってよい `.bar` は composer の1つだけ。数で押さえるのは、
    // footer 以外の場所に増えた時も気付ける様にする為。
    const count = text.split(BAR).length - 1;
    assert.equal(count, 1, `会話画面の灰色の帯が ${count} 箇所。composer の1つだけである事`);
    // ★glass の系の帯も同じ線を守る(2026-08-29)。此方は数で押さえない ——
    //   material は道具チップと入力欄でも使う正当な材質なので、数の主張は必ず腐る。
    //   測るのは意味の在る1点だけ:**「以前を読む」に面を敷いていない事**。
    assert.ok(!block.includes(GLASS_BAR), [
        "「以前を読む」にガラスの面が敷かれている(監査 X-3 の glass 版)。",
        "  灰色でもガラスでも、面を敷けば其処は「電話の道具」に見える —— 材質が変わっても",
        "  意味は変わらないので、この線は両方の系で同じ場所に引く。",
    ].join("\n"));
});

// ★逃げ道の錨。上の3本が `GATE.skip` で飛べるので、完全な木で**飛んでいない**事を
//   1本だけ主張する。此処が壊れて常に飛ぶ様になれば、完全な木でこの錨が赤くなる。
test("この木では『部分木だから測らない』を通っていない", { skip: !REPO_INTACT && "部分木の写し" }, () => {
    assert.equal(GATE.skip, false, `親は健在なのに ios を測っていない: ${GATE.skip}`);
});
