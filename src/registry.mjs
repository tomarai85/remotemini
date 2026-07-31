// ペイン登録簿 — 「この会話は今どの tmux ペインに居るか」を会話自身に名乗らせた記録を読む。
//
// なぜ登録簿が要るか(2026-07-31 実測。DESIGN.md §2.10):
//   cwd 一致では会話を特定できない。直近7日のセッションは ~/.claude に192件・~ に78件が
//   同じ cwd = 同じ場所で claude を複数開くのが常態。プロセス名でも無理で、対話 claude の
//   `pane_current_command` は "2.1.220"(バージョン文字列)。jsonl は開きっぱなしでなく
//   (lsof=0)、argv も素の `claude`。外から辿る手が存在しない。
//   → 会話自身に名乗らせる。書き手は ~/.claude/statusline.sh の rc-backend ブロックで、
//     tmux 内で動いている時だけ ~/.rc-backend/panes/<session_id>.json を置く。
//
// 読み側(このファイル)の原則: **登録簿を信じ切らない**。
//   書かれた瞬間は正しくても、そのペインで別の会話が始まれば古くなる。矛盾を見つけたら
//   「たぶんこれだろう」で埋めず、決められないと言う(fail-closed)。誤ると別の会話に
//   本文が入る = 取り返しがつかない類の事故。

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

/** 1ファイル分の JSON を検証して構造化する。壊れていれば null。純関数。 */
export function parseEntry(text, mtimeMs) {
  let obj;
  try {
    obj = JSON.parse(text);
  } catch {
    return null; // 書き込み途中を読んだ等。次の周期で読み直せばよい。
  }
  const sessionId = typeof obj?.session_id === "string" ? obj.session_id : "";
  const pane = typeof obj?.pane === "string" ? obj.pane : "";
  // pane は tmux の #{pane_id} = "%12" 形式。それ以外は受け付けない。
  if (!/^[0-9a-f-]{8,64}$/i.test(sessionId)) return null;
  if (!/^%\d+$/.test(pane)) return null;
  return {
    sessionId,
    pane,
    model: typeof obj?.model === "string" ? obj.model : "",
    mtimeMs: Number(mtimeMs) || 0,
  };
}

/** 登録簿ディレクトリを読む。読めない/無いは「登録ゼロ」として扱い、落とさない。 */
export function readRegistry(dir, fs = { readdirSync, readFileSync, statSync }) {
  let names;
  try {
    names = fs.readdirSync(dir);
  } catch {
    return []; // 登録簿がまだ無い = 全会話が cwd 経路にフォールバックするだけ
  }
  const entries = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    const p = join(dir, name);
    try {
      const e = parseEntry(fs.readFileSync(p, "utf8"), fs.statSync(p).mtimeMs);
      // ファイル名と中身の session_id が食い違う登録は捨てる(取り違えの温床)
      if (e && `${e.sessionId}.json` === name) entries.push(e);
    } catch {
      continue; // 消えた/読めない1件で全体を落とさない
    }
  }
  return entries;
}

/**
 * 会話 -> ペインを決める。登録簿を第一候補にし、矛盾があれば決めない。
 *
 * 返り値の reason は**扱いが分岐する**ので潰さないこと:
 *   ok            -> そのペインへ注入してよい
 *   none          -> tmux に居ない。ワーカー経路(-p --resume)に落として安全
 *   not-claude    -> そのペインは claude ではない(claude が終了しシェルに戻った等)。ワーカー経路
 *   ambiguous     -> cwd 経路で複数候補。どれか決められない
 *   stale         -> 登録簿が現実と矛盾(同じペインをより新しい会話が名乗っている)。
 *                    ワーカーにも落とさない — その会話が別ペインで開いたままの可能性を
 *                    否定できず、落とすと同じ会話を2プロセスが触る(lost-update)。
 *   cwd-mismatch  -> 登録されたペインの居場所が会話の cwd と違う。同上の理由で決めない。
 *
 * @param {object} a
 * @param {string} a.sessionId
 * @param {string} a.cwd            会話の cwd(jsonl 由来。空なら突き合わせを省く)
 * @param {Array}  a.entries        readRegistry() の結果
 * @param {Array}  a.panes          TmuxInjector#listPanes() の結果
 * @param {(cmd:string)=>boolean} a.isClaude
 * @param {(cwd:string, panes:Array)=>object} a.resolveByCwd 登録が無い時のフォールバック
 */
export function resolveSessionPane({ sessionId, cwd, entries, panes, isClaude, resolveByCwd }) {
  const entry = entries.find((e) => e.sessionId === sessionId);

  if (!entry) {
    // 登録が無い = この会話は登録機構の入る前から開いている、または tmux 外。
    // cwd 経路に落とすが、**他の会話が名乗り済みのペインは候補から外す**。
    // 候補が減る方向にしか動かないので、素の cwd 一致より必ず安全側。
    const claimed = new Set(entries.map((e) => e.pane));
    const free = panes.filter((p) => !claimed.has(p.pane));
    return { ...resolveByCwd(cwd, free), source: "cwd" };
  }

  const info = panes.find((p) => p.pane === entry.pane);
  if (!info) {
    // 登録時のペインが消えている = その会話の TUI はもう無い。ワーカー経路でよい。
    return { pane: null, reason: "none", candidates: 0, source: "registry" };
  }
  if (!isClaude(info.command)) {
    // ペインは在るが claude ではない(終了してシェルに戻った)。注入したら任意コマンド実行。
    return { pane: null, reason: "not-claude", candidates: 1, source: "registry" };
  }

  // 同じペインを名乗る、より新しい登録があるか。あれば**この登録が古い**。
  // (ペインが別の会話に使い回された時にここで捕まる)
  const newer = entries.find(
    (e) => e.pane === entry.pane && e.sessionId !== sessionId && e.mtimeMs > entry.mtimeMs,
  );
  if (newer) {
    return { pane: null, reason: "stale", candidates: 0, source: "registry", takenBy: newer.sessionId };
  }

  // 居場所の突き合わせ。会話の cwd と、そのペインの現在地が違うなら登録を信じない。
  if (cwd && info.path !== cwd) {
    return { pane: null, reason: "cwd-mismatch", candidates: 0, source: "registry", panePath: info.path };
  }

  return { pane: entry.pane, reason: "ok", candidates: 1, source: "registry" };
}

/**
 * 「開いたばかりでまだ一度も発言していない会話」を一覧に足す。
 *
 * なぜ必要か(2026-07-31 edith 実測): transcript の jsonl は**最初のメッセージが入るまで
 * 作られない**。一覧は jsonl の走査で作っているので、Tom が edith でセッションを開いて
 * 席を立った状態は電話から見えない。だが登録簿には居るので、ペインは分かっている
 * = 電話から最初の一言を送れる。Tom 裁定「返答待ちであれ作業中であれいつでも見て、
 * 干渉できればいい」に照らすと、ここが見えないのは穴。
 *
 * 採用条件は resolveSessionPane に委ねる(判定を二重に書かない)。
 * cwd は jsonl が無いので突き合わせられない → ペインの現在地をその会話の cwd として採る。
 */
export function registryOnlySessions({ listing, entries, panes, isClaude }) {
  const known = new Set(listing.map((s) => s.id));
  const out = [];
  for (const e of entries) {
    if (known.has(e.sessionId)) continue;
    const r = resolveSessionPane({
      sessionId: e.sessionId,
      cwd: "", // 突き合わせる相手が無い(jsonl が未生成)
      entries,
      panes,
      isClaude,
      resolveByCwd: () => ({ pane: null, reason: "none", candidates: 0 }),
    });
    if (r.reason !== "ok") continue; // stale / not-claude / 消えたペインは出さない
    const info = panes.find((p) => p.pane === e.pane);
    out.push({
      id: e.sessionId,
      project: null,
      cwd: info?.path || "",
      // 中身が無いので中身から題を作れない。何であるかをそのまま書く。
      title: "(未発言)",
      lastPrompt: "",
      turns: 0,
      updatedAt: new Date(e.mtimeMs).toISOString(),
      fromRegistryOnly: true,
    });
  }
  return out.sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1));
}

/** fs を持つ薄い読み手。サーバはこれを1リクエストにつき1回叩く。 */
export class PaneRegistry {
  constructor({ dir, fs }) {
    this.dir = dir;
    this.fs = fs;
  }
  read() {
    return readRegistry(this.dir, this.fs);
  }
}
