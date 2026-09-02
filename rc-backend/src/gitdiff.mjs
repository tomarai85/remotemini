// 会話の作業木に**未コミットの差分が幾ら在るか**(対照表 #5「一覧の ± バッジ」)。
//
// 公式 Remote Control は一覧に `+42 -18` を出す。RemoteMini は差分を一切見られなかった。
// 此処は其の最初の 1 段 = **数だけ**。中身(#4 の diff 画面)は別。
//
// ── 設計 ─────────────────────────────────────────────────────────────────
// ★読むだけ。`git diff --shortstat` 以外の git を撃たない(書く動詞は動詞表に無い)。
// ★一覧の組み立て(`buildListing`)は同期で、41 本の会話が在る。1 本ずつ git を
//   同期で撃つと 41 × 最大 1.5 秒 で**一覧が固まる**。だから:
//     - 値は cache から**同期で**返す(無ければ null)
//     - 取り直しは**非同期で**、cwd ごとに 1 本だけ飛ばす(飛行中なら重ねない)
//   = 初回の一覧は null で返り、次の poll で埋まる。一覧は 2-3 秒ごとに来るので足りる。
// ★null は「読めなかった / まだ読んでいない / git 管理外」の**全部**。
//   数が出ない事を 0 に丸めない —— 0 は「差分が無い」で、別の意味。
import { execFile as nodeExecFile } from "node:child_process";

/** `git diff --shortstat` の 1 行を読む。形が合わなければ null。 */
export function parseShortstat(text) {
  const t = String(text ?? "").trim();
  if (!t) return { files: 0, added: 0, removed: 0 };   // 出力が空 = 差分ゼロ(git の仕様)
  const files = /(\d+) files? changed/.exec(t);
  if (!files) return null;
  const ins = /(\d+) insertions?\(\+\)/.exec(t);
  const del = /(\d+) deletions?\(-\)/.exec(t);
  return {
    files: Number(files[1]),
    added: ins ? Number(ins[1]) : 0,
    removed: del ? Number(del[1]) : 0,
  };
}

/**
 * cwd ごとの差分の数を、TTL 付きで覚える箱。
 *
 * @param {object} [o]
 * @param {Function} [o.exec]   execFile 互換(検査で差し替える)
 * @param {number}   [o.ttlMs]  同じ cwd を撃ち直すまでの間(既定 10 秒)
 * @param {Function} [o.now]    時計(検査で差し替える)
 * @param {number}   [o.timeoutMs] git 1 本の上限(既定 1.5 秒。動かない repo で固まらない為)
 */
export function makeDiffCache(o = {}) {
  const exec = o.exec ?? nodeExecFile;
  const ttlMs = o.ttlMs ?? 10_000;
  const now = o.now ?? (() => Date.now());
  const timeoutMs = o.timeoutMs ?? 1500;
  /** cwd -> { value, at } */
  const store = new Map();
  /** cwd -> Promise(飛行中) */
  const inflight = new Map();

  function refresh(cwd) {
    if (inflight.has(cwd)) return inflight.get(cwd);
    const p = new Promise((resolve) => {
      exec("git", ["-C", cwd, "diff", "--shortstat"], { timeout: timeoutMs }, (err, stdout) => {
        const value = err ? null : parseShortstat(stdout);
        store.set(cwd, { value, at: now() });
        inflight.delete(cwd);
        resolve(value);
      });
    });
    inflight.set(cwd, p);
    return p;
  }

  return {
    /** 同期。覚えていれば其れを返し、古ければ裏で取り直す。無ければ null を返して裏で取る。 */
    get(cwd) {
      if (typeof cwd !== "string" || !cwd) return null;
      const hit = store.get(cwd);
      if (!hit || now() - hit.at >= ttlMs) refresh(cwd);
      return hit ? hit.value : null;
    },
    /** 検査用: 飛行中の取り直しを待つ。 */
    settle(cwd) { return inflight.get(cwd) ?? Promise.resolve(store.get(cwd)?.value ?? null); },
    /** 検査用: 中身を覗く。 */
    _size() { return store.size; },
  };
}
