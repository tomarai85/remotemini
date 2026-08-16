// 電話が**言う**秒数と、電話が**実際に待つ**秒数と、サーバが**実際に保持する**秒数が
// 同じ数か。
//
// 経緯 (2026-08-08, S8-23)。S8-19 / S8-20 / S8-21 / S8-22 は「画面に出る**文字列**を
// 本番が作れるか」を4面続けて縛った。根は文字列ではない —— **電話は境界の向こうの値を
// 写して持ち、写しを照合する者が居ない**。秒数は同じ根の、より痛い媒体である:
//
//   ・サーバの `POLL_MAX_WAIT_MS`(20_000ms)は、電話側に `serverPollMaxWait = 20` として
//     **手で写されている**。`BackendSession.swift` の注釈は「so the two numbers cannot
//     drift apart」と書いていたが、離れない事を確かめる機械は1つも無かった(この検査が
//     出来るまでは)。サーバが上限を 40 秒に伸ばした日、電話は 30 秒で諦めるので
//     **正常な「何も起きていない 200」が網の障害として出る**。移動中に一番出てほしくない嘘。
//   ・「最大30秒待ちます」の 30 は `writeTimeout` から作られている(S8-4 / S8-6 で
//     直書きを落とした)。ただし**どの client の待ちを言っているか**は注釈にしか無い。
//     `SendClient` の1行を `interactiveTimeout` に替えると、要求は 8 秒で諦めるのに
//     文は 30 秒と言い続ける —— 両側の単体検査は**両方緑のまま**。
//   ・画面検査(`InFlightUITests` / `KeyEntryUITests` / `TapTargetUITests`)は待つ文を
//     **文字列で焼いて**いる。UI の束を回す control は1本も無い(意図された設計)ので、
//     此処が腐っても誰も気付かない。焼くのは避けられない(UI 検査は別過程で走るので
//     アプリの定数を読めない)。避けられないなら、**焼いた数を照合する者**を置く。
//
// ★此の検査が縛るのは「今日の数」ではなく「写しどうしが動く時に一緒に動く事」。
//   定数を 45 に変えて文も 45 になるなら緑。片方だけ動いたら赤。control の陰性対照が
//   其の性質そのものを機械にしている(揃えて動かした変異は緑でなければならない)。
//
// ★木が居ない時は「測っていない」で飛ばす(赤ではない)。変異走行は `rc-backend/` だけの
//   部分木で回るので、此処が赤い造りだと走行中の**全件**が「検出」に化ける。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { ROOT, REPO, requireOutside } from "./subtree.mjs";

const SESSION = "ios/Sources/Core/BackendSession.swift";
const POLL_LOOP = "ios/Sources/Core/PollLoop.swift";
const CONV_VM = "ios/Sources/Screens/Conversation/ConversationViewModel.swift";
const KEY_VM = "ios/Sources/Screens/KeyEntry/KeyEntryViewModel.swift";
const CORE = "ios/Sources/Core";
const UITESTS = "ios/UITests";

const outside = requireOutside([SESSION, POLL_LOOP, CONV_VM, KEY_VM]);

const read = (rel) => readFileSync(join(REPO, rel), "utf8");

/** 行頭が注釈の行は読み飛ばす。注釈の中で数字に言及するのは正当(この直し自体が増やした)。 */
function isComment(line) {
  const t = line.trim();
  return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") || t.startsWith("///");
}

function codeLines(src) {
  return src.split("\n").filter((l) => !isComment(l));
}

/**
 * `BackendSession` の秒数の定数を読む。式は `12` / `別の定数` / `別の定数 + 12` の
 * 3形だけを解く。**知らない形は投げる** —— 解けない式を黙って飛ばすと、その定数だけが
 * 誰にも照合されないまま残り、しかも検査は緑に見える(S8-21 で踏んだ穴と同じ形)。
 */
function timeIntervalConstants(src) {
  const out = {};
  const re = /static let (\w+): TimeInterval = (.+)$/gm;
  let m;
  while ((m = re.exec(src)) !== null) {
    const name = m[1];
    const expr = m[2].trim().replace(/\s*\/\/.*$/, "");
    const num = /^([0-9_]+)$/.exec(expr);
    const ident = /^(\w+)$/.exec(expr);
    const sum = /^(\w+)\s*\+\s*([0-9_]+)$/.exec(expr);
    if (num) out[name] = Number(num[1].replace(/_/g, ""));
    else if (sum) {
      assert.ok(sum[1] in out, `${SESSION}: ${name} が未知の定数 ${sum[1]} を参照している`);
      out[name] = out[sum[1]] + Number(sum[2].replace(/_/g, ""));
    } else if (ident) {
      assert.ok(expr in out, `${SESSION}: ${name} が未知の定数 ${expr} を参照している`);
      out[name] = out[expr];
    } else {
      assert.fail(
        `${SESSION}: 秒数の式の形が増えている —— この評価器は解けない\n  ${name} = ${expr}\n` +
          `  解ける形: 数値 / 別の定数 / 別の定数 + 数値。広げるか、式を戻すか。` +
          `**飛ばすのは駄目** —— 飛ばした定数は誰にも照合されないまま緑になる`
      );
    }
  }
  return out;
}

test("★サーバが保持する上限と、電話が持つ其の写しが同じ数である", { skip: outside.skip }, () => {
  // 写しは1箇所ではない: 秒で持つ物(`serverPollMaxWait`)と、要求に載せて送る
  // ミリ秒(`PollLoop` の `nextWaitMs`)の2種類が在り、両方ともサーバの1つの定数の写し。
  const server = readFileSync(join(ROOT, "src/server.mjs"), "utf8");
  const declared = /^const POLL_MAX_WAIT_MS = ([0-9_]+);/m.exec(server);
  assert.ok(declared, "server.mjs の POLL_MAX_WAIT_MS を読めない(綴りか形が変わった)");
  const serverMaxWaitMs = Number(declared[1].replace(/_/g, ""));

  const consts = timeIntervalConstants(read(SESSION));
  assert.ok("serverPollMaxWait" in consts, `${SESSION}: serverPollMaxWait が居ない(錨)`);

  assert.equal(
    consts.serverPollMaxWait * 1000,
    serverMaxWaitMs,
    `電話が持つサーバ上限の写しが本物とズレている。\n` +
      `  server.mjs POLL_MAX_WAIT_MS : ${serverMaxWaitMs} ms\n` +
      `  BackendSession.serverPollMaxWait : ${consts.serverPollMaxWait} 秒\n` +
      `  ★サーバ側が伸びた場合、電話は正常な「何も起きていない 200」を網の障害として出す`
  );

  // 電話が要求に載せて送る待ち時間も同じ数。サーバは受け取った値を上限で clamp するので
  // 「大きすぎる」は安全側に落ちるが、**上限より小さい**と長い保持を毎回捨てる事になる。
  const src = read(POLL_LOOP);
  const code = codeLines(src).join("\n");
  // 値を渡している所だけを数える。型の宣言(`let nextWaitMs: Int`)は渡す場所ではない。
  const sites =
    (code.match(/nextWaitMs:/g) || []).length - (code.match(/let nextWaitMs:/g) || []).length;
  assert.ok(sites > 0, `${POLL_LOOP}: 待ち時間を渡している所を1件も拾えていない(錨)`);

  // 素の数値で書かれた物。三項式などは下の宣言で名指す。
  const literals = [];
  for (const line of codeLines(src)) {
    const m = /nextWaitMs:\s*([0-9_]+)\s*,/.exec(line);
    if (m) literals.push(Number(m[1].replace(/_/g, "")));
  }
  const plainSites = literals.length;

  /**
   * 素直な数値で書かれていない `nextWaitMs`。**行番号ではなく式そのもの**で名指す。
   * 式が動けば宣言が外れて総数が合わなくなり、其処で赤になる。
   */
  const WAIT_EXCEPTIONS = ["nextWaitMs: response.more ? 0 : 20_000"];
  for (const decl of WAIT_EXCEPTIONS) {
    const n = src.split(decl).length - 1;
    assert.equal(n, 1, `${POLL_LOOP}: 宣言した式が ${n} 箇所(1 でない)\n  ${decl}`);
    for (const raw of decl.match(/[0-9_]+/g) || []) literals.push(Number(raw.replace(/_/g, "")));
  }

  // ★総数の帳尻。新しい書き方の待ち時間が増えたら、照合も宣言もされないまま此処で赤になる。
  //   拾えなかった物を無かった事にすると、0件が「全部一致」に化ける(S8-21 と同じ穴)。
  assert.equal(
    plainSites + WAIT_EXCEPTIONS.length,
    sites,
    `${POLL_LOOP}: 待ち時間の書き方が増えている(渡す所 ${sites} / 数値 ${plainSites} / 宣言 ${WAIT_EXCEPTIONS.length})`
  );

  for (const ms of literals) {
    assert.ok(
      ms === 0 || ms === serverMaxWaitMs,
      `${POLL_LOOP}: 要求に載せる待ち時間がサーバの上限でも 0 でもない\n` +
        `  この木: ${ms} ms / サーバ: ${serverMaxWaitMs} ms`
    );
  }
});

/**
 * 「飛んでいる間」の一文と、其の文が説明している要求を出す client の対応。
 * **注釈にしか無かった対応を、機械の読める場所へ移す**のが此の宣言の役目。
 */
const SENTENCE_CLIENT = {
  sendInFlightText: "SendClient.swift",
  interruptInFlightText: "InterruptClient.swift",
  choiceInFlightText: "ChoiceClient.swift",
  urlProbeInFlightText: "HealthzClient.swift",
  keyProbeInFlightText: "SessionsAuthProbe.swift",
};

test("★「最大N秒待ちます」の N は、其の要求が実際に載せている秒数である", { skip: outside.skip }, () => {
  // 秒数を直書きしない事は既に両 ViewModel の単体検査が見ている。此処が見るのは其の一段上 ——
  // **渡している定数が、其の待ちを実際に決めている定数か**。`SendClient` の1行だけを
  // `interactiveTimeout` に替えると、要求は 8 秒で諦めるのに文は 30 秒と言い続け、
  // `SendClientTests` も `ConversationViewModelTests` も**両方緑のまま**通る。
  const clientTimeout = {};
  for (const entry of readdirSync(join(REPO, CORE))) {
    if (!entry.endsWith(".swift")) continue;
    for (const line of codeLines(readFileSync(join(REPO, CORE, entry), "utf8"))) {
      const m = /request\.timeoutInterval\s*=\s*BackendSession\.(\w+)/.exec(line);
      if (m) clientTimeout[entry] = m[1];
    }
  }
  assert.ok(
    Object.keys(clientTimeout).length > 0,
    `${CORE}: 待ち時間を載せている client を1件も拾えていない(錨)`
  );

  const sentenceTimeout = {};
  for (const rel of [CONV_VM, KEY_VM]) {
    for (const line of codeLines(read(rel))) {
      const m = /Self\.(\w*InFlightText)\(timeout:\s*BackendSession\.(\w+)\)/.exec(line);
      if (m) sentenceTimeout[m[1]] = m[2];
    }
  }

  // 錨。呼び出しの書き方が変わって1件も拾えなくなると、下の照合は0件で緑になる。
  assert.deepEqual(
    Object.keys(sentenceTimeout).sort(),
    Object.keys(SENTENCE_CLIENT).sort(),
    "飛んでいる間の文の呼び出しが、宣言した一覧と一致しない(増えた/減った/書き方が変わった)"
  );

  for (const [maker, clientFile] of Object.entries(SENTENCE_CLIENT)) {
    assert.ok(
      clientFile in clientTimeout,
      `${CORE}/${clientFile} が待ち時間を載せていない(改名された/行が消えた)`
    );
    assert.equal(
      sentenceTimeout[maker],
      clientTimeout[clientFile],
      `文が言う秒数と、要求が実際に待つ秒数が別の定数から来ている\n` +
        `  文  : ${maker} <- BackendSession.${sentenceTimeout[maker]}\n` +
        `  要求: ${clientFile} <- BackendSession.${clientTimeout[clientFile]}\n` +
        `  ★どちらかを動かす時は両方動かす。片方だけだと画面が嘘の秒数を言う`
    );
  }
});

/**
 * 画面検査に**焼かれている**秒数の宣言。UI 検査は別の過程で走るのでアプリの定数を
 * 読めない —— 焼くのは避けられない。避けられないなら照合する者を置く、が此の宣言。
 * 値は定数からの式で書く(今日の数を書かない)。
 */
const UITEST_SECONDS = {
  "InFlightUITests.swift": (c) => [c.writeTimeout],
  // 2段の合計(16秒)も出る。1段ずつの 8 と、利用者が体感する合計の両方。
  "KeyEntryUITests.swift": (c) => [c.interactiveTimeout, c.interactiveTimeout * 2],
  "TapTargetUITests.swift": (c) => [c.writeTimeout],
};

test("★画面検査に焼いた秒数が、いま効いている秒数と同じである", { skip: outside.skip }, () => {
  const consts = timeIntervalConstants(read(SESSION));
  const seen = {};

  for (const entry of readdirSync(join(REPO, UITESTS))) {
    if (!entry.endsWith(".swift")) continue;
    const src = readFileSync(join(REPO, UITESTS, entry), "utf8");
    // 2026-08-17 英語化: 焼き文は "waiting up to Ns"。旧綴り(最大N秒)は assertion
    // message やコメントにだけ残る(画面には出ない)ので、数えると偽の不一致になる —
    // 英語綴りだけを見る。
    const found = [...src.matchAll(/waiting up to (\d+)s/g)].map((m) => Number(m[1]));
    if (found.length > 0) seen[entry] = found;
  }

  // ★宣言していない file が秒数を焼き始めたら此処で赤。「知っている file だけ見る」形にすると、
  //   新しい画面検査が黙って外側に落ちる —— 検査の外に落ちた物は永久に見えない。
  assert.deepEqual(
    Object.keys(seen).sort(),
    Object.keys(UITEST_SECONDS).sort(),
    "秒数を焼いている画面検査の集合が、宣言と一致しない(新しい file が焼き始めた/焼くのを止めた)"
  );

  for (const [entry, found] of Object.entries(seen)) {
    const allowed = UITEST_SECONDS[entry](consts);
    for (const n of found) {
      assert.ok(
        allowed.includes(n),
        `${UITESTS}/${entry}: 焼いた秒数が今の定数から作れない\n` +
          `  焼いた値: ${n} 秒 / 作れる値: ${allowed.join(" / ")} 秒\n` +
          `  ★UI の束を回す control は無いので、此処が腐っても走らせるまで誰も気付かない`
      );
    }
  }
});

test("読む待ちと書く待ちが別の数のままである(分割が畳まれていない)", { skip: outside.skip }, () => {
  // 上の3件は「写しどうしが一致するか」しか見ない。**全部を1つの定数に畳む**変更は
  // 一致したまま通ってしまい、しかも REQUIREMENTS §5-6 が直した当の症状
  // (応答の無い網で白画面が長く続く)がそのまま戻る。畳めない事は別に言う必要が在る。
  const c = timeIntervalConstants(read(SESSION));
  assert.ok(c.interactiveTimeout < c.pollTimeout, "読む待ちが長い待ちより短くない = 分割の意味が消えている");
  assert.equal(c.writeTimeout, c.pollTimeout, "書く待ちを縮めると二重投入の窓が開く(冪等鍵が無い)");
});
