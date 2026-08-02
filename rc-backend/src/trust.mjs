// 会話の居場所(cwd)がワーカーを起こしてよい場所かを**読むだけ**で判定する(DESIGN §2.22 / §3-V)。
//
// ★この file に**書く関数を置かない**。信頼済み dir の登録は人が一度 `claude` を起動して
//   確認画面に答える事で起きる。自動化がそれを代行したら、Tom の standing ruling
//   「自動化に安全確認を押させない」を破る(= 変異 W23)。ここは `readFileSync` だけを持つ。
//
// ★許可根の一覧を**自分で持たない**(§2.22)。持つと「よそに正本がある一覧の写し」を
//   もう1本抱える事になり、Tom が新しい dir で会話を始めた瞬間に電話が黙る。
//   許可集合は Claude Code 自身の信頼済み dir 集合に従わせる。
//
// ★**捨てた守り**を明示する(DESIGN §2.25)。両側を実体へ解決する為、「一覧に在る名前の位置に
//   symlink を植えて別の dir を指す」形は通る。これを捨てたのは、その細工に file 書き込み権が
//   要るから —— その権限が在るなら `~/.claude.json` へ dir を直接足せる。既にこの仕組みが
//   前提から外している脅威より弱い。守っているのは「実体が一致する事」であって「名前」ではない。
import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** 判定が `ok` でない時に返る値の**全域**。文面側(blocked.mjs)はこれを覆う。 */
export const CWD_REFUSALS = ["cwd_unknown", "cwd_missing", "cwd_untrusted"];

/**
 * 信頼一覧の在り処。`RC_PHONE_TRUST_FILE` は**検査用の使い捨て**を差し込む口
 * (`tools/ensure-phone-window.sh:55` と同じ名前)。検査が本物の `~/.claude.json` を
 * 触らない為に在る —— 読むだけとはいえ、本物を読ませると環境で結果が変わる検査になる。
 */
export const trustFilePath = () => process.env.RC_PHONE_TRUST_FILE || join(homedir(), ".claude.json");

/**
 * @returns "ok" | "cwd_unknown" | "cwd_missing" | "cwd_untrusted"
 *
 * fail-closed の向き: 一覧が読めない・壊れている・項が無い —— どれも `cwd_untrusted`。
 * 「確かめられなかった」を「信頼してよい」へ倒さない(`ensure-phone-window.sh` の
 * `unknown` が window を**作らない**側に倒すのと同じ決め事)。
 */
export function cwdVerdict(cwd, opts = {}) {
  const trustFile = opts.trustFile || trustFilePath();
  const realpath = opts.realpath || realpathSync;

  if (!cwd) return "cwd_unknown";

  // ★**両側**を実体へ解決してから突き合わせる(§2.22 / 判断の経緯は DESIGN §2.25)。
  //   守りたい性質は「これから開く実体の dir が、人が承諾した実体の dir と同じ」。
  //   片側(cwd)だけ正規化すると、一覧の鍵が symlink 経由で書かれている会話を偽って断る
  //   —— Tom の実機で実測 59 件中 2 件がその形だった(2026-08-03)。
  let real;
  try {
    real = realpath(cwd);
  } catch {
    return "cwd_missing";
  }

  let json;
  try {
    json = JSON.parse(readFileSync(trustFile, "utf8"));
  } catch {
    return "cwd_untrusted";
  }

  // 速い道: 実体がそのまま鍵に在る(実測 57/59)。1回の hash 引きで終わる。
  let project = json?.projects?.[real];
  if (!project) {
    // 遅い道: 鍵の側が symlink 経由。鍵も解決して突き合わせる。存在しない鍵(実測 19 件)は飛ばす。
    for (const [key, val] of Object.entries(json?.projects || {})) {
      if (key === real) continue;
      let keyReal;
      try {
        keyReal = realpath(key);
      } catch {
        continue;
      }
      if (keyReal === real) {
        project = val;
        break;
      }
    }
  }
  return project && project.hasTrustDialogAccepted === true ? "ok" : "cwd_untrusted";
}
