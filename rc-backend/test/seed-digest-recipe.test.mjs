// 焼く時に印字する種の指紋と、電話の中で計算する種の指紋が、同じ材料から同じ値に
// 落ちるか。**二つの言語に同じ計算が在る**ので、片方だけ直った日を捕まえる為に居る。
//
// ── 何を守るか(2026-08-11、#64)──────────────────────────────────────────
// `ios/tools/build.sh` は焼く時に `Info.plist` へ URL と鍵を刻み、その指紋を1行出す:
//     種: 刻んだ(指紋 xxxxxxxxxxxxxxxx)
// 電話の側は `SeedDigest.of` で同じ材料から指紋を作り、「此の種はもう蒔いた」の
// 判定に使う。Tom が机から遠い所で「焼いた物と電話の中身が同じか」を見る唯一の
// 手掛かりが、この二つの値が一致する事。
//
// ★一致は**設計上の願い**であって、これまで誰も測っていなかった。build.sh の
//   comment に「其れを突き合わせる検査はまだ無い」と書いてあった通りで、
//   此のファイルはその行を消す為に在る。
//
// ── 値の正本は1つ ────────────────────────────────────────────────────────
// 期待値を此処に書くと**写しが2つ**になり、片方を直した人がもう片方を知らない
// (2026-08-11 に `ios/tools/signout-notice-control.sh` の class 一覧で現に踏んだ形)。
// なので正本は Swift 側の検査(⑪)だけが持ち、此処はそれを**読んで**使う。
//   - Swift の計算が壊れる      → ⑪ が赤(XCTest)
//   - ⑪ の期待値を壊れた側へ書き換える → 此の検査が赤(build.sh は古い値を出す)
//   - build.sh の計算が壊れる   → 此の検査が赤
//
// ── 何を測っていないか ────────────────────────────────────────────────────
// 走らせているのは build.sh の python 断片**そのもののバイト**で、build.sh 全体では
// ない。断片の外(ssh で鍵を取る所、`$SEED_URL` の組み立て)は此処からは見えない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { requireOutside, REPO, REPO_INTACT } from "./subtree.mjs";

const SWIFT_TEST = "ios/Tests/Core/ProvisioningTests.swift";
const BUILD = "ios/tools/build.sh";
const GATE = requireOutside(["ios", SWIFT_TEST, BUILD]);

// 綴りが此の file の中に素で現れると、走査を自分自身へ向けた時に自分を捕まえる。
const MARK = "SEED-DIGEST" + "-CONTRACT";

/** Swift 側の検査から「材料と期待値」を読む。値の正本は向こうにしか無い。 */
function contract() {
    const text = readFileSync(join(REPO, SWIFT_TEST), "utf8");
    const head = new RegExp(`${MARK}\\s+url=(\\S+)\\s+key=(\\S+)`).exec(text);
    const hex = /let expectedDigest = "([0-9a-f]{16})"/.exec(text);
    return head && hex ? { url: head[1], key: head[2], digest: hex[1] } : null;
}

/**
 * build.sh から、刻んで読み戻して指紋を出す python 断片を**そのまま**切り出す。
 * 断片は `-c '` と、閉じの `'` + 引数行 の間に在り、中に単引用符を含まない。
 *
 * ★終端から探す。build.sh には python の断片が複数在り(机の名前を取り出す方が先)、
 *   頭から素直に取ると**別の断片**が当たる。一意なのは `Info.plist` を渡す引数行の方。
 */
function fragment() {
    const text = readFileSync(join(REPO, BUILD), "utf8");
    const open = "/usr/bin/python3 -c '";
    const end = text.indexOf("\n' \"$HERE/Info.plist\"");
    if (end < 0) return null;
    const from = text.lastIndexOf(open, end);
    return from < 0 ? null : text.slice(from + open.length, end);
}

/** 断片を走らせて、印字された指紋を返す。plist は使い捨ての空の物を渡す。 */
function stamp(py, { url, key }) {
    const plist = join(mkdtempSync(join(tmpdir(), "seed-digest-")), "Info.plist");
    writeFileSync(plist, '<?xml version="1.0" encoding="UTF-8"?>\n'
        + '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        + '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        + '<plist version="1.0"><dict></dict></plist>\n');
    const out = execFileSync("/usr/bin/python3", ["-c", py, plist, url], {
        input: key, encoding: "utf8",
    });
    return { digest: out.trim(), plist };
}

test("切り出しが現に当たっている(錨: 空振りを緑にしない)", { skip: GATE.skip }, () => {
    const c = contract();
    assert.ok(c, `Swift 側に ${MARK} の行と expectedDigest が要る`);
    assert.match(c.url, /^https:\/\//);
    assert.ok(c.key.length > 0);

    const py = fragment();
    assert.ok(py, "build.sh から python 断片を切り出せない(綴りが動いた)");
    assert.ok(py.includes("hashlib"), "断片に指紋の計算が居ない = 切り出す場所を間違えた");
    assert.ok(py.includes("RCAPIKey"), "断片に刻印が居ない = 切り出す場所を間違えた");
});

test("焼く側と電話の側が、同じ材料から同じ指紋へ落ちる", { skip: GATE.skip }, () => {
    const c = contract();
    const { digest } = stamp(fragment(), c);
    assert.equal(digest, c.digest,
        "build.sh の指紋が Swift 側の契約値と違う(片側だけ直った日)");
});

test("★指紋は現に材料に依っている(定数を返す実装を落とす)", { skip: GATE.skip }, () => {
    const c = contract();
    const py = fragment();
    const same = stamp(py, c).digest;
    const otherKey = stamp(py, { url: c.url, key: `${c.key}-rotated` }).digest;
    const otherURL = stamp(py, { url: "https://other.invalid", key: c.key }).digest;

    assert.equal(same, c.digest);
    assert.notEqual(otherKey, same, "鍵を回しても同じ指紋 = 判定が効かない");
    assert.notEqual(otherURL, same, "宛先が変わっても同じ指紋 = 判定が効かない");
});

test("刻んだ値が現に plist へ入っている(印字だけして書かない実装を落とす)", { skip: GATE.skip }, () => {
    const c = contract();
    const { plist } = stamp(fragment(), c);
    const written = readFileSync(plist, "utf8");
    assert.ok(written.includes("RCBaseURL"), "URL の鍵名が plist に無い");
    assert.ok(written.includes(c.url), "URL が plist に入っていない");
    assert.ok(written.includes("RCAPIKey"), "鍵の鍵名が plist に無い");
});

// ★逃げ道の錨。上の4本が `GATE.skip` で飛べるので、完全な木で**飛んでいない**事を
//   1本だけ主張する。此処が壊れて常に飛ぶ様になれば、完全な木でこの錨が赤くなる。
test("この木では『部分木だから測らない』を通っていない", { skip: !REPO_INTACT && "部分木の写し" }, () => {
    assert.equal(GATE.skip, false, `親は健在なのに ios を測っていない: ${GATE.skip}`);
});
