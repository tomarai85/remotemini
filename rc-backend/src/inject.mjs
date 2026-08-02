// tmux 注入層 — 動いている対話 Claude に iPhone からの入力を届ける。
//
// なぜこの形か(DESIGN.md §2.9):
//   Tom 裁定「返答待ちであれ作業中であれいつでも見て干渉できればいい」。
//   別プロセスで claude -p を起こすと同じ会話を2実行が読む(lost-update)。
//   動いているペインに直接注入すれば会話は1プロセスのままで、その問題が原理的に消える。
//
// ★2026-08-01 全面改訂。それまでの状態機械は**存在しない状態を調整していた**。
// 使い捨てセッションで 0.25 秒刻みに 240 枚の画面を撮って分かったこと:
//   M1 `esc to interrupt` はこのビルドの画面に存在しない(240/0)。唯一の BUSY 材料が
//      これだったので、BUSY は一度も発火しておらず、キュー経路は死んでいた。
//   M3 進行中スピナーは 6.5 秒の生成中に 8/26 サンプルしか見えない(31%)。残りは同じ行を
//      tmux のヒント文が占拠する。→ **画面から「生成中」を遮断条件にはできない**。
//   M4 生成中も入力欄の `❯` は出たまま。「プロンプトが見える = 待機中」も成り立たない。
//   M5 生成中に本文→Enter を送ると生成は中断されず完走し、**TUI 自身がキューして**
//      (`❯ Press up to edit queued messages`)次のターンとして処理した。
//
// そこから決めた3点(全て Codex 二次レビュー 2026-08-01 と整合):
//   1. 自前キューは撤去。TUI が正しく持っている機能の二重実装で、固有の挙動は
//      「状態判定を外した時に本文を滞留させる」ことだけ。M3 はそれが7割外れると言っている。
//      契約は「最善努力・拒否は明示・電話から再送」。
//   2. 送信可否を「生成中か」で決めない。**composer(入力欄)が実在するか**で決める。
//      `READY`(= BUSY でない、という消極的定義)を捨て `SENDABLE`(積極的定義)にする。
//      分からなければ UNKNOWN = 送らない。「生成中でない」は「送ってよい」ではない。
//   3. 判定は **viewport だけ**を見る(`capture-pane -p`、`-S` 無し)。7/31・8/01 に踏んだ
//      失敗は2回とも「消えない過去の行を今の状態と読んだ」。範囲を今の画面に限れば
//      この失敗の型そのものが消える。
//
// 7/31 実機で確かめた規約は生きている:
//   - 本文と Enter は別送信(生成中の一括送信はバッファされ、完了後に誤送信される)
//   - 割り込みは Escape のみ。C-c は画面状態で消去/中断/終了に化ける

/**
 * 入力欄を囲む罫線。Claude Code は composer を上下の `─` 行で挟んで描く。
 *
 * ★**桁0から始まる事**を要求する(字下げを許さない)。理由は本文そのものが罫線文字を
 * 含む場合で、実測(2026-08-01)では `この表を直して⏎────────⏎以上` を打つと画面は
 *   `❯ この表を直して` / `  ────────` / `  以上`
 * となり、字下げを許した旧版は本文の中の罫線を箱の一部と読んで `composerBox = null`
 * → `composer-mismatch` → **本文が残ってペインが固着**した(欠陥3/5と同じ壊れ方)。
 * 本物の罫線は端末幅いっぱいで必ず桁0から始まり、入力欄の中の行は `❯ ` か2桁字下げで
 * 始まるので、この1文字分の差が両者を完全に分ける。
 * 実測の裏取り(実機 fixture 17枚): 桁0から始まる罫線 29本に対し、**字下げされた罫線は1本だけ**
 * — それがこの `composer-rule-in-body` の本文の中の罫線、つまり除外すべき当の物だった。
 * 不変量として `test/inject.test.mjs` に固定してある(fixture が増えても崩れたら赤になる)。
 */

import { makeKeyedMutex, MUTEX_BUSY, MUTEX_ABORTED } from "./mutex.mjs";

const BOX_RULE = /^─{8,}\s*$/;
/** composer の行。`❯` で始まる(空でも `Press up to edit queued messages` でも同じ)。 */
const COMPOSER_HEAD = /^\s*❯/;
/** 選択カーソル。実装差を吸収するため複数の字体を許す(Codex 指摘④)。 */
const SELECT_CURSOR = /^\s*[❯>›→▶]\s*\d+\.\s+\S/;
/** 番号付き選択肢の行(カーソルの有無を問わない)。 */
const OPTION_ROW = /^\s*(?:[❯>›→▶]\s*)?\d+\.\s+\S/;
/**
 * 承認・課金・信頼などの強い文言。**単独では CHOICE にしない**(下の menuAt 参照)。
 * 応答本文にこの語が出ることは普通に起きるため。
 */
const CHOICE_PHRASE =
  /(Enter to confirm|What do you want to do\?|Do you want to (proceed|continue)|weekly limit|Do you trust)/i;
/**
 * 進行中スピナー。**表示専用**。M3 の通り 31% しか見えないので、これが無いことは
 * 待機中の証拠にならない。送信可否には一切使わない。
 * 進行中 `✳ Fluttering… (3s · thinking)` / 完了 `✻ Cogitated for 10s`(`…` が無い)。
 */
const IN_FLIGHT = /[✻✽✢✶✳][^\n]*…/;
/**
 * 「この機械は今、答えられない」の告知。**送信可否には使わない**(下の理由)。
 *
 * ★2026-08-02、edith 実機で踏んで足した。`tools/live-inject-check.mjs` を回したら
 * 4/4 `delivered=verified` / exit 0 の緑が出た。ところが画面の写しを開くと4件とも
 *   `⎿  You've hit your weekly limit · resets 12am (Asia/Tokyo)`
 * で、**一度も答えが返っていなかった**。配達の検査としては嘘ではない(本文は入力欄に
 * 載り、消費された)。しかし「edith で 4/4 緑」を読んだ人は「注入の鎖が通った」と読む。
 * 狭い観測を、それが支えていない結論に貼る型 — この案件で最も繰り返している誤りなので、
 * **緑がその読み方をされ得ない形**にする方を選んだ。
 *
 * 送信可否に使わない理由: この告知が出ている画面は composer が実在し空で、
 * 打ち込み自体は正常に成立する(実測)。上限は「送れない」ではなく「答えが返らない」。
 * ここを遮断条件にすると、上限が解けた瞬間に送れる物まで送れなくなる。
 * 電話側にとって必要なのは遮断ではなく**理由が見える事**(「返事が来ない」と
 * 「上限に当たっている」は、外出先で取る行動が全く違う)。
 *
 * ★この検出が壊れる条件: 文言は Claude Code 側の英文なので、ビルド更新で変わりうる。
 * 変わった時この関数は黙って false を返す = **当たらないプローブは「無い」と報告する**。
 * 現物は `test/fixtures/screens/limit-reached-edith.txt`(edith 実機、メールのみ伏せ字)。
 *
 * ★**承知の上で残している誤検知が1つある**(2026-08-02 に検討して残す方を選んだ)。
 * この関数は画面のどこに在っても当てるので、**電話から送った本文そのもの**に
 * `You've hit your weekly limit` と書くと、その履歴表示で true になる。
 * 締める(告知の描画位置 `⎿` に限る等)事はできるが、その方向の外し方は
 * **本物の上限を見落とす**側 = 外出先の Tom が永久に返らない答えを待つ。
 * 誤検知の側の被害は「上限でないのに上限と出る」= Tom が確かめれば分かる。
 * **非対称なので緩い側に倒す**。
 * ★被害はこの日さらに小さくなった: 生成中の画面では見出しが「動いている」に戻り、
 *   上限は但し書きに落ちる(`view.mjs` の `routeLabel`)ので、誤検知が
 *   「答えは返りません」と断言する事は無くなった。
 * ★実物の陰性対照: `fixtures/screens/promo-banner-boot.txt`(Fable 5 の告知帯に
 *   `weekly usage limit` の語がそのまま載っている実機の画面)で false を返す事を検査済み。
 *
 * ★2026-08-02 に修飾語の固定列挙(`weekly|usage`)をやめた。理由と、やめてよい根拠:
 *   - やめた理由: 上の「壊れる条件」に自分で書いておきながら、**列挙は既知の2語しか拾えない**。
 *     `5-hour` や モデル名つき の形が出た瞬間、この関数は黙って false = 上限に当たっている事が
 *     電話に出なくなる。外出先の Tom は永久に返らない答えを待つ。
 *   - やめてよい根拠(実測、`scratchpad/usage-limit-regex-diff.mjs`): 現物 fixture 20 枚
 *     全部で新旧の判定が一致(割れゼロ)。手書きの 15 例のうち**新旧で変わったのは5行で、
 *     全部が「私が推測した未観測の文言」**。観測済みの文言と陰性対照は1つも動いていない。
 *     = 退行を作らずに未知の文言へ余裕だけ足した形。
 *   - 骨格 `hit your ... limit` は残す。これが陰性対照(告知帯 "your weekly usage limit" =
 *     `hit your` を持たない)を落とさない為の防壁そのものなので、ここは緩めない。
 *   - `{0,24}` の上限は、`hit your` と `limit` が同じ行で近くに在る事の担保。長い無関係な文を
 *     跨いで当たるのを防ぐ。実測で「24字超」と「行またぎ」が false に落ちる事を確認済み。
 *   - `’`(活字アポストロフィ)は**推測**。実機の現物は ASCII の `'`(0x27、fixture で確認)。
 *     見た事は無いが、入れても陰性対照を1つも動かさないので余裕として持たせる。
 */
const USAGE_LIMIT = /You['’]?ve hit your [^\n]{0,24}limit|usage limit reached/i;

/**
 * 上限の告知が画面に出ているか。
 * @returns {boolean}
 */
export function limitNoticeIn(text) {
  return USAGE_LIMIT.test(String(text || ""));
}

/** 末尾の空行を落とす(capture-pane は下に空行を付けてくることがある)。 */
function trimTail(lines) {
  let end = lines.length;
  while (end > 0 && lines[end - 1].trim() === "") end--;
  return lines.slice(0, end);
}

/** 閉じ罫線がここより下にある事を要求する(下にあってよいのはモデル名・権限モードの数行だけ)。 */
const COMPOSER_CLOSE_FLOOR = 8;

/**
 * composer を**箱として**取る。`{head, close}` = `❯` の行と閉じ罫線の行。
 *
 * 「`❯` がある = 入力できる」ではない。応答本文が Claude Code の画面を引用していれば
 * 同じ字は出る(この案件の設計文書がまさにそれ)。罫線で囲まれている・画面の下部にある、
 * という**構造**まで見て初めて実在の入力欄と言える。
 *
 * ★2026-08-01 改訂(実機で欠陥を踏んで): 旧実装は `❯` 行の**すぐ下**も罫線であることを
 * 要求していた。本文が折り返す、あるいは改行を含むと、下の行は続き行なので罫線ではない。
 * 実測(端末幅120)では **日本語60字で既に破綻**し、`UNKNOWN` = 送信拒否になっていた。
 * 長い指示ほど送れないという、電話から使う道具として最悪の壊れ方。
 * → 下端付近の**閉じ罫線**から上に向かって走査し、続き行は読み飛ばし、最初に見つけた `❯` が
 *   **開き罫線に接している**ことを要求する。途中に罫線があればそこで打ち切る(別の箱)。
 *
 * @returns {{head:number, close:number}|null}
 */
export function composerBox(text) {
  const lines = trimTail(String(text || "").split("\n"));
  const floor = Math.max(0, lines.length - COMPOSER_CLOSE_FLOOR); // 下部限定 = 引用された画面を拾わない
  for (let close = lines.length - 1; close >= floor; close--) {
    if (!BOX_RULE.test(lines[close])) continue;
    for (let head = close - 1; head > 0; head--) {
      if (BOX_RULE.test(lines[head])) return null; // `❯` より先に罫線 = 入力欄ではない箱
      if (!COMPOSER_HEAD.test(lines[head])) continue; // 折り返し・改行の続き行
      return BOX_RULE.test(lines[head - 1] ?? "") ? { head, close } : null;
    }
    return null; // 一番下の罫線だけを閉じ罫線とみなす(上の箱を漁らない)
  }
  return null;
}

/**
 * composer の行番号(箱の先頭行)。無ければ -1。
 * @returns {number}
 */
export function findComposer(text) {
  const box = composerBox(text);
  return box ? box.head : -1;
}

/**
 * 選択メニューが出ているか。**2つ以上の番号行が近接**し、そのいずれかに選択カーソルが
 * 載っていること(または強い文言 + 番号行)を要求する。
 *
 * なぜ「番号行1つ」で CHOICE にしないか: 電話から `1. まずテストを直して` と送ると、
 * その本文が `❯ 1. まずテストを直して` として画面に出る。1つで CHOICE にすると
 * **自分が送った本文でそのペインが送信不能になる**。実在するメニューは必ず2択以上なので、
 * 2つ以上を要求しても実物は取り逃さない。逆に応答本文の箇条書きは番号行が複数でも
 * **カーソルが載らない**ので当たらない。両方の誤検知がこの1条件で消える。
 *
 * 強い文言の側に番号行を要求するのは、文言だけで遮断すると「応答本文にその語が出た画面」で
 * 送信不能になるため。文言は、カーソルの字体が想定と違った時の保険として残す。
 *
 * ★2026-08-01 追加(実機で現物を撮って確定): **composer の箱の中身は選択肢として数えない**。
 * `SELECT_CURSOR` は `❯` をカーソルとして認めるが、composer の頭文字も `❯` なので、
 * 電話から番号付きの複数行
 *     ❯ 1. まずテストを直して
 *       2. 次にドキュメントを更新して
 *       3. 最後にコミットして
 * を送ると、**入力欄の中身がそのまま「カーソルの載ったメニュー」に見える**。
 * 現物 `fixtures/screens/composer-numbered-multiline.txt` を旧コードに通すと
 * `{"state":"CHOICE"}` が出る = 実在した欠陥。
 * 実害は「無視できる誤検知」では済まない: 本文を入力欄に入れた**後**に発火するので
 * `modal-appeared` で中断し、本文が入力欄に残る → 次の送信は最初から CHOICE →
 * **そのペインが送信不能のまま固まる**。
 * 実機の選択画面2枚(`/model` と許可確認)はどちらも composer が無い(メニュー中は
 * 入力欄が描かれない)ので、除外しても実物の検出は1件も落ちない。
 *
 * 行1つでなく**箱の範囲**を除くのが要点。折り返し・改行で中身は何行にもなる。
 *
 * ★★2026-08-01 夕、実機で送信経路そのものを回して分かった、より重い形:
 * Claude Code は**送信済みメッセージを `❯` 付きで履歴に残す**。番号付き複数行を送ると
 *     ❯ 1. 返事は「B」の一文字だけでいい
 *       2. 他には何もしないで
 *       3. 以上
 *     ⏺ B
 * が入力欄の**外**(履歴側)に残り続ける。箱の中身を除くだけでは効かない。
 * 実測: A(折り返す長文)B(番号付き複数行)は送信成功したのに、次の C が送信前から
 * CHOICE で拒否された。つまり **一度番号付きの指示を送ると、その履歴が画面から流れるまで
 * そのペインは二度と送れない**。現物 = `fixtures/screens/transcript-echo-numbered.txt`。
 *
 * 履歴表示と本物のメニューは**行の形が完全に同じ**(`❯ 1. Yes` / `  2. No`)。
 * 字面で割ることはできない。割れる材料は1つだけ — **メニュー中は入力欄が描かれない**。
 * 実機のメニュー2枚(`/model`・許可確認)はどちらも composer が無い。よって
 * **入力欄の箱より上にある番号行は履歴とみなし、メニューとして数えない**。
 *
 * ★この規則が壊れる条件(観測したら即座に見直す): 入力欄が描かれたまま選択メニューが出る
 * 画面が1枚でも見つかった時。その1枚で「Enter を押さない」という最重要の守りが破れる。
 */
export function menuAt(text) {
  const lines = trimTail(String(text || "").split("\n"));
  const box = composerBox(text); // null = 入力欄なし
  const opts = [];
  for (let i = 0; i < lines.length; i++) {
    if (box && i <= box.close) continue; // 入力欄より上 = 履歴。自分が送った本文をメニューと読まない
    if (OPTION_ROW.test(lines[i])) opts.push({ i, cursor: SELECT_CURSOR.test(lines[i]) });
  }
  if (opts.length === 0) return false;
  if (CHOICE_PHRASE.test(lines.join("\n"))) return true; // 文言 + 番号行
  for (const o of opts) {
    const cluster = opts.filter((x) => x.i >= o.i && x.i <= o.i + 6);
    if (cluster.length >= 2 && cluster.some((x) => x.cursor)) return true;
  }
  return false;
}

/**
 * 画面から「今このペインに何をしてよいか」を決める。純関数。
 *
 * @returns {{state:"SENDABLE"|"CHOICE"|"UNKNOWN", activity:"observed"|"unknown", composer:number, limited:boolean}}
 *   state    送信可否。**SENDABLE 以外は送らない**(fail-closed)
 *   activity 生成中を**観測できたか**。observed でないことは待機中を意味しない(M3)
 *   composer composer の行番号(-1 = 無い)
 *   limited  上限の告知が見えているか。**state とは独立**(送れるが答えは返らない、が有りうる)
 */
export function classifyScreen(text) {
  const s = typeof text === "string" ? text : "";
  const activity = IN_FLIGHT.test(s) ? "observed" : "unknown";
  const limited = limitNoticeIn(s);
  if (s.trim() === "") return { state: "UNKNOWN", activity, composer: -1, limited };
  // メニューを最優先。ここを取りこぼすと Enter が課金や承認になる。
  if (menuAt(s)) return { state: "CHOICE", activity, composer: -1, limited };
  const composer = findComposer(s);
  if (composer < 0) return { state: "UNKNOWN", activity, composer: -1, limited };
  return { state: "SENDABLE", activity, composer, limited };
}

/**
 * composer に今載っている文字列(`❯` と続き行の字下げを除く)。無ければ null。
 *
 * ★折り返しと改行は画面上で区別できない。返るのは**表示の構造**であって打った文字列そのもの
 * ではない。用途は「本文がまだそこに在るか」の確認に限る(送信後の消費確認)。
 * 続き行の字下げ(2桁)を落とすので、本文自身の行頭空白も一緒に落ちる。
 */
export function composerText(text) {
  const box = composerBox(text);
  if (!box) return null;
  const lines = String(text).split("\n");
  const head = lines[box.head].replace(/^\s*❯\s?/, "");
  const rest = lines.slice(box.head + 1, box.close).map((l) => l.replace(/^ {1,2}/, ""));
  return [head, ...rest].join("\n");
}

/**
 * TUI が本文を取り込んだ後の**空の入力欄**の表示。現物 = `fixtures/queued-during-generation.txt`
 * で、`composerText()` はこれを本文として返す(空文字列ではない)。
 */
const COMPOSER_PLACEHOLDER = "Press up to edit queued messages";

/**
 * 入力欄が空か(= 本文がもう入力欄に無いか)。
 *
 * ★なぜ「空文字列か」だけでは足りないか(2026-08-01 実測): 生成中に送ると TUI は本文をキューへ
 * 取り込み、入力欄には上記の定型文を出す。これを本文と読むと、短い本文の印がこの定型文の
 * 部分文字列になった時(`up` / `edit` / `messages` 等)、本文が消えているのに
 * 「まだ入力欄に在る」と判定して `delivered: "unverified"` を返す。
 * 実害はペイン固着ではなく**届いたのに届いた証明が出ない**こと。だが定型文が出ている状態は
 * むしろ「TUI が受け取った」の直接証拠なので、これを空と読むのは緩めではなく厳密化。
 */
export function composerIsEmpty(text) {
  const body = composerText(text);
  if (body === null) return false;
  const t = body.trim();
  return t === "" || t === COMPOSER_PLACEHOLDER;
}

/**
 * ペイン一覧の区切り。**印字可能な ASCII しか使わない**。
 *
 * ★初版はタブだった。タブは **tmux 側の locale 次第で消える**(2026-08-02 edith 実測、
 *   tmux 3.7b / MBP 3.6a でも同じ)。locale が UTF-8 でないと tmux は `-F` の出力中の
 *   制御文字を潰し、タブが `_` になる:
 *       env -i ... tmux list-panes -a -F '#{pane_id}\t#{pane_current_command}'
 *         -> "%0_2.1.220"      (LANG/LC_ALL/LC_CTYPE のどれか = *.UTF-8 なら "%0\t2.1.220")
 *   launchd は locale を渡さない = **本番の server だけ区切りを失っていた**。開発シェルには
 *   LANG が在るので、手元と ssh の検査は永久に緑。実際に本番だけが壊れていた。
 *   ★`\x1f` 等の他の制御文字に替えても同じ理由で潰れる。だから区切りは印字可能に倒す。
 *   ★locale を被せる対策(makeTmuxRunner)は**残す**が、それ単独を根拠にしない。
 *     locale 名は環境に在るとは限らず、無い名前を渡すと setlocale が C に落ちて再発する。
 *
 * 空白は使えない: cwd に空白が入りうる(実在する: "/Users/tom/My Docs")。
 * 値に紛れ込まない形として、印字可能 ASCII 3文字を使う。万一 path に現れても
 * 「解釈できない行」として拒否側に倒れる(= 送らない)ので、静かに壊れることはない。
 */
export const PANE_SEP = "|&|";

// 対象は #{pane_id}(= "%12" 形式)。session:window.pane と違いウィンドウ番号の振り直しで動かない。
// tty は path より**前**に置く。path は区切り以外の何でも入りうるので末尾で吸わせる必要があり、
// その後ろに項目を足すと path に食われる。
const PANE_FORMAT = ["#{pane_id}", "#{pane_current_command}", "#{pane_tty}", "#{pane_current_path}"].join(
  PANE_SEP,
);

/**
 * tmux を子プロセスとして起こす時に**必ず被せる** env。
 *
 * ここで locale を明示しないと上の PANE_FORMAT のタブが落ちる。呼び側の env を信じない
 * (launchd・cron・systemd 相当の起動には locale が無い)。上書きは意図的:
 * 親が LC_ALL=C を持っていても、我々の制御用 tmux 呼び出しだけは UTF-8 で回す。
 */
export function tmuxChildEnv(base = process.env) {
  return { ...base, LC_ALL: "en_US.UTF-8" };
}

/** tmux が動いていない事を示す tmux 自身の言い分。これだけは「ペインが無い」と読んでよい。 */
const NO_SERVER_RE = /no server running|error connecting to/i;

/**
 * 本番で使う tmux ランナー。**locale を被せるのはここ1箇所**。
 *
 * `run` と `runStrict` は失敗の扱いが違う:
 *   - `run`       失敗を "" にする。**画面を撮る系**専用(撮れなければ画面は UNKNOWN 判定に
 *                 なり、送信は既に止まる = 空文字が状態の主張にならない)。
 *   - `runStrict` 失敗を分類して投げる。**一覧のように「空」が状態の主張になる呼び出し**用。
 *                 ここで飲むと「読めなかった」が「ペインが無い」に化け、tmux で開いている
 *                 会話がワーカー経路(別プロセスの claude)に落ちて lost-update になる。
 *
 * @param {object} o
 * @param {string} o.tmuxBin tmux の絶対パス
 * @param {(bin:string,args:string[],opts:object)=>string} o.exec execFileSync 相当
 * @param {boolean} [o.quiet] `run` の失敗を "" にして飲む
 * @param {(()=>boolean|null)} [o.socketsPresent] tmux のソケットが実在するか。
 *   「接続できない」には2つの意味がある: **本当に tmux が動いていない**(= ペイン0 は真)と、
 *   **動いているのに別のソケットを見ている**(= ペインは在る。ワーカーに落とすと lost-update)。
 *   この2つを分けられるのはソケットの実在だけなので、判定を外から挿す。
 *   省略時 = 分けられない → 接続失敗は投げる(fail-closed)。
 */
export function makeTmuxRunner({ tmuxBin, exec, quiet = true, env = process.env, socketsPresent = null }) {
  const call = (args) => exec(tmuxBin, args, { encoding: "utf8", env: tmuxChildEnv(env) });
  return {
    run(args) {
      try {
        return call(args);
      } catch (e) {
        if (quiet) return "";
        throw e;
      }
    },
    runStrict(args) {
      try {
        return call(args);
      } catch (e) {
        const stderr = String(e?.stderr || e?.message || "");
        if (e?.code === "ENOENT") {
          // PATH や設定の誤りでも同じ形で来る。tmux が実在しないと決めつけない。
          throw new TmuxUnavailableError(`tmux を起動できない(実行ファイルが見つからない: ${tmuxBin})`, stderr);
        }
        if (NO_SERVER_RE.test(stderr)) {
          const present = socketsPresent ? socketsPresent() : null;
          if (present === false) return ""; // tmux は本当に動いていない = ペインは無い(観測)
          if (present === null) {
            throw new TmuxUnavailableError("tmux に接続できず、ソケットの有無も確かめられない", stderr);
          }
          throw new TmuxUnavailableError("tmux のソケットは在るのに接続できない(別のソケットを見ている疑い)", stderr);
        }
        throw new TmuxUnavailableError(`tmux が異常終了した(status=${e?.status ?? "?"} signal=${e?.signal ?? "-"})`, stderr);
      }
    },
  };
}

/** 区切りを失った出力を「ペインが無い」と読み違えない為の投げ物。 */
export class TmuxUnreadableError extends Error {
  constructor(message) {
    super(message);
    this.name = "TmuxUnreadableError";
    this.code = "TMUX_UNREADABLE";
  }
}

/** tmux 自体に届かなかった事を「ペインが無い」と読み違えない為の投げ物。 */
export class TmuxUnavailableError extends Error {
  constructor(message, detail = "") {
    super(detail ? `${message}: ${String(detail).trim().slice(0, 200)}` : message);
    this.name = "TmuxUnavailableError";
    this.code = "TMUX_UNAVAILABLE";
  }
}

/**
 * list-panes の出力を構造化し、**読めなかった行数も返す**。純関数。
 *
 * `panes` だけを返すと「ペインが1つも無い」と「1行も解釈できなかった」が同じ `[]` になる。
 * この2つは取るべき行動が正反対(前者=ワーカー経路で安全 / 後者=宛先不明なので送らない)
 * なので、値の側で分ける。
 */
export function parsePaneListStrict(out) {
  const panes = [];
  let lines = 0;
  let refused = 0;
  for (const line of String(out || "").split("\n")) {
    if (!line.trim()) continue;
    lines += 1;
    const [pane, command, tty, ...rest] = line.split(PANE_SEP);
    // 先頭は tmux の pane_id 文法(`%12`)。区切りに頼らず**形**でも縛る:
    // 区切りが壊れた行は1列に潰れて `%0_2.1.220` のようになり、ここで落ちる。
    if (!/^%\d+$/.test(String(pane || "")) || rest.length === 0) {
      refused += 1;
      continue;
    }
    panes.push({ pane, command: command || "", tty: tty || "", path: rest.join(PANE_SEP) });
  }
  return { panes, lines, refused };
}

/** list-panes の出力を行ごとに構造化する。純関数(寛容側。判定は Strict を使う)。 */
export function parsePaneList(out) {
  return parsePaneListStrict(out).panes;
}

/**
 * そのペインで動いているのが Claude Code か。
 *
 * 2026-07-31 edith 実測: 対話 claude のペインは `pane_current_command` が `2.1.220`。
 * Claude Code が自身のバージョンをプロセス名にしているため、名前での照合はできない。
 * よって「semver 形か、claude/node と名乗るもの」だけを通す**許可制**にする。
 * 未知の名前は通さない(拒否側に倒す)= zsh/bash/vim 等への誤注入がここで止まる。
 */
export function looksLikeClaudePane(command) {
  const c = String(command || "").trim();
  if (!c) return false;
  if (/^\d+\.\d+\.\d+/.test(c)) return true; // 実測の形
  return /^(claude|node)$/i.test(c);
}

/**
 * 照合用に空白・改行を落とした形。画面は折り返しと字下げを勝手に入れるので、
 * 打った本文と画面の文字列は**そのままでは一致しない**(下の2つの実測がどちらもこれ)。
 */
function norm(s) {
  return String(s ?? "").replace(/\s+/g, "");
}

/**
 * 本文の「これが載ったか」を確かめるための短い印。**末尾** 12 文字(空白を除く)。
 *
 * ★2026-08-01、実機で2つ踏んで今の形になった。どちらも「本文は入力欄に入っているのに
 * 確認できず、Enter を押さないまま本文が残る」= 次の送信に混ざる、という壊れ方をする。
 *
 * 1. **改行を跨ぐ印**: 本文の先頭12字を印にすると、改行入りの本文で印が改行を跨ぐ。
 *    画面側は続き行が2桁字下げされる(`やあ⏎  返事は…`)ので永久に一致しない。
 *    実測: 本文「やあ⏎返事は「C」の一文字だけでいい。」で `composer-mismatch`。
 * 2. **長文で先頭が消える**: 入力欄は内部で巻き上がる。実測(端末幅120)で中身は最大15行、
 *    **JP 1500字から本文の先頭が画面から消える**。先頭を印にする限り長文は送信不能。
 *
 * → 印は**末尾**から採る。巻き上がっても末尾は常に見えている。さらに「末尾が届いた」は
 *   「途中も届いた」を含意するので、送信の途中欠けにも強い。照合は norm() で行う。
 */
function probeOf(text) {
  return norm(text).slice(-12);
}
function countOf(haystack, needle) {
  if (!needle) return 0;
  return String(haystack).split(needle).length - 1;
}

/**
 * 画面の描き直しを待つ上限。**実測から決めた値**(2026-08-01、本物の tmux + 2.1.220)。
 *
 * `send-keys -l` の直後に撮ると本文はまだ画面に無い。12 回測って
 * min 8ms / median 9ms / max 77ms(idle)。生成中は描画が遅れうるので余裕を厚く取り、
 * 実測最大の約 20 倍を上限にする。**待ち切れなかった時は送らない**(= 安全側)ので、
 * この値は「誤って Enter を押す確率」ではなく「諦めるまでの時間」しか決めない。
 *
 * 初回の点検は待つ前に行うので、偽 tmux(即時反映)では 1ms も待たない。
 */
const ECHO_BUDGET_MS = 1500;
const ECHO_POLL_MS = 25;

export class TmuxInjector {
  /**
   * @param {object} opts
   * @param {{run:(args:string[])=>string, runStrict:(args:string[])=>string}} opts.tmux
   *   tmux 実行の注入(テスト容易性)。**両方**要る:
   *   - `run` = 失敗を飲んでよい呼び出し(送る・撮る)
   *   - `runStrict` = 失敗を投げる呼び出し(一覧のように「空」が状態の主張になる所)
   *   `runStrict` の無い注入は**構築時に落とす**。飲む `run` から投げる版は作れないので、
   *   ここで代用を合成すると「一覧が空 = ペインが無い」という嘘が復活する(M84)。
   * @param {number} [opts.echoBudgetMs] 画面反映を待つ上限
   * @param {(ms:number)=>Promise<void>} [opts.sleep] 待ちの注入
   * @param {{run:Function}} [opts.mutex] ペイン鍵の直列化(既定 = この注入器専用に1本作る)。
   *   差し替えられるのは検査の為だけ。**共有しない**: 鍵は「同じ物理キーボード」を守るので、
   *   注入器が2本になったら鍵も2本になり、直列化は成り立たない。
   *   今の構成では `server.mjs` が注入器を1本しか作らないのでこれで足りる(実測: `new TmuxInjector` は
   *   `server.mjs:209` の1箇所。`tools/live-*.mjs` は別プロセスの点検道具)。
   */
  constructor({ tmux, echoBudgetMs = ECHO_BUDGET_MS, sleep, mutex } = {}) {
    if (!tmux || typeof tmux.run !== "function") {
      throw new Error("TmuxInjector: tmux runner injection required");
    }
    // ★runStrict を任意にしない。任意にすると listPanes() が飲む run に落ち、
    //   tmux の失敗が「ペイン0本」に化けて会話がワーカー経路へ流れる(= lost-update)。
    //   makeTmuxRunner() が両方を返すので、正しい注入は必ずこれを満たす。
    if (typeof tmux.runStrict !== "function") {
      throw new Error(
        "TmuxInjector: tmux.runStrict injection required " +
          "(一覧は失敗を投げる必要がある。makeTmuxRunner() を使うか、run と同じ実体を runStrict にも渡す)",
      );
    }
    this.tmux = tmux;
    this.echoBudgetMs = echoBudgetMs;
    this.sleep = sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.mutex = mutex || makeKeyedMutex();
  }

  /**
   * 鍵が取れなかった時の返し。**送っていない / 押していない**を必ず名乗る。
   * `send()` の返り値の形をそのまま保つ(呼ぶ側に新しい分岐を増やさない為)。
   */
  static #refusedByLock(e) {
    if (e?.code === MUTEX_BUSY) {
      return { sent: false, state: "BUSY", delivered: null, reason: "pane-busy" };
    }
    if (e?.code === MUTEX_ABORTED) {
      return { sent: false, state: "BUSY", delivered: null, reason: "pane-wait-timeout" };
    }
    return null; // 鍵と無関係の失敗は握り潰さない
  }

  /**
   * 何かが確定するまで画面を撮り直す。**最初の1枚は待たずに撮る**ので、
   * 即時反映の環境(テストの偽 tmux)では待ち時間ゼロで抜ける。
   *
   * @param {string} pane
   * @param {(text:string)=>(string|null)} decide 確定したら理由の札を返す。未確定は null
   * @returns {Promise<{tag:(string|null), text:string, waited:number}>} tag=null は時間切れ
   */
  async pollScreen(pane, decide) {
    const t0 = Date.now();
    for (;;) {
      const text = this.capture(pane);
      const tag = decide(text);
      if (tag) return { tag, text, waited: Date.now() - t0 };
      if (Date.now() - t0 >= this.echoBudgetMs) return { tag: null, text, waited: Date.now() - t0 };
      await this.sleep(ECHO_POLL_MS);
    }
  }

  /** 今の viewport。**scrollback は読まない**(過去の行を今の状態と読む失敗を構造的に消す)。 */
  capture(pane) {
    return this.tmux.run(["capture-pane", "-t", pane, "-p"]);
  }

  /** 今の画面状態。送信の可否はここだけを根拠にする。 */
  state(pane) {
    return classifyScreen(this.capture(pane));
  }

  /**
   * 本文を送る。**送る前に測り、送った後に確かめる**3相の手続き。
   *
   * Codex 指摘①(分類 → 本文 → Enter の間に modal が割り込むと Enter が承認になる)は実在する。
   * 対策として「本文と Enter を1回にまとめる」は採らない — まとめても何も観測しないので
   * 競合が縮むだけで、しかも規約1(生成中の一括送信は完了後に誤送信される)と衝突する。
   * 代わりに**間に観測を挟む**。これは Codex 指摘③(send-keys の成功はバイトが届いた証明で
   * あって Claude が受け取った証明ではない)への回答も兼ねる。
   *
   * ★2026-08-01 実機で判明: **画面の描き直しは同期しない**。`send-keys -l` の直後に撮ると
   * 本文はまだ映っておらず、初版はここで毎回 `composer-mismatch` を返して Enter を押さずに
   * 終わっていた(偽 tmux は即時反映なので緑のままだった = テストが届いていなかった型)。
   * → 観測を「1枚だけ撮る」から「確定するまで撮り直す」に変える。上限は実測由来(§ECHO_BUDGET_MS)。
   *
   * ★2026-08-02、鍵で囲った(DESIGN §2.18-1/2)。囲う範囲は**この手続きの全体**。
   *   短くして「Enter を押すまで」にすると、最後の確認(下の `gone`)が**他人の入力欄**を読む。
   *   実際に起きる並び:
   *     A が Enter を押して鍵を放す → B が本文を打ち込む → A が「入力欄に自分の本文が無い」
   *     のを見て `delivered:"verified"` を返す。A は自分の本文が消えた所を**一度も見ていない**。
   *   これはこの手続き自身が上で禁じている推論(「本文が見えない」を「送れた」と読まない)に
   *   別の入口から到達する形。だから**確認まで含めて**1人の物にする。
   *   囲い方も「行数を人が数えない」形にしてある = 本体ごと `#sendExclusive` に閉じ込める。
   *
   * @param {object} [opts]
   * @param {AbortSignal} [opts.signal] **順番待ちの間だけ**効く期限。取った後は効かない
   *   (途中で降りると入力欄に本文が残り、次の送信に混ざる = §2.18 の決め事1)。
   * @returns {Promise<{sent:boolean, state:string, delivered:("verified"|"unverified"|null), reason:(string|null), waited?:object}>}
   */
  async send(pane, text, { signal } = {}) {
    try {
      return await this.mutex.run(pane, () => this.#sendExclusive(pane, text), { signal });
    } catch (e) {
      const refused = TmuxInjector.#refusedByLock(e);
      if (refused) return refused;
      throw e;
    }
  }

  /** 鍵の中でだけ走る本体。**直接呼ばない**(呼ぶと直列化を素通りする)。 */
  async #sendExclusive(pane, text) {
    const before = this.capture(pane);
    const s0 = classifyScreen(before);
    if (s0.state !== "SENDABLE") {
      return { sent: false, state: s0.state, delivered: null, reason: s0.state.toLowerCase() };
    }

    const probe = probeOf(text);
    // ★印は**入力欄の中**だけで数える(2026-08-01 夜に実測で作り替え)。
    //   旧実装は画面全体で数えていた。これは「本文が画面のどこかに出た」を
    //   「入力欄に載った」と読む形で、規約の文言(「本文が入力欄に載っていなければ
    //   composer-mismatch」)と**コードが一致していなかった**。
    //   実測: 入力欄の箱だけを描いて stdin を読まない偽物に送ると、打った文字は
    //   tty のエコーで箱の**下**に出る。画面全体では印が増えるので「載った」になり、
    //   Enter を押した後の確認は「入力欄が空 = 消費された」と読んで
    //   **一度も届いていないのに `delivered: "verified"`** を返した。
    //   入力欄の外に出た本文で Enter を押す理由は無いので、ここは箱の中で数える。
    const seenBefore = countOf(norm(composerText(before) ?? ""), probe);

    this.tmux.run(["send-keys", "-t", pane, "-l", "--", text]);

    // ★Enter を送る前に、本文が実際に載ったのを見届ける。載る前に選択画面が
    // 割り込んでいたら、そこで打ち切る(Enter を押せば承認や課金になる)。
    const echo = await this.pollScreen(pane, (t) => {
      if (menuAt(t)) return "modal";
      const inBox = composerText(t);
      if (inBox !== null && countOf(norm(inBox), probe) > seenBefore) return "echoed";
      return null;
    });
    if (echo.tag === "modal") {
      return { sent: false, state: "CHOICE", delivered: null, reason: "modal-appeared" };
    }
    if (echo.tag !== "echoed") {
      // 上限まで待っても本文が増えない = ペインに入っていない。Enter を送る理由が無い。
      const s1 = classifyScreen(echo.text);
      return { sent: false, state: s1.state, delivered: null, reason: "composer-mismatch" };
    }

    this.tmux.run(["send-keys", "-t", pane, "Enter"]);

    // 送信後: composer から本文が消えていれば消費された(即送信 or TUI のキュー入り)。
    // ここも描き直し待ちが要る。composer 自体が消えていた場合は**確かめられなかった**ので、
    // 「本文が見えない」を「送れた」と読まない(この層で二度踏んだ誤り)。
    // 本文それ自体が定型文と同一の時だけは、定型文が見えても**何も判別できない**
    // (取り込まれて定型文が出たのか、本文がそのまま残っているのか区別が付かない)。
    // 曖昧さを verified 側へ倒さない = この層の非対称(分からなければ言わない)そのもの。
    const bodyIsPlaceholder = norm(text) === norm(COMPOSER_PLACEHOLDER);
    const gone = await this.pollScreen(pane, (t) => {
      if (!bodyIsPlaceholder && composerIsEmpty(t)) return "cleared"; // 定型文 = 取り込んだ直接証拠
      const left = composerText(t);
      return left !== null && !norm(left).includes(probe) ? "cleared" : null;
    });
    return {
      sent: true,
      state: s0.state,
      delivered: gone.tag === "cleared" ? "verified" : "unverified",
      reason: null,
      waited: { echo: echo.waited, clear: gone.waited },
    };
  }

  /**
   * 割り込み。規約3: Escape のみ。C-c はここでは送らない。
   *
   * ★**送信と同じ鍵を取る**(2026-08-02、`send()` を読んで判った)。Escape は送信と同じ
   *   キーボードを叩くので、本文を打ってから Enter を押すまでの間に割り込むと入力欄が空になる。
   *   すると送信側の最後の確認は「入力欄から本文が消えた = 取り込まれた」と読み、
   *   **一度も届いていない本文に `delivered:"verified"`** を返す。
   *   `send()` の確認が成り立つ前提は「この入力欄は今の自分の物」で、その前提を壊すのは
   *   別の送信だけではなく**割り込みも**同じ。だから同じ鍵の中に入れる。
   *
   *   待たされる事は受け入れる。上限は `echoBudgetMs` の2倍程度(= 送信1回の最長)で、
   *   その間に起きるのは「本文が送られてから止まる」= 筋の通る結末。
   *   逆に割り込みを先に通すと、上の嘘が出る。
   *
   * @returns {Promise<boolean>} false = **まだ止めていない**(鍵が取れなかった)。
   *   ここで true を返すと「押したのに止まらない」を「止めた」と報告する事になる。
   */
  async interrupt(pane, { signal } = {}) {
    try {
      return await this.mutex.run(
        pane,
        () => {
          this.tmux.run(["send-keys", "-t", pane, "Escape"]);
          return true;
        },
        { signal },
      );
    } catch (e) {
      if (e?.code === MUTEX_BUSY || e?.code === MUTEX_ABORTED) return false;
      throw e;
    }
  }

  /**
   * 今ある全ペイン。1回の tmux 呼び出しで取り、呼び側で使い回す。
   *
   * ★出力は在るのに1行も解釈できない時は **投げる**。空配列を返すと呼び側は
   *   「tmux にペインが無い」と読み、tmux で開いている会話をワーカー経路(別プロセスの
   *   claude)に落とす = 同じ会話を2つが読む lost-update。区切りが消える実在の条件が
   *   locale なので(PANE_FORMAT の注記)、これは理論上の話ではなく本番で起きていた。
   */
  listPanes() {
    const args = ["list-panes", "-a", "-F", PANE_FORMAT];
    // 一覧は「空」が状態の主張になる呼び出しなので、失敗を飲む run は使わない。
    const raw = this.tmux.runStrict(args);
    const { panes, lines, refused } = parsePaneListStrict(raw);
    // ★1行でも解釈できない行が在れば、一覧**全体**を信じない。
    //   「読めた分だけ返す」は最悪の形になる: 読めた1行のせいで例外は起きず、読めなかった
    //   ペインだけが「存在しない」ことになり、その会話が静かにワーカー経路へ落ちる。
    if (refused > 0) {
      throw new TmuxUnreadableError(
        `tmux の一覧を解釈できない(${lines} 行中 ${refused} 行が書式に合わない)。` +
          `期待する形は「%<数字>${PANE_SEP}…」。区切りが潰れていないか、makeTmuxRunner を経由しているかを確認する。`,
      );
    }
    return panes;
  }

  /**
   * 会話(cwd)から注入先ペインを決める。**曖昧なら決めない**。
   *
   * 2026-07-31 実測で分かったこと:
   *   - 対話 claude のペインは `pane_current_command` が **`2.1.220`**(バージョン文字列)。
   *     `claude` でも `node` でもない → 「cwd が一致したペイン」だけで送ると、
   *     同じ cwd に居る**素の zsh ペインに本文と Enter を打ち込む**(= 任意コマンド実行)。
   *   - 同じ cwd で claude を2つ開くのは普通にある → 先頭一致で決めると**別の会話に届く**。
   * どちらも「送ってから気づく」類なので、ここは決められない時に null を返す(fail-closed)。
   *
   * @returns {{pane: string|null, reason: "ok"|"none"|"not-claude"|"ambiguous", candidates: number}}
   */
  resolvePane(cwd, panes = this.listPanes()) {
    if (!cwd) return { pane: null, reason: "none", candidates: 0 };
    const atCwd = panes.filter((p) => p.path === cwd);
    if (atCwd.length === 0) return { pane: null, reason: "none", candidates: 0 };
    const claudePanes = atCwd.filter((p) => looksLikeClaudePane(p.command));
    if (claudePanes.length === 0) {
      // cwd は合うが claude ではない = シェル等。ここに送ると事故る。
      return { pane: null, reason: "not-claude", candidates: atCwd.length };
    }
    if (claudePanes.length > 1) {
      // どの会話か決められない。cwd だけでは原理的に解けない(→ 登録簿が要る)。
      return { pane: null, reason: "ambiguous", candidates: claudePanes.length };
    }
    return { pane: claudePanes[0].pane, reason: "ok", candidates: 1 };
  }

  /** 後方互換の薄い糖衣。決められない時は null(理由は resolvePane で取る)。 */
  findPaneByCwd(cwd) {
    return this.resolvePane(cwd).pane;
  }
}
