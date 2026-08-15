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
//   echo "優先順 (.order):"
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
  "not-a-string": "アカウント名が文字列で届いていません。",
  empty: "アカウント名が空です(.order の行が `claude-token-` だけになっている可能性があります)。",
  "too-long": `アカウント名が長すぎます(${ACCOUNT_NAME_MAX}文字まで)。`,
  dot: "`.` と `..` はアカウント名として使えません。",
  "leading-dash": "`-` で始まる名前は切替に使えません(fleet-account が option として読んでしまいます)。",
  "path-separator": "名前に `/` か `\\` が入っています(トークンの置き場所を跨ぐので使えません)。",
  "control-char": "名前に制御文字が入っています。",
  whitespace: "名前に空白が入っています(一覧の桁揃えと見分けが付きません)。",
  "listing-unreadable": "アカウント一覧が読めていないので切替は出来ません(edith の fleet-account の出力形式が変わった可能性があります)。",
  "unknown-account": "そのアカウントは一覧にありません。",
  "no-token": "そのアカウントのトークンが edith にありません。",
};

/** 理由コードを人の読む1文にする。★覆い漏れは `unknownSelectionMessage` に落ちる(検査が押さえる)。 */
export function selectionMessage(reason) {
  return SELECTION_MESSAGES[reason] ?? unknownSelectionMessage(reason);
}

export function unknownSelectionMessage(reason) {
  return `このアカウントは選べません(理由: ${reason})。`;
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
  "no-current-line": "edith の fleet-account が想定と違う形を返しました(1行目が「現用:」ではありません)。切替は出来ません。",
  "no-order-header": "edith の fleet-account が想定と違う形を返しました(「優先順 (.order):」の見出しがありません)。切替は出来ません。",
  "unreadable-rows": "アカウント一覧の行が読めませんでした(fleet-account の出力形式が変わった可能性があります)。半端な一覧は出さずに伏せています。",
};

/** `ok` の時は **null**(出す物が無い)。空文字に化かさない —— `gapNotice` と同じ規律。 */
export function parseStatusMessage(status) {
  if (status === "ok") return null;
  return PARSE_STATUS_MESSAGES[status] ?? unknownParseStatusMessage(status);
}

export function unknownParseStatusMessage(status) {
  return `アカウント一覧の状態が判りません(${status})。`;
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
  "unnamed-row": "名前が空のアカウントが一覧にあります(.order の行が `claude-token-` だけになっている可能性があります)。",
  "order-not-sequential": "一覧の番号が飛んでいます(.order を手で編集した後などに起きます)。表示順は fleet-account の出した順のままです。",
  "duplicate-name": "同じ名前のアカウントが一覧に2つ以上あります。どちらに切り替わるかは fleet-account 側の順序次第です。",
  "current-not-listed": "現用のアカウントが一覧に載っていません(トークンの symlink を手で張り替えた可能性があります)。",
  // ★「本当に0件」と断定していた文を撤回した(2026-08-15、Codex 指摘)。この file の頭が
  //   書いている通り `list_order()` は `.order` が**空・存在しない・読めない**の
  //   どれでも同じ0行を返すので、stdout だけでは3つを区別できない。区別できない物を
  //   断定すると、`.order` が読めない日に Tom が「登録し直す」方へ走る。
  "empty-order": "fleet-account が返した優先順は0件です(.order が空・存在しない・読めない、のいずれでも同じ0行になります)。台本の出力自体は読めているので、通信や解釈の失敗ではありません。",
  "active-name-mismatch": "現用として名乗っているアカウントと、一覧で選択中の印(->)が付いている行が食い違っています。fleet-account の出力が壊れているか、トークンの symlink を手で張り替えた可能性があります。",
};

/** 引っ掛かり1件を人の読む1文にする。★`active-count-<n>` の族もここで畳む。 */
export function anomalyMessage(anomaly) {
  if (typeof anomaly === "string" && anomaly.startsWith(ACTIVE_COUNT_PREFIX)) {
    const n = anomaly.slice(ACTIVE_COUNT_PREFIX.length);
    if (/^\d+$/.test(n)) {
      return n === "0"
        ? "一覧のどの行にも現用の印(->)が付いていません。"
        : `現用の印(->)が${n}行に付いています。fleet-account の出力が壊れている可能性があります。`;
    }
  }
  return ANOMALY_MESSAGES[anomaly] ?? unknownAnomalyMessage(anomaly);
}

export function unknownAnomalyMessage(anomaly) {
  return `一覧に引っ掛かる点があります(${anomaly})。`;
}
