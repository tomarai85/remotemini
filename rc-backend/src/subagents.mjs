// subagents.mjs — 「この会話の下で今 何が走っているか」を**ディスクだけ**から読む。2026-09-04 新設。
//
// なぜ要るか(research/subagent-stop-panel-design-2026-09-04.md「半分その一」)
//   公式の Remote Control は端末に「そのセッションが背後で走らせている subagent」を出す。
//   机はそれを一度も出していない。列挙は**打鍵を1つも要らない** —— 子は自分の転写を
//   親の隣に書くので、読むだけで済む。停止(`x` を押す方)とは切り離して出荷できる。
//
// ── 置き場所(実測 2026-09-04、~/.claude/projects 配下 64 セッション / 991 subagent)──
//   親  : <projects>/<slug>/<sessionId>.jsonl
//   子  : <projects>/<slug>/<sessionId>/subagents/agent-<agentId>.jsonl
//         + 同名の .meta.json
//   拡張子を落とした**同じ幹**の下に `subagents/` が生える。親 file と子の dir は兄弟。
//
// ── ★meta の鍵について、設計文書の記述を実測で訂正した ────────────────────
//   引き継ぎ文は「meta は `agentType` と `description` の**ちょうど2鍵**」と書いていた。
//   1082 本を数えると、その2つは確かに**全件に在る**が、ちょうど2鍵なのは 182 本だけ。
//   残りは `spawnDepth`(900) `model`(568) `toolUseId`(497) `name`(424)
//   `taskKind`/`teamName`/`color`/`permissionMode`(各 402)… と増える。
//   つまり正しい読み方は「**在ると当てにしてよいのは2つだけ**」。ここでは其の2つだけを
//   拾い、他は読まない —— 無い物を鍵にすると、無い会話で黙って null が並ぶ。
//
// ── ★生死の規則は、引き継ぎ文の記述だと**逆向きに嘘をつく** ──────────────
//   引き継ぎ文: 「親の `tool_result` が子の agentId を名乗っていたら終了」。
//   実測するとこれは成り立たない。親が agentId を名乗る `toolUseResult` には
//   **`status` が2種類**在って(991 本の走査):
//     - `status:"async_launched"`(294) = **起動した瞬間**に名乗る。まだ走っている。
//     - `status:"completed"`   (217) = 終わった時に名乗る。
//   名乗られた事だけを見ると、起動直後の agent が全部「終了」になる —— 走っている物を
//   「終わった」と報告するのは、この機能が防ごうとしている誤りの**ちょうど裏返し**で、
//   しかも害は大きい(Tom は待つのをやめる)。だから見るのは名前ではなく `status`。
//
//   もう一つの終了の形が `<task-notification>` の user 行で、`<task-id>` と
//   `<status>completed</status>` を持つ。背後起動(async)の agent はこちらで終わる。
//   両方を終了の証拠として数える。
//
//   ★そして 991 本中 **485 本(49%)は親のどこにも出て来ない**(`in_process_teammate`)。
//   親の記録だけを生死の材料にすると、其の半分は永遠に「走っている」になる。
//   mtime による第3の状態が飾りではなく**主戦場**なのは此の為。
import { closeSync, openSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { nodeIo, readLinesBackward, TAIL_MAX, LINE_CAP_MAX } from "./listing.mjs";

/**
 * ★「最後の書き込みから此れだけ経っていたら、生きている証拠は無い」の境目。
 *
 * 15 分にした理由(何を測って決めたか):
 *   子の転写は、子が道具を呼ぶ度・喋る度に伸びる。だから「伸びていない時間」の上限は
 *   **子が1手に掛けうる最長時間**で決まる。此の repo の道具で一番長く黙れるのは
 *   `Bash` の timeout(上限 600000ms = 10 分)で、其の前後にモデルの応答待ちが乗る。
 *   10 分 + 余裕 = 15 分。
 *
 * ★外した時に何を失うか、両側を書く(片側だけ考えると必ず短くしたくなる):
 *   短すぎる(例 2 分)と、10 分の `Bash` を回している**生きた** agent が `stalled` に
 *     なる。Tom は届く筈の結果を待つのをやめる。「動いていない」と言われた物が実は
 *     動いていた、という向きの嘘。
 *   長すぎる(例 6 時間)と、死んだ agent が 6 時間 `running` を名乗る。Tom は来ない
 *     結果を待つ。
 *
 * ★どちらも**同じ一つの誤り**で、其れは「ログの最終行を健康診断として読む」事。
 *   mtime が言えるのは「最後に書いた時刻」だけで、「今 生きているか」では無い。
 *   だから `stalled` は「死んだ」ではなく「**最近 生きている証拠が無い**」と読む語で、
 *   文面(下の `SUBAGENT_STATE_TEXT`)も其の通りに書く。死んだ agent を「作業中」と
 *   出すのは、最終行を健康診断と読んだ時に起きる事そのもので、此の3値はその為に在る。
 */
export const SUBAGENT_STALE_MS = 15 * 60 * 1000;

/**
 * 机が止めたのを見た後、転写に最後の数行が書かれる猶予。実測(2026-09-07 friday、single run1 / shell run4)では x の直後から
 * 転写のサイズは 1 byte も動かなかったので 5 秒は十分に広い。此れを超えて書かれたら「止まっていない」と読む。
 */
export const DESK_STOP_GRACE_MS = 5_000;
/** 机の記憶の寿命。此れを過ぎれば mtime の 3 値に戻る(親が終了を記録すれば其方が先に勝つ)。 */
export const DESK_STOP_TTL_MS = 60 * 60 * 1000;

/**
 * 「机が止めた agent」の記憶(session の転写 path → agentId → 止めた時刻)。プロセス内だけ。
 * 電話の一覧は転写の mtime で生死を読むので、止めた直後も最長 SUBAGENT_STALE_MS の間「Working」のままだった
 * (帯は Stopped と言うのに行は Working = 15 分の矛盾)。机は x を押してパネルで行が減ったのを見ているので、其の観測を一覧に返す。
 */
export class DeskStopMemory {
  #m = new Map();
  record(key, agentId, atMs = Date.now()) {
    if (typeof key !== "string" || typeof agentId !== "string") return;
    if (!this.#m.has(key)) this.#m.set(key, new Map());
    this.#m.get(key).set(agentId, atMs);
  }
  /** `readSubagentsFromPath` の `opts.deskStopped` にそのまま渡せる Map(期限切れは落とす)。無ければ空の Map。 */
  for(key, nowMs = Date.now()) {
    const inner = this.#m.get(key);
    if (!inner) return new Map();
    for (const [id, at] of inner) if (nowMs - at > DESK_STOP_TTL_MS) inner.delete(id);
    if (inner.size === 0) this.#m.delete(key);
    return new Map(inner);
  }
  forget(key, agentId) { this.#m.get(key)?.delete(agentId); }
  get size() { let n = 0; for (const inner of this.#m.values()) n += inner.size; return n; }
}

/**
 * 1回の応答で返す子の数の上限。teams は1セッションで数十本 spawn しうるので、
 * dir の中身をそのまま全部読むと file descriptor と時間が青天井になる。
 * ★超えた事は `truncated` で必ず名乗る(黙って切ると「これで全部」に化ける)。
 */
export const SUBAGENT_MAX = 200;

/**
 * 親の転写を後ろから舐める予算。digest(`DIGEST_SCAN_MAX`)と同じ 12 MiB。
 * ★親は 280 MB に達する(server.mjs の註)。全部読むのは論外で、末尾だけ読む。
 *   読み切れなかった範囲に在るかもしれない終了記録を「無かった」と読まない為の
 *   仕掛けが下の `coveredFrom`。
 */
export const SUBAGENT_SCAN_MAX = 12 * 1024 * 1024;

/** 子1本から model を拾う為の予算。**小さくてよい** —— 最後の数行に在れば足りる。 */
const CHILD_TAIL_MAX = 64 * 1024;

/** 状態語。電話が分岐に使うので、増やす時は電話側と一緒に。 */
export const SUBAGENT_STATES = ["finished", "running", "stalled", "unknown", "stopped", "failed"];

/**
 * 電話にそのまま出せる英文。★`unknown` を `running` や `finished` に丸めない ——
 * 「分からない」を「作業中」と書くと、読み手には観測値と区別が付かない。
 */
export const SUBAGENT_STATE_TEXT = {
  finished: "Finished",
  running: "Working",
  stalled: "No sign of life recently",
  unknown: "Could not tell",
  // ★止められた agent(2026-09-07、Codex #9): 成功の完了(finished)と混ぜない。源は親転写の `killed` か机の観測。
  stopped: "Stopped",
  // ★失敗した agent(2026-09-07 round 12): 親転写の `<status>failed</status>`(例 "Agent … failed: Agent terminated early due to an API
  //   error")。Jervis の転写 8158 completed / 470 failed のうち 42 が agent の失敗(残りは背景シェル)。成功の完了と混ぜない。
  failed: "Failed",
};

/**
 * `agent-<agentId>.jsonl` の `<agentId>`。実測の形は `af447032e47628a50` と
 * `aadversary-70a7928baf236f1d` の2系統でハイフンを含む。readdir 由来なので
 * `/` は原理的に来ないが、`.` を弾いて `..` が名前に化ける道を型で殺しておく。
 */
const AGENT_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

/** 親の転写のうち、agentId を名乗る `toolUseResult` から**終了だけ**を拾う。 */
function completionsIn(records) {
  // ★終端の記録は id ごとに**最後の物が勝つ**(records はファイルの並び = 古い順)。止められた agent は再開でき、再開して完了
  //   すれば completed が後に書かれる。逆(完了 → 再開 → 停止)も在りうる(Codex 2026-09-07 stopped-state #1)。集合で持つと
  //   歴史を失うので、終端は id → { status, ts } で持ち、`done` / `killed` は其処から導く。
  const terminal = new Map();
  const launched = new Set();
  // ★`<status>killed</status>` = Claude Code 自身が「stopped by user」と書く停止(本番 friday 2026-09-07 の attic 転写 2 本で実測、
  //   `.harness/evidence-2026-09-07/subagent-stop-cause-binding-verdict.md`)。以前は `completed` しか読まず、止めた agent は mtime で
  //   running のままだった。★`failed` は此処では読まない(背景シェルの失敗の形。agent の failed は別の題)。
  for (const rec of records) {
    const tur = rec && rec.toolUseResult;
    if (tur && typeof tur === "object" && typeof tur.agentId === "string") {
      // ★`status` を見る。名乗られた事自体は起動の証拠にしかならない(頭注)。
      if (tur.status === "completed") terminal.set(tur.agentId, { status: "completed", ts: tsOf(JSON.stringify(rec)) });
      else {
        launched.add(tur.agentId);
        // ★終端の後の起動の記録 = 再開した(Codex failed-state #4/#5: 時刻の推定でなく親転写の記録で再開を読む)。終端を捨てる。
        terminal.delete(tur.agentId);
      }
    }
    // 背後起動の agent は `<task-notification>` の user 行で終わる。
    const content = rec && rec.message && rec.message.content;
    if (typeof content === "string" && content.includes("<task-notification>")) {
      const id = /<task-id>([^<]+)<\/task-id>/.exec(content);
      if (id) {
        launched.add(id[1]);
        if (/<status>completed<\/status>/.test(content)) terminal.set(id[1], { status: "completed", ts: tsOf(JSON.stringify(rec)) });
        if (/<status>killed<\/status>/.test(content)) terminal.set(id[1], { status: "killed", ts: tsOf(JSON.stringify(rec)) });
        // ★`failed` は id で agent に束ねる(Codex 2026-09-07 failed-state #1-#3): 一覧の行は `agent-<id>.jsonl` が在る id だけなので、
        //   背景シェル(`Background command … failed`)や Monitor の failed は id が agent の転写と重ならず、行にならない。summary の文で
        //   選ぶと文言の変更や偽装で外れるので、文は読まない。
        if (/<status>failed<\/status>/.test(content)) terminal.set(id[1], { status: "failed", ts: tsOf(JSON.stringify(rec)) });
      }
    }
  }
  const done = new Set();
  const killed = new Map();   // agentId → 通知の時刻(ms)。時刻が読めなければ null
  const failed = new Map();   // 同上(agent の失敗)
  for (const [id, t] of terminal) {
    if (t.status === "completed") done.add(id);
    else if (t.status === "killed") killed.set(id, Number.isFinite(t.ts) ? t.ts : null);
    else if (t.status === "failed") failed.set(id, Number.isFinite(t.ts) ? t.ts : null);
  }
  return { done, launched, killed, failed };
}

function parseLine(ln) {
  const t = String(ln).trim();
  if (!t) return null;
  try {
    const o = JSON.parse(t);
    return o && typeof o === "object" ? o : null;
  } catch {
    return null; // 書き込み途中の末尾行。1行で全体を落とさない(sessions.mjs と同じ規約)。
  }
}

function tsOf(ln) {
  const m = /"timestamp":"([^"]+)"/.exec(String(ln));
  if (!m) return null;
  const t = Date.parse(m[1]);
  return Number.isFinite(t) ? t : null;
}

/**
 * 親の末尾を有界に読んで、終了/起動の記録と「どこまで遡れたか」を返す。
 *
 * ★`coveredFrom` が肝。**読めた範囲の一番古い時刻**で、其れより新しい出来事なら
 *   此の窓に必ず入っている。子が最後に書いた時刻が `coveredFrom` 以降なら、
 *   其の子の終了記録(在るなら最後の書き込み以降に書かれる)も窓の中に在った筈 ——
 *   つまり「見付からなかった = 本当に無い」と言い切れる。逆に子の方が古ければ、
 *   見付からない理由が「無い」なのか「予算の外」なのか**分けられない**ので `unknown`。
 */
function scanParent(path, opts = {}) {
  const fd = openSync(path, "r");
  try {
    let oldest = Infinity;
    const r = readLinesBackward(opts.io ?? nodeIo, fd, {
      chunk: opts.chunk,
      maxBytes: opts.maxBytes ?? SUBAGENT_SCAN_MAX,
      lineCap: opts.lineCap ?? LINE_CAP_MAX,
      done: (lines) => {
        for (const ln of lines) {
          const t = tsOf(ln);
          if (t !== null && t < oldest) oldest = t;
        }
        return false; // 予算いっぱいまで読む(窓の指定が無いので件数でも時刻でも止めない)
      },
    });
    const records = [];
    for (const ln of r.lines) {
      const o = parseLine(ln);
      if (o) records.push(o);
    }
    const { done, launched, killed, failed } = completionsIn(records);
    // 先頭まで届いたなら、どんなに古い子でも「見えていた」= covered。
    return { done, launched, killed, failed, coveredFrom: r.reachedStart ? -Infinity : (Number.isFinite(oldest) ? oldest : Infinity) };
  } finally {
    closeSync(fd);
  }
}

/** 子の末尾から `message.model` を拾う。読めなければ null(= 「無い」の断定ではない)。 */
function modelOf(path, opts = {}) {
  let fd;
  try {
    fd = openSync(path, "r");
  } catch {
    return null;
  }
  try {
    const r = readLinesBackward(opts.io ?? nodeIo, fd, {
      chunk: opts.chunk,
      maxBytes: opts.childMaxBytes ?? CHILD_TAIL_MAX,
      lineCap: opts.lineCap ?? TAIL_MAX,
      done: () => false,
    });
    // 後ろから前へ。★最後に喋った時の model を採る(会話の途中で切り替わりうる)。
    for (let i = r.lines.length - 1; i >= 0; i -= 1) {
      const o = parseLine(r.lines[i]);
      const m = o && o.message && o.message.model;
      if (typeof m === "string" && m) return m;
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

/**
 * 親の転写 path から、その会話の subagent 一覧を組む。**読むだけ**。
 *
 * @param {string} transcriptPath `<projects>/<slug>/<sessionId>.jsonl`
 * @param {object} [opts] `{nowMs, staleMs, io, maxBytes, chunk}`
 * @returns {{agents: object[], directory: string, parent: string, truncated: boolean, counts: object|null}}
 *
 * ★「無い」と「読めない」を混ぜない(digest.mjs の一線その1と同じ)。
 *   `directory:"absent"`   = subagents/ が無い = **本当に1本も居ない**。
 *   `directory:"unreadable"` = 在るのに読めない = 居るかもしれない。
 *   どちらも `agents: []` になるが、後者を「今 何も走っていない」と読まれると、
 *   走っている物を見落とす。だから `counts` は読めた時しか出さない —— 数を書けば
 *   読み手は其の数を信じるので、信じてよい時だけ書く。
 */
export function readSubagentsFromPath(transcriptPath, opts = {}) {
  const nowMs = opts.nowMs ?? Date.now();
  const staleMs = opts.staleMs ?? SUBAGENT_STALE_MS;
  // 机が止めたのを見た agent(agentId → 止めた時刻 ms)。`DeskStopMemory.for(key)` の形。無ければ空。
  const deskStopped = opts.deskStopped instanceof Map ? opts.deskStopped : new Map();
  const dir = subagentDirFor(transcriptPath);

  let names;
  try {
    names = readdirSync(dir);
  } catch (e) {
    // ★ENOENT だけが「居ない」。権限やそれ以外は「読めない」で、同じ空配列にしない。
    const directory = e && e.code === "ENOENT" ? "absent" : "unreadable";
    return { agents: [], directory, parent: "unscanned", truncated: false, counts: directory === "absent" ? empty() : null };
  }

  const ids = [];
  for (const n of names) {
    if (!n.startsWith("agent-") || !n.endsWith(".jsonl")) continue;
    const id = n.slice("agent-".length, -".jsonl".length);
    if (AGENT_ID_RE.test(id)) ids.push(id);
  }
  ids.sort();
  const truncated = ids.length > SUBAGENT_MAX;
  const use = truncated ? ids.slice(0, SUBAGENT_MAX) : ids;

  // 親は**1回だけ**舐める。子ごとに開き直すと、同じ答えを得る為に N 倍払う事になる。
  let parentState = "read";
  let done = new Set();
  let launched = new Set();
  let killed = new Map();
  let failed = new Map();
  let coveredFrom = Infinity;
  try {
    const s = scanParent(transcriptPath, opts);
    done = s.done;
    launched = s.launched;
    killed = s.killed;
    failed = s.failed;
    coveredFrom = s.coveredFrom;
  } catch {
    // ★親が読めない = **何が終わったか一つも知らない**。ここで `running` にも
    //   `finished` にも倒さない。倒した瞬間、観測していない事が観測値の顔で出る。
    parentState = "unreadable";
  }

  const agents = use.map((agentId) => {
    const jsonl = join(dir, `agent-${agentId}.jsonl`);
    let lastActivityMs = null;
    try {
      lastActivityMs = statSync(jsonl).mtimeMs;
    } catch {
      lastActivityMs = null;
    }

    // meta。★壊れていても此の1本を落とすだけで、一覧は返す。
    let metaState = "read";
    let agentType = null;
    let description = null;
    try {
      const parsed = JSON.parse(readTextCapped(join(dir, `agent-${agentId}.meta.json`)));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        agentType = typeof parsed.agentType === "string" ? parsed.agentType : null;
        description = typeof parsed.description === "string" ? parsed.description : null;
      } else {
        metaState = "malformed";
      }
    } catch (e) {
      metaState = e && e.code === "ENOENT" ? "absent" : "malformed";
    }

    const { state, reason } = stateOf({
      agentId, done, launched, coveredFrom, lastActivityMs, parentState, nowMs, staleMs,
      killedAt: killed.has(agentId) ? (killed.get(agentId) ?? true) : null,
      failedAt: failed.has(agentId) ? (failed.get(agentId) ?? true) : null,
      deskStoppedAt: deskStopped.has(agentId) ? deskStopped.get(agentId) : null,
    });

    return {
      agentId,
      agentType,
      description,
      model: modelOf(jsonl, opts),
      state,
      reason,
      meta: metaState,
      lastActivityIso: lastActivityMs === null ? null : new Date(lastActivityMs).toISOString(),
      display: { state: SUBAGENT_STATE_TEXT[state] },
    };
  });

  // 新しい順。読み手が最初に見たいのは「今 動いている物」。
  agents.sort((a, b) => String(b.lastActivityIso ?? "").localeCompare(String(a.lastActivityIso ?? "")));
  return { agents, directory: "read", parent: parentState, truncated, counts: tally(agents) };
}

/** 拡張子を落とした幹 + `/subagents`。親 file と子の dir は兄弟(頭注の実測)。 */
export function subagentDirFor(transcriptPath) {
  const p = String(transcriptPath);
  const stem = p.endsWith(".jsonl") ? p.slice(0, -".jsonl".length) : p;
  return join(stem, "subagents");
}

/**
 * 3値 + `unknown` の判定。**此処だけが状態を決める**(呼び手に分岐を配らない)。
 *
 * 順序に意味が在る:
 *   1. 終了の記録が在る → `finished`。mtime が何であれ勝つ(観測値 > 推測)。
 *   2. 親が読めない → `unknown`。終了したかを**知らない**ので、mtime だけで
 *      `stalled` と言うと「結果を出さずに止まった」と主張した事になる —— 実際は
 *      終わっているかもしれない。
 *   3. 子の最終書き込みが親の走査窓より古い → `unknown`(予算の外なので分けられない)。
 *   4. ここまで来たら「終了の記録は**本当に**無い」。あとは mtime で running/stalled。
 */
export function stateOf({ agentId, done, launched, coveredFrom, lastActivityMs, parentState, nowMs, staleMs, killedAt = null, deskStoppedAt = null, failedAt = null }) {
  // 順位(2026-09-07、Codex stopped-state の後): 親転写の最後の終端が completed > 転写が読めない → unknown > 机の観測(親が読めなくても
  // 独立の観測)> 親が読めない → unknown > 親転写の killed > 走査の予算 > mtime。
  if (done.has(agentId)) return { state: "finished", reason: "parent-completed" };
  if (lastActivityMs === null) return { state: "unknown", reason: "transcript-unreadable" };
  // ★机が此の agent を止めたのを**見ている**(x を押してパネルで行が減った)なら、其の観測は mtime より強く、親の転写に依らない
  //   (Codex #7: 親が読めないだけで観測した停止を unknown にしない)。ただし転写が止めた後も動いていれば(猶予 DESK_STOP_GRACE_MS を
  //   超えて書かれた)、止まっていない = 記憶を捨てる。机が止めたのなら親転写の killed も同じ事を言う —— 其の時は机の観測が reason を
  //   決める(`stopped-by-desk`。Codex #3: 机の停止を「利用者」に隠さない)。
  if (Number.isFinite(deskStoppedAt) && lastActivityMs <= deskStoppedAt + DESK_STOP_GRACE_MS) {
    return { state: "stopped", reason: "stopped-by-desk" };
  }
  if (parentState !== "read") return { state: "unknown", reason: "parent-unreadable" };
  // ★親転写の最後の終端が killed = 利用者(Mac の鍵盤、または机の x で記憶が無い / 切れた時)が止めた。mtime より上。
  //   ★止められた agent は**再開できる**(通知の note)。通知より後(猶予を超えて)に転写が動いていれば再開した = killed を捨てて
  //   mtime で読む(Codex #2)。通知の時刻が読めない(`true`)時は転写の動きで反証できないので、通知を信じる。
  if (killedAt === true) return { state: "stopped", reason: "stopped-by-user" };
  if (Number.isFinite(killedAt) && lastActivityMs <= killedAt + DESK_STOP_GRACE_MS) return { state: "stopped", reason: "stopped-by-user" };
  // ★親転写の最後の終端が failed(agent の失敗)。killed と同じく再開できるので、通知の後に転写が動いていれば mtime で読む。
  if (failedAt === true) return { state: "failed", reason: "agent-failed" };
  if (Number.isFinite(failedAt) && lastActivityMs <= failedAt + DESK_STOP_GRACE_MS) return { state: "failed", reason: "agent-failed" };
  // 起動の記録を窓の中で見ていれば、其の子の一生は窓に収まっている ——
  // 終了は起動より後にしか書かれないので、無い事を言い切ってよい。
  const covered = launched.has(agentId) || lastActivityMs >= coveredFrom;
  if (!covered) return { state: "unknown", reason: "scan-budget" };
  const idleMs = nowMs - lastActivityMs;
  if (idleMs > staleMs) return { state: "stalled", reason: "no-result-idle" };
  return { state: "running", reason: "no-result-active" };
}

function empty() {
  return { finished: 0, running: 0, stalled: 0, unknown: 0, stopped: 0, failed: 0 };
}

function tally(agents) {
  const c = empty();
  for (const a of agents) if (c[a.state] !== undefined) c[a.state] += 1;
  return c;
}

/**
 * meta を読む。★上限を掛ける —— 名前が `.meta.json` でも中身が巨大な事は在りうるし、
 * 此処は「壊れていたら1本落とす」為の道なので、丸ごと読む理由が無い。
 */
function readTextCapped(path) {
  const fd = openSync(path, "r");
  try {
    const r = readLinesBackward(nodeIo, fd, { maxBytes: 256 * 1024, lineCap: 256 * 1024, done: () => false });
    return r.lines.join("\n");
  } finally {
    closeSync(fd);
  }
}
