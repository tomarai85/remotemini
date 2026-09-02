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
//
// ── 2026-09-02 Codex 批評(直叩き、12 件中 5 件 採用)で直した所 ────────────────
// ★`git diff --shortstat HEAD`(HEAD を付ける)。付けないと **staged を数えない** ——
//   `git add` した直後に数がゼロへ落ちる。未追跡は今も数えない(`git diff` の意味論、
//   #4 の diff 画面と同じ数え方)。commit が 1 つも無い repo は HEAD が無く exit 128 = null。
// ★`LC_ALL=C`。git の出力が翻訳されると `1 file changed` の形が崩れて null になる。
// ★一過性の失敗(timeout / signal)は**前の値を据え置く**。null で上書きすると、git が
//   1.5 秒 遅れただけでバッジが消える(fail-open)。git が「答え」として非零で終わった時
//   (管理外・HEAD 無し)は null が正しい答えなので上書きする。
// ★同時に飛ばす git は既定 4 本まで。cold start / TTL 切れは 40 本が一斉に来て、
//   負荷で timeout が増え、上の据え置きが無ければ連鎖して全部 null になっていた。
//   溢れた分は撃たずに null(次の poll が 2-3 秒後に来るので其処で拾う)。
// ★鍵は `path.resolve` で正規化(`/a` と `/a/.` を同じ箱に)、箱の上限は既定 512。
import { execFile as nodeExecFile } from "node:child_process";
import path from "node:path";

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
 * @param {number}   [o.maxInflight] 同時に飛ばす git の上限(既定 4)
 * @param {number}   [o.maxEntries]  箱の上限(既定 512。超えたら最も古く入った鍵を落とす)
 */
export function makeDiffCache(o = {}) {
  const exec = o.exec ?? nodeExecFile;
  const ttlMs = o.ttlMs ?? 10_000;
  const now = o.now ?? (() => Date.now());
  const timeoutMs = o.timeoutMs ?? 1500;
  const maxInflight = o.maxInflight ?? 4;
  const maxEntries = o.maxEntries ?? 512;
  /** 正規化した cwd -> { value, at } */
  const store = new Map();
  /** 正規化した cwd -> Promise(飛行中) */
  const inflight = new Map();

  /** git が途中で切られたか(timeout / signal)。非零 exit は「答え」なので偽。 */
  function transient(err) {
    return Boolean(err && (err.killed || err.signal || typeof err.code !== "number"));
  }

  function remember(key, value) {
    store.set(key, { value, at: now() });
    if (store.size > maxEntries) store.delete(store.keys().next().value);
  }

  function refresh(key) {
    if (inflight.has(key)) return inflight.get(key);
    if (inflight.size >= maxInflight) return null;     // 溢れ: 撃たない。次の poll で拾う
    const p = new Promise((resolve) => {
      exec(
        "git",
        ["-C", key, "diff", "--shortstat", "HEAD"],
        { timeout: timeoutMs, env: { ...process.env, LC_ALL: "C" } },
        (err, stdout) => {
          const prev = store.get(key);
          let value;
          if (!err) value = parseShortstat(stdout);
          else if (transient(err) && prev) value = prev.value;   // 据え置き(TTL は進める)
          else value = null;
          remember(key, value);
          inflight.delete(key);
          resolve(value);
        },
      );
    });
    inflight.set(key, p);
    return p;
  }

  return {
    /** 同期。覚えていれば其れを返し、古ければ裏で取り直す。無ければ null を返して裏で取る。 */
    get(cwd) {
      if (typeof cwd !== "string" || !cwd) return null;
      const key = path.resolve(cwd);
      const hit = store.get(key);
      if (!hit || now() - hit.at >= ttlMs) refresh(key);
      return hit ? hit.value : null;
    },
    /** 検査用: 飛行中の取り直しを待つ。 */
    settle(cwd) {
      const key = path.resolve(cwd);
      return inflight.get(key) ?? Promise.resolve(store.get(key)?.value ?? null);
    },
    /** 検査用: 中身を覗く。 */
    _size() { return store.size; },
    /** 検査用: 今 飛んでいる本数。 */
    _inflight() { return inflight.size; },
  };
}
