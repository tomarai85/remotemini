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
import { attentionOf } from "./digest.mjs";

/**
 * 一覧の1行。`row` は生産者3つ(buildListing / registryOnlySessions / unreadableRow)の
 * いずれかの出力、`live` はその行の現在の居場所(tmux / worker / blocked)。
 *
 * ★`display` = **計算済み**と一目で分かる名前空間。生データの兄弟キーとして
 *   `routeLabelText` の様に散らすと、電話側が「これは観測値か表示語か」を
 *   毎回思い出す羽目になる。追加のみ = 既存の鍵は1つも動かさないので、
 *   `app.html` は無改修のまま(自分で view.mjs を呼び続ける)。
 */
export function sessionRow(row, live, machine, diff = null) {
  return {
    ...row,
    live,
    // 2026-09-02(対照表 #5): 作業木の未コミット差分の**数**。`{files, added, removed}`。
    // ★null = 読めなかった / まだ読んでいない / git 管理外。0 件とは別の意味なので丸めない。
    diff,
    // §9-2(2026-08-16): 「今どちらの機体に居るか」。無指定 = 机(edith)の仕事。
    // kind: "desk" | "checkout"。checkout は MBP から持ち出されて来ている仕事で、
    // returnRequestedAt が非 null なら「戻し待ち(MBP が開いた時に実行される)」。
    machine: machine ?? { kind: "desk", checkoutId: null, returnRequestedAt: null },
    // ★「Tom の返事を待っている」を**一覧にも**載せる(2026-08-27)。
    //
    //   なぜ要るか(実測): 会話の画面は digest を取って「待っている」を出すが、
    //   **一覧は `route.kind === "choice"` の時だけ**「Needs input」を出していた。
    //   実測すると生きた 2 本とも `route = null` で、あの札は一度も出ていない。
    //   一方 digest は同じ会話を `attention=input` と判定していた ——
    //   つまり **Tom は開くまで待たれている事を知れない**。開くまでの時間こそ、
    //   この機能が取り戻そうとしている死に時間そのもの(2026-08-26 に 60 分観測)。
    //
    // ★**判定器を2つ持たない。** `attentionOf` は digest と同じ物を呼ぶ。
    //   電話側で `screen` から推測すると、机と電話で「待っている」の定義が分かれ、
    //   必ず片方だけ腐る(`AccountClient` の `blocked` と同じ判断)。
    //
    // ★N+1 を作らない。一覧は既に `live` に `screen`/`activity` を持っているので、
    //   1 行あたりの追加の往復は**ゼロ**。
    //
    // ★`unknown` は **false**。読めなかった事を「待っている」に倒すと、
    //   正直だが役に立たない札が並び、Tom は札そのものを見なくなる(Codex 2026-08-26)。
    requiresOwnerInput: OWNER_INPUT_STATES.has(attentionOf(live)),
    display: { route: routeLabel(live), subtitle: subtitleOf(row) },
  };
}

/** 「Tom の返事が要る」と言ってよい attention。`unknown`/`none` は含めない。 */
const OWNER_INPUT_STATES = new Set(["choice", "input"]);

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
/**
 * 「机はもっと新しい版を配っている」を電話に言わせる文面(2026-08-30)。
 *
 * なぜ要るか — CF-11 と CF-17 が一続きの失敗を作った:
 *   私は「4件の指摘は反映済み・目視待ち」と報告したが、其の修正は **Tom が持っている
 *   どの版にも入っていなかった**(commit は署名の3分後)。そして CF-17 で、配布口には
 *   `client=app` が **path を問わず1本も来ていない**と実測された —— 栞は一度も叩かれていない。
 *   つまり「新しい版が在る」を伝える経路が、**私が思い出して言う**しか無かった。
 *   私の記憶は F3 以来ずっと此の系の最弱点なので、構造で置き換える。
 *
 * ★どちらか一方でも判らなければ `null`(= 出さない)。推測しない。
 *   「配っている版が読めない」を「新しいのが在る」に化かすと、栞を叩いても何も変わらず、
 *   その1回で此の帯は二度と読まれなくなる。
 * ★比べるのは**配っている版**(manifest)であって承認済みの版ではない。巻き戻った時に
 *   「105 が在る」と言うのは嘘になる —— 叩いても 96 しか入らない。
 * ★等しい時・電話の方が新しい時も `null`。差が在る時だけ言う。
 */
export function updateNotice(publishedBuild, appBuild) {
  // ★**全桁が数字**の物だけ通す。`parseInt` は前方一致なので `"96abc"` を 96 として
  //   受ける —— 電話の版は **User-Agent 由来**(誰でも詐称できる)なので、
  //   出鱈目な名乗りから作った数字を Tom の画面に出す事になる。
  //   `reqlog.appBuild()` が読めない時に `"-"` を返すのと同じ、閉じる側の判断。
  const digits = (v) => (/^\d{1,9}$/.test(String(v ?? "").trim()) ? Number(String(v).trim()) : NaN);
  const pub = digits(publishedBuild);
  const mine = digits(appBuild);
  if (!Number.isSafeInteger(pub) || !Number.isSafeInteger(mine)) return null;
  if (pub <= 0 || mine <= 0) return null;
  if (pub <= mine) return null;
  return `机は新しい版を配っています(手元 ${mine} → 配布 ${pub})。栞から入れ直してください。`;
}

/**
 * 帯が指している**配布側の番号**(文字列)か `null`。文面と同じ条件で出す。
 *
 * ★何に使うか: 電話が「此の版は後で」を憶える鍵。番号が無いと、憶えられるのは
 *   「帯を消した」という事実だけになり、**次の版が出ても黙ったまま**になる ——
 *   壁紙を消す為の仕掛けが、警報そのものを消す。
 * ★文面から数字を拾わせない。文面は語を直す事が在り、其の度に電話の記憶が壊れる。
 */
export function updateBuild(publishedBuild, appBuild) {
  return updateNotice(publishedBuild, appBuild) === null
    ? null
    : String(publishedBuild).trim();
}

export function sessionsBody({ sessions, scan, paneFault, publishedBuild, appBuild }) {
  return {
    sessions,
    scan,
    display: {
      scan: scanLine(scan),
      update: updateNotice(publishedBuild, appBuild),
      updateBuild: updateBuild(publishedBuild, appBuild),
    },
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
 * `GET /api/sessions/<id>/status` の封筒(tmux 経路)。対照表 #16。
 *
 * ★以前は `src/server.mjs` に literal で書かれていて、突き合わせ表(S8-25/26 と同じ
 *   理由)から測れなかった。ここへ切り出したのは `permissionMode` を足す為 —— 机が
 *   bypass で走っているかを電話から知る手段が今まで無かった(D4/#17 の裁定には触れない
 *   読むだけの1鍵)。`screen` は `screenOf(pane)` の戻りをそのまま展開する
 *   (poll の `screenChanged ? f.screen.body : null` とは別経路 —— こちらは1回読みの
 *   on-demand で、poll の変化差分とは意味が違う)。
 */
export function statusBodyTmux({ pane, screen, source, permissionMode }) {
  return { route: "tmux", pane, ...screen, source, permissionMode };
}

/**
 * 同・ワーカー経路。`manager.status()` の形をそのまま運び、`permissionMode` だけ足す
 * (tmux 側との差はこの1鍵 + `pane`/`source` の有無)。
 */
export function statusBodyWorker({ worker, permissionMode }) {
  return { route: "worker", ...worker, permissionMode };
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
 * `GET /api/sessions/<id>/history?q=<語>` の封筒(2026-09-01 に切り出し)。
 *
 * 切り出した理由は `test/wire-key-agreement.test.mjs` が「**実行して出た鍵**」を側Aとして
 * 取る為で、`src/server.mjs` は import した瞬間に listen するので単体から呼べない =
 * 直書きの分岐は鍵名を突き合わせる者が構造的に存在しない。新設した
 * `TranscriptSearchResponse` の鍵を、生まれた日から無監視にしない為に此処へ出す。
 *
 * ★★**振る舞いは変わる。1 つだけ、意図的に。**(2026-09-01)
 *   最初 此処に「振る舞いの変更はゼロ」と書いた。**偽だった** —— 実機の机
 *   (friday:9443)へ GET を撃って判った。旧のハンドラは `history: r.history` と
 *   **生のまま**返しており、`.map(withWho)` を通していなかった。実測:
 *     探索の 1 件 = `{"role":"assistant","text":"…"}`          ← `display` が無い
 *     素の履歴の 1 件 = `{"role":"assistant","text":"…","display":{"who":"Claude"}}`
 *   電話の `HistoryEntry.display` は**非 optional** なので、`display` を欠く項目は
 *   復号ごと落ちる = 実機で探索すると必ず
 *   「The desk's answer wasn't in a form this app can read.」になる。
 *   **機能は出荷前から 100% 壊れていた**。
 *   ★之を捕まえた者が木の中に 1 人も居ない理由まで書く: fixture も、私が書いた
 *     検体 body も、全部 `display` を入れて組んである。**検体は自分が知っている形しか
 *     名乗らない** —— 実機を撃つまで、誰も「机が本当に何を吐くか」を見ていなかった。
 *   だから此の builder は `.map(withWho)` を通す(素の履歴と同じ 1 本の道)。
 *   守り: `test/e2e-local.mjs` の「探索の項目も `display.who` を持つ」。
 *
 * ★`truncated` と `searchedToStart` が**同じ事実の裏表**で並ぶのは意図。
 *   `truncated` = 「これより前が在る」という素の履歴の語彙で、探索では
 *   「最初まで見ていない」が其れに当たる。出荷済みの電話が `truncated` を読むので
 *   消せず、新しい電話は `searchedToStart` だけを読む(`truncated` は復号しない)。
 *   ★**電話が読まない鍵は、机側の扉でしか守れない** —— 2 つが逆を向いていない事は
 *     `test/e2e-local.mjs` の `truncated === !searchedToStart` が実サーバへ HTTP を
 *     撃って測る。関数の扉にも Swift の扉にも、之を赤くする手は無い。
 */
export function historySearchBody({ entries, matched, reachedStart }) {
  return {
    history: entries.map(withWho),
    matched,
    truncated: !reachedStart,
    searchedToStart: reachedStart,
  };
}

/**
 * 補完の候補1件(2026-09-02)。**2鍵しか無いのが要点。**
 *
 * ★大きさ・時刻・権限・絶対 path を足さない。電話が要るのは「入力欄へ差す文字列」と
 *   「其れが dir なら続けて降りられる」の2つだけで、他は会話の作業場所の中身を
 *   認証の外へ運ぶ材料にしかならない(`attachBody` が絶対 path の欄を持たないのと同じ判断)。
 * ★`path` は cwd からの**相対**。絶対にすると机の置き場が API に固まる。
 */
export function pathItem(p) {
  return { path: p.path, kind: p.kind };
}

/**
 * `GET /api/sessions/<id>/paths?q=<語>` の封筒(2026-09-02)。
 *
 * ★`reason` は**当たっていない時も `null` で載せる**。`gapItem` の `seq` の様に
 *   「無い時は鍵ごと生やさない」形にしなかったのは、此処の `reason` が
 *   **成功と失敗の両方で電話が読む欄**だから —— 鍵の有無で分岐させると、
 *   電話側は「鍵が無い」と「`null`」を区別できる形で書く事になり、区別に意味が無い所に
 *   区別が生まれる。`attachBody` の `injectReason` と同じ形(載った時は `null`)。
 *
 * ★`truncated` = 上限に当たって**途中で止めた**。除外した dir(`node_modules` 等)や、
 *   問いが空の時に直下だけを返す事は打ち切りではない —— あれは範囲の定義であって
 *   予算の枯渇ではない。混ぜると此の鍵は常に真になり、電話の「…」が意味を失う。
 *   正本は `src/paths.mjs` の `completePaths`。
 */
export function pathsBody({ entries, truncated, reason }) {
  return {
    paths: entries.map(pathItem),
    truncated,
    reason: reason ?? null,
  };
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
export function accountBody(parsed, { raw = "", usageByEmail = null, usageAgeSeconds = null } = {}) {
  const ok = parsed.parseStatus === "ok";
  return {
    account: parsed.current ?? "（未設定）", // 出荷済みの版が読む1行。中身は現用名だけ
    current: parsed.current,
    accounts: parsed.accounts.map((a) => accountRow(parsed, a, usageByEmail)),
    ok,
    parseStatus: parsed.parseStatus,
    anomalies: parsed.anomalies,
    // 使用量の観測の齢(秒)。null = この机はまだ一度も測れていない。電話は齢が古い時に
    // 「古い」と言えるが、数字を捨てる判断はしない(1時間前の率でも無いよりは判断材料)。
    usageAgeSeconds,
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
export function accountRow(parsed, a, usageByEmail = null) {
  const problem = selectionProblem(parsed, a.name);
  const u = usageByEmail ? usageByEmail[a.name] : null;
  return {
    name: a.name,
    hasToken: a.hasToken,
    active: a.active,
    selectable: problem === null,
    display: { blocked: problem === null ? null : selectionMessage(problem) },
    // 残量(cswap の観測、無ければ null = 「測れていない」。0 と混ぜない — DESIGN の
    // 「読めなかったと本当に0は別」の口座版)。中身の形は accountUsage が正本。
    usage: u ? accountUsage(u) : null,
  };
}

/**
 * 口座1つぶんの使用量(2026-08-29、CodexBar と同じ真実を電話へ)。
 *
 * ★pct は**使用率**。残りは電話が 100 - pct で描く。
 * ★`weeklyResetsIn` は cswap が作った文字列("20h 50m")をそのまま運ぶ —
 *   期限の文言を電話で組み立て直すと語彙が2箇所に分かれる(display と同じ判断)。
 */
export function accountUsage(u) {
  return {
    usageStatus: u.usageStatus ?? null,
    sessionUsedPct: u.sessionUsedPct ?? null,
    weeklyUsedPct: u.weeklyUsedPct ?? null,
    weeklyResetsIn: u.weeklyResetsIn ?? null,
    willLastToReset: u.willLastToReset ?? null,
  };
}

/**
 * `POST /api/sessions/<id>/attach` の封筒。2026-08-26。
 *
 * ★ハンドラの中に literal で書かない。書くと鍵名を**実行して測れない**ので、
 *   電話の `Decodable` と突き合わせられない(監査 S8-25 と同じ判断)。
 *   実際、突き合わせの検査は「新しい Decodable 型がどちらの箱にも入っていない」で
 *   これを掴んだ —— 逃がすのではなく、測れる形にするのが正しい直し方。
 *
 * ★**絶対パスの欄を持たない。** 置き場は API に出さない(出すと動かせなくなる)。
 * ★`injected` を `stored` と分けて持つ。「置けた」と「入力欄に載った」は別の事実で、
 *   混ぜると、机に窓が無い時に「送れました」と言って利用者を入力欄の前で迷わせる。
 */
export function attachBody(stored, injected, injectReason, swept) {
  return {
    attachmentId: stored.id,
    bytes: stored.bytes,
    format: stored.format,
    converted: stored.converted,
    injected,
    // 載らなかった理由。載った時は null(空文字にしない —— 空文字は「理由が在るが空」に読める)
    injectReason: injected ? null : (injectReason ?? "unknown"),
    swept,
  };
}

/**
 * `GET /api/sessions/<id>/diff` の封筒(2026-09-02、対照表 #4)。
 *
 * 中身を作るのは `src/sessiondiff.mjs`。此処が持つのは**鍵名だけ** ——
 * 其れが此の file の役目で、電話の `Decodable` と突き合わせられる唯一の場所。
 *
 * ★`reason` は成功でも `null` で**必ず載せる**。欄ごと消すと、電話は
 *   「差分が無い」と「読めなかった」を本文の形で見分ける事になり、
 *   其の判定が机と電話の 2 箇所に増える。
 * ★`truncated` と `totalBytes` は**対**で読む。切った事(真偽)と、切る前に
 *   どれだけ在ったか(数)。片方だけだと「全部出ているのか」に答えられない。
 *   ★git の出力が器(`maxBuffer`)から溢れた時だけ、`totalBytes` は**読めた分** = 下限
 *     (2026-09-03、Codex #1 の 6)。其の時も `added` / `removed` は `--numstat` で取り直した
 *     正確な数(`sessiondiff.mjs` の註)。
 * ★`added` / `removed` は**切る前の全文から**数えた値(`capFiles` の註)。
 *   本文が途中で止まっても数は正しい = 電話は「+42 -18(表示は途中まで)」と言える。
 *
 * ★#5(一覧の ± バッジ、`sessionRow` の `diff` 引数)とは**別の型**。あちらは
 *   `{files, added, removed}` の**数**だけを一覧の全会話ぶん同期で持つ(`gitdiff.mjs`
 *   の `makeDiffCache`)。此方は**1 会話を開いた時だけ**、hunks の中身まで運ぶ。
 *   両方が同じ `git diff --shortstat` 相当を二重に撃たない様、此の関数は
 *   `src/sessiondiff.mjs`(`readWorkingDiff`)としか組まない。
 */
export function diffBody({ files, truncated, totalBytes, reason }) {
  return {
    files: (files ?? []).map((f) => ({
      path: f.path,
      // index の側か。同じ path が 2 行出る事が在る(stage 済みの変更に、
      // さらに手が入っている作業木)。其の 2 行を見分ける唯一の欄。
      staged: f.staged,
      binary: f.binary,
      added: f.added,
      removed: f.removed,
      // 此の file の本文だけが切られたか(全体の `truncated` とは別の事実)。
      truncated: f.truncated,
      hunks: (f.hunks ?? []).map((h) => ({
        header: h.header,
        lines: (h.lines ?? []).map((l) => ({ kind: l.kind, text: l.text })),
      })),
    })),
    truncated,
    totalBytes,
    reason: reason ?? null,
  };
}
