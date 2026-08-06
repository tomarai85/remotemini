// 実機を触る台本が、終了コードの意味で**合意しているか**を測る。
// 対象は2つの言語に散っている: `rc-backend/tools/live-*.mjs` 4本 + `ios/tools/live-*.sh` 2本。
//
// ── なぜ要るか(2026-08-02 の再発を 2026-08-06 に数えて見つけた)──────────────
// 8/02、同じ機械を同じ時刻に測った2本が逆の事を言った。inject 側は exit 3
// (相手が上限で答えていない)、http 側は「16 OK / 0 NG / exit 0」。後者の緑は嘘では
// ないが「一巡した」と読まれる。そこで 3 を足した —— **足したのは1本だけだった**。
//
// 8/06 に4本を数えた実測:
//   tools/live-inject-check.mjs   上限を知る / exit 3 あり
//   tools/live-fork-check.mjs     上限を知る(自前の写し)/ exit 3 あり
//   tools/live-http-check.mjs     上限を知る / exit 3 あり
//   tools/live-choice-check.mjs   ★知らない。failed ? 1 : 0 で、上限の画面はただの赤
// しかも choice 側の注釈は「上限や信頼確認の可能性」と**2つの状態を束ねて**いた ——
// inject 側が 8/02 に解いた束ねと同じ形。教訓を1本に適用して他へ運ばない型そのもの。
//
// 直した上で、**次に台本が増えた日に同じ事が起きない様に**この検査を置く。
// 一覧(下の INSTRUMENTS)は手で書くが、**手で同期する2本目の一覧にはしない** ——
// disk 上の live-* を数えて一覧と突き合わせるので、7本目を足した人は
// 此処で必ず止まる(止まった人がする事は1行足す事、ではなく 3 を持たせる事)。
//
// ★同日の続き: 上の census を書いた時、私は `rc-backend/tools/live-*.mjs` しか数えず
//   shell の2本を落としていた —— 直後に数え直したら**どちらも上限を知らなかった**。
//   「教訓を N 箇所のうち一部にしか運ばない」型が、其れを直す為の道具自身に出た。
//   だから住処は `HOMES` に2つとも持つ。3つ目の言語が増える日は、また此処で止まる。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { exitCodeFor, EXIT_MEANING } from "../tools/exit-codes.mjs";
import { limitNoticeIn } from "../src/inject.mjs";
import { requireOutside } from "./subtree.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const TOOLS = join(ROOT, "tools");
const read = (rel) => readFileSync(join(ROOT, rel), "utf8");

// ★shell の2本は**木の外**(`ios/`)に居る。rc-backend だけを写した木では在って当然
// 無いので、素の `readdirSync` は throw = **赤**になる —— 変異走行はその写しの中で
// 回るので、対照1が落ちて以降の変異が全部「検出」に化ける(2026-08-05 に実際に起きた形)。
// 「写しなので測っていない」と「消えた/改名された」を分ける口が `requireOutside`。
const OUTSIDE = requireOutside([
  "ios",
  "ios/tools/live-send-check.sh",
  "ios/tools/live-interrupt-check.sh",
]);

// ★実機を触る台本は**2つの言語に散っている**。8/06 に4本を揃えた時、此の一覧は
//   `rc-backend/tools/live-*.mjs` しか数えていなかった —— shell の2本
//   (`ios/tools/live-*.sh`)は census の外に居て、どちらも上限を知らないままだった。
//   「教訓を N 箇所のうち一部にしか運ばない」型が、其れを直す為の道具自身に出た形。
//   だから住処は2つとも書き、disk との突き合わせも2つとも回す。
const HOMES = [
  { dir: join(ROOT, "tools"), rel: (n) => `tools/${n}`, ext: ".mjs" },
  { dir: join(ROOT, "..", "ios", "tools"), rel: (n) => `../ios/tools/${n}`, ext: ".sh" },
];

// 木の中(この写しでも必ず在る)と、木の外(写しでは無い)を**分けて持つ**。
// 混ぜた1本の一覧にすると、写しの中で「無い」を赤と読むか未測定と読むかが書けない。
const MJS_INSTRUMENTS = [
  "tools/live-inject-check.mjs",
  "tools/live-fork-check.mjs",
  "tools/live-http-check.mjs",
  "tools/live-choice-check.mjs",
];
const SH_INSTRUMENTS = [
  "../ios/tools/live-send-check.sh",
  "../ios/tools/live-interrupt-check.sh",
];
// ★写しでも**一覧からは落とさない**。落とすと TAP から名前ごと消えて「測っていない」が
//   誰にも見えなくなる(= 黙って範囲が縮む)。skip として名前を残し、理由を言わせる。
const INSTRUMENTS = [...MJS_INSTRUMENTS, ...SH_INSTRUMENTS];
const gateFor = (rel) => (rel.endsWith(".sh") ? OUTSIDE.skip : false);

// 3 を返す道として認める形。新しい書き方を足すなら此処に足す = 増やした事が diff に残る。
const RETURNS_THREE = [
  /exitCodeFor\(/, // 正本(tools/exit-codes.mjs)に委ねている
  /exitCode\s*=\s*3/, // process.exitCode へ直に置く
  /\bexit\(3\)/, // 直に撃つ
  /\?\s*3\s*:/, // fail(lim ? 3 : 2, ...) の形
  /\bexit\s+3\b/, // shell
  /\breturn\s+3\b/, // shell の関数(判定を切り出すと `exit` は呼び側へ移る)
];
// ★`return 3` を足したのは 2026-08-06、`ios/tools/live-send-check.sh` の判定を `send_verdict()` へ
//   切り出した時に此処が赤くなったから(commit の門が捕まえた = 切り出した後に一式を
//   回し直していなかった)。**緩めた訳ではない**: shell 側の本当の証拠は
//   `ios/tools/live-send-check-control.sh` の真理値表 —— 終了コードが実際に 3 で出る事を
//   21 通りで撃っている。此処の静的検査が守るのは「3 へ行く道が1本も無い」台本だけ。

// ── A. 順序そのもの ────────────────────────────────────────────────────────
// 8 通り全部。実機でしか走らない台本の**結論**なので、手元で撃てるのは此処だけ。
test("終了コードは 8 通りとも決まっている(2 > 1 > 3 > 0)", () => {
  const t = true, f = false;
  const cases = [
    [{ prepAbort: f, failed: f, limitedReply: f }, 0],
    [{ prepAbort: f, failed: f, limitedReply: t }, 3],
    [{ prepAbort: f, failed: t, limitedReply: f }, 1],
    [{ prepAbort: f, failed: t, limitedReply: t }, 1],
    [{ prepAbort: t, failed: f, limitedReply: f }, 2],
    [{ prepAbort: t, failed: f, limitedReply: t }, 2],
    [{ prepAbort: t, failed: t, limitedReply: f }, 2],
    [{ prepAbort: t, failed: t, limitedReply: t }, 2],
  ];
  for (const [flags, want] of cases) {
    assert.equal(exitCodeFor(flags), want, `flags=${JSON.stringify(flags)}`);
  }
});

test("何も測れていない(2)は、測った結果の顔をしない", () => {
  assert.equal(
    exitCodeFor({ prepAbort: true, failed: true }),
    2,
    "準備段で中断した回に 1 を出すと、読み手は在りもしない欠陥を探しに行く",
  );
});

test("赤(1)は上限(3)に隠されない", () => {
  assert.equal(
    exitCodeFor({ failed: true, limitedReply: true }),
    1,
    "上限は「送れない」ではないので、運ぶ層の赤は上限では説明が付かない = 本物の欠陥",
  );
});

test("何も渡さなければ 0(既定値が事故らない)", () => {
  assert.equal(exitCodeFor(), 0);
  assert.equal(exitCodeFor({}), 0);
});

test("4つの意味が言葉でも残っている", () => {
  // 長さの下限は書かない(0 の「全部通った」で理由なく赤くなる = 発明した数字)。
  // 本当の壊れ方は写し間違いで2つが同じ文言になる事なので、**相異なる**事を見る。
  for (const c of [0, 1, 2, 3]) {
    assert.equal(typeof EXIT_MEANING[c], "string", `意味が無い: ${c}`);
    assert.ok(EXIT_MEANING[c].trim().length > 0, `意味が空: ${c}`);
  }
  assert.equal(new Set(Object.values(EXIT_MEANING)).size, 4, "4つの意味のどれかが重複している");
  assert.ok(EXIT_MEANING[2].includes("測"), "2 は「何も測れていない」である事を言う");
  assert.ok(EXIT_MEANING[3].includes("上限"), "3 は上限である事を言う");
});

// ── B. 4本が合意しているか ────────────────────────────────────────────────
test("★disk 上の live-* と一覧が一致している(7本目が黙って増えない)", { skip: OUTSIDE.skip }, () => {
  // ★対照(`*-control.sh` / `*-controls.sh`)は計器ではないので数えない。
  //   `ios/tools/live-send-check-control.sh` を書いた日に此処が赤くなった(2026-08-06)——
  //   名前が `live-` で始まるので「7本目の計器が黙って増えた」に見えた。
  //   対照の登録漏れを見るのは `rc-backend/tools/run-controls.sh` の方の照合。
  //   此処で除くのは**対照だけ**。名前が `live-` の計器を足せば従来通り赤くなる。
  const onDisk = HOMES.flatMap(({ dir, rel, ext }) =>
    readdirSync(dir)
      .filter((n) => n.startsWith("live-") && n.endsWith(ext))
      .filter((n) => !/-controls?\.(sh|mjs)$/.test(n))
      .map(rel),
  ).sort();
  assert.deepEqual(
    onDisk,
    [...INSTRUMENTS].sort(),
    "台本が増減している。増やしたなら、この一覧に足す前に**上限で 3 を返す**様にする事。\n" +
      "  8/02 の再発はここで止まる筈だった —— 3 を足したのが1本だけだったのが 8/06 の発見。",
  );
});

for (const rel of INSTRUMENTS) {
  test(`${rel} は上限を知っている`, { skip: gateFor(rel) }, () => {
    const src = read(rel);
    // ★**呼んでいる**事を見る。import や注釈に名前が在るだけでは認めない ——
    //   陰性対照で実測(2026-08-06): 判定の枝を `if (false)` に潰しても import 行は残るので、
    //   素の文字列検査だと緑のままだった。名前の実在を意味と取り違える型そのもの。
    //   fork 側は注釈に limitNoticeIn と書いてあるが実体は自前の写し(中身は下の D が測る)。
    const calls = new RegExp("limitNoticeIn\\s*\\([^)]").test(src);
    const ownDetector = /const\s+(looks\w*)\s*=\s*\(s\)\s*=>\s*\/[^\n]*limit/i.exec(src);
    const callsOwn = ownDetector
      ? new RegExp(ownDetector[1] + "\\s*\\([^)]").test(src.replace(ownDetector[0], ""))
      : false;
    // shell の2本は自前で画面を読まない。訊く口が `disposable-session.mjs limited`
    // (= 同じ `classifyScreen.limited` を出す)なので、**呼んでいる事**を同じ強さで見る。
    const asks = /disposable-session\.mjs\s+limited\b/.test(src);
    assert.ok(
      calls || callsOwn || asks,
      "上限の判定を持たない台本は、上限の機械を「壊れている」と報告する(= 待てば直る物を直す物として出す)",
    );
  });

  test(`${rel} は 3 を返す道を持っている`, { skip: gateFor(rel) }, () => {
    const src = read(rel);
    assert.ok(
      RETURNS_THREE.some((re) => re.test(src)),
      "上限を判定していても、それが終了コードに出なければ呼んだ側は区別できない",
    );
  });

  test(`${rel} の頭書きが 3 の意味を書いている`, { skip: gateFor(rel) }, () => {
    // 読み手が最初に見るのは頭のコメント。ここに無い意味は無いのと同じ。
    const head = read(rel).split("\n").slice(0, 40).join("\n");
    assert.match(head, /3\s*=/, "終了コード 3 の説明が頭書きに無い");
    const line = head.split("\n").find((l) => /3\s*=/.test(l)) || "";
    assert.match(line, /上限/, `3 の説明が上限に触れていない: ${line.trim()}`);
  });
}

// ── B-2. shell が訊く先が、実際に答えられる事 ──────────────────────────────
// shell の2本は自前で画面を読まず `disposable-session.mjs limited` に訊く。訊く側だけ
// 在って答える側が消えると、`LIM` は空になり **黙って上限を知らない台本に戻る**
// (`ios/tools/live-send-check.sh` は3本の足が hard check に戻り、上限の機械をまた赤で報告する)。
// 答える側は木の中に在るので、**写しの中でも measurable**。だから gate を掛けない。
test("★答える側: disposable-session.mjs が `limited` を実装している", () => {
  const src = read("tools/disposable-session.mjs");
  assert.match(src, /cmd === "limited"/, "分岐が無い = shell の問いに誰も答えない");
  assert.match(src, /function cmdLimited\s*\(/, "実体が無い");
  assert.match(
    src,
    /limited\s*\?\s*"limited"\s*:\s*"not-limited"/,
    'shell 側は "limited" の一語一致で読む。出す語を変えるなら台本2本も同時に直す事',
  );
  assert.match(src, /\|limited <id>\|/, "使い方の1行に出ていない = 人が見つけられない");
});

// 訊く側は木の外。片方だけ直る日を作らない為に綴りを固定するが、写しでは測れない。
test("★訊く側: shell の2本が同じ綴りで訊いている", { skip: OUTSIDE.skip }, () => {
  for (const rel of SH_INSTRUMENTS) {
    assert.match(read(rel), /disposable-session\.mjs limited '/, `訊き方が変わっている: ${rel}`);
  }
});

// ── C. 逃げ道の錨 ──────────────────────────────────────────────────────────
// 上の B は「文字列が在るか」しか見ていないので、正本へ委ねた2本については
// **委ね方**まで固定する(引数名を取り違えると意味が入れ替わるが、文字列検査は通る)。
test("正本へ委ねた2本は、旗の名前を取り違えていない", () => {
  const wired = {
    "tools/live-http-check.mjs": "exitCodeFor({ prepAbort, failed, limitedReply })",
    "tools/live-choice-check.mjs": "exitCodeFor({ failed, limitedReply: limited })",
  };
  for (const [rel, call] of Object.entries(wired)) {
    assert.ok(
      read(rel).includes(call),
      `呼び方が変わっている(名前を入れ替えると赤と上限が反転する): ${rel}\n  期待: ${call}`,
    );
  }
});

// ── D. 上限の見分け方が2つ在る事を、黙って持たない ────────────────────────
// tools/live-fork-check.mjs だけは自前の写しを持っている(looksLimited)。理由は文脈差:
//   正本(src/inject.mjs の USAGE_LIMIT)は**画面**に当てる。画面には Tom 自身が打った
//   本文も映るので、素の「usage limit」で当てると人が上限の話をしただけで 3 になる。
//   だから正本は文の形(You've hit your … limit / usage limit reached)を要求して**狭い**。
//   fork 側は自分で固定した prompt に対する `claude -p` の JSON にしか当てないので、
//   誤爆の余地が無く**広く**取れる。
// 危ないのは、この非対称が**逆転**する事 —— 正本が拾う文面を写しが落とす様になると、
// 同じ機械について2本がまた逆の事を言う(8/02 の再発)。だから包含関係だけを固定する。
// ★ここで測っていない事: どちらの綴りが Anthropic の実際の文面と合っているか。
//   観測したのは 8/02 の1件だけなので、**真偽ではなく関係**を測るに留める。
test("★写しの判定は正本を包含している(正本が拾う物を写しが落とさない)", () => {
  const src = read("tools/live-fork-check.mjs");
  const m = src.match(/const looksLimited\s*=\s*\(s\)\s*=>\s*(\/.+?\/[a-z]*)\.test\(/);
  assert.ok(m, "写しの判定が見つからない = この検査は測定不能(綴りが変わったなら此処も直す)");
  const body = m[1].replace(/^\//, "").replace(/\/([a-z]*)$/, "");
  const flags = (m[1].match(/\/([a-z]*)$/) || [, ""])[1];
  const copy = new RegExp(body, flags);

  const samples = [
    "You've hit your weekly limit · resets 12am",
    "You’ve hit your weekly limit",
    "You've hit your usage limit for this 5-hour window",
    "usage limit reached",
    "  会話の途中に You've hit your weekly limit と出た  ",
  ];
  const canonical = samples.filter((s) => limitNoticeIn(s));
  assert.ok(canonical.length >= 4, `正本が当たる見本が少なすぎて包含を測れない: ${canonical.length}`);
  for (const s of canonical) {
    assert.ok(
      copy.test(s),
      "正本が上限と読む文面を、写しが読み落とす。同じ機械について2本が逆の事を言う条件が揃っている。\n" +
        `  文面: ${s}`,
    );
  }
});

test("★陰性対照: 上限でない文面はどちらも拾わない", () => {
  // 包含だけを見ると「常に true を返す写し」でも緑になる。写しが選り分けている事を先に見る。
  const src = read("tools/live-fork-check.mjs");
  const m = src.match(/const looksLimited\s*=\s*\(s\)\s*=>\s*(\/.+?\/[a-z]*)\.test\(/);
  assert.ok(m, "写しの判定が見つからない = 測定不能");
  const copy = new RegExp(m[1].replace(/^\//, "").replace(/\/([a-z]*)$/, ""), (m[1].match(/\/([a-z]*)$/) || [, ""])[1]);
  for (const s of ["Not logged in · Please run /login", "1 から 40 までの数を順に書き出して", ""]) {
    assert.equal(copy.test(s), false, `写しが上限でない文面を拾う: ${s}`);
    assert.equal(limitNoticeIn(s), false, `正本が上限でない文面を拾う: ${s}`);
  }
});
