// sessions.mjs の permissionModeOf — 転写から「今」の permission mode を拾えるか。
// **本物のファイル**で回す(listing.test.mjs と同じ理由: この module が引き受ける
// 難しさは「文字列の解釈」ではなく「ファイルの一部しか読まずに嘘をつかない事」)。
//
// ── 何を守るか(対照表 #16、`status` の分岐)────────────────────────────────
// 転写には permissionMode を持つ行が2種ある: 専用イベント `type:"permission-mode"`
// (トグルの瞬間に追記。timestamp を持たない)と、`type:"user"` に埋め込まれた
// スナップショット(送信時点。timestamp を持つが、送信を挟まないトグルには付かない)。
// ★守る一線: **timestamp では揃えない、ファイルの並びのまま最後尾から見る**。
//   timestamp で揃えると、timestamp を持たない `permission-mode` 行が時刻 0 に落ちて
//   必ず負け、送信の無いトグルが「無かった事」になる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { permissionModeOf } from "../src/sessions.mjs";

const L = (o) => `${JSON.stringify(o)}\n`;
const userRec = (mode, isoOffset = 0) =>
  L({
    type: "user",
    timestamp: new Date(Date.parse("2026-09-02T10:00:00.000Z") + isoOffset).toISOString(),
    permissionMode: mode,
    message: { role: "user", content: "hi" },
  });
const modeEvent = (mode) => L({ type: "permission-mode", permissionMode: mode, sessionId: "s1" });
const dir = () => mkdtempSync(join(tmpdir(), "rc-permmode-"));

const withFile = (body, fn, opts = {}) => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, body);
  try {
    return fn(permissionModeOf(p, opts), p);
  } finally {
    rmSync(d, { recursive: true });
  }
};

test("末尾の user 行から採る(素直な場合)", () => {
  withFile(userRec("default") + userRec("bypassPermissions", 1000), (mode) => {
    assert.equal(mode, "bypassPermissions");
  });
});

test("★送信を挟まないトグルが勝つ: timestamp の無い permission-mode 行が" +
  " timestamp 付きの user 行より**後ろ**に在れば、そちらを採る", () => {
  // user 行(bypassPermissions, timestamp 付き)の後で plan へトグルしたが、
  // まだ何も送っていない = 専用イベント行だけが追記されている状態。
  withFile(userRec("bypassPermissions") + modeEvent("plan"), (mode) => {
    assert.equal(mode, "plan", "ファイルの並びで後ろに在る方(トグル後)を採るべき");
  });
});

test("★逆順でも崩れない: user 行の方が後ろなら user 行が勝つ", () => {
  withFile(modeEvent("plan") + userRec("acceptEdits", 1000), (mode) => {
    assert.equal(mode, "acceptEdits");
  });
});

test("timestamp の無い行だけが在っても採れる(全て permission-mode イベント)", () => {
  withFile(modeEvent("default") + modeEvent("plan") + modeEvent("bypassPermissions"), (mode) => {
    assert.equal(mode, "bypassPermissions", "ファイルの最後尾が勝つ");
  });
});

test("permissionMode を持つ行が1つも無ければ null", () => {
  withFile(L({ type: "assistant", timestamp: "2026-09-02T10:00:00.000Z", message: { role: "assistant" } }), (mode) => {
    assert.equal(mode, null);
  });
});

test("空ファイルでも落ちず null", () => {
  withFile("", (mode) => {
    assert.equal(mode, null);
  });
});

test("壊れた行(書き込み途中)は飛ばし、その手前の完全な行から採る", () => {
  withFile(userRec("plan") + '{"type":"permission-mode","permissionMode":"bypass', (mode) => {
    assert.equal(mode, "plan");
  });
});

test("値が空文字なら無視する(発明しない — 空文字は「無い」の代わりにならない)", () => {
  withFile(userRec("default") + L({ type: "permission-mode", permissionMode: "" }), (mode) => {
    assert.equal(mode, "default", "空文字の permissionMode は採らず、その手前の値まで戻る");
  });
});

test("ファイルが存在しない = 呼び手の責任(ENOENT を投げる。null に丸めない)", () => {
  const d = dir();
  try {
    assert.throws(() => permissionModeOf(join(d, "no-such-file.jsonl")));
  } finally {
    rmSync(d, { recursive: true });
  }
});
