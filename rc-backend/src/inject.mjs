// tmux 注入層 — 動いている対話 Claude に iPhone からの入力を届ける。
//
// なぜこの形か(DESIGN.md §2.9):
//   Tom 裁定「返答待ちであれ作業中であれいつでも見て干渉できればいい」。
//   別プロセスで claude -p を起こすと同じ会話を2実行が読む(lost-update)。
//   動いているペインに直接注入すれば会話は1プロセスのままで、その問題が原理的に消える。
//
// ★2026-08-01 全面改訂。それまでの状態機械は**存在しない状態を調整していた**。
// 使い捨てセッションで 0.25 秒刻みに 240 枚の画面を撮って分かったこと:
//   M1 `esc to interrupt` はこのビルドの画面に存在しない(240/0)。唯一の BUSY 材料が
//      これだったので、BUSY は一度も発火しておらず、キュー経路は死んでいた。
//   M3 進行中スピナーは 6.5 秒の生成中に 8/26 サンプルしか見えない(31%)。残りは同じ行を
//      tmux のヒント文が占拠する。→ **画面から「生成中」を遮断条件にはできない**。
//   M4 生成中も入力欄の `❯` は出たまま。「プロンプトが見える = 待機中」も成り立たない。
//   M5 生成中に本文→Enter を送ると生成は中断されず完走し、**TUI 自身がキューして**
//      (`❯ Press up to edit queued messages`)次のターンとして処理した。
//
// そこから決めた3点(全て Codex 二次レビュー 2026-08-01 と整合):
//   1. 自前キューは撤去。TUI が正しく持っている機能の二重実装で、固有の挙動は
//      「状態判定を外した時に本文を滞留させる」ことだけ。M3 はそれが7割外れると言っている。
//      契約は「最善努力・拒否は明示・電話から再送」。
//   2. 送信可否を「生成中か」で決めない。**composer(入力欄)が実在するか**で決める。
//      `READY`(= BUSY でない、という消極的定義)を捨て `SENDABLE`(積極的定義)にする。
//      分からなければ UNKNOWN = 送らない。「生成中でない」は「送ってよい」ではない。
//   3. 判定は **viewport だけ**を見る(`capture-pane -p`、`-S` 無し)。7/31・8/01 に踏んだ
//      失敗は2回とも「消えない過去の行を今の状態と読んだ」。範囲を今の画面に限れば
//      この失敗の型そのものが消える。
//
// 7/31 実機で確かめた規約は生きている:
//   - 本文と Enter は別送信(生成中の一括送信はバッファされ、完了後に誤送信される)
//   - 割り込みは Escape のみ。C-c は画面状態で消去/中断/終了に化ける

/** 入力欄を囲む罫線。Claude Code は composer を上下の `─` 行で挟んで描く。 */
const BOX_RULE = /^\s*─{8,}\s*$/;
/** composer の行。`❯` で始まる(空でも `Press up to edit queued messages` でも同じ)。 */
const COMPOSER_HEAD = /^\s*❯/;
/** 選択カーソル。実装差を吸収するため複数の字体を許す(Codex 指摘④)。 */
const SELECT_CURSOR = /^\s*[❯>›→▶]\s*\d+\.\s+\S/;
/** 番号付き選択肢の行(カーソルの有無を問わない)。 */
const OPTION_ROW = /^\s*(?:[❯>›→▶]\s*)?\d+\.\s+\S/;
/**
 * 承認・課金・信頼などの強い文言。**単独では CHOICE にしない**(下の menuAt 参照)。
 * 応答本文にこの語が出ることは普通に起きるため。
 */
const CHOICE_PHRASE =
  /(Enter to confirm|What do you want to do\?|Do you want to (proceed|continue)|weekly limit|Do you trust)/i;
/**
 * 進行中スピナー。**表示専用**。M3 の通り 31% しか見えないので、これが無いことは
 * 待機中の証拠にならない。送信可否には一切使わない。
 * 進行中 `✳ Fluttering… (3s · thinking)` / 完了 `✻ Cogitated for 10s`(`…` が無い)。
 */
const IN_FLIGHT = /[✻✽✢✶✳][^\n]*…/;

/** 末尾の空行を落とす(capture-pane は下に空行を付けてくることがある)。 */
function trimTail(lines) {
  let end = lines.length;
  while (end > 0 && lines[end - 1].trim() === "") end--;
  return lines.slice(0, end);
}

/**
 * composer の行番号。**下部にあり、上下を罫線で挟まれた `❯` 行**だけを認める。
 *
 * 「`❯` がある = 入力できる」ではない。応答本文が Claude Code の画面を引用していれば
 * 同じ字は出る(この案件の設計文書がまさにそれ)。罫線で挟まれている・画面の下部にある、
 * という**構造**まで見て初めて実在の入力欄と言える。
 * @returns {number} 行番号。無ければ -1
 */
export function findComposer(text) {
  const lines = trimTail(String(text || "").split("\n"));
  const floor = Math.max(0, lines.length - 8); // 下部限定 = 引用された画面を拾わない
  for (let i = lines.length - 2; i >= floor; i--) {
    if (!COMPOSER_HEAD.test(lines[i])) continue;
    if (BOX_RULE.test(lines[i - 1] ?? "") && BOX_RULE.test(lines[i + 1] ?? "")) return i;
  }
  return -1;
}

/**
 * 選択メニューが出ているか。**2つ以上の番号行が近接**し、そのいずれかに選択カーソルが
 * 載っていること(または強い文言 + 番号行)を要求する。
 *
 * なぜ「番号行1つ」で CHOICE にしないか: 電話から `1. まずテストを直して` と送ると、
 * その本文が `❯ 1. まずテストを直して` として画面に出る。1つで CHOICE にすると
 * **自分が送った本文でそのペインが送信不能になる**。実在するメニューは必ず2択以上なので、
 * 2つ以上を要求しても実物は取り逃さない。逆に応答本文の箇条書きは番号行が複数でも
 * **カーソルが載らない**ので当たらない。両方の誤検知がこの1条件で消える。
 *
 * 強い文言の側に番号行を要求するのは、文言だけで遮断すると「応答本文にその語が出た画面」で
 * 送信不能になるため。文言は、カーソルの字体が想定と違った時の保険として残す。
 */
export function menuAt(text) {
  const lines = trimTail(String(text || "").split("\n"));
  const opts = [];
  for (let i = 0; i < lines.length; i++) {
    if (OPTION_ROW.test(lines[i])) opts.push({ i, cursor: SELECT_CURSOR.test(lines[i]) });
  }
  if (opts.length === 0) return false;
  if (CHOICE_PHRASE.test(lines.join("\n"))) return true; // 文言 + 番号行
  for (const o of opts) {
    const cluster = opts.filter((x) => x.i >= o.i && x.i <= o.i + 6);
    if (cluster.length >= 2 && cluster.some((x) => x.cursor)) return true;
  }
  return false;
}

/**
 * 画面から「今このペインに何をしてよいか」を決める。純関数。
 *
 * @returns {{state:"SENDABLE"|"CHOICE"|"UNKNOWN", activity:"observed"|"unknown", composer:number}}
 *   state    送信可否。**SENDABLE 以外は送らない**(fail-closed)
 *   activity 生成中を**観測できたか**。observed でないことは待機中を意味しない(M3)
 *   composer composer の行番号(-1 = 無い)
 */
export function classifyScreen(text) {
  const s = typeof text === "string" ? text : "";
  const activity = IN_FLIGHT.test(s) ? "observed" : "unknown";
  if (s.trim() === "") return { state: "UNKNOWN", activity, composer: -1 };
  // メニューを最優先。ここを取りこぼすと Enter が課金や承認になる。
  if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };
  const composer = findComposer(s);
  if (composer < 0) return { state: "UNKNOWN", activity, composer: -1 };
  return { state: "SENDABLE", activity, composer };
}

/** composer に今載っている文字列(`❯` を除く)。無ければ null。 */
export function composerText(text) {
  const i = findComposer(text);
  if (i < 0) return null;
  return String(text).split("\n")[i].replace(/^\s*❯\s?/, "");
}

// 区切りはタブ。cwd に空白が入りうるので空白分割は使えない(実在する: "/Users/tom/My Docs")。
// 対象は #{pane_id}(= "%12" 形式)。session:window.pane と違いウィンドウ番号の振り直しで動かない。
const PANE_FORMAT = "#{pane_id}\t#{pane_current_command}\t#{pane_current_path}";

/** list-panes の出力を行ごとに構造化する。純関数。 */
export function parsePaneList(out) {
  const panes = [];
  for (const line of String(out || "").split("\n")) {
    if (!line.trim()) continue;
    const [pane, command, ...rest] = line.split("\t");
    if (!pane || rest.length === 0) continue;
    panes.push({ pane, command: command || "", path: rest.join("\t") });
  }
  return panes;
}

/**
 * そのペインで動いているのが Claude Code か。
 *
 * 2026-07-31 edith 実測: 対話 claude のペインは `pane_current_command` が `2.1.220`。
 * Claude Code が自身のバージョンをプロセス名にしているため、名前での照合はできない。
 * よって「semver 形か、claude/node と名乗るもの」だけを通す**許可制**にする。
 * 未知の名前は通さない(拒否側に倒す)= zsh/bash/vim 等への誤注入がここで止まる。
 */
export function looksLikeClaudePane(command) {
  const c = String(command || "").trim();
  if (!c) return false;
  if (/^\d+\.\d+\.\d+/.test(c)) return true; // 実測の形
  return /^(claude|node)$/i.test(c);
}

/** 本文の「これが載ったか」を確かめるための短い印。長文・折り返しに強い先頭 12 文字。 */
function probeOf(text) {
  const t = String(text).trim();
  return t.slice(0, 12);
}
function countOf(haystack, needle) {
  if (!needle) return 0;
  return String(haystack).split(needle).length - 1;
}

/**
 * 画面の描き直しを待つ上限。**実測から決めた値**(2026-08-01、本物の tmux + 2.1.220)。
 *
 * `send-keys -l` の直後に撮ると本文はまだ画面に無い。12 回測って
 * min 8ms / median 9ms / max 77ms(idle)。生成中は描画が遅れうるので余裕を厚く取り、
 * 実測最大の約 20 倍を上限にする。**待ち切れなかった時は送らない**(= 安全側)ので、
 * この値は「誤って Enter を押す確率」ではなく「諦めるまでの時間」しか決めない。
 *
 * 初回の点検は待つ前に行うので、偽 tmux(即時反映)では 1ms も待たない。
 */
const ECHO_BUDGET_MS = 1500;
const ECHO_POLL_MS = 25;

export class TmuxInjector {
  /**
   * @param {object} opts
   * @param {{run:(args:string[])=>string}} opts.tmux tmux 実行の注入(テスト容易性)
   * @param {number} [opts.echoBudgetMs] 画面反映を待つ上限
   * @param {(ms:number)=>Promise<void>} [opts.sleep] 待ちの注入
   */
  constructor({ tmux, echoBudgetMs = ECHO_BUDGET_MS, sleep } = {}) {
    if (!tmux || typeof tmux.run !== "function") {
      throw new Error("TmuxInjector: tmux runner injection required");
    }
    this.tmux = tmux;
    this.echoBudgetMs = echoBudgetMs;
    this.sleep = sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
  }

  /**
   * 何かが確定するまで画面を撮り直す。**最初の1枚は待たずに撮る**ので、
   * 即時反映の環境(テストの偽 tmux)では待ち時間ゼロで抜ける。
   *
   * @param {string} pane
   * @param {(text:string)=>(string|null)} decide 確定したら理由の札を返す。未確定は null
   * @returns {Promise<{tag:(string|null), text:string, waited:number}>} tag=null は時間切れ
   */
  async pollScreen(pane, decide) {
    const t0 = Date.now();
    for (;;) {
      const text = this.capture(pane);
      const tag = decide(text);
      if (tag) return { tag, text, waited: Date.now() - t0 };
      if (Date.now() - t0 >= this.echoBudgetMs) return { tag: null, text, waited: Date.now() - t0 };
      await this.sleep(ECHO_POLL_MS);
    }
  }

  /** 今の viewport。**scrollback は読まない**(過去の行を今の状態と読む失敗を構造的に消す)。 */
  capture(pane) {
    return this.tmux.run(["capture-pane", "-t", pane, "-p"]);
  }

  /** 今の画面状態。送信の可否はここだけを根拠にする。 */
  state(pane) {
    return classifyScreen(this.capture(pane));
  }

  /**
   * 本文を送る。**送る前に測り、送った後に確かめる**3相の手続き。
   *
   * Codex 指摘①(分類 → 本文 → Enter の間に modal が割り込むと Enter が承認になる)は実在する。
   * 対策として「本文と Enter を1回にまとめる」は採らない — まとめても何も観測しないので
   * 競合が縮むだけで、しかも規約1(生成中の一括送信は完了後に誤送信される)と衝突する。
   * 代わりに**間に観測を挟む**。これは Codex 指摘③(send-keys の成功はバイトが届いた証明で
   * あって Claude が受け取った証明ではない)への回答も兼ねる。
   *
   * ★2026-08-01 実機で判明: **画面の描き直しは同期しない**。`send-keys -l` の直後に撮ると
   * 本文はまだ映っておらず、初版はここで毎回 `composer-mismatch` を返して Enter を押さずに
   * 終わっていた(偽 tmux は即時反映なので緑のままだった = テストが届いていなかった型)。
   * → 観測を「1枚だけ撮る」から「確定するまで撮り直す」に変える。上限は実測由来(§ECHO_BUDGET_MS)。
   *
   * @returns {Promise<{sent:boolean, state:string, delivered:("verified"|"unverified"|null), reason:(string|null), waited?:object}>}
   */
  async send(pane, text) {
    const before = this.capture(pane);
    const s0 = classifyScreen(before);
    if (s0.state !== "SENDABLE") {
      return { sent: false, state: s0.state, delivered: null, reason: s0.state.toLowerCase() };
    }

    const probe = probeOf(text);
    const seenBefore = countOf(before, probe);

    this.tmux.run(["send-keys", "-t", pane, "-l", "--", text]);

    // ★Enter を送る前に、本文が実際に載ったのを見届ける。載る前に選択画面が
    // 割り込んでいたら、そこで打ち切る(Enter を押せば承認や課金になる)。
    const echo = await this.pollScreen(pane, (t) => {
      if (menuAt(t)) return "modal";
      if (countOf(t, probe) > seenBefore) return "echoed";
      return null;
    });
    if (echo.tag === "modal") {
      return { sent: false, state: "CHOICE", delivered: null, reason: "modal-appeared" };
    }
    if (echo.tag !== "echoed") {
      // 上限まで待っても本文が増えない = ペインに入っていない。Enter を送る理由が無い。
      const s1 = classifyScreen(echo.text);
      return { sent: false, state: s1.state, delivered: null, reason: "composer-mismatch" };
    }

    this.tmux.run(["send-keys", "-t", pane, "Enter"]);

    // 送信後: composer から本文が消えていれば消費された(即送信 or TUI のキュー入り)。
    // ここも描き直し待ちが要る。composer 自体が消えていた場合は**確かめられなかった**ので、
    // 「本文が見えない」を「送れた」と読まない(この層で二度踏んだ誤り)。
    const gone = await this.pollScreen(pane, (t) => {
      const left = composerText(t);
      return left !== null && !left.includes(probe) ? "cleared" : null;
    });
    return {
      sent: true,
      state: s0.state,
      delivered: gone.tag === "cleared" ? "verified" : "unverified",
      reason: null,
      waited: { echo: echo.waited, clear: gone.waited },
    };
  }

  /** 割り込み。規約3: Escape のみ。C-c はここでは送らない。 */
  interrupt(pane) {
    this.tmux.run(["send-keys", "-t", pane, "Escape"]);
    return true;
  }

  /** 今ある全ペイン。1回の tmux 呼び出しで取り、呼び側で使い回す。 */
  listPanes() {
    return parsePaneList(this.tmux.run(["list-panes", "-a", "-F", PANE_FORMAT]));
  }

  /**
   * 会話(cwd)から注入先ペインを決める。**曖昧なら決めない**。
   *
   * 2026-07-31 実測で分かったこと:
   *   - 対話 claude のペインは `pane_current_command` が **`2.1.220`**(バージョン文字列)。
   *     `claude` でも `node` でもない → 「cwd が一致したペイン」だけで送ると、
   *     同じ cwd に居る**素の zsh ペインに本文と Enter を打ち込む**(= 任意コマンド実行)。
   *   - 同じ cwd で claude を2つ開くのは普通にある → 先頭一致で決めると**別の会話に届く**。
   * どちらも「送ってから気づく」類なので、ここは決められない時に null を返す(fail-closed)。
   *
   * @returns {{pane: string|null, reason: "ok"|"none"|"not-claude"|"ambiguous", candidates: number}}
   */
  resolvePane(cwd, panes = this.listPanes()) {
    if (!cwd) return { pane: null, reason: "none", candidates: 0 };
    const atCwd = panes.filter((p) => p.path === cwd);
    if (atCwd.length === 0) return { pane: null, reason: "none", candidates: 0 };
    const claudePanes = atCwd.filter((p) => looksLikeClaudePane(p.command));
    if (claudePanes.length === 0) {
      // cwd は合うが claude ではない = シェル等。ここに送ると事故る。
      return { pane: null, reason: "not-claude", candidates: atCwd.length };
    }
    if (claudePanes.length > 1) {
      // どの会話か決められない。cwd だけでは原理的に解けない(→ 登録簿が要る)。
      return { pane: null, reason: "ambiguous", candidates: claudePanes.length };
    }
    return { pane: claudePanes[0].pane, reason: "ok", candidates: 1 };
  }

  /** 後方互換の薄い糖衣。決められない時は null(理由は resolvePane で取る)。 */
  findPaneByCwd(cwd) {
    return this.resolvePane(cwd).pane;
  }
}
