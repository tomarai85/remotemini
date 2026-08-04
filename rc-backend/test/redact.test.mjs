// 伏せ字(src/redact.mjs)。**陰性対照が本体**の検査。
//
// ここで測るのは2方向で、片方だけだと意味が無い:
//   ① 秘密の**生の文字列が出力に残っていない**事(「変わった」ではなく「消えた」を見る)
//   ② 診断に要る物(session id / path / exit code / 普通の文)が**壊れていない**事
//      —— 全部伏せれば ① は満点になる。②が無い網は、通るが役に立たない。
//
// ★網は拒否一覧なので、ここに書いた形しか守られない(src/redact.mjs 冒頭の但し書き)。
//   形を1つ足す時は必ずこの file に1行足す。網を外す = 変異 W17。
import { test } from "node:test";
import assert from "node:assert/strict";
import { redact } from "../src/redact.mjs";

/** [名前, 生の入力, 出力に**残ってはいけない**部分文字列, 出力に**出る**印] */
const SHAPES = [
  ["メール(edith の account= 行が実際にこれ)", "account=mail-redacted@example.invalid", "client-a.team", "<mail>"],
  ["Discord の webhook(URL 自体が鍵)", "https://discord.com/api/webhooks/123456/AbCdEf-gh_IJ", "AbCdEf-gh_IJ", "<webhook>"],
  ["Anthropic の鍵", "key: sk-ant-api03-AAAAAAAAAAAAAAAA", "sk-ant-api03-AAAA", "<秘匿>"],
  ["GitHub の token", "ghp_AAAAAAAAAAAAAAAAAAAA", "ghp_AAAAAAAAAAAA", "<秘匿>"],
  ["Google OAuth の client secret", "GOCSPX-AAAAAAAAAAAAAAAA", "GOCSPX-AAAA", "<秘匿>"],
  ["Slack の bot token", "xoxb-1111-2222-AAAAAAAA", "xoxb-1111", "<秘匿>"],
  ["AWS の access key", "AKIAAAAAAAAAAAAAAAAA", "AKIAAAAAAAAA", "<秘匿>"],
  ["Google API key", "AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "AIzaAAAA", "<秘匿>"],
  ["Authorization ヘッダ", "Authorization: Bearer abcdefghijklmnop", "abcdefghijklmnop", "<秘匿>"],
  ["名前で当てる形(値の形は問わない)", "api_key=zzzz1", "zzzz1", "<秘匿>"],
  ["password:", "password: hunter22", "hunter22", "<秘匿>"],
];

for (const [name, raw, mustGo, mark] of SHAPES) {
  test(`伏せる: ${name}`, () => {
    const out = redact(raw);
    assert.ok(!out.includes(mustGo), `生のまま残った: ${out}`);
    assert.ok(out.includes(mark), `印が出ていない: ${out}`);
  });
}

// ★②の側。これが無いと「全部 <秘匿> に潰す」実装が満点を取ってしまう。
test("診断に要る物は壊さない", () => {
  const keep = [
    "worker exited code=1 signal=none",
    "11111111-2222-3333-4444-555555555555", // session id(UUID)
    "/Users/edith/.rc-backend/api.key", // path は出す(中身は読まない)
    "Error: ENOENT: no such file or directory, open 'claude-work'",
    "--resume が解決できませんでした",
  ];
  for (const s of keep) assert.equal(redact(s), s, `壊した: ${s}`);
});

test("文字列でない物でも投げない", () => {
  assert.equal(redact(null), "");
  assert.equal(redact(undefined), "");
  assert.equal(redact(42), "42");
});

test("1行に2つ在っても両方伏せる", () => {
  const out = redact("mail-redacted@example.invalid と ghp_AAAAAAAAAAAAAAAAAAAA");
  assert.ok(!out.includes("mail-redacted@example.invalid"));
  assert.ok(!out.includes("ghp_AAAA"));
  // ★②の側(2026-08-05 に足した)。此処だけ①しか無く、file 冒頭の但し書きと食い違っていた。
  //   欠けていたのは「複数一致の時だけ壊れる形」—— 網が最初の一致から最後の一致まで
  //   丸ごと飲むと、生の秘密は消えるので上の2行は緑のまま通る。飲まれるのは間の
  //   「と」と印の片方で、それを見ているのは此処しか無い(他の検査は1行1件しか渡さない)。
  assert.ok(out.includes("と"), `間の本文まで飲んだ: ${out}`);
  assert.equal(out.match(/<mail>/g)?.length, 1, `メールの印が1つ出ていない: ${out}`);
  assert.equal(out.match(/<秘匿>/g)?.length, 1, `token の印が1つ出ていない: ${out}`);
});
