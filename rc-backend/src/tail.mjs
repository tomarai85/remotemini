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

/**
 * SSE の再接続でどう繋ぐか。**純関数**にしてあるのは、ここが嘘の連続性を作る唯一の場所で、
 * サーバに埋めると検査(変異)が掴めないから。
 *
 * id の形は `epoch.seq`。epoch は配信の世代で、購読が絶えて seq が 1 に戻った時に
 * 「Last-Event-ID: 57 → since(57) は空 → 追いついた」という嘘が成立しないようにする為の前置き。
 *
 * @param {string} rawLast Last-Event-ID か ?since=
 * @param {number} epoch   今の配信の世代
 * @returns {{kind:"fresh"}|{kind:"resume",seq:number}|{kind:"gap",why:string}}
 */
export function resumeDecision(rawLast, epoch) {
  const s = String(rawLast ?? "");
  // 何も持っていない = 初回。電話が `since=0` を付けて来るのは普通の事で、これを
  // 壊れた再開として gap にすると**毎回**読み直しを命じることになり、やがて
  // クライアントは gap を無視するようになる = 本当の取りこぼしが埋もれる(8/02 実測)。
  if (s === "" || s === "0") return { kind: "fresh" };
  const [ep, sq] = s.split(".");
  if (ep !== String(epoch) || !/^\d+$/.test(sq || "")) return { kind: "gap", why: "epoch-mismatch" };
  return { kind: "resume", seq: Number(sq) };
}

// ---- long-poll の栞(cursor)------------------------------------------------
// 電話が使う配信は SSE ではなく long-poll(2026-08-04、§2.36)。栞は**不透明**に扱う
// 契約で、電話は受け取った文字列をそのまま返すだけ。組み立てと解釈が此処に居るのは
// `resumeDecision` と同じ理由 —— 嘘の連続性を作れる唯一の場所を純関数に出す為。
//
// 形:
//   tmux   `t.<epoch>.<seq>.<screenRev>`
//   worker `w.<generation>.<seq>.0`
// epoch / generation は **process ごとの token**(連番ではない)。連番だと再起動で
// 1 に戻り、再起動前の栞が偶然一致して「追いついた」と黙って嘘をつく。
// ★この欠陥は SSE 側に**実在していた**(`feedEpochSeq` は 0 起点の連番だった)。
//   poll を足すついでに直したのではなく、同じ穴を2本目に掘らない為に先に直した。
const CURSOR_MAX = 128; // 長さの栓。栞は自分で作った物しか来ない筈だが、外から来る値なので絞る

/** 栞を組む。`screenRev` は worker 経路では常に 0(画面を持たない)。 */
export function formatPollCursor({ route, token, seq, screenRev = 0 }) {
  return `${route === "tmux" ? "t" : "w"}.${token}.${seq}.${screenRev}`;
}

/**
 * 栞をどう繋ぐか。
 *
 * ★`kind:"gap"` は「差分では繋げない」であって「異常」ではない。初回(栞が無い)だけは
 * `fresh` で、これを gap にすると開くたびに履歴の読み直しを命じる事になり、やがて電話は
 * gap を無視する = **本物の取りこぼしが埋もれる**(`resumeDecision` と同じ判断)。
 *
 * @param {string} raw       電話が返してきた栞
 * @param {"tmux"|"worker"} route 今の経路
 * @param {string} token     今の epoch / generation
 * @returns {{kind:"fresh"}|{kind:"resume",seq:number,screenRev:number}|{kind:"gap",why:string}}
 */
export function pollDecision(raw, route, token) {
  const s = String(raw ?? "");
  if (s === "") return { kind: "fresh" };
  if (s.length > CURSOR_MAX) return { kind: "gap", why: "cursor-too-long" };
  const parts = s.split(".");
  if (parts.length !== 4) return { kind: "gap", why: "cursor-malformed" };
  const [r, tok, sq, sr] = parts;
  // ★経路が変わった時に **gap を出す**。tmux で開いていた会話が閉じられて worker 経路へ
  //   落ちる(逆も)と、seq の空間ごと別物になる。ここを素通りさせると、別の空間の数字で
  //   「追いついた」と答える経路ができる。
  if (r !== (route === "tmux" ? "t" : "w")) return { kind: "gap", why: "route-changed" };
  if (tok !== String(token)) return { kind: "gap", why: "epoch-mismatch" };
  if (!/^\d+$/.test(sq) || !/^\d+$/.test(sr)) return { kind: "gap", why: "cursor-malformed" };
  return { kind: "resume", seq: Number(sq), screenRev: Number(sr) };
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
