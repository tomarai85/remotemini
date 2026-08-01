// プロセスの実測 — 「そのペインに今どのプロセスが居るか」を**名前でなく観測**で答える。
//
// なぜ要るか(2026-08-01 実測):
//   tmux の `#{pane_current_command}` は、その tty の**前面プロセスグループのリーダ**の名前。
//   claude を直接起動している機械ではそれが "2.1.220"(バージョン文字列)になるが、
//   MBP は `claude` が retry ラッパ(bash スクリプト、exec せず子として起動)への alias なので
//   リーダは bash であり、`#{pane_current_command}` は "bash" になる。
//   同じ艦隊の2台で違う値が出る = 名前は同一性の材料にならない。
//
//   影響は片側だけではない:
//     - 「このペインは claude か」を名前で偽と判定 -> 生きている登録済みの会話を拒否(送れない)
//     - 「近くに生きた claude が居るか」を名前で偽と判定 -> 開いたままの TUI に対して
//       ワーカー(`claude -p --resume`)を起こす = 同じ会話を2プロセスが触る(lost-update)
//   後者は危険側なので、名前ではなく ps の実測で答える。
//
// この file は node の API を一切 import しない(runner を渡してもらう)。テストで
// 固定文字列を流し込めるようにするため。

/** ps の tty("ttys000")と tmux の #{pane_tty}("/dev/ttys000")を突き合わせる形に揃える。 */
export const normTty = (s) => String(s || "").replace(/^\/dev\//, "");

// `ps -axww -o pid=,tty=,pgid=,tpgid=,lstart=,command=` の1行。
// lstart は "Fri Aug  1 15:57:05 2026"(日が1桁だと空白2つ)。command は空白を含むので最後。
const PS_LINE =
  /^\s*(\d+)\s+(\S+)\s+(\d+)\s+(\d+)\s+([A-Za-z]{3} [A-Za-z]{3} [ \d]\d \d{2}:\d{2}:\d{2} \d{4})\s+(.*)$/;

export const PS_ARGS = ["-axww", "-o", "pid=,tty=,pgid=,tpgid=,lstart=,command="];

/**
 * 「この command は claude か」の**広い方**の判定。argv に claude が入っていれば真。
 *
 * 広いので `vim claude-notes.md` も真になる(Codex 2026-08-01 の指摘)。それを承知で広く採る:
 * この判定の用途は**ワーカーを起こさない理由**を探すことだけで、偽陽性の代償は「送れない」、
 * 偽陰性の代償は「開いている会話への二重実行」。代償が非対称なので広い側に倒す。
 * **注入の許可には使わない**(許可は登録簿の同一性検証だけが出せる)。
 */
export const looksLikeClaudeProc = (command) => /claude/i.test(String(command || ""));

/**
 * ps の出力を構造化する。純関数。
 * @returns {{ byPid: Map<number, object>, claudeTtys: Set<string> }}
 */
export function parsePs(text) {
  const byPid = new Map();
  const claudeTtys = new Set();
  for (const line of String(text || "").split("\n")) {
    const m = PS_LINE.exec(line);
    if (!m) continue;
    const [, pid, tty, pgid, tpgid, lstart, command] = m;
    const startMs = Date.parse(lstart);
    const rec = {
      pid: Number(pid),
      tty: normTty(tty),
      // 前面か。tty を握っているだけでは足りない: Ctrl-Z で止めた claude は tty を
      // 握ったままなので(実測)、tty 一致だけでは今前面に居る別プロセスに送ってしまう。
      foreground: pgid === tpgid,
      // プロセスの誕生時刻。pid は使い回されるので、pid だけでは「登録した時と同じ実体か」を
      // 言えない(Codex 2026-08-01 の指摘)。誕生時刻を足すと pid + 誕生時刻で一意になる。
      startMs: Number.isFinite(startMs) ? startMs : 0,
      command,
    };
    byPid.set(rec.pid, rec);
    if (rec.tty !== "??" && rec.foreground && looksLikeClaudeProc(command)) claudeTtys.add(rec.tty);
  }
  return { byPid, claudeTtys };
}

/**
 * ps を1回だけ叩いて、pid 引きと「claude が前面に居る tty の集合」を作る。
 *
 * available=false は「死んでいる」ではなく「**分からない**」。呼び手はこれを死と読んではいけない
 * (Codex 2026-08-01: "Unknown must mean do not spawn")。分からない時は心拍にフォールバックし、
 * ワーカーを起こす側には倒さない。
 *
 * @param {(args: string[]) => string} run ps を実行して stdout を返す
 */
export function psSnapshot(run) {
  let out;
  try {
    out = run(PS_ARGS);
  } catch {
    return { available: false, procOf: () => null, claudeTtys: null };
  }
  const { byPid, claudeTtys } = parsePs(out);
  if (byPid.size === 0) return { available: false, procOf: () => null, claudeTtys: null };
  return { available: true, procOf: (pid) => byPid.get(pid) || null, claudeTtys };
}
