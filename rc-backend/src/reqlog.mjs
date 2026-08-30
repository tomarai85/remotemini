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
// ★action は**白名簿**(2026-08-16 に title / archive / return-request を追加)。
// 追加を忘れると handler が在っても**到達不能**になる — 実際に其の状態で3本を
// 出荷しかけ、Codex の敵対レビューが掴んだ(静的検査は字面の存在しか見ないので素通り)。
// 検体 = test/title-route.test.mjs の「到達できる」検査(regex に当てて実測する)。
export const SESSION_ROUTE_RE = /^\/api\/sessions\/([^/]+)\/(history|messages|stream|poll|interrupt|status|choice|queue|title|archive|return-request|digest|attach)$/;

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
/**
 * 要求を出した**種類**だけを返す(2026-08-27 新設)。閉じた4語しか返さない。
 *
 * ★なぜ要るか(実測 2026-08-27): この記録は「誰が叩いたか」を一切残していなかった。
 *   その為「Tom はこのアプリを開いたのか」に答えるのに、私は自分の作業記録との
 *   時刻突き合わせを 6 回やる羽目になった —— しかも **Simulator と実機を最後まで
 *   区別できなかった**。答えが要る問いに、記録が答えられない状態だった。
 *
 * ★**生の User-Agent は決して記録しない。** あれには端末の型番と OS の版が入る。
 *   §3-U の「行に中身が乗らない」は、本文やパスだけでなく端末の指紋にも掛かる。
 *   だから分類器は**閉じた語**を返し、呼び出し側は返り値しか書かない。
 *
 *   app   iOS の URLSession(実機でも Simulator でも CFNetwork を名乗る)
 *   tool  curl / node など —— この機体の常駐(digest-notify・health-observer)がこれ
 *   none  名乗りが無い
 *   other 上のどれでもない
 */
export function clientClass(userAgent) {
  const ua = String(userAgent || "");
  if (!ua) return "none";
  // ★検査道具を **app より先に**外す(2026-08-27)。
  //   `ios/tools/live-*-check.sh` が建てる殻は**電話の製品 Swift をそのまま**使うので、
  //   URLSession が `CFNetwork/… Darwin/…` を名乗る = 下の分岐で `app` に落ちる。
  //   それを許すと「私がビルドしていない時間帯に app が出たら、それが Tom」という
  //   **この計器の唯一の読み方が壊れる** —— 実際に今日壊した(自分の検査 20 件が
  //   `client=app` として記録され、Tom が使ったのかを区別できなくなった)。
  //   分ける鍵は UA の頭に出る**実行ファイル名**(実測: `rc-live-poll (unknown version)
  //   CFNetwork/3860.600.21 Darwin/25.5.0`)。製品は `RemoteMini/<番号>` を名乗るので衝突しない。
  if (/^rc-live-/i.test(ua)) return "probe";
  // ★app を先に見る。curl は Darwin を名乗らないので取り違えない。
  if (/CFNetwork|Darwin/i.test(ua)) return "app";
  if (/curl|wget|node|undici|python|libwww/i.test(ua)) return "tool";
  return "other";
}

/**
 * 製品アプリの build 番号だけを取り出す。**閉じた形しか返さない**(数字か `-`)。
 *
 * ★なぜ要るか(2026-08-30): `client=app` は「電話から来た」までしか言わない。
 *   実際 2026-08-30 に、配布口が build 89 を配り Tom の電話が 96 を動かし HEAD が 99、
 *   という**3つの版が同時に存在する**状態を2日間誰も気付かなかった。
 *   記録に版が無いと、後から「その要求はどの版から来たか」を誰も答えられない。
 *
 * ★**生の User-Agent は決して記録しない**(上の §3-U と同じ線)。UA には端末の型番と
 *   OS の版が入る。だから此処は**数字だけ**を通す —— 返り値が閉じているので、
 *   呼び出し側がどう書いても UA の断片が行に出る道が無い。
 *   長さも縛る(9 桁まで): 「数字なら何でも通す」だと、細工した UA で行を膨らませられる。
 *
 * ★頭に錨を打つ(`^RemoteMini/`)。`clientClass` が `rc-live-` を頭で外しているのと同じ理由で、
 *   URLSession の名乗りは**実行ファイル名から始まる**。検査用の殻(`rc-live-poll …`)や
 *   `curl/8.4.0` は此処に当たらないので `-` に落ちる。
 */
export function appBuild(userAgent) {
  const m = /^RemoteMini\/(\d{1,9})(?:\s|$)/.exec(String(userAgent || ""));
  return m ? m[1] : "-";
}

/**
 * 電話が**自分で名乗った**版(`X-App-Build`)。読めなければ `"-"`。
 *
 * ★`appBuild()` と分ける理由: あちらは `RemoteMini/<n> CFNetwork/...` という
 *   **iOS が既定で組み立てる** UA の形を読む。こちらは素の数字1つ。
 *   同じ関数に両方を通そうとすると、片方の形が緩んだ時にもう片方も緩む。
 * ★全桁が数字の物だけ通す。ヘッダは誰でも書けるので、`"96abc"` から 96 を作らない
 *   (`parseInt` の前方一致で実際に踏んだ罠。`wire.mjs` の `updateNotice` と同じ判断)。
 */
export function headerBuild(value) {
  const v = String(value ?? "").trim();
  return /^\d{1,9}$/.test(v) ? v : "-";
}

export function attachRequestLog(req, res, opt = {}) {
  const out = opt.out || ((line) => console.log(line));
  const now = opt.now || (() => new Date());
  const t0 = Date.now();
  // 生のパスはここで**型に畳んでから**しか使わない。`?` から後ろは見ない。
  const rawPath = String(req.url || "").split("?")[0];
  const shape = pathShape(rawPath, opt.knownPaths);
  const sid = sessionOf(rawPath);
  const method = methodOf(req.method);
  // ★分類は要求ごとに1回。生の名乗りはこの行から先へ**出さない**。
  const client = clientClass((req.headers || {})["user-agent"]);
  // ★同じ header を2回読むが、**どちらも閉じた語しか返さない**ので生の名乗りは
  //   此の2行から先へ出ない。
  const build = appBuild((req.headers || {})["user-agent"]);

  const st = { route: "", reason: "", emitted: false };
  res[LOG] = st;

  const emit = (code, why) => {
    if (st.emitted) return;
    st.emitted = true;
    const reason = why || st.reason || "-";
    out(
      `[rc-backend] req ${now().toISOString()} ${method} ${shape}` +
        `${sid ? ` sid=${sid}` : ""} route=${st.route || "-"} client=${client} build=${build} code=${code} reason=${reason} ms=${Date.now() - t0}`,
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
