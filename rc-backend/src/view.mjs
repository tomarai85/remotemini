// 電話の画面が使う純関数層 — **判断は全部ここに置き、HTML は貼るだけにする**。
//
// なぜ切り出すか(2026-08-02): `app.html` の中に書いた判断は、変異検査も単体検査も
// 一切掴めない(§2-E の `resumeDecision` と同じ理由)。特にここに入るのは
//   - 履歴とライブの継ぎ目(重複を消す)
//   - 送信の応答を画面語にする表(§2.13。**成否を丸めない**のが仕様)
// の2つで、どちらも「間違っても緑のまま」になりうる種類の判断。
//
// ★node の API を import しない。ブラウザと単体検査が同じファイルを読む。

/**
 * 履歴(スナップショット)とライブ(流れてきた分)を繋ぐ。
 *
 * ★なぜ重複を消す形なのか: 電話は**先に `/stream` を開き、後から `/history` を撮る**。
 * 逆順(履歴 → 購読)にすると、その隙間に書かれた発言が**どちらにも入らない = 消える**。
 * 先に開けば同じ隙間は「両方に入る = 重なる」に変わる。消えるより重なる方が直せる。
 * ここはその重なりを、末尾と先頭の一致で剥がす層。
 *
 * 一致は (role, text) で見る。履歴側に id が無いので他に突き合わせる鍵が無い。
 * **同じ発言を2回した場合は剥がしすぎる**ことがある(下の検査に明記)。
 * 取りこぼしより重複、重複より剥がしすぎ、の順で害が小さいと判断した。
 */
export function mergeHistory(history, live) {
  const h = history || [];
  const l = live || [];
  const max = Math.min(h.length, l.length);
  for (let k = max; k > 0; k--) {
    const tail = h.slice(-k);
    let same = true;
    for (let i = 0; i < k; i++) {
      if (tail[i].role !== l[i].role || tail[i].text !== l[i].text) {
        same = false;
        break;
      }
    }
    if (same) return [...h, ...l.slice(k)];
  }
  return [...h, ...l];
}

/**
 * `POST /api/sessions/<id>/messages` の応答を画面語にする(DESIGN §2.13 の表)。
 *
 * ★丸めない: `unverified` を「送れませんでした」に潰さない。画面からは
 * (a) 本文が入力欄に残っている / (b) 入力欄が見えなくなった の区別が付かないので、
 * サーバが付けた `note` をそのまま出す。断定はサーバも私もしていない。
 *
 * @returns {{kind:"ok"|"warn"|"refused"|"error", text:string, keepText:boolean}}
 *   `keepText` = 入力欄の本文を残すか。**`warn` では残す**(2026-08-02 修正)。
 *   `unverified` は「届いたか分からない」であって成功ではない。欄を空にすると、
 *   届いていなかった場合に打った本文が復元不能になる。二重注入の危険は文面で明示して
 *   人に委ねる — 黙って本文を捨てる方が害が大きい(Codex も同判定)。
 *   ★空にするのは `ok` の時だけ。`app.html` はこの1つの値しか読まない。
 */
export function sendResult(status, body) {
  const b = body || {};
  if (status === 202) {
    if (b.delivered === "unverified") {
      const note = b.note || "送りましたが、取り込まれた事を確認できませんでした。";
      return {
        kind: "warn",
        // ★この一文だけは client が足す。入力欄の状態はサーバが知らないので、
        //   「残してある」と書けるのはここだけ(文面の出所を1つに保つ原則の例外理由)。
        text: `${note}本文は残してあります。送り直すと二重に入ることがあります。`,
        keepText: true,
      };
    }
    return {
      kind: "ok",
      text: b.route === "worker" ? "送った(ワーカー)" : "送った",
      keepText: false,
    };
  }
  if (status === 409) {
    return { kind: "refused", text: b.error || "送信を断られました。", keepText: true };
  }
  if (status === 400) {
    return { kind: "error", text: b.error || "送れない形でした。", keepText: true };
  }
  if (status === 401) {
    return { kind: "error", text: "鍵が通りませんでした。", keepText: true };
  }
  if (status >= 500) {
    // 「応答しませんでした(HTTP 500)」は自己矛盾。応答は来ている。
    return { kind: "error", text: `サーバ側で失敗しました(HTTP ${status})。`, keepText: true };
  }
  return { kind: "error", text: `想定していない応答でした(HTTP ${status})。`, keepText: true };
}

/**
 * `POST /api/sessions/<id>/interrupt` の応答を画面語にする。
 *
 * ★`send()` と同じく判断を HTML の中に置かない(2026-08-02 に `app.html` の中で
 * その場で文面を決めていたのを出した)。`interrupted:false` は失敗ではなく
 * 「止める対象が無かった」= 静かな会話に Escape を撃った時の正常な結果なので、
 * `error` に丸めない。
 *
 * @returns {{kind:"ok"|"warn"|"refused"|"error", text:string}}
 */
export function interruptResult(status, body) {
  const b = body || {};
  if (status === 200) {
    return b.interrupted
      ? { kind: "ok", text: "止めました(Escape)。" }
      : { kind: "warn", text: "止める対象がありませんでした。" };
  }
  if (status === 409) return { kind: "refused", text: b.error || "止められませんでした。" };
  if (status === 401) return { kind: "error", text: "鍵が通りませんでした。" };
  if (status >= 500) return { kind: "error", text: `サーバ側で失敗しました(HTTP ${status})。` };
  return { kind: "error", text: `想定していない応答でした(HTTP ${status})。` };
}

/** 一覧・会話の見出しに出す経路の印。 */
export function routeLabel(live) {
  const v = live || {};
  if (v.route === "tmux") {
    const work = v.work === "observed" ? "動いている" : v.activity === "observed" ? "動いている" : "静か";
    // ★上限は「静か」と見分けが付かないまま外出先で待たされる元(2026-08-02 edith 実測:
    //   4回送って4回とも上限、画面上は入力欄が空で静かなだけに見える)。
    //   これを言わないと、電話の側は「返事が遅い」と読んで待ち続ける。
    // ★★但し「上限の告知」は**過去形**、「動いている」は**現在形**(2026-08-02 に分けた)。
    //   同じ1枚に両方写る事が有りうる = 上限が解けた後、告知が履歴に残ったまま
    //   新しい返答が流れ始めた画面。そこで「答えは返りません」と言うと、
    //   **現に返っている最中の物を否定する**。電話の Tom は待つのをやめる =
    //   緩い判定を選んだ時に避けようとした偽陰性そのものを、表示側で作る事になる。
    //   よって**現在形の観測を見出しにして、告知は但し書きに落とす**。
    //   どちらの事実も画面から消さないので、この分岐は新しい死角を作らない。
    //   実測(8/02): `limit-reached-edith.txt` の告知行と `generating-spinner-visible.txt` を
    //   1枚に混ぜると `{state:"SENDABLE", activity:"observed", limited:true}` = 分類器は両方立てる。
    //   ★未観測: その並びの画面を edith で撮ってはいない(実物19枚では同時に立つのは0枚)。
    //     推論の根拠は「履歴は回転子より上に残る」という TUI の構造。撮れたら fixture にする。
    if (v.limited) {
      return work === "動いている"
        ? { kind: "tmux", text: "机で開いている・動いている(★画面に利用上限の告知が残っている)", screen: v.screen || "" }
        : { kind: "tmux", text: "机で開いている・★利用上限(答えは返りません)", screen: v.screen || "" };
    }
    return { kind: "tmux", text: `机で開いている・${work}`, screen: v.screen || "" };
  }
  if (v.route === "worker") {
    return { kind: "worker", text: v.state ? `ワーカー・${v.state}` : "ワーカー", screen: "" };
  }
  if (v.route === "blocked") {
    // サーバが文を付けてきたらそれが正(文面の出所は1つ = server.mjs の blockedMessage)。
    // 付いていない時だけ、ここの短い言い換えに落ちる。**理由コードを生で出さない**。
    return { kind: "blocked", text: v.message || BLOCKED_SHORT[v.reason] || "宛先を確定できません。", screen: "" };
  }
  return { kind: "unknown", text: "状態不明", screen: "" };
}

const BLOCKED_SHORT = {
  ambiguous: "同じフォルダで複数開いているため、宛先を確定できません。",
  unregistered: "ペイン登録が無いため、宛先を確定できません。",
  stale: "登録したペインを今は別の会話が使っています。",
  "cwd-mismatch": "登録ペインの現在地が一致しません。",
  "pane-gone": "開いていたペインが見つかりません。",
};

/**
 * 相対時刻。`updatedAt` は ISO 文字列。
 * ★`now` を引数で受けるのは、検査が時計に依存しない為(固定値を渡せる)。
 */
export function relTime(iso, nowMs) {
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "";
  const d = Math.floor((nowMs - t) / 1000);
  if (d < 0) return "たった今";
  if (d < 60) return "たった今";
  if (d < 3600) return `${Math.floor(d / 60)}分前`;
  if (d < 86400) return `${Math.floor(d / 3600)}時間前`;
  if (d < 86400 * 7) return `${Math.floor(d / 86400)}日前`;
  const dt = new Date(t);
  return `${dt.getMonth() + 1}/${dt.getDate()}`;
}

/**
 * 購読が切れた後、「次は何回目の試行として数えるか」。
 *
 * ★「一度つながった」だけで待ち時間を戻すと、受けた直後に切るサーバ相手に毎秒
 * つなぎ直し続ける(地下鉄で電波が瞬く時がまさにそれ)。**続いた時間**で判断する。
 * `openedAt` が偽値 = 一度も開けなかった回。その時は必ず数を進める。
 *
 * @param attempt 直前までの試行回数
 * @param openedAt 接続が開いた時刻(ms)。開けなかったら 0 / null
 * @param nowMs 今
 */
export function nextAttempt(attempt, openedAt, nowMs) {
  const healthy = Boolean(openedAt) && nowMs - openedAt > HEALTHY_MS;
  return healthy ? 1 : attempt + 1;
}
const HEALTHY_MS = 5000;

/**
 * `gap` イベントを帯に出すか。
 *
 * `tail-attached` = 購読を張った瞬間の**正直な継ぎ目**で、欠陥ではない(電話は先に
 * `/stream` を開いてから `/history` を撮るので必ず出る)。毎回警告を出すと、
 * **本当の取りこぼしが同じ文面に埋もれる**。それ以外は黙らない。
 *
 * @returns {string|null} 出す文面。出さないなら null
 */
export function gapNotice(why) {
  if (!why || why === "tail-attached") return null;
  return `流れに切れ目がありました(${why})。履歴を読み直しました。`;
}

/**
 * 「以前を読む」を押した時に、次に頼む履歴の件数。
 * ★上限 500 は「電話が固まらない」側の栓。`current` が 0(まだ何も無い)でも
 * 先へ進む必要があるので下駄を履かせる — ここを `current + 100` にすると
 * **押しても件数が増えず、ボタンが効かないまま無限に押せる**。
 */
export function nextHistoryLimit(current) {
  return Math.min(500, (current || 50) + 100);
}

/** 発言者の表示名。知らない role は道具(tool_result 等)に寄せる。 */
export function whoOf(role) {
  if (role === "user") return "Tom";
  if (role === "assistant") return "Claude";
  return "道具";
}

/**
 * 一覧の下に出す走査の計器。★速さを主張する側が計器を持つ(§2.12)。
 * 値が欠けている時に 0 で埋めない — 「読めなかった」と「0本だった」は違う。
 */
export function scanLine(scan) {
  if (!scan) return "";
  return `${scan.files ?? "?"}本のうち ${scan.read ?? "?"}本を読み、${scan.cached ?? 0}本は前の結果を使いました。`;
}

/** 一覧の1行に出す副題。★読み切れていない時は「無い」と書かない(§2.12)。 */
export function subtitleOf(row) {
  const r = row || {};
  if (r.lastPrompt) return r.lastPrompt;
  if (r.metadataIncomplete) return "(直近の発言は読み取り範囲の外)";
  return "(まだ発言がありません)";
}
