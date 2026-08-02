// 信頼済み dir の判定(src/trust.mjs)。DESIGN §2.22 / §3-V。
//
// ★本物の `~/.claude.json` は**読まない**。使い捨ての一覧を `trustFile` で差し込む
//   (環境で結果が変わる検査は検査ではない。加えて、本物に触る道をこの file に作らない)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, symlinkSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { cwdVerdict, CWD_REFUSALS } from "../src/trust.mjs";
import { WORKER_REFUSAL } from "../src/blocked.mjs";

const root = mkdtempSync(join(tmpdir(), "rc-trust-"));
const projectDir = join(root, "Projects");
mkdirSync(projectDir);
const listFor = (map) => {
  const p = join(root, `list-${Object.keys(map).length}-${Math.abs(hash(JSON.stringify(map)))}.json`);
  writeFileSync(p, JSON.stringify({ projects: map }));
  return p;
};
function hash(s) {
  return parseInt(createHash("sha1").update(s).digest("hex").slice(0, 8), 16);
}

const TRUSTED = listFor({ [projectDir]: { hasTrustDialogAccepted: true } });

test("空の cwd は cwd_unknown(黙って $HOME で開かない)", () => {
  assert.equal(cwdVerdict("", { trustFile: TRUSTED }), "cwd_unknown");
  assert.equal(cwdVerdict(undefined, { trustFile: TRUSTED }), "cwd_unknown");
});

test("実在しない dir は cwd_missing", () => {
  assert.equal(cwdVerdict(join(root, "居ない"), { trustFile: TRUSTED }), "cwd_missing");
});

test("信頼済みなら ok", () => {
  assert.equal(cwdVerdict(projectDir, { trustFile: TRUSTED }), "ok");
});

test("★項が在っても false なら通さない", () => {
  const f = listFor({ [projectDir]: { hasTrustDialogAccepted: false } });
  assert.equal(cwdVerdict(projectDir, { trustFile: f }), "cwd_untrusted");
});

test("★真偽値でない truthy(\"true\" / 1)を通さない", () => {
  for (const v of ["true", 1, {}]) {
    const f = listFor({ [projectDir]: { hasTrustDialogAccepted: v } });
    assert.equal(cwdVerdict(projectDir, { trustFile: f }), "cwd_untrusted", `${JSON.stringify(v)} を通した`);
  }
});

test("項そのものが無ければ通さない", () => {
  const f = listFor({ [join(root, "別の場所")]: { hasTrustDialogAccepted: true } });
  assert.equal(cwdVerdict(projectDir, { trustFile: f }), "cwd_untrusted");
});

test("★一覧が読めない / 壊れている時も通さない(fail-closed の向き)", () => {
  assert.equal(cwdVerdict(projectDir, { trustFile: join(root, "無い.json") }), "cwd_untrusted");
  const broken = join(root, "broken.json");
  writeFileSync(broken, "{ これは JSON ではない");
  assert.equal(cwdVerdict(projectDir, { trustFile: broken }), "cwd_untrusted");
});

test("★一覧のどの項とも実体が一致しなければ、名前が何であれ通さない", () => {
  // 守っている性質は「これから開く**実体**が、人が承諾した**実体**と同じ」(DESIGN §2.25)。
  // 名前が信頼済みの項に似ていても、実体が違えば通らない。
  const link = join(root, "紛らわしい名前");
  const other = join(root, "untrusted-real");
  mkdirSync(other);
  symlinkSync(other, link);
  assert.equal(cwdVerdict(link, { trustFile: TRUSTED }), "cwd_untrusted");
  assert.equal(cwdVerdict(other, { trustFile: TRUSTED }), "cwd_untrusted");
});

test("実体が信頼済みなら symlink で渡しても ok(cwd 側の正規化)", () => {
  const link = join(root, "link-to-trusted");
  symlinkSync(projectDir, link);
  assert.equal(cwdVerdict(link, { trustFile: TRUSTED }), "ok");
});

test("★鍵の側が symlink で書かれていても実体が同じなら ok(Tom の実機 59 件中 2 件がこの形)", () => {
  // 片側(cwd)だけ正規化していた時、この形が偽って断られていた。両側を解決して直した(§2.25)。
  const keyLink = join(root, "key-written-via-link");
  symlinkSync(projectDir, keyLink);
  const f = listFor({ [keyLink]: { hasTrustDialogAccepted: true } });
  assert.equal(cwdVerdict(projectDir, { trustFile: f }), "ok");
});

test("実在しない鍵が混ざっていても、後続の項まで見る(実機の一覧は 78 件中 19 件が実在しない)", () => {
  const keyLink = join(root, "key-link-2");
  symlinkSync(projectDir, keyLink);
  const f = listFor({
    [join(root, "消えた1")]: { hasTrustDialogAccepted: true },
    [join(root, "消えた2")]: { hasTrustDialogAccepted: true },
    [keyLink]: { hasTrustDialogAccepted: true },
  });
  assert.equal(cwdVerdict(projectDir, { trustFile: f }), "ok", "実在しない鍵で探索を止めている");
});

test("★捨てた守りの記録: 一覧の名前の位置に symlink を植えると通る(守りではない)", () => {
  // これは**保証**ではなく、両側正規化と引き換えに捨てた守りの記録(DESIGN §2.25)。
  // 細工には file 書き込み権が要り、その権限が在れば `~/.claude.json` へ直接足せる ——
  // 既に前提から外している脅威より弱いので捨てた。締め直す判断をした時はこの検査ごと書き換える。
  const planted = join(root, "planted");
  const evil = join(root, "evil-real");
  mkdirSync(evil);
  symlinkSync(evil, planted);
  const f = listFor({ [planted]: { hasTrustDialogAccepted: true } });
  assert.equal(cwdVerdict(planted, { trustFile: f }), "ok");
});

test("★判定は一覧 file を1バイトも変えない(信頼を機械で与えない)", () => {
  const before = readFileSync(TRUSTED);
  const mtime = statSync(TRUSTED).mtimeMs;
  for (const d of [projectDir, join(root, "居ない"), ""]) cwdVerdict(d, { trustFile: TRUSTED });
  assert.deepEqual(readFileSync(TRUSTED), before, "一覧の中身が変わった");
  assert.equal(statSync(TRUSTED).mtimeMs, mtime, "一覧に書き込んだ");
});

test("★src/trust.mjs は書く手段を持たない(構造で禁じる。変異 W23 の的)", () => {
  const src = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "..", "src", "trust.mjs"), "utf8");
  for (const bad of ["writeFileSync", "appendFileSync", "openSync", "createWriteStream", "rmSync"]) {
    assert.ok(!src.includes(bad), `信頼一覧へ書ける手段が入った: ${bad}`);
  }
});

test("★断る理由は全部、電話に出す文を持つ(覆い漏れ = 既定の嘘)", () => {
  assert.ok(CWD_REFUSALS.length >= 3);
  for (const r of CWD_REFUSALS) {
    assert.equal(typeof WORKER_REFUSAL[r], "string", `${r} の文が無い`);
    assert.ok(WORKER_REFUSAL[r].length >= 10, `${r} の文が短すぎる`);
  }
  assert.ok(!("ok" in WORKER_REFUSAL), "通した時の文が在る = 断りと通過が混ざっている");
});
