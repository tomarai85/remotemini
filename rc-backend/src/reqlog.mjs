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
// ★`new` は 2026-09-03 に足した。handler(`action === "new"`、cf41905 で 2026-08-31 に新設)は在ったのに
//   此の表に無く、電話の「New session here」は机で **404 `NO_SUCH_ROUTE`** になっていた —— 上の註が
//   警告している形そのもの。e2e が `/new` を一度も叩いていなかったので誰も気付かなかった
//   (roots の口の e2e を足した時に `会話の道の cwd 付き` が 404 で赤になって発覚)。
// ★`attach-file` は 2026-09-03(行 #23「非画像の添付」)に足した。`attach`(画像)の隣に
//   handler を置いただけでは此処に載らず、上と同じ形で永久に 404 になる —— この表が
//   handler の到達性を決める唯一の場所である事を、足す度に自分で踏んで確かめている。
export const SESSION_ROUTE_RE = /^\/api\/sessions\/([^/]+)\/(history|messages|stream|poll|interrupt|status|choice|queue|title|archive|return-request|digest|attach|attach-file|diff|paths|new)$/;

/**
 * roots の道(2026-09-03、対照表 #11)。会話に**紐づかない** 2 本 = `/api/roots/<i>/paths` と
 * `/api/roots/<i>/new`。`<i>` は台帳の index(3 桁まで = 台帳は 32 行以内なので余裕を持って)。
 * 固定の `/api/roots`(一覧)は regex ではなく server.mjs の `LOG_PATHS` に居る。
 * ★此処が唯一の写し。server.mjs は此の regex を import して使い、自分では持たない
 *   (`SESSION_ROUTE_RE` と同じ規約。検査 = test/reqlog.test.mjs)。
 */
export const ROOTS_ROUTE_RE = /^\/api\/roots\/(\d{1,3})\/(paths|new)$/;

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
  const r = ROOTS_ROUTE_RE.exec(path);
  if (r) return `/api/roots/:i/${r[2]}`;
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
 *   control 私が焼いた検査用の殻(自分で `X-RC-Role: control` を名乗る)
 *   app   iOS の URLSession(実機でも Simulator でも CFNetwork を名乗る)
 *
 * ★★`app` は**上限**であって「Tom 本人」ではない(2026-08-30、Codex の指摘3)。
 *   役を付けても曖昧さは消えず、移動しただけ:
 *     control = たぶん私の、印を付けた殻
 *     app     = Tom **または** 印を付け損ねた私の実機ビルド **または** 同じ UA の何か
 *   使える非対称: **不在は強い陰性証拠**(app が1件も無ければ誰も来ていない ——
 *   CF-17 の「栞は一度も叩かれていない」は此の向きで、生き残る)。
 *   **存在は本人の行為を証明しない**。誰が押したかを言うには、認証された口座か
 *   机が発行した設置 ID か、行為ごとの事象 ID が要る。UA と印の組み合わせは
 *   背景の雑音を掃けるだけで、行為者を立証しない。★此の一行を消すと、
 *   次に読む人が `app` の件数を「Tom の使用回数」として読む。
 *   tool  curl / node など —— この機体の常駐(digest-notify・health-observer)がこれ
 *   none  名乗りが無い
 *   other 上のどれでもない
 */
export function clientClass(userAgent, headers = {}) {
  const ua = String(userAgent || "");
  // ★**自分で名乗った役**を最優先で見る(2026-08-30)。
  //   `rc-live-*` の殻は実行ファイル名で外せたが、`ios/tools/build.sh` が焼く殻は
  //   **製品の Swift をそのまま**使うので `RemoteMini/<番号> CFNetwork/…` を名乗り、
  //   UA からは Tom の実機と1文字も違わない。実測(H-3 訂正、同日): 述べ 593 件のうち
  //   `build=1` の 60 件が私の対照で、`build=96` の 36 件だけが Tom だった ——
  //   **版番号で人を判じていた**ので、彼が古い版に留まる日(= 普段)には壊れる。
  //   版は人ではない。名乗る側が名乗る。
  //   ★之は**認証ではない**。詐称できるが、詐称して得をするのは自分の計器を汚す事だけ。
  //     守っているのは「Tom が使ったか」を後から読める事であって、権限では無い。
  const role = String((headers || {})["x-rc-role"] || "").trim().toLowerCase();
  if (role === "control") return "control";
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

/*
 * ── 削除: `appBuild(userAgent)`(2026-08-31)───────────────────────────────
 * 「製品アプリの build 番号を User-Agent から取り出す」関数が此処に在った。
 * **UA は build 番号を運んでいない**。iOS が既定で組み立てる名乗りは
 * `<実行ファイル名>/<CFBundleShortVersionString> CFNetwork/… Darwin/…` で、
 * 運ぶのは**売り物の版**(此の app では `0.1`)であって `CFBundleVersion` ではない。
 *
 * 実測(2026-08-31): 手元の実物が 短版 `0.1` / build `106`。friday の要求ログに在る
 * `client=app` の 861 本は**全部 `build=1`** —— 電話に入っている古い版の短版が `1` だった、
 * というだけの数字で、build 番号ではない。つまり此の欄が在る理由
 * (「其の要求はどの版から来たか」を後から答える)を、欄の中身が丸ごと裏切っていた。
 *
 * 消したのであって置き換えたのではない: 名乗らない版の build 番号は**判らない**。
 * 判らない物は `-` と書く。近い数字で埋めない —— 埋めた数字は必ず誰かが引き算に使う
 * (実際、`delivery-check.sh` を直す時に「1 は 105 より 104 古い」と書きかけた)。
 * 正しい入口は電話が名乗る `X-App-Build`(下の `headerBuild`)だけ。
 */

/**
 * 電話が**自分で名乗った**版(`X-App-Build`)。読めなければ `"-"`。
 * **版を答えられる唯一の入口**(上の削除の註を見よ)。
 *
 * ★全桁が数字の物だけ通す。ヘッダは誰でも書けるので、`"96abc"` から 96 を作らない
 *   (`parseInt` の前方一致で実際に踏んだ罠。`wire.mjs` の `updateNotice` と同じ判断)。
 * ★長さも縛る(9 桁まで): 「数字なら何でも通す」だと、細工した値で行を膨らませられる。
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
  const client = clientClass((req.headers || {})["user-agent"], req.headers || {});
  // ★版は**電話が名乗った物だけ**を採る(2026-08-31)。08-30 まで此処は UA を読んでいたが、
  //   UA が運ぶのは売り物の版であって build 番号ではない(上の削除の註)。
  //   名乗らない版の build は判らないので `-` = 「判らない」と書く。近い数字で埋めない。
  const build = headerBuild((req.headers || {})["x-app-build"]);

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
