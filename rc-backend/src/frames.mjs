// SSE の枠組みを解く純関数層 — **ブラウザと node の両方が同じ物を import する**。
//
// なぜ `EventSource` を使わないか(DESIGN §2.13): 認証が `Authorization: Bearer` のみで、
// `EventSource` はヘッダを打てない。`fetch()` の本体を自分で読む形にすると、
// 枠組み(`id:` / `event:` / `data:` / 空行で1件)を自分で解く事になる。
//
// ★この module は node の API を一切 import しない。だから
//   - ブラウザは `<script type="module">` から `/frames.mjs` として読む
//   - 単体検査は同じファイルを `import` して回す
// が成立する。サーバに埋めると変異検査が掴めない(§2-E の `resumeDecision` と同じ理由)。
//
// 規約は WHATWG の event stream の解釈に合わせる。**自分で簡略化しない**:
// 電話の回線は途中で切れるので、フィールドの途中・行の途中・フレームの途中の
// どこで切れても正しく繋がる事がこの層の唯一の仕事。

/**
 * 逐次パーサ。`push(text)` を呼ぶたび、その時点で**完成した**イベントだけを返す。
 * 未完成の分は内部に残り、次の `push` と繋がる。
 */
export function createSseParser() {
  let buf = "";        // まだ行に切れていない断片
  let dataLines = [];  // 今組み立て中のフレームの data 行
  let eventType = "";  // 同 event 名
  let lastEventId = ""; // ★フレームを跨いで保持する(仕様)。data 無しのフレームでも更新される

  const parser = {
    get lastEventId() {
      return lastEventId;
    },

    push(text) {
      buf += text;
      const out = [];
      // 行の切れ目は LF / CRLF / CR の3種。**CR だけ**の物が末尾に来た時は、
      // 次が LF かもしれないので確定させない(CRLF が2行に割れる)。
      for (;;) {
        const m = /\r\n|\n|\r/.exec(buf);
        if (!m) break;
        // 代償: **CR だけで区切るサーバの最後のフレームは、続きが来るまで出ない**。
        // 接続が閉じた時点の未完成フレームは捨てる、が仕様なのでこれで正しい。
        // 我々のサーバは LF しか出さないので実害は無い(frames.test.mjs の同名の検査)。
        if (m[0] === "\r" && m.index === buf.length - 1) break; // 次の push を待つ
        const line = buf.slice(0, m.index);
        buf = buf.slice(m.index + m[0].length);
        const ev = feedLine(line);
        if (ev) out.push(ev);
      }
      return out;
    },
  };

  function feedLine(line) {
    if (line === "") return dispatch();
    if (line.startsWith(":")) return null; // コメント(サーバの `: ping`)
    const i = line.indexOf(":");
    const field = i < 0 ? line : line.slice(0, i);
    let value = i < 0 ? "" : line.slice(i + 1);
    if (value.startsWith(" ")) value = value.slice(1); // 先頭の空白は**1つだけ**剥がす
    if (field === "data") dataLines.push(value);
    else if (field === "event") eventType = value;
    else if (field === "id") {
      // NUL を含む id は無視する(仕様)。我々のサーバは出さないが、
      // 「見た事のない物が来たら黙って採用する」を作らない。
      if (!value.includes("\u0000")) lastEventId = value;
    }
    // retry: は使わない(再接続の間隔は電話側の方針で決める。DESIGN §2.13)
    return null;
  }

  function dispatch() {
    const hadData = dataLines.length > 0;
    const type = eventType || "message";
    const data = dataLines.join("\n");
    dataLines = [];
    eventType = "";
    // data が1行も無いフレームは配信しない(仕様)。ただし id は既に更新済み =
    // 「id だけ送って中身は無い」でも追いつきの位置は進む。
    if (!hadData) return null;
    return { type, data, lastEventId };
  }

  return parser;
}

/**
 * サーバが載せてくる `data` は必ず JSON。壊れていたら**捨てずに印を返す**。
 * 電話の画面で「何か来たが読めない」と「何も来ない」は意味が違う。
 */
export function decodeEvent(ev) {
  try {
    return { type: ev.type, id: ev.lastEventId, body: JSON.parse(ev.data), ok: true };
  } catch {
    return { type: ev.type, id: ev.lastEventId, body: null, ok: false, raw: ev.data };
  }
}

/**
 * 再接続の待ち時間。切れた回数から決める(1s → 2s → 4s → 8s → 15s で頭打ち)。
 * 純関数にしてあるのは、**「上限がある」を検査で押さえる為**。
 * 地下鉄で 30 分切れ続けても待ち時間が発散しない事が要件(user_work_pattern_mobile)。
 */
export function backoffMs(attempt) {
  if (attempt <= 0) return 0;
  return Math.min(15_000, 1000 * 2 ** (attempt - 1));
}
