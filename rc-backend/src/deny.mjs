/**
 * deny.mjs — 机が持つ拒否規則。2026-08-26 新設。
 *
 * なぜ**机**が持つのか(Codex 2026-08-26 の指摘の核心)
 *   生の打鍵注入は**万能権限**で、エンドポイント単位の権限設計は原理的に迂回される。
 *   電話側の確認も、注入された LLM が「これは危険ではない」と言えば人が押してしまう。
 *   **電話が何を送っても効く層は、机の側にしか作れない。**
 *
 * ★この層が守らない事を先に書く(消さない)
 *   1. **合致しない事は安全の証明ではない。** 規則は既知の物を止めるだけ。
 *      「拒否されなかったから安全」と読ませない為に、通した時は何も言わない。
 *   2. **賢くしない。** 打鍵の中身を解釈して意図を推し量る道は採らない ——
 *      推し量りが外れた時、外れた事に誰も気付けない。素朴な一致だけを見る。
 *   3. **既定は空。** 規則を1本も書いていない機体では、この層が在る前と挙動が1ミリも変わらない。
 *      入れた瞬間に何かが止まる設計だと、入れた人が最初にやるのは規則を消す事になる。
 *
 * 規則の置き場: `~/.rc-backend/deny.json`(同期ツリーの外 = 配備の `--delete` に巻き込まれない)
 *   [{ "id": "no-force-push", "pattern": "git push .*--force", "why": "他人の履歴を壊す" }]
 *
 * ★`why` は必須。理由の書けない規則は、後で誰かが「何だったか分からない」を理由に消す。
 */
import { readFileSync } from "node:fs";

/** 1つの規則が持つべき物。欠けている規則は**読み込まない**(黙って半分効く状態を作らない)。 */
function validRule(r) {
  if (!r || typeof r !== "object") return false;
  if (typeof r.id !== "string" || !/^[a-z0-9][a-z0-9-]{0,63}$/.test(r.id)) return false;
  if (typeof r.pattern !== "string" || r.pattern.length === 0 || r.pattern.length > 500) return false;
  if (typeof r.why !== "string" || r.why.trim().length < 4) return false;
  try { new RegExp(r.pattern, "i"); } catch { return false; }
  return true;
}

/**
 * 規則を読む。
 *
 * ★読めない・壊れている時は**空で返す**(fail-open)。ここだけは fail-closed にしない ——
 *   規則 file が1文字壊れただけで電話から一言も打てなくなるのは、防いでいる害より大きい。
 *   その代わり `error` を返し、呼び手が黙って捨てない形にする。
 *
 * @returns {{rules: object[], error: string|null, skipped: number}}
 */
export function loadRules(path, io) {
  const read = io?.readFileSync ?? readFileSync;
  let raw;
  try { raw = read(path, "utf8"); }
  catch (e) {
    if (e.code === "ENOENT") return { rules: [], error: null, skipped: 0 };  // 未設定 = 正常
    return { rules: [], error: `unreadable:${e.code || "unknown"}`, skipped: 0 };
  }
  let parsed;
  try { parsed = JSON.parse(raw); }
  catch { return { rules: [], error: "bad-json", skipped: 0 }; }
  if (!Array.isArray(parsed)) return { rules: [], error: "not-an-array", skipped: 0 };

  const rules = [];
  let skipped = 0;
  for (const r of parsed) {
    if (validRule(r)) rules.push({ id: r.id, pattern: r.pattern, why: r.why.trim() });
    else skipped++;
  }
  // ★捨てた数を返す。黙って半分読むと「規則を書いたのに効かない」が静かに起きる。
  return { rules, error: skipped > 0 ? `skipped-${skipped}` : null, skipped };
}

/**
 * 打とうとしている本文が、止めるべき物か。
 *
 * @returns {{denied: boolean, id: string|null, why: string|null}}
 */
export function checkDeny(text, rules) {
  if (typeof text !== "string" || text === "") return { denied: false, id: null, why: null };
  for (const r of rules || []) {
    let re;
    try { re = new RegExp(r.pattern, "i"); } catch { continue; }
    if (re.test(text)) return { denied: true, id: r.id, why: r.why };
  }
  // ★ここで「安全」と名乗らない。合致しなかっただけ。
  return { denied: false, id: null, why: null };
}

/**
 * 断りの文。**規則の `why` をそのまま使い、机で作文しない。**
 * 作文すると、Tom が書いた理由と電話に出る文がずれ、どちらが本当か分からなくなる。
 */
export function denyMessage(hit) {
  return `The desk refused to type this: ${hit.why} (rule: ${hit.id})`;
}

/** 机が持っている規則を人が数えられる形で。**中身は返さない**(規則自体が手の内)。 */
export function rulesSummary(loaded) {
  return {
    count: loaded.rules.length,
    // 読み込めなかった規則が在る事は隠さない。「書いたのに効かない」を静かにしない。
    problem: loaded.error,
  };
}
