// 「送れない」を人の読む1文にする層 — **判断はここに置き、server.mjs は貼るだけにする**。
//
// なぜ server.mjs から出したか(2026-08-02):
// `server.mjs` は import した瞬間に listen する(1002行目)ので、**単体検査から呼べない**。
// 結果この層は e2e 越しにしか触れず、下の欠落が実行するまで見つからなかった:
//
//   `feedTick` だけが `blockedBody()` に**理由の全域**を渡している(他の呼び口は全部
//   `UNDECIDABLE` で絞ってから渡す)。`blockedMessage()` は `UNDECIDABLE` の6つを前提に
//   書かれていて、残る `none` / `not-claude` は**既定 = cwd 不一致の文**に落ちていた。
//   画面が消えただけの会話に「現在地が一致しません」と出る = 直し方まで嘘になる。
//
// ★今日4回踏んだ型の4回目 =「既に在る物(`blockedMessage`)に寄せれば正しくなる」。
//   寄せ先が**全入力を覆っているか**は、寄せる前に読む以外に確かめる手が無かった。
//   だから domain を定数にして、覆っている事を検査(`test/blocked.test.mjs`)で押さえる。
//
// ★node の API を import しない(検査が listen 無しで読める事がこの分離の目的)。

/**
 * `resolveSessionPane()` が返しうる理由の全域。★ここが正本。
 * `ok` は「送れる」なので入れない。
 */
export const RESOLVE_REASONS = [
  "none",
  "not-claude",
  "ambiguous",
  "unregistered",
  "stale",
  "cwd-mismatch",
  "panes-unreadable",
  "tmux-unavailable",
];

/**
 * 電話に**実際に流れる**理由の全域(= `blockedBody()` が出しうる値)。
 * `none` はここに無い — 下で `pane-gone` に正規化する。
 * `pane-gone` は `resolveSessionPane()` が返さない名前で、サーバが付ける。
 */
export const WIRE_REASONS = [
  "not-claude",
  "ambiguous",
  "unregistered",
  "stale",
  "cwd-mismatch",
  "pane-gone",
  "panes-unreadable",
  "tmux-unavailable",
];

/**
 * ペイン一覧が取れなかった時の理由札。**「読めた出力が壊れている」と「そもそも届かない」は別**。
 * 直し方が違う(前者=書式/locale、後者=tmux 自体かソケット)ので画面にも別の文で出す。
 */
export function paneFaultReason(e) {
  return e?.code === "TMUX_UNAVAILABLE" ? "tmux-unavailable" : "panes-unreadable";
}

/**
 * 一覧の**帯**に出す文。`reason` ごとの見出しと本文の組。
 *
 * ★行ごとの拒否文(`blockedMessage`)と**別に持つ**理由(2026-08-08、監査 S8-22)。
 * 同じ2つの `reason` に対して `blockedMessage` は既に日本語を持っているが、その文は
 * 「宛先を確定できないため送信しません。復旧するまで**この会話には**送れません」——
 * 主語が1つの会話である。帯は一覧の頭に1本だけ出て、下に並ぶ**全部**が送れない事を
 * 言う場所なので、同じ文を貼ると「この会話」がどれを指すのか読めなくなる。
 * 文の出所を1つに畳むのは、**同じ事を言う時**だけ正しい。
 *
 * ★下に会話が1件も無い事が在る(走査が0件で帯だけが出る)ので、本文は
 * 「下の会話は」と数えず「どの会話にも」と言う —— 空の一覧の上で嘘にならない形。
 */
export const PANE_FAULT_VIEW = {
  "tmux-unavailable": {
    headline: "サーバが tmux に届いていません",
    body: "机で開いている画面の一覧を取れませんでした。復旧するまで、どの会話にも送れません。この故障は電話からは直せないので、机で確認してください。",
  },
  "panes-unreadable": {
    headline: "tmux の画面一覧を読めていません",
    body: "tmux からの返事は来ていますが、中身が壊れていて読めません。復旧するまで、どの会話にも送れません。この故障は電話からは直せないので、机で確認してください。",
  },
};

/**
 * 帯の文を作る。**知らない `reason` に原因を作らない** —— `blockedMessage` の既定と同じ作法で、
 * もっともらしい別の原因に化けるより、名乗れないと言う方がまし(理由コードは出す)。
 *
 * ★`detail`(= `e.message`)は**受け取らない**。自由記述で tmux のペイン名や作業 dir の
 * path をそのまま載せうる値で、`test/wire-shape-controls.sh` は診断の出力からこれを
 * 伏せている。伏せる値を画面の本文にしていた、というのが此の監査で出た形。
 */
export function paneFaultView(reason) {
  return (
    PANE_FAULT_VIEW[reason] || {
      headline: "机の画面一覧を取れていません",
      body: `原因を名乗れません(理由: ${reason || "不明"})。復旧するまで、どの会話にも送れません。この故障は電話からは直せないので、机で確認してください。`,
    }
  );
}

/**
 * 会話の居場所(cwd)を理由にワーカーを起こさなかった時、電話に出す文。
 * ★鍵は `src/trust.mjs` の `CWD_REFUSALS` と**同じ全域**を覆う(test/trust.mjs が押さえる)。
 *   `ok` の文は**置かない** —— 通した時の文が在ると、断りと通過が同じ表に混ざる。
 */
export const WORKER_REFUSAL = {
  cwd_unknown: "この会話の作業場所が記録に無いので、机の外からは起こせません。一度机で開くと記録されます。",
  cwd_missing: "この会話の作業場所(フォルダ)が今は見つかりません。移動か削除をされていないか確認してください。",
  cwd_untrusted: "この作業場所はまだ Claude Code に信頼されていません。机で一度 claude を起動して確認画面に答えてください(電話からは答えません)。",
};

/** 決められなかった理由のうち、ワーカー経路にも落としてはいけないもの。 */
export const UNDECIDABLE = new Set([
  "ambiguous",
  "unregistered",
  "stale",
  "cwd-mismatch",
  "panes-unreadable",
  "tmux-unavailable",
]);

/** 既定の文。**原因を名乗らない**(下の理由を参照)。 */
export function unknownBlockedMessage(reason) {
  return `宛先を確定できません(理由: ${reason || "不明"})。送信しません。`;
}

/** 拒否理由を Tom が読める1文にする(画面にそのまま出る)。 */
export function blockedMessage(r) {
  if (r.reason === "ambiguous") {
    return `同じフォルダで Claude が ${r.candidates} 個開いています。どの画面かを特定できないため送信しません。`;
  }
  if (r.reason === "unregistered") {
    // 直せる拒否なので、直し方まで書く。ここが「エラーで終わり」だと電話側で詰む。
    return "この会話はペイン登録をしていないため、宛先を確定できません(同じフォルダの画面に送ると別の会話に入る恐れがあります)。その画面を rc-claude で開き直すと送れるようになります。";
  }
  if (r.reason === "pane-gone") {
    // ★この分岐が無いと既定に落ちる。画面が消えた事と現在地がずれた事は別の事実で、
    //   後者を出すと「開き直せば直る」と読めてしまう。
    return "開いていた画面が見つかりません(閉じられたか、別の会話が使っています)。宛先を確定できないため送信しません。";
  }
  if (r.reason === "not-claude") {
    // ペインは在るが claude ではない。注入すれば**シェルに任意コマンドが入る**ので、
    // 「消えた」でも「ずれた」でもなく**中身が変わった**と書く。
    return "開いていた画面は、今は Claude ではありません(終了してシェルに戻ったようです)。宛先を確定できないため送信しません。";
  }
  if (r.reason === "stale") {
    return "この会話が登録したペインは、今は別の会話が使っています。宛先を確定できないため送信しません。";
  }
  if (r.reason === "cwd-mismatch") {
    return `登録されたペインの現在地(${r.panePath || "不明"})が、この会話のフォルダと一致しません。宛先を確定できないため送信しません。`;
  }
  if (r.reason === "panes-unreadable") {
    // 電話の持ち主が取れる手が無い種類の故障なので、**故障だと分かる文**にする。
    // 「ペインが無い」風に書くと、机で開いている会話が消えたように読めて誤解を招く。
    return "サーバが tmux の画面一覧を読めていません(書式の壊れた出力が返っています)。宛先を確定できないため送信しません。復旧するまでこの会話には送れません。";
  }
  if (r.reason === "tmux-unavailable") {
    return "サーバが tmux に届いていません(画面一覧を取れませんでした)。宛先を確定できないため送信しません。復旧するまでこの会話には送れません。";
  }
  // ★既定は**原因を作らない**。以前はここが cwd 不一致の文で、覆えていない理由が来ると
  //   もっともらしい嘘が出た。理由コードを見せる方が「知らない」と分かるだけましで、
  //   覆い漏れが**画面で見える**ようにもなる(黙って別の原因に化けない)。
  return unknownBlockedMessage(r.reason);
}

/**
 * 電話に返す拒否の本体。
 *
 * ★`none` をここで `pane-gone` に正規化する。`resolveSessionPane()` の `none` は
 * 「登録ペインが消えていて、近くに生きた claude も無い」= 電話から見れば画面消失。
 * 正規化を呼び口ごとに書くと、書き忘れた呼び口だけが既定に落ちる(それが今回の欠陥)。
 * 出所を1つにするので、以後 `WIRE_REASONS` の外の値は電話に出ない。
 */
export function blockedBody(r) {
  // ★文面の出所を1つに保つ。電話側に同じ日本語を書くと、直した時に片方だけ古くなる。
  // 一覧の行にも 409 の本文にも、ここで作った同じ1文が載る(e2e が同一性を検査する)。
  const reason = !r.reason || r.reason === "none" ? "pane-gone" : r.reason;
  const body = { ...r, reason };
  return { route: "blocked", reason, candidates: r.candidates, source: r.source,
           message: blockedMessage(body) };
}
