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
import { EventRing } from "./ring.mjs";

const noop = () => {};

export class WorkerManager {
  /**
   * @param {object} opts
   * @param {(sessionId: string) => ChildProcessLike} opts.spawn 実 spawn は server 層が注入
   * @param {number} [opts.idleMs] ready のままこの時間で kill(既定 10 分)
   * @param {() => number} [opts.now] テスト用時計
   * @param {number} [opts.ringCapacity]
   */
  constructor({ spawn, idleMs = 10 * 60 * 1000, now = Date.now, ringCapacity = 512 }) {
    if (typeof spawn !== "function") throw new Error("WorkerManager: spawn injection required");
    this._spawn = spawn;
    this.idleMs = idleMs;
    this.now = now;
    this.ringCapacity = ringCapacity;
    this.workers = new Map(); // sessionId -> entry
    this.rings = new Map();   // sessionId -> EventRing(ワーカーより長生き)
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
    const entry = this.workers.get(sessionId);
    (entry?.onEvent || noop)(seq, data);
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
  send(sessionId, text, { onEvent } = {}) {
    let e = this.workers.get(sessionId);
    if (!e) {
      e = this._start(sessionId);
    }
    if (onEvent) e.onEvent = onEvent;
    if (e.state === "busy") {
      e.queue.push(text);
      return this._emit(sessionId, { type: "user_queued", text });
    }
    return this._write(sessionId, e, text);
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

  _start(sessionId) {
    const proc = this._spawn(sessionId);
    const entry = {
      proc,
      state: "ready",
      queue: [],
      lastActive: this.now(),
      onEvent: noop,
      buf: "",
    };
    this.workers.set(sessionId, entry);

    proc.stdout.on("data", (chunk) => {
      entry.buf += chunk.toString("utf8");
      let idx;
      while ((idx = entry.buf.indexOf("\n")) !== -1) {
        const line = entry.buf.slice(0, idx).trim();
        entry.buf = entry.buf.slice(idx + 1);
        if (!line) continue;
        let ev;
        try {
          ev = JSON.parse(line);
        } catch {
          continue; // NDJSON でない行(verbose の混入等)は流さない
        }
        this._emit(sessionId, ev);
        if (ev.type === "result") {
          entry.lastActive = this.now();
          if (entry.queue.length > 0) {
            const next = entry.queue.shift();
            this._write(sessionId, entry, next);
          } else {
            entry.state = "ready";
          }
        }
      }
    });
    proc.stderr?.on?.("data", noop); // claude-work の account= 行など。捨てるが購読はする(バッファ詰まり防止)
    proc.on("error", (err) => {
      this._emit(sessionId, { type: "worker_error", error: String(err?.message || err) });
      this.workers.delete(sessionId);
    });
    proc.on("close", (code, signal) => {
      // interrupt(kill)による close は interrupt() 側で後始末済み。ここに来た時に
      // まだ Map に居る = 予期しない終了。
      if (!this.workers.has(sessionId)) return;
      this.workers.delete(sessionId);
      if (code !== 0) {
        this._emit(sessionId, {
          type: "worker_error",
          error: `worker exited code=${code} signal=${signal || "none"}`,
        });
      } else {
        this._emit(sessionId, { type: "worker_closed" });
      }
    });
    return entry;
  }

  /** 割り込み = kill。--resume 再開は実測で無傷(MULTITURN-OK 検証)。 */
  interrupt(sessionId) {
    const e = this.workers.get(sessionId);
    if (!e) return false;
    this.workers.delete(sessionId); // close ハンドラの「予期しない終了」判定より先に外す
    try {
      e.proc.kill("SIGTERM");
    } catch {
      /* already gone */
    }
    this._emit(sessionId, { type: "worker_interrupted" });
    return true;
  }

  /** idle 回収。サーバ層が setInterval で回す(テストでは手動呼び)。 */
  sweep() {
    const t = this.now();
    for (const [sid, e] of this.workers) {
      if (e.state === "ready" && t - e.lastActive > this.idleMs) {
        this.workers.delete(sid);
        try {
          e.proc.kill("SIGTERM");
        } catch {
          /* already gone */
        }
        this._emit(sid, { type: "worker_idle_closed" });
      }
    }
  }

  /** シャットダウン(サーバ終了時)。 */
  shutdown() {
    for (const [sid, e] of this.workers) {
      this.workers.delete(sid);
      try {
        e.proc.kill("SIGTERM");
      } catch {
        /* already gone */
      }
    }
  }
}
