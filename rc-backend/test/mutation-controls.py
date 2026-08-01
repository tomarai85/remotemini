#!/usr/bin/env python3
# 変異検査 (mutation controls) — 実行: python3 test/mutation-controls.py
#
# なぜ要るか: 2026-07-31 まで、この層のテストは 74 件すべて緑だったのに、
# 検査していた状態(BUSY)は**画面に一度も現れていなかった**。緑は「守りが働いている」の
# 証明ではなく「その検査が何も掴んでいなくても出る色」だった。
#
# だから守りを1つずつ壊して、テストが落ちることを確かめる。落ちない変異があれば、
# そこは誰も見ていないという報告になる。exit 1 = 素通りした変異あり。
#
# 変異検査 — 守りを1つずつ壊して、テストが**落ちること**を確かめる。
# 通る検査が並んでいることは、その検査が守りを掴んでいる証明にならない。
# 落ちない変異 = そこは誰も見ていない、という報告。
#
# 注記つきの生き残り(= 5要素目に理由を書いた変異)について:
#   守りの中には「今の実機の画面では到達しない」物がある。到達しない = 検査で赤にできない。
#   そこを黙って素通りさせると exit 1 が常態化して**この道具ごと無視される**ので、
#   「測った上で到達しないと分かっている物」だけ理由つきで分離し、exit の判定から外す。
#   理由には必ず (a) それを覆っているより強い守り (b) 到達しないと分かった実測 を書く。
#   逆に注記つきが**検出された**場合も報告する(= 到達する様になった。注記を外す合図)。
import shutil, subprocess, sys, os, tempfile, re, atexit

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INJ = "src/inject.mjs"
REG = "src/registry.mjs"
PRC = "src/procs.mjs"
TAI = "src/tail.mjs"
LIS = "src/listing.mjs"
SES = "src/sessions.mjs"
FRM = "src/frames.mjs"
VIE = "src/view.mjs"
SRV = "src/server.mjs"
APP = "src/app.html"

MUT = [
 ("M1 メニュー判定を外す(CHOICE を返さない)", INJ,
  'if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };',
  '// mutated: menuAt 無効'),
 ("M2 入力欄の開き罫線の条件を外す(裸の ❯ を入力欄と認める)", INJ,
  'return BOX_RULE.test(lines[head - 1] ?? "") ? { head, close } : null;',
  'return { head, close };',
  "覆う守り = M3(下部8行限定)+ 実測: 入力欄の無い画面で下部8行に閉じ罫線が現れない。"
  "`/model` 2枚は `─` 罫線が1本も無く(枠は `▔` = U+2594)、許可確認画面の1本は下から14行目。"
  "実機18枚で判定の差は0枚(18枚目を足した 8/01 に測り直し)"),
 ("M3 入力欄の下部限定を外す(画面のどこの ❯ でも拾う)", INJ,
  'const floor = Math.max(0, lines.length - COMPOSER_CLOSE_FLOOR);',
  'const floor = 0;'),
 ("M4 本文送信後の再観測を外す(modal の割り込みを見ない)", INJ,
  'if (menuAt(t)) return "modal";',
  '// mutated: 待っている間の menu 見張りを外す'),
 ("M5 本文が載ったかの確認を外す(送れた事にして Enter を押す)", INJ,
  'if (echo.tag !== "echoed") {',
  'if (false) {'),
 ("M6 メニューを番号行1つで成立させる(自己ロックが復活する)", INJ,
  'if (cluster.length >= 2 && cluster.some((x) => x.cursor)) return true;',
  'if (cluster.length >= 1) return true;',
  "覆う守り = M24/M27(入力欄の箱より上は数えない)。この除外が入った時点で、自分の本文が"
  "選択肢に化ける経路は構造的に消えた。箱より下に残るのはモデル名と権限モードの2行だけで"
  "番号行を含まない。緩めても CHOICE が増える側(fail-closed)にしか倒れない。実機18枚で差0枚(18枚目を足した 8/01 に測り直し)"),
 ("M7 生成中を送信の遮断条件に戻す(旧設計への退行)", INJ,
  'if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };',
  'if (activity === "observed") return { state: "UNKNOWN", activity, composer: -1 };\n  if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };'),
 ("M8 scrollback を読む(-S を付ける)", INJ,
  'return this.tmux.run(["capture-pane", "-t", pane, "-p"]);',
  'return this.tmux.run(["capture-pane", "-t", pane, "-p", "-S", "-200"]);'),
 ("M9 Enter 後に入力欄が消えていたら verified と言う", INJ,
  'return left !== null && !norm(left).includes(probe) ? "cleared" : null;',
  'return left === null || !norm(left).includes(probe) ? "cleared" : null;'),
 ("M10 claude 判定の許可制を外す(どのコマンドにも送る)", INJ,
  'if (/^\\d+\\.\\d+\\.\\d+/.test(c)) return true; // 実測の形',
  'return true;'),
 # M11 = 2026-08-01 に実機で実際に踏んだ欠陥そのもの。画面の描き直しを待たず1枚だけ撮る実装に戻す。
 # 偽 tmux は即時反映なのでこれを検出できる検査は「遅れて載る画面」を持つ物だけ。
 ("M11 画面の反映を待たない(1枚撮って諦める = 実機で毎回不達)", INJ,
  'if (Date.now() - t0 >= this.echoBudgetMs) return { tag: null, text, waited: Date.now() - t0 };',
  'return { tag: null, text, waited: Date.now() - t0 };'),
 # M12-M16 = 2026-08-01 に実測から見つけた「登録が古い」経路の守り。
 # 観測: ~/.rc-backend/panes/ の 10 件が全部 %0 を名乗っていた(tmux サーバは未起動)。
 # ペイン id はサーバ世代ごとに振り直されるので、生死を見ない限り古い登録が
 # 今そこに居る**別の会話**を指す。
 ("M12 登録の生死を見ない(死んだ登録もそのまま信じる)", REG,
  'const live = entries.filter((e) => entryAlive(e, ctx));',
  'const live = entries;'),
 ("M13 心拍の TTL を実質無限にする(長い方が危険側)", REG,
  'export const HEARTBEAT_TTL_MS = 15_000;',
  'export const HEARTBEAT_TTL_MS = 86_400_000;'),
 ("M14 tmux サーバ世代の突き合わせを外す(%0 が全部同じ物になる)", REG,
  'if (!ctx.server || e.server !== ctx.server) return null;',
  '// mutated: 世代を見ない'),
 ("M15 前面判定を外す(Ctrl-Z で止めた claude を生きていると見なす)", REG,
  'if (!proc || !proc.foreground) return null;',
  'if (!proc) return null;'),
 ("M16 同着の登録を通す(両方が同じペインへ注入できる)", REG,
  '(e) => e.pane === entry.pane && e.sessionId !== sessionId && e.mtimeMs >= entry.mtimeMs,',
  '(e) => e.pane === entry.pane && e.sessionId !== sessionId && e.mtimeMs > entry.mtimeMs,'),
 ("M17 tty をペイン一覧から落とす(同一性の検証材料を失う)", INJ,
  'const PANE_FORMAT = "#{pane_id}\\t#{pane_current_command}\\t#{pane_tty}\\t#{pane_current_path}";',
  'const PANE_FORMAT = "#{pane_id}\\t#{pane_current_command}\\t#{pane_current_path}";'),
 # M18-M23 = 2026-08-01 の2つ目の実測から。名前(#{pane_current_command})は機械ごとに
 # 違う値になる(edith="2.1.220" / MBP="bash")ので、判定を名前から ps の実測へ移した。
 # その移し替えで新しく守りになった点を1つずつ壊す。
 ("M18 pid の誕生時刻を見ない(pid 使い回しで別プロセスを本人と認める)", REG,
  'if (!(proc.startMs > 0 && proc.startMs <= e.mtimeMs)) return null;',
  '// mutated: 誕生時刻を見ない'),
 ("M19 ps を読めない時に同一性を「検証失敗=死」と倒す(全登録が死にワーカーが起きる)", REG,
  'if (e.server && e.pid && ctx.procAvailable) {',
  'if (e.server && e.pid) {'),
 ("M20 同一性を検証済みの登録にも名前の関門を掛ける(ラッパ経由の機械で機能が死ぬ)", REG,
  'if (aliveKind(entry, ctx) !== "identity" && !isClaude(info.command)) {',
  'if (!isClaude(info.command)) {'),
 ("M21 近くの claude を名前だけで探す(ラッパ経由の TUI を見落としてワーカーが起きる)", REG,
  '(claudeTtys ? claudeTtys.has(normTty(p.tty)) : false) || isClaude(p.command);',
  'isClaude(p.command);'),
 ("M22 ps の出力が空でも「読めた」と言う(解釈できない = 全プロセス死亡になる)", PRC,
  'if (byPid.size === 0) return { available: false, procOf: () => null, claudeTtys: null };',
  '// mutated: 空でも読めたことにする'),
 ("M23 ps 側の前面判定を外す(停止中の claude が居る tty を「claude が前面」と数える)", PRC,
  'foreground: pgid === tpgid,',
  'foreground: true,'),

 # M24 = 2026-08-01 の3つ目。composer の頭文字 `❯` は SELECT_CURSOR が認める字体なので、
 # 電話から `1. …` と送ると入力欄が「カーソルの載った選択肢」に見える。上に箇条書きが
 # 残っていれば番号行が2つ以上になり CHOICE = 本文を入れた後に中断 → 本文が残る →
 # 次も CHOICE で**ペインが固まる**。M6 は「番号行1つで成立」だけを見ていて、
 # 「2つ目を応答本文が供給する」この経路を掴んでいなかった。
 ("M24 入力欄より上の番号行を選択肢として数える(Tom 自身の本文でペインが固まる)", INJ,
  'if (box && i <= box.close) continue; // 入力欄より上 = 履歴。自分が送った本文をメニューと読まない',
  '// mutated: 履歴の除外を外す'),
 # M27 = 2026-08-01 に私が最初に書いた**不十分な直し**そのもの。入力欄の「中身」だけを除いても、
 # 送信済みメッセージの履歴表示は箱の外に残るので、一度送ったペインが二度と使えなくなる。
 ("M27 除外を入力欄の中身だけに狭める(履歴表示で一度送ると二度と送れない)", INJ,
  'if (box && i <= box.close) continue; // 入力欄より上 = 履歴。自分が送った本文をメニューと読まない',
  'if (box && i >= box.head && i < box.close) continue;'),
 # M25/M26 = 2026-08-01 夕、実機で踏んだ「入力欄の中身は何行にもなる」欠陥の守り。
 # 折り返し / 改行を認めないと、長い指示ほど送れないという最悪の壊れ方をする。
 ("M25 入力欄の続き行を認めない(折り返した本文で送信不能になる旧実装への退行)", INJ,
  'if (!COMPOSER_HEAD.test(lines[head])) continue; // 折り返し・改行の続き行',
  'if (!COMPOSER_HEAD.test(lines[head])) return null;'),
 ("M26 途中の罫線で打ち切らない(引用された画面の ❯ を入力欄として拾う)", INJ,
  'if (BOX_RULE.test(lines[head])) return null; // `❯` より先に罫線 = 入力欄ではない箱',
  '// mutated: 途中の罫線を無視して上へ探し続ける',
  "到達には「閉じ罫線と最初の `❯` の間にもう1本罫線がある画面」が要る = 空の箱が二重に描かれた形。"
  "実機18枚に存在せず(差0枚。18枚目を足した 8/01 に測り直し)、作る手も見つかっていない。M30(罫線は桁0)で本文由来の罫線は除外済み"),

 # M28/M29 = 2026-08-01 夜、実機で踏んだ「本文は入力欄に入っているのに確認できない」欠陥の守り。
 # どちらも Enter を押さないまま本文が入力欄に残るので、次の送信に前回の本文が混ざる。
 ("M28 印を本文の先頭から採る(長文で先頭が画面から消え、永久に送信不能)", INJ,
  'return norm(text).slice(-12);',
  'return norm(text).slice(0, 12);'),
 ("M29 照合の正規化を外す(折り返し・字下げ・改行で本文と画面が一致しなくなる)", INJ,
  "return String(s ?? \"\").replace(/\\s+/g, \"\");",
  'return String(s ?? "");'),
 # M30 = 2026-08-01 夜、5つ目。本文が罫線文字を含むと(表・区切り線を貼った時)
 # 字下げされた罫線を箱の一部と読んでしまい、入力欄を見失って本文が残る = ペイン固着。
 ("M30 罫線の字下げを許す(本文の中の罫線を箱と読み、ペインが固着する)", INJ,
  'const BOX_RULE = /^─{8,}\\s*$/;',
  'const BOX_RULE = /^\\s*─{8,}\\s*$/;'),
 # M31/M32 = 2026-08-01 夜、6つ目。他の5件と壊れ方が違う: ペインは固着せず本文は届く。
 # 届いたのに `delivered: "unverified"` が返る = 電話側に「送れたか分からない」と出る。
 ("M31 キュー中の定型文を本文として読む(短い本文で、届いたのに未確認になる)", INJ,
  'return t === "" || t === COMPOSER_PLACEHOLDER;',
  'return t === "";'),
 ("M32 送信後の判定で定型文を見ない(守りを書いたが使っていない状態)", INJ,
  'if (!bodyIsPlaceholder && composerIsEmpty(t)) return "cleared"; // 定型文 = 取り込んだ直接証拠',
  '// mutated: 定型文の分岐を通さない'),
 # M33 = 欠陥8の直しを敵対的に読み返して出た曖昧さ。本文それ自体が定型文だと、
 # 画面からは「取り込まれた」と「残っている」が区別できない。verified 側へ倒すと嘘になる。
 ("M33 曖昧な時に verified を名乗る(本文 = 定型文の一致を見ない)", INJ,
  'if (!bodyIsPlaceholder && composerIsEmpty(t)) return "cleared"; // 定型文 = 取り込んだ直接証拠',
  'if (composerIsEmpty(t)) return "cleared";'),
 # M34 = 2026-08-01 夜、実機で踏んだ**唯一の fail-open**。他の変異は全て「送れない/確認できない」
 # 側に壊れる(害はあるが嘘はつかない)。これだけは **届いていない本文を verified と報告する**。
 # 旧実装そのもの: 印を画面全体で数えると、入力欄の箱だけ描いて stdin を読まない相手の
 # tty エコー(箱の下に出る)を「入力欄に載った」と読み、Enter を押し、
 # その後「入力欄が空 = 取り込まれた」と読む。実測: 相手は `sleep 600`、返り値は verified。
 ("M34 印を画面全体で数える(入力欄の外に出た本文で Enter を押し、届いていない物を verified と言う)", INJ,
  'if (inBox !== null && countOf(norm(inBox), probe) > seenBefore) return "echoed";',
  'if (countOf(norm(t), probe) > seenBefore) return "echoed";'),
 # --- ここから tail.mjs(2026-08-02 追加。SSE の tmux 経路配信)-----------------
 # この層が守っているのは1つだけ:「ファイルが追記だと信じない」。信じた瞬間、
 # 世代交代した jsonl の途中を前の続きとして読み、**電話に別の会話を混ぜて出す**。
 ("M35 改行を待たずに読んだ分を全部消費する(書き込み途中の行を JSON.parse に渡す)", TAI,
  'const nl = buf.lastIndexOf(0x0a);',
  'const nl = buf.length - 1;'),
 ("M36 inode の突き合わせを外す(rename での差し替えを前の続きとして読む)", TAI,
  'const swapped = gen !== this.generation;',
  'const swapped = false;'),
 ("M37 印(offset 直前のハッシュ)の照合を外す(同じ長さの書き直しが素通りする)", TAI,
  'const drifted = !shrunk && !swapped && this.#readCheckpoint(fd, this.offset) !== this.checkpoint;',
  'const drifted = false;'),
 ("M38 切り詰めの検出を外す", TAI,
  'const shrunk = st.size < this.offset;',
  'const shrunk = false;'),
 ("M39 初回の位置合わせを先頭にする(購読した瞬間に過去の全会話が流れ出す)", TAI,
  'this.offset = st.size;',
  'this.offset = 0;'),
 ("M40 since=0 を壊れた再開として扱う(初回購読で毎回 gap = 本当の取りこぼしが埋もれる)", TAI,
  'if (s === "" || s === "0") return { kind: "fresh" };',
  'if (s === "") return { kind: "fresh" };'),
 ("M41 配信の世代を見ずに seq だけで繋ぐ(seq が振り直された後に嘘の追いつきが成立する)", TAI,
  'if (ep !== String(epoch) || !/^\\d+$/.test(sq || "")) return { kind: "gap", why: "epoch-mismatch" };',
  'if (!/^\\d+$/.test(sq || "")) return { kind: "gap", why: "epoch-mismatch" };'),
 # M42-M51 = 2026-08-02 の有界読み(一覧メタ + 履歴)。全部読みを末尾からの部分読みに替えた層。
 # この層が引き受けている難しさは「一部しか読まずに、全部読んだのと同じ答えを出す」事なので、
 # 壊すべき守りは**繋ぎ目**(持ち越し・短い read・改行での切り出し)と**嘘をつかない印**
 # (metadataIncomplete / truncated)の2種類。実データ 1,644本との突き合わせは別建て(DESIGN §2.11)。
 ("M42 チャンク間の持ち越しを捨てる(境界を跨いだレコードが消える)", LIS,
  'const buf = carry.length > 0 && raw.length === step ? Buffer.concat([raw, carry]) : raw;',
  'const buf = raw;'),
 ("M43 短く返った read を読み直さない(繋いだ buffer に穴が開く)", LIS,
  'while (got < len) {',
  'if (got < len) {'),
 ("M44 読み切っていなくても「無い」と断言する(metadataIncomplete を常に false)", LIS,
  'metadataIncomplete: !r.reachedStart && (m.entrypoint === null || m.lastPrompt === null),',
  'metadataIncomplete: false,'),
 ("M45 読む上限を外す(280MB の会話で一覧が止まる)", LIS,
  'while (scanned < maxBytes) {',
  'while (true) {'),
 ("M46 改行で切らずに断片を完全な行として扱う(多バイト文字が割れる)", LIS,
  '''  if (!atFileStart) {
    const nl = buf.indexOf(0x0a);
    if (nl < 0) return { lines: [], carry: buf }; // 完全な行が1つも無い = 全部が断片
    start = nl + 1;
  }''',
  '  // mutated: 断片をそのまま行として読む'),
 ("M47 メタを先頭優先で採る(cwd が現在地でなく起動地に戻る)", LIS,
  'for (let i = lines.length - 1; i >= 0; i--) {',
  'for (let i = 0; i < lines.length; i++) {'),
 ("M48 一覧キャッシュの鍵から mtime を落とす(書き足された会話が古いまま出る)", LIS,
  'return `${st.dev}-${st.ino}-${st.size}-${Math.round(st.mtimeMs)}`;',
  'return `${st.dev}-${st.ino}-${st.size}`;'),
 ("M49 履歴を止める条件を行数にする(項目を生まない行が挟まると件数が足りない)", SES,
  'done: (lines) => entriesFromLines(lines).length >= limit,',
  'done: (lines) => lines.length >= limit,'),
 ("M50 履歴を先頭側から切る(直近でなく一番古い会話が返る)", SES,
  'history: all.slice(-limit),',
  'history: all.slice(0, limit),'),
 ("M51 履歴の truncated を常に false(「これより前がある」を隠す)", SES,
  'truncated: !r.reachedStart || all.length > limit,',
  'truncated: false,'),
 # M52-M59 = 2026-08-02 の電話側(frames/view)+ 契約を外へ出す2箇所。
 # この層が引き受けている難しさは (a) 回線が**どこで切れても**同じ答えを出す事、
 # (b) サーバが測った結果を**丸めずに**人の言葉にする事。壊すべき守りはその2種類。
 # ★ view/frames は app.html から切り出した層。判断を HTML の中に書くと、単体でも
 #   変異でも触れなくなる(緑が意味を失う)ので、判断は必ずこちら側に置く。
 ("M52 履歴とライブの重なりを剥がさない(購読を先に開いた分がそのまま二重に出る)", VIE,
  'if (same) return [...h, ...l.slice(k)];',
  'if (same) return [...h, ...l];'),
 ("M53 未確認の送信を「送った」に丸める(取り込まれた確認が無いのに成功と言う)", VIE,
  'if (b.delivered === "unverified") {',
  'if (false) {'),
 # ★M54 は 2026-08-02 に的を差し替えた。旧版は `retry: false -> true` を壊していたが、
 #   `retry` は読み手が0人のまま残っていた死に field なので、その日のうちに削除した。
 #   同じ「断られた送信」の危険を、生きている field(`keepText`)で測り直す。
 ("M54 断られた送信で入力欄を空にする(打った本文が消え、打ち直す先を間違える)", VIE,
  'return { kind: "refused", text: b.error || "送信を断られました。", keepText: true };',
  'return { kind: "refused", text: b.error || "送信を断られました。", keepText: false };'),
 ("M55 末尾の孤立 CR をその場で確定させる(チャンクを跨いだ CRLF が2行に割れる)", FRM,
  'if (m[0] === "\\r" && m.index === buf.length - 1) break; // 次の push を待つ',
  ''),
 ("M56 待ち時間の上限を外す(地下鉄で切れ続けると再接続が発散する)", FRM,
  'return Math.min(15_000, 1000 * 2 ** (attempt - 1));',
  'return 1000 * 2 ** (attempt - 1);'),
 ("M57 data の無いフレームも配信する(空の発言が画面に出る)", FRM,
  'if (!hadData) return null;',
  ''),
 ("M58 blocked の本文から文面を落とす(電話が理由コードを生で出す)", SRV,
  '           message: blockedMessage(r) };',
  '         };'),
 ("M59 一覧から metadataIncomplete を落とす(読み残しを「発言なし」と表示する)", SES,
  'metadataIncomplete: !!e.meta.metadataIncomplete,',
  ''),
 # M60-M68 = 2026-08-02 深夜。(a) 未確認の送信で本文を捨てない、(b) app.html の中に
 # 残っていた5つの判断を view.mjs へ出した分、(c) 常設(launchd)に載せる為の起動/停止。
 # ★(c) の2本は**電話からは見えない**性質(起動できない・降りるのに20秒)なので、
 #   e2e 側にしか的が無い。単体が通ったままなのは想定通り。
 ("M60 未確認の送信で入力欄を空にする(届いたか分からない本文を黙って捨てる)", VIE,
  '        keepText: true,\n      };',
  '        keepText: false,\n      };'),
 ("M61 二重注入の注意を落とす(送り直しが二重に入る事を人に伝えない)", VIE,
  '本文は残してあります。送り直すと二重に入ることがあります。',
  '本文は残してあります。'),
 ("M62 「止める対象が無い」を失敗に丸める(静かな会話への Escape が赤く出る)", VIE,
  ': { kind: "warn", text: "止める対象がありませんでした。" };',
  ': { kind: "error", text: "止める対象がありませんでした。" };'),
 ("M63 一度つながっただけで待ち時間を戻す(受けた直後に切る相手に毎秒つなぎ直す)", VIE,
  'const healthy = Boolean(openedAt) && nowMs - openedAt > HEALTHY_MS;',
  'const healthy = Boolean(openedAt);'),
 ("M64 継ぎ目(tail-attached)にも警告を出す(本当の取りこぼしが同じ文面に埋もれる)", VIE,
  'if (!why || why === "tail-attached") return null;',
  'if (!why) return null;'),
 ("M65 「以前を読む」で件数が増えない(押しても何も起きないボタンになる)", VIE,
  'return Math.min(500, (current || 50) + 100);',
  'return Math.min(500, current || 50);'),
 ("M66 走査の欠けた値を 0 で埋める(「読めなかった」を「0本だった」と表示する)", VIE,
  '${scan.files ?? "?"}本のうち ${scan.read ?? "?"}本',
  '${scan.files ?? 0}本のうち ${scan.read ?? 0}本'),
 ("M67 起動失敗の理由を出さない(移動中に読むログが EADDRINUSE の一行になる)", SRV,
  'server.on("error", (e) => {',
  'server.on("error", (e) => { process.exit(1); } ); (() => {'),
 ("M68 SIGTERM の自主降機を外す(SSE が1本あるだけで launchd の 20 秒を毎回払う)", SRV,
  '  setTimeout(() => process.exit(0), 3000).unref();',
  ''),
 ("M69 app.html が view.mjs から名前を取り込むのをやめる(電話だけが白紙になる)", APP,
  'relTime, routeLabel, scanLine, sendResult, subtitleOf, whoOf,',
  'relTime, routeLabel, sendResult, subtitleOf, whoOf,'),
]

# ★2026-08-01 に実機で踏んだ欠陥: 落ちたかを `"# fail 0" not in stdout` で見ていた。
# node の test reporter は **22 が `# fail 0` / 25 が `ℹ fail 0`** と書式が違うので、
# Node 25 の機械(edith)ではこの文字列が原理的に現れず、**全変異が「検出」になっていた**。
# 走って、exit 0 を返して、何も測っていない = この台本が防ごうとしている失敗そのもの。
# → 正は**終了コード**にし、要約行は両書式で読んで突き合わせる。読めない時は止める。
UNIT_FAIL = re.compile(r"^[#ℹ]\s*fail\s+(\d+)\s*$", re.M)
E2E_FAIL = re.compile(r"fail=(\d+)")

def die(msg):
    sys.exit(f"★台本を止める: {msg}\n(緑を報告しない。測れていない事を隠すのが一番害が大きい)")

def read_suite(p, label, rx):
    """落ちたか。**終了コードが正**。要約行は読めた時だけ突き合わせる。

    要約行が無い時の扱いを非対称にしてある:
      exit != 0 で要約が無い = 検査が途中で死んだ(= 赤)。変異で import が壊れれば普通に起きる。
      exit == 0 で要約が無い = **緑を名乗っているのに中身が読めない**。これが 8/1 に
      edith を盲にした形そのもの(Node 25 の `ℹ fail 0` を Node 22 の書式で見ていた)なので止める。
    """
    m = rx.search(p.stdout)
    rc_failed = p.returncode != 0
    if m is None:
        if rc_failed:
            return True  # 落ちた事は終了コードで確定している
        die(f"{label}: exit=0 なのに要約行が読めない(書式が想定外 = 緑を確認できていない)\n"
            f"--- stdout 末尾 ---\n" + "\n".join(p.stdout.splitlines()[-8:]) +
            f"\n--- stderr 末尾 ---\n" + "\n".join(p.stderr.splitlines()[-8:]))
    n = int(m.group(1))
    if (n > 0) != rc_failed:
        die(f"{label}: 要約 fail={n} と exit={p.returncode} が食い違う")
    return n > 0

# --- `--dry`: 変異の**的**が今のコードに当たるかだけを数秒で見る ---------------
#
# 動機(2026-08-02): M54 が狙っていた `retry: false` は、その日のうちに死に field として
# 削除されていた。台本は 30 分走った末に「対象行が無い」と言う。**当たらない的は、
# 走らせる前に分かる**。コードを直した直後にここだけ回せば、台本の腐りが即座に出る。
# ★これは変異検査そのものではない(守りが効くかは何も測らない)。的の生死だけ。
if "--dry" in sys.argv:
    bad = 0
    for m in MUT:
        name, f, old = m[0], m[1], m[2]
        n = open(os.path.join(SRC, f)).read().count(old)
        if n != 1:
            bad += 1
            print(f"NG({n}件) {name}\n      <- {f}")
    print(f"的の照合: {len(MUT)}件 / 当たらない {bad}件")
    sys.exit(1 if bad else 0)

def suites(dst):
    u = subprocess.run(["npm", "test", "--silent"], cwd=dst, capture_output=True, text=True)
    e = subprocess.run(["node", "test/e2e-local.mjs"], cwd=dst, capture_output=True, text=True)
    return read_suite(u, "単体", UNIT_FAIL), read_suite(e, "e2e", E2E_FAIL)

# 作業コピーは中断路(die / 対象行が無くて continue)でも必ず消す。
# 木まるごとのコピーなので、放置すると /var/folders に何本も残る(実際に残っていた)。
LIVE = []
atexit.register(lambda: [shutil.rmtree(d, ignore_errors=True) for d in LIVE])

def copy_tree():
    d = tempfile.mkdtemp(prefix="mut-")
    LIVE.append(d)
    dst = os.path.join(d, "rc")
    shutil.copytree(SRC, dst, ignore=shutil.ignore_patterns("node_modules", ".git"))
    return d, dst

# --- 対照2枚: 測る前に「この台本は赤を見分けられる」ことを証明する ---
# これが無いと、書式が変わった機械で全部緑(あるいは全部検出)を報告し続ける。
d, dst = copy_tree()
if any(suites(dst)):
    die("対照1(無変異): 手を加えていない木で検査が落ちた。まず作業ツリーを緑にする事")
shutil.rmtree(d, ignore_errors=True)
d, dst = copy_tree()
p = os.path.join(dst, INJ)
orig = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write('throw new Error("canary");\n' + orig)
cu, ce = suites(dst)
if not (cu and ce):
    die(f"対照2(故意に壊した木): 赤にならなかった(単体={cu} e2e={ce})。"
        "落ちるはずの木で落ちない = この台本は何も測れていない")
shutil.rmtree(d, ignore_errors=True)
print("対照 OK: 無変異=緑 / 故意に壊した木=赤。以降の判定は意味を持つ\n")

rows = []
for m in MUT:
    name, f, old, new = m[0], m[1], m[2], m[3]
    why = m[4] if len(m) > 4 else None  # 有れば「測った上で到達しないと分かっている」注記
    d, dst = copy_tree()
    p = os.path.join(dst, f)
    src_text = open(p).read()
    if old not in src_text:
        # 走行中に返す(下の atexit が最後に拾うので**漏れてはいない**が、
        # 木まるごとのコピーなので走っている間の /var/folders を無駄に太らせない)。
        shutil.rmtree(d, ignore_errors=True)
        rows.append((name, "対象行が無い", "?", "?", why)); continue
    open(p, "w").write(src_text.replace(old, new, 1))
    ufail, efail = suites(dst)
    if ufail or efail:
        verdict = "★注記を外せる" if why else "検出"
    else:
        verdict = "未到達(注記)" if why else "★素通り"
    rows.append((name, verdict, "unit落ちる" if ufail else "unit通る",
                 "e2e落ちる" if efail else "e2e通る", why))
    shutil.rmtree(d, ignore_errors=True)

w = max(len(r[0]) for r in rows)
print(f"{'変異'.ljust(w)} | 結果         | unit       | e2e")
for r in rows:
    print(f"{r[0].ljust(w)} | {r[1]:12} | {r[2]:10} | {r[3]}")

noted = [r for r in rows if r[1] == "未到達(注記)"]
if noted:
    print("\n--- 未到達(実測の上で承知。理由つき)---")
    for r in noted:
        print(f"* {r[0]}\n    {r[4]}")

reachable = [r[0] for r in rows if r[1] == "★注記を外せる"]
if reachable:
    print("\n★注記つきなのに検出された(= 到達する様になった。理由を読み直して注記を外す):")
    for n in reachable:
        print(f"  - {n}")

missed = [r[0] for r in rows if r[1] in ("★素通り", "対象行が無い")]
print("\n素通りした変異:", missed if missed else "なし")
sys.exit(1 if missed else 0)
