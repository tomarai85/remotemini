// `fleet-account` の**人向け出力**を構造に直す暫定アダプター。
//
// ★暫定である事の意味(2026-08-14):
//   `fleet-account` は edith 上の `~/fleet-tools/fleet-account`(75行の bash)で、
//   **この repo の git 管理外**、艦隊レーンの持ち物、OAuth トークンの symlink を
//   差し替える台本。正しい直し方は「あの台本に `--json` を足す」だが、それは
//   他レーンの資産を許可なく書き換える事になるので採らない(艦隊レーンへの提案として出す)。
//   ここは**その提案が通るまでの繋ぎ**。通ったらこの file 全体が消える。
//
// ★だから解析を server.mjs に埋めない:
//   `server.mjs` は import した瞬間に listen するのでハンドラ内の literal は単体検査から
//   一度も呼べない(wire.mjs 冒頭と同じ理由)。繋ぎのコードほど、**消す時に何が壊れるか**が
//   検査で見えていないと消せなくなる。
//
// ★この層が守る一線 = 「読めなかった」と「本当に0件だった」を混ぜない。
//   台本の出力が変わった時に「アカウントが1つも無い」と表示するのが最悪の壊れ方
//   (電話側は切替を諦めるべきなのに、単に候補が消えたように見える)。
//   → `parseStatus !== "ok"` は**読めていない**、`accounts: []` かつ `ok` は**本当に空**。
//
// ★node の API を import しない(純関数 = 検査が listen 無しで読める)。

// 台本の実出力の literal。`show()` の printf をそのまま写した物 —
//   echo "現用: $(label "$cur")"  /  echo "現用: （未設定）"
//   echo "Priority (.order):"
//   printf "  %s %d. %-8s トークン:%s\n" "$mark" "$i" "$(label "$t")" "$have"
const CURRENT_PREFIX = "現用:";
const UNSET_LABEL = "（未設定）";
const ORDER_HEADER = "優先順 (.order):";
const ROW = /^\s*(->)?\s*(\d+)\.\s+(.*?)\s+トークン:(有|欠)$/;

/** 名前の上限。台本側に上限は無いが、際限なく長い名前を素通しする理由も無い。 */
export const ACCOUNT_NAME_MAX = 64;

/**
 * 切替先として受け取ってよい名前か。null = 問題なし、文字列 = 断る理由。
 *
 * ★白名簿(一覧に在る事)だけでは足りない — Codex の指摘(2026-08-14):
 *   台本の `case "$1"` は `--next` を `*)` より先に拾うので、`--next` という名の
 *   アカウントが `.order` に在ると「切替」ではなく「次へ送る」が走る。
 *   一覧に在る事は、その名前が**引数として安全**である事を意味しない。
 *   だから白名簿と**別に**この不変条件を通す(両方必須)。
 */
export function accountNameProblem(name) {
  if (typeof name !== "string") return "not-a-string";
  if (name.length === 0) return "empty";
  if (name.length > ACCOUNT_NAME_MAX) return "too-long";
  if (name === "." || name === "..") return "dot";
  if (name.startsWith("-")) return "leading-dash"; // `--next` / `-h` / `--help` が此処で落ちる
  if (/[/\\]/.test(name)) return "path-separator"; // `$TOKDIR/claude-token-<name>` を組むので
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(name)) return "control-char";
  if (/\s/.test(name)) return "whitespace"; // %-8s の詰めと区別が付かなくなる
  return null;
}

function empty(parseStatus, current = null) {
  return { current, accounts: [], parseStatus, anomalies: [] };
}

/**
 * `fleet-account`(引数なし)の標準出力を構造に直す。
 *
 * 返り値:
 *   current     現用アカウント名(symlink 未設定なら null)
 *   accounts    [{ name, order, hasToken, active }] — `.order` の並び順
 *   parseStatus "ok" = 出力を読み切った / それ以外 = **読めていない**(切替を出してはいけない)
 *   anomalies   読めてはいるが引っ掛かる点(表示は出してよい。切替の可否は呼び手が決める)
 *
 * ★`accounts: []` + `parseStatus: "ok"` は起こりうる正当な状態:
 *   `list_order()` は `.order` が読めなければ 0 行返すので、見出しだけ出て行が0本になる。
 *   これは「本当に候補が無い」= 台本の出力は読めている。読めていない状態と混ぜない。
 */
export function parseFleetAccount(stdout) {
  const lines = String(stdout ?? "").split("\n").map((l) => l.replace(/\s+$/, ""));
  while (lines.length && lines[lines.length - 1] === "") lines.pop();

  const head = lines[0];
  if (typeof head !== "string" || !head.startsWith(CURRENT_PREFIX)) return empty("no-current-line");
  const label = head.slice(CURRENT_PREFIX.length).trim();
  const current = label === UNSET_LABEL || label === "" ? null : label;

  if (lines[1] !== ORDER_HEADER) return empty("no-order-header", current);

  const anomalies = [];
  const accounts = [];
  for (let i = 2; i < lines.length; i++) {
    const m = ROW.exec(lines[i]);
    // 1行でも読めなければ一覧全体を信じない。半分だけ読んだ一覧は、
    // 「候補が減った」という**間違った真実**として表示されてしまう。
    if (!m) return empty("unreadable-rows", current);
    const name = m[3];
    accounts.push({ name, order: Number(m[2]), hasToken: m[4] === "有", active: m[1] === "->" });
    if (name === "") anomalies.push("unnamed-row");
  }

  for (let i = 0; i < accounts.length; i++) {
    if (accounts[i].order !== i + 1) { anomalies.push("order-not-sequential"); break; }
  }
  const names = accounts.map((a) => a.name);
  if (new Set(names).size !== names.length) anomalies.push("duplicate-name");

  if (accounts.length === 0) {
    // ★見出しは在るのに行が0本。台本の出力は**読めている**ので degraded ではないが、
    //   黙って空の一覧を渡すと、電話には「候補が1つも無い」と「読めなかった」が
    //   同じ顔で出る —— この file の頭が守ると言っている一線そのもの。
    //   `parseStatus` は "ok" のまま(読めたのは事実)、引っ掛かりとして1行載せる。
    anomalies.push("empty-order");
    // ★下の2つは**行の中身から導く**判定なので、行が0本の時は回さない。回すと
    //   `current-not-listed`(「現用が一覧に載っていません」= symlink を疑わせる)と
    //   `active-count-0`(「どの行にも印が付いていません」= 行が在る前提の文)が出て、
    //   空の一覧に**行が在るかの様な誤診**を2行並べる事になる。空である事の方が上位。
  } else {
    const marked = accounts.filter((a) => a.active);
    if (current !== null && marked.length !== 1) anomalies.push(`active-count-${marked.length}`);
    // ★印が**1行に付いているのに、その行が現用ではない**(2026-08-15、Codex 指摘)。
    //   `active-count-` は印の**本数**しか見ないので、`現用: team` と `-> biz` が
    //   同時に出ている出力は本数1で通り、引っ掛かりが1件も付かないまま
    //   「現用 team / 選択中 biz」という**矛盾した画面**が出る。名前まで突き合わせる。
    if (current !== null && marked.length === 1 && marked[0].name !== current) {
      anomalies.push("active-name-mismatch");
    }
    // symlink の指す先が `.order` に載っていない事は実際に起こる(手で張り替えた等)。
    // 一覧は正しいので degraded にはしないが、黙って捨てると現用が画面から消える。
    if (current !== null && !names.includes(current)) anomalies.push("current-not-listed");
  }

  return { current, accounts, parseStatus: "ok", anomalies };
}

/**
 * `name` へ切り替えてよいか。null = よい、文字列 = 断る理由(そのまま機械可読の理由コード)。
 *
 * 順序に意味がある: **名前の不変条件を先に見る**。一覧に在るかどうかより前に
 * 「引数として安全か」を確かめないと、`--next` の様な名前が白名簿を通ってしまう。
 */
export function selectionProblem(parsed, name) {
  const bad = accountNameProblem(name);
  if (bad) return bad;
  if (!parsed || parsed.parseStatus !== "ok") return "listing-unreadable";
  const hit = parsed.accounts.find((a) => a.name === name);
  if (!hit) return "unknown-account";
  if (!hit.hasToken) return "no-token";
  return null;
}

/**
 * `selectionProblem` が返しうる理由の全域。★ここが正本。
 * `null`(選べる)は入れない。
 */
export const SELECTION_REASONS = [
  "not-a-string", "empty", "too-long", "dot", "leading-dash",
  "path-separator", "control-char", "whitespace",
  "listing-unreadable", "unknown-account", "no-token",
];

const SELECTION_MESSAGES = {
  "not-a-string": "The account name did not arrive as a string.",
  empty: "The account name is empty (an .order line may contain only `claude-token-`).",
  "too-long": `The account name is too long (max ${ACCOUNT_NAME_MAX} chars).`,
  dot: "`.` and `..` cannot be used as an account name.",
  "leading-dash": "Names starting with `-` cannot be switched to (fleet-account would read them as an option).",
  "path-separator": "The name contains `/` or `\\` (it would cross the token directory).",
  "control-char": "The name contains control characters.",
  whitespace: "The name contains whitespace (indistinguishable from list padding).",
  "listing-unreadable": "The account list is unreadable, so switching is unavailable (fleet-account's output format may have changed).",
  "unknown-account": "That account is not in the list.",
  "no-token": "That account's token is missing on edith.",
};

/** 理由コードを人の読む1文にする。★覆い漏れは `unknownSelectionMessage` に落ちる(検査が押さえる)。 */
export function selectionMessage(reason) {
  return SELECTION_MESSAGES[reason] ?? unknownSelectionMessage(reason);
}

export function unknownSelectionMessage(reason) {
  return `This account cannot be selected (reason: ${reason}).`;
}

// --- 状態コードの人語(★`paneFault` で一度やった失敗と同型を塞ぐ) --------------
//
// `parseStatus` / `anomalies` は**内部の英語トークン**。2026-08-08 の監査 S8-22 で、
// 一覧が出ない時の帯に `reason`(英語)と生の `e.message` が**そのまま描かれていた** ——
// 旅程で一番踏みそうな画面が日本語ですらなかった。同じ物をここで作らない。
// 観測値(`parseStatus` / `anomalies`)は残す(診断用)。描くのは `display` 側。

/** `parseFleetAccount` が返しうる `parseStatus` の全域。★ここが正本。 */
export const PARSE_STATUSES = ["ok", "no-current-line", "no-order-header", "unreadable-rows"];

const PARSE_STATUS_MESSAGES = {
  "no-current-line": "fleet-account on edith returned an unexpected shape (the first line is not 「現用:」). Switching is unavailable.",
  "no-order-header": "fleet-account on edith returned an unexpected shape (the 「優先順 (.order):」 header is missing). Switching is unavailable.",
  "unreadable-rows": "Account list rows were unreadable (fleet-account's output format may have changed). A partial list is withheld rather than shown.",
};

/** `ok` の時は **null**(出す物が無い)。空文字に化かさない —— `gapNotice` と同じ規律。 */
export function parseStatusMessage(status) {
  if (status === "ok") return null;
  return PARSE_STATUS_MESSAGES[status] ?? unknownParseStatusMessage(status);
}

export function unknownParseStatusMessage(status) {
  return `The account list state is unknown (${status}).`;
}

/**
 * `anomalies` の全域。`active-count-<n>` だけは**族**(n は 0 と 2 以上)なので
 * 接頭辞で持つ。域の検査は「族の代表を2つ」で押さえる。
 */
export const ACTIVE_COUNT_PREFIX = "active-count-";
export const ANOMALY_REASONS = [
  "unnamed-row", "order-not-sequential", "duplicate-name", "current-not-listed", "empty-order",
  "active-name-mismatch",
];

const ANOMALY_MESSAGES = {
  "unnamed-row": "An account with an empty name is in the list (an .order line may contain only `claude-token-`).",
  "order-not-sequential": "List numbering has gaps (can happen after hand-editing .order). Display order follows fleet-account's output.",
  "duplicate-name": "Two or more accounts share the same name. Which one a switch lands on depends on fleet-account's ordering.",
  "current-not-listed": "The current account is not in the list (the token symlink may have been relinked by hand).",
  // ★「本当に0件」と断定していた文を撤回した(2026-08-15、Codex 指摘)。この file の頭が
  //   書いている通り `list_order()` は `.order` が**空・存在しない・読めない**の
  //   どれでも同じ0行を返すので、stdout だけでは3つを区別できない。区別できない物を
  //   断定すると、`.order` が読めない日に Tom が「登録し直す」方へ走る。
  "empty-order": "fleet-account returned zero priority entries (.order being empty, missing, or unreadable all produce the same zero rows). The script's own output was readable, so this is not a transport or parse failure.",
  "active-name-mismatch": "The account named as current and the row marked selected (->) disagree. fleet-account's output may be corrupted, or the token symlink was relinked by hand.",
};

/** 引っ掛かり1件を人の読む1文にする。★`active-count-<n>` の族もここで畳む。 */
export function anomalyMessage(anomaly) {
  if (typeof anomaly === "string" && anomaly.startsWith(ACTIVE_COUNT_PREFIX)) {
    const n = anomaly.slice(ACTIVE_COUNT_PREFIX.length);
    if (/^\d+$/.test(n)) {
      return n === "0"
        ? "No row in the list carries the current marker (->)."
        : `The current marker (->) appears on ${n} rows. fleet-account output may be corrupted.`;
    }
  }
  return ANOMALY_MESSAGES[anomaly] ?? unknownAnomalyMessage(anomaly);
}

export function unknownAnomalyMessage(anomaly) {
  return `The list has an anomaly (${anomaly}).`;
}
