// 頭の登録簿(DESIGN.md §2.18-4〜6)。**本物のファイルで回す**(`history.test.mjs` と同じ作法)。
// rename の原子性・走査から temp が外れる事は、偽 fs では測った事にならない。
//
// 押さえるのは1点に尽きる:
//   ★**判らない時に必ず「頭が無い」へ倒れる**(= fork する)。
//   逆へ倒れると祖先へ resume = 机の TUI と同じ転写ファイルを2人で書く = H2 が防ぐ破壊。
//   だから「無い」「壊れている」「名前と中身が食い違う」「書きかけ」を全部別々に測る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readdirSync, renameSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseHead, readHead, writeHead, readAllHeads } from "../src/heads.mjs";

const A = "11111111-2222-3333-4444-555555555555"; // 祖先
const B = "66666666-7777-8888-9999-aaaaaaaaaaaa"; // 別の祖先
const H1 = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"; // 頭
const H2 = "12341234-5678-9abc-def0-123456789abc"; // 次の頭

const withDir = (fn) => {
  const d = mkdtempSync(join(tmpdir(), "rc-heads-"));
  try {
    return fn(d);
  } finally {
    rmSync(d, { recursive: true });
  }
};

test("登録が無ければ空 = fork 側へ倒れる", () => {
  withDir((d) => {
    assert.equal(readHead(d, A), "", "登録が無いのに頭を名乗った");
    assert.deepEqual(readAllHeads(d), []);
  });
});

test("ディレクトリごと無くても落ちない(空を返す)", () => {
  const gone = join(tmpdir(), "rc-heads-存在しない-0000");
  assert.equal(readHead(gone, A), "");
  assert.deepEqual(readAllHeads(gone), []);
});

test("書いた頭がそのまま読める / 2通目以降は上書きが効く", () => {
  withDir((d) => {
    writeHead(d, A, H1);
    assert.equal(readHead(d, A), H1);

    writeHead(d, A, H2);
    assert.equal(readHead(d, A), H2, "上書きが効いていない(枝が古いまま固まる)");
    assert.equal(readAllHeads(d).length, 1, "上書きでファイルが増えている");
  });
});

test("別の祖先は干渉しない(1会話1ファイルの意味)", () => {
  withDir((d) => {
    writeHead(d, A, H1);
    writeHead(d, B, H2);
    assert.equal(readHead(d, A), H1);
    assert.equal(readHead(d, B), H2);
    assert.equal(readAllHeads(d).length, 2);
  });
});

test("★壊れた中身は「頭が無い」= 共有せず分岐する(倒す向き)", () => {
  withDir((d) => {
    writeFileSync(join(d, `${A}.json`), "{ここで切れて");
    assert.equal(readHead(d, A), "", "壊れた登録から頭を読み出した(= 祖先へ resume する側へ倒れた)");
    assert.deepEqual(readAllHeads(d), [], "壊れた1件が一覧に混ざった");
  });
});

test("★ファイル名と中身の祖先が食い違う登録は捨てる(取り違えの温床)", () => {
  withDir((d) => {
    // B の中身を A の名前で置く = 名前を付け替えただけのファイル
    writeFileSync(join(d, `${A}.json`), JSON.stringify({ ancestor: B, head: H1 }));
    assert.equal(readHead(d, A), "", "別の会話の頭を自分の頭として読んだ");
    assert.deepEqual(readAllHeads(d), []);
  });
});

test("形の違う ID は受け付けない(書く側も読む側も)", () => {
  withDir((d) => {
    assert.throws(() => writeHead(d, "../../逃げ道", H1), /祖先/);
    assert.throws(() => writeHead(d, A, "頭ではない"), /頭/);
    assert.equal(readHead(d, "../../逃げ道"), "");
    writeFileSync(join(d, `${A}.json`), JSON.stringify({ ancestor: A, head: "" }));
    assert.equal(readHead(d, A), "", "空の頭を頭として返した");
  });
});

test("★書きかけ(temp)は走査にも読み出しにも出てこない", () => {
  withDir((d) => {
    writeHead(d, A, H1);
    // 書きかけを模す。**部分的な JSON** なので、もし読まれたら壊れた物として見える。
    writeFileSync(join(d, `${A}.99999.7.tmp`), '{"ancestor":"' + A + '","head":"' + H2);

    assert.equal(readHead(d, A), H1, "書きかけが本物の頭を押しのけた");
    assert.deepEqual(readAllHeads(d).map((e) => e.head), [H1], "書きかけが一覧に出た");
  });
});

test("★**中身が完全な**書きかけ(書き終えて rename 前)も頭として読まれない", () => {
  withDir((d) => {
    writeHead(d, A, H1);
    // 実際に起こり得る状態: 書き込みは終わったが rename がまだ / rename に失敗して消せなかった。
    // 中身は**壊れていない**ので、「壊れた JSON を捨てる」経路では止まらない。
    writeFileSync(join(d, `${A}.222.1.tmp`), JSON.stringify({ ancestor: A, head: H2 }));

    assert.equal(readHead(d, A), H1, "rename 前の書きかけが頭を名乗った");
    assert.deepEqual(readAllHeads(d).map((e) => e.head), [H1], "書きかけが一覧に出た");
  });
});

test("★書き終えた後に書きかけが残らない(rename で消えている)", () => {
  withDir((d) => {
    writeHead(d, A, H1);
    writeHead(d, A, H2);
    const left = readdirSync(d).filter((n) => n.endsWith(".tmp"));
    assert.deepEqual(left, [], `書きかけが残っている: ${left.join(", ")}`);
    assert.deepEqual(readdirSync(d), [`${A}.json`]);
  });
});

test("★書きかけの名は毎回違う(2本が同時に書いても互いの書きかけを rename しない)", () => {
  withDir((d) => {
    const tmps = [];
    const spy = {
      writeFileSync: (p, body) => {
        tmps.push(p);
        writeFileSync(p, body);
      },
      renameSync,
      unlinkSync,
    };
    writeHead(d, A, H1, spy, 111); // プロセス1
    writeHead(d, A, H2, spy, 222); // プロセス2(別 pid)
    writeHead(d, A, H1, spy, 111); // プロセス1の2回目(自分同士の重なり)

    assert.equal(new Set(tmps).size, 3, `書きかけの名が重なった: ${tmps.join(", ")}`);
    for (const p of tmps) {
      assert.ok(p.endsWith(".tmp"), `書きかけが .tmp で終わっていない(走査に出る): ${p}`);
    }
    assert.equal(readHead(d, A), H1);
    assert.deepEqual(readdirSync(d), [`${A}.json`]);
  });
});

test("parseHead は純関数として単体で正しい(名前を渡さないと通らない)", () => {
  const good = JSON.stringify({ ancestor: A, head: H1 });
  assert.deepEqual(parseHead(good, `${A}.json`), { ancestor: A, head: H1 });
  assert.equal(parseHead(good, `${B}.json`), null);
  assert.equal(parseHead("null", `${A}.json`), null);
  assert.equal(parseHead("", `${A}.json`), null);
});
