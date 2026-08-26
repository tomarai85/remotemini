/**
 * risk.mjs — 電話に出す承認要求の**危険度**を1語で返す。2026-08-26 新設。
 *
 * なぜ要るか(研究 2026-08-26、`.harness/evidence-2026-08-26/research-mobile-dev-tools.md`)
 *   調べた全ての製品(Claude Code Remote Control / Cursor / Codex mobile / CodeAgent Mobile)が
 *   承認を**一律の y/n** で出している。中身を見て重さを変える物が1つも無い。
 *   引用された実例: 移動中に承認した1つが本番の列を落とす操作だった。
 *   小さい画面で急いで押す人にとって、`ls` の確認と再帰削除の確認が同じ顔なのは欠陥。
 *
 * ★この層が**やらない**事(ここを誤解すると危険側に倒れる)
 *   1. **許可を増やさない / 減らさない。** 押せる物は今まで通り。変えるのは**表示の重さ**だけ。
 *      許可の出所は1つ(サーバの `keys`)のまま保つ。
 *   2. **「安全」と言わない。** 一致しなかった事は安全の証明ではない。返すのは
 *      `unmatched` = 「既知の危険語に当たらなかった」。この語を UI が「安全」と
 *      言い換えたら、それはこの層の嘘ではなく UI の嘘になる。
 *   3. **下げない。** 一度 danger に当たった要求を、別の語が当たらなかった事で下げる経路は無い。
 *
 * 返り値: { tier: "danger"|"caution"|"unmatched", signals: [{ id, why }] }
 *   danger   … 取り返しがつかない / 本番に触る / 資格情報に触る
 *   caution  … 外へ出る / 版を動かす(戻せるが、他人から見える)
 *   unmatched… 既知の語に当たらなかった(= 安全ではない)
 */

/**
 * ★語の一覧は**この1箇所**に置く。判定を2箇所に書くと、片方だけが古くなり、
 *   「直したのに効かない」型の欠陥になる(この repo が何度も踏んだ形)。
 * ★`why` は電話に出す1文。人が読んで**何が怖いか**が判る事だけを書く。
 */
const RULES = [
  // --- danger: 取り返しがつかない ---------------------------------------
  ["recursive-delete", "danger", /\brm\s+(-[a-zA-Z]*[rR][a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*[rR])\b/, "ファイルを再帰的に消します"],
  ["drop",             "danger", /\bDROP\s+(TABLE|DATABASE|SCHEMA|COLUMN|INDEX)\b/i,             "データベースの構造を落とします"],
  ["truncate",         "danger", /\bTRUNCATE\s+(TABLE\s+)?\w/i,                                  "テーブルの中身を全部消します"],
  ["delete-all",       "danger", /\bDELETE\s+FROM\s+[\w."`[\]]+\s*(;|$)/i,                        "WHERE の無い DELETE = 全行消えます"],
  ["history-rewrite",  "danger", /\bgit\s+push\b[^\n]*\s(--force\b|--force-with-lease\b|-f\b)/, "他人の履歴を上書きします"],
  ["hard-reset",       "danger", /\bgit\s+reset\s+--hard\b/,                                 "未 commit の変更が消えます"],
  ["clean-untracked",  "danger", /\bgit\s+clean\s+-[a-zA-Z]*d[a-zA-Z]*f|\bgit\s+clean\s+-[a-zA-Z]*f[a-zA-Z]*d/, "追跡外のファイルを消します"],
  ["disk-wipe",        "danger", /\bmkfs\b|\bdd\s+if=|\bdiskutil\s+(erase|reformat)/i,            "ディスクを初期化します"],
  ["unload-service",   "danger", /\blaunchctl\s+(unload|bootout|remove)\b/,                       "常設サービスを止めます"],
  ["power",            "danger", /\b(shutdown|reboot|halt)\b\s+-/,                                "機械を落とします"],
  ["secrets",          "danger", /\.env\b|\bid_rsa\b|\bprivate[_-]?key\b|\bAPI[_-]?KEY\s*=/i,     "資格情報に触ります"],
  ["world-writable",   "danger", /\bchmod\s+(-[a-zA-Z]+\s+)?777\b/,                               "誰でも書ける権限にします"],
  ["elevated",         "danger", /(^|\s)sudo\s+\S/,                                               "管理者権限で走ります"],
  ["pipe-to-shell",    "danger", /\b(curl|wget)\b[^\n|]*\|\s*(sudo\s+)?(ba|z|)sh\b/,              "落とした物をそのまま実行します"],
  // --- caution: 戻せるが、外から見える ------------------------------------
  ["remote-write",     "caution", /\bgit\s+push\b/,                                          "他人が見る場所へ出ます"],
  ["publish",          "caution", /\b(npm|yarn|pnpm)\s+publish\b|\bpod\s+trunk\s+push\b/,     "公開の場所へ出ます"],
  ["deploy",           "caution", /\b(deploy|vercel\s+--prod|fly\s+deploy|kubectl\s+apply)\b/i,    "本番へ出ます"],
  ["migrate",          "caution", /\b(migrate|migration)\b/i,                                     "データの形を変えます"],
  ["outbound",         "caution", /\b(send|post)\b[^\n]{0,40}\b(mail|email|slack|discord|dm)\b/i,  "外部へ送ります"],
];

const ORDER = { danger: 2, caution: 1, unmatched: 0 };

/**
 * @param {unknown} texts 画面から取れた文字列(見出し・選択肢・要約など)。配列でも1本でもよい。
 * @returns {{tier: "danger"|"caution"|"unmatched", signals: {id: string, why: string}[]}}
 */
export function classifyRisk(texts) {
  const list = (Array.isArray(texts) ? texts : [texts])
    .filter((t) => typeof t === "string" && t !== "");
  // ★入力が空 = 判定材料が無い。**unmatched を返すが、それは「安全」ではない。**
  //   ここで caution へ上げない理由: 材料が無い事を毎回警告に化けさせると、
  //   本物の警告が「いつも出ている物」になって効かなくなる。
  if (list.length === 0) return { tier: "unmatched", signals: [] };

  const hay = list.join("\n");
  const signals = [];
  let tier = "unmatched";
  for (const [id, level, re, why] of RULES) {
    if (!re.test(hay)) continue;
    signals.push({ id, why });
    // ★上げるだけ。当たらなかった語が、当たった語を打ち消す事は無い。
    if (ORDER[level] > ORDER[tier]) tier = level;
  }
  return { tier, signals };
}

/**
 * 分類器の版。**信号と一緒に電話へ送る**(Codex 2026-08-26 #4)。
 * 語の一覧を増やしても電話は自分で分類しない設計なので、電話に「どの版が判定したか」が
 * 無いと、古いサーバが出した弱い判定と新しい判定を区別できない。
 * 語を足したら**必ず上げる**。
 */
export const RISK_CLASSIFIER_VERSION = 1;

/**
 * 電話に出す1行。
 *
 * ★2026-08-26 に **unmatched を無言から明文へ変えた**(Codex の最強の反論を採用)。
 *   元は空文字にしていた。狙いは「当たらなかった」を UI が「安全です」と言い換える
 *   材料を渡さない事だったが、Codex の指摘はその逆側だった ——
 *   **帯が出ない事そのものが「安全」の合図として読まれる**。しかも帯を目立たせるほど、
 *   帯の無い要求は今より雑に押される(この機能が状況を悪化させ得る唯一の経路)。
 *   沈黙は中立ではないので、沈黙をやめて**検査していない事を明言する**。
 *   「安全」とは書かない、という元の一線はそのまま守る。
 */
export function riskNotice(tier) {
  switch (tier) {
    case "danger":  return "This action is hard to undo. Read it before you tap.";
    case "caution": return "This goes somewhere other people can see.";
    default:        return "Not checked against known hazards — read it yourself.";
  }
}
