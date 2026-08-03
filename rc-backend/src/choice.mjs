// 選択メニューへ電話から打鍵してよいかを決める層。**純関数のみ**(tmux も画面取得も持たない)。
//
// ── なぜ許可一覧で、拒否一覧ではないか ──────────────────────────────────
// Tom の裁定(逐語)= 「自動化に安全確認を押させない」。設計 D4 = 「電話から permission
// 承認」は採らない。この2つを満たす実装は**1通りしかない**:
//
//   拒否一覧(「`Do you want to proceed?` が在れば断る」)は、**未観測の文言で fail-open
//   する**。Claude Code の版が上がって確認画面の文言が変われば、その画面は「危険と書いて
//   ないから良性」になる。つまり守りの強さが「私が全部の危険文言を知っている事」に依存する。
//   許可一覧は逆向きに倒れる。知らない画面は良性と名乗れないので**断る**。
//
// 代償は非対称で、それが選ぶ理由:
//   許可一覧の誤り = 安全に答えられた筈のメニューを断る → Tom が画面を見れば回復する
//   拒否一覧の誤り = 自動化が承認を押した            → 回復しない。裁定が名指しで禁じた事
//
// ★この設計の**安全性は下の HARD_STOP に依存しない**。HARD_STOP は「なぜ断ったか」を
//   電話に出す為の材料であって、守りではない。HARD_STOP が1つも当たらなくても、
//   許可一覧に無い画面は `unrecognized` として断る。守りを denylist に置かない。
//   (2026-08-03: 評価の**順序**は hard-stop を先にした。両方に当たる画面が良性へ倒れない為で、
//    守りが denylist へ移ったのではない —— HARD_STOP は断りを**足す**だけ。詳細は classifyChoice)
//
// ── 広げ方 ────────────────────────────────────────────────────────
// 許可一覧を増やす手順は「実物の画面を撮って fixture にし、matcher を足して検査を通す」。
// **一致条件を緩める事で増やしてはいけない**。緩めた瞬間、上の非対称が消える。
//
// ── 出していない口(Tom の裁定待ち。私が決めてよい範囲を超える)────────────
// 「良性と同定できない画面へ `Escape` だけは送る(= 明示的な拒否)」は**採っていない**。
// Escape の向きは取り消しなので裁定の字面には触れないが、D4 は hard-stop を
// 「電話へ通知のみ・承認ボタン無し」と書いており、**画面に操作を出す事自体**を断っている。
// D4 を「承認は禁止、明示的な拒否は可」と読み替えるのは Tom の仕事で、私の解釈で広げない
// (Codex 2026-08-03 も同じ結論: 「開発側の解釈だけで広げるべきではない」)。
import { createHash } from "node:crypto";

/** 番号付き選択肢の行(カーソルの有無を問わない)。 */
export const OPTION_ROW = /^\s*(?:[❯>›→▶]\s*)?\d+\.\s+\S/;
/** 選択カーソル。実装差を吸収するため複数の字体を許す(Codex 指摘④)。 */
export const SELECT_CURSOR = /^\s*[❯>›→▶]\s*\d+\.\s+\S/;
/** 罫線だけの行(`▔` `─` `━` `▁`)。見出しの材料に混ぜない。 */
const RULE_ONLY = /^\s*[▔─━▁_]{4,}\s*$/;
/** 見出しとして拾い上げる非空行の上限。 */
const HEAD_MAX = 4;

const norm = (s) => String(s).replace(/\s+/g, " ").trim();

/**
 * 画面から**メニューの構造**を取り出す。字面ではなく構造を返すのが要点で、
 * これがそのまま指紋の材料になる(生の画面を指紋にするとスピナー1コマで毎回変わる)。
 *
 * @param {string} text        capture-pane の文字列
 * @param {number} composerClose 入力欄の箱の終わり行(-1 = 入力欄なし)。
 *   **ここより上の番号行は履歴**。自分が送った `1. …` をメニューと読まない為で、
 *   `inject.mjs` の menuAt が使っているのと同じ材料を、同じ理由で使う。
 *   この module が `inject.mjs` を import しないのは、依存を一方向に保つ為
 *   (inject.mjs → choice.mjs。逆向きを足すと循環になる)。
 * @returns {null|{head:string[], options:{n:number,label:string,cursor:boolean}[],
 *   cursor:number, footer:string, composerAbsent:boolean}}
 */
export function parseMenu(text, composerClose = -1) {
  const lines = String(text || "").split("\n");
  const opts = [];
  for (let i = 0; i < lines.length; i++) {
    if (composerClose >= 0 && i <= composerClose) continue;
    if (!OPTION_ROW.test(lines[i])) continue;
    const m = /^\s*(?:[❯>›→▶]\s*)?(\d+)\.\s+(.*)$/.exec(lines[i]);
    if (!m) continue;
    opts.push({ i, n: Number(m[1]), label: norm(m[2]), cursor: SELECT_CURSOR.test(lines[i]) });
  }
  if (opts.length < 2) return null; // 単独の番号行はメニューと呼ばない(inject.mjs と同じ判断)

  // 見出し = 最初の選択肢より上の非空・非罫線行。罫線に当たったら**そこで止める**
  // (罫線の向こうは別の箱 = 別の物の説明)。
  const head = [];
  for (let i = opts[0].i - 1; i >= 0 && head.length < HEAD_MAX; i--) {
    const l = lines[i];
    if (RULE_ONLY.test(l)) break;
    if (!l.trim()) continue;
    head.push(norm(l));
  }
  head.reverse();

  const nonEmpty = lines.filter((l) => l.trim());
  return {
    head,
    options: opts.map(({ n, label, cursor }) => ({ n, label, cursor })),
    cursor: opts.find((o) => o.cursor)?.n ?? -1,
    footer: norm(nonEmpty[nonEmpty.length - 1] || ""),
    composerAbsent: composerClose < 0,
  };
}

/**
 * 良性メニューの**許可一覧**。実物の画面を撮った物だけが入る。
 *
 * `keys` = そのメニューで許す打鍵の種別。メニューごとに違ってよい
 * (例えば「Escape だけ許す」matcher を後から足せる)。
 */
export const MATCHERS = [
  {
    name: "select-model",
    version: "2",
    fixture: "choice-model-menu.txt",
    keys: ["digit", "enter", "escape"],
    // `/model`。押して起きるのは既定モデルの切替だけで、道具の実行を承認しないし、
    // 取り返しの付かない事も起きない。★**無害だとは言っていない**(上位モデルへ切り替えれば
    // 利用上限の減りは速くなる)。許可一覧に入れた理由は「間違えても選び直せる」事。
    //
    // ★v1 -> v2(2026-08-03、Codex 指摘): v1 は**見出しと末尾の2つの字面しか見ていなかった**。
    //   選択肢の形を1つも検査していないので、「見出しに `Select model` の行が在り、末尾が
    //   `Enter to set as default` で始まる」画面なら、実際の選択肢が `1. Yes / 2. No` でも
    //   良性と名乗れた。字面の一致は**出自の証明ではない**。so 形も要求する:
    //     - 見出しの**先頭行**が `Select model`(箱の中の1行目。`head` のどこかではない)
    //     - 末尾が `Enter to set as default` で**始まる**(部分一致ではない)
    //     - 選択肢が3つ以上、かつ 1 から**連番**(実機は5つ。Yes/No 型の2択はここで落ちる)
    //   version を上げたのは指紋の材料に `matcher@version` が入っているから。上げないと
    //   v1 で見た画面の指紋が v2 でもそのまま通る。
    test: (m) =>
      m.head[0] === "Select model" &&
      /^Enter to set as default/.test(m.footer) &&
      m.options.length >= 3 &&
      m.options.every((o, i) => o.n === i + 1),
  },
];

/**
 * hard-stop の印。**守りではない**(冒頭の注釈)。断る理由を電話に出す為だけに使う。
 * 当たらなくても許可一覧に無ければ断るので、この式の穴が守りの穴にはならない。
 */
const HARD_STOP =
  /(Do you want to (proceed|continue)|Do you trust|requires confirmation|\/permissions to update rules|[Bb]ypass permissions|weekly limit)/;

/**
 * @returns {{kind:"benign"|"hard-stop"|"unrecognized"|"not-menu", matcher:object|null,
 *   menu:object|null}}
 */
export function classifyChoice(text, composerClose = -1) {
  const menu = parseMenu(text, composerClose);
  if (!menu) return { kind: "not-menu", matcher: null, menu: null };
  // ★入力欄が描かれている画面は、matcher が当たっても良性と名乗らせない。
  //   `inject.mjs` の menuAt が履歴と本物のメニューを割る材料は**それ1つ**
  //   (「メニュー中は入力欄が描かれない」)。入力欄が在るのにメニューに見える画面が
  //   出たら、その前提が破れている = 何が起きているか分からない。実機のメニュー2枚は
  //   どちらも入力欄が無いので、この要求で実物は1枚も落ちない。
  if (!menu.composerAbsent) return { kind: "unrecognized", matcher: null, menu };
  // ★hard-stop を**許可一覧より先**に見る(2026-08-03、Codex 指摘)。順序が逆だと、
  //   両方に当たる画面が良性へ倒れる —— 誤りの向きが承認側になる唯一の並びだった。
  //   これで守りが denylist へ移った訳ではない: HARD_STOP は**断りを足すだけ**で、
  //   1つも当たらなくても許可一覧に無い画面は下で `unrecognized` として断る。
  const hay = [...menu.head, menu.footer, ...menu.options.map((o) => o.label)].join("\n");
  if (HARD_STOP.test(hay)) return { kind: "hard-stop", matcher: null, menu };
  const matcher = MATCHERS.find((x) => x.test(menu)) || null;
  if (matcher) return { kind: "benign", matcher, menu };
  return { kind: "unrecognized", matcher: null, menu };
}

/**
 * その数字に**対応する選択肢が実在するか**。無ければ null。
 *
 * ★2026-08-03(Codex 指摘): `1`-`9` を受け付けておきながら、その番号がメニューに在るかを
 *   一度も見ていなかった。5択の画面へ `7` を打つと何が起きるかは**未定義**で、
 *   少なくとも「電話の利用者が意図した選択肢」ではない。分からない打鍵は打たない。
 */
export function optionFor(menu, key) {
  if (!menu || !/^[1-9]$/.test(key)) return null;
  return menu.options.find((o) => o.n === Number(key)) || null;
}

/**
 * 指紋。**解析後の意味表現**を材料にする(Codex 2026-08-03 の C への答え)。
 *
 * 生の画面をそのまま hash すると、履歴側のスピナーが1コマ進むだけで毎回変わり、
 * 「常に食い違う = 常に断る」検査になる。逆に数字や行を広く削って正規化すると
 * **違う選択肢を同一視する**ので、そちらはもっと危ない。よって削るのではなく、
 * 意味のある欄だけを**並べて**指紋にする。
 *
 * 履歴が動いても指紋が変わらないのは正しい: 指紋が答えるのは「同じメニューか」であって
 * 「画面が1バイトも動いていないか」ではない。
 */
export function digestOf(pane, c) {
  const m = c.menu;
  const src = JSON.stringify([
    pane,
    "CHOICE",
    c.kind,
    c.matcher ? `${c.matcher.name}@${c.matcher.version}` : "-",
    m ? m.head : [],
    m ? m.options.map((o) => `${o.n}|${o.label}`) : [],
    m ? m.cursor : -1,
    m ? m.footer : "",
    m ? m.composerAbsent : false,
  ]);
  return createHash("sha256").update(src).digest("hex").slice(0, 16);
}

/** 電話から受け付ける打鍵。これ以外は 400。 */
export const CHOICE_KEYS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "enter", "escape"];

/** 打鍵 -> 種別(matcher の `keys` と突き合わせる)。 */
export function keyKind(key) {
  if (/^[1-9]$/.test(key)) return "digit";
  if (key === "enter" || key === "escape") return key;
  return null;
}

/**
 * 打鍵 -> `tmux send-keys` の引数。
 *
 * 数字は `-l`(literal)で送る。`send-keys 1` は tmux にとって**繰り返し回数**にも
 * 見える書き方なので、字として送る事を明示する。
 */
export function keyArgs(pane, key) {
  if (/^[1-9]$/.test(key)) return ["send-keys", "-t", pane, "-l", "--", key];
  if (key === "enter") return ["send-keys", "-t", pane, "Enter"];
  if (key === "escape") return ["send-keys", "-t", pane, "Escape"];
  throw new Error("unsupported key"); // 呼ぶ前に CHOICE_KEYS で弾く
}

/**
 * `Escape` の後に置く静穏。
 *
 * 端末は `Esc` + 次の1文字を **Alt シーケンス**として読む事がある(Codex 2026-08-03 の A)。
 * ペイン鍵で要求は直列化されるが、鍵は「重ならない」を保証するだけで「間が空く」は
 * 保証しない。連続した2要求が Esc → `1` を詰めて送ると、`Alt-1` として解釈され得る。
 */
export const ESC_SETTLE_MS = 150;
