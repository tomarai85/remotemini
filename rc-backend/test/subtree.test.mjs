// test/subtree.mjs の3分岐を、砂場の木で実際に踏んで固定する。
//
// この module は「木の外の対象が無い時に、赤にするか飛ばすか」を決める。両方向に
// 壊れ方が在るので両方測る:
//   常に飛ばす側へ壊れる → 改名・削除を黙って飲む(検査が消えた事に誰も気付かない)
//   常に赤にする側へ壊れる → 写しで対照1が落ち、変異が1件も回らない(2026-08-06 の再発源)
//
// 砂場は `DESIGN.md` の有無だけで「親が健在か」を作る。実物の repo は触らない。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { requireOutside, REPO, REPO_INTACT } from "./subtree.mjs";

/** 砂場を1つ作る。opts.intact=true なら親に DESIGN.md を置く。 */
function sandbox({ intact, present = [] }) {
    const dir = mkdtempSync(join(tmpdir(), "subtree-ctl-"));
    if (intact) writeFileSync(join(dir, "DESIGN.md"), "sandbox\n");
    for (const p of present) mkdirSync(join(dir, p), { recursive: true });
    return dir;
}

const withSandbox = (opts, fn) => {
    const dir = sandbox(opts);
    try {
        return fn(dir);
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
};

// ── 錨 ──────────────────────────────────────────────────────────────────
// 下の3分岐は全部砂場の話なので、砂場の作り方を間違えれば全部緑のまま無意味になる。
// だから**実物の木**に対して1本、逃げ道を通っていない事を主張しておく。
// 完全な木でしか意味を持たないので、写しの中では自分から飛ばす。
test("実物の木では『部分木だから測らない』を通っていない", { skip: !REPO_INTACT && "部分木の写し" }, () => {
    const g = requireOutside(["ios", "ios/tools/ui-fixture-absence-control.sh", "DESIGN.md"]);
    assert.equal(g.skip, false, `親は健在なのに測っていない: ${g.skip}`);
    assert.deepEqual(g.missing, [], `実物の木に無い物を頼んでいる(REPO=${REPO})`);
    assert.equal(g.measured, true);
});

test("対象が在れば測る", () => {
    withSandbox({ intact: false, present: ["ios"] }, (dir) => {
        const g = requireOutside(["ios"], { repo: dir });
        assert.equal(g.skip, false);
        assert.equal(g.measured, true);
        assert.deepEqual(g.missing, []);
    });
});

test("親が欠けた写しで対象が無ければ、赤にせず**名指しで**飛ばす", () => {
    withSandbox({ intact: false, present: [] }, (dir) => {
        const g = requireOutside(["ios", ".harness"], { repo: dir });
        assert.equal(typeof g.skip, "string", "写しで赤にすると変異走行が起動しない");
        assert.match(g.skip, /ios/, "何を測っていないかを言わない飛ばしは、黙った緑と同じ");
        assert.match(g.skip, /\.harness/);
        assert.equal(g.measured, false);
        assert.deepEqual(g.missing, ["ios", ".harness"]);
    });
});

test("親が健在なのに対象が無ければ飛ばさない(改名・削除は赤で正しい)", () => {
    withSandbox({ intact: true, present: [] }, (dir) => {
        const g = requireOutside(["ios"], { repo: dir });
        assert.equal(g.skip, false, "此処で飛ばすと、対象を消した commit が素通りする");
        assert.deepEqual(g.missing, ["ios"]);
    });
});

test("一部だけ欠けている時、欠けた物だけを挙げる", () => {
    withSandbox({ intact: false, present: ["ios"] }, (dir) => {
        const g = requireOutside(["ios", ".harness"], { repo: dir });
        assert.deepEqual(g.missing, [".harness"]);
        assert.match(g.skip, /\.harness/);
        assert.doesNotMatch(g.skip, /ios/, "在る物まで理由に混ぜると、読んだ人が探す先を間違える");
    });
});

test("intact は口で差し替えられる(砂場が実物の DESIGN.md を拾っていない事の裏取り)", () => {
    withSandbox({ intact: false, present: [] }, (dir) => {
        assert.equal(requireOutside(["ios"], { repo: dir, intact: true }).skip, false);
        assert.equal(typeof requireOutside(["ios"], { repo: dir, intact: false }).skip, "string");
    });
});
