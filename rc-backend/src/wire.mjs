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
import { routeLabel, scanLine, subtitleOf } from "./view.mjs";

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
