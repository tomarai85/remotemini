// `fleet-account` の出力を読む暫定アダプターの検査。
//
// ★fixture は**実測**である事に意味が在る(2026-08-14、Codex の条件):
//   人向け出力を解析する層の危険は「自分が書いた期待値を自分で解析して緑になる」事。
//   `LIVE_2026_08_14` は edith 上の本物の `fleet-account` を叩いて採った文字列を
//   1文字も直さずに置いた物。台本の printf が変わったらここが赤くなるのが正しい。
//
// ★もう1つ押さえるのは「読めなかった」と「本当に0件」の区別 —
//   混ぜると、台本の出力形式が変わった日に電話が「候補が1つも無い」という
//   **もっともらしい嘘**を出す(切替を諦めるべき場面で、単に選択肢が消えたように見える)。
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ACCOUNT_NAME_MAX, ACTIVE_COUNT_PREFIX, ANOMALY_REASONS, PARSE_STATUSES, SELECTION_REASONS,
  accountNameProblem, anomalyMessage, parseFleetAccount, parseStatusMessage,
  selectionMessage, selectionProblem,
  unknownAnomalyMessage, unknownParseStatusMessage, unknownSelectionMessage,
} from "../src/account.mjs";

// edith 上で `~/fleet-tools/fleet-account` を引数なしで叩いた実出力(2026-08-14 実測)。
const LIVE_2026_08_14 = [
  "現用: team",
  "優先順 (.order):",
  "  -> 1. team     トークン:有",
  "     2. biz      トークン:有",
  "     3. sdgs      トークン:有",
  "     4. tom      トークン:有",
  "",
].join("\n");

test("★実出力(2026-08-14 実測)を構造に読み切る", () => {
  const p = parseFleetAccount(LIVE_2026_08_14);
  assert.equal(p.parseStatus, "ok");
  assert.equal(p.current, "team");
  assert.deepEqual(p.anomalies, []);
  assert.deepEqual(p.accounts, [
    { name: "team", order: 1, hasToken: true, active: true },
    { name: "biz", order: 2, hasToken: true, active: false },
    { name: "sdgs", order: 3, hasToken: true, active: false },
    { name: "tom", order: 4, hasToken: true, active: false },
  ]);
});

test("現用が未設定(symlink 無し)でも一覧は読める", () => {
  const p = parseFleetAccount("現用: （未設定）\n優先順 (.order):\n     1. team     トークン:有\n");
  assert.equal(p.parseStatus, "ok");
  assert.equal(p.current, null);
  assert.equal(p.accounts.length, 1);
  // 現用が無いのだから「印が1つでない」は異常ではない
  assert.deepEqual(p.anomalies, []);
});

test("トークン欠けは hasToken:false として残す(行を捨てない)", () => {
  const p = parseFleetAccount("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     2. biz      トークン:欠\n");
  assert.equal(p.parseStatus, "ok");
  assert.equal(p.accounts[1].hasToken, false);
  // 一覧には出す。選べないだけ = 「なぜ選べないか」を電話が言える
  assert.equal(selectionProblem(p, "biz"), "no-token");
});

// --- 「読めなかった」と「本当に0件」の分かれ目 ---------------------------------

test("★見出しが在って行が0本 = 本当に候補ゼロ(.order が読めない時に台本が出す形)", () => {
  const p = parseFleetAccount("現用: （未設定）\n優先順 (.order):\n");
  assert.equal(p.parseStatus, "ok"); // 出力は読み切れている
  assert.deepEqual(p.accounts, []);
  // ★**黙って空を渡さない**(2026-08-15)。`parseStatus: "ok"` は `display.status` が
  //   null になる = 電話の設定画面には現用と矢印だけが出て、候補が0本である事の説明が
  //   1文字も出ない状態だった。行が0本な事自体を引っ掛かりとして載せる。
  assert.ok(p.anomalies.includes("empty-order"),
    "行が0本なのに、その事を言う anomaly が1つも載っていない(画面が黙る)");
});

test("★空の一覧に**行が在る前提の誤診**を並べない(現用が設定されていても)", () => {
  const p = parseFleetAccount("現用: team\n優先順 (.order):\n");
  assert.deepEqual(p.accounts, []);
  assert.deepEqual(p.anomalies, ["empty-order"]);
  // 負の対照: この2つが出ると「一覧に行が在るのに現用が見当たらない」と読める。
  // 実際は行が0本なので、symlink を疑わせるのも印を数えるのも診断として間違い。
  assert.ok(!p.anomalies.includes("current-not-listed"),
    "行が0本なのに symlink を疑わせる文が出ている");
  assert.ok(!p.anomalies.some((a) => a.startsWith("active-count-")),
    "行が0本なのに現用の印を数えた文が出ている");
});

test("★出力形式が変わったら parseStatus で落ちる(空の一覧に化けない)", () => {
  for (const [name, out] of [
    ["1行目が別物", "accounts:\n  team\n"],
    ["見出しが無い", "現用: team\n  -> 1. team     トークン:有\n"],
    ["行が読めない", "現用: team\n優先順 (.order):\n  -> 1. team  [active]\n"],
    ["空", ""],
  ]) {
    const p = parseFleetAccount(out);
    assert.notEqual(p.parseStatus, "ok", `${name}: 読めていないのに ok を返した`);
    assert.deepEqual(p.accounts, [], `${name}: 半端に読んだ一覧を返している`);
    assert.equal(selectionProblem(p, "team"), "listing-unreadable", `${name}: 切替を許してしまう`);
  }
});

test("行が1本でも読めなければ一覧全体を捨てる(半分だけの一覧は間違った真実)", () => {
  const p = parseFleetAccount("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     2. biz  ???\n");
  assert.equal(p.parseStatus, "unreadable-rows");
  assert.deepEqual(p.accounts, []);
  assert.equal(p.current, "team"); // 現用だけは読めたので残す(表示には使える)
  // ★`empty-order`(2026-08-15 に足した「候補が0件」)を此処へ混ぜない。行は在るのに
  //   読めなかっただけなので、「候補が0件」は嘘になる —— この file の頭が守ると
  //   言っている一線(「読めなかった」と「本当に0件だった」を混ぜない)そのもの。
  //   構造上も `unreadable-rows` は `empty()` で早く返るので此処へは来ないが、
  //   其れは**今の書き方**の性質でしかない。混ざった時に赤くなる物を置いておく。
  assert.deepEqual(p.anomalies, [],
    "行が読めなかったのに『候補が0件』側の引っ掛かりが載っている");
});

// --- 名前の不変条件(白名簿と併用する側) ---------------------------------------

test("★`--next` という名のアカウントは一覧に在っても切替に使わない", () => {
  // 台本の `case "$1"` は `--next` を `*)` より先に拾う = 切替ではなく「次へ送る」が走る。
  // 白名簿(一覧に在る)を通ってしまう経路なので、名前の不変条件が独立に要る。
  const p = parseFleetAccount("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     2. --next   トークン:有\n");
  assert.equal(p.parseStatus, "ok");
  assert.equal(p.accounts[1].name, "--next"); // 一覧には出る
  assert.equal(selectionProblem(p, "--next"), "leading-dash"); // 切替には使わせない
});

test("引数として危ない名前は全部断る", () => {
  const cases = {
    "": "empty",
    ".": "dot",
    "..": "dot",
    "-h": "leading-dash",
    "--help": "leading-dash",
    "../../etc/passwd": "path-separator", // `.` 始まりなので dot ではなく区切りで落ちる
    "a/b": "path-separator",
    "a\\b": "path-separator",
    "a\u0000b": "control-char",
    "a\tb": "control-char",
    "a\nb": "control-char",
    "a b": "whitespace",
    ["x".repeat(ACCOUNT_NAME_MAX + 1)]: "too-long",
  };
  for (const [name, want] of Object.entries(cases)) {
    assert.equal(accountNameProblem(name), want, `${JSON.stringify(name)} の断り方`);
  }
  assert.equal(accountNameProblem(42), "not-a-string");
  for (const ok of ["team", "biz", "sdgs", "tom", "a.b", "a_b", "a-b"]) {
    assert.equal(accountNameProblem(ok), null, `${ok} は通るべき`);
  }
});

test("一覧に無い名前は断る(不変条件を通っても白名簿で落ちる)", () => {
  const p = parseFleetAccount(LIVE_2026_08_14);
  assert.equal(selectionProblem(p, "unknown"), "unknown-account");
  assert.equal(selectionProblem(p, "team"), null);
});

// --- 一覧は読めるが引っ掛かる形(表示は出す / 異常は黙らせない) -----------------

test("現用が .order に載っていない事は起こる — 捨てずに印を付ける", () => {
  const p = parseFleetAccount("現用: ghost\n優先順 (.order):\n     1. team     トークン:有\n");
  assert.equal(p.parseStatus, "ok");
  assert.equal(p.current, "ghost");
  assert.ok(p.anomalies.includes("current-not-listed"));
  assert.ok(p.anomalies.includes("active-count-0"));
});

test("同名が2本 / 番号が飛ぶ形も印を付ける", () => {
  const dup = parseFleetAccount("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     2. team     トークン:有\n");
  assert.ok(dup.anomalies.includes("duplicate-name"));
  const skip = parseFleetAccount("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     3. biz      トークン:有\n");
  assert.ok(skip.anomalies.includes("order-not-sequential"));
});

// --- 「なぜ選べないか」の文面(blocked.test.mjs と同じ規律) --------------------

test("★断る理由は全部、既定でない文を持つ(覆い漏れ = 「理由: no-token」という機械語が人に出る)", () => {
  for (const reason of SELECTION_REASONS) {
    const msg = selectionMessage(reason);
    assert.equal(typeof msg, "string");
    assert.ok(msg.length >= 10, `${reason}: 文が短すぎる`);
    assert.notEqual(msg, unknownSelectionMessage(reason), `${reason} が既定に落ちている`);
  }
});

test("覆っていない理由は既定に落ちる(上の検査が常に緑にならない事の対照)", () => {
  assert.equal(selectionMessage("made-up"), unknownSelectionMessage("made-up"));
});

// --- 状態コードの人語(電話が英語トークンを帯に描かない為) ----------------------

test("★`parseStatus` は全部、既定でない文を持つ(`ok` だけは null = 出す物が無い)", () => {
  for (const status of PARSE_STATUSES) {
    const msg = parseStatusMessage(status);
    if (status === "ok") {
      // 空文字ではなく null。「出す物が無い」と「文面が空」を混ぜると帯に空の警告が出る
      assert.equal(msg, null, "ok に文面を付けると、正常時にも帯が出る");
      continue;
    }
    assert.equal(typeof msg, "string");
    assert.ok(msg.length >= 10, `${status}: 文が短すぎる`);
    assert.notEqual(msg, unknownParseStatusMessage(status), `${status} が既定に落ちている`);
  }
});

test("覆っていない parseStatus は既定に落ちる(上の検査が常に緑にならない事の対照)", () => {
  assert.equal(parseStatusMessage("made-up"), unknownParseStatusMessage("made-up"));
});

test("★`anomalies` は全部、既定でない文を持つ(`active-count-<n>` の族を含む)", () => {
  for (const a of [...ANOMALY_REASONS, `${ACTIVE_COUNT_PREFIX}0`, `${ACTIVE_COUNT_PREFIX}2`]) {
    const msg = anomalyMessage(a);
    assert.equal(typeof msg, "string");
    assert.ok(msg.length >= 10, `${a}: 文が短すぎる`);
    assert.notEqual(msg, unknownAnomalyMessage(a), `${a} が既定に落ちている`);
  }
  // 数の所は本当に読んでいる(族を1文に潰していない)
  assert.match(anomalyMessage(`${ACTIVE_COUNT_PREFIX}3`), /3 rows/);
});

test("覆っていない anomaly / 壊れた族名は既定に落ちる(対照)", () => {
  assert.equal(anomalyMessage("made-up"), unknownAnomalyMessage("made-up"));
  // 接頭辞は合っていても数でなければ族として畳まない
  assert.equal(anomalyMessage(`${ACTIVE_COUNT_PREFIX}x`), unknownAnomalyMessage(`${ACTIVE_COUNT_PREFIX}x`));
});

test("★実際に出せる parseStatus / anomalies が正本の域と一致する(両向き)", () => {
  const statuses = new Set();
  const anomalies = new Set();
  const record = (out) => {
    const p = parseFleetAccount(out);
    statuses.add(p.parseStatus);
    for (const a of p.anomalies) anomalies.add(a);
  };
  record(LIVE_2026_08_14);                                                        // ok
  record("accounts:\n");                                                          // no-current-line
  record("現用: team\n  -> 1. team     トークン:有\n");                            // no-order-header
  record("現用: team\n優先順 (.order):\n  -> 1. team  ???\n");                     // unreadable-rows
  record("現用: team\n優先順 (.order):\n  -> 1.      トークン:有\n");              // unnamed-row
  record("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     3. biz      トークン:有\n"); // order-not-sequential
  record("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     2. team     トークン:有\n"); // duplicate-name
  record("現用: ghost\n優先順 (.order):\n     1. team     トークン:有\n");         // current-not-listed + active-count-0
  record("現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n  -> 2. biz      トークン:有\n"); // active-count-2
  record("現用: team\n優先順 (.order):\n");                                       // empty-order

  assert.deepEqual([...statuses].sort(), [...PARSE_STATUSES].sort(),
    "出せる parseStatus と正本の域が食い違っている");
  // 族は接頭辞で畳んでから突き合わせる(n は無限に在る)
  const fixed = [...anomalies].filter((a) => !a.startsWith(ACTIVE_COUNT_PREFIX));
  const family = [...anomalies].filter((a) => a.startsWith(ACTIVE_COUNT_PREFIX));
  assert.deepEqual(fixed.sort(), [...ANOMALY_REASONS].sort(),
    "出せる anomaly と正本の域が食い違っている");
  assert.deepEqual(family.sort(), [`${ACTIVE_COUNT_PREFIX}0`, `${ACTIVE_COUNT_PREFIX}2`],
    "族の代表が2つとも出ていない = 上の文面検査は族を測れていない");
});

test("★`selectionProblem` が返す値は全部 SELECTION_REASONS に居る(域の取りこぼしを塞ぐ)", () => {
  const p = parseFleetAccount(LIVE_2026_08_14);
  const seen = new Set();
  const probes = [42, "", "x".repeat(ACCOUNT_NAME_MAX + 1), ".", "-h", "a/b", "a\u0000b", "a b", "unknown"];
  for (const bad of probes) {
    const r = selectionProblem(p, bad);
    assert.ok(r, `${JSON.stringify(bad)} が通ってしまった`);
    seen.add(r);
  }
  seen.add(selectionProblem(parseFleetAccount(""), "team")); // listing-unreadable
  seen.add(selectionProblem(parseFleetAccount(
    "現用: team\n優先順 (.order):\n  -> 1. team     トークン:有\n     2. biz      トークン:欠\n"), "biz")); // no-token
  for (const r of seen) assert.ok(SELECTION_REASONS.includes(r), `${r} が正本の域に居ない`);
  // ★逆向きも測る: 正本に「一度も出せない理由」が紛れていないか。
  //   出せない理由が域に居ると、文面の検査(上)は緑なのに死んだ文を守り続ける。
  assert.deepEqual([...SELECTION_REASONS].sort(), [...seen].sort(),
    "正本の域と、実際に出せた理由が食い違っている");
});

// ★台本の出力 → 封筒、の**一続き**を1本で押さえる(2026-08-15)。
//   `parseFleetAccount` の側は上で、`anomalyMessage` の語彙も上で測っているが、
//   其の2つを `accountBody` が繋いでいる事は何処でも測っていなかった ——
//   `wire-key-agreement` は**鍵名**しか見ないので、`display.anomalies` を
//   組み立てる行(`wire.mjs` の `parsed.anomalies.map(anomalyMessage)`)を
//   丸ごと落としても緑のままになる。電話が実際に描くのは此の枝。
test("★行が0本の時、電話が描く `display.anomalies` に人の読める理由が届く(解析→封筒。2026-08-17 から英語)", async () => {
  const { accountBody } = await import("../src/wire.mjs");
  const body = accountBody(parseFleetAccount("現用: （未設定）\n優先順 (.order):\n"));

  assert.equal(body.ok, true);        // 読めてはいる = 「読めなかった」の顔をさせない
  assert.deepEqual(body.accounts, []);
  assert.equal(body.display.status, null);
  assert.equal(body.display.anomalies.length, 1);
  assert.match(body.display.anomalies[0], /zero priority entries/);
  // 内部トークンは観測値として残るが、描く物は日本語の側(S8-22 の再演を塞ぐ)。
  assert.deepEqual(body.anomalies, ["empty-order"]);
  assert.notEqual(body.display.anomalies[0], "empty-order");
});

// ── 読めなかった時に載る生出力(2026-08-15、Codex の指摘で足した) ────────────
//
// ★`raw` は「台本が吐いた物をそのまま」載せる鍵で、**唯一の自由書式**が線に出る場所。
//   `fleet-account` の stderr には edith の環境がそのまま流れ込むので、伏せ字と上限は
//   飾りではない。此処を測っていなかったので、載せた当日に測る側を書いた。
test("★生出力は伏せてから載る(台本の stderr に混ざった宛先を線に出さない)", async () => {
  const { accountBody } = await import("../src/wire.mjs");
  const stdout = "garbage line\nerror: could not read /Users/x/.config for mail-redacted@example.invalid\n";
  const body = accountBody(parseFleetAccount(stdout), { raw: stdout });

  assert.equal(body.ok, false);
  assert.doesNotMatch(body.raw, /@gmail/, "宛先がそのまま線に出ている");
  assert.match(body.raw, /<mail>/);
  assert.match(body.raw, /garbage line/, "伏せ字が診断の材料まで消している");
});

test("★上限を超えた生出力は切って、切った事を `rawTruncated` で名乗る", async () => {
  const { accountBody, ACCOUNT_RAW_MAX } = await import("../src/wire.mjs");
  const stdout = `garbage line\n${"x".repeat(ACCOUNT_RAW_MAX + 100)}`;
  const body = accountBody(parseFleetAccount(stdout), { raw: stdout });

  assert.equal(body.raw.length, ACCOUNT_RAW_MAX);
  assert.equal(body.rawTruncated, true);
});

test("★上限以下なら `rawTruncated` は false(鍵ごと消して『切れていない』を推測させない)", async () => {
  const { accountBody } = await import("../src/wire.mjs");
  const stdout = "garbage line\nmore";
  const body = accountBody(parseFleetAccount(stdout), { raw: stdout });

  assert.equal(body.raw, stdout);
  assert.equal(body.rawTruncated, false);
  assert.ok("rawTruncated" in body, "鍵が消えると、電話は『切れていない』を欠けから推測する事になる");
});

// ★順序の検査(`src/redact.mjs` 冒頭が変異 W18 として名指ししている形)。
//   切ってから伏せると、上限に跨った宛先は**左半分だけが残って**網を抜ける ——
//   `client-a.team@gm` は網が要求する `@ドメイン.tld` の全体を満たさないので、
//   一番読まれたくない側だけが線に出る。踏むのは上限に達した時だけだが、
//   「稀にしか踏まない」は「起きない」ではない。
test("★伏せてから切る(上限に跨った宛先の左半分だけが残る道を塞ぐ)", async () => {
  const { accountBody, ACCOUNT_RAW_MAX } = await import("../src/wire.mjs");
  const mail = "mail-redacted@example.invalid";
  // 宛先が丁度 `ACCOUNT_RAW_MAX` を跨ぐように置く。
  const head = `garbage line\n${"x".repeat(ACCOUNT_RAW_MAX - 12 - 10)}`;
  const stdout = `${head}${mail}${"y".repeat(50)}`;
  const body = accountBody(parseFleetAccount(stdout), { raw: stdout });

  assert.doesNotMatch(body.raw, /client-a/, "切ってから伏せている(宛先の左半分が残った)");
  assert.match(body.raw, /<mail>/);
});

test("★読めた時は生出力を載せない(`raw` も `rawTruncated` も鍵ごと出ない)", async () => {
  const { accountBody } = await import("../src/wire.mjs");
  const stdout = "現用: team\n優先順 (.order):\n->  1. team     トークン:有\n";
  const body = accountBody(parseFleetAccount(stdout), { raw: stdout });

  assert.equal(body.ok, true);
  assert.ok(!("raw" in body), "読めているのに生出力を運んでいる");
  assert.ok(!("rawTruncated" in body));
});
