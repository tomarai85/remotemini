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
    // ★本文が読めなかった(`body == null`)時に「送った」と名乗らない(2026-08-02 追加)。
    //   202 の意味は「受け取った」までで、取り込まれたかは**本文の `delivered` にしか無い**。
    //   その本文が読めていないなら、私は確認していない。`{}` に潰すと「確認できた」側へ倒れる。
    //   `frames.mjs` の `decodeEvent()` が同じ状況で ok:false を返すのと同じ判断 — 読めない事は値ではない。
    //   ★`{}` は対象外。`server.mjs` の 202 応答(worker 経路)は `delivered` を正当に持たないので、
    //     「鍵が無い読める本文」は今まで通り ok のままにする。変えるのは `null` だけ。
    if (body == null) {
      return {
        kind: "warn",
        text: "送りましたが、サーバの返事を読めませんでした。本文は残してあります。送り直すと二重に入ることがあります。",
        keepText: true,
      };
    }
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
    // ★本文が読めなかった時に「対象が無かった」と断定しない(2026-08-02 追加)。
    //   「止める対象が無かった」は**観測した結果**であって、既定値ではない。
    //   `server.mjs` の割り込み応答の 200 は必ず `interrupted` を載せるので、それが読めていない
    //   のは「無かった」ではなく「分からない」。下の workPhrase の注記(観測できなかったを
    //   静かと書かない)と同じ誤りを、こちらは `|| {}` の1行でやっていた。
    if (body == null) {
      return { kind: "warn", text: "止めたかどうか確認できませんでした。画面を見て確かめてください。" };
    }
    // ★2026-08-03、tmux 経路は3通りに分かれるようになった(`server.mjs` の interrupt 参照)。
    //   それまでは Escape を送れた事が必ず「止めました(Escape)。」になっていて、
    //   **止まっていない時も同じ文が出ていた**。押した事と止まった事は別なので、別の文にする。
    //   ★2026-08-08、**worker 経路も `stopped` を載せる様になった**(§2.64)。旧版の
    //   ここには「worker 経路は tmux を持たないので画面を撮れない = `stopped` を名乗れない」
    //   と書いてあったが、逆だった —— worker は**子プロセスの handle を握っている**ので、
    //   画素から推し量る tmux より強い観測ができる。撮れないのは画面であって、死は分かる。
    //   下の二択が残っているのは worker の為ではなく、**`stopped` を載せない古いサーバ**の為。
    if (Object.prototype.hasOwnProperty.call(b, "stopped")) {
      if (b.stopped === "verified") return { kind: "ok", text: "止めました(生成が止まったのを確認)。" };
      // ★2026-08-03 追加。Escape を押した時には番が自力で終わっていた場合。
      //   画面の見え方は「止まった」と同じ(スピナーが消える)ので、これを verified に
      //   混ぜると**止めていないのに止めたと言う**。完了行が増えた事で区別が付く。
      //   ★この値は tmux 経路にしか出ない(worker の interrupt docstring 参照)。
      if (b.stopped === "already-done") {
        return { kind: "ok", text: "押した時には終わっていました(止めるものは残っていません)。" };
      }
      // ★何を撃ったかは経路で違う。tmux は Escape、worker は子への停止信号。
      //   両方を「Escape」と書くと、**やっていない操作を報告する**事になる。
      //   経路が読めない時は動作を名指しせず「止める操作」に畳む(創作しない)。
      const pressed = b.route === "tmux" ? "Escape は押しました"
        : b.route === "worker" ? "停止の信号は送りました"
          : "止める操作は届きました";
      if (b.stopped === "unverified") {
        return { kind: "warn", text: `${pressed}が、まだ止まっていません。画面を見て確かめてください。` };
      }
      // stopped == null = 押す前から生成の印が無かった。押した事だけが確かなので、そう書く。
      return { kind: "warn", text: `止める対象が見当たりませんでした(${pressed})。` };
    }
    // ★`stopped` が無い = **`stopped` を載せない古いサーバ**。2026-08-08 より前の版で、
    //   `interrupted` は「止める対象が居たか」しか意味していない。だから居た場合でも
    //   「止めました」とは書けない —— それがこの節を書き直す原因になった嘘そのもの。
    return b.interrupted
      ? { kind: "warn", text: "止める操作は届きましたが、止まったかどうかは分かりません。画面を見て確かめてください。" }
      : { kind: "warn", text: "止める対象がありませんでした。" };
  }
  if (status === 409) return { kind: "refused", text: b.error || "止められませんでした。" };
  if (status === 401) return { kind: "error", text: "鍵が通りませんでした。" };
  if (status >= 500) return { kind: "error", text: `サーバ側で失敗しました(HTTP ${status})。` };
  return { kind: "error", text: `想定していない応答でした(HTTP ${status})。` };
}

/** 一覧・会話の見出しに出す経路の印。 */
/**
 * tmux の行に出す「動き」の語。
 *
 * ★**「観測できなかった」を「静か」と書かない**(2026-08-02 に直した)。
 * `inject.mjs` の activity docstring・`server.mjs` の `screenOf()`・`screenBody()` の3箇所が揃って
 * 「observed でない事は待機中を意味しない」と書いているのに、表示層だけが「静か」と
 * 断定していた。`activity` の値域は `"observed" | "unknown"` の2値で、待機中を表す値は
 * **存在しない**。値の言い換えではなく創作だった。
 *
 * 誤りの大きさ(2026-08-03 の測り直し後の値。旧版はここに M3 の値を書いていた =
 * DESIGN §2.9-X-2/X-8): 一覧は1枚しか撮らないので、生成中のうち **1枚あたり 18-39%** を
 * 「静か」と書いていた。ストリームの窓についての「独立仮定の上界」計算は**撤回**した
 * (掛け算の前提そのものが測られていない)。代わりに測ったのは
 * 「生成中に印が消えた最長 = 2-3 枠 ≈ 300-450ms」で、窓がこれを**超えて**静かな時に初めて
 * 「静か」と言える。
 * 向きも悪い —「静か」は「打ち込んでいい」と読めるので、生成中の所へ打たせる方に外す。
 *
 * `work:"quiet"` は窓が在るので**測った窓をそのまま出す**(結論ではなく観測)。
 * `activity` しか無い一覧は窓が無いので「状態不明」。
 */
function workPhrase(v) {
  if (v.work === "observed" || v.activity === "observed") return "動いている";
  if (v.work === "quiet") {
    const sec = Math.round((v.windowMs || 0) / 1000);
    return sec > 0 ? `${sec}秒 動く印なし` : "動く印なし";
  }
  return "状態不明";
}

/**
 * ワーカーの `state` を Tom の言葉にする。`workPhrase` の worker 版(2026-08-08)。
 *
 * 起票: 一覧の札が `ワーカー・busy` と、**内部のトークンを生で**出していた。tmux 枝は
 * 全部日本語(「動いている」「動く印なし」「状態不明」)なので、これも片方の経路にだけ
 * 残っていた古い形 —— R2-2 / R2-3 と同じ型が、同じ関数の中で3件目。
 *
 * ★これを隠していた物が在る: `ios/Sources/Core/SessionsListingFixture.swift` の worker 行は
 *   `ワーカー・実行中` と**日本語**だった。電話の見た目を確かめる時に使う fixture が本番より
 *   綺麗な文字列を出していたので、画面を何度見ても `ワーカー・busy` は一度も出て来ない。
 *   「答えを書き込んだ fixture は何も証明しない」の新しい形。fixture 側も本番に揃えた。
 *
 * ★言葉は**観測**に留める。`busy` は「送ってから result がまだ返っていない」という事実で、
 *   「Claude が考えている」は推測。tmux 側が `observed` を「動いている」と書き、
 *   窓が無い時に「静か」と書かない(= 打って良いと読める)のと同じ線引き。
 *
 * ★知らない state は**生のトークンのまま返す**。新しい state を勝手に既存の言葉へ丸めると、
 *   増えた事が誰にも見えないまま既存の状態に化ける。読めない物を読めた事にしない、は
 *   `errored` 枝(理由を創作しない)と同じ方針。
 */
function workerStatePhrase(state) {
  if (state === "busy") return "答え待ち";
  if (state === "ready") return "待機";
  if (state === "idle") return "未起動";
  return String(state);
}

export function routeLabel(live) {
  const v = live || {};
  if (v.route === "tmux") {
    // ★選択待ちを最優先。Enter が承認や課金の選択になる唯一の状態なのに、一覧は
    //   `label.text` しか描かない(`app.html` の `sessionRow`)ので `screen` に入れておくだけでは
    //   **一覧から見えなかった**(2026-08-02 発見)。帯だけが screen を読む = 開くまで分からない
    //   = 順序が逆。送信は `SEND_REFUSAL.choice` が既に拒むが、**拒む事と見える事は別**。
    if (v.screen === "CHOICE") {
      const lim = v.limited ? " / 利用上限の告知も出ています" : ""; // 事実をどちらも消さない
      return {
        kind: "choice",
        short: "★選択待ち",
        text: `机で開いている・★選択待ち(Enter が承認や課金になります)${lim}`,
        screen: v.screen,
      };
    }
    const work = workPhrase(v);
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
        ? { kind: "tmux", short: "動いている・★上限", text: "机で開いている・動いている(★画面に利用上限の告知が残っている)", screen: v.screen || "" }
        : { kind: "tmux", short: "★利用上限", text: "机で開いている・★利用上限(答えは返りません)", screen: v.screen || "" };
    }
    return { kind: "tmux", short: `机・${work}`, text: `机で開いている・${work}`, screen: v.screen || "" };
  }
  if (v.route === "worker") {
    const w = v.state ? `ワーカー・${workerStatePhrase(v.state)}` : "ワーカー";
    // ★上の tmux 枝と**同じ骨格**。監査 R2-2 まで、ここには状態しか無く、上限に当たった
    //   会話と正常に答え終わった会話が同じ札で並んでいた(2026-08-08 実測、どちらも
    //   `ワーカー・busy` でバイト単位に一致)。tmux 側は 2026-08-02 に直っていたので、
    //   **片方の経路にだけ古い形が残っていた** = R2-3 と同じ残り方。
    // ★過去形と現在形を混ぜないのも tmux と同じ理由。`limited` / `errored` が指すのは
    //   **直前の turn**で、`state` が指すのは**今**。上限の直後に次の一件が走り始める事は
    //   普通に起きる(行列を止めない裁定 —— `worker.mjs` の `_recordTurnEnd`)ので、
    //   見出しは現在形、告知は但し書きに落とす。
    if (v.limited) {
      return v.state === "busy"
        ? { kind: "worker", short: "ワーカー・★上限", text: `${w}(★直前の答えは利用上限で返っていません)`, screen: "" }
        : { kind: "worker", short: "★利用上限", text: `${w}(★利用上限。直前の答えは返っていません)`, screen: "" };
    }
    // ★上限と名指せない異常。**理由を創作しない**のがここの仕事 —— `is_error` は確かだが
    //   何が起きたかは分からないので、分かる事(答えが返らなかった)だけを言う。
    //   この枝が在るから、上限の文面が未知の形に変わった日も無音にはならない。
    if (v.errored) {
      return { kind: "worker", short: "ワーカー・★答えなし", text: `${w}(★直前の答えは返りませんでした。理由は名指せません)`, screen: "" };
    }
    return { kind: "worker", short: w, text: w, screen: "" };
  }
  // `"gone"` は旧いストリームが送ってくる経路名(産む所1・使う所0だった)。server 側で
  // `blockedBody()` に寄せたが、繋ぎっ放しの購読が古い本文を持っている事があるので受ける。
  if (v.route === "blocked" || v.route === "gone") {
    // サーバが文を付けてきたらそれが正(文面の出所は1つ = server.mjs の blockedMessage)。
    // 付いていない時だけ、ここの短い言い換えに落ちる。**理由コードを生で出さない**。
    // ★`short` を別に持つのは**置き場所が違う**から: 92文字の説明は電話の一覧の丸い札に
    //   入らない(他の札は9-10文字。2026-08-02 実測)。説明は会話画面の帯で出す。
    //   同じ文を2箇所に書くのではなく、一覧=要約 / 会話画面=サーバの文、と役割を分ける。
    return {
      kind: "blocked",
      short: BLOCKED_TAG[v.reason] || "送れない",
      text: v.message || BLOCKED_SHORT[v.reason] || "宛先を確定できません。",
      screen: "",
    };
  }
  return { kind: "unknown", short: "状態不明", text: "状態不明", screen: "" };
}

/**
 * 一覧の札に出す**短い**理由。`BLOCKED_SHORT` は会話画面用の言い換え(サーバの文が無い時)で、
 * こちらは一覧の丸い札用。★理由コードを生で出さない原則は両方に効く。
 * ★覆うべき集合は `blocked.mjs` の `WIRE_REASONS`(= 電話に実際に流れる理由の全域)。
 *   「`blockedMessage()` の枝を覆う」と書いていた頃、その `blockedMessage()` 自身が
 *   全域を覆っていなかったので、基準にしていた物が既に欠けていた。検査は
 *   `test/view.test.mjs` が `WIRE_REASONS` を回して両方の表を突く。
 */
const BLOCKED_TAG = {
  ambiguous: "送れない(複数該当)",
  unregistered: "送れない(未登録)",
  stale: "送れない(登録ずれ)",
  "cwd-mismatch": "送れない(現在地ずれ)",
  "pane-gone": "送れない(画面消失)",
  "not-claude": "送れない(別プログラム)",
  "panes-unreadable": "送れない(tmux 故障)",
  "tmux-unavailable": "送れない(tmux 不達)",
};

const BLOCKED_SHORT = {
  ambiguous: "同じフォルダで複数開いているため、宛先を確定できません。",
  unregistered: "ペイン登録が無いため、宛先を確定できません。",
  stale: "登録したペインを今は別の会話が使っています。",
  "cwd-mismatch": "登録ペインの現在地が一致しません。",
  "pane-gone": "開いていたペインが見つかりません。",
  // ★2026-08-02 追加。この3つが**抜けていた**ので、サーバの文が届かなかった時だけ
  //   「宛先を確定できません。」という**故障だと分からない文**に落ちていた。
  //   前2つは `BLOCKED_TAG` を作った時に鍵の集合を突き合わせて発見、`not-claude` は
  //   同日夕方に `WIRE_REASONS` を回す検査を書いて発見 = **目で突き合わせても1つ残った**。
  "not-claude": "その画面は今は Claude ではありません(シェルに戻っています)。",
  "panes-unreadable": "サーバが tmux の画面一覧を読めていません(故障)。",
  "tmux-unavailable": "サーバが tmux に届いていません(故障)。",
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

/**
 * 一覧が**いつ測った値か**。★2026-08-03 追加(DESIGN §2.19 U1)。
 *
 * 一覧は網を叩いた瞬間の観測で、その後は勝手に古くなる。それを黙って現在形で
 * 出し続けるのがこの系で一番よく踏む型 —**記録が在る事を、事象が起きた事と読む**。
 * しかも外れる向きが悪い:「動く印なし」は「打ち込んでいい」と読めるので、
 * 古い静けさは**生成中の所へ打たせる**側に倒れる(`workPhrase` の注記と同じ心配)。
 *
 * 時計での定期取得はしない(一覧1回 = 実測 0.75秒。常時 5% を edith に載せる価値が無い)。
 * 代わりに**古さを見せる**。網を使わないので電池も相手の負荷も増えない。
 *
 * `stale` の境目を 60 秒に置く理由 = **この画面自身の目盛り**。`relTime` は 60 秒
 * 未満を全部「たった今」に潰すので、それより細かい古さは画面上で区別できない。
 * 分に乗った瞬間が、表示が「今」を名乗れなくなる最初の点。
 *
 * @param fetchedAtMs 一覧が**取れた**時刻(ms)。0/未設定 = まだ取れていない
 * @param nowMs 今
 * @returns {{text:string, stale:boolean}}
 */
export function freshness(fetchedAtMs, nowMs) {
  // ★「いつ測ったか分からない」を「新しい」側へ倒さない。分からないなら分からないと出す。
  //   ここを `{text:"", stale:false}` にすると、時刻を取り損ねた時に**何も言わない綺麗な
  //   一覧**が出る = 古さの警告が消えるだけで、値は古いまま。fail-closed に倒す。
  if (!fetchedAtMs || !Number.isFinite(fetchedAtMs)) {
    return { text: "いつ測った値か不明", stale: true };
  }
  const d = Math.floor((nowMs - fetchedAtMs) / 1000);
  if (d < 0) return { text: "たった今の値", stale: false }; // 時計のずれ。relTime と同じ扱い
  if (d < 60) return { text: `${d}秒前の値`, stale: false };
  if (d < 3600) return { text: `${Math.floor(d / 60)}分前の値(更新してください)`, stale: true };
  if (d < 86400) return { text: `${Math.floor(d / 3600)}時間前の値(更新してください)`, stale: true };
  return { text: `${Math.floor(d / 86400)}日前の値(更新してください)`, stale: true };
}

/** 一覧の1行に出す副題。★読み切れていない時は「無い」と書かない(§2.12)。 */
export function subtitleOf(row) {
  const r = row || {};
  if (r.lastPrompt) return r.lastPrompt;
  if (r.metadataIncomplete) return "(直近の発言は読み取り範囲の外)";
  return "(まだ発言がありません)";
}

/**
 * 長待ち受け(`/api/sessions/:id/poll`)の応答1回分の形を、**適用の前に**丸ごと検める。
 * 真を返した物だけ画面へ渡す(DESIGN §2.36)。
 *
 * ★`entries || []` で埋めない理由: 読めない形を空に化かすと「何も来なかった」と区別が
 *   付かなくなる。サーバが壊れた時に**電話だけが黙って正常に見える** —— この系がいちばん
 *   嫌う嘘の形。読めなければ読めないと言い、帯を切断側へ倒す。
 * ★**判断を app.html に置かない**理由がまさにこの関数: ここを画面側に書いた初版は、
 *   `entries` だけを見ていた。ところが**ワーカー経路の item は `entries` を持たない**
 *   (`server.mjs` は `{kind:"message", event: <NDJSON1行>}` を積む)。画面側に在ると
 *   単体検査も変異検査も掴めないので、**ワーカー経路の poll が毎回投げる**形のまま
 *   緑で出荷できてしまう。view.mjs へ移した事でこの取り違えが出た。
 * ★知らない `kind` は**捨てて良い**(偽を返さない)。将来サーバが種類を1つ足した時、
 *   古い電話が配信を丸ごと拒んで固まる方が害が大きい。読めない物を「空」と偽らずに
 *   ただ素通りさせるのは、化かす事とは別。
 *
 * @param {{items?: unknown}} d poll の応答本文
 * @returns {boolean} 適用してよいか
 */
export function readablePoll(d) {
  if (!d || typeof d !== "object" || !Array.isArray(d.items)) return false;
  for (const it of d.items) {
    if (!it || typeof it !== "object") return false;
    // `kind:"message"` は経路で中身が違う。tmux = `entries`(転記の行)、
    // worker = `event`(我々が起こした子の NDJSON 1行)。どちらでもなければ読めない。
    if (it.kind === "message" && !Array.isArray(it.entries) && !isPlainEvent(it.event)) return false;
  }
  return true;
}

function isPlainEvent(v) {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

// ---- 選択待ち画面の操作面(2026-08-04)---------------------------------------
//
// なぜここに在るか: `POST …/choice` は 2026-08-03 に出荷済みなのに、電話には**その口へ
// 繋がる操作が1つも無かった**。会話が選択メニューで止まると、composer の送信は
// `SEND_REFUSAL.choice` が断り、割り込みは Escape を撃つだけ = 外出先からは
// **その会話を進める手が無い**。移動中に机の Claude Code を動かす、というこの系の
// 目的そのものが、メニュー1枚で止まる。
//
// ★判断をここに置く理由は他と同じ(この file の冒頭)。特にこの層は
// 「押せる/押せない」を決める = 間違いの向きが**安全確認を押す側**へ倒れうる唯一の場所なので、
// 単体でも変異でも掴める所に無ければならない。app.html に書いたら、間違っても緑になる。

/**
 * 打鍵できない時に電話へ出す短い文。
 *
 * ★`server.mjs` の `CHOICE_REFUSAL` と**役割が違う**(重複ではない)。あちらは
 *   「打鍵を要求したが断った」の**事後**の説明で、こちらは「そもそも押す物を出さない」の
 *   **事前**の説明。同じ文言にすると、押していないのに「何も送っていません」と出る事になり、
 *   何も要求していない人に打鍵の話をする事になる。`BLOCKED_TAG` / `BLOCKED_SHORT` を
 *   一覧と会話画面で分けたのと同じ形(役割で分ける、写しを置かない)。
 */
const CHOICE_BLOCKED = {
  "hard-stop":
    "これは許可・信頼の確認画面です。電話からは操作を出しません(自動化に安全確認を押させない、という決め事)。机で確認してください。",
  "unrecognized":
    "見覚えのない選択画面です。安全と確認できた画面にしか打鍵しないので、操作は出しません。",
  "not-menu":
    "選択待ちですが、メニューの形を読み取れませんでした。操作は出しません。画面を確認してください。",
};

/** 打鍵 -> ボタンに出す鍵の名。数字は選択肢の本文が付くのでここには無い。 */
const CHOICE_KEY_LABEL = { enter: "Enter", escape: "Escape" };

/**
 * 鍵の名だけでは何が起きるか分からない鍵に、括弧で足す日本語。
 *
 * Enter は「カーソルの選択肢で決定」と、押した先を**その場の値**で名乗れる(下の `at`)。
 * Escape は押した先が画面に依らないので、名乗る語がここにしか無い —— 無ければ
 * `Escape` の一語で出る事になり、`1. はい` / `Enter(1. はい で決定)` と並ぶカードの中で
 * **そこだけ英語の鍵名**になる。
 *
 * ★2026-08-08(監査 S8-20)。これが無かった間、`PollFixture.swift` は `中止(Escape)` と
 *   書いていた —— rc-backend の何処にも無い文字列で、電話は札をそのまま描くので、
 *   撮った画面に出ていたその札は**一度も本番に存在した事が無い**。Sprint 7 に
 *   「画面を見て」直した割り込みの注意文(「中止するなら下の選択肢から選んでください」)は
 *   その実在しないボタンを指していた。今この表が在るので、その文の指す先が実在する。
 */
const CHOICE_KEY_ACTION = { escape: "中止" };

/**
 * poll が運んでくる画面状態 -> 選択の操作面。**純関数**。
 *
 * @param {null|{screen?:string, choice?:object}} state `conv.state`(= screenBody の本文)
 * @returns {{show:boolean, reason:string, head:string[], options:{n:number,label:string,cursor:boolean}[],
 *   buttons:{key:string,label:string}[], digest:string}}
 *   `show` = 操作面そのものを描くか(= 選択待ちか)。`buttons` が空でも `show` は真になりうる
 *   —— **押せない事と、何が出ているか見える事は別**(routeLabel の §2 と同じ判断)。
 */
export function choiceView(state) {
  const none = { show: false, reason: "", head: [], options: [], buttons: [], digest: "" };
  const v = state || {};
  if (v.screen !== "CHOICE") return none;
  const c = v.choice || null;
  // サーバが CHOICE と言ったのに中身が無い = `choiceViewOf` が null を返した形
  // (`classifyScreen` の「強い文言 + 番号行」経路)。押す物は出さないが、選択待ちである事は出す。
  if (!c) return { ...none, show: true, reason: CHOICE_BLOCKED["not-menu"] };

  const head = Array.isArray(c.head) ? c.head : [];
  const options = Array.isArray(c.options) ? c.options : [];
  const keys = Array.isArray(c.keys) ? c.keys : [];
  const digest = typeof c.digest === "string" ? c.digest : "";
  const base = { show: true, reason: "", head, options, buttons: [], digest };

  // ★指紋が無ければ**押す物を出さない**。サーバは digest 必須(省略は 400)なので、
  //   出したボタンは押した瞬間に必ず失敗する。押せない物を押せる顔で出さない(fail-closed)。
  if (!digest) return { ...base, reason: CHOICE_BLOCKED["not-menu"] };
  // ★`keys` が空 = サーバが「この画面に打ってよい鍵は無い」と言っている。理由は `kind` で分ける。
  //   ここで `kind` を見て**自前に**押せると判断してはいけない —— 許可の出所を1つに保つ。
  if (keys.length === 0) {
    return { ...base, reason: CHOICE_BLOCKED[c.kind] || CHOICE_BLOCKED["unrecognized"] };
  }

  const buttons = [];
  // ★数字の門は**2つ**。`keys` に `"digit"` が在る事と、その番号の選択肢が実在する事。
  //   これは `#chooseExclusive` の2つの門(`matcher.keys.includes(keyKind(key))` と
  //   `optionFor(c.menu, key)`)と1対1で、写しではなく**同じ規則の表側**。
  //   ★Codex (gpt-5.6-sol xhigh, 2026-08-04) は「各数字が `keys` に在るかを見よ」と言ったが、
  //     `keys` が持つのは種別語(`"digit"`)で `"1"`..`"9"` ではない(`choice.mjs` の `keyKind`)。
  //     助言の**意図**(鍵の許可と選択肢の実在を両方要求する)はこの形で満たしている。
  if (keys.includes("digit")) {
    // 1-9 を機械的に並べると、5択の画面に 6-9 の4個が出る = サーバが
    // `choice-no-such-option` で断るボタンを4個並べる事になる。
    for (const o of options) {
      if (!Number.isInteger(o.n) || o.n < 1 || o.n > 9) continue;
      buttons.push({ key: String(o.n), label: `${o.n}. ${o.label}` });
    }
  }
  for (const k of ["enter", "escape"]) {
    if (!keys.includes(k)) continue;
    // ★Enter は**カーソルが載っている選択肢**を押す。どれが選ばれるかを語にして出す
    //   (「見た物と押す物が同じ」を、指紋だけでなく**人の目にも**通す)。
    //   カーソルが読めない時は名乗らない — 分からない物を断定しない。
    const at = k === "enter" ? options.find((o) => o.n === c.cursor) : null;
    // 括弧の中身は、その場で読めた物(Enter)が先、読めなくても言える物(Escape の
    // `中止`)が後。**両方無い時だけ鍵名だけで出す** —— カーソルの読めない Enter が
    // 其れで、「Escape だから中止」の様な当て推量を Enter 側へ持ち込まない。
    const action = at ? `${at.n}. ${at.label} で決定` : CHOICE_KEY_ACTION[k];
    buttons.push({
      key: k,
      label: action ? `${CHOICE_KEY_LABEL[k]}(${action})` : CHOICE_KEY_LABEL[k],
    });
  }
  return { ...base, buttons };
}

/**
 * `POST /api/sessions/<id>/choice` の応答を画面語にする。`sendResult` と同じ形。
 *
 * ★`applied` を「効いた」と読まない。サーバは「送った(accepted)」と「画面が動いた(applied)」を
 *   別項目で返す —— 割り込みの `stopped` と同じ規律。ここで丸めると、押したのに何も
 *   起きていない画面を「決定しました」と言う事になる。
 *
 * @returns {{kind:"ok"|"warn"|"refused"|"error", text:string}}
 */
export function choiceResult(status, body) {
  const b = body || {};
  if (status === 200) {
    // 本文が読めない 200 を「押せた」と名乗らない(sendResult / interruptResult と同じ)。
    if (body == null) {
      return { kind: "warn", text: "打鍵しましたが、サーバの返事を読めませんでした。画面を見て確かめてください。" };
    }
    // `applied` の値域は "verified" | "unverified" | "moved-to-hard-stop" | null
    // (`inject.mjs` の choice docstring)。**真偽値ではない** —— 初版で `=== false` と
    // 書いて、`"unverified"` が全部「押しました」へ落ちていた(自分の diff を読み直して発見)。
    if (b.applied === "verified") return { kind: "ok", text: "押しました(画面が変わったのを確認)。" };
    // ★打鍵の後に許可・信頼の確認へ変わった時。**押した事は確か**なので `refused` にはしない
    //   (refused は「何も送っていない」の語)。だが机で見る必要がある事は文で立てる。
    //   文面はサーバの `note` が正(★付きで来る)。
    if (b.applied === "moved-to-hard-stop") {
      return { kind: "warn", text: b.note || "打鍵の後、許可・信頼の確認画面に変わりました。机で確認してください。" };
    }
    if (b.applied === "unverified") {
      return { kind: "warn", text: b.note || "打鍵は送りましたが、画面が変わったのは確認できていません。画面を取り直してください。" };
    }
    // ここへ来るのは `sent:true` なのに `applied` が読めない形。分からない事を成功に丸めない。
    return { kind: "warn", text: "打鍵しましたが、画面が変わったかを確認できませんでした。画面を見て確かめてください。" };
  }
  // 409 = サーバが打鍵を断った(指紋の食い違い・許可一覧に無い・二度打ち等)。文面はサーバの物。
  if (status === 409) return { kind: "refused", text: b.error || "打鍵を断られました。" };
  if (status === 400) return { kind: "error", text: b.error || "受け付けられない打鍵でした。" };
  if (status === 401) return { kind: "error", text: "鍵が通りませんでした。" };
  if (status >= 500) return { kind: "error", text: `サーバ側で失敗しました(HTTP ${status})。` };
  return { kind: "error", text: `想定していない応答でした(HTTP ${status})。` };
}

/**
 * 送信待ち(まだワーカーへ書いていない番)の面を出すか、出すなら何と書くか。
 *
 * ★数は poll の本文が運ぶ(`server.mjs` の `collectW`)。**事象からは復元できない**:
 *   積む時は `user_queued` が出るが、降ろす時は `entry.queue.shift()` して書くだけで
 *   何も出ない(`worker.mjs` の `result` 処理)。事象を数えると増える一方の数になる。
 *
 * ★`null` と `0` を混ぜない。tmux 経路の送信待ちは Claude Code の TUI が持っていて
 *   (`Press up to edit queued messages`)、我々はその数を観測できないので `queued:null` が来る。
 *   これを `0` と同じ枝へ落とすと表示は同じ「何も出さない」で済むが、**判定の意味が変わる** ——
 *   「観測して0だった」と「観測していない」を1つの枝に畳んだ瞬間、後から
 *   「机の会話でも 0 件と出しては?」という直し方が正しく見えてしまう。枝を分けて残す。
 *
 * ★この数も**観測した瞬間の値**で、その後は勝手に古くなる(2026-08-04)。面は poll が
 *   返った時にしか描き直されない —— つまり **poll が返らなくなった時こそ**、電話は
 *   「送信待ち 2 件」を現在形で出し続ける。一覧が `freshness` で古さを見せているのと
 *   同じ穴が此処にも開いていた。古さの判定は一覧と**同じ関数**から取る(二つ目の境目を
 *   作らない = 60 秒の意味が画面ごとにずれない)。
 *
 * @param fetchedAtMs この数が**取れた**時刻(ms)。0/未設定 = 分からない → 古い側へ倒す
 * @param nowMs 今
 * @returns {{show:boolean, known:boolean, count:number, text:string, clearLabel:string,
 *            ageText:string, stale:boolean}}
 */
export function queueView(d, fetchedAtMs, nowMs) {
  const v = d || {};
  const q = v.queued;
  // 観測していない(tmux 経路 / 古いサーバ / 読めなかった本文)。断定しないので何も出さない。
  if (typeof q !== "number" || !Number.isFinite(q)) {
    return { show: false, known: false, count: 0, text: "", clearLabel: "", ageText: "", stale: false };
  }
  // ★出さない枝で古さを名乗らない。面が無いのに「2分前の値」だけ残ると、**何の**2分前かが
  //   画面から消える(数が消えた後も古さの行だけ生きる、という見え方になる)。
  if (q <= 0) {
    return { show: false, known: true, count: 0, text: "", clearLabel: "", ageText: "", stale: false };
  }
  const f = freshness(fetchedAtMs, nowMs); // ★境目(60秒)は一覧と共有。此処に条件を書かない
  return {
    show: true,
    known: true,
    count: q,
    // ★「送信待ち」= まだ Claude へ**渡していない**。渡した番は取り消せない(止めるのは別の口)。
    text: `送信待ち ${q} 件(まだ Claude に渡していません)`,
    clearLabel: `${q} 件を取り消す`,
    // ★文面も一覧と揃える。同じ「古さ」に画面ごとの言い回しを与えると、人は二つの規約を
    //   覚える羽目になる。「更新してください」は此処でも実行できる(会話を開き直す /
    //   前面へ戻る、どちらも張り直しの口になっている)。
    ageText: f.text,
    stale: f.stale,
  };
}

/**
 * 「取り消す」の応答をどう読むか。`interruptResult` と同じ規律 ——
 * 読めなかった本文を「無かった」に丸めない。
 *
 * @returns {{kind:"ok"|"warn"|"refused"|"error", text:string}}
 */
export function clearQueueResult(status, body) {
  const b = body || {};
  if (status === 200) {
    if (body == null) {
      return { kind: "warn", text: "取り消せたかどうか確認できませんでした。画面を見て確かめてください。" };
    }
    const n = b.dropped;
    // 200 は必ず `dropped` を載せる(`server.mjs`)。載っていないのは「0件」ではなく「不明」。
    if (typeof n !== "number" || !Number.isFinite(n)) {
      return { kind: "warn", text: "取り消せたかどうか確認できませんでした。画面を見て確かめてください。" };
    }
    if (n <= 0) return { kind: "ok", text: "取り消す送信は残っていませんでした。" };
    // ★走っている番は止まらない事を必ず書く。ここを省くと「取り消した = 全部止まった」と読める。
    return { kind: "ok", text: `${n} 件の送信を取り消しました(いま動いている番は止まりません)。` };
  }
  if (status === 409) return { kind: "refused", text: b.error || "取り消せませんでした。" };
  if (status === 401) return { kind: "error", text: "鍵が通りませんでした。" };
  if (status >= 500) return { kind: "error", text: `サーバ側で失敗しました(HTTP ${status})。` };
  return { kind: "error", text: `想定していない応答でした(HTTP ${status})。` };
}
