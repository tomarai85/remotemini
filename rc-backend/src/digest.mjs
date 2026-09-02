/**
 * digest.mjs — 「留守中に何が起きたか」を1画面ぶんに畳む。2026-08-26 新設。
 *
 * なぜ要るか(研究 2026-08-26)
 *   実際の使われ方は「移動中に短く覗く」。なのに調べた全製品が**生の流れ**を垂れ流す。
 *   Tom が知りたいのは1行の判断 —— **今すぐノートを開く必要があるか**。
 *
 * ★守る一線は3つ。どれも「完全に見えて完全でない要約」を潰す為に在る。
 *   1. 読み切れなかった時は**数を返さない**(`counts: null`)。「3件」と書けば人は3件だと
 *      思う。その数が「読めた範囲で3件」だと知る方法が読み手に無い。0 に丸めるのは更に悪い
 *      —— 読めなかった時間帯が「静かだった」として届く。
 *   2. `window.observedFromIso` は**実際に見えた最初のレコードの時刻**。頼まれた時刻を
 *      そのまま書かない(Codex 2026-08-26)。5分前までしか読めていないのに「1時間前から」と
 *      名乗ったら、その1行は嘘になる。
 *   3. `attention`(今 人を待っているか)は**ここでは決めない**。転写の形からの推測は
 *      当たる時と当たらない時が混ざる。生の画面を読む分類器が唯一の出所で、読めなければ
 *      `unknown`。推測を `none` の代わりに使わない —— 一番肝心な判断が汚れる。
 */

/** 1回の digest で読む項目の上限。超える範囲を頼まれたら不完全へ倒す。 */
export const DIGEST_MAX_RECORDS = 4000;

/** 一覧に出す道具の種類の上限(小さい画面に20行並べても読まれない)。 */
export const DIGEST_TOP_TOOLS = 5;

/** 小さい画面に出す対象パスの数。残りは件数だけ。 */
export const DIGEST_TOP_TARGETS = 3;

/**
 * ファイルを指定する道具。★名前が `filesTouched` ではなく `fileTargets` なのは、
 * `input` が「触った証拠」ではなく**モデルが書いた指定**だから(Codex 2026-08-26)。
 * 失敗・取り消し・相対パスで簡単にズレる。
 */
const FILE_TOOLS = new Set(["Edit", "Write", "NotebookEdit", "Read", "MultiEdit"]);

/**
 * ★**書き換えた**側の道具(2026-08-31)。
 *
 * 直す前は `Read` と `Edit` が同じ箱に入っていて、**読んだ file と書き換えた file が
 * 区別できなかった**。此の 1 行が答えようとしている問いは「今ノートを開くべきか」で、
 * 其の判断に効くのは**読んだ 20 件ではなく、書き換えた 3 件**の方。
 *
 * ★名前は `fileTargets` と同じ理由で `written` ではなく `writeTargets` ——
 *   `input` は「触った証拠」ではなく**モデルが書いた指定**で、失敗・取り消しで簡単にズレる
 *   (Codex 2026-08-26 の裁定。此処でも同じ線を引く)。
 */
const WRITE_TOOLS = new Set(["Edit", "Write", "NotebookEdit", "MultiEdit"]);

/** 画面の分類器が返しうる注意状態。**`unknown` を `none` に丸めない。** */
export const ATTENTION_STATES = ["none", "input", "choice", "permission", "unknown"];

function isoOf(rec) {
  const t = rec && typeof rec.timestamp === "string" ? Date.parse(rec.timestamp) : NaN;
  return Number.isFinite(t) ? t : null;
}

function textOf(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b && b.type === "text" && typeof b.text === "string")
    .map((b) => b.text).join("");
}

function toolUses(content) {
  if (!Array.isArray(content)) return [];
  return content.filter((b) => b && b.type === "tool_use" && typeof b.name === "string");
}

/** 最後の発言の末尾だけ。頭ではなく末尾を採るのは、結論が後ろに在るから。 */
export function trimTail(text, max = 400) {
  const t = String(text).replace(/\s+/g, " ").trim();
  return t.length <= max ? t : `…${t.slice(-max)}`;
}

/**
 * @param {object[]} records jsonl の生レコード(新旧どちらの順でもよい — 中で並べ直す)
 * @param {{sinceMs:number, nowMs:number, reachedStart?:boolean}} o
 *   `reachedStart` = 後方走査が `sinceMs` より前まで届いたか(呼び手にしか分からない)
 */
export function digestOf(records, o) {
  const sinceMs = Number(o?.sinceMs);
  const nowMs = Number(o?.nowMs);
  const list = Array.isArray(records) ? records : [];

  // 窓の骨。`observedFromIso` は下で**実際に見えた物**から埋める。
  const win = {
    requestedFromIso: Number.isFinite(sinceMs) ? new Date(sinceMs).toISOString() : "",
    observedFromIso: null,
    toIso: Number.isFinite(nowMs) ? new Date(nowMs).toISOString() : "",
    minutes: Number.isFinite(sinceMs) && Number.isFinite(nowMs)
      ? Math.max(0, Math.round((nowMs - sinceMs) / 60000)) : 0,
  };

  // 末尾は不完全な時も読めている(後方走査なので新しい方から埋まる)。
  // 数は伏せても**最後の発言だけは出す** —— それが一番知りたい1行だから(Codex #2)。
  const tail = lastAssistantOf(list, sinceMs, nowMs);

  if (!Number.isFinite(sinceMs) || !Number.isFinite(nowMs)) return incomplete(win, "bad-window", tail);
  if (o?.reachedStart === false) return incomplete(win, "scan-budget", tail);
  if (list.length > DIGEST_MAX_RECORDS) return incomplete(win, "too-many-records", tail);

  const counts = { user: 0, assistant: 0, tool: 0 };
  const toolN = new Map();
  const fileTargets = [];
  const writeTargets = [];
  let sawUndated = false;
  let firstAt = null;

  const sorted = list.slice().sort((a, b) => (isoOf(a) ?? 0) - (isoOf(b) ?? 0));
  for (const rec of sorted) {
    if (!rec || typeof rec !== "object") continue;
    const at = isoOf(rec);
    // ★時刻の無いレコードは窓の中とも外とも言えない。捨てると静かに数が減るので、
    //   捨てた事を覚えて下で不完全へ倒す。
    if (at === null) {
      // ★時刻が無くても**数に入らない行**(要約・メタ・分岐の印)は抜けではない。
      //   実測(2026-08-26): 実際の転写には時刻を持たないメタ行が普通に混ざる。
      //   全部を不完全の証拠にすると、digest は**常に**数を伏せて役に立たなくなる。
      //   倒すのは「数える筈だったのに時刻が無い」行だけ。
      if ((rec.type === "user" || rec.type === "assistant") && rec.message) sawUndated = true;
      continue;
    }
    if (at < sinceMs || at > nowMs) continue;
    if (firstAt === null || at < firstAt) firstAt = at;

    if (rec.type === "user" && rec.message) {
      counts.user++;
    } else if (rec.type === "assistant" && rec.message) {
      if (textOf(rec.message.content)) counts.assistant++;
      for (const u of toolUses(rec.message.content)) {
        counts.tool++;
        toolN.set(u.name, (toolN.get(u.name) || 0) + 1);
        if (FILE_TOOLS.has(u.name)) {
          const p = u.input?.file_path ?? u.input?.path ?? u.input?.notebook_path;
          // 文字列である事だけを要求し、中身は解釈しない(存在確認もしない)。
          if (typeof p === "string" && p && !fileTargets.includes(p)) fileTargets.push(p);
          // ★書き換えた側を別に数える。読んだ物と混ぜない。
          if (typeof p === "string" && p && WRITE_TOOLS.has(u.name) && !writeTargets.includes(p)) {
            writeTargets.push(p);
          }
        }
      }
    }
  }

  if (sawUndated) return incomplete(win, "undated-records", tail);

  win.observedFromIso = firstAt === null ? null : new Date(firstAt).toISOString();

  return {
    complete: true,
    incompleteReason: null,
    window: win,
    counts,
    tools: [...toolN.entries()]
      .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
      .slice(0, DIGEST_TOP_TOOLS)
      .map(([name, n]) => ({ name, n })),
    // ★名前が「触った」ではなく「対象」。上位だけ出して残りは数で言う。
    fileTargets: fileTargets.slice(0, DIGEST_TOP_TARGETS),
    fileTargetsTotal: fileTargets.length,
    writeTargets: writeTargets.slice(0, DIGEST_TOP_TARGETS),
    writeTargetsTotal: writeTargets.length,
    lastAssistant: tail.text,
    lastAt: tail.at,
    // ★2026-09-02: 会話が**今 何で走っているか**。転写の各レコードが `model` /
    //   `gitBranch` / `version` を持つ(実機で確認: `claude-sonnet-4-6` / `main` /
    //   `2.1.128`)。公式は接続端末に現用モデルを出す(対照表 #14-16)が、電話には
    //   今まで何も出ていなかった。**最新のレコードの値**を採る —— 途中で `/model` を
    //   切り替えた会話では古い行が別のモデルを名乗るので、頭の値では嘘になる。
    //   ★無い物は無いと言う(`null`)。0 件の窓や古い版の転写には項目自体が無い。
    session: sessionOf(sorted),
  };
}

/// 転写の最新レコードから、会話の実行環境を拾う。**後ろから前へ**見て、初めて値を持つ
/// レコードの物を採る(最後の 1 件がメタ行で持たない事が普通に在る)。
function sessionOf(sorted) {
  let model = null, gitBranch = null, version = null;
  for (let i = sorted.length - 1; i >= 0; i -= 1) {
    const r = sorted[i];
    if (!r || typeof r !== "object") continue;
    if (model === null && typeof r?.message?.model === "string") model = r.message.model;
    if (gitBranch === null && typeof r.gitBranch === "string") gitBranch = r.gitBranch;
    if (version === null && typeof r.version === "string") version = r.version;
    if (model !== null && gitBranch !== null && version !== null) break;
  }
  return { model, gitBranch, version };
}

/** 窓の中で最後に喋った内容。**不完全でも返す**(後方走査なので末尾は読めている)。 */
function lastAssistantOf(list, sinceMs, nowMs) {
  let best = null, bestAt = null;
  for (const rec of list) {
    if (!rec || rec.type !== "assistant" || !rec.message) continue;
    const at = isoOf(rec);
    if (at === null) continue;
    if (Number.isFinite(sinceMs) && at < sinceMs) continue;
    if (Number.isFinite(nowMs) && at > nowMs) continue;
    const t = textOf(rec.message.content);
    if (!t) continue;
    if (bestAt === null || at >= bestAt) { best = t; bestAt = at; }
  }
  return { text: best === null ? null : trimTail(best), at: bestAt === null ? null : new Date(bestAt).toISOString() };
}

// ★`session` は不完全な時も**項目として在る**(既定は全部 null)。電話の復号は
//   「項目が無い」と「値が null」を同じに扱うが、線の形が読めた/読めないで変わると
//   `wire-shape-capture` が別形として数える。形は 1 つに保つ。
function incomplete(win, reason, tail, session = { model: null, gitBranch: null, version: null }) {
  return {
    session,
    complete: false,
    incompleteReason: reason,
    window: win,
    // ★null であって 0 ではない。0 は「起きなかった」、null は「読めなかった」。
    counts: null,
    tools: null,
    fileTargets: null,
    writeTargets: null,
    writeTargetsTotal: null,
    fileTargetsTotal: null,
    // 末尾だけは読めているので出す(数は伏せる)。
    lastAssistant: tail?.text ?? null,
    lastAt: tail?.at ?? null,
  };
}

/**
 * 「今すぐノートを開く必要があるか」。件数ではなく**これ**が判断を決める(Codex #5)。
 *
 * @param {string} attentionState 画面の分類器が言った状態(ATTENTION_STATES のどれか)
 * @param {{complete:boolean}} d digest
 * @returns {{level:"now"|"soon"|"none"|"unknown", reason:string|null}}
 */
export function actionRequired(attentionState, d) {
  switch (attentionState) {
    // 人が押すまで**何も進まない**。これだけが「今」。
    case "permission": return { level: "now", reason: "permission" };
    case "choice":     return { level: "now", reason: "choice" };
    // 打てば進む。止まってはいるが、放っておいても壊れない。
    case "input":      return { level: "soon", reason: "input" };
    case "none":
      // 動いている。ただし**読み切れていない要約で「大丈夫」とは言わない**。
      return d?.complete === true
        ? { level: "none", reason: null }
        : { level: "unknown", reason: "partial-digest" };
    default:
      // ★画面が読めない = 待っているかもしれない。`none` に倒さない。
      return { level: "unknown", reason: "screen-unreadable" };
  }
}

/** 単複を合わせる。`1 replies` は英語として壊れていて、**数字より先に目に付く**。
 *  2026-08-31、実機の画面で `60m · 1 replies · 1 tool calls · 1 file targets` を観測。
 *  此の1行は「今ノートを開くべきか」を判断する為の物なので、読んだ瞬間に
 *  文法の粗が気を散らすのは、書いてある数字の価値をそのまま削る。 */
function plural(n, one, many) { return `${n} ${n === 1 ? one : many}`; }

/** 人が読む1行。**判断に使える語だけ**を並べる。 */
export function digestLine(d, action) {
  const head = d?.complete === true
    ? [`${d.window.minutes}m`,
       plural(d.counts.assistant, "reply", "replies"),
       plural(d.counts.tool, "tool call", "tool calls"),
       // ★出すのは**書き換えた**側(2026-08-31)。読んだ file の数は
       //   「今ノートを開くべきか」を動かさない —— 20 件 読んで何も変えていない事は
       //   在り得るし、其の時に「20 files」と出るのは判断を誤らせる。
       //   `writeTargetsTotal` が無い古い机とも噛み合う様に、値が無ければ黙る。
       ...(d.writeTargetsTotal ? [`${plural(d.writeTargetsTotal, "file", "files")} changed`] : [])
      ].join(" · ")
    : "Could not read the whole window — counts withheld on purpose";

  switch (action?.level) {
    case "now":     return `${head} — waiting for you now (${action.reason}).`;
    case "soon":    return `${head} — stopped, needs a message.`;
    case "none":    return `${head} — still working.`;
    default:        return `${head} — cannot tell if it needs you (${action?.reason ?? "unknown"}).`;
  }
}

/**
 * 画面の分類器の語(`classifyScreen` の `state`)を、digest の注意状態へ写す。
 *
 * ★ここを暗黙にしない。`SENDABLE` を「待っていない」と読むのは**間違い**で、
 *   あれは「打てば通る」= 止まって人を待っている状態(soon)。逆に `UNKNOWN` は
 *   画面が読めなかった事で、`none`(動いている)とは全く違う。
 *   写像を1箇所に固定して、両方の語彙を知っている人が読める形で置く。
 */
export function attentionFromScreen(state) {
  switch (state) {
    case "CHOICE":   return "choice";     // 選択待ち = 押すまで進まない
    case "SENDABLE": return "input";      // 打てる = 止まっているが壊れない
    case "UNKNOWN":  return "unknown";    // 読めなかった。none に倒さない
    default:         return "unknown";
  }
}

/**
 * 走っている最中(活動が観測できている)なら、止まってはいない。
 * `classifyScreen` は `activity` を独立に出すので、そちらが `observed` の時だけ
 * `none` を名乗ってよい —— composer が在る事は「待っている」の証拠にならない。
 */
/**
 * digest の応答の**封筒**。2026-08-26 に切り出した。
 *
 * ★なぜ関数にしたか: `server.mjs` に **3 箇所 直書き**されていた。直書きの封筒は
 *   `wire-key-agreement` の突き合わせ表に載せられない —— 表は「builder を呼んで出た鍵名」と
 *   電話の `Decodable` を比べるので、呼べる物が無いと**電話側の型が永久に未検証**になる。
 *   実際 2026-08-26 に `DigestEnvelope` を足した所、門が
 *   「新しい Decodable 型がどちらの箱にも入っていない」で止めた。正しい指摘だった。
 *
 * ★形はここが正本。3 箇所は此処を呼ぶ。
 */
export function digestBody(d, attention, action) {
  return { digest: d, attention, action, line: digestLine(d, action) };
}

export function attentionOf(screen) {
  const s = attentionFromScreen(screen?.screen);
  if (s === "input" && screen?.activity === "observed") return "none";
  return s;
}
