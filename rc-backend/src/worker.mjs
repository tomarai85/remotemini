// セッション常駐ワーカーの管理 — DESIGN.md D3 の実装。
//
// 1セッション = 最大1ワーカー(claude-work -p --resume <id> --input-format stream-json
// --output-format stream-json)。stdin に user turn を流し、stdout の NDJSON を
// セッションごとの EventRing に積む。SSE 層は eventsSince() で読む。
//
// 規約(spec「ワーカー管理の契約」):
//   - 排他: workers Map への同期アクセスのみで到達(Node 単線)= 二重 spawn 不可
//   - 実行状態の真実はここ(プロセス状態+result イベント)。jsonl から推測しない
//   - 異常終了 → worker_error イベント + 破棄。次 send で再 spawn(--resume なので無傷)
//   - busy 中の send は FIFO queue(公式仕様でも同一 transcript へは interleave —
//     こちらは1本の書き手なので順序を自分で保証する)
//   - idle timeout は sweep() で発火(タイマーはサーバ層が回す。テスト容易性のため)
import { randomBytes } from "node:crypto";
import { EventRing } from "./ring.mjs";
import { redact } from "./redact.mjs";

const noop = () => {};

/** 溜める側の上限。総量に依らず記憶は一定(変異 W17 = 外す)。 */
const TAIL_KEEP_BYTES = 4096;
/** 出す側の上限(§2.21-a)。電話へ流す量を抑える(変異 W25 = 外す)。 */
const TAIL_EMIT_LINES = 10;
const TAIL_EMIT_BYTES = 1024;
/** 改行を1度も出さない子を切る位置。 */
const TAIL_LINE_MAX = 1024;

/** 伏せ**済み**の1行を積む。溜める側の上限はここ1箇所。 */
function pushRedacted(entry, line) {
  entry.stderrTail.push(line);
  let total = entry.stderrTail.reduce((n, s) => n + s.length + 1, 0);
  while (entry.stderrTail.length > 1 && total > TAIL_KEEP_BYTES) {
    total -= entry.stderrTail.shift().length + 1;
  }
}

/**
 * ★**伏せてから切る**。網は形の**全体**を要求する(メールなら `@ドメイン.tld` まで)ので、
 *   先に切ると `client-a.team@gm` のように**左半分だけが残って網を抜ける**(= 変異 W24)。
 */
function pushTailLine(entry, rawLine) {
  pushRedacted(entry, redact(rawLine));
}

/** stderr は行の途中で切れて届く。stdout 側と同じ緩衝を持つ。 */
function pushStderr(entry, chunk) {
  entry.errBuf += chunk.toString("utf8");
  let idx;
  while ((idx = entry.errBuf.indexOf("\n")) !== -1) {
    const line = entry.errBuf.slice(0, idx).trim();
    entry.errBuf = entry.errBuf.slice(idx + 1);
    if (line) pushTailLine(entry, line);
  }
  // 改行を1度も出さない子でも溜め込まない。**捨てずに切って積む**(捨てると
  // 「読めなかった」が「言わなかった」に化ける)。
  // ★ここでも順序は**伏せてから切る**。`redact` は冪等(`<mail>` は再び当たらない)。
  while (entry.errBuf.length > TAIL_LINE_MAX) {
    const red = redact(entry.errBuf);
    pushRedacted(entry, red.slice(0, TAIL_LINE_MAX));
    entry.errBuf = red.slice(TAIL_LINE_MAX);
  }
}

/**
 * 電話へ出す形。**閉包の `entry` から読む**。
 *
 * ★罠: `onDeath` は `this.workers.delete(sessionId)` を**先に**呼ぶ。
 *   `this.workers.get(sessionId)` から読む書き方は**必ず空になる**(= 変異 W18)。
 * ★死ぬ間際の一行は**改行が付かない**事が多い(そこが一番読みたい行)。先に流し込む。
 */
function flushStderr(entry) {
  if (entry.errBuf) {
    pushTailLine(entry, entry.errBuf);
    entry.errBuf = "";
  }
  const out = entry.stderrTail.slice(-TAIL_EMIT_LINES);
  while (out.length > 1 && out.reduce((n, s) => n + s.length + 1, 0) > TAIL_EMIT_BYTES) out.shift();
  // 1行しか残っていないのに長い時は、**空にせず**切る(全部落とす方が悪い)。
  if (out.length === 1 && out[0].length > TAIL_EMIT_BYTES) out[0] = out[0].slice(0, TAIL_EMIT_BYTES);
  return out;
}

export class WorkerManager {
  /**
   * @param {object} opts
   * @param {(sessionId: string, plan: {fork: boolean, resumeId: string}) => ChildProcessLike} opts.spawn
   *   実 spawn は server 層が注入。★**第2引数を必ず argv に写す事**(H2 = DESIGN §2.18-10):
   *   `plan.fork` なら `--fork-session` を付け、`--resume` には `sessionId` ではなく
   *   `plan.resumeId` を渡す。ここを取り違えると**単体は全部緑のまま**転写ファイルの
   *   書き手が2人になる(継ぎ目なので単体からは原理的に見えない。対照 = 変異 W7/W8)。
   * @param {{read: (ancestor: string) => string, write: (ancestor: string, head: string) => void}} [opts.heads]
   *   枝の頭の登録簿。★`read` は**投げない事**が契約(読めない/壊れている時は空文字)。
   *   空 = 「頭が無い」= もう一度 fork = 安全側に倒れる。出荷の `heads.mjs` の `readHead` が
   *   その形で、対照は `test/heads.test.mjs` の3件(登録なし / dir ごと無い / 中身が壊れている)。
   *   未注入(null)なら H2 の機能ごと切れて毎回 fork する = これも安全側。
   * @param {number} [opts.idleMs] ready のままこの時間で kill(既定 10 分)
   * @param {() => number} [opts.now] テスト用時計
   * @param {number} [opts.ringCapacity]
   * @param {number} [opts.killGraceMs] SIGTERM から SIGKILL までの猶予(既定 5 秒)
   * @param {typeof setTimeout} [opts.setTimer] テスト用タイマー
   * @param {typeof clearTimeout} [opts.clearTimer] 同上
   */
  constructor({
    spawn,
    idleMs = 10 * 60 * 1000,
    now = Date.now,
    ringCapacity = 512,
    heads = null,
    killGraceMs = 5000,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
    generation = null,
  }) {
    if (typeof spawn !== "function") throw new Error("WorkerManager: spawn injection required");
    this._spawn = spawn;
    // この manager の**通し番号ではない印**。`this.rings` は process の寿命なので、再起動すると
    // seq が 1 から振り直される。電話が持っている古い栞(`w.<印>.50.0`)が、印を見ないと
    // そのまま有効に見えて `since(50)` が空 = 「追いついた」と黙って嘘をつく。
    // 注入できるのは検査の為(乱数だと期待値が書けない)。既定は乱数。
    this.generation = generation || randomBytes(4).toString("hex");
    this.idleMs = idleMs;
    this.now = now;
    this.ringCapacity = ringCapacity;
    this.workers = new Map(); // sessionId -> entry
    this.rings = new Map();   // sessionId -> EventRing(ワーカーより長生き)
    // H2(DESIGN §2.18-4〜6, §2.18-10)。注入なので unit では本物のファイルを触らない。
    this.heads = heads;                 // { read(ancestor)->string, write(ancestor, head) }
    this.killGraceMs = killGraceMs;     // SIGTERM から SIGKILL までの猶予
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    // sessionId -> Set<entry>(SIGTERM 済みで**死が未確認**の先代たち)。
    // ★1件だけ覚える形(Map)は穴が在る(2026-08-02、差分を読み直して見つけた):
    //   e1 を退役 → e2 を fork → e2 も退役(この時 e1 の印が上書きされる)→ e2 の exit で
    //   印が空になる。ここで e1 がまだ生きていて、かつ **e2 の頭の書き込みが失敗していた**
    //   場合、頭は e1 の枝のままなので、次の子が **生きている e1 と同じファイル**へ resume する
    //   = H2 そのもの。全員を覚えれば「1人でも未確認なら分岐する」が素直に言える。
    this.dying = new Map();
    this.gens = new Map();    // sessionId -> 世代番号(単調増加)
    // sessionId -> 生配信の宛先。**entry ではなくセッションが持つ**(2026-08-04、実測で発見)。
    // 旧: `entry.onEvent`。`_emit` が `workers` から entry を引いていたので、**entry を外した後の
    // 通知が繋がっている電話に届かなかった** —— つまり `worker_interrupted` / 死亡通知 /
    // idle 回収の全部。検査は全部 `eventsSince`(= リング)で見ていたので、1本も落ちなかった
    // (§2.33「死んだ計器は下流の欠陥も隠す」の、計器が**別の口を見ていた**版)。
    // 宛先はワーカーより長生きする物なので、リング(`this.rings`)と同じ寿命に置く。
    this.listeners = new Map();
  }

  _ring(sessionId) {
    let r = this.rings.get(sessionId);
    if (!r) {
      r = new EventRing(this.ringCapacity);
      this.rings.set(sessionId, r);
    }
    return r;
  }

  _emit(sessionId, data) {
    const seq = this._ring(sessionId).push(data);
    // ★宛先は `workers` から引かない。引いていた頃、entry を外した後の通知(死・割り込み・
    //   idle 回収)は繋がっている電話に届かず、電話は「黙った」としか見えなかった。
    (this.listeners.get(sessionId) || noop)(seq, data);
    return seq;
  }

  /** SSE 層の読み口。EventRing.since の薄い委譲。 */
  eventsSince(sessionId, seq) {
    return this._ring(sessionId).since(seq);
  }

  /** 実行状態の真実(jsonl からの推測はしない — Codex 補正)。 */
  status(sessionId) {
    const e = this.workers.get(sessionId);
    if (!e) return { worker: "none", state: "idle", queued: 0 };
    return { worker: "running", state: e.state, queued: e.queue.length };
  }

  /**
   * user turn を送る。ワーカーが無ければ spawn。busy なら queue。
   * 戻り値: 受理時点の seq(user_sent イベント)。
   */
  send(sessionId, text, { onEvent, cwd } = {}) {
    // ★宛先は `_start` より**先に**登録する。spawn の途中で出る通知(同期の失敗など)も
    //   同じ口から出したい。旧実装は `_start` の後に `entry.onEvent` を代入していたので、
    //   起動中に出た物だけが静かにリング止まりになっていた。
    let e = this.workers.get(sessionId);
    if (onEvent) this.listeners.set(sessionId, onEvent);
    if (!e) {
      // ★cwd の既定値をここで作らない。作った瞬間に「渡し忘れ」が観測できなくなる
      //   (`_openPlan` の第2引数を argv に写し忘れた H2 と同じ型)。
      e = this._start(sessionId, cwd);
    }
    if (e.state === "busy") {
      // ★積む物が**文字列でなく物**なのは、`user_queued` の seq を持たせる為
      //   (§2.18-12)。この seq が turn の名前になり、後で「その turn は届かなかった」と
      //   **名指しで**言える。番号を別に発明していない = 既に在る計器(EventRing)の目盛りを使う。
      //   先に push してから emit するのは、今日までの順序をそのまま保つ為。
      const item = { text, seq: 0 };
      e.queue.push(item);
      item.seq = this._emit(sessionId, { type: "user_queued", text });
      return item.seq;
    }
    return this._write(sessionId, e, text);
  }

  /**
   * ★accepted した turn を**黙って**消さない(§2.18-12、2026-08-04)。
   *
   * entry が `workers` から外れる時、まだ積んだままの turn を1件ずつ名指しで
   * 「届かなかった」と出す。**外れる道は5本ある**(interrupt / idle 回収 / shutdown /
   * 予期しない死 / spawn の error)ので、道ごとに書くと必ずどれかが漏れる。
   * だから「外す直前に必ず通る場所」に1つ置いて、全部そこを通す。
   *
   * ★かつて此処に「`_emit` は `workers` から entry を引くので map から外す**前に**呼べ」と
   *   書いてあった。守る側の作法として正しかったが、**規則を守れる位置に置いた事**が、
   *   規則を守っていない他の口を隠していた —— 死亡通知 / `worker_interrupted` /
   *   idle 回収は全部「外した後」で、繋がっている電話に届いていなかった(2026-08-04 実測)。
   *   宛先を `this.listeners`(セッション持ち)へ移して、順序への依存ごと消した。
   * ★届かなかった事は EventRing に残る = 電話が割り込みの瞬間に切れていても、
   *   繋ぎ直して `eventsSince` で拾える。Codex `gpt-5.6-sol` xhigh 2026-08-04 が
   *   「一番ありそうな失敗は、失敗イベントを揮発性にする事。検査では listener が
   *   繋がっているので通るが、本番では切断中に消える」と名指しした穴が、これで塞がる。
   */
  _dropQueued(sessionId, entry, reason) {
    if (!entry.queue.length) return 0;
    const dropped = entry.queue.splice(0, entry.queue.length);
    for (const item of dropped) {
      this._emit(sessionId, {
        type: "user_dropped",
        text: item.text,
        queuedSeq: item.seq,
        reason,
      });
    }
    return dropped.length;
  }

  /**
   * 電話からの「待っている送信を取り消す」(2026-08-04)。**走っている番には触れない** ——
   * それは `interrupt` の仕事で、2つを1つの操作に畳むと「取り消す」が生成を殺す事になる。
   *
   * ★`_dropQueued` を外へ晒さずに此処を足したのは、あちらが **entry を引数で受け取る**から。
   *   呼び手が `workers` から引いた物と違う entry を渡せてしまい、その時に出る
   *   `user_dropped` は**別の会話の番号**を名乗る。引く場所を1つに閉じる。
   */
  dropQueued(sessionId, reason) {
    const e = this.workers.get(sessionId);
    if (!e) return 0; // ワーカーが居ない = 積める場所が無い。0 は「無かった」で嘘ではない
    return this._dropQueued(sessionId, e, reason);
  }

  _write(sessionId, entry, text) {
    const msg = {
      type: "user",
      message: { role: "user", content: [{ type: "text", text }] },
    };
    entry.proc.stdin.write(JSON.stringify(msg) + "\n");
    entry.state = "busy";
    entry.lastActive = this.now();
    return this._emit(sessionId, { type: "user_sent", text });
  }

  /**
   * この会話をどう開くか。**待たない**のが要点(DESIGN §2.18-10(2))。
   *
   *   頭が無い          → 祖先から fork(初回)
   *   頭が有る          → その枝の先端へ resume
   *   ★先代の死が未確認 → 頭が有っても**もう一度 fork**
   *
   * 3番目が肝。SIGTERM を撃っただけの先代はまだ書いているかもしれず、その枝へ resume すると
   * 同じ転写ファイルに書き手が2人になる = H2 そのもの。死ぬまで待つ選択もあるが、それは
   * 電話を数秒待たせる。分岐すれば待ち時間ゼロで、起きる事は「枝が1本増える」だけ
   * (§2.17 が既に**名前の問題**と値付けした側)。§2.18-6 と同じ倒れ方。
   */
  _openPlan(sessionId, cwd) {
    const head = this.heads ? this.heads.read(sessionId) : "";
    const undead = this._hasUndead(sessionId);
    return { fork: !head || undead, resumeId: head || sessionId, cwd };
  }

  _start(sessionId, cwd) {
    const plan = this._openPlan(sessionId, cwd);
    // ★`_spawn` が**同期で**投げたら、そのまま外へ出す。`this.workers.set` はこの下に在るので
    //   半端な entry は残らず、次の送信は素の初回として扱われる。握り潰して 202 を返さない。
    const proc = this._spawn(sessionId, plan);
    const gen = (this.gens.get(sessionId) || 0) + 1;
    this.gens.set(sessionId, gen);
    const entry = {
      proc,
      state: "ready",
      queue: [],
      lastActive: this.now(),
      buf: "",
      gen,
      dead: false,
      forked: plan.fork,
      headWritten: false,
      killTimer: null,
      stderrTail: [],
      errBuf: "",
    };
    // ★「本当に終わった」を**待てる形**で持つ(§2.64)。`entry.dead` は真偽値なので
    //   「もう死んだか」しか答えられず、「死ぬまで待つ」に使えない。割り込みが
    //   止まった事を名乗るには後者が要る。解決するのは `onDeath` の1箇所だけ。
    entry.exited = new Promise((resolve) => { entry._markExited = resolve; });
    this.workers.set(sessionId, entry);

    proc.stdout.on("data", (chunk) => {
      entry.buf += chunk.toString("utf8");
      let idx;
      while ((idx = entry.buf.indexOf("\n")) !== -1) {
        const line = entry.buf.slice(0, idx);
        entry.buf = entry.buf.slice(idx + 1);
        this._ingestLine(sessionId, entry, line, true);
      }
    });
    // claude-work の account= 行や `--resume` の失敗理由がここに来る。**捨てない**。
    // 購読自体はバッファ詰まり防止として元から必要だったので、捨て先を尻尾に変えただけ。
    proc.stderr?.on?.("data", (chunk) => pushStderr(entry, chunk));
    proc.on("error", (err) => {
      this._emit(sessionId, {
        type: "worker_error",
        error: redact(String(err?.message || err)),
        // ★空でも欄ごと落とさない。欄が無い事と「何も言わずに死んだ」事は、
        //   電話から区別が付かない(§2.16 を production 側でもう一度)。
        stderr: flushStderr(entry),
        // ★**今の子の失敗か、退役した先代の失敗か**を欄で言う(Codex 2026-08-04)。
        //   消さないのは §2.16 の通り(失敗を黙らせない)。だが黙らせないだけだと、
        //   電話は「今動いている子が壊れた」と読む —— `error` は kill 失敗でも出るので、
        //   割り込みの直後に**先代の**失敗が今の会話の帯を赤くし得る。
        //   真偽値は**常に載せる**(欄の不在と false は区別が付かない、が此処の作法)。
        stale: this.workers.get(sessionId) !== entry,
      });
      // 行列は**無条件に**畳む(この entry の物なので、退役済みなら既に空 = 何も起きない)。
      this._dropQueued(sessionId, entry, "worker_error");
      // ★Map から外すのは**同一性で**。`error` は spawn 失敗だけでなく kill 失敗でも出るので、
      //   割り込みで退役 → 別の子に差し替わった**後**に届き得る。名前で消すと、その時
      //   生きている次の子が Map から外れ、次の送信がもう1本 spawn する = 1つの転写に
      //   書き手が2人(H2)。`exit`/`close` 側(下)には同じ守りが在って、此処だけ無かった。
      if (this.workers.get(sessionId) === entry) this.workers.delete(sessionId);
    });
    // ★`exit` と `close` の両方を購読する。**死んだ事の合図は `exit`**(DESIGN §2.18-10(2)):
    //   `close` は stdio が全部閉じるまで来ないので、孫がパイプを持っていると永久に来ない。
    //   両方来るのが普通なので `entry.dead` で1回に畳む。
    const onDeath = (code, signal) => {
      if (entry.dead) return;
      entry.dead = true;
      // ★待っている割り込みを起こすのは**ここだけ**。`_retire` 側(SIGTERM を撃つ所)で
      //   解決すると「撃った事」を「死んだ事」として名乗る事になり、直そうとしている
      //   嘘をそのまま作り直す事になる。解決は死の観測点でしか行わない。
      entry._markExited?.();
      // ★改行の付かなかった最後の一行を、**死の合図より先に**流す(DESIGN §2.45)。
      //   `worker.mjs` は改行でしか行を切らないので、改行の手前で死ぬと最後の行は
      //   `entry.buf` に残ったまま捨てられていた。stderr には `flushStderr` が在るのに
      //   stdout には何も無い —— 取引ではなく**非対称の抜け**。落ちるのが `result` だと
      //   電話は「まだ生成中」のまま永久に止まる(idle 回収の kill / 上限 / クラッシュで起きる)。
      // ★退役した entry でも流す。中身はその子が**実際に書いた**出力であり、
      //   黙らせない(§2.16)。`_commitHead` 側は同一性で自衛しているので此処では抑えない。
      this._flushStdout(sessionId, entry);
      this._confirmDeath(sessionId, entry);
      // interrupt(kill)による終了は interrupt() 側で後始末済み。まだ Map に**この entry が**
      // 居る = 予期しない終了。同一性で見る(名前で見ると、既に別の子に差し替わった後の
      // 遅い close が新しい子を消してしまう)。
      if (this.workers.get(sessionId) !== entry) return;
      this._dropQueued(sessionId, entry, "worker_died");
      this.workers.delete(sessionId);
      if (code !== 0) {
        this._emit(sessionId, {
          type: "worker_error",
          error: `worker exited code=${code} signal=${signal || "none"}`,
          stderr: flushStderr(entry),
        });
      } else {
        this._emit(sessionId, { type: "worker_closed" });
      }
    };
    proc.on("exit", onDeath);
    proc.on("close", onDeath);
    return entry;
  }

  /**
   * fork した子が名乗った新しいセッション ID を頭として記録する。
   *
   * ★守りは**二重**(同一性 + 世代)。それぞれが**単独で捕まえる場面**を持つ:
   *   - 同一性のみ = 子が死んだ後、まだ次を spawn していない間に届いた名乗り
   *     (世代は進んでいないので世代照合では捕まらない)
   *   - 世代のみ   = 「頭の書き込みが同期である」という**呼ぶ側から見えない前提**が崩れた時。
   *     §2.18-9(`execFileSync` だから鍵の行列が空だった)と同じ形の依存なので外に出す
   *
   * ★かつて3つ目に `entry.retired` を見ていたが、**外した**(2026-08-02、変異 X1/X8 が
   *   素通りして分かった)。`_retire` は必ず `workers` から外すので、退役した entry は
   *   同一性の検査で必ず捕まる = `retired` が判定を分ける場面が1つも無い。
   *   冗長(§2.18-8 の M102 型 = 両方が実際に効く)ではなく、**一度も効かない**守りだった。
   */
  /**
   * stdout の1行を電話へ流す。行の**切り出し**は呼ぶ側の仕事。
   *
   * @param {boolean} live 生きている子からの行か。`false` = 死んだ後の流し込み
   *   (= 改行の付かなかった最後の行)。★`result` を拾っても**行列を進めない**:
   *   進めると死んだ `stdin` へ次の一件を書きに行く。届く物は届け、
   *   次の一手は死の処理(`_dropQueued`)に任せる。
   * @returns {boolean} 事象を1本出したか
   */
  _ingestLine(sessionId, entry, raw, live) {
    const line = raw.trim();
    if (!line) return false;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      return false; // NDJSON でない行(verbose の混入等)は流さない
    }
    this._commitHead(sessionId, entry, ev);
    this._emit(sessionId, ev);
    if (ev.type === "result" && live) {
      entry.lastActive = this.now();
      if (entry.queue.length > 0) {
        const next = entry.queue.shift();
        this._write(sessionId, entry, next.text);
      } else {
        entry.state = "ready";
      }
    }
    return true;
  }

  /**
   * 死ぬ間際、改行の付かなかった最後の1行を流す。stderr 側の `flushStderr` と同じ形。
   *
   * ★必ず `entry.buf` を空にしてから出す。`exit` と `close` は両方来るのが普通で、
   *   `entry.dead` の畳みが将来外れても二重には出ない様にしておく。
   * @returns {boolean} 実際に1本出したか(半端な JSON / 空なら false)
   */
  _flushStdout(sessionId, entry) {
    const rest = entry.buf;
    entry.buf = "";
    if (!rest) return false;
    return this._ingestLine(sessionId, entry, rest, false);
  }

  _commitHead(sessionId, entry, ev) {
    if (!this.heads || !entry.forked || entry.headWritten) return;
    const newId = typeof ev?.session_id === "string" ? ev.session_id : "";
    if (!newId || newId === sessionId) return;
    if (this.workers.get(sessionId) !== entry) return; // 死んだ/差し替わった後の遅い名乗り
    if (entry.gen !== this.gens.get(sessionId)) return; // 世代が進んでいる
    entry.headWritten = true;
    try {
      this.heads.write(sessionId, newId);
    } catch {
      // 書けなければ頭は無いまま = 次回は fork。倒れる向きが安全側なので送信は落とさない。
      entry.headWritten = false;
    }
  }

  /** 死を確認した。猶予タイマーを止め、「先代がまだ生きているかも」の印を外す。 */
  _confirmDeath(sessionId, entry) {
    if (entry.killTimer) {
      this.clearTimer(entry.killTimer);
      entry.killTimer = null;
    }
    const set = this.dying.get(sessionId);
    if (set) {
      set.delete(entry);
      if (set.size === 0) this.dying.delete(sessionId);
    }
  }

  /** 未確認の先代が1人でも居るか。1人でも居れば分岐する(§2.18-10(2))。 */
  _hasUndead(sessionId) {
    const set = this.dying.get(sessionId);
    return Boolean(set && set.size > 0);
  }

  /**
   * 退役させて SIGTERM を撃つ。**死ぬのを待たない**。
   * 猶予を過ぎたら SIGKILL を撃つが、それは送信経路の外の話。
   */
  _retire(sessionId, entry, reason = "worker_retired") {
    // ★外す**前**に、積んだままの turn を名指しで出す(§2.18-12)。
    //   idle 回収は「ready なら行列は空」なので普通は0件だが、**それを言葉で保証しない**:
    //   名前(state === "ready")に頼ると、その名前の意味が変わった日に黙って壊れる。
    //   ここで実際に中を見て0件なら何も起きない = 保証が構造になる(Codex 2026-08-04 の Q3)。
    this._dropQueued(sessionId, entry, reason);
    // ★`workers` から外す事**そのもの**が退役の印(別に旗を持たない)。
    //   旗を持っていた時、それを読む場面が1つも無い事に変異 X1/X8 の素通りで気づいた。
    if (this.workers.get(sessionId) === entry) this.workers.delete(sessionId);
    let set = this.dying.get(sessionId);
    if (!set) { set = new Set(); this.dying.set(sessionId, set); }
    set.add(entry);
    try {
      entry.proc.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    entry.killTimer = this.setTimer(() => {
      entry.killTimer = null;
      try {
        entry.proc.kill("SIGKILL");
      } catch {
        /* already gone */
      }
    }, this.killGraceMs);
    if (entry.killTimer && typeof entry.killTimer.unref === "function") entry.killTimer.unref();
  }

  /**
   * 割り込み = kill。--resume 再開は実測で無傷(MULTITURN-OK 検証)。
   *
   * ★積んだ送信は**此処で終端が決まる**(§2.18-12)。tmux 経路は「割り込みの後も積んだ
   *   送信は打たれる」= `delivered` に落ちるが、ワーカー経路は子を殺すので同じにはならない。
   *   両経路で揃えるのは**中の振る舞いではなく turn の終端状態**:
   *   `accepted → delivered | failed(理由)`。どちらも言える形になっていればよく、
   *   駄目なのは「`user_queued` と出した後、**どちらにも落ちない**」= 今日までの姿。
   *
   * ★2026-08-08、戻り値を真偽値から4通しへ変えた(§2.64)。旧版は SIGTERM を撃った
   *   直後に `true` を返し、電話には `view.mjs` が「止めました(Escape)。」と出していた。
   *   **二重に偽**だった: ①止まった事は誰も観測していない(撃っただけ) ②この経路は
   *   Escape を押していない(子への SIGTERM)。tmux 経路は 2026-08-03 に同じ誤りを
   *   直しているのに、**片方の経路にだけ残っていた**。
   *
   * ★直す時に前提が1つ引っくり返った。`view.test.mjs` は「ワーカー経路は tmux を
   *   持たないので画面を撮れない = `stopped` を名乗れない」と書いていたが、これは逆。
   *   ワーカーは**子プロセスの handle を握っている**ので、画素から推し量る tmux より
   *   **強い**観測ができる。撮れないのは画面であって、死は撮るまでもなく分かる。
   *
   * @returns {Promise<{stopped:("verified"|"unverified"|null), reason:string|null, waited:number}>}
   *   `verified`   … 子が実際に終了したのを観測した
   *   `unverified` … SIGTERM は撃ったが、期限内に終了を観測できていない = **まだ止まっていない**
   *   `null`       … 止める対象がそもそも居ない
   *
   * ★`already-done`(tmux 側の4つ目)は**この経路には無い**。子が自力で終わっていれば
   *   `exit` が届いて Map から外れているので、区別は `null` に畳まれる。値域に名前だけ
   *   置くと「出るはずなのに出ない値」になり、読む側が到達しない枝を守ってしまう。
   */
  async interrupt(sessionId, { budgetMs } = {}) {
    const e = this.workers.get(sessionId);
    const t0 = this.now();
    if (!e) return { stopped: null, reason: "not-running", waited: 0 };
    const exited = e.exited;
    this._retire(sessionId, e, "worker_interrupted");
    this._emit(sessionId, { type: "worker_interrupted" });
    // ★死を待つ手段そのものが無い entry(`_start` を通らずに作られた物)は、
    //   **観測できない**が正しい答え。ここで `verified` に倒すと、直したい嘘が
    //   「待つ物が無い時だけ復活する」形で戻ってくる。
    if (!exited) return { stopped: "unverified", reason: "no-exit-signal", waited: 0 };
    // ★期限は既定で「SIGKILL の猶予 + 1 秒」。SIGKILL は握り潰せないので、猶予を過ぎれば
    //   子は必ず死ぬ —— つまりこの期限を過ぎても死を観測できない場合、疑うべきは子ではなく
    //   **観測側**(`exit` が来ない = 孫がパイプを持っている等)。だから待ち足すのではなく
    //   `unverified` で正直に降りる。電話の書き込み側の上限は 30 秒なので余裕がある。
    const budget = budgetMs ?? this.killGraceMs + 1000;
    // ★`exited` が**既に**解決している場合でも `await` は 1 tick 遅れるだけで、
    //   タイマーは張ったまま残らない(下で必ず clear する)。
    let timer = null;
    const timeout = new Promise((resolve) => {
      timer = this.setTimer(() => resolve("timeout"), budget);
      if (timer && typeof timer.unref === "function") timer.unref();
    });
    const who = await Promise.race([exited.then(() => "exited"), timeout]);
    this.clearTimer(timer);
    const waited = this.now() - t0;
    if (who === "exited") return { stopped: "verified", reason: null, waited };
    return { stopped: "unverified", reason: "still-alive", waited };
  }

  /** idle 回収。サーバ層が setInterval で回す(テストでは手動呼び)。 */
  sweep() {
    const t = this.now();
    for (const [sid, e] of this.workers) {
      if (e.state === "ready" && t - e.lastActive > this.idleMs) {
        this._retire(sid, e, "worker_idle_closed");
        this._emit(sid, { type: "worker_idle_closed" });
      }
    }
  }

  /**
   * シャットダウン(サーバ終了時)。
   *
   * ★積んだ送信は此処でも終端を決める。「プロセスが終わるのだから消えてよい」は通らない
   *   (Codex 2026-08-04 の Q3): クラッシュと違い shutdown は**こちらの意図**なので、
   *   accepted した turn の会計は残る。再配信はしない = `failed(server_shutdown)` で確定。
   */
  shutdown() {
    for (const [sid, e] of [...this.workers]) this._retire(sid, e, "server_shutdown");
  }
}
