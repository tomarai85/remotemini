/**
 * 会話の作業場所(cwd)の下を**名前だけ**歩いて、前方一致する path を返す(2026-09-02)。
 *
 * ★何を直しに来たか。`@` の補完が無い事は、それ自体が不便なだけでなく
 *   **別の機能を止めていた** —— `ios/Sources/Screens/List/ListView.swift` の
 *   「新規セッション」の註が「補完が無い以上、電話で path を打たせるのは盲打ち」を
 *   理由に、ディレクトリを選ぶ画面を作らないと決めている。補完が出来ればその判断の
 *   前提が消える(公式 Remote Control の対照表 `research/feature-parity-2026-09-01.md` の #10)。
 *
 * ★★**読むだけ**。開くのは dir だけで、file の中身は1バイトも読まない。
 *   返すのは cwd からの**相対 path** と `file` / `dir` の別の2つだけ ——
 *   大きさも時刻も権限も返さない。「電話が入力欄へ差す為の文字列」以上の物を
 *   線に載せない(`src/attach.mjs` が絶対パスを応答に出さないのと同じ判断)。
 *
 * ★★★**問いを path として使わない。** 此処は `q` を join も resolve も一度もしない ——
 *   歩くのは readdir が返した名前だけで、`q` は出来上がった相対 path に対する
 *   `startsWith` にしか使わない。だから `q = "../../etc"` は「相対 path が `..` で
 *   始まる物は存在しない」で**自然に 0 件**になり、外へ出る道が構造的に無い。
 *   `q` を検査して弾く形(拒否一覧)を採らなかったのは、弾き漏らしが即座に脱出になるから。
 *
 * ★一致は**相対 path の前方一致**で、区切りを跨いでよい(`src/wi` → `src/wire.mjs`)。
 *   曖昧一致(部分一致 / 飛ばし読み)を採らないのは、走査の枝刈りが前方一致からしか
 *   導けないから —— 下の `mayContain` が「其の dir の下に在り得るか」を答えられるのは
 *   前方一致だからで、部分一致にした瞬間に**木を全部歩く以外の手が無くなる**。
 *   有界である事は此の口の設計の中心なので、一致の緩さと引き換えにしない。
 */
import { readdirSync, statSync } from "node:fs";
import { join } from "node:path";

/**
 * 歩かない dir。**大きくて意味が無い**(`ios/tools/xcode-tree-guard.sh` が生成木を
 * 触らないのと同じ理由)。
 *
 * ★除外は**打ち切りではない**。`truncated` を立てない —— あれは「上限に当たったので
 *   途中で止めた」の合図で、此処は最初から範囲外だと決めてある物。混ぜると
 *   `truncated` が常に真になり、電話の「…」が意味を失う。
 * ★候補としても出さない。`node_modules` を差せても其の先へ降りられないので、
 *   出すと「押せるのに何も起きない選択肢」になる。
 */
const SKIP_DIRS = new Set(["node_modules", ".git", "build", "DerivedData"]);

/** 除外の一覧(検査と註が同じ物を読む為に出す)。 */
export const PATHS_SKIPPED = Object.freeze([...SKIP_DIRS]);

/** 深さの上限。cwd 直下を 1 と数える。 */
export const PATHS_MAX_DEPTH = 8;
/** 返す件数の既定と上限。 */
export const PATHS_DEFAULT_LIMIT = 40;
export const PATHS_MAX_LIMIT = 200;
/** 見た項目の上限(dir の中身を1つ見るごとに1)。 */
export const PATHS_ENTRY_BUDGET = 4000;
/** 掛けてよい時間の上限(ms)。 */
export const PATHS_TIME_BUDGET_MS = 250;
/** 問いの長さの上限。之より長い問いは切る(長さで走査を膨らませられない様に)。 */
export const PATHS_QUERY_MAX = 200;

/**
 * 断りの語。**小文字**にするのは `src/reqlog.mjs` の `token()` を通す為 ——
 * 通れば1リクエスト1行の `reason=` に出る。読めない語は行の上で `-` になり、
 * 「答えられなかった」の理由が記録から消える。
 *
 * `no_cwd` は `src/server.mjs` の new の分岐と**同じ綴り**を使う(電話の
 * `NewSessionOutcome.WireCode.noCwd` が既に知っている語)。同じ事実に2つ目の
 * 綴りを作らない。
 */
export const PATHS_NO_CWD = "no_cwd";
export const PATHS_UNREADABLE = "cwd_unreadable";

/** 問いを丸める。**中身は書き換えない**(切るだけ)。 */
export function normalizeQuery(v) {
  const s = String(v ?? "");
  return s.length > PATHS_QUERY_MAX ? s.slice(0, PATHS_QUERY_MAX) : s;
}

/**
 * 件数の上限を枠に収める。読めない値は**既定**へ(0 や負を「全部」と読ませない)。
 *
 * ★空文字を `Number("") === 0` のまま通さない。通すと `?limit=` が「1件」になり、
 *   欄を空にしただけの要求が**最も狭い答え**を返す —— 既定へ落ちるのが正しい。
 *   `reqlog.headerBuild` が「全桁が数字の物だけ」を通すのと同じ、読めない物は
 *   近い値で埋めずに既定/`-` へ倒す判断。
 */
export function clampLimit(v) {
  if (v === null || v === undefined) return PATHS_DEFAULT_LIMIT;
  const s = String(v).trim();
  if (!/^\d{1,9}$/.test(s)) return PATHS_DEFAULT_LIMIT;
  const n = Number(s);
  if (n < 1) return PATHS_DEFAULT_LIMIT;
  return Math.min(PATHS_MAX_LIMIT, n);
}

/**
 * `rel` が問いに当たるか。**前方一致**(区切りを跨ぐ)。
 * 問いが空 = 何にでも当たる。
 */
export function matches(rel, q) {
  return q === "" || rel.startsWith(q);
}

/**
 * `dirRel` の**下**に問いに当たる物が在り得るか(= 降りる価値が在るか)。
 *
 * `dirRel` の子の相対 path は必ず `dirRel + "/" + 名前` なので、
 * 或る名前で `q` に前方一致し得る条件は「`dirRel + "/"` と `q` の**どちらかが
 * 他方の接頭辞**である」に丁度一致する:
 *   - `q` の方が短い/等しい → `dirRel + "/"` が `q` で始まれば、どの名前でも当たる
 *   - `q` の方が長い       → `q` が `dirRel + "/"` で始まれば、残りで始まる名前が当たる
 *
 * 根(`dirRel === ""`)は子の相対 path が名前そのものなので、常に降りる。
 */
export function mayContain(dirRel, q) {
  if (q === "") return true;
  if (dirRel === "") return true;
  const p = `${dirRel}/`;
  return p.startsWith(q) || q.startsWith(p);
}

/**
 * dirent 1つの種別。読めない物・入力に差せない物(socket / fifo / device)は `null`。
 *
 * ★symlink は `stat` して**解決先**で名乗る。名乗りだけ file にして dir を隠すと、
 *   電話は差した後に「其の先が無い」を自分で見つける事になる。
 * ★但し symlink の先へは**降りない**(呼ぶ側が判断する)。輪を作られると有界でなくなる。
 */
export function kindOf(dirent, abs, stat) {
  if (dirent.isDirectory()) return "dir";
  if (dirent.isFile()) return "file";
  if (dirent.isSymbolicLink()) {
    try {
      const st = stat(abs);
      return st.isDirectory() ? "dir" : st.isFile() ? "file" : null;
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * `root` の下を幅優先で歩き、`q` に前方一致する相対 path を返す。
 *
 * @returns {{paths: {path: string, kind: "file"|"dir"}[], truncated: boolean, reason: string|null}}
 *
 * ★幅優先なのは、補完で先に見たいのが**浅い物**だから。深さ優先だと、根の2番目の
 *   dir に用が在る時でも1番目の dir の底まで先に並ぶ。
 * ★`q` が空の時は**直下だけ**。全走査を「一致が緩い」に紛れて起こさない為で、
 *   之は上限ではなく**仕様**なので `truncated` を立てない(下の `shallow`)。
 * ★並びは名前順に固定する。`readdir` の順は file system 次第で、順が揺れると
 *   同じ問いで違う候補が出る = 検査が「たまたま緑」になる。
 */
export function completePaths(root, rawQuery, opts = {}) {
  const q = normalizeQuery(rawQuery);
  const shallow = q === "";
  const limit = clampLimit(opts.limit ?? PATHS_DEFAULT_LIMIT);
  const maxDepth = shallow ? 1 : Math.max(1, opts.maxDepth ?? PATHS_MAX_DEPTH);
  const entryBudget = Math.max(1, opts.entryBudget ?? PATHS_ENTRY_BUDGET);
  const msBudget = Math.max(1, opts.msBudget ?? PATHS_TIME_BUDGET_MS);
  const now = opts.now ?? (() => Date.now());
  const readdir = opts.readdir ?? ((p) => readdirSync(p, { withFileTypes: true }));
  const stat = opts.stat ?? ((p) => statSync(p));
  const dirsOnly = opts.dirsOnly === true; // 既定 false = 会話側の `@` 補完は 1 バイトも変わらない

  const startedAt = now();
  const paths = [];
  let truncated = false;
  let seen = 0;

  // 根が読めない = 机に其の場所が無い(消えた / 権限が無い)。**空 + 語**で答える。
  // 500 にしないのは、電話にとって次の一手が同じだから —— 補完は出ないが会話は使える。
  let rootEntries;
  try {
    rootEntries = readdir(root);
  } catch {
    return { paths: [], truncated: false, reason: PATHS_UNREADABLE };
  }

  // `depth` = **その node が並べる項目の深さ**(根の直下 = 1)。
  const queue = [{ abs: root, rel: "", depth: 1, entries: rootEntries }];
  let head = 0;

  walk: while (head < queue.length) {
    const node = queue[head];
    head += 1;
    let entries = node.entries;
    if (!entries) {
      try {
        entries = readdir(node.abs);
      } catch {
        // 途中の dir が読めないのは**其の枝だけ**の事情。根と違って全体の答えを
        // 断る理由にはならないので飛ばす。★但し見落としを黙らせない為に打ち切りを名乗る。
        truncated = true;
        continue;
      }
    }
    entries = [...entries].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));

    for (const e of entries) {
      seen += 1;
      if (seen > entryBudget || now() - startedAt > msBudget) {
        truncated = true;
        break walk;
      }
      const rel = node.rel ? `${node.rel}/${e.name}` : e.name;
      const abs = join(node.abs, e.name);
      const kind = kindOf(e, abs, stat);
      if (kind === null) continue;
      // 生成木は候補にも出さず、降りもしない(上の註)。
      if (kind === "dir" && SKIP_DIRS.has(e.name)) continue;

      if (matches(rel, q)) {
        // ★`dirsOnly`(2026-09-03、roots の口)は**此処で**落とす。route 側で「多めに取って後で削る」と
        //   `limit` と `truncated` が嘘になる(削った分だけ少なく返し、打ち切りの印は立たない)。
        //   降りる判断(下の queue.push)は変えない = file を落としても dir の中は歩く。
        if (dirsOnly && kind !== "dir") continue;
        if (paths.length >= limit) {
          truncated = true;
          break walk;
        }
        paths.push({ path: rel, kind });
      }

      if (kind === "dir" && !e.isSymbolicLink() && mayContain(rel, q)) {
        if (node.depth + 1 > maxDepth) {
          // ★`shallow` は仕様(問いが空 = 直下だけ)なので打ち切りではない。
          if (!shallow) truncated = true;
        } else {
          queue.push({ abs, rel, depth: node.depth + 1, entries: null });
        }
      }
    }
  }

  return { paths, truncated, reason: null };
}
