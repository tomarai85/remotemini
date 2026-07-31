// tmux 注入層 — 動いている対話 Claude に iPhone からの入力を届ける。
//
// なぜこの形か(DESIGN.md §2.9):
//   Tom 裁定「返答待ちであれ作業中であれいつでも見て干渉できればいい」。
//   別プロセスで claude -p を起こすと同じ会話を2実行が読む(lost-update)。
//   動いているペインに直接注入すれば会話は1プロセスのままで、その問題が原理的に消える。
//
// 実機で確かめたこと(2026-07-31, edith 使い捨てセッション):
//   - send-keys -l で本文、別コマンドで Enter → 入力欄に入り送信まで到達した
//   - 上限到達時に選択肢画面が出る。ここに Enter を送ると
//     "2. Switch to usage credits" を選びかねない = 課金事故。だから CHOICE は絶対に送らない。
//
// Codex レビュー(同日)で確定した3規約をそのまま実装している:
//   1. 本文と Enter は別送信(生成中の一括送信はバッファされ、完了後に誤送信される)
//   2. 「入力受付中か」を知る確実な tmux API は無い → 状態不明なら送らない(fail-closed)
//   3. 割り込みは Escape。C-c は画面状態で消去/中断/終了に化けるので緊急専用

/** 画面テキストから「今なら何を送ってよいか」を判定する。純関数。 */
export function classifyPane(text) {
  if (typeof text !== "string" || text.trim() === "") return "UNKNOWN";

  // CHOICE を最優先で見る。ここを取りこぼすと課金や誤承認に直結するため、
  // 他のどの状態よりも先に判定する(READY の記号が同じ画面に混在しても CHOICE が勝つ)。
  const choiceSignals = [
    /Enter to confirm/i,
    /What do you want to do\?/i,
    /Do you want to (proceed|continue)/i,
    /^\s*[❯>]?\s*\d\.\s+\S/m, // 番号付き選択肢
  ];
  if (choiceSignals.some((re) => re.test(text))) return "CHOICE";

  // BUSY: 生成中。判定材料は "esc to interrupt" **だけ**にする。
  //
  // かつてここに「スピナー記号 + "... for N秒"」の行を BUSY と見なす規則があった。
  // それは生成中の行ではなく**完了行**に当たる(2026-07-31 edith 実機で判明):
  //   生成中  "✻ Baking… (12s · esc to interrupt)"   ← 下の規則が捕まえる
  //   完了後  "✻ Baked for 0s"                        ← 過去形。scrollback に残り続ける
  // 完了行は消えないので、一度でも喋ったペインが永久に BUSY になっていた。実測: 画面は
  // 入力待ち、/status は BUSY、送った本文は queued:true のままペインに 0 件しか届かず、
  // キューは READY でしか流れないので**永久に滞留**する。電話から復旧する手段は無い。
  // しかも週次上限に当たった画面がまさにこの形 = 渡米中に必ず踏む。
  // 削除の代償(生成中に "esc to interrupt" を出さない画面があれば送ってしまう)は、
  // 本文と Enter を別送信しているので人が生成中に打つのと同じ挙動に落ち着き、
  // 課金事故に繋がる CHOICE は上で先に弾いている。Codex 同意(同日)。
  // 今後 BUSY の変種を実測したら、過去形を巻き込まない「進行中の形」だけを足すこと。
  if (/esc to interrupt/i.test(text)) return "BUSY";

  // READY: 入力プロンプトが見えている。
  if (/^\s*❯\s/m.test(text) || /shortcuts/i.test(text)) return "READY";

  return "UNKNOWN";
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

export class TmuxInjector {
  /**
   * @param {object} opts
   * @param {{run:(args:string[])=>string}} opts.tmux tmux 実行の注入(テスト容易性)
   * @param {number} [opts.captureLines] 判定に使う末尾行数
   */
  constructor({ tmux, captureLines = 30 }) {
    if (!tmux || typeof tmux.run !== "function") {
      throw new Error("TmuxInjector: tmux runner injection required");
    }
    this.tmux = tmux;
    this.captureLines = captureLines;
    this.queues = new Map(); // pane -> string[]
  }

  /** 今の画面状態。送信の可否はここだけを根拠にする。 */
  state(pane) {
    const text = this.tmux.run(["capture-pane", "-t", pane, "-p", "-S", `-${this.captureLines}`]);
    return classifyPane(text);
  }

  pending(pane) {
    return this.queues.get(pane) || [];
  }

  _enqueue(pane, text) {
    const q = this.queues.get(pane) || [];
    q.push(text);
    this.queues.set(pane, q);
  }

  /**
   * 本文を送る。READY の時だけ実際に送信し、それ以外はキューに積む。
   * CHOICE / UNKNOWN では**何も送らない**(fail-closed)。
   */
  send(pane, text) {
    const st = this.state(pane);
    if (st !== "READY") {
      // CHOICE は人が画面を見て選ぶべき状態。キューに積むと後で誤爆するので積まない。
      if (st === "CHOICE") return { sent: false, queued: false, state: st };
      this._enqueue(pane, text);
      return { sent: false, queued: true, state: st };
    }
    this._write(pane, text);
    return { sent: true, queued: false, state: st };
  }

  _write(pane, text) {
    // 規約1: 本文はリテラル、Enter は別コマンド。まとめない。
    this.tmux.run(["send-keys", "-t", pane, "-l", "--", text]);
    this.tmux.run(["send-keys", "-t", pane, "Enter"]);
  }

  /**
   * キューを1件だけ流す。READY でなければ何もしない。
   * 一度に1件なのは、連続送信が誤爆の主因だから(規約1・3)。
   * @returns {number} 実際に送った件数(0 or 1)
   */
  drain(pane) {
    const q = this.queues.get(pane);
    if (!q || q.length === 0) return 0;
    if (this.state(pane) !== "READY") return 0;
    this._write(pane, q.shift());
    return 1;
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
