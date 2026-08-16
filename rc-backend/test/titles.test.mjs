// titles.mjs の単体。spec-audit A1(明示名の機構が製品に無かった)を閉じる側の検体。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadTitles, setTitle, normalizeTitle, loadArchived, setArchived } from "../src/titles.mjs";

const dir = () => mkdtempSync(join(tmpdir(), "titles-"));

test("normalizeTitle: 整った名前は空白を圧縮して通る", () => {
  assert.equal(normalizeTitle("  移動中の  作業\n続き "), "移動中の 作業 続き");
});

test("normalizeTitle: 空・60字超・文字列でない、は全部 null", () => {
  assert.equal(normalizeTitle(""), null);
  assert.equal(normalizeTitle("   "), null);
  assert.equal(normalizeTitle("あ".repeat(61)), null);
  assert.equal(normalizeTitle(42), null);
  assert.equal(normalizeTitle(null), null);
  // ★境界の錨: 60 ちょうどは通る(上限が 59 に縮む実装を落とす)
  assert.equal(normalizeTitle("あ".repeat(60)), "あ".repeat(60));
});

test("set -> load の往復。null で外すと鍵ごと消える", () => {
  const d = dir();
  setTitle(d, "sid-1", "案件A");
  setTitle(d, "sid-2", "案件B");
  assert.deepEqual(loadTitles(d), { "sid-1": "案件A", "sid-2": "案件B" });
  setTitle(d, "sid-1", null);
  const after = loadTitles(d);
  assert.deepEqual(after, { "sid-2": "案件B" });
  // ★「空文字の名前」という第3状態を作らない(鍵の不在 = 名前なし、の1状態だけ)
  assert.ok(!("sid-1" in after));
});

test("台帳が無い/壊れている = 空で開く(名前は装飾。一覧を殺さない)", () => {
  const d = dir();
  assert.deepEqual(loadTitles(d), {});
  writeFileSync(join(d, "titles.json"), "{ こわれた", "utf8");
  assert.deepEqual(loadTitles(d), {});
  // 壊れた台帳の上からでも書ける(修復 = 上書き)
  setTitle(d, "sid-3", "復旧後");
  assert.deepEqual(loadTitles(d), { "sid-3": "復旧後" });
});

test("書きは tmp -> rename(書きかけの JSON が本名で存在した瞬間が無い)", () => {
  const d = dir();
  setTitle(d, "sid-4", "原子性");
  // rename 後の本名は必ず完全な JSON
  assert.doesNotThrow(() => JSON.parse(readFileSync(join(d, "titles.json"), "utf8")));
});

// ── 保管の台帳(§9-1)────────────────────────────────────────────────────────

test("archive: 外す -> 台帳に時刻が載る / 戻す -> 鍵ごと消える", () => {
  const d = dir();
  const t = new Date("2026-08-16T12:00:00Z");
  setArchived(d, "sid-a", true, t);
  assert.deepEqual(loadArchived(d), { "sid-a": "2026-08-16T12:00:00.000Z" });
  setArchived(d, "sid-a", false);
  assert.deepEqual(loadArchived(d), {});
});

test("archive: 台帳は titles と別ファイル(片方を壊しても片方は生きる)", () => {
  const d = dir();
  setTitle(d, "sid-b", "名前");
  setArchived(d, "sid-b", true);
  writeFileSync(join(d, "archived.json"), "{ こわれた", "utf8");
  assert.deepEqual(loadArchived(d), {}, "壊れた archive は空で開く");
  assert.deepEqual(loadTitles(d), { "sid-b": "名前" }, "titles は無傷");
});

test("archive: transcript を消す機構がこの module に存在しない(『file は残る』の形)", () => {
  const src = readFileSync(new URL("../src/titles.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(src, /unlink|rmSync|rmdir|rm -rf/,
    "★台帳の module に削除系の呼び出しが生えた = 『外すだけ』の約束が形でなくなる");
});
