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
import { paneFaultView } from "./blocked.mjs";
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
export function sessionRow(row, live) {
  return { ...row, live, display: { route: routeLabel(live), subtitle: subtitleOf(row) } };
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
