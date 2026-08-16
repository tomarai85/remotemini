// 封筒(レスポンス本体)を組む純関数 — 電話が復号する鍵名の**出所**をここ1箇所にする。
//
// なぜ view.mjs ではなく別 file か(2026-08-08、監査 S8-25):
//   view.mjs は `/view.mjs` として**ブラウザにそのまま配られる**ので、何も import できない
//   (file 冒頭の「★node の API を import しない」)。封筒は `paneFaultView`(blocked.mjs)を
//   要るので view.mjs には置けない。ここはサーバ専用 = import してよい。
//
// なぜハンドラの中から出したか:
//   `src/server.mjs` は import した瞬間に listen する為、ハンドラ内の literal は単体検査から
//   **一度も呼べない**。S8-24 で電話の Decodable 28本のうち突き合わせられたのが6本止まり
//   だった原因がこれ。封筒を純関数にすると、鍵名の照合(test/wire-key-agreement.test.mjs)が
//   実際に**実行して**鍵を採れる — 写しを目で比べるのではなく。
import { anomalyMessage, parseStatusMessage, selectionMessage, selectionProblem } from "./account.mjs";
import { paneFaultView } from "./blocked.mjs";
import { redact } from "./redact.mjs";
import { choiceView, gapNotice, routeLabel, scanLine, subtitleOf, whoOf } from "./view.mjs";

/**
 * 一覧の1行。`row` は生産者3つ(buildListing / registryOnlySessions / unreadableRow)の
 * いずれかの出力、`live` はその行の現在の居場所(tmux / worker / blocked)。
 *
 * ★`display` = **計算済み**と一目で分かる名前空間。生データの兄弟キーとして
 *   `routeLabelText` の様に散らすと、電話側が「これは観測値か表示語か」を
 *   毎回思い出す羽目になる。追加のみ = 既存の鍵は1つも動かさないので、
 *   `app.html` は無改修のまま(自分で view.mjs を呼び続ける)。
 */
export function sessionRow(row, live, machine) {
  return {
    ...row,
    live,
    // §9-2(2026-08-16): 「今どちらの機体に居るか」。無指定 = 机(edith)の仕事。
    // kind: "desk" | "checkout"。checkout は MBP から持ち出されて来ている仕事で、
    // returnRequestedAt が非 null なら「戻し待ち(MBP が開いた時に実行される)」。
    machine: machine ?? { kind: "desk", checkoutId: null, returnRequestedAt: null },
    display: { route: routeLabel(live), subtitle: subtitleOf(row) },
  };
}

/**
 * `GET /api/sessions` の封筒。
 *
 * `scan` を出す理由: `limit` が「会話の件数」になったので、**一覧が短い理由が2つ**ある —
 *   (a) ページが埋まって止めた(`examined < files`) (b) 全部見た上でこれだけ
 *   (`examined === files` = これ以上は無い)。区別できないと「以前を読む」が
 *   押しても何も起きないボタンになる(変異 M65 と同じ形)。
 *
 * ★`scanLine` は `scan` **本体**を受ける(行ごとの値ではない)。ここを取り違えても
 *   「関数を呼んだか」を見る検査は緑のままなので、検査は期待値を独立に組む
 *   (DESIGN §2.13 の訂正3)。
 *
 * ★`paneFault` に `display` を足した(2026-08-08 / 監査 S8-22)。`reason` は内部の英語トークン、
 *   `detail` は生の `e.message` で、電話はこの2つを**そのまま帯に描いていた** ——
 *   一覧が出ない時に出る、旅程で一番踏みそうな画面が、日本語ですらなかった。
 *   `reason` / `detail` は観測値として残す(診断と app.html の互換)。描くのは `display`。
 */
export function sessionsBody({ sessions, scan, paneFault }) {
  return {
    sessions,
    scan,
    display: { scan: scanLine(scan) },
    paneFault: paneFault
      ? { reason: paneFault.reason, detail: paneFault.detail, display: paneFaultView(paneFault.reason) }
      : null,
  };
}

/**
 * 流れの切れ目1件。**帯に出す文面まで**をここで決める(S 群)。
 *
 * ★`gapNotice` は `tail-attached`(購読を張った瞬間の正直な継ぎ目)に `null` を返す =
 *   「出さない」。`null` を空文字に化かさない —— 「出す物が無い」と「文面が空」は別で、
 *   後者は帯に空の警告を出す。`why` は消さずに残す(電話が理由で分岐する道を塞がない)。
 *
 * ★`seq` は**在る時だけ生やす**。`pollDecision` が返す4つ(cursor-too-long /
 *   cursor-malformed / route-changed / epoch-mismatch)には番号が無い。`undefined` を
 *   入れると JSON からは消えるのに `Object.keys` には出るので、鍵名の照合が
 *   「サーバが吐いている」と読む —— 線には無いのに。
 */
export function gapItem(why, seq) {
  const item = { kind: "gap", why, display: { notice: gapNotice(why) } };
  return seq === undefined ? item : { ...item, seq };
}

/**
 * 履歴・ライブの1発言に**表示語だけ**を足す(DESIGN §2.13 の S 群)。
 *
 * ★`role` は消さない。ネイティブは `display.who` を描くが、`app.html` は今まで通り
 *   自分で `whoOf(role)` を呼ぶ。片方だけが読む鍵を消すと、追加のみという条件が壊れる。
 * ★発言そのもの(`text`)には触らない。ここは**語を足す**層で、丸める層ではない。
 */
export function withWho(entry) {
  if (!entry || typeof entry !== "object") return entry;
  return { ...entry, display: { who: whoOf(entry.role) } };
}

/**
 * poll の項目のうち「発言」1件。**経路で中身が違う**:
 *   tmux    `entries` = 会話の発言の束(`withWho` を通した物)
 *   ワーカー `event`   = 我々が起こした子の NDJSON 1行そのもの
 *
 * ★無い方の鍵は生やさない(`gapItem` の `seq` と同じ理由)。ワーカー経路の項目に
 *   `entries: undefined` を入れると線からは消えるのに走査には出る。
 * ★ワーカー側に `display` を足さない。材料の `role` が無いので、足せば**無い物から
 *   作った名前**が付く(server.mjs の元の注釈のまま)。
 */
export function messageItem({ entries, event, seq }) {
  return {
    kind: "message",
    ...(entries === undefined ? {} : { entries }),
    ...(event === undefined ? {} : { event }),
    seq,
  };
}

/**
 * `GET /api/sessions/<id>/poll` の封筒(tmux 経路)。
 *
 * 引数は**既に決まった観測値**だけを受ける純関数。状態の読み取り(リングの巻き戻し・
 * 画面の版が変わったか)はハンドラに残す —— `src/server.mjs` は import した瞬間に
 * listen するので、ここへ持ち込めるのは「呼べる物」だけ。
 *
 * ★`display.choice` は `screen` と**同じ規則**で運ぶ(変わった時だけ載る / `null` =
 *   据え置き)。毎回載せると、画面が変わっていない poll が `show:false` を運んで
 *   **電話が持っている選択待ちの面を消す**(2026-08-05)。切り出す前は
 *   `screenChanged ? … : null` を2箇所に書いていた —— `screen` が非 null な時だけ
 *   `choice` も非 null、という関係が**2つの三項演算子の間**にしか無かった。
 *   ここでは `screen` 1つから両方を決めるので、片方だけ直す道が消える。
 */
export function pollBodyTmux({ items, screen, cursor, more }) {
  return {
    items,
    screen,
    display: { choice: screen ? choiceView(screen) : null },
    route: "tmux",
    // ★`null` であって `0` ではない(2026-08-04)。机で開かれている会話の送信待ちは
    //   Claude Code の TUI が自分で持っていて(`Press up to edit queued messages`)、
    //   我々はその数を**観測できない**。`0` と書けば「待っていない」という断定になる。
    queued: null,
    cursor,
    more,
  };
}

/**
 * 同・ワーカー経路。**`display` を持たない**のは意図で、tmux 経路との差はこの1鍵だけ。
 * ワーカーには画面が無く(`screen: null`)、選択待ちも起こらないので、載せる物が無い。
 *
 * ★`queued` は数で来る(`manager.status()` が持ち主)。tmux 側の `null` と対で読む事。
 */
export function pollBodyWorker({ items, queued, cursor, more }) {
  return { items, screen: null, route: "worker", queued, cursor, more };
}

/**
 * `GET /api/sessions/<id>/history` の封筒。発言に表示語を足すのも**ここ1箇所**にする。
 *
 * ★`truncated` = これより前がある。電話が「以前を読む」を出せるかがこの1鍵で決まる。
 * ★file がまだ無い / 読めない枝の `{history: []}` はハンドラに残す。空の応答に
 *   **2つの形**が実在する事は電話側が明示的に受けている(`HistoryModels.swift`)ので、
 *   ここで1つに均すと、その受け方が測れない物になる。
 */
export function historyBody({ entries, truncated }) {
  return { history: entries.map(withWho), truncated };
}

/**
 * `GET /healthz` の封筒(DESIGN §7-P)。**認証の外に出る唯一の応答**。
 *
 * ★引数を分解して受ける = 時計も pid もここでは読まない。読むとハンドラが渡した値と
 *   検査が見る値がズレて、「鍵名は合っているのに中身が別物」を作れる形になる。
 * ★返して良いのは**秘密でない値だけ**。セッション名も cwd も件数も入れない
 *   (件数は「今日は何本開いていたか」を認証の外へ漏らす)。鍵を1つ足す時は
 *   `test/wire-key-agreement.test.mjs` の `HealthzClient.Wire` の組が赤くなるので、
 *   電話側と同時に足す手を必ず通る。
 */
export function healthzBody({ pid, uptime, version }) {
  return { ok: true, pid, uptime, version };
}

/** 台本の生出力を線に載せる時の上限。診断の材料であって、全文を運ぶ道ではない。 */
export const ACCOUNT_RAW_MAX = 2000;

/**
 * `GET /api/account` と `POST /api/account/select|next` の封筒(REQUIREMENTS §9-3)。
 *
 * ★`account`(単数・人語1行)を**残す**理由:
 *   出荷済みの電話(`AccountState { let account: String }`)が此の鍵を読む。消すと、
 *   更新していない手元の版が黙って失敗表示になる。しかも中身は今まで
 *   **6行の人向け出力そのもの**が入っていて、それが §9-3 の苦情の機械的な正体だった。
 *   現用名だけを入れれば、古い版は**直る側**に転ぶ(壊れない、かつ良くなる)。
 *
 * ★`raw` は `ok` でない時だけ生やす:
 *   読めた時に生出力を運ぶ理由が無い(電話は構造しか使わない)。読めなかった時だけは
 *   「何が来たのか」を人が見られないと、edith に入らないと直せなくなる。
 *
 * ★`ok: false` と `accounts: []` を**別物として**運ぶ。混ぜると、台本の出力形式が
 *   変わった日に電話が「候補が1つも無い」という、もっともらしい嘘を描く(account.mjs 冒頭)。
 *
 * ★`display` に人語を畳む(S8-22 の再演を塞ぐ):
 *   `parseStatus: "no-order-header"` / `anomalies: ["active-count-0"]` は内部の英語トークン。
 *   `paneFault` の時は電話がこれを**そのまま帯に描いていた**。観測値は残し、描く物は
 *   `display` に置く —— 電話側で日本語を組み立て直すと、語彙が2箇所に分かれて必ずズレる。
 *   `display.status` は正常時 `null`(= 出す物が無い。空文字にすると空の帯が出る)。
 */
export function accountBody(parsed, { raw = "" } = {}) {
  const ok = parsed.parseStatus === "ok";
  return {
    account: parsed.current ?? "（未設定）", // 出荷済みの版が読む1行。中身は現用名だけ
    current: parsed.current,
    accounts: parsed.accounts.map((a) => accountRow(parsed, a)),
    ok,
    parseStatus: parsed.parseStatus,
    anomalies: parsed.anomalies,
    display: {
      status: parseStatusMessage(parsed.parseStatus),
      anomalies: parsed.anomalies.map(anomalyMessage),
    },
    ...(ok ? {} : accountRaw(raw)),
  };
}

/**
 * 読めなかった時だけ載せる生出力。**伏せてから切る**(順序に意味が在る)。
 *
 * ★2026-08-15(Codex 指摘)。切ってから伏せると、境目を跨いだ形が網に掛からない ——
 *   `worker.mjs` の stderr が既に同じ順序を取っている(`redact` は冪等なので二度掛けても
 *   `<mail>` が壊れない)。台本の出力が**想定外の形になった時こそ**、後から足された
 *   連絡先や token 表記が raw へ混ざり得るので、ここが最後の網になる。
 *
 * ★切った事は必ず名乗る。黙って切ると、途中で終わっている出力を全文だと読んだ人が
 *   「ここまでしか出ていない」を台本の症状として診断する事になる。
 */
function accountRaw(raw) {
  const red = redact(String(raw));
  const truncated = red.length > ACCOUNT_RAW_MAX;
  return { raw: truncated ? red.slice(0, ACCOUNT_RAW_MAX) : red, rawTruncated: truncated };
}

/**
 * 一覧の1行。**選べない行も出す**(消さない)。
 *
 * ★これは 2026-08-14 に取り消した `cwdIsGone` と同じ判断の再演: 行を消すと
 *   「そのアカウントが無い」に見え、本当の理由(トークンが欠けている / 名前が引数に使えない)が
 *   画面から消える。出して、押せなくして、理由を日本語で置く(DESIGN §2.88)。
 */
export function accountRow(parsed, a) {
  const problem = selectionProblem(parsed, a.name);
  return {
    name: a.name,
    hasToken: a.hasToken,
    active: a.active,
    selectable: problem === null,
    display: { blocked: problem === null ? null : selectionMessage(problem) },
  };
}
