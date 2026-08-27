// listing.mjs の unit test — **本物のファイル**で回す。
// tail.test.mjs と同じ理由で偽の fs を使わない: この module が引き受けている難しさは
// 「文字列の解釈」ではなく **ファイルの一部しか読まずに嘘をつかない事**で、
// 偽 fs を組むと自分の思い込み(チャンクは必ず満たされる、境界は跨がない)を検査するだけになる。
//
// 実データとの突き合わせは別建てで済んでいる(1,651本、entrypoint/title/lastPrompt 差 0、
// cwd 差 90 = 意図した 起動地→現在地。DESIGN §2.11)。ここは境界と嘘の検査。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, openSync, closeSync, fstatSync, readSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MetaCache, TAIL_CHUNK, nodeIo, parseTailMeta, readMetaFromPath, tailLines } from "../src/listing.mjs";

const L = (o) => `${JSON.stringify(o)}\n`;
const userRec = (text, cwd = "/Users/tomtim") =>
  L({ type: "user", entrypoint: "cli", cwd, message: { role: "user", content: text } });
const titleRec = (t) => L({ type: "ai-title", aiTitle: t });
const promptRec = (t) => L({ type: "last-prompt", lastPrompt: t });
const dir = () => mkdtempSync(join(tmpdir(), "rc-listing-"));

const withFile = (body, fn, opts = {}) => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, body);
  try {
    return fn(readMetaFromPath(p, opts), p);
  } finally {
    rmSync(d, { recursive: true });
  }
};

test("末尾側から4項目を採る", () => {
  withFile(userRec("さいしょ") + titleRec("折り紙の検査") + promptRec("次はどうする"), (m) => {
    assert.equal(m.entrypoint, "cli");
    assert.equal(m.cwd, "/Users/tomtim");
    assert.equal(m.title, "折り紙の検査");
    assert.equal(m.lastPrompt, "次はどうする");
    assert.equal(m.wholeFile, true);
    assert.equal(m.metadataIncomplete, false, "読み切ったので「無い」を断言してよい状態");
  });
});

test("★cwd は現在地が出る(途中で cd したら後の行が勝つ)", () => {
  // 旧実装は先頭の cwd を採っていた。実データ 1,644本中 90本がこれで
  // 起動地(/Users/tomtim)を表示していた — 電話の一覧としては現在地が正しい。
  withFile(userRec("はじめ", "/Users/tomtim") + userRec("cd した後", "/Users/tomtim/Infra/mobile-work"), (m) => {
    assert.equal(m.cwd, "/Users/tomtim/Infra/mobile-work");
    assert.equal(m.entrypoint, "cli");
  });
});

test("ai-title が無いファイルでは title は null(lastPrompt は採れる)", () => {
  withFile(userRec("ひとこと") + promptRec("ひとこと"), (m) => {
    assert.equal(m.title, null);
    assert.equal(m.lastPrompt, "ひとこと");
    assert.equal(m.metadataIncomplete, false, "全部読んだ上での null は「本当に無い」");
  });
});

test("turns は常に null(部分読みで数えられない物の数を発明しない)", () => {
  withFile(userRec("あ") + userRec("い") + userRec("う"), (m) => {
    assert.equal(m.turns, null);
  });
});

test("空ファイルでも落ちず、全部 null", () => {
  withFile("", (m) => {
    assert.equal(m.entrypoint, null);
    assert.equal(m.lastPrompt, null);
    assert.equal(m.metadataIncomplete, false, "0 バイトは読み切っている");
  });
});

test("壊れた行は飛ばし、他の行からは採る", () => {
  withFile(userRec("まえ") + "{これは JSON ではない\n" + promptRec("あと"), (m) => {
    assert.equal(m.entrypoint, "cli");
    assert.equal(m.lastPrompt, "あと");
  });
});

// --- チャンク境界 -----------------------------------------------------------

test("★チャンク境界を跨いだレコードが失われない(持ち越しの検査)", () => {
  // 長い ai-title 行を、わざと小さいチャンクの境界に跨がせる。
  const long = titleRec(`長い題名 ${"あ".repeat(120)}`);
  const body = userRec("さいしょ") + long + promptRec("おわり");
  withFile(
    body,
    (m) => {
      assert.equal(m.title, `長い題名 ${"あ".repeat(120)}`);
      assert.equal(m.lastPrompt, "おわり");
    },
    { tailChunk: 96, tailMax: 1024 * 1024 },
  );
});

test("★陰性対照: 持ち越し無しでは、跨いだレコードはどのチャンクからも見えない", () => {
  // 上の検査が「たまたま通った」ではない事を、同じ材料で示す。
  // チャンク単体の lines を見ると ai-title は**片方にも入っていない**。
  const long = titleRec(`長い題名 ${"あ".repeat(120)}`);
  const body = Buffer.from(userRec("さいしょ") + long + promptRec("おわり"));
  const C = 96;
  let seen = false;
  for (let scanned = 0; scanned < body.length; scanned += C) {
    const step = Math.min(C, body.length - scanned);
    const pos = body.length - scanned - step;
    const { lines } = tailLines(body.subarray(pos, pos + step), pos === 0);
    if (parseTailMeta(lines).title !== null) seen = true;
  }
  assert.equal(seen, false, "持ち越さずに切ると ai-title は消える = 持ち越しが効いている証拠");
});

test("多バイト文字がチャンク境界に来ても割れない", () => {
  const jp = "折り紙の鶴を折る手順を説明します。".repeat(12);
  withFile(
    userRec("x") + promptRec(jp),
    (m) => {
      assert.equal(m.lastPrompt, jp);
    },
    { tailChunk: 64 },
  );
});

test("1行がチャンクより長くても読み切れる", () => {
  const huge = "ん".repeat(5000);
  withFile(
    userRec("x") + promptRec(huge),
    (m) => {
      assert.equal(m.lastPrompt, huge);
    },
    { tailChunk: 128 },
  );
});

// --- 予算と正直さ -----------------------------------------------------------

test("★予算切れは metadataIncomplete = true(「無い」と断言しない)", () => {
  // last-prompt を先頭に置き、その後ろを予算より厚く埋める。
  const filler = L({ type: "assistant", message: { content: "x".repeat(400) } }).repeat(20);
  withFile(
    promptRec("ずっと前の発言") + filler,
    (m) => {
      assert.equal(m.lastPrompt, null);
      assert.equal(m.metadataIncomplete, true, "予算の外にあるだけかもしれない = 断言しない");
      assert.equal(m.wholeFile, false);
    },
    { tailChunk: 256, tailMax: 512 },
  );
});

test("予算内で読み切れば metadataIncomplete = false", () => {
  const filler = L({ type: "assistant", message: { content: "x".repeat(100) } }).repeat(3);
  withFile(
    promptRec("前の発言") + userRec("後") + filler,
    (m) => {
      assert.equal(m.lastPrompt, "前の発言");
      assert.equal(m.metadataIncomplete, false);
      assert.equal(m.wholeFile, true);
    },
    { tailChunk: 128, tailMax: 1024 * 1024 },
  );
});

test("★ai-title は遡る理由にならない(止まった位置より手前に在れば拾えない = それでよい)", () => {
  // 実測: 1,644本中 1,252本(76%)に ai-title が無い。「揃うまで遡る」条件に入れると
  // その 76% が毎回 TAIL_MAX を読み切る。だから止める条件は entrypoint と lastPrompt だけ。
  const filler = L({ type: "assistant", message: { content: "x".repeat(200) } }).repeat(6);
  withFile(
    titleRec("ずっと手前の題名") + filler + userRec("あと") + promptRec("あと"),
    (m) => {
      assert.equal(m.lastPrompt, "あと", "止める条件の2つは最初のチャンクで揃う");
      assert.equal(m.entrypoint, "cli");
      assert.equal(m.title, null, "その手前まで遡る理由が無いので拾わない");
      assert.equal(m.wholeFile, false, "読み切っていない = 遡らずに止まった証拠");
      assert.equal(
        m.metadataIncomplete,
        false,
        "title の不在は incomplete にしない(resolveTitle が lastPrompt に落ちるだけで嘘は言わない)",
      );
    },
    { tailChunk: 256, tailMax: 1024 * 1024 },
  );
});

test("遡る理由がある時は、ついでに手前の ai-title も拾う", () => {
  // entrypoint が手前にしか無いファイル。遡る過程で ai-title が視界に入る。
  const filler = L({ type: "assistant", message: { content: "x".repeat(200) } }).repeat(6);
  withFile(
    userRec("さいしょ") + titleRec("ついでに拾う題名") + filler + promptRec("あと"),
    (m) => {
      assert.equal(m.entrypoint, "cli", "これを探して遡る");
      assert.equal(m.title, "ついでに拾う題名", "遡る途中で視界に入るので拾える");
    },
    { tailChunk: 256, tailMax: 1024 * 1024 },
  );
});

// --- 読みの下回り -----------------------------------------------------------

test("★1回の read が短く返っても結果が変わらない(読み直しの検査)", () => {
  const chatty = {
    fstat: (fd) => fstatSync(fd),
    read: (fd, buf, pos) => readSync(fd, buf, 0, Math.min(7, buf.length), pos), // 毎回 7 バイトしか返さない
  };
  const body = userRec("さいしょ") + titleRec("短い読みでも同じ") + promptRec("おわり");
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, body);
  const full = readMetaFromPath(p, { tailChunk: 96 });
  const short = readMetaFromPath(p, { tailChunk: 96, io: chatty });
  assert.deepEqual(short, full);
  assert.equal(short.title, "短い読みでも同じ");
  rmSync(d, { recursive: true });
});

test("fstat は開いた fd から採る(stat→open の隙間を作らない)", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, userRec("x"));
  const fd = openSync(p, "r");
  const st = fstatSync(fd);
  closeSync(fd);
  const m = readMetaFromPath(p);
  assert.equal(m.size, st.size);
  rmSync(d, { recursive: true });
});

test("nodeIo は要求した長さを渡す(len を捨てていない)", () => {
  const d = dir();
  const p = join(d, "s.jsonl");
  writeFileSync(p, "0123456789abcdef");
  const fd = openSync(p, "r");
  const b = Buffer.alloc(4);
  assert.equal(nodeIo.read(fd, b, 6), 4);
  assert.equal(b.toString(), "6789");
  assert.equal(nodeIo.fstat(fd).size, 16);
  closeSync(fd);
  rmSync(d, { recursive: true });
});

test("既定のチャンクは 64KB(実測 p99 0.9KB に対して十分な余裕)", () => {
  assert.equal(TAIL_CHUNK, 64 * 1024);
});

// --- キャッシュ -------------------------------------------------------------

test("鍵は dev/ino/size/mtime で変わる(同じパスの別ファイルを取り違えない)", () => {
  const base = { dev: 1, ino: 2, size: 3, mtimeMs: 4.4 };
  const k = MetaCache.keyOf(base);
  assert.equal(k, MetaCache.keyOf({ ...base, mtimeMs: 4.4 }));
  assert.notEqual(k, MetaCache.keyOf({ ...base, ino: 9 }), "ino が変われば別物");
  assert.notEqual(k, MetaCache.keyOf({ ...base, dev: 9 }), "dev が変われば別物");
  assert.notEqual(k, MetaCache.keyOf({ ...base, size: 9 }), "追記されれば別物");
  assert.notEqual(k, MetaCache.keyOf({ ...base, mtimeMs: 5 }), "同じ長さの書き直しも別物");
});

// st の作り方をここに1つだけ置く。検査ごとに手で組むと、鍵に効く欄を書き忘れた検査が
// 「たまたま緑」になる。
const stOf = (ino, { size = 10, mtimeMs = 1000, dev = 1 } = {}) => ({ dev, ino, size, mtimeMs });

test("上限を超えたら古い物から落ちる(占有は無限に増えない)", () => {
  const c = new MetaCache({ max: 2 });
  c.set(stOf(1), "a");
  c.set(stOf(2), "b");
  c.set(stOf(3), "c");
  assert.equal(c.size, 2, "上限を超えて溜め込まない");
  assert.ok(c.evictions >= 1, "追い出した事を自分で数えている");
});

test("同じパスが別 file に差し替わっても中身を取り違えない", () => {
  const c = new MetaCache({ max: 10 });
  c.set(stOf(1), "元の中身");
  assert.equal(c.get(stOf(2)), null, "ino が違えば別物(前の中身を返さない)");
  assert.equal(c.get({ ...stOf(1), dev: 9 }), null, "dev が違えば別物");
});

test("追記されたら中身は返さない(版が違う)", () => {
  const c = new MetaCache({ max: 10 });
  c.set(stOf(1, { size: 10 }), "古い");
  assert.equal(c.get(stOf(1, { size: 20 })), null, "size が伸びた = 読み直す");
  assert.equal(c.get(stOf(1, { mtimeMs: 2000 })), null, "書き直された = 読み直す");
});

// ★ここから下は 2026-08-27 の欠陥を捕まえる為の対照。
//   本番(friday)で `files=10303 read=10303 cached=0` が毎回出ていたのに、既存の検査は
//   全部緑だった —— 鍵の性質と LRU の追い出しは測っていたが、**キャッシュが効くか**を
//   一度も測っていなかったから。名前が主張する対象(キャッシュ)と assert している集合
//   (LRU の機械)がずれていた典型。

test("★周回走査の2周目は1本も読まない(これが効かないと一覧は毎回全件読みに戻る)", () => {
  const N = 500;
  const c = new MetaCache({ max: 8 }); // 走査対象より遥かに小さい上限から始める
  const files = Array.from({ length: N }, (_, i) => stOf(i + 1));
  const scan = () => {
    c.beginScan();
    c.ensureCapacity(files.length); // ★読む前に上げる
    let read = 0, hit = 0;
    for (const st of files) {
      if (c.get(st) === null) { c.set(st, `meta-${st.ino}`); read += 1; } else hit += 1;
    }
    c.sweep({ complete: true });
    return { read, hit };
  };
  const first = scan();
  assert.equal(first.read, N, "1周目は当然全部読む");
  const second = scan();
  assert.equal(second.read, 0, "2周目は1本も読まない");
  assert.equal(second.hit, N, "全部キャッシュから出る");
});

test("★追記され続けても entry は file 数を超えない(版が積み上がらない)", () => {
  // Codex 2026-08-27 が指摘した罠。旧形は鍵に size/mtime が入っていたので、
  // 1本の file が書き換わる度に **entry が1つ増え**、余白を版が食い潰して
  // 上限を上げただけの修正が無効化された。
  const c = new MetaCache({ max: 1000 });
  const ino = 7;
  for (let gen = 1; gen <= 200; gen += 1) {
    const st = stOf(ino, { size: gen * 10, mtimeMs: 1000 + gen });
    if (c.get(st) === null) c.set(st, `gen-${gen}`);
  }
  assert.equal(c.size, 1, "200回書き換わっても entry は1つ");
  assert.equal(c.get(stOf(ino, { size: 2000, mtimeMs: 1200 })), "gen-200", "最新の版が返る");
});

test("★上限は下がらない(部分走査や同時要求で上下すると、その度に雪崩が起きる)", () => {
  const c = new MetaCache({ max: 100 });
  const wide = c.ensureCapacity(5000);
  assert.ok(wide >= 5000, "走査対象を必ず上回る");
  assert.equal(c.ensureCapacity(3), wide, "小さい走査を見ても下げない");
  assert.equal(c.ensureCapacity(0), wide, "空の走査でも下げない");
});

test("★天井に当たっても行は消えない(遅くなるだけ)と、当たった事を名乗る", () => {
  const c = new MetaCache({ max: 10, ceiling: 1000 });
  // 余白の式 = ceil(files * 1.25) + 64。走査中に増える file の分だけ。
  assert.equal(c.ensureCapacity(50), Math.ceil(50 * 1.25) + 64, "天井の下では観測値どおり伸びる");
  assert.ok(c.ensureCapacity(50) > 50, "必ず走査対象を上回る(これが 0% ヒットの原因だった)");
  assert.equal(c.capped, false);
  assert.equal(c.ensureCapacity(10000), 1000, "天井を超えて伸ばさない");
  assert.equal(c.capped, true, "当たった事を自分から名乗る(静かに劣化しない)");
  // 天井に当たった状態でも読み書きは正しく働く = 一覧の内容には関与しない
  c.beginScan();
  c.set(stOf(1), "meta");
  assert.equal(c.get(stOf(1)), "meta", "遅くなるだけで、値が壊れたり消えたりはしない");
});

test("★途中で読むのを止めた走査では掃除しない(見ていないだけの file を捨てない)", () => {
  const c = new MetaCache({ max: 100 });
  c.beginScan();
  c.set(stOf(1), "a");
  c.set(stOf(2), "b");
  c.sweep({ complete: true });
  assert.equal(c.size, 2, "今回見た物は残る");

  c.beginScan();
  c.get(stOf(1)); // 1 だけ見て打ち切った、という形
  assert.equal(c.sweep({ complete: false }), 0, "打ち切った走査は1件も落とさない");
  assert.equal(c.size, 2, "見ていない 2 が生き残る");

  c.beginScan();
  c.get(stOf(1));
  assert.equal(c.sweep({ complete: true }), 1, "最後まで回れた時だけ、見なかった物を落とす");
  assert.equal(c.get(stOf(2)), null, "消えた file を永久に抱えない");
});
