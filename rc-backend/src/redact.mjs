/**
 * 外へ出す文字列から「出てはいけない形」を伏せる。
 *
 * ★**これは拒否一覧(denylist)であって fail-closed ではない**。知っている形しか捕まえられない。
 *   自由書式の stderr に対して許可一覧を書く事はできない(書けば診断そのものが消える)ので、
 *   ここは意図的に緩い側に倒してある。**残余リスクを明記した上で採用した**判断:
 *     - 出す先 = Tom 自身の電話(tailnet 越し)。第三者に配る面ではない。
 *     - repo / transcript には**この tail を書かない**。書くと `check-no-pii.sh` の面が増える。
 *     - 網は `test/redact.test.mjs` の陰性対照で**形ごとに**固定する。網を外す = 変異 W17。
 *
 * ★呼ぶ順序の罠: **伏せてから切る**。ここの網は**形の全体**を要求する —— メールなら
 *   `@ドメイン.tld` まで揃って初めて一致する。先に切ると `client-a.team@gm` のように
 *   **一番読まれたくない左半分だけが残って網を抜ける**(= 変異 W18)。
 *   踏むのは行が上限に達した時だけだが、順序を逆にしてよい理由が1つも無い。
 */

/** メール = edith の `account=` 行が実際にここへ来る(2026-08-02 実機で観測)。 */
const MAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;

/** Discord の webhook は URL 自体が鍵。 */
const WEBHOOK = /https?:\/\/(?:ptb\.|canary\.)?discord(?:app)?\.com\/api\/webhooks\/\S+/gi;

/** 頭が決まっている鍵。長さの下限を付けて、ただの単語を潰さない。 */
const PREFIXED = new RegExp(
  [
    "sk-ant-[A-Za-z0-9_-]{8,}",
    "sk-[A-Za-z0-9]{16,}",
    "ghp_[A-Za-z0-9]{16,}",
    "gho_[A-Za-z0-9]{16,}",
    "github_pat_[A-Za-z0-9_]{20,}",
    "GOCSPX-[A-Za-z0-9_-]{8,}",
    "xox[baprs]-[A-Za-z0-9-]{8,}",
    "AKIA[0-9A-Z]{12,}",
    "AIza[A-Za-z0-9_-]{20,}",
  ].join("|"),
  "g",
);

/** `Authorization: Bearer xxx` の類。 */
const BEARER = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi;

/** `token=xxx` / `password: xxx` の類。名前で当てるので値の形は問わない。 */
const NAMED = /\b(api[_-]?key|apikey|token|secret|password|passwd|authorization)(\s*[=:]\s*)\S+/gi;

/**
 * @param {unknown} s
 * @returns {string} 伏せ字を適用した文字列。文字列でない入力は `String()` で寄せる。
 */
export function redact(s) {
  return String(s ?? "")
    .replace(WEBHOOK, "<webhook>")
    .replace(MAIL, "<mail>")
    .replace(PREFIXED, "<秘匿>")
    .replace(BEARER, "$1 <秘匿>")
    .replace(NAMED, "$1$2<秘匿>");
}
