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
//
// 2026-08-01 の実測で、「登録が古い」を検出できないと**実際に他人の会話へ本文が入る**
// 経路が在ることが分かった(下の「登録が生きているかの判定」参照)。同日、書き手が
// 追加費用ゼロでプロセス同一性を書けることも実測できたので、判定を推測から検証へ変えた。

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { normTty } from "./procs.mjs";

/**
 * 心拍が途絶えた登録を死んだとみなすまでの猶予。**同一性の書かれていない古い形式にだけ**使う。
 *
 * 実測(2026-08-01, 放置した会話を90秒観測): statusline は 45回 / min 1986ms / median 2001ms /
 * max 2269ms で書き直す。放置中でも止まらないので mtime は心拍として使える。
 * 15秒 = 心拍7回分の空振りを許す。長くする方が危険側 —— 死んだ登録がペインを占有し続ける
 * ほど「その会話は tmux に居ない」と誤判定してワーカーを起こす窓が延びる(= lost-update)。
 */
export const HEARTBEAT_TTL_MS = 15_000;

/** "<socket>,<server_pid>,<client_index>"($TMUX の中身)から socket と server pid を取る。 */
function parseTmuxEnv(s) {
  const m = /^(.+),(\d+),\d+$/.exec(String(s || ""));
  return m ? `${m[1]},${m[2]}` : "";
}

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
  const pid = Number.isInteger(obj?.pid) && obj.pid > 0 ? obj.pid : 0;
  return {
    sessionId,
    pane,
    model: typeof obj?.model === "string" ? obj.model : "",
    // 同一性の2点(2026-08-01 追加)。無い = 古い書き手 -> 心拍だけで判定する。
    server: parseTmuxEnv(obj?.tmux), // その会話が居た tmux サーバ世代(socket + server pid)
    pid, // claude 本体の pid(statusline の $PPID = claude 実体だと実測済)
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
 *   unregistered  -> 有効な登録が無く、その cwd に claude のペインが在る。cwd 一致は
 *                    同定ではないので注入しない。ワーカーにも落とさない(そのペインが
 *                    この会話本人である可能性を否定できず、落とすと lost-update)。
 *                    登録を有効にすれば ok になる = Tom に手当てを案内する理由。
 *                    source="cwd" = 一度も名乗っていない / source="registry" = 名乗ったが
 *                    その登録がもう現実と合っていない(ペイン消滅・シェルに戻った)。
 *                    どちらも電話側の直し方は同じ(rc-claude で開き直す)。
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
/**
 * その登録は**今も現実を指しているか**。ここが登録簿の要。
 *
 * なぜ要るか(2026-08-01 実測、これが無いと実際に他人の会話へ本文が入る):
 *   - tmux の pane id(%0, %1...)は**サーバ世代ごとに %0 から振り直される**。登録簿は
 *     サーバより長生きするので、id だけでは別世代のペインと区別が付かない。
 *     実際 ~/.rc-backend/panes/ には10件あり、**全件が %0 を名乗っていた**(全部別世代)。
 *   - 書き手は登録を消さない。会話が終わっても登録は残り続ける。
 *   - この2つが揃うと「死んだ登録が、今そこに居る別の会話のペインを指す」状態になる。
 *     古い登録を信じて注入すれば、無関係な会話に本文と Enter が入る。
 *
 * 判定は2通りある。**同一性が書いてあり、かつ ps が読めた時だけ検証**。それ以外は心拍。
 *
 * 1) 同一性あり(2026-08-01 以降の書き手): 推測せず検証する。4点が揃って初めて
 *    「そのペインへ送った物はこの会話に届く」と言える:
 *      - tmux サーバが同世代(socket + server pid) -> ペイン id が同じ意味を持つ
 *      - その pid の tty がそのペインの tty      -> 場所が一致する
 *      - その pid が**前面**(pgid == tpgid)       -> send-keys を受け取るのは本当にこの
 *        プロセス。実測: 前面 pgid=tpgid=54850、Ctrl-Z 後は tpgid だけシェルの 54787 に
 *        変わり stat も T になる。suspend された claude は tty を握ったままなので、
 *        tty 一致だけでは「前面に居る別の claude」に送ってしまう。
 *      - その pid が**登録より前に生まれている**(startMs <= mtimeMs) -> pid の使い回し除け。
 *        pid は再利用されるので、pid 一致は「登録した時と同じ実体」を意味しない
 *        (Codex 2026-08-01 の指摘)。誕生時刻を足すと pid + 誕生時刻で実体が一意になる。
 *        ps の誕生時刻は秒で切り捨てられる = 実際より過去に寄る = 安全側に効く。
 *    心拍は問わない。停止していようが本人は本人で、送り先としては正しい。
 *
 * 2) 同一性なし(古い書き手)、**または ps が読めなかった**: mtime = 心拍しか手掛かりが無い。
 *    実測どおり2秒ごとに更新されるので、TTL を超えた沈黙は死んだ登録とみなす。
 *    未来の時刻(時計の巻き戻し)も信用しない。
 *    ★ps が読めない時に「検証できないから死んでいる」と倒すのは**危険側**(Codex 2026-08-01
 *    "Unknown must mean do not spawn"): 全登録が死ぬと、開いたままの TUI を持つ会話が
 *    none に落ちてワーカーを起こす = lost-update。分からない時は心拍という別の証拠に退く。
 *
 * @returns {"identity"|"heartbeat"|null} どの根拠で生きていると判定したか(null = 死)
 */
export function aliveKind(e, ctx) {
  if (e.server && e.pid && ctx.procAvailable) {
    if (!ctx.server || e.server !== ctx.server) return null;
    const pane = ctx.paneBy.get(e.pane);
    if (!pane || !pane.tty) return null;
    const proc = ctx.procOf(e.pid);
    if (!proc || !proc.foreground) return null;
    if (!(proc.startMs > 0 && proc.startMs <= e.mtimeMs)) return null;
    const ok = normTty(proc.tty) === normTty(pane.tty) && normTty(pane.tty) !== "";
    return ok ? "identity" : null;
  }
  const age = ctx.now - e.mtimeMs;
  return age >= 0 && age <= ctx.ttlMs ? "heartbeat" : null;
}

export function entryAlive(e, ctx) {
  return aliveKind(e, ctx) !== null;
}

/**
 * 「そのペインは他の会話の物だ」と言い切れるペインの集合。
 *
 * 用途は**候補から外すこと**。外し過ぎると候補が消えて "none" になり、ワーカーを
 * 起こしてしまう(= 開いたままの会話を2プロセスが触る lost-update)。つまりここは
 * **少なめに主張する方が安全**なので、生きた登録のうち mtime が単独最新の物だけを
 * 占有者とし、同着は「誰の物か決められない」として占有扱いしない。
 */
function ownedPanes(live) {
  const byPane = new Map();
  for (const e of live) {
    const cur = byPane.get(e.pane);
    if (!cur || e.mtimeMs > cur.mtimeMs) byPane.set(e.pane, e);
    else if (e.mtimeMs === cur.mtimeMs) byPane.set(e.pane, { ...cur, tied: true });
  }
  return new Set([...byPane.entries()].filter(([, e]) => !e.tied).map(([pane]) => pane));
}

/**
 * 「この会話が生きているかもしれない claude ペインが、他に在るか」。
 *
 * cwd 一致は**同定には弱すぎるが、警戒には十分強い**。この非対称がこの関数の全て:
 *   - 「cwd が一致したから本人だ」→ 誤り(同じ cwd を192会話が共有している)
 *   - 「cwd が一致する claude が居るから、本人でない**とは言い切れない**」→ 正しい
 * ワーカー(別プロセス)を起こす前にこれを見て、少しでも当たりが在れば起こさない。
 * 誤判定の代償は「送れない」だけで、逆側は同じ会話への二重実行。
 *
 * 誰も名乗っていないペインだけを見る(名乗り済み = 別の会話だと分かっている)。
 *
 * 「そのペインは claude か」は**広い方**で判定する(ctx.claudeTtys = ps の実測)。名前
 * (#{pane_current_command})だけに頼ると、ラッパ経由で起動した claude が "bash" に見えて
 * 取り逃す = ワーカーを起こす方向に外れる(2026-08-01 MBP で実測)。ここでの偽陽性は
 * 「送れない」で済むので、広く採るのが正しい向き。
 */
function livePaneNearby({ cwd, owned, panes, isClaude, exclude, claudeTtys }) {
  if (!cwd) return false; // 突き合わせる相手が無い(jsonl 未生成など)。ここでは判断しない
  const claudeish = (p) =>
    (claudeTtys ? claudeTtys.has(normTty(p.tty)) : false) || isClaude(p.command);
  return panes.some(
    (p) => p.pane !== exclude && !owned.has(p.pane) && p.path === cwd && claudeish(p),
  );
}

export function resolveSessionPane({
  sessionId, cwd, entries, panes, isClaude, resolveByCwd,
  // 登録が生きているかを判定するための現実側の情報。server / procOf は server.mjs が入れる。
  now = Date.now(),
  ttlMs = HEARTBEAT_TTL_MS,
  server = "",            // 今の tmux サーバ "socket,pid"。不明なら同一性の検証はできない
  procOf = () => null,    // pid -> { tty, foreground, startMs } | null
  procAvailable = false,  // ps を読めたか。false = 「死んでいる」ではなく「分からない」
  claudeTtys = null,      // claude が前面に居る tty の集合(ps 実測)。null = 分からない
}) {
  const ctx = {
    now, ttlMs, server, procOf, procAvailable, claudeTtys,
    paneBy: new Map(panes.map((p) => [p.pane, p])),
  };
  // 死んだ登録は「占有」も「同定」もしない。ここを通さないと、終わった会話の登録が
  // 今そこに居る別の会話のペインを指し続ける(2026-08-01 実測: 10件が全部 %0 を名乗っていた)。
  const live = entries.filter((e) => entryAlive(e, ctx));
  const owned = ownedPanes(live);
  const entry = live.find((e) => e.sessionId === sessionId);
  // 登録はあるが死んでいた場合、**登録が無い場合と同じ道**を通す。ここで即座に拒否すると
  // 「机で閉じた会話にワーカー経路で送る」という正常な使い方まで塞いでしまう。
  // 近くに生きた claude が居るかどうかで、拒否(unregistered)とワーカー(none)を分ける。
  const hadDeadEntry = !entry && entries.some((e) => e.sessionId === sessionId);

  if (!entry) {
    // 登録が無い = この会話は登録機構の入る前から開いている、または tmux 外。
    // cwd 経路で場所を見るが、**他の会話が名乗り済みのペインは候補から外す**。
    // 候補が減る方向にしか動かないので、素の cwd 一致より必ず安全側。
    const free = panes.filter((p) => !owned.has(p.pane));
    const byCwd = { ...resolveByCwd(cwd, free), source: hadDeadEntry ? "registry" : "cwd" };

    // ★cwd 経路は "ok" を返せない(2026-07-31 Codex 同意)。
    // 「その cwd に claude のペインが1つだけ在る」は**同定ではない**。実測で
    // ~/.claude だけに192会話が同じ cwd を共有しており、たまたま今開いている1枚が
    // 電話で選んだ会話である保証はどこにも無い。当たれば速い・外れれば他人の会話に
    // 本文と Enter が入って実際に動き出す = 取り返しがつかない。期待値は明確にマイナス。
    // 名乗り(登録簿)だけが同定で、それ以外は「速いかもしれない推測」にすぎない。
    if (byCwd.reason === "ok") {
      return { pane: null, reason: "unregistered", candidates: byCwd.candidates, source: byCwd.source };
    }
    // none / not-claude(= 注入できる claude が居ない)はワーカー経路のままでよい。
    // ambiguous は元から拒否。
    return byCwd;
  }

  const info = panes.find((p) => p.pane === entry.pane);
  if (!info) {
    // 登録時のペインが消えている。「その会話の TUI はもう無い」と読みたくなるが、
    // **それは証明されていない**(2026-07-31 二次レビュー、Codex 指摘):
    //   rc-claude で開いて %7 を登録 → 終了 → 後で素の `claude --resume` で %19 に開き直す
    // という順序を踏むと、登録簿は %7 のまま古くなり、会話は %19 で生きている。ここで
    // ワーカー(`-p --resume`)を起こすと、同じ会話を2プロセスが触る = lost-update。
    // 実際にこの案件は「登録が無い機械でも動くように」ラッパ方式を採っているので、
    // 登録あり→登録なしで開き直す順序は例外ではなく通常運転。
    if (livePaneNearby({ cwd, owned, panes, isClaude, exclude: entry.pane, claudeTtys })) {
      return { pane: null, reason: "unregistered", candidates: 1, source: "registry" };
    }
    return { pane: null, reason: "none", candidates: 0, source: "registry" };
  }
  // ★名前による claude 判定は**同一性を検証できなかった登録にだけ**掛ける。
  //   #{pane_current_command} は tty の前面プロセスグループ**リーダ**の名前で、claude を
  //   ラッパ(exec しない bash スクリプト)越しに起動している機械では "bash" になる
  //   (2026-08-01 MBP 実測。edith は直接起動なので "2.1.220")。同じ艦隊の2台で違う値が
  //   出る物を、生きている本人を拒否する根拠には使えない。
  //   同一性を検証できた登録は、その pid が前面・同じ tty・登録より前に生まれていることまで
  //   確認済みなので、名前は情報を足さない。心拍だけで生かした登録には従来どおり掛ける。
  if (aliveKind(entry, ctx) !== "identity" && !isClaude(info.command)) {
    // ペインは在るが claude ではない(終了してシェルに戻った)。注入したら任意コマンド実行。
    // 上と同じ理由で、その会話が別ペインで生きている可能性を潰してからでないと落とせない。
    if (livePaneNearby({ cwd, owned, panes, isClaude, exclude: entry.pane, claudeTtys })) {
      return { pane: null, reason: "unregistered", candidates: 1, source: "registry" };
    }
    return { pane: null, reason: "not-claude", candidates: 1, source: "registry" };
  }

  // 同じペインを名乗る、同じか新しい登録があるか。あれば**この登録を信じない**。
  // (ペインが別の会話に使い回された時にここで捕まる)
  //
  // 同着(mtimeMs が完全一致)も止める。「厳密に新しい物だけ」にすると、同着の2件が
  // **どちらも ok** を返して両方がそのペインへ注入できてしまう。同着は起こりにくいが、
  // 起きた時の結果が「別の会話に本文が入る」なので、可用性(送れない)を差し出す。
  const newer = live.find(
    (e) => e.pane === entry.pane && e.sessionId !== sessionId && e.mtimeMs >= entry.mtimeMs,
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
export function registryOnlySessions({
  listing, entries, panes, isClaude,
  now = Date.now(), ttlMs = HEARTBEAT_TTL_MS, server = "", procOf = () => null,
  procAvailable = false, claudeTtys = null,
}) {
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
      // 生死の判定材料をそのまま渡す。渡し忘れると死んだ登録が「未発言の会話」として
      // 一覧に並び、電話から送れてしまう(= 別の会話への注入)。
      now, ttlMs, server, procOf, procAvailable, claudeTtys,
    });
    if (r.reason !== "ok") continue; // stale / not-claude / 消えたペインは出さない
    const info = panes.find((p) => p.pane === e.pane);
    out.push({
      id: e.sessionId,
      project: null,
      cwd: info?.path || "",
      // 中身が無いので中身から題は作れない。★「(未発言)」は機械の内部語で、
      // Tom が 2026-08-16 に「論外」と裁定した画面の顔そのものだった(spec-audit A2)。
      // 人が読む一覧に出すのは人の言葉。明示名(titles.mjs)が在れば server 側の
      // 一括 override が此の値を上書きする。
      title: "New session",
      lastPrompt: "",
      turns: 0,
      // jsonl が存在しない = 読み残したのではなく、本当に何も無い。false が正しい。
      metadataIncomplete: false,
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
