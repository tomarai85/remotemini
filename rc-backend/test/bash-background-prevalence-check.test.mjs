// 背景シェルの頻度を数える道具の検査(2026-09-07)。数え方は JSON として読む(文字列の部分一致ではない)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { tallyTranscript, tally, listParentTranscripts, formatLine } from "../tools/bash-background-prevalence-check.mjs";

const TOOL = join(dirname(fileURLToPath(import.meta.url)), "..", "tools", "bash-background-prevalence-check.mjs");
const asst = (blocks) => JSON.stringify({ type: "assistant", message: { role: "assistant", content: blocks } });
const bash = (cmd, bg) => ({ type: "tool_use", name: "Bash", input: bg === undefined ? { command: cmd } : { command: cmd, run_in_background: bg } });

test("tallyTranscript: Bash の tool_use を数え、run_in_background が true の物だけを bg に数える(空白・綴り・文字列の偽陽性を通さない)", () => {
  const text = [
    asst([bash("ls"), bash("sleep 300", true), bash("echo x", false)]),
    JSON.stringify({ type: "user", message: { role: "user", content: '"run_in_background":true "name":"Bash" written by a person' } }),
    asst([{ type: "tool_use", name: "Read", input: { file_path: "/x", run_in_background: true } }]),
    asst([{ type: "text", text: "no tools" }]),
    "not json",
    JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", name: "Bash", input: { command: "y", run_in_background: "true" } }] } }),
  ].join("\n");
  assert.deepEqual(tallyTranscript(text), { bash: 4, bg: 1 });
});

test("tally: 転写ごとの集計と bg を使ったセッション数、割合は小数 1 桁", () => {
  const a = asst([bash("a"), bash("b", true), bash("c", true)]);
  const b = asst([bash("d")]);
  const r = tally([a, b, ""]);
  assert.deepEqual(r, { files: 3, bash: 4, bg: 2, bg_pct: 50, sessions_bg: 1 });
  assert.equal(tally([]).bash, 0);
  assert.equal(tally([b]).bg_pct, 0);
});

test("listParentTranscripts: subagents/ 配下は除き、古い物は除き、新しい順に max 本", () => {
  const root = mkdtempSync(join(tmpdir(), "rc-prev-"));
  const slug = join(root, "-Users-x-proj"); mkdirSync(join(slug, "s1", "subagents"), { recursive: true });
  writeFileSync(join(slug, "s1.jsonl"), asst([bash("a", true)]) + "\n");
  writeFileSync(join(slug, "s2.jsonl"), asst([bash("b")]) + "\n");
  writeFileSync(join(slug, "s1", "subagents", "agent-1.jsonl"), asst([bash("c", true)]) + "\n");
  writeFileSync(join(slug, "old.jsonl"), asst([bash("z", true)]) + "\n");
  const old = new Date(Date.now() - 40 * 86400 * 1000); utimesSync(join(slug, "old.jsonl"), old, old);
  const t1 = new Date(Date.now() - 1000); utimesSync(join(slug, "s1.jsonl"), t1, t1);
  const paths = listParentTranscripts(root, { days: 14, max: 10 });
  assert.deepEqual(paths.map((p) => p.split("/").pop()), ["s2.jsonl", "s1.jsonl"]);
  assert.deepEqual(listParentTranscripts(root, { days: 14, max: 1 }).map((p) => p.split("/").pop()), ["s2.jsonl"]);
  assert.deepEqual(listParentTranscripts(join(root, "nope"), {}), []);
});

test("formatLine: 表として読める 1 行。0 件は kind=ng(使われていない、と読ませない)", () => {
  assert.equal(formatLine({ files: 2, bash: 10, bg: 1, bg_pct: 10, sessions_bg: 1 }, { days: 14 }), "kind=ok days=14 files=2 bash=10 bg=1 bg_pct=10 sessions=2 sessions_bg=1");
  assert.equal(formatLine({ files: 0, bash: 0, bg: 0, bg_pct: 0, sessions_bg: 0 }, { days: 7 }), "kind=ng reason=no-transcripts days=7");
});

test("殻: --root で数え、rc 0 / 空なら rc 1 / 変な引数は usage(rc 2)", () => {
  const root = mkdtempSync(join(tmpdir(), "rc-prev2-"));
  const slug = join(root, "-Users-y"); mkdirSync(slug, { recursive: true });
  writeFileSync(join(slug, "a.jsonl"), asst([bash("a", true), bash("b")]) + "\n");
  const out = execFileSync(process.execPath, [TOOL, "--root", root, "--days", "14", "--max", "10"], { encoding: "utf8" }).trim();
  assert.equal(out, "kind=ok days=14 files=1 bash=2 bg=1 bg_pct=50 sessions=1 sessions_bg=1");
  let rc = 0; try { execFileSync(process.execPath, [TOOL, "--root", join(root, "empty")], { encoding: "utf8" }); } catch (e) { rc = e.status; }
  assert.equal(rc, 1);
  let rc2 = 0; try { execFileSync(process.execPath, [TOOL, "--bogus"], { encoding: "utf8" }); } catch (e) { rc2 = e.status; }
  assert.equal(rc2, 2);
});
