/**
 * 常設のログに **1リクエスト1行**(DESIGN §3-U)。
 *
 * ★なぜ足すか: 2026-08-03 時点の `~/Library/Logs/rc-backend/rc-backend.log`(7.4 KB)は
 *   **起動行しか無い**。送信も割り込みも経路の分岐も拒否も、1件も残っていない。
 *   §3-W はまさにこれで刺さった —— ワーカー経路が `202 accepted` を返した直後に死に、
 *   唯一の診断行は捨てられ、壊れたまま出荷されて**誰も気づけなかった**。
 *   ログが無い事は不便ではなく、**欠陥が発見されない条件そのもの**。
 *
 * ★★書かない物(こちらが本体。足す物より厳しく決める):
 *   - **本文 / プロンプト / 会話の中身** —— 電話に見える物をログへ複製しない。
 *   - **生のパス** —— パスは外から来る任意の文字列。表に在る形に当たった時だけその形を出し、
 *     当たらなければ `(other)`。「知らない物は出さない」= fail-closed。
 *   - **問い合わせ文字列**(`?…`)—— 丸ごと捨てる。
 *   - **自由文の理由** —— `reason` は語彙(小文字+数字+ハイフン、24字まで)に当たった物だけ。
 *     当たらなければ `-`。
 *   - **§3-W が足す stderr の尾**(DESIGN §2.21-b)—— 画面に出るだけの物を disk に残さない。
 *   - `sessionId` は**先頭8文字だけ**。
 *
 * ★`src/redact.mjs` との違い(混同すると片方の設計が壊れる):
 *   redact は**拒否一覧**。自由書式の stderr を Tom の電話へ出す為の網で、知っている形しか
 *   捕まえられない事を明記した上で緩い側に倒してある。ここは逆に**許可一覧**にできる ——
 *   出す欄も語彙も此方が決める側だから。自由書式を通す口を1つも作らないのが要点で、
 *   だから「読めない値は `-` にする」であって「伏せ字にして出す」ではない。
 */

/**
 * 会話に紐づく道。`:id` は伏せ、動作名だけ残す。
 *
 * ★**server.mjs の振り分けもこれを使う**(写しを持たない)。最初は各々が同じ正規表現を
 *   持つ形にしかけたが、それは此処で何度も踏んだ型 —— 道を1本足した時に片方だけが古くなり、
 *   ログは新しい道を `(other)` と書き続ける。しかも**ログが静かなだけ**なので誰も気づかない。
 *   一覧は1箇所に集める。置き場を此処にしたのは「パスの型」を決める責任が此処だから。
 */
export const SESSION_ROUTE_RE = /^\/api\/sessions\/([^/]+)\/(history|messages|stream|interrupt|status|choice)$/;

/**
 * 語彙 = 小文字で始まり、小文字/数字/ハイフン/下線だけ、24字まで。
 *
 * ★下線を許すのは飾りではない: 実物の理由は `cwd_unknown` / `cwd_missing` / `cwd_untrusted` /
 *   `spawn_failed`(trust.mjs / server.mjs)と `pane-gone` / `composer-mismatch`(blocked.mjs)が
 *   **綴りを分けて**混在している。下線を弾いた初版は、e2e の実物のログで
 *   `route=worker code=409 reason=-` を出した —— 拒否の理由が定数として在るのに欄が空、
 *   つまり**一番読みたい行だけが黙る**形。緩めても網は緩まない(空白も `:` も依然弾く)。
 *   出す時はハイフンに寄せる。ログの中で同じ物が2通りに綴られると grep が二度要る。
 */
const TOKEN = /^[a-z][a-z0-9_-]{0,23}$/;

/** 記録の置き場。`res` に生の名前で生やすと将来 node 側の property と衝突しうる。 */
export const LOG = Symbol("rc-reqlog");

/**
 * パスの**型**。表に在る物はそのまま、会話の道は `:id` に畳む、それ以外は `(other)`。
 * @param {string} path 生のパス(`?` より前)
 * @param {Set<string>} [known] 表に在るパス(server.mjs が配る表 + 固定の api から作る)
 */
export function pathShape(path, known) {
  if (known && known.has(path)) return path;
  const m = SESSION_ROUTE_RE.exec(path);
  if (m) return `/api/sessions/:id/${m[2]}`;
  return "(other)";
}

/** 会話の道なら sessionId の**先頭8文字**。それ以外は空。 */
export function sessionOf(path) {
  const m = SESSION_ROUTE_RE.exec(path);
  return m ? m[1].slice(0, 8) : "";
}

/** 語彙に当たれば返す(下線はハイフンに寄せる)。当たらなければ空(= 行では `-`)。 */
export function token(v) {
  if (typeof v !== "string") return "";
  const s = v.trim().toLowerCase();
  return TOKEN.test(s) ? s.replace(/_/g, "-") : "";
}

/**
 * `error` の**定数**だけを語彙へ寄せる。`bad body: <構文解析器の言い分>` の様に
 * 外来の文字が混じった物は `:` や `"` で弾かれて空になる —— それが正しい。
 * 40字を超える物も空。長い error は説明であって語彙ではない。
 */
export function errSlug(v) {
  if (typeof v !== "string" || v.length > 40) return "";
  if (!/^[A-Za-z0-9 _-]+$/.test(v)) return "";
  const s = v.trim().toLowerCase().replace(/[ _]+/g, "-");
  return TOKEN.test(s) ? s : "";
}

/** method も外から来る。表に在る形だけ出す。 */
function methodOf(m) {
  return /^[A-Z]{3,10}$/.test(String(m || "")) ? String(m) : "(other)";
}

/**
 * 枝が**自分で**名乗る。応答の中身から拾えない物(経路の判定が本文に出ない場合)と、
 * 拾わせたくない物(500 の生の例外文)の為に在る。先に名乗った方が勝つ。
 */
export function markResult(res, fields) {
  const st = res && res[LOG];
  if (!st || st.emitted || !fields) return;
  if (!st.route) st.route = token(fields.route);
  if (!st.reason) st.reason = token(fields.reason);
}

/**
 * `json()` から呼ぶ。本文の `route` / `reason` / `error` は**この repo の定数**なので
 * 語彙に当たる。当たらない物(自由文)は落ちて `-` になる = 中身が漏れない。
 */
export function noteBody(res, obj) {
  const st = res && res[LOG];
  if (!st || st.emitted || !obj || typeof obj !== "object") return;
  if (!st.route) st.route = token(obj.route);
  if (!st.reason) st.reason = token(obj.reason) || errSlug(obj.error);
}

/**
 * 1リクエスト1行を仕掛ける。`createServer` の handler の**最初**で呼ぶ(try の外)。
 *
 * ★行が出る合図は `writeHead`。`finish` ではない —— SSE は何分も開いたままなので、
 *   終わりで書くと「電話が繋がった」が**繋がっている間ずっとログに出ない**。
 *   その代わり、頭を書く前に落ちた要求(電話が切った等)は `close` で拾って `aborted` にする。
 *   ★`writeHead` の時点で全部の欄が決まっている事が要る。ストリームの経路判定を
 *   `writeHead` の**前**へ動かしたのはこの為(server.mjs の `action === "stream"`)。
 *
 * @param {import("node:http").IncomingMessage} req
 * @param {import("node:http").ServerResponse} res
 * @param {{knownPaths?: Set<string>, out?: (line: string) => void, now?: () => Date}} [opt]
 */
export function attachRequestLog(req, res, opt = {}) {
  const out = opt.out || ((line) => console.log(line));
  const now = opt.now || (() => new Date());
  const t0 = Date.now();
  // 生のパスはここで**型に畳んでから**しか使わない。`?` から後ろは見ない。
  const rawPath = String(req.url || "").split("?")[0];
  const shape = pathShape(rawPath, opt.knownPaths);
  const sid = sessionOf(rawPath);
  const method = methodOf(req.method);

  const st = { route: "", reason: "", emitted: false };
  res[LOG] = st;

  const emit = (code, why) => {
    if (st.emitted) return;
    st.emitted = true;
    const reason = why || st.reason || "-";
    out(
      `[rc-backend] req ${now().toISOString()} ${method} ${shape}` +
        `${sid ? ` sid=${sid}` : ""} route=${st.route || "-"} code=${code} reason=${reason} ms=${Date.now() - t0}`,
    );
  };

  const orig = res.writeHead.bind(res);
  res.writeHead = (code, ...rest) => {
    const r = orig(code, ...rest);
    emit(code);
    return r;
  };
  // 頭を書く前に切れた = 応答を1つも返していない。`code=0` は「答えていない」の意。
  res.on("close", () => emit(0, "aborted"));
  return st;
}
