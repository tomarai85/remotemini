// jsonl の**追記分だけ**を読む tail。SSE のライブ配信(tmux 経路)の下回り。
//
// なぜ要るか(実測 2026-08-02): `/stream` に push している箇所は worker 経路の1つだけで、
// 実運用の主線である tmux 経路のセッションでは実イベントが **0 件** だった
// (`tools/live-http-check.mjs` 初回: 送信〜返答の 3.2 秒間に 0 件)。
// 電話側は「送った → 無音」になる。Tom 裁定「返答待ちであれ作業中であれ**いつでも見て**、
// 干渉できればいい」を、この無音は直接破っている。
//
// 方式は Codex 相談(2026-08-02)の裁定に従う: jsonl の追記 tail を主系、`/history` を
// 再同期の保険、画面状態は「最新値だけ意味がある一時状態」として別イベントに分ける。
//
// ★このファイルが引き受ける難しさは1つだけ: **追記だと信じない**こと。
//   - 書き込み途中の最終行を読まない(改行までしか消費しない)
//   - 同じ inode のままの truncate / 書き直し
//   - rename 差し替え(パスは同じで inode が変わる)
//   - ローテーション
//   これらを「世代(generation)が変わった」として検出し、**取りこぼしを黙って埋めない**。
//   世代が変わったら差分を作らず reset を返し、呼び手は /history の読み直しへ倒す。
import { createHash } from "node:crypto";
import { closeSync, fstatSync, openSync, readSync } from "node:fs";

export const CHECKPOINT_BYTES = 512;

/** 追記の連続性を確かめる印。offset の**直前**の一定バイトから採る。 */
export function checkpointOf(buf) {
  return createHash("sha1").update(buf).digest("hex").slice(0, 16);
}

/**
 * 完全な行(改行で終わっている分)だけを切り出す。
 * 改行は 1 バイト(0x0A)で、UTF-8 の多バイト文字の一部には決してならないので、
 * ここで切る限り文字の途中で割れることはない。
 * @returns {{ chunk: Buffer, consumed: number }} consumed は 0 なら完全な行が1つも無い
 */
export function sliceCompleteLines(buf) {
  const nl = buf.lastIndexOf(0x0a);
  if (nl < 0) return { chunk: Buffer.alloc(0), consumed: 0 };
  return { chunk: buf.subarray(0, nl + 1), consumed: nl + 1 };
}

const defaultIo = {
  open: (p) => openSync(p, "r"),
  fstat: (fd) => fstatSync(fd),
  read: (fd, buffer, position) => readSync(fd, buffer, 0, buffer.length, position),
  close: (fd) => closeSync(fd),
};

export class JsonlTail {
  /**
   * @param {object} o
   * @param {string} o.path 監視するファイル
   * @param {object} [o.io] fs の注入(試験用)
   * @param {number} [o.maxChunk] 1回の poll で読む上限。巨大な追記でメモリを持っていかれない為
   */
  constructor({ path, io = defaultIo, checkpointBytes = CHECKPOINT_BYTES, maxChunk = 2 * 1024 * 1024 }) {
    if (!path) throw new Error("JsonlTail: path required");
    this.path = path;
    this.io = io;
    this.checkpointBytes = checkpointBytes;
    this.maxChunk = maxChunk;
    this.generation = null; // `${dev}-${ino}`
    this.offset = 0;
    this.checkpoint = null;
    this.primed = false;
  }

  /** 現在の末尾に位置を合わせる。過去分は流さない(スナップショットは /history の仕事)。 */
  #primeTo(fd, st) {
    this.generation = `${st.dev}-${st.ino}`;
    this.offset = st.size;
    this.checkpoint = this.#readCheckpoint(fd, st.size);
    this.primed = true;
  }

  #readCheckpoint(fd, upto) {
    if (upto <= 0) return "";
    const n = Math.min(this.checkpointBytes, upto);
    const b = Buffer.alloc(n);
    const got = this.io.read(fd, b, upto - n);
    return checkpointOf(b.subarray(0, got));
  }

  /**
   * 前回からの追記を読む。
   * @returns {{ ok: boolean, reset: boolean, generation: string|null, records: Array<{end:number, obj:any}>, error?: string }}
   *   reset=true は「差分では繋がらない」の合図。records は空で返し、呼び手は履歴を読み直す。
   */
  poll() {
    let fd;
    try {
      fd = this.io.open(this.path);
    } catch (e) {
      // まだ発言が無い会話では jsonl そのものが存在しない(edith 実測 2026-07-31)。
      // 「読めない」を「消えた」と混同しない — 次の poll で現れたらそこから始める。
      return { ok: false, reset: false, generation: this.generation, records: [], error: String(e?.code || e?.message || e) };
    }
    try {
      const st = this.io.fstat(fd);
      const gen = `${st.dev}-${st.ino}`;

      if (!this.primed) {
        this.#primeTo(fd, st);
        return { ok: true, reset: false, generation: this.generation, records: [] };
      }

      // 世代交代の検出。mtime や ctime は当てにしない(Codex 指摘: 単独では不十分)。
      const shrunk = st.size < this.offset;
      const swapped = gen !== this.generation;
      const drifted = !shrunk && !swapped && this.#readCheckpoint(fd, this.offset) !== this.checkpoint;
      if (shrunk || swapped || drifted) {
        this.#primeTo(fd, st);
        return {
          ok: true,
          reset: true,
          generation: this.generation,
          records: [],
          error: swapped ? "generation-changed" : shrunk ? "truncated" : "checkpoint-mismatch",
        };
      }

      if (st.size === this.offset) {
        return { ok: true, reset: false, generation: this.generation, records: [] };
      }

      const want = Math.min(st.size - this.offset, this.maxChunk);
      const buf = Buffer.alloc(want);
      const got = this.io.read(fd, buf, this.offset);
      const { chunk, consumed } = sliceCompleteLines(buf.subarray(0, got));
      if (consumed === 0) {
        // 書き込み途中。改行が来るまで何もしない(半端な行を JSON.parse に渡さない)。
        return { ok: true, reset: false, generation: this.generation, records: [] };
      }

      const records = [];
      let seen = 0;
      for (const raw of chunk.toString("utf8").split("\n")) {
        if (raw === "") continue; // 末尾の空要素
        seen += Buffer.byteLength(raw, "utf8") + 1;
        const end = this.offset + seen;
        try {
          records.push({ end, obj: JSON.parse(raw) });
        } catch {
          // 壊れた行は飛ばす。1行の為に配信全体を止めない(一覧側と同じ方針)。
        }
      }
      this.offset += consumed;
      this.checkpoint = this.#readCheckpoint(fd, this.offset);
      return { ok: true, reset: false, generation: this.generation, records };
    } catch (e) {
      return { ok: false, reset: false, generation: this.generation, records: [], error: String(e?.message || e) };
    } finally {
      try {
        this.io.close(fd);
      } catch {
        /* 既に閉じている */
      }
    }
  }
}
