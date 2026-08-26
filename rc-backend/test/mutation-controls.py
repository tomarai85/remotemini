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
import shutil, subprocess, sys, os, tempfile, re, atexit, time, signal

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
BLK = "src/blocked.mjs"
MTX = "src/mutex.mjs"
HDS = "src/heads.mjs"
APP = "src/app.html"
WRK = "src/worker.mjs"
RNG = "src/ring.mjs"
HLT = "src/health.mjs"
CHO = "src/choice.mjs"
# 封筒を組む純関数(S8-25/S8-26 で server.mjs から切り出した)。`server.mjs` は import した
# 瞬間 listen するので、封筒の literal は単体からは**呼べない**。切り出した先が此処。
WIR = "src/wire.mjs"

MUT = [
 ("M1 メニュー判定を外す(CHOICE を返さない)", INJ,
  'if (menuAt(s)) return { state: "CHOICE", activity, activityFrom, composer: -1, limited };',
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
  'if (menuAt(s)) return { state: "CHOICE", activity, activityFrom, composer: -1, limited };',
  'if (activity === "observed") return { state: "UNKNOWN", activity, activityFrom, composer: -1 };\n  if (menuAt(s)) return { state: "CHOICE", activity, activityFrom, composer: -1, limited };'),
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
  'if (Date.now() - t0 >= limit) return { tag: null, text, waited: Date.now() - t0 };',
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
  '"#{pane_current_command}", "#{pane_tty}",',
  '"#{pane_current_command}",'),
 # M79-M83 = 2026-08-02、本番だけが壊れていた故障(launchd に locale が無く `-F` のタブが
 # `_` に潰れ、ペイン一覧が 0 件 = 全会話がワーカー経路 = lost-update)の直しを1つずつ壊す。
 # ★最初 M69-M73 で書いて **既存の SRV/SES 側の M70-M73 と番号が衝突していた**。
 #   衝突しても走行自体は正しいが、報告(と `--only`)が「どちらの M70 か」を区別できなくなる。
 #   = 今夜ずっと直していた「区別の付かない計器」そのもの。下の重複検出で機械に見張らせた。
 ("M79 区切りをタブに戻す(locale の無い本番でだけ潰れる文字に戻す)", INJ,
  'export const PANE_SEP = "|&|";',
  'export const PANE_SEP = "\\t";'),
 ("M80 一部だけ壊れた一覧を「読めた分だけ」返す(その会話だけ静かにワーカーへ落ちる)", INJ,
  '    if (refused > 0) {',
  '    if (panes.length === 0 && refused > 0) {'),
 ("M81 pane_id の形の縛りを外す(区切りが潰れた行を1列の値として通す)", INJ,
  'if (!/^%\\d+$/.test(String(pane || "")) || rest.length === 0) {',
  'if (!pane || rest.length === 0) {'),
 ("M82 一覧を失敗を飲む run で取る(tmux 不達がまた空一覧に化ける)", INJ,
  'const raw = this.tmux.runStrict(args);',
  'const raw = this.tmux.run(args);'),
 ("M83 ソケットの有無を確かめられない時に「tmux は動いていない」と決める(fail-open)", INJ,
  '          if (present === null) {',
  '          if (false) {'),
 # M84/M85 = 2026-08-02。M82 を入れた時、listPanes は
 #   `this.tmux.runStrict ? this.tmux.runStrict(args) : this.tmux.run(args)`
 # という三項で書いてあった。runStrict を持たない注入(道具3本と偽 tmux)が現に居たので、
 # **その経路だけ黙って旧挙動(飲む run)に戻る**潜在の穴が残っていた。M82 は「runStrict を
 # run に書き換える」変異なので、この分岐そのものは掴めない。塞ぎ方は2枚:
 #   M84 = 構築時に runStrict を必須にする関門(= 無い注入は作れない)
 #   M85 = その関門が在る限り三項の else 側は到達しない事の記録
 ("M84 runStrict 必須の関門を外す(runStrict の無い注入をまた作れる様にする)", INJ,
  '    if (typeof tmux.runStrict !== "function") {',
  '    if (false) {'),
 ("M85 一覧の呼び出しを三項に戻す(runStrict が無ければ飲む run に落ちる形)", INJ,
  'const raw = this.tmux.runStrict(args);',
  'const raw = this.tmux.runStrict ? this.tmux.runStrict(args) : this.tmux.run(args);',
  "覆う守り = M84(構築時の関門)。関門が在る限り else 側は**実行時に到達し得ない**。"
  "到達しない事は主張ではなく単体検査で押さえてある(『runStrict の無い注入は構築の時点で"
  "落ちる』= 構築が投げるので listPanes まで届かない)。関門を外した瞬間に穴が開く事は"
  "M84 が別に測る。逆にこの行が『検出』に変われば、runStrict 無しの注入が復活したという事"),
 # M86/M87 = 2026-08-02 夕。`feedTick` だけが `blockedBody()` に**理由の全域**を渡していて、
 # `blockedMessage()` は `UNDECIDABLE` の6つ前提で書かれていた。落ちた先の既定が
 # 「cwd 不一致」という**具体的な文**だったので、画面が消えただけの会話に
 # 「現在地が一致しません」= 直し方まで間違った案内が出ていた(実行して判明)。
 # 守りは2つに分けてある: (a) 出所を1つにした正規化、(b) 原因を作らない既定。
 # (b) が無いと (a) の抜けが**検査できない**(既定がもっともらしい文だと覆い漏れが緑を通る)。
 ("M86 none の正規化を外す(画面消失が既定の文に化ける)", BLK,
  'const reason = !r.reason || r.reason === "none" ? "pane-gone" : r.reason;',
  'const reason = r.reason || "pane-gone";'),
 ("M87 既定に原因を書く(覆い漏れが「cwd 不一致」に化けて緑を通る)", BLK,
  '  return unknownBlockedMessage(r.reason);',
  '  return `登録されたペインの現在地(${r.panePath || "不明"})が、この会話のフォルダと一致しません。宛先を確定できないため送信しません。`;'),
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
 # ★2026-08-02 修正。旧版は `while (got < len) {` を `if (...) {` に替えるだけで、
 # 中の `break` が孤立して **SyntaxError**(Illegal break statement)になっていた。
 # 単体も e2e も「module が読めない」で落ちていた = 検出に見えて**何も測っていない**。
 # 実際に測りたいのは「1回しか read しない実装を、7バイトずつ返す io が捕まえるか」。
 ("M43 短く返った read を読み直さない(繋いだ buffer に穴が開く)", LIS,
  '''    while (got < len) {
      const n = io.read(fd, b.subarray(got), pos + got);
      if (n <= 0) break; // EOF
      got += n;
    }''',
  '''    const n = io.read(fd, b.subarray(got), pos + got);
    if (n > 0) got += n;'''),
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
  'return { kind: "refused", text: b.error || "The server declined to send.", keepText: true };',
  'return { kind: "refused", text: b.error || "The server declined to send.", keepText: false };'),
 ("M55 末尾の孤立 CR をその場で確定させる(チャンクを跨いだ CRLF が2行に割れる)", FRM,
  'if (m[0] === "\\r" && m.index === buf.length - 1) break; // 次の push を待つ',
  ''),
 ("M56 待ち時間の上限を外す(地下鉄で切れ続けると再接続が発散する)", FRM,
  'return Math.min(15_000, 1000 * 2 ** (attempt - 1));',
  'return 1000 * 2 ** (attempt - 1);'),
 ("M57 data の無いフレームも配信する(空の発言が画面に出る)", FRM,
  'if (!hadData) return null;',
  ''),
 ("M58 blocked の本文から文面を落とす(電話が理由コードを生で出す)", BLK,
  '           message: blockedMessage(body) };',
  '         };'),
 ("M59 一覧から metadataIncomplete を落とす(読み残しを「発言なし」と表示する)", SES,
  'metadataIncomplete: !!e.meta.metadataIncomplete,',
  ''),
 # M60-M68 = 2026-08-02 深夜。(a) 未確認の送信で本文を捨てない、(b) app.html の中に
 # 残っていた5つの判断を view.mjs へ出した分、(c) 常設(launchd)に載せる為の起動/停止。
 # ★(c) の2本は**電話からは見えない**性質(起動できない・降りるのに20秒)なので、
 #   e2e 側にしか的が無い。単体が通ったままなのは想定通り。
 # ★2026-08-02: P1 で「本文が読めない」枝を足した時、この2件の目印が**2箇所に当たる**ように
 #   なった(新しい枝が同じ文面と同じ `keepText: true,` を持つ為)。目印を `${note}` を含む
 #   未確認枝だけの形に絞って一意に戻す。文面をわざと違える方向は採らない — 人に出す助言は
 #   どちらの枝でも同じ(本文は残した / 送り直すと二重に入る)であるべきなので。
 ("M60 未確認の送信で入力欄を空にする(届いたか分からない本文を黙って捨てる)", VIE,
  '        text: `${note} Your text is kept — resending may duplicate it.`,\n        keepText: true,',
  '        text: `${note} Your text is kept — resending may duplicate it.`,\n        keepText: false,'),
 ("M61 二重注入の注意を落とす(送り直しが二重に入る事を人に伝えない)", VIE,
  '`${note} Your text is kept — resending may duplicate it.`',
  '`${note} Your text is kept.`'),
 ("M62 「止める対象が無い」を失敗に丸める(静かな会話への Escape が赤く出る)", VIE,
  ': { kind: "warn", text: "Nothing was running to stop." };',
  ': { kind: "error", text: "Nothing was running to stop." };'),
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
  'Read ${scan.read ?? "?"} of ${scan.files ?? "?"} files',
  'Read ${scan.read ?? 0} of ${scan.files ?? 0} files'),
 ("M67 起動失敗の理由を出さない(移動中に読むログが EADDRINUSE の一行になる)", SRV,
  'server.on("error", (e) => {',
  'server.on("error", (e) => { process.exit(1); } ); (() => {'),
 ("M68 SIGTERM の自主降機を外す(SSE が1本あるだけで launchd の 20 秒を毎回払う)", SRV,
  '  setTimeout(() => process.exit(0), 3000).unref();',
  ''),
 # ★2026-08-04 に的を付け替えた。取り込む名前が2つ増えて**行が折り返した**だけで、
 #   旧的(`relTime, routeLabel, scanLine, sendResult, subtitleOf, whoOf,`)は改行を跨ぐ
 #   文字列になり当たらなくなった —— pre-commit の `--dry` が「当たらない 1件」で捕まえた。
 #   狙いは変えない: **app.html が view.mjs から名前を1つ取り込まなくなる**。
 #   ★整形に強い側へ寄せる。名前2つぶんの並びだけを的にすれば、次に何が増えても折り返しは
 #   この2語の間には入りにくい(完全な不変ではない —— 次に外れたら、また `--dry` が言う)。
 ("M69 app.html が view.mjs から名前を取り込むのをやめる(電話だけが白紙になる)", APP,
  'scanLine, sendResult,',
  'sendResult,'),

 # M70-M73 = 2026-08-02。edith で実際に踏んだ「一覧が空」の欠陥の周り。
 # 机(MBP)では `cli` が 1本目に来るので**4つとも素通りする**。守っているのは
 # e2e 12-b に足した edith 分布の再現(新しい方が全部 `sdk-cli`)の側。
 ("M70 `limit` を「開く file の上限」に戻す(edith で一覧が空に戻る)", SRV,
  'if (limit > 0 && entries.length + unreadable.length >= limit) break;',
  'if (limit > 0 && examined >= limit) break;'),
 ("M71 走査側の絞り込みを外す(出さない会話が枠を食って本命が押し出される)", SRV,
  '    if (!isPhoneVisible(meta)) continue;\n',
  ''),
 ("M72 「電話に出す会話」の定義を広げる(adapter の非対話ログが一覧に混ざる)", SES,
  'export const isPhoneVisible = (meta) => meta?.entrypoint === "cli";',
  'export const isPhoneVisible = (meta) => meta?.entrypoint != null;'),
 ("M73 何本開いたかを外に出さない(「埋まって止めた」と「全部見た」が区別できない)", SRV,
  'cached: scan.cached, examined: scan.examined }',
  'cached: scan.cached }'),

 # M74-M76 = 2026-08-02。「配達できた」を「相手が答えた」と読ませない為の層。
 # 出所は自分の道具に踏まれた事: edith で 4/4 delivered=verified / exit 0 が出たのに、
 # 4件とも `You've hit your weekly limit` で一度も答えが返っていなかった。
 # ★2026-08-02 夕: `USAGE_LIMIT` の修飾語を固定列挙から外した(inject.mjs の理由を参照)ので、
 #   ここの的も同じ行に付け替えた。**式を直したのに的を置き去りにすると `対象行が無い` で
 #   missed に入り exit 1** になる(黙って飛ばさない設計。付け替え漏れは `--dry` で秒で出る)。
 ("M74 上限の検出を殺す(答えられない機械が「静か」に見える)", INJ,
  "const USAGE_LIMIT = /You['’]?ve hit your [^\\n]{0,24}limit|usage limit reached/i;",
  "const USAGE_LIMIT = /この文字列は画面に出ない/;"),
 ("M75 上限を常に真にする(陰性対照が無ければ M74 と区別が付かない)", INJ,
  'export function limitNoticeIn(text) {\n  return USAGE_LIMIT.test(String(text || ""));',
  'export function limitNoticeIn(text) {\n  return true || USAGE_LIMIT.test(String(text || ""));'),
 ("M76 電話の表示から上限を落とす(検出はできているのに人に届かない)", VIE,
  '''    if (v.limited) {
      return work === "Active"
        ? { kind: "tmux", short: "Active · limit", text: "Open on desktop · Active (a usage limit notice remains on screen)", screen: v.screen || "" }
        : { kind: "tmux", short: "Usage limit", text: "Open on desktop · usage limit (no reply will come)", screen: v.screen || "" };
    }
''',
  ''),
 # ★M77 は「上限を出す」方向でなく「**出しすぎる**」方向の退行を撃つ(2026-08-02 追加)。
 # 8/02 朝までの実装がこれそのもので、`limited` が `動いている` を無条件に押し退けていた。
 # 症状は静かで、検査も緑のままだった — `limited:true` と `activity:"observed"` を
 # **同時に**与える検査が1本も無かったから。組み合わせを測らない検査は、
 # 個々の枝を全部緑にしたまま、その交差点を丸ごと見落とす。
 ("M77 上限を動きより優先させる(生成中の画面に「答えは返りません」と出す)", VIE,
  '      return work === "Active"',
  '      return false'),
 # ★M78 は**継ぎ目**を撃つ(2026-08-02 追加)。分類器(M74/M75)と電話の表示(M76/M77)は
 # それぞれ撃っていたのに、その間の `server.mjs` が `limited` を JSON に載せる所は
 # 誰も撃っていなかった。両端が緑でも、間で落ちれば人には届かない。
 # ★この変異が「素通り」で返ってきたら、それは**継ぎ目に検査が無い**という答えで、
 #   その時は e2e に `live.limited` の assert を足す。台本に答えを出させる為に置く。
 # ★2026-08-03: 的を付け替えた。`screenOf` が選択メニューの中身も載せる様になり
 #   (`choice`)、一度で撮った1枚から組む形へ変わった為、探し文が本文に当たらなくなった。
 #   **欠陥は同じ** —— 分類器が見えている `limited` が電話へ渡らない。
 ("M78 サーバの応答から limited を落とす(分類器は見えているのに電話へ渡らない)", SRV,
  '    const base = { screen: s.state, activity: s.activity, limited: s.limited };',
  '    const base = { screen: s.state, activity: s.activity };'),
# ================= H1 の鍵まわり (2026-08-02 追加) =========================
# ここから下は「同じ物理キーボードを2人で叩かない」を守る層。写し(git archive HEAD の
# 複製)の上で先に測ってから入れた。写しでの結果 = 22件すべて検出 / 素通り 0。
#
# ★M88-M103 は当初 `scratchpad/rc/neg.py` という**別の台本**で回していた。別台本のままだと
#   「回した」記録は残っても、次に誰かが `mutation-controls.py` を回した時この層は測られない。
#   台本が2本ある = 片方だけ回して緑を名乗れる、という事なので畳む。
 ("M88 中止しても呼ぶ側に返さない(押した人が待ち続ける)", MTX,
  "          reject(mutexError(MUTEX_ABORTED, `${key}: 順番待ちの間に期限切れ。**送っていない**`));",
  "          void mutexError;"),
 ("M89 待ちの上限を1本ゆるめる", MTX,
  "if (!priority && normalWaiters(q) >= maxWaiters) {",
  "if (!priority && normalWaiters(q) > maxWaiters) {"),
 ("M90 fn が投げた時に鍵を渡さない(finally を外す)", MTX,
  """    try {
      return await fn();
    } finally {
      // fn が投げても必ず渡す。ここを条件付きにすると、1回の失敗で鍵が永久に埋まる。
      releaseAndPump(key);
    }""",
  """    const out = await fn();
    releaseAndPump(key);
    return out;"""),
 ("M91 中止した待ち手を行列から外さない", MTX,
  "          if (i >= 0) q.splice(i, 1);",
  "          void i;"),
 ("M92 呼ばれた時点の中止済みを見ない", MTX,
  """    if (signal?.aborted) {
      throw mutexError(MUTEX_ABORTED, `${key}: 呼ばれた時点で中止済み。**走らせていない**`);
    }""",
  ""),
 ("M93 待たずに全員が鍵を持つ(直列化そのものを外す)", MTX,
  "      await enqueue(key, signal, priority); // ここを抜けた = 自分が持ち主",
  "      queueOf(key); // 直列化しない"),
 ("M94 鍵の値を無視して全部1本にする(並列性を殺す)", MTX,
  "  async function run(key, fn, { signal, maxWaiters = defaultMaxWaiters, priority = false } = {}) {",
  "  async function run(key0, fn, { signal, maxWaiters = defaultMaxWaiters, priority = false } = {}) {\n    const key = typeof key0 === 'string' && key0 ? 'ALL' : key0;"),

 # ★M110-M112 =「積んだ待ちを、後から来た誰かの為に捨てない」(規則3、2026-08-04 決着)の対照。
 #   捨て方は**3通りあって、1つ潰しても他は通る**ので3本要る(Codex `gpt-5.6-sol` xhigh の指摘)。
 #     - 孤児化(M110/M111): 約束が**永久に未解決**。素の配列操作で起きる事故の形。
 #     - 明示的 flush(M112): 断って捨てる。仕様違反だが「ちゃんと」書かれている形。
 #   両者は片方が片方を含まない。だから `watch()` は「決着した」ではなく
 #   **`resolved` である事**を要求している(断って捨てる方は settled では素通りする)。
 ("M110 後から積む時に、先に待っている待ちを黙って捨てる(孤児化)", MTX,
  "      q.push(w);",
  "      q.length = 0;\n      q.push(w);"),
 # ★M111 が**境界だけ**の形。上限ちょうどの時にしか現れないので、2本→3本の検査では
 #   掴めない(だから `test/mutex.test.mjs` に上限ちょうどの検査が別に居る)。
 #   §2.18-11 の優先挿入が入ると「先頭へ入れる」がこれに化ける道が出来る。
 ("M111 上限で断る代わりに、古い待ちを外して席を空ける(優先挿入が化ける形)", MTX,
  "        throw mutexError(MUTEX_BUSY, `${key}: 送信中で、待ちも上限(${maxWaiters})。**積まない**`);",
  "        q.shift();"),
 # ★M113-M117 = ワーカー経路側(§2.18-12)。鍵の層で「捨てない」を決めた後も、
 #   **こちらには捨てる実装が生きたまま残っていた**。検査 538 本が全部緑だったので、
 #   「決めた事」と「決めた事を実現している事」を分けて測る対照が此処に要る。
 ("M113 退役の時に、積んだ送信を黙って消す(2026-08-04 まで本当にこうだった)", WRK,
  "    this._dropQueued(sessionId, entry, reason);\n    // ★`workers` から外す事",
  "    void reason;\n    // ★`workers` から外す事"),
 # ★M114 が Codex の名指しした穴(「失敗イベントを揮発性にする」)。リングには残るので
 #   後から拾えるが、**繋がっている電話にはその場で届かない**。
 #
 #   ★2026-08-04 に**的を差し替えた**。元の的は `_retire` の中の順序(通知を entry を外した
 #   後に出す)だったが、同日に「宛先が entry 持ちだと、外した後の通知は全部届かない」
 #   —— 死亡通知・割り込み・idle 回収の**全部** —— が実測で出たので、宛先を
 #   `this.listeners`(セッション持ち)へ移した。結果、順序の入れ替えは**何も変えない**
 #   = 元の的は永久に素通りする死んだ変異になる。撤去ではなく、同じ穴の**今の形**へ移す:
 #   「生配信を workers の在籍で門番する」。旧実装の意味をそのまま再現する形。
 ("M114 生配信を workers の在籍で門番する(entry を外した後の通知が電話に届かない)", WRK,
  "    (this.listeners.get(sessionId) || noop)(seq, data);",
  "    (this.workers.has(sessionId) ? (this.listeners.get(sessionId) || noop) : noop)(seq, data);"),
 ("M115 予期しない死の道だけ通知を落とす(退役路は5本ある)", WRK,
  '      this._dropQueued(sessionId, entry, "worker_died");\n',
  ""),
 # ★M116 は逆向きの対照。「退役のたびに落ちた事にする」= 嘘の failed を流す形。
 #   上の肯定側の検査5本は**これを全部緑で通す**ので、陰性対照が別に要る。
 ("M116 積んだ物が無くても『落ちました』と出す(嘘の failed)", WRK,
  "    if (!entry.queue.length) return 0;\n    const dropped = entry.queue.splice(0, entry.queue.length);",
  '    const dropped = entry.queue.splice(0, entry.queue.length).concat([{ text: "", seq: 0 }]);'),
 ("M117 どの turn が落ちたか言わない(名指しをやめる)", WRK,
  "        queuedSeq: item.seq,\n",
  ""),
 # ★M118 は「積んだ物を消す」の**隣の形**。消すのは行列ではなく Map の席で、
 #   巻き添えで消えるのは**生きている次の子**。`error` は kill 失敗でも出るので、
 #   割り込みで差し替わった後に届く。名前で消すと H2(1つの転写に書き手が2人)。
 ("M118 遅れて来た error が、名前で Map を消す(差し替わった後の生きた子を外す)", WRK,
  "此処だけ無かった。\n      if (this.workers.get(sessionId) === entry) this.workers.delete(sessionId);",
  "此処だけ無かった。\n      this.workers.delete(sessionId);"),

 # ★2026-08-04 に的が空いていた事が判った。X6 は「猶予後に SIGKILL を撃たない」側で、
 #   「死を確認しても猶予を止めない」側は誰も撃っていなかった。掴む検査 (H2-9b) は
 #   `timers.every(t => t.cleared)` = **空配列でも true** なので、対照としても空回りし得た。
 #   前提 (`timers.length >= 1`) を足した上で、此処に的を置いて実際に赤くなる事を測る。
 ("M119 死を確認しても猶予タイマーを止めない(死体に SIGKILL を撃つ)", WRK,
  """    if (entry.killTimer) {
      this.clearTimer(entry.killTimer);
      entry.killTimer = null;
    }""",
  """    if (false) {
      this.clearTimer(entry.killTimer);
      entry.killTimer = null;
    }"""),

 ("M112 後から積む時に、先の待ちを**断って**捨てる(明示的 flush)", MTX,
  "      const w = { grant, detach: () => {}, priority: !!priority };",
  """      const w = { grant, reject, detach: () => {}, priority: !!priority };
      if (q.length) {
        const v = q.shift();
        v.detach();
        v.reject(mutexError(MUTEX_BUSY, "席を空ける為に断って捨てた"));
      }"""),

 # ★M95 が本丸。頭が読めない時に祖先へ倒すと、机の TUI と同じ転写ファイルを2人で書く。
 ("M95 頭が読めない時に**祖先**を返す(= 共有書き込みへ倒す。H2 が防ぐ破壊そのもの)", HDS,
  '  const e = parseHead(text, name);\n  return e ? e.head : "";',
  '  const e = parseHead(text, name);\n  return e ? e.head : ancestor;'),
 ("M96 ファイル名と中身の祖先の突き合わせを外す(名前を付け替えた登録が通る)", HDS,
  "  if (`${ancestor}.json` !== name) return null;",
  "  void name;"),
 ("M97 書きかけを `.json` で置く(部分的に書かれた中身が頭として読まれる)", HDS,
  "  return join(dir, `${ancestor}.${pid}.${tempSeq}.tmp`);",
  "  return join(dir, `${ancestor}.${pid}.${tempSeq}.json`);"),
 ("M98 rename を経ずに直接書く(原子性を失う)", HDS,
  """  const tmp = tempPathFor(dir, ancestor, pid);
  const dest = join(dir, `${ancestor}.json`);
  fs.writeFileSync(tmp, JSON.stringify({ ancestor, head }) + "\\n");""",
  """  const dest = join(dir, `${ancestor}.json`);
  const tmp = dest;
  fs.writeFileSync(dest, JSON.stringify({ ancestor, head }) + "\\n");"""),
 ("M99 書きかけの名を固定にする(2本が互いの書きかけを rename する)", HDS,
  "  tempSeq += 1;",
  "  tempSeq = 1;"),
 ("M100 ID の形の判定を緩める(何でも祖先・頭として通る)", HDS,
  "const SESSION_ID = /^[0-9a-f-]{8,64}$/i;",
  "const SESSION_ID = /^.*$/;"),
 ("M101 壊れた1件を一覧から捨てない(空の登録が混ざる)", HDS,
  "      if (e) out.push(e);",
  '      out.push(e || { ancestor: "", head: "" });'),
 # ★注記つき = **素通りが正しい**。対になっている事は M103 が測る。
 ("M102 走査の `.json` 絞りを外す(書きかけが一覧に出る)", HDS,
  'const isHeadFile = (name) => name.endsWith(".json");',
  'const isHeadFile = (name) => !name.startsWith(".");',
  "走査の絞りとファイル名照合は**どちらか片方だけで足りる**冗長な守り。片方を外しても"
  "他方が止めるので単独では観測できない(死んだ枝ではなく、実際に走る二重の守り)。"
  "対になっている事は M103 が測る = この注記は M103 が検出である限りにおいて有効"),
 ("M103 ★二重の守りを**両方**外す(冗長だと言い張れなくなる合図)", HDS,
  ['const isHeadFile = (name) => name.endsWith(".json");',
   "  if (`${ancestor}.json` !== name) return null;"],
  ['const isHeadFile = (name) => !name.startsWith(".");',
   "  void name;"]),

 # --- 選択メニューへの打鍵 (C) = 良性と同定できた画面にしか打たない層 -------------
 # 出典: DESIGN D4 + Tom 裁定「自動化に安全確認を押させない」。守りの形は**許可一覧**で、
 # 「危険と書いてあるから断る」ではなく「良性と証明できないから断る」。だから的の中心は
 # C1 = 許可一覧を拒否一覧へ退化させる変異。ここが素通りしたら、設計が裏返っても誰も
 # 気づかないという報告になる。方針(policy)と繋ぎ目(wiring)を W と分けずに C に纏めたのは、
 # 壊れた時に読む場所が `choice.mjs` とその1本の呼び出し元しか無いから。
 # ★C1 は 2026-08-03 に的を付け替えた。判定の順序を hard-stop 先へ変えた時に本文が
 #   動いた為で、**撃つ欠陥は同じ**(許可一覧を素通りさせて「危険と書いていない=良性」にする)。
 ("C1 ★許可一覧を拒否一覧へ退化させる(危険な語が無ければ良性と認める)", CHO,
  '  const matcher = MATCHERS.find((x) => x.test(menu)) || null;',
  '  const matcher = MATCHERS[0]; // mutated: 許可一覧を素通り(何でも良性)'),
 ("C2 hard-stop の網を空にする(断る理由の欄が死ぬ)", CHO,
  r'  /(Do you want to (proceed|continue)|Do you trust|requires confirmation|\/permissions to update rules|[Bb]ypass permissions|weekly limit)/;',
  '  /$^/;'),
 ("C3 入力欄が描かれた画面でも良性と認める(menuAt の唯一の材料が壊れても進む)", CHO,
  '  if (!menu.composerAbsent) return { kind: "unrecognized", matcher: null, menu };',
  '  // mutated: 入力欄の有無を見ない'),
 ("C4 番号行1つでメニューを成立させる(自分の本文1行が選択肢に化ける)", CHO,
  '  if (opts.length < 2) return null; // 単独の番号行はメニューと呼ばない(inject.mjs と同じ判断)',
  '  if (opts.length < 1) return null;'),
 ("C5 履歴側の番号行を除外しない(こだまをメニューとして読む)", CHO,
  '    if (composerClose >= 0 && i <= composerClose) continue;',
  '    // mutated: 履歴を除外しない'),
 ("C6 数字を literal で送らない(tmux が繰り返し回数と読みうる綴りへ戻す)", CHO,
  '  if (/^[1-9]$/.test(key)) return ["send-keys", "-t", pane, "-l", "--", key];',
  '  if (/^[1-9]$/.test(key)) return ["send-keys", "-t", pane, key];'),
 ("C7 ★注入器が分類器を通らない(方針が正しくても打ってしまう繋ぎ目)", INJ,
  ['    if (c.kind !== "benign") {',
   '      return refuse("CHOICE", c.kind === "hard-stop" ? "choice-hard-stop" : "choice-unrecognized", now);',
   '    if (!c.matcher.keys.includes(keyKind(key))) {',
   '      return refuse("CHOICE", "choice-key-not-allowed", now);'],
  ['    if (false) {',
   '      void c;',
   '    if (false) {',
   '      void keyKind(key);']),
 ("C8 指紋の突き合わせを外す(見た画面と押す画面が別でも通る)", INJ,
  '    if (expectDigest !== now) return refuse("CHOICE", "digest-mismatch", now);',
  '    // mutated: 指紋を見ない'),
 # 2026-08-03 に的を付け替え: 同じ if が「二度打ち止めの消し所①」を抱えてブロックになった。
 # 撃っている欠陥(画面状態を見ずに打つ)は変えていない。
 ("C9 選択待ちでない画面への打鍵を止めない", INJ,
  '    if (s0.state !== "CHOICE") {',
  '    if (false) {'),
 ("C10 Escape の後の静穏を外す(次の打鍵が Alt シーケンスに読まれうる)", INJ,
  '    if (key === "escape") await this.sleep(ESC_SETTLE_MS);',
  '    // mutated: Escape の後に間を置かない'),
 # ★C11 も 2026-08-03 に的を付け替えた(`applied` が3値になり探し文が当たらなくなった)。
 #   欠陥は同じ + 一段重い: 決め打つと**許可確認へ着地した回まで**成功として返る。
 ("C11 打鍵を「効いた」と決め打つ(送信を効果と読む)", INJ,
  '      landKind === "hard-stop" ? "moved-to-hard-stop" : after.tag ? "verified" : "unverified";',
  '      "verified";'),
 ("C12 打鍵が鍵を通らない(2人が同じメニューを見て両方押す)", INJ,
  '      return await this.mutex.run(pane, () => this.#chooseExclusive(pane, key, digest), { signal });',
  '      return await this.#chooseExclusive(pane, key, digest);'),
 ("C13 指紋なしの打鍵を 400 で止めない", SRV,
  '      if (!digest) {',
  '      if (false) {'),

 # --- C14-C18 = 2026-08-03 の締め直し(Codex 指摘)を守る的 ---------------------
 # 5件とも「誤りの向きが承認側になる」形へ戻す変異。C1-C13 と違って**新しい欠陥**ではなく、
 # 一度直した欠陥が戻った時に赤が出るかを測る(直した事を検査が知らなければ、また戻る)。
 ("C14 ★hard-stop を許可一覧の後ろへ戻す(両方に当たる画面が良性へ倒れる)", CHO,
  '  if (HARD_STOP.test(hay)) return { kind: "hard-stop", matcher: null, menu };',
  '  { const m0 = MATCHERS.find((x) => x.test(menu)); if (m0) return { kind: "benign", matcher: m0, menu }; }\n'
  '  if (HARD_STOP.test(hay)) return { kind: "hard-stop", matcher: null, menu };'),
 ("C15 ★matcher を字面2つだけの v1 へ戻す(選択肢の形を見ない)", CHO,
  ['      m.options.length >= 3 &&',
   '      m.options.every((o, i) => o.n === i + 1),'],
  ['      true &&',
   '      true,']),
 ("C16 存在しない番号でも打つ(5択へ 7 を流す)", INJ,
  '    if (keyKind(key) === "digit" && !optionFor(c.menu, key)) {',
  '    if (false) {'),
 ("C17 ★同じ指紋へ何度でも打つ(撃ち直しが次の画面へ流れる)", INJ,
  '    if (this.#choiceSent.get(pane) === now) return refuse("CHOICE", "choice-already-sent", now);',
  '    // mutated: 二度打ちを止めない'),
 ("C18 着地した画面をサーバが伏せる(「動いた」しか電話に届かない)", SRV,
  '        ...(out.after ? { after: out.after } : {}),',
  '        // mutated: どこへ動いたかを返さない'),

 # --- 二度打ち止めの**解除条件**(2026-08-03。条件付きの守りは両側に対照が要る) -------
 # 止めは「結果が分からない間だけ」効く。緩める向き(C19)と締め過ぎる向き(C20/C21)は
 # 別の壊れ方なので、片側だけの変異では「常に解除」も「常に保持」も緑のまま通る。
 ("C19 ★動きを見ずに二度打ち止めを解除する(撃ち直しが次の画面へ流れる)", INJ,
  '    if (after.tag) this.#choiceSent.delete(pane);',
  '    this.#choiceSent.delete(pane);'),
 ("C20 二度打ち止めを一度も解除しない(同じ形のメニューへ生涯1回しか打てない)", INJ,
  '    if (after.tag) this.#choiceSent.delete(pane);',
  '    // mutated: 動いても解除しない'),
 ("C21 メニューを離れたのを見ても解除しない(消し所①が死ぬ)", INJ,
  '      this.#choiceSent.delete(pane);',
  '      // mutated: 離れたのを見ても解除しない'),

 # --- 電話の操作面 (2026-08-04) ------------------------------------------------
 # ここまでの C は「打鍵を受けた後に守る」層。C22 以降は**押す物を出すか**の層で、
 # 壊れた時の向きが違う: サーバは断り続けるので事故にはならないが、
 # 「押せる顔をして必ず失敗するボタン」や「見ていない選択が通る道」が電話に出る。
 # ★C22 は特別 —— これだけは**サーバの照合を通ってしまう**唯一の道(閉包を外すと
 #   古いボタンが新しい指紋を送るので `digest-mismatch` が起きない)。
 ("C22 ★指紋を押した時に読み直す(表示は古いまま、見ていない選択がサーバの照合を通る)", APP,
  "      sendChoice(b.key, digest);",
  "      sendChoice(b.key, choiceView(state).digest);"),
 # ★C23 に注記(5要素目)を書いて回したら「注記を外せる」と報告された = 到達する。
 #   注記の枠は「測った上で素通りが正しい」の意味なので外した。書きたかった内容は
 #   素通りの理由ではなく**この門の格**の話なので、こちらに置く:
 #   電話の伏せは**安全境界ではない**。二重打鍵を止めているのはサーバ側の
 #   `#choiceSent` とペイン鍵(C17/C19/W1)で、此処が緩んでも打鍵は二度届かない。
 #   伏せの役目は「必ず失敗する操作を人に見せない」= 雑音除け。
 #   だから此処が落ちた時に直すのは UI であって、サーバの守りを疑う合図ではない。
 ("C23 押下時にその描画のボタンを伏せない(二度押しが `choice-already-sent` の雑音になる)", APP,
  "      for (const x of made) x.disabled = true; // fetch より**前**に、同期で伏せる\n",
  ""),
 ("C24 打鍵ボタンの type を submit のままにする(将来 form に包まれた時、入力欄の Enter が撃つ)", APP,
  '    btn.type = "button";',
  '    btn.title = "";'),
 ("C25 1-9 の固定キーパッドを出す(5択の画面に、断られると分かっているボタンが4個並ぶ)", VIE,
  """    for (const o of options) {
      if (!Number.isInteger(o.n) || o.n < 1 || o.n > 9) continue;
      buttons.push({ key: String(o.n), label: `${o.n}. ${o.label}` });
    }""",
  """    for (let n = 1; n <= 9; n++) {
      const o = options.find((x) => x.n === n) || { n, label: "" };
      buttons.push({ key: String(n), label: `${o.n}. ${o.label}` });
    }"""),
 ("C26 ★keys が空でも操作を出す(サーバの許可一覧を電話が自前に上書きする)", VIE,
  """  if (keys.length === 0) {
    return { ...base, reason: CHOICE_BLOCKED[c.kind] || CHOICE_BLOCKED["unrecognized"] };
  }""",
  """  if (keys.length === 0 && c.kind === "not-a-real-kind") {
    return { ...base, reason: CHOICE_BLOCKED["unrecognized"] };
  }"""),
 ("C27 指紋の無い画面でも操作を出す(押した瞬間に必ず 400 になるボタン)", VIE,
  '  if (!digest) return { ...base, reason: CHOICE_BLOCKED["not-menu"] };\n',
  ""),
 ("C28 ★applied の値域を潰す(画面が動いていないのに「押しました」と出る)", VIE,
  '    if (b.applied === "verified") return { kind: "ok", text: "Pressed (screen change confirmed)." };',
  '    if (b.applied !== "nope") return { kind: "ok", text: "Pressed (screen change confirmed)." };'),

 # --- 配線 (W) = `inject.mjs` / `server.mjs` が鍵を**実際に通っている**か -------
 # 鍵単体(M88-M94)が完璧でも、注入器がそれを通らなければ何も守られない。
 # M と分けたのは、壊れた時に読む場所が違うから(M = 鍵の中身 / W = 繋ぎ目)。
 ("W1 送信が鍵を通らない(直列化を素通りする)", INJ,
  "      return await this.mutex.run(pane, () => this.#sendExclusive(pane, text), { signal });",
  "      return await this.#sendExclusive(pane, text);"),
 ("W2 鍵の値をペインでなく固定にする(別ペインが互いに待つ)", INJ,
  "      return await this.mutex.run(pane, () => this.#sendExclusive(pane, text), { signal });",
  '      return await this.mutex.run("ALL", () => this.#sendExclusive(pane, text), { signal });'),
 ("W3 断ったのに送ったと名乗る(`sent:true` / `delivered:\"verified\"`)", INJ,
  '      return { sent: false, state: "BUSY", delivered: null, reason: "pane-busy" };',
  '      return { sent: true, state: "BUSY", delivered: "verified", reason: null };'),
 # ★W4/W5/W6 は 2026-08-03 に的を付け替えた。割り込みの返り値が真偽値から4値
 #   (verified / already-done / unverified / null)へ変わり、探し文が本文に当たらなく
 #   なった為。**欠陥は同じ** —— 断ったのに「止めた」と名乗る / 鍵を通らない / 継ぎ目で化ける。
 # ★W4 は 2026-08-04 に**もう一度**的を付け替えた。旧的
 #   (`pressed:false` … `reason:"pane-busy"`)は**本文から消えた** —— §2.18-11 で割り込みが
 #   待ち上限に数えられなくなり、鍵が priority の取得を断る道が本番から無くなったので、
 #   断りを値に化かす catch ごと落とした(Codex `gpt-5.6-sol` xhigh Q3/Q4、2026-08-04)。
 #   **欠陥の名前は変えない**: 止めていないのに「止めた」と名乗る。今それを言える場所は
 #   期限切れの返り値なので、そこへ移した。到達する場所へ的を置き直しただけで、緩めていない。
 ("W4 止めていないのに「止めた」と返す(期限切れなのに verified を名乗る)", INJ,
  '    return { stopped: "unverified", reason: "still-in-flight", waited: seen.waited };',
  '    return { stopped: "verified", reason: null, waited: seen.waited };'),
 ("W5 割り込みを鍵の外へ出す(Escape が本文と Enter の間に落ちる)", INJ,
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), { priority: true });",
  "    return await this.#interruptExclusive(pane);"),

 # ★M104-M109 + W14 = §2.18-11「割り込みの行列優先」。**優先と束ねはセットでしか正しくない**
 #   ので、片方だけを撃つ変異が両側に要る(M104/M105 = 優先を外す / M106-M108 = 束ねを壊す)。
 #   M107 と M108 は「束ねの消し所」の**前後**を撃つ:早すぎ(M108)ても遅すぎ(M107)ても
 #   飢餓が戻る。同じ地図を消す1行の、置き場所だけが違う2つの欠陥。
 ("M104 優先の挿入位置を末尾へ戻す(FIFO へ退行 = 直す前の状態)", MTX,
  "        q.splice(i, 0, w);",
  "        q.push(w);"),
 ("M105 優先でも待ち上限を数える(混雑時に割り込みが 409 で断られる退行)", MTX,
  "      if (!priority && normalWaiters(q) >= maxWaiters) {",
  "      if (normalWaiters(q) >= maxWaiters) {"),
 ("M106 束ねを外す(連打で Escape が複数回飛び、次の番に当たる)", INJ,
  "    const joined = this.#interrupts.get(pane);\n    if (joined) return joined;\n",
  ""),
 # ★M107/M108 は 2026-08-04 に**向きが入れ替わった**。此処に在った規則
 #   (「畳むのは臨界区間の最後の同期文」)は、その走行で M107 が**素通り**した =
 #   検査がどちらの置き場所も区別できていなかった、と出た。区別できる計器
 #   (`gapMutex` = 解放前の隙でだけ撃つ鍵、`test/inject-serial.test.mjs` の (5b))を
 #   作って測ったら、規則が指していた方が**負けた**: `[Escape, Escape, 打:AAA]`
 #   (送信が追い越された)対 `[Escape, 打:AAA]`。だから本文は「消すのは settle 時の
 #   sweep だけ」へ改め、変異は**その両隣**を撃つ形にした。
 #   M107 = 遅すぎる方を撃つ(= 旧本文。臨界区間の中で畳む)。M108 = 早すぎる方(取得直後)。
 ("M107 束ねの消去を臨界区間の中へ戻す(解放の前に消す = 隙が開き、送信が追い越される)", INJ,
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), { priority: true });",
  """    return await this.mutex.run(pane, async () => {
      try { return await this.#interruptExclusive(pane); } finally { this.#interrupts.delete(pane); }
    }, { priority: true });"""),
 # ★M108 = 消し所が**早すぎる**形(§2.18-11 の表の A)。鍵を取った直後に消えるので、
 #   走っている間に来た割り込みが全部**先頭**へ積まれ、送信が永久に追い越される。
 ("M108 束ねの消去を鍵の取得直後へ前倒し(押しっぱなしで送信が走れない)", INJ,
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), { priority: true });",
  """    return await this.mutex.run(pane, () => {
      this.#interrupts.delete(pane);
      return this.#interruptExclusive(pane);
    }, { priority: true });"""),
 ("M109 束ねた実行へ呼び手の signal を転送する(合流した2本目が他人の期限で倒れる)", INJ,
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), { priority: true });",
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), { priority: true, signal });"),
 # ★W14 = 鍵は正しいのに**繋ぎ目が嘘**(§2.18-9 と同じ形)。M104/M105 が緑でも此処で死ぬ。
 ("W14 interrupt() が priority を渡さない(鍵は正しいのに繋ぎ目が嘘)", INJ,
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), { priority: true });",
  "    return await this.mutex.run(pane, () => this.#interruptExclusive(pane), {});"),
 # ★W6 も 2026-08-04 に付け替えた。旧的 `if (!out.pressed) {` は**到達不能**で、
 #   実際に素通りした(その走行が、注入器の catch とサーバの 409 を落とす根拠になった)。
 #   狙いは変えない —— **継ぎ目の嘘**: 注入器が「止まっていない」と返しているのに、
 #   サーバが電話へ「止めた」と出す。今その一行は `interrupted` の導出なので、そこを撃つ。
 #   到達する: e2e が「止まらなかった」「止める対象が無い」の2通りで false を要求している。
 ("W6 止まっていないのに `interrupted:true` を返す(電話へ「止めた」が出る)", SRV,
  "          interrupted: out.stopped === \"verified\",",
  "          interrupted: true,"),
 # ★W10-W12 = 2026-08-03 に作り直した判定そのものの的。ここを的にしないと、
 #   「止まりを観測した」の中身が誰にも見張られない状態で残る(この file の趣旨)。
 ("W10 印を**増分**でなく存在で見る(前の番に残った `Interrupted` を今の結果と読む)", INJ,
  "      if (interruptMarksIn(t) > marks0) return \"stopped\";",
  "      if (interruptMarksIn(t) > 0) return \"stopped\";"),
 ("W11 印が1枚消えただけで「止まった」と言う(生成中の 2-3 枠の空白を止まりと読む)", INJ,
  "      return ++quiet >= QUIET_FRAMES ? \"stopped\" : null;",
  "      return \"stopped\";"),
 ("W12 自力で終わったのを「止めた」と数える(already-done を verified に潰す)", INJ,
  "      if (doneMarksIn(t) > done0) return \"already-done\";",
  "      // mutated: 完了行を見ない"),
 # ★W13 = W11 と**対称の嘘**の的。2026-08-03、W11 が素通りしたのを追って
 #   「消失側(quiet)には的が在るのに、未 armed 側(idle)には1つも無い」と分かった。
 #   こちらが壊れると電話に「止める対象はありませんでした」と出たまま Claude が喋り続ける。
 ("W13 押した直後の1枚が空白なら「止める対象が無かった」と言う(生成の入り口を踏む)", INJ,
  "      if (!armed) return ++idle >= PRE_FRAMES ? \"idle\" : null;",
  "      if (!armed) return \"idle\";"),
 # ★W15-W18 / W24-W26 = 死因を電話へ届ける経路(§2.21 / §3-W)。ここが壊れると電話には
 #   `worker exited code=1` だけが出て**理由が消える** —— 「読めなかった」ではなく
 #   「最初から読んでいない」側の倒れ方(§2.16 の production 版)。
 #   W16/W24 は**漏れ**の的。素通りしたら、伏字は在るのに効いていない。
 ("W15 stderr を捨てる(= 直す前の姿。死因が電話に一度も出ない)", WRK,
  "    proc.stderr?.on?.(\"data\", (chunk) => pushStderr(entry, chunk));",
  "    proc.stderr?.on?.(\"data\", noop);"),
 ("W16 伏字を通さずそのまま添える(account= の実メールが電話へ)", WRK,
  "  pushRedacted(entry, redact(rawLine));",
  "  pushRedacted(entry, rawLine);"),
 ("W17 溜める側の上限を外す(喋り続ける子で無限に伸びる)", WRK,
  "  while (entry.stderrTail.length > 1 && total > TAIL_KEEP_BYTES) {",
  "  while (false) {"),
 # ★W18 = §2.21-a で見つけた順序の罠。`onDeath` は先に `workers.delete` を呼ぶので、
 #   Map 経由で読むと**必ず空の尾**が出る。「理由なしで着く」が直った様に見えて直らない。
 ("W18 尾を閉包でなく workers Map から読む(delete 済みなので必ず空)", WRK,
  "          stderr: flushStderr(entry),",
  "          stderr: flushStderr(this.workers.get(sessionId) || { stderrTail: [], errBuf: \"\" }),"),
 ("W24 切ってから伏せる(切れたメールの左半分が網を抜ける)", WRK,
  "    pushRedacted(entry, red.slice(0, TAIL_LINE_MAX));",
  "    pushRedacted(entry, redact(entry.errBuf.slice(0, TAIL_LINE_MAX)));"),
 ("W25 出す側の上限を外す(1件の失敗で電話へ 4KB 流す)", WRK,
  "  const out = entry.stderrTail.slice(-TAIL_EMIT_LINES);",
  "  const out = entry.stderrTail.slice();"),
 # ★的に**閉じ括弧まで**入れてある。8 空白の行だけでは 10 空白の行(= W18 と同じ site B)の
 #   部分文字列になって**2件に当たる**(`--dry` が `NG(2件)` で出した。2026-08-03)。
 #   site A は `      });`(6 空白)で閉じ、site B は `        });`(8 空白)で閉じる。
 # ★2026-08-04 に的を付け替えた。site A に `stale` 欄が増えて、旧探し文の `\n      });` が
 #   もう続かない(= `--dry` の「当たらない 1件」で pre-commit gate に捕まった)。欄を消すのでは
 #   なく**site A を撃つ**事が W26 の趣旨なので、探し文を今の本文へ寄せた。続く註釈行を
 #   1行入れてあるのは上と同じ理由 —— 8 空白の行だけでは site B の部分文字列に当たる。
 ("W26 異常終了側にだけ死因を付ける(spawn 失敗は理由なしのまま電話へ)", WRK,
  "        stderr: flushStderr(entry),\n        // ★**今の子の失敗か",
  "        // mutated: 片方だけ\n        // ★**今の子の失敗か"),
 # --- W19-W23: 会話の**居場所**(DESIGN §2.22 / §3-V)。検出は `test/server-cwd.test.mjs`
 #   の静的検査 —— `server.mjs` は import すると listen するので単体から呼べない。
 ("W19 会話の居場所を spawn に渡さない($HOME で開く)", SRV,
  "cwd: plan.cwd });",
  "cwd: HOME });"),
 ("W20 場所が無い会話を既定値へ落とす(断るべき所で通す)", SRV,
  "cwd: plan.cwd });",
  "cwd: plan.cwd || HOME });"),
 ("W22 起こす直前の同期確認を外す(検査と spawn の間に消えた dir で 202 を返す)", SRV,
  "\n    realpathSync(plan.cwd);\n",
  "\n    // mutated: 同期の確認を外す\n"),
 ("W21 未信頼でも断らずに送る(電話から答えられない確認画面を作る)", SRV,
  '      if (verdict !== "ok") {\n        return json(res, 409, {\n          accepted: false, route: "worker", reason: verdict,\n          error: WORKER_REFUSAL[verdict],\n        });\n      }\n',
  "      // mutated: 断らない\n"),
 # ★**書く形の変異は作らない**。木に一瞬でも信頼一覧へ書く文を置きたくない
 #   (Tom の裁定「自動化に安全確認を押させない」の的は、書く手段が**在る事**そのもの)。
 #   同じ的は「server が Claude Code の一覧を自前で読み直す」形で当てる —— 読むだけで、
 #   `test/server-cwd.test.mjs` の `hasTrustDialogAccepted` 検査には同じく引っ掛かる。
 ("W23 信頼を server が自前で判定する(正本を Claude Code から奪う)", SRV,
  "      const verdict = cwdVerdict(wcwd);",
  '      const verdict = wcwd.includes("hasTrustDialogAccepted") ? "ok" : cwdVerdict(wcwd);'),
 # ★W7-W9 も継ぎ目(W6 と同じ狙い、H2 側)。`worker.mjs` の単体検査は**計画(plan)**まで
 #   しか見られない —— 実際に `--fork-session` を渡すのも、頭の読み書きを繋ぐのも
 #   `server.mjs` で、そこは import した瞬間に listen するので単体から呼べない。
 #   つまり**単体が満点でも配線が抜けていれば H2 は成立しない**。e2e 8-b がその唯一の目。
 ("W7 計画が fork でも `--fork-session` を渡さない(元の転写へ2人目が書く)", SRV,
  '      ...(plan.fork ? ["--fork-session"] : []),',
  "      "),
 ("W8 頭を無視して祖先へ resume する(枝の先端を捨てる)", SRV,
  '      "--resume", plan.resumeId,',
  '      "--resume", sessionId,'),
 ("W9 頭の読み書きを繋がない(毎回 fork し続け、枝が increment しない)", SRV,
  """  heads: {
    read: (ancestor) => readBranchHead(HEADS_DIR, ancestor),
    write: (ancestor, head) => writeBranchHead(HEADS_DIR, ancestor, head),
  },""",
  "  "),

 # --- 電話の面 (P) = 「失敗を成功の顔をした値に化かす」型の再発防止 --------------
 # 2026-08-02 に5件見つけた。全部同じ病気: `|| {}` / `|| []` / `.catch(() => ({}))` が
 # 「読めなかった」を「読めた」側へ倒す。M/W と分けたのは読む場所が違うから
 # (M = 部品の中身 / W = 繋ぎ目 / P = 電話に**何が見えるか**)。
 # ★P4-P8 は静的検査が的。DOM の検査台が無いので「書いてある事」しか測れていない。
 #   その限界は app-html.test.mjs の冒頭注記と同じ理由でここにも書いておく。
 ("P1 送信 202 で読めない本文を `{}` に潰す(確認していないのに「送った」と名乗る)", VIE,
  """    if (body == null) {
      return {
        kind: "warn",
        text: "Sent, but the server's reply could not be read. Your text is kept — resending may duplicate it.",
        keepText: true,
      };
    }""",
  "    void body;"),
 ("P9 読めない本文でも入力欄を空にする(打った文が黙って消える)", VIE,
  '        text: "Sent, but the server\'s reply could not be read. Your text is kept — resending may duplicate it.",\n        keepText: true,',
  '        text: "Sent, but the server\'s reply could not be read. Your text is kept — resending may duplicate it.",\n        keepText: false,'),
 ("P2 その守りを広げすぎる(delivered の無い正当な worker 応答まで warn にする)", VIE,
  "    if (body == null) {\n      return {\n        kind: \"warn\",",
  "    if (!b.delivered) {\n      return {\n        kind: \"warn\","),
 ("P3 割り込み 200 で読めない本文を「対象が無かった」と断定する", VIE,
  '      return { kind: "warn", text: "Could not confirm the stop. Check the screen." };',
  '      return { kind: "warn", text: "There was nothing to stop." };'),
 # ★2026-08-04: 打鍵の口(`sendChoice`)が3本目になった時、割り込み側の find が**2箇所に当たる**
 #   ようになって的の照合が NG を出した(コメント行まで写しだったため)。曖昧な的は
 #   「どこを壊したか」を言えないので、各行を**次の行の判定関数名**で一意に留め直した。
 ("P4 読めなかった応答を `{}` に捏造して判定層へ渡す(送信・割り込み・打鍵の3箇所)", APP,
  ["    const body = await r.json().catch(() => null);\n    const v = sendResult(r.status, body);",
   "    const body = await r.json().catch(() => null); // ★send() と同じ。読めない事を値にしない\n    const v = interruptResult(r.status, body);",
   "    const body = await r.json().catch(() => null); // ★send() と同じ。読めない事を値にしない\n    const v = choiceResult(r.status, body);"],
  ["    const body = await r.json().catch(() => ({}));\n    const v = sendResult(r.status, body);",
   "    const body = await r.json().catch(() => ({}));\n    const v = interruptResult(r.status, body);",
   "    const body = await r.json().catch(() => ({}));\n    const v = choiceResult(r.status, body);"]),
 ("P5 前面へ戻った時の張り直しを外す(帯が証拠なく「つながっています」と出し続ける)", APP,
  'document.addEventListener("visibilitychange", onForeground);',
  "void onForeground;"),
 ("P6 履歴の失敗経路で描き直さない(「以前を読む」が二度と押せなくなる)", APP,
  """      notice("error", `履歴を取れませんでした(${e.message})`);
      // ★描き直す。「以前を読む」は押した時に自分を disabled にするので、失敗したまま
      //   描き直さないと**二度と押せない**(renderConv がボタンを毎回作り直す設計に依存)。
      renderConv();""",
  '      notice("error", `履歴を取れませんでした(${e.message})`);'),
 ("P7 形の違う一覧を「会話がありません。」という断定に化かす", APP,
  ['    if (!Array.isArray(data.sessions)) throw new Error("一覧の形が読めません");',
   "  const rows = data.sessions.map((s) => sessionRow(s, now));"],
  ["    void data;",
   "  const rows = (data.sessions || []).map((s) => sessionRow(s, now));"]),
 ("P8 形の違う履歴を空の履歴として飲む", APP,
  ['    if (!Array.isArray(d.history)) throw new Error("履歴の形が読めません");',
   "    conv.history = d.history;"],
  ["    void d;",
   "    conv.history = d.history || [];"]),

 # --- P10-P15: fork した会話を頭へ畳む (§3-T / DESIGN §2.18-4b) -----------------
 # ★この族は新機能の守りではなく**出荷済みの欠陥に当てた回帰の的**。素通りしたら、
 #   電話は「机で fork した会話の現在」をまた失う(古い行 → やがて `limit` で行ごと消える)。
 # ★罠2(P15)を撃つのは e2e の検査1。`st` と `p` の組を崩すと `head` が付かず、
 #   祖先の行に**祖先の**(空の)lastPrompt が出る。覚え書きの汚れ自体は外から見えないので、
 #   見える所に出る同じ原因を的にしている。
 ("P10 頭への差し替えを sort の後へ回す(limit に当たった時だけ祖先が消える)", SRV,
  "  found.sort((a, b) => b.sortMs - a.sortMs);",
  "  found.sort((a, b) => b.st.mtimeMs - a.st.mtimeMs);"),
 ("P11 頭そのものの行を落とさない(枝が別の会話として湧く)", SRV,
  "    if (headIds.size) found = found.filter((e) => !headIds.has(e.sessionId));",
  "    // mutated: 頭の行を落とさない"),
 ("P12 頭が読めない時に行ごと落とす(fail-loud 側へ倒れて会話が消える)", SRV,
  "      if (!he) continue;",
  "      if (!he) { headIds.add(e.sessionId); continue; }"),
 ("P12b メタを丸ごと頭から採る(行の所属が枝の cwd に化ける)", SRV,
  "      if (hm) meta = { ...meta, lastPrompt: hm.lastPrompt, turns: hm.turns };",
  "      if (hm) meta = { ...meta, ...hm };"),
 ("P13 /history の引き先を祖先へ戻す(fork の後の番が電話に出ない)", SRV,
  "      return (headId && headId !== sessionId && findSessionFile(headId)) || file;",
  "      return file;"),
 ("P14 only を広げない(scope=registered でだけ静かに畳めなくなる)", SRV,
  """  let scope = only;
  if (only && heads) {
    scope = new Set(only);
    for (const a of only) {
      const h = heads.get(a);
      if (h) scope.add(h);
    }
  }""",
  "  const scope = only;"),
 ("P15 st だけ差し替えて p を祖先のまま残す(覚え書きの鍵と中身がずれる)", SRV,
  "      e.head = { p: he.p, st: he.st, slug: he.slug };",
  "      e.st = he.st;"),

 # --- 子プロセスの生き死に (X) = H2「1つの転写に書き手が2人」を守る層 -------------
 # ★★この族は **復元** である。原本は 2026-08-02 16:43 開始の 119 件走行の中にしか存在せず、
 #   走行中(16:55)に台本が上書きされて disk からも 12 commit 全部からも消えた。走行ログに
 #   残った題名だけが手掛かり = **同じ的を書き直したという保証は無い**。走行時は X1〜X9 が
 #   あり X2-X7/X9 の7件が検出された。X1/X8 は当時**素通り**し、その素通りを根拠に
 #   `entry.retired` 旗そのものが削除された(`src/worker.mjs` の同一性判定の docstring に
 #   その経緯が書いてある) = X1/X8 は失われたのではなく**意図的に退役**した。だから復元は7件。
 #   復元の意味は「同じ判定を再現する」ではなく「この7つの守りが今も殺されるかを測り直す」。
 #
 # なぜ worker.mjs に的が要るか: この module だけが**本物の Claude プロセスを起こして殺す**。
 # ここが緩むと1つの転写に2人が書く(H2)。単体試験は前からあったが、その試験の**強さ**は
 # この復元まで一度も測られていなかった(M/W/P の的が1つも刺さっていなかった)。
 ("X2 遅い名乗りを撥ねない(死んだ子が新しい子の頭を上書きする)", WRK,
  "    if (this.workers.get(sessionId) !== entry) return; // 死んだ/差し替わった後の遅い名乗り",
  "    // 撥ねない"),
 ("X3 世代を見ずに頭を書く(古い世代の子が現世代の頭を奪う)", WRK,
  "    if (entry.gen !== this.gens.get(sessionId)) return; // 世代が進んでいる",
  "    // 世代を見ない"),
 ("X4 未確認の先代が居ても分岐しない(まだ生きている子と同じ転写へ二重に書く)", WRK,
  "return { fork: !head || undead, resumeId: head || sessionId, cwd };",
  "return { fork: !head, resumeId: head || sessionId, cwd };"),
 ("X5 死を確認しても印を外さない(以後ずっと分岐し続ける = 会話が毎回切れる)", WRK,
  "      set.delete(entry);",
  "      void entry;"),
 ("X6 猶予後の SIGKILL を撃たない(SIGTERM を無視した子が残り続ける)", WRK,
  """    entry.killTimer = this.setTimer(() => {
      entry.killTimer = null;
      try {
        entry.proc.kill("SIGKILL");
      } catch {
        /* already gone */
      }
    }, this.killGraceMs);""",
  "    entry.killTimer = null;"),
 ("X7 再開先に頭でなく元の id を渡す(枝の続きでなく根から喋り直す)", WRK,
  "return { fork: !head || undead, resumeId: head || sessionId, cwd };",
  "return { fork: !head || undead, resumeId: sessionId, cwd };"),
 ("X9 退役の記録を積まず上書きする(2人目を退役させた瞬間に1人目を見失う)", WRK,
  """    let set = this.dying.get(sessionId);
    if (!set) { set = new Set(); this.dying.set(sessionId, set); }
    set.add(entry);""",
  """    const set = new Set();
    this.dying.set(sessionId, set);
    set.add(entry);"""),

 # --- 追いつきリング (R) = 再接続で「間が失われた」を黙って連続に見せない層 ----------
 # `src/ring.mjs` は 39 行で単体はあるが、**変異の的はゼロ**だった = その単体の強さが
 # 一度も測られていない。ここの中心は `out.gap = true` —— リングから溢れて連続性を
 # 保証できない時だけ立つ印で、これが落ちるとクライアントは /history の読み直しへ
 # 倒さず、**欠けた列を連続として描く**(= 電話に嘘の履歴が出る)。
 # 族の性質は M/P と同じ病気の一族: 「読めなかった」を値として通す形。
 # ★2026-08-04: 量の門を足した時に本文が `if` から `while` へ変わり、この的が外れた
 #   (`--dry` が「当たらない 1件」で捕まえた = 門が仕事をした実例)。
 ("R1 溢れても切り捨てない(固定長リングが無限に伸びる)", RNG,
  "    while (this.buf.length > this.capacity) this.bytes -= this.buf.shift().bytes;",
  "    void 0;"),
 ("R2 溢れを黙って連続として渡す(gap を立てない = 嘘の連続性)", RNG,
  "    if (seq + 1 < oldestHeld) out.gap = true;",
  "    void oldestHeld;"),
 # ★R3 は**退役**(2026-08-02)。素通りしたが、これは検査の穴ではなく**等価変異**だった。
 #   的: `... : this.nextSeq` を `... : 0` に変える(空リングの起点)。
 #   実測で挙動が変わる入力は **`since(-1)` の1点だけ**(orig gap=true / mut gap=false)。
 #   そして負の seq は `src/tail.mjs` の `/^\d+$/` で撥ねられるので **since() に到達しない**
 #   (唯一の呼び口は `server.mjs` の `f.ring.since(d.seq)` と、その薄い委譲
 #    `worker.mjs` の `this._ring(sessionId).since(seq)`)。
 #   到達しない入力でしか殺せない変異を的に残すと、それを殺す為だけの**現実に無い入力の検査**を
 #   書く事になり、計器が嘘の穴を報告し続ける。だから的を退役させ、根拠をここに残す。
 #   ★依存: この等価性は「buf が空 ⟹ nextSeq === 1」に乗っており、それを保証しているのは
 #   R5 の `capacity >= 1` 検査。R5 を消すと R3 の等価性も静かに崩れる(capacity=0 なら
 #   buf は空のまま nextSeq だけ進む)。その土台は `test/ring.test.mjs` に検査として固定した。
 ("R4 since が要求 seq 自身も返す(再接続のたびに1件二重に見える)", RNG,
  "    const out = this.buf.filter((e) => e.seq > seq);",
  "    const out = this.buf.filter((e) => e.seq >= seq);"),
 ("R5 capacity の検査を外す(0 や負で構築でき、以後 push が全部消える)", RNG,
  """    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error(`EventRing: capacity must be a positive integer, got ${capacity}`);
    }""",
  "    void capacity;"),
 # --- R12-R14 = 量の門 (2026-08-04) ------------------------------------------------
 # 件数の門(R1)は**1件の大きさを問わない**。tool 結果が数 MB になる 1 行が来ると
 # 256 件 x 数 MB がそのまま常駐し、会話は `feeds` / `WorkerManager.rings` に溜まり続ける
 # (どちらも掃除する口が無い)ので、常駐量は**会話数 x 1件の大きさ**で伸びる。
 # R1 の的だけ在って量の的がゼロだと、「リングは上限を守る」という主張の**半分しか**
 # 測っていない事になる(件数は測る / 量は誰も見張っていない)。
 ("R12 量の門を外す(件数に余裕が在る限り、1件が何 MB でも溜め続ける)", RNG,
  """    while (this.buf.length > 1 && this.bytes > this.maxBytes) {
      this.bytes -= this.buf.shift().bytes;
    }""",
  "    void 0;"),
 ("R13 maxBytes の検査を外す(0 や負で構築でき、最新1件しか残らないリングが静かに出来る)", RNG,
  """    if (!Number.isInteger(maxBytes) || maxBytes < 1) {
      throw new Error(`EventRing: maxBytes must be a positive integer, got ${maxBytes}`);
    }""",
  "    void maxBytes;"),
 # ★R14 は「効かない門」の的。UTF-16 の文字数で測ると、日本語(UTF-8 で 3 byte)の会話では
 #   **3 倍過小評価**する = 門は在るのに実質 3 倍まで溜まる。門の**有無**でなく**目盛り**の変異。
 ("R14 量を UTF-16 の文字数で測る(日本語の会話で上限が実質 3 倍に緩む)", RNG,
  '  return Buffer.byteLength(s, "utf8");',
  "  return s.length;"),
 # --- R6-R11 = 長待ち受け(long-poll)の栞 (2026-08-04、DESIGN §2.36) ------------------
 # 族が `src/ring.mjs` から広がった。電話の配信が SSE から long-poll へ替わった事で、
 # 「間が失われたのを黙って連続に見せない」責任が **栞の判定 (`tail.mjs`) と
 #  世代の印 (`server.mjs` / `worker.mjs`)** に分かれた。的を ring.mjs に留めると、
 # 同じ病気の**新しい住処**を1つも見張らない事になる。
 # ★R10/R11 の限界を先に書く: 此処が守っているのは「process を跨いだ栞の偶然の一致」で、
 #   それは process を跨いで測っていない。的が殺せるのは**連番への退化**(印が `1`)と
 #   **固定値への退化**(全会話で同じ)の2つだけ。乱数性の証明ではない。
 ("R6 栞の世代を照合しない(再起動を跨いだ古い栞が「追いついた」と読まれる)", TAI,
  'if (tok !== String(token)) return { kind: "gap", why: "epoch-mismatch" };',
  "void tok;"),
 ("R7 栞の経路を照合しない(tmux と worker で seq の空間が違うのに繋ぐ)", TAI,
  'if (r !== (route === "tmux" ? "t" : "w")) return { kind: "gap", why: "route-changed" };',
  "void r;"),
 ("R8 栞の数字を検めない(`x` が NaN の seq として ring.since へ渡る)", TAI,
  'if (!/^\\d+$/.test(sq) || !/^\\d+$/.test(sr)) return { kind: "gap", why: "cursor-malformed" };',
  "void sq; void sr;"),
 ("R9 取りこぼしを ring に載せず流すだけにする(切れている間の gap が消える)", SRV,
  """  const seq = f.ring.push({ kind: "gap", why });
  feedBroadcast(f, { id: `${f.epoch}.${seq}`, event: "gap", data: { rereadHistory: true, why } });""",
  '  feedBroadcast(f, { event: "gap", data: { rereadHistory: true, why } });'),
 ("R10 世代の印を連番へ戻す(再起動後の最初の feed が前の栞と偶然一致する)", SRV,
  'return randomBytes(4).toString("hex"); // `.` を含まない = 栞の区切りと衝突しない',
  'return "1";'),
 ("R11 ワーカー側の世代の印を連番へ戻す(同上。manager 側の同じ穴)", WRK,
  "this.generation = generation || randomBytes(4).toString(\"hex\");",
  'this.generation = generation || "1";'),
 # ---- H 系(外向きの生存信号の判定層。DESIGN §7-P)-----------------------
 # ★13枚とも砂場で先に「赤くなる」事を層ごとに実測してから入れた(APPLY-PLAN-phaseP §3)。
 #   変異走行は `npm test` と `test/e2e-local.mjs` を回すが `health-observer-controls.sh` は
 #   回さない。素通りしたら検査の穴でなく**当て損ね**を先に疑う。
 ("H1 戻り判定の門を外す(落ちていないのに『戻りました』と鳴る)", HLT,
  'if (prev.status === "down") {',
  'if (prev.status !== "xxx") {'),
 ("H2 重複抑止を外す(落ちた後も10分毎に鳴り続ける = 黙らされる)", HLT,
  "fails >= threshold && !toldItsDown",
  "fails >= threshold"),
 ("H3 閾値の比較をずらす(>= → >。1回ぶん遅れて鳴る)", HLT,
  "fails >= threshold &&",
  "fails > threshold &&"),
 ("H4 since を連続の頭でなく毎回今にする(『何時から』が嘘になる)", HLT,
  "prev.fails === 0 ? now : prev.firstFailAt",
  "now"),
 ("H5 連続を数えない(fails が増えず**永久に鳴らない**)", HLT,
  "const fails = prev.fails + 1;",
  "const fails = 1;"),
 ("H6 閾値の門を外す(0 を通す = 黙って鳴らない監視が作れる)", HLT,
  "if (!Number.isInteger(threshold) || threshold < 1) {",
  "if (false) {"),
 ("H7 成功で連続を消さない(復旧を挟んでも数え続ける)", HLT,
  'state: { status: "up", fails: 0, firstFailAt: null, owed: null },',
  'state: { status: "up", fails: prev.fails, firstFailAt: prev.firstFailAt, owed: null },'),
 ("H8 秒/分の境目をずらす(60秒を『0分』と言う側へ)", HLT,
  "if (sec < 60) return",
  "if (sec < 61) return"),
 ("H9 『伝え済み』の判定から status を落とす(初回の落下が一度も鳴らない)", HLT,
  'const toldItsDown = prev.status === "down" && prev.owed === null;',
  "const toldItsDown = prev.owed === null;"),
 ("H10 借りを返しても消さない(同じ警報を10分毎に鳴らし続ける)", HLT,
  "return { ...state, owed: null };",
  "return { ...state };"),
 ("H11 未配達の『戻りました』を鳴らし直さない(復旧を Tom が永久に知らない)", HLT,
  'if (prev.owed !== null && prev.owed !== undefined && prev.owed.kind === "recovered") {',
  "if (false) {"),
 ("H12 鳴らし直す復帰の秒数を測り直す(落ちていた長さが10分毎に伸びる嘘)", HLT,
  "const note = { ...prev.owed };",
  "const note = { ...prev.owed, seconds: now };"),
 ("H13 項の欠落を『返済済み』に丸める(古い状態を読んだ瞬間に落下が鳴らない)", HLT,
  'const toldItsDown = prev.status === "down" && prev.owed === null;',
  'const toldItsDown = prev.status === "down" && (prev.owed === null || prev.owed === undefined);'),
 # ★V 族 = 見た目と古さ(2026-08-03、DESIGN §2.19)。ここは**描画を観測できない**層なので、
 #   検査が測るのは「規則がそう書かれている事」だけ。だからこそ的が要る:
 #   規則を測る検査は、規則を消しても緑のままになりやすい(= 一番静かに死ぬ種類の検査)。
 ("V1 画面の箱から安全域の余白を外す(送るボタンが画面の外へ出る)", APP,
  "    padding: env(safe-area-inset-top) env(safe-area-inset-right) 0 env(safe-area-inset-left);",
  ""),
 ("V2 いつ測ったか分からない一覧を『新しい』側へ倒す(警告だけ消えて値は古いまま)", VIE,
  '    return { text: "Measured at an unknown time", stale: true };',
  '    return { text: "", stale: false };'),
 ("V3 古さの境目を外す(何時間前の値でも「今」を名乗る)", VIE,
  "  if (d < 60) return { text: `As of ${d}s ago`, stale: false };",
  "  if (d < 6000) return { text: `As of ${d}s ago`, stale: false };"),
 ("V4 前面へ戻った時の一覧の取り直しを外す(拾っても20分前の値のまま)", APP,
  'document.addEventListener("visibilitychange", onForegroundList);',
  ""),
 ("V5 入力欄の上限を鍵盤前の画面に戻す(鍵盤が半分を占めた時に本文が潰れる)", APP,
  "  e.target.style.height = `${Math.min(e.target.scrollHeight, visibleHeight() * 0.4)}px`;",
  "  e.target.style.height = `${Math.min(e.target.scrollHeight, window.innerHeight * 0.4)}px`;"),
 ("V6 CSS 側の上限だけ古い物差しへ戻す(JS を直しても『直した筈』で残る型)", APP,
  "  textarea { resize: none; max-height: calc(var(--vvh, 100dvh) * 0.4); }",
  "  textarea { resize: none; max-height: 40dvh; }"),
 ("V7 高さの物差しを2つに割る(値は正しいが読む場所が増える = 次に片方だけ古くなる)", APP,
  "  e.target.style.height = `${Math.min(e.target.scrollHeight, visibleHeight() * 0.4)}px`;",
  "  e.target.style.height = `${Math.min(e.target.scrollHeight, window.visualViewport.height * 0.4)}px`;"),
 ("V8 実高さの落とし先を外す(visualViewport が無い環境で高さが 0 になる)", APP,
  "  return Math.round((vv && vv.height) || window.innerHeight || 0);",
  "  return Math.round((vv && vv.height) || 0);"),
 # --- V9/V10 = 長待ち受けの応答の形を検める層 (2026-08-04、DESIGN §2.36) --------------
 # ★この2枚は「判断を app.html に置かない」規則の**費用**を測る物でもある。初版は
 #   この関数を画面側に書いており、そこでは的を当てても単体も e2e も動かない。
 #   view.mjs へ移した瞬間に、ワーカー経路を毎回落とす取り違えが出た。
 ("V9 応答の形を検めず何でも通す(読めない形を空の配信として飲む)", VIE,
  '  if (!d || typeof d !== "object" || !Array.isArray(d.items)) return false;',
  "  if (!d) return true;"),
 ("V10 ワーカー経路の形を読めない事にする(worker の poll が毎回例外へ落ちる)", VIE,
  '    if (it.kind === "message" && !Array.isArray(it.entries) && !isPlainEvent(it.event)) return false;',
  '    if (it.kind === "message" && !Array.isArray(it.entries)) return false;'),
 # ★V11 = 実際に手が滑った形そのもの。存在確認だけを門にすると、前の会話の後始末が
 #   新しい会話の `reading` を偽にして、前面復帰の撃ち直しが黙って消える。
 ("V11 世代の門を存在確認へ落とす(前の購読の後始末が次の会話を黙らせる)", APP,
  "      if (conv && conv.gen === myGen) conv.reading = false;",
  "      conv && (conv.reading = false);"),
 # --- Q 族 = 送信待ちの取り消し(2026-08-04、DESIGN §2.46)------------------------
 # ★この口は**電話に「取り消した」と出す**。壊れ方が全部「成功と出たまま中身が違う」側に
 #   倒れるので、検査が緑のままだと人は気付けない。だから4つの嘘それぞれに的を置く:
 #   ①観測していない数を断定する ②数の出所を持ち主から奪う ③捨てていないのに捨てたと言う
 #   ④取り消しが**走っている番**を巻き込む(= 人が読んだ意味と違う事をする)。
 # ★的の所番地は S8-26 で `src/server.mjs` から `src/wire.mjs` へ移った(封筒を純関数へ
 #   切り出した)。**変異の中身は一字も変えていない** —— 同じ嘘を、同じ行に、移った先で
 #   当てている。錨が腐った事は pre-commit の `--dry` が「当たらない 1件」で捕まえた。
 ("Q1 机の会話の送信待ちを `0` と断定する(観測していない事の反対を言う)", WIR,
  "    queued: null,",
  "    queued: 0,"),
 ("Q2 送信待ちの数を持ち主から貰わず固定にする(捨てても数が動かない)", SRV,
  "          queued: manager.status(sessionId).queued,",
  "          queued: 0,"),
 ("Q3 机の会話でも「捨てました(0件)」と返す(持っていない行列について観測を主張する)", SRV,
  '        markResult(res, { reason: "queue-not-ours" });',
  '        return json(res, 200, { dropped: 0, route: "tmux" });'),
 # ★Q4 = **自分の diff を読み直して出た欠陥**そのもの。無条件に起こすと、捨てる物が無い時に
 #   出来事ゼロで保留を起こす = 電話が空の 200 で張り直す(長待ち受けを選んだ理由を壊す)。
 ("Q4 保留を無条件に起こす(捨てる物が無い時に電話へ空の応答を返させる)", SRV,
  "      if (dropped > 0) wakeWorkerPolls(sessionId);",
  "      wakeWorkerPolls(sessionId);"),
 ("Q5 数だけ数えて実際には捨てない(電話には成功と出て、行列は残る)", WRK,
  "    return this._dropQueued(sessionId, e, reason);",
  "    return e.queue.length;"),
 # ★Q6 = `null`(知らない)と `0`(無いのを見た)を1つに潰す変異。潰しても画面の見た目は
 #   同じ(どちらも何も出さない)ので、**判断層の検査だけ**が捉えられる。
 ("Q6 「知らない」を「0件」に潰す(次に机の会話へ 0 を出す直しが正しく見える)", VIE,
  '  if (typeof q !== "number" || !Number.isFinite(q)) {',
  "  if (false) {"),
 ("Q7 「動いている番は止まらない」を文面から落とす(取り消した=全部止まった と読める)", VIE,
  "    return { kind: \"ok\", text: `Cancelled ${n} queued sends (the one already running is not stopped).` };",
  "    return { kind: \"ok\", text: `Cancelled ${n} queued sends.` };"),
 ("Q8 押した後で伏せる(二度押しが同じ物を2回捨てに行く)", APP,
  "    btn.disabled = true; // fetch より前に、同期で伏せる。二度押しは同じ物を2回捨てに行く",
  "    // mutated: 伏せない"),
]

# ★変異の番号は一意でなければならない(2026-08-02 追加。実際に M69-M73 を重複させた)。
# 重複しても走行は正しいが、**報告と `--only` がどちらの変異の事か言えなくなる**。
# 「対象行が無い」で片方が空振りしても、もう片方が検出なら人は番号で見分けられない。
# 番号は人が結果を追う為の同一性なので、機械で見張る。台本の起動段で落とす(測る前に止める)。
# ★接頭辞の集合は「読む場所」の一覧そのもの: M = 部品の中身 / W = 繋ぎ目 /
#   X = H2(1つの転写に書き手が2人)を守る層 / P = 電話に何が見えるか /
#   R = 追いつきリング(再接続で「間が失われた」を黙って連続に見せない層)。
#   H = 外向きの生存信号の判定層(落ちた/戻ったを Tom に伝え終えたかを持つ層)。
#   V = 電話の画面の**見た目と古さ**の層(安全域・実高さ・「いつ測った値か」)。
#     ここだけ性質が違う: この計画には描画を観測できる器械が無いので、V が守る検査は
#     「規則がそう書かれている事」しか測れない。だから的が要る = 規則を消しても緑のままなら、
#     その検査は最初から何も掴んでいない。P(電話に何が見えるか)は判定の中身、V は画面の器。
#   2026-08-02: ここが `[MW]` だった為、走行中のメモリにしか無かった X 系を書き戻そうとすると
#   台本自身が起動段で落ちる状態だった = **この検査が X の復元を機械的に禁じていた**。
#   新しい族を足す時はここも足す。足し忘れると「番号で始まっていない」で止まる(fail-closed)。
#   2026-08-03: 族の文字は**ここ1箇所**に持つ。同じ一覧が起動段の検査と `--only` の
#   選び方に2重に書かれていて、`--only` 側は `[MWXPR]` のまま = H/V を族として選べず、
#   題名の部分一致に黙って落ちていた(`--only V` が題名に大文字 V を含む物まで拾う)。
#   上の「新しい族を足す時はここも足す」が守れなかったのは、足す場所が2つあったから。
#   C = 選択メニューへの打鍵の層(良性と同定できた画面にしか打たない = 許可一覧)。
#   Q = 送信待ちの行列(数を誰が持つか / 取り消しが**走っている番**に触らない事)。
#     この族の壊れ方は全部「電話には成功と出たまま中身が違う」側に倒れる。
FAM = "MWXPRHVCQ"

# ★番号の後ろの1文字(`P12b`)を許す(2026-08-03)。`b` は「**同じ場所を別の壊し方で撃つ**」
#   という既にある書き方で、DESIGN §2.18-4b の検査 4b と対を成す。別番号(P16)へ逃がすと
#   題名を読んでも**どの的の変種か**が分からなくなるので、番号の側を広げる。
_named = [(re.match(rf"[{FAM}]\d+[a-z]?(?=[ (])", m[0]), m[0]) for m in MUT]
_unnamed = [t for mo, t in _named if not mo]
if _unnamed:
    sys.exit("★台本を止める: 番号で始まっていない変異がある: " + " / ".join(_unnamed[:3]))
_ids = [mo.group(0) for mo, _ in _named]
# 並べ替えの鍵は接尾辞に耐える事(`int("12b")` は ValueError)。重複が出た時にしか通らない
# 道なので、壊れていても普段は誰も踏まない = 気付ける機会が無い。ここで潰す。
_dupes = sorted({i for i in _ids if _ids.count(i) > 1},
                key=lambda s: (int(re.match(r"[A-Z](\d+)", s).group(1)), s))
if _dupes:
    sys.exit(
        f"★台本を止める: 変異の番号が重複している: {', '.join(_dupes)}\n"
        "(走らせれば結果は出るが、その結果がどの変異の物か言えない = 計器として壊れている)"
    )

# ★2026-08-01 に実機で踏んだ欠陥: 落ちたかを `"# fail 0" not in stdout` で見ていた。
# node の test reporter は **22 が `# fail 0` / 25 が `ℹ fail 0`** と書式が違うので、
# Node 25 の機械(edith)ではこの文字列が原理的に現れず、**全変異が「検出」になっていた**。
# 走って、exit 0 を返して、何も測っていない = この台本が防ごうとしている失敗そのもの。
# → 正は**終了コード**にし、要約行は両書式で読んで突き合わせる。読めない時は止める。
def as_list(v):
    """変異の的は1本でも複数でもよい。

    複数 = **冗長だと言い張っている守りを同時に外す**形(M103)。片方ずつ外しても
    他方が止めるので観測できず、その「単独では素通り」を冗長の証拠として
    使い回せてしまう。両方外して初めて、冗長という言い分そのものが測れる。
    """
    return v if isinstance(v, list) else [v]


UNIT_FAIL = re.compile(r"^[#ℹ]\s*fail\s+(\d+)\s*$", re.M)
E2E_FAIL = re.compile(r"fail=(\d+)")

def die(msg):
    sys.exit(f"★台本を止める: {msg}\n(緑を報告しない。測れていない事を隠すのが一番害が大きい)")

def die_unmeasured(msg):
    """**測れていない**事による停止。`die` と分けるのは終了コードが違うから。

    走行の最終行が `1 = 素通りが在る / 2 = 未測定 / 0 = 全部測れて穴なし` で返している以上、
    対照の段でも同じ区別を守る。1 で降りると呼び手には「欠陥が見つかった」と読める。
    """
    sys.stderr.write(f"★台本を止める(測れていない): {msg}\n")
    sys.stderr.write("(この赤は木の話ではない。緑にも赤にも丸めずに 2 で降りる)\n")
    sys.exit(2)

# ★「変異のせいで落ちた」と「検査が環境の都合で死んだ」を分ける印(2026-08-02 追加)。
#
# 動機は推測ではなく実測: `test/e2e-local.mjs` は以前 `8790 + random(0..99)` で port を
# 選んでいて、その範囲に**過去の走行が落とした孤児**(pid 45236 が 11時間33分 8861 を
# 掴んでいた)が居ると bind に失敗する。すると e2e は `server did not start` で throw し、
# 要約行が出ないまま exit≠0 になる → 下の `if m is None: return True` が**無言で「検出」**と
# 数える = **守れていない変異を守れたと報告する**。1/100 × 76 = 約53%で1件混ざる計算だった。
#
# port は 0(カーネル任せ)に変えて原因は塞いだが、**塞いだ事に依存しない**様にここでも見る。
# 原因側の直しだけだと、次に別の理由(fd 枯渇・実行系の入れ替え)で同じ嘘が復活した時に
# また無言になる。ここは**結果の側**の関門。
#
# ★合図に選ぶ語は慎重に。素朴に `EADDRINUSE` を見ると**この検査自身が正しく出す物**に当たる:
#   e2e の 13-b は二重起動を**故意に**起こして「読める一行が出るか」を測るし、M67 は
#   その一行を消す変異なので、落ちた時の詳細に `EADDRINUSE` が載る。それで止めたら
#   「変異を検出した」を「環境が死んだ」と誤って読む = 今度は逆向きの嘘になる。
#   `server did not start` も同じく両義的(変異でサーバが壊れても出る)。
#   よって e2e 側に**環境死の時にだけ**書く専用の合図を出させ、ここはそれだけを見る。
#
# ★2026-08-02、その専用の合図で**逆向きの嘘**を踏んだ。素朴に `RC-ENV-DEATH` を
#   stdout+stderr の全文から探していたが、e2e 側は合図を throw の文字列に埋めていた。
#   Node は未捕捉例外の報告に **throw 文の原文** を stderr へ写すので、環境死でない
#   落ち方(対照2 の canary = 正しい赤)でも原文経由で合図が現れ、78件の走行が
#   最初の対照で即死した。**検出器が自分の原文に一致していた**。
#   直しは両側:
#     e2e 側 = 合図を stdout の行頭に console.log で出す(原文に埋めない)。
#     ここ  = **stdout だけ**を、**行頭固定**で見る。原文の写しは stderr かつ字下げ付きなので
#             どちらの条件でも当たらない = 片方が崩れても二重で守る。
#   対照は `test/env-death-controls.sh`。**本物の bind 失敗**と**本物の canary クラッシュ**で
#   駆動する。手書きの文字列で試すと、私が想像した出力しか試せない(それで外した)。
ENV_DEATH = re.compile(r"^RC-ENV-DEATH", re.M)

# ★1つの変異を回している間に「要約が読めないまま落ちた」検査が溜まる場所(行8)。
#   本体側の for が変異ごとに空にする。要素は (検査名, 出力の写し)。
#
# ★2026-08-02 に写しを足した。それまでは名前だけを溜めて最後に「写しを読む事」と
#   印字していたが、**写しはどこにも保存していなかった**。実際 M43 がこの状態で出て、
#   指示どおり読もうとしても読む物が無かった(50 分の走行をやり直す以外に手が無い)。
#   人に次の一手を指図する出力は、その一手に要る物を自分で残しておく事。
NO_SUMMARY = []

def read_suite(p, label, rx):
    """落ちたか。**終了コードが正**。要約行は読めた時だけ突き合わせる。

    要約行が無い時の扱いを非対称にしてある:
      exit != 0 で要約が無い = 検査が途中で死んだ(= 赤)。変異で import が壊れれば普通に起きる。
      exit == 0 で要約が無い = **緑を名乗っているのに中身が読めない**。これが 8/1 に
      edith を盲にした形そのもの(Node 25 の `ℹ fail 0` を Node 22 の書式で見ていた)なので止める。
    """
    if ENV_DEATH.search(p.stdout):
        die(f"{label}: 検査が**環境の都合で**死んだ(port 衝突など)。\n"
            f"これを「変異を検出した」と数えると、守れていない物を守れたと報告する事になる。\n"
            f"--- stdout 末尾 ---\n" + "\n".join(p.stdout.splitlines()[-8:]) +
            f"\n--- stderr 末尾 ---\n" + "\n".join(p.stderr.splitlines()[-8:]))
    m = rx.search(p.stdout)
    rc_failed = p.returncode != 0
    if m is None:
        if rc_failed:
            # ★落ちた事は終了コードで確定しているが、**何件がどう落ちたかは読めていない**。
            #   ここを素の True で返していた間、「検査が変異を捕まえた」と「検査が起動段で
            #   死んだ」が同じ1つの数に畳まれていた = 台本が自分の成績を水増ししうる形。
            #   死因不明の赤も赤ではあるので判定は変えない。**内訳を残す**(行8)。
            NO_SUMMARY.append((label, f"$ exit={p.returncode}\n"
                                      f"--- stdout 末尾 ---\n" + "\n".join(p.stdout.splitlines()[-40:]) +
                                      f"\n--- stderr 末尾 ---\n" + "\n".join(p.stderr.splitlines()[-40:])))
            return True
        die(f"{label}: exit=0 なのに要約行が読めない(書式が想定外 = 緑を確認できていない)\n"
            f"--- stdout 末尾 ---\n" + "\n".join(p.stdout.splitlines()[-8:]) +
            f"\n--- stderr 末尾 ---\n" + "\n".join(p.stderr.splitlines()[-8:]))
    n = int(m.group(1))
    if (n > 0) != rc_failed:
        die(f"{label}: 要約 fail={n} と exit={p.returncode} が食い違う")
    return n > 0

# --- `--env-death <file>`: 環境死の判定**だけ**を外から駆動する口 ---------------
#
# 対照(test/env-death-controls.sh)がここを叩く。判定を対照側に書き写すと、
# 書き写した方だけが正しくても本体は間違ったまま緑になる。8/02 に踏んだのは
# まさにその形(手書きの文字列で対照を通し、本物の出力で外した)。
# 渡すのは **e2e の stdout そのもの**。read_suite が見る物と同じ物を見る。
if "--env-death" in sys.argv:
    _i = sys.argv.index("--env-death")
    if _i + 1 >= len(sys.argv):
        die("--env-death の後に file が無い")
    _t = open(sys.argv[_i + 1], encoding="utf-8", errors="replace").read()
    print("ENV-DEATH" if ENV_DEATH.search(_t) else "ok")
    sys.exit(0)

# --- `--only <語>`: 名前にその語を含む変異だけ回す ---------------------------
#
# 動機(2026-08-02): 守りを1つ足した直後に確かめたいのは**その1つ**なのに、全件は 30 分強かかる。
# 待てないと「あとで回す」になり、実際には回さない。
# ★対照2枚は絞っても必ず通す。件数を絞る事と「この台本が赤を見分けられる」証明を省く事は別。
# ★出力の頭に「全部ではない」と印字する。絞った回の緑を全件の緑と読み違えると、
#   この台本が防ごうとしている「測っていないのに緑」に自分で戻る。
ONLY = None
if "--only" in sys.argv:
    _i = sys.argv.index("--only")
    if _i + 1 >= len(sys.argv):
        die("--only の後に語が無い")
    ONLY = sys.argv[_i + 1]

# ★選び方は3通り。族(`R`)と番号(`R5`)を**題名の部分一致から分ける**(2026-08-02)。
#   きっかけ: `--only R` が題名に大文字 R を含むだけの M55/M67/M68/X6 まで拾い、
#   5件だけの筈の族の走行が9件・353 秒になった。害は時間だけではない —— 報告表に
#   選んでいない族が混ざるので、「R 族を測った」と「たまたま一緒に回った」が区別できない。
#   計器は**何を選んだのか**を曖昧にしてはいけない。
# ★ここで選ぶ(対照2枚より**前**)理由: 語を打ち間違えた時の die が、対照2枚の
#   約2分を払った後ではなく即座に出る。fail-closed は早い方が良い。
def _select(word):
    if re.fullmatch(rf"[{FAM}]", word):                     # 族まるごと
        return [m for m in MUT if m[0].startswith(word) and m[0][1:2].isdigit()], f"族 {word}"
    if re.fullmatch(rf"[{FAM}]\d+[a-z]?", word):             # 番号ちょうど1件(`P12b` も1件)
        return [m for m in MUT if re.match(rf"{word}(?=[ (])", m[0])], f"番号 {word}"
    return [m for m in MUT if word in m[0]], f"題名に「{word}」を含む"

# ★カンマ区切りで複数選べる(2026-08-03)。きっかけ: §3-V の変異 W19-W23 が題名に共通語を
#   持たず、5回に分けると対照2枚の約2分を5回払う上、報告が5枚に割れて「§3-V を1回で測った」
#   と読めなくなる。選択の意味は1語の時と同じ(族/番号/部分一致)で、和を取るだけ。
#   順序は MUT の並び順に戻す —— 打った順で並べると、報告の並びが打鍵の癖に依存する。
def _select_many(word):
    if "," not in word:
        return _select(word)
    picked, hows = [], []
    for w in [x.strip() for x in word.split(",") if x.strip()]:
        got, how = _select(w)
        if not got:
            die(f"--only の「{w}」に当たる変異が無い(名前を確かめる)")
        hows.append(how)
        picked.extend(got)
    seen, uniq = set(), []
    for m in MUT:
        if id(m) in {id(x) for x in picked} and id(m) not in seen:
            seen.add(id(m))
            uniq.append(m)
    return uniq, " + ".join(hows)

if ONLY is None:
    MUT_RUN = MUT
else:
    MUT_RUN, _how = _select_many(ONLY)
    if not MUT_RUN:
        die(f"--only {ONLY} に当たる変異が無い(名前を確かめる)")
    print(f"★--only {ONLY}({_how}): {len(MUT_RUN)}/{len(MUT)} 件だけ回す = **全件の緑ではない**\n")

# --- `--dry`: 変異の**的**が今のコードに当たるかだけを数秒で見る ---------------
#
# 動機(2026-08-02): M54 が狙っていた `retry: false` は、その日のうちに死に field として
# 削除されていた。台本は 30 分走った末に「対象行が無い」と言う。**当たらない的は、
# 走らせる前に分かる**。コードを直した直後にここだけ回せば、台本の腐りが即座に出る。
# ★これは変異検査そのものではない(守りが効くかは何も測らない)。的の生死だけ。
# ★`--only` の**後ろ**に置いてある(2026-08-02)。前に在った時は `--dry --only R` が
#   黙って全件を照合していた —— 絞ったつもりの確認が絞られていない、が起きる場所。
#   ついでに `--dry --only <語>` が**選択そのものを秒で確かめる手段**になる。
if "--dry" in sys.argv:
    bad = 0
    for m in MUT_RUN:
        name, f = m[0], m[1]
        text = open(os.path.join(SRC, f)).read()
        ns = [text.count(o) for o in as_list(m[2])]
        if any(n != 1 for n in ns):
            bad += 1
            print(f"NG({','.join(map(str, ns))}件) {name}\n      <- {f}")
    print(f"的の照合: {len(MUT_RUN)}件 / 当たらない {bad}件")
    sys.exit(1 if bad else 0)

# ── 子は「群」ごと始末する(2026-08-02 追加)─────────────────────────────────
#
# なぜ要るか(実際に起きた事): この台本は変異1件ごとに `npm test` と
# `node test/e2e-local.mjs` を起こす。e2e は**ポートを掴むサーバ**を上げるので、
# 子が生き残るとそのポートを掴んだ孤児が残る。実測でその形は既に起きていて —
# **pid 45236 が port 8861 を 11時間33分 保持**していた — 後続の走行でサーバが上がらず
# → 要約行が出ず → 終了コードだけ見て**「変異を検出した」と数える**、という
# 「守れていない物を守れたと報告する」経路になっていた(DESIGN §2.18-10、表の①)。
#
# ★`subprocess.run` は**親が死んでも子を殺さない**。しかも本体は `npm` の**孫**の node
#   なので、直の子だけ殺しても足りない。だから
#     (a) `start_new_session=True` で子を独立した**群**にする
#     (b) 1件終わるごとに群ごと SIGKILL = 取りこぼした孫をその場で落とす(孤児の予防)
#     (c) SIGTERM/SIGINT/SIGHUP を受けたら群を全部落としてから降りる(中断時の予防)
#   (b) が本命。(c) だけだと `kill -9` された時に何も走らない。
#
# ★群 ID の再利用について正直に書く: (b) の killpg は `communicate()` が直の子を
#   wait した**直後**に撃つので、理屈の上では「その pid が別プロセスに再利用された後に
#   撃つ」窓が存在する。窓は Python のバイトコード数命令分で、そこへ当てるには OS が
#   pid 空間をほぼ一周させる必要がある。実用上は無視できるが、**無いとは書かない**。
_CHILD_PGIDS = set()

# 実測: `npm test` 約0.7秒 / e2e 約35秒。600秒 = 17倍の余裕。
# ★これは「遅かったら赤」の閾値ではなく**無限に待たない為の上限**。
#   ここに引っ掛かったら測定は失敗であって「検出」ではない。
#
# ★2026-08-04 の是正: 引っ掛かった時に**必ず die する**形だった。理由は正しかった
#   (時間切れを「検出」に丸めるのは成績の水増し)が、結論が行き過ぎていた ——
#   **変異1件の測定失敗で、走行 157 件が全部落ちる**。実際に M111 で起きた。
#   M111 は「上限超えを断る」を「古い待ちを外す」へ変える変異で、外された待ちの
#   約束が永久に未解決になる = e2e の HTTP 要求が永遠に返らない。つまり**この変異が
#   撃っている欠陥そのものの症状として**脚が固まる。それで台本ごと止まるなら、
#   固まる系の欠陥を撃つ変異は1つも置けなくなる。
#
#   分けたのは**処分**であって閾値ではない(数は1つのまま = 増やすと必ず drift する):
#     - 対照の脚(無変異 / 故意に壊した木)で時間切れ → **die**。台本が自分の赤を
#       見分けられる事の証明が取れていないので、以降の判定に意味が無い。
#     - 変異の脚で時間切れ → その脚は **未測定**。緑にも赤にも丸めず、行にそう書き、
#       走行は続ける。素通りが1件も無くても未測定が在れば終了コードは **2**。
#   「未測定を緑に丸めない」は守ったまま、「未測定を赤(検出)にも丸めない」を足した。
CHILD_TIMEOUT_S = 600

# 変異の脚で時間切れになった記録。変異1件ごとに clear する(NO_SUMMARY と同じ作法)。
TIMED_OUT = []

def _reap_children(grace=1.0):
    if not _CHILD_PGIDS:
        return
    for pgid in list(_CHILD_PGIDS):
        try:
            os.killpg(pgid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
    time.sleep(grace)
    for pgid in list(_CHILD_PGIDS):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    _CHILD_PGIDS.clear()

atexit.register(_reap_children)

def _on_signal(signum, _frame):
    # ★まず子を落とす。その後 sys.exit で降りる = **atexit が走る**ので、
    #   作業コピー(mkdtemp)の片付けも一緒に効く。既定の始末に戻して撃ち直すと
    #   atexit が走らず、178MB の残骸を作った 8/02 未明の形に戻る。
    _reap_children()
    sys.exit(128 + signum)

for _sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(_sig, _on_signal)

def run_child(cmd, cwd, label, timeout_fatal=True, timeout_s=None):
    # timeout_s は**対照の口だけ**が渡す(下の `--selftest-timeout`)。走行は既定のまま。
    # env で上書きできる形にしなかったのは、低い値が real な走行に残ると偽の未測定が
    # 出るから —— 差し替え口は在るが、走行の経路からは触れない。
    timeout_s = CHILD_TIMEOUT_S if timeout_s is None else timeout_s
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         stdin=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        pgid = os.getpgid(p.pid)
    except ProcessLookupError:
        pgid = p.pid            # 即死した = 群 ID は pid と同じ(start_new_session の性質)
    _CHILD_PGIDS.add(pgid)
    timed_out = False
    try:
        out, err = p.communicate(timeout=timeout_s)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        out, err = p.communicate()
    finally:
        try:
            os.killpg(pgid, signal.SIGKILL)   # ★孫の取りこぼしをここで必ず落とす
        except (ProcessLookupError, PermissionError):
            pass
        _CHILD_PGIDS.discard(pgid)
    if timed_out:
        msg = (f"{label}: {timeout_s} 秒を超えた(実測は 0.7〜52 秒。e2e は 2026-08-03 に\n"
               f"割り込みの予算を 4000ms へ戻した分だけ伸びた = 35→52 秒)。\n"
               f"これは**測定の失敗**であって「変異を検出した」ではない。\n"
               f"--- stdout 末尾 ---\n" + "\n".join(out.splitlines()[-8:]) +
               f"\n--- stderr 末尾 ---\n" + "\n".join(err.splitlines()[-8:]))
        if timeout_fatal:
            die(msg + "\n(対照の脚なので、ここで止める。台本が赤を見分けられる証明が無い)")
        TIMED_OUT.append((label, msg))
        return None      # ★「測れていない」を**型で**表す。read_suite に渡さない
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)

def suites(dst, timeout_fatal=True, sink=None):
    """(単体, e2e) を返す。各要素は True=落ちた / False=緑 / **None=測れていない**。

    sink: 渡すと生の出力を `(脚名, stdout+stderr)` で溜める。**対照2枚だけ**が渡す。
    変異 197 件ぶんの生出力を抱えると数百 MB になるので、既定では捨てる。
    対照は 2 回しか走らないので、そこだけ全部持つ。
    """
    u = run_child(["npm", "test", "--silent"], dst, "単体", timeout_fatal)
    e = run_child(["node", "test/e2e-local.mjs"], dst, "e2e", timeout_fatal)
    if sink is not None:
        for lbl, r in (("単体", u), ("e2e", e)):
            if r is not None:
                sink.append((lbl, r.stdout + r.stderr))
    return (None if u is None else read_suite(u, "単体", UNIT_FAIL),
            None if e is None else read_suite(e, "e2e", E2E_FAIL))

def verdict_of(ufail, efail, why, blind_here):
    """変異1件の判定。ufail/efail は True/False/**None(未測定)**。

    順序が全て。**赤が先、未測定が次、緑は最後**:
      - 脚が1本でも赤 → 検出(他方が固まっていても、捕まえた事実は動かない)
      - 赤が無く未測定が在る → **未測定**。素通り(検査の穴)と区別が付いていないので、
        どちらにも丸めない。ここを「素通り」に倒すと嘘の穴を報告し、「検出」に倒すと
        守れていない物を守れたと報告する。両方とも過去に踏んだ形。
      - 全部緑 → 素通り(注記つきなら未到達)
    """
    if ufail is True or efail is True:
        return "★注記を外せる" if why else ("検出(要約なしで落ちた)" if blind_here else "検出")
    if ufail is None or efail is None:
        return "★未測定(時間切れ)"
    return "未到達(注記)" if why else "★素通り"

def leg_text(fail, name):
    return f"{name}未測定" if fail is None else (f"{name}落ちる" if fail else f"{name}通る")

# --- `--verdict <u> <e> [why]`: 上の判定表**だけ**を外から駆動する口 -----------------
# 対照(test/mutation-verdict-controls.sh)がここを叩く。`--env-death` と同じ作法で、
# 判定を対照側に書き写さない(写した方だけ正しくて本体は間違ったまま緑、を避ける)。
# 引数は `t`/`f`/`u` (= True/False/None)。
if "--verdict" in sys.argv:
    _i = sys.argv.index("--verdict")
    _a = sys.argv[_i + 1:]
    if len(_a) < 2:
        die("--verdict の後に <u> <e> が要る(t|f|u)")
    _m = {"t": True, "f": False, "u": None}
    if _a[0] not in _m or _a[1] not in _m:
        die(f"--verdict の引数は t|f|u のみ: {_a[:2]}")
    _why = _a[2] if len(_a) > 2 and _a[2] not in ("", "-") else None
    print(verdict_of(_m[_a[0]], _m[_a[1]], _why, []))
    sys.exit(0)

# --- 対照2枚の判定 -----------------------------------------------------------
#
# 変異の脚(verdict_of)と分けて書く理由: **同じ赤が別の意味を持つ**から。
# 変異の脚では「要約行の無い赤」は正当で有り触れている(変異が import を壊せばそうなる)。
# 対照1の木は**変異していない**ので、同じ形が正当ではなくなる。
#
#   要約行(`# fail N`)の在る赤 = 検査が本当に落ちた   = 作業ツリーが赤
#   要約行の無い赤             = 結果を出す前に子が死んだ = 混み合い / メモリ / kill / 環境死
#
# ここを畳んでいた間、後者を「まず作業ツリーを緑にする事」と診断していた。
# 手元で `npm test` を回すと緑なので、指示どおり動いた人は行き止まりに着く(進捗の記録に
# この症状が残っている)。**次の一手を指図する出力は、その一手が当たる事まで責任を持つ**。
def blind_labels(no_summary):
    """要約行を出さないまま落ちた脚の名前。`read_suite` が溜めた物から採る**唯一の道**。

    小さくても関数にするのは、対照(test/mutation-timeout-controls.sh)が
    ここを叩けるようにするため。呼び出し側に書き写すと、read_suite が入れる名前と
    読み手が探す名前が食い違った時に**誰も気付かない**(= 死んだ子が今まで通り
    「作業ツリーが赤」に化けるが、対照は判定表だけ見て緑を出す)。
    """
    return {lbl for lbl, _ in no_summary}

def canary_seen(sink):
    """仕込んだ合言葉が**両脚**の出力に在るか。片脚でも欠ければ False。

    ★配線が壊れた時(suite が sink を埋め忘れる等)は False に倒れる = 対照2が止まる。
      黙って緑になる向きには壊れない。
    """
    return len(sink) == 2 and all("canary" in t for _, t in sink)

def _tail(sink, want, n=40):
    """sink に溜めた生出力から、名前が want に在る脚の末尾だけを取り出す。"""
    return "\n".join(f"--- {lbl} の出力末尾 ---\n" + "\n".join(t.splitlines()[-n:])
                     for lbl, t in sink if lbl in want)

def _failing(sink, want, n=30):
    """**落ちた行だけ**を拾う。末尾ではない。

    ★書いた其の日にこれが要ると分かった(2026-08-09)。対照1が木の赤を報せた時、
      末尾40行を印字していたが —— 落ちた検査は列の**途中**に在り、その後ろに
      PASS が何十行も続く。受け取った人が見るのは PASS の壁で、**どの検査が落ちたかは
      1つも書いていない**。「作業ツリーを緑にする事」と言いながら、緑にする対象を伏せていた。
      未測定の側を直したのと同じ欠陥が、赤の側にも在ったという事。
    拾い方は各脚の書式に従う: 単体(TAP)= `not ok`、e2e = `FAIL`。要約行も足す。
    印が1つも無いのに落ちている = 書式が変わった合図なので、その時だけ末尾へ落とす。
    """
    marks = ("not ok ", "FAIL")
    out = []
    for lbl, t in sink:
        if lbl not in want:
            continue
        lines = t.splitlines()
        cases = [ln for ln in lines if ln.startswith(marks)]
        summary = [ln for ln in lines if ln.startswith("# fail ") or "fail=" in ln]
        if cases:
            out.append(f"--- {lbl} の落ちた行({len(cases)}件)---\n"
                       + "\n".join(cases[:n] + summary[-1:]))
        else:
            # ★要約だけ在って名前が無い、も「読めない」側に入れる。件数だけ渡されても
            #   受け取った人は次の一手を打てない —— それが此の節で直している欠陥そのもの。
            out.append(f"--- {lbl}: 落ちた検査の名前が1つも読めない(書式が変わった?)。末尾を出す ---\n"
                       + "\n".join(summary[-1:] + lines[-n:]))
    return "\n".join(out)

def control1_verdict(ufail, efail, blind):
    """無変異の木の判定。blind = **要約行を出さずに**落ちた脚の名前の集合。

    返す語: ok / tree-red / unmeasured。
    赤が両種混じった時は tree-red が勝つ —— 本物の赤が1本でも在れば、それが診断。
    """
    legs = (("単体", ufail), ("e2e", efail))
    if any(f is True and n not in blind for n, f in legs):
        return "tree-red"
    if any(f is True for n, f in legs):
        return "unmeasured"          # 赤は在るが全部「死因不明」= 木の話ではない
    if any(f is None for _, f in legs):
        return "unmeasured"          # 時間切れ(対照の脚では run_child が先に止めるが、口では在りうる)
    return "ok"

def control2_verdict(ufail, efail, canary_seen):
    """故意に壊した木の判定。canary_seen = 仕込んだ合言葉が出力に在ったか。

    ★赤が出た事だけでは足りない。混み合いで死んだ子も赤なので、**仕込んだ物が
      効いて赤い**事まで言えないと、この対照は「何かが赤くなった」しか測っていない。
      変異の脚に 5 番目の引数(どの検査が倒れるはず)を足したのと同じ作法。
    ここでは逆に **要約行の有無は問わない** —— e2e は起動段で落ちるので要約行は出ない。
    それが期待どおりの形。対照1と対照2で見る物が違うのは、赤の意味が違うから。
    """
    if not (ufail and efail):
        return "not-red"
    if not canary_seen:
        return "red-without-canary"
    return "ok"

# --- `--control-verdict <1|2> <u> <e> <blind> [canary]`: 上の2つを外から駆動する口 ---
# 作法は `--env-death` / `--verdict` と同じ。対照(test/mutation-timeout-controls.sh)は
# 判定を書き写さず、ここを叩く。<blind> は `単体` / `e2e` の comma 列、無ければ `-`。
if "--control-verdict" in sys.argv:
    _i = sys.argv.index("--control-verdict")
    _a = sys.argv[_i + 1:]
    if len(_a) < 4:
        die("--control-verdict の後に <1|2> <u> <e> <blind> [canary] が要る")
    _m = {"t": True, "f": False, "u": None}
    if _a[0] not in ("1", "2") or _a[1] not in _m or _a[2] not in _m:
        die(f"--control-verdict の引数が不正: {_a[:4]}")
    _blind = set() if _a[3] in ("-", "") else set(_a[3].split(","))
    if _a[0] == "1":
        print(control1_verdict(_m[_a[1]], _m[_a[2]], _blind))
    else:
        print(control2_verdict(_m[_a[1]], _m[_a[2]],
                               len(_a) > 4 and _a[4] == "y"))
    sys.exit(0)

# --- `--selftest-control <blind|summary|canary|sink-empty>`: 対照の**配線**を駆動する口 ---
#
# ★`--control-verdict` だけでは足りない。判定表が正しくても、**入力の作り方**が
#   食い違っていれば対照は今まで通り誤診する。実際に直したのはそこ:
#   `read_suite` が NO_SUMMARY へ入れる脚の名前と、判定が探す名前が一致して初めて
#   「要約行の無い赤」が拾える。ここを写しで通すと、その一致を誰も測らない。
# 偽の子を作るので秒で済む(検査一式は回さない)。
if "--selftest-control" in sys.argv:
    _i = sys.argv.index("--selftest-control")
    _a = sys.argv[_i + 1:]
    if not _a or _a[0] not in ("blind", "summary", "canary", "sink-empty",
                               "die-unmeasured", "fail-lines", "fail-lines-unknown"):
        die("--selftest-control <blind|summary|canary|sink-empty|die-unmeasured|"
            "fail-lines|fail-lines-unknown>")
    if _a[0].startswith("fail-lines"):
        # 落ちた行が**列の途中**に在り、その後ろを PASS が埋める形を作る。
        # 末尾を印字する実装ならここで落ちた検査の名前が出ない = 対照が赤くなる。
        _known = _a[0] == "fail-lines"
        _mid = "FAIL  ★狙いの検査" if _known else "こけた(印の無い書式)"
        _txt = ("\n".join(f"PASS  前の検査{i}" for i in range(50)) + "\n" + _mid + "\n"
                + "\n".join(f"PASS  後ろの検査{i}" for i in range(50)) + "\nE2E: pass=100 fail=1\n")
        _o = _failing([("e2e", _txt)], {"e2e"})
        print("狙いが出る" if "★狙いの検査" in _o else
              ("書式が変わったと言う" if "名前が1つも読めない" in _o else "出ない"))
        sys.exit(0)
    if _a[0] == "die-unmeasured":
        # 終了コードの取り決め(1=素通りが在る / 2=未測定)を**現物で**見せる口。
        die_unmeasured("配線の確認(この文は対照が読む)")
    if _a[0] in ("blind", "summary"):
        # 落ちた脚を1本ぶん**本物の read_suite に通す**。要約行の有無だけを変える。
        _out = "落ちた形跡はあるが要約行が無い\n" if _a[0] == "blind" else "# fail 1\n"
        NO_SUMMARY.clear()
        _u = read_suite(subprocess.CompletedProcess(["x"], 1, _out, ""), "単体", UNIT_FAIL)
        print(control1_verdict(_u, False, blind_labels(NO_SUMMARY)))
    else:
        _sink = ([] if _a[0] == "sink-empty"
                 else [("単体", "Error: canary\n"), ("e2e", "Error: canary\n")])
        print(control2_verdict(True, True, canary_seen(_sink)))
    sys.exit(0)

# --- `--selftest-timeout <fatal|soft> <秒> <hang|fast>`: **配線**を駆動する口 ---------
#
# ★上の `--verdict` だけでは足りない。判定表が全部正しくても `run_child` が今まで通り
#   die していたら、変異の脚は verdict_of へ **辿り着かない**。「写した方だけ正しくて
#   本体は間違ったまま緑」を避けるのがこの file の作法なので、配線そのものを本物の
#   `run_child` で回す(偽の脚 = `sleep`。検査一式を回さないので数秒で済む)。
if "--selftest-timeout" in sys.argv:
    _i = sys.argv.index("--selftest-timeout")
    _a = sys.argv[_i + 1:]
    if len(_a) < 3 or _a[0] not in ("fatal", "soft") or _a[2] not in ("hang", "fast"):
        die("--selftest-timeout <fatal|soft> <秒> <hang|fast>")
    _cmd = ["/bin/sh", "-c", "sleep 999" if _a[2] == "hang" else "exit 0"]
    TIMED_OUT.clear()
    _r = run_child(_cmd, SRC, "偽の脚", timeout_fatal=(_a[0] == "fatal"), timeout_s=float(_a[1]))
    # fatal + hang はここへ来ない(die 済み)。来たら**それ自体が外れ**なので言う。
    if _r is None:
        print(f"未測定 timed_out={len(TIMED_OUT)}")
    else:
        print(f"測れた rc={_r.returncode} timed_out={len(TIMED_OUT)}")
    sys.exit(0)

# ── 走行の**所有印**(lock/pid file)を立てる ─────────────────────────────────
#
# 何を直しているか(2026-08-04、DESIGN §2.38 の「まだ直っていない根」):
#   「今この機械で変異走行が動いているか」は今まで `pgrep -f <正規表現>` の**推定**だった。
#   argv 全体への文字列一致なので両方向に外れ、両方向とも実害を出している:
#     - 偽陽性(8/02): 台本名を変数に持つだけの無関係な shell に当たり、配備が**恒久的に**塞がった
#     - 偽陰性(8/02 夜): `python3 -u <台本>` の `-u` を正規表現が跨げず、走行中に**2本目**を
#       起こした(2本が同じ log へ書いて混ざった)。配備の門も同じ判定なので黙って開いていた
#   どちらも「その字が誰かのコマンド行に在るか」を訊いているから起きる。訊くべきは
#   **「走行が自分で立てた印の主が、今も生きているか」** —— 推定ではなく観測である。
#
# 置き場所がこの行である理由は2つ、どちらも実測に基づく:
#   - **これより上に置かない**: `--dry` / `--verdict` / `--env-death` / `--selftest-timeout` は
#     木も触らず子も起こさない。上で印を立てると、pre-commit の `--dry` が走る間ずっと
#     配備の門が塞がる(`tools/check-mutation-targets.sh` は毎コミット `--dry` を叩く)。
#   - **これより下に置かない**: すぐ下の凍結は木まるごとの copytree で秒を食う。その後に
#     立てると「走っているのに印が無い」窓がその秒数だけ開く = 2本目を起こせてしまう。
MUTATION_LOCK = os.environ.get("RC_MUTATION_LOCK", "/tmp/rc-backend-mutation-run.lock")


def _proc_started(pid):
    """pid の起動時刻を1行で返す(居なければ空文字)。

    ★pid だけでは足りない。印を残したまま SIGKILL された走行の pid が別のプロセスへ
      再利用されると、`kill -0` は「生きている」と答える —— それは配備が二度と通らない
      形であり、8/02 に pgrep 版で実際に起きた恒久的な詰まりと**同じ壊れ方**である。
      起動時刻まで一致して初めて「同じプロセス」と言える。
    ★読み手(`tools/mutation-run-live.sh`)と**同じ道具**(`ps -o lstart=`)で採る事。
      書き手と読み手で採り方が違うと、書式の食い違いが「主が居ない」に化ける。
    ★`TZ` と `LC_ALL` を固定する(2026-08-04、Codex 指摘 #4)。`lstart` は**呼び手の
      時間帯と locale で描かれる**ので、書き手と読み手の環境が違うと —— たとえば片方が
      launchd 由来で `TZ` を持たず、片方が shell から走る —— **同じプロセスが違う文字列に
      なる**。読み手はそれを「pid の再利用」と読んで exit 1 を返し、走行中に門が**開く**。
      印は環境を跨いで読まれる file なので、書かれる値は環境に依らない形でなければならない。
    """
    env = dict(os.environ, TZ="UTC", LC_ALL="C")
    r = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)],
                       capture_output=True, text=True, env=env)
    return r.stdout.strip() if r.returncode == 0 else ""


def _read_run_lock(path):
    """印を dict で返す。無い・読めない・欠けている = None(= 主を確かめられない)。"""
    try:
        with open(path, encoding="utf-8") as f:
            txt = f.read()
    except OSError:
        return None
    d = {}
    for line in txt.splitlines():
        k, sep, v = line.partition("=")
        if sep:
            d[k.strip()] = v.strip()
    if not d.get("pid", "").isdigit() or not d.get("started"):
        return None
    return d


def _live_lock_owner(path):
    """印の主が**今も生きている**なら dict、そうでなければ None(古い印も None)。"""
    d = _read_run_lock(path)
    if d is None:
        return None
    now = _proc_started(int(d["pid"]))
    return d if now and now == d["started"] else None


def _held_msg(d):
    return (f"変異走行が既に動いている(pid={d['pid']}, 木={d.get('root', '?')})。\n"
            f"  2本が同時に走ると囮と log が混ざる(2026-08-02 に実測)。\n"
            f"  何が掴んでいるか: bash tools/mutation-run-live.sh --who\n"
            f"  主が死んで印だけ残っている場合は、古い印として退けてから走る")


def _steal_stale_lock():
    """古い印を退ける。**退ける側どうしを一列にする**のが肝。

    ★2026-08-04、対照(8本同時出発)が実測で捕まえた。`os.link` は原子的なのに
      **3本が同時に走り出した**。原子的なのは「立てる」だけで、その手前の「退ける」が
      競っていたから:

        B が「古い印だ」と確かめる
        C も「古い印だ」と確かめる
        C が unlink して link  ← C が主になる
        B が unlink            ← ★**C の生きた印**を消している
        B が link              ← B も主になる = 2本走る

      退ける操作だけを O_EXCL の門で一列にすると消える。門を持っている間、印は
      「古いと確かめた、まさにその file」のままである —— 印が在る限り誰も link できず、
      新しい主が現れる余地が無いから。門を取れなかった側は待ってから取り直す(門は
      1ミリ秒級でしか握られない)。待っても空かない = 退ける途中で落ちた走行が在る、
      という別の事象なので、そう名指しで言って**走らない**。
    """
    guard = f"{MUTATION_LOCK}.steal"
    fd = None
    for _ in range(200):        # 最大 ~2 秒
        try:
            fd = os.open(guard, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
            break
        except FileExistsError:
            time.sleep(0.01)
        except OSError as e:
            die(f"古い印を退ける門を作れない({guard}): {e}")
    if fd is None:
        die(f"古い印を退ける門が塞がったままである({guard})。\n"
            f"  退ける途中で落ちた走行が在る。手で消す: rm {guard}")
    try:
        os.write(fd, f"pid={os.getpid()}\n".encode())
    except OSError:
        pass
    finally:
        os.close(fd)
    try:
        # 門の中で**もう一度**確かめる。門の外で見た「古い」は、待っている間に
        # 別の主へ入れ替わっている事が在る(それが上の B/C の筋書きそのもの)。
        if _live_lock_owner(MUTATION_LOCK) is None:
            try:
                os.unlink(MUTATION_LOCK)
            except FileNotFoundError:
                pass            # 先に退けた者が居る。取り合いは link で決まる
            except OSError as e:
                die(f"古い印を消せない({MUTATION_LOCK}): {e}")
    finally:
        try:
            os.unlink(guard)
        except OSError:
            pass


def _take_run_lock():
    """印を**原子的に**立てる。既に在る印は、主が死んでいる時だけ退ける。

    ★`os.replace` で上書きするだけでは足りない(2026-08-04、自己指摘)。
      上の `_live_lock_owner()` が「古い印だ」と答えてから書き込むまでの間に、別の走行が
      同じ判断を下し得る —— 2本とも「自分が主だ」と思って進む。相互排他を名乗りながら、
      稀に2本走る形で、**8/02 の偽陰性と結果が同じ**(log と囮が混ざる)。
      `os.link` は宛先が在れば EEXIST で**失敗する** = 勝者が機械的に1本へ決まる。

    ★退ける道が要る理由: 退けないと、SIGKILL された走行が残した印で**以後の全走行が
      永久に止まる**。それは 8/02 の「配備が恒久的に塞がる」を、門ではなく走行側で
      作り直す事になる。「原子的に取る」と「古い印を退ける」は両方要り、退ける前に
      毎回**主の生死を確かめる**のがその安全弁。
    """
    started = _proc_started(os.getpid())
    if not started:
        die("自分の起動時刻(ps)が読めない = 印の主を後から確かめる手段が無い。走らない")
    tmp = f"{MUTATION_LOCK}.tmp.{os.getpid()}"
    try:
        parent = os.path.dirname(MUTATION_LOCK)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(f"pid={os.getpid()}\nstarted={started}\nroot={SRC}\n")
    except OSError as e:
        die(f"走行の印を書けない({MUTATION_LOCK}): {e}")
    try:
        # 3 周まで。古い印を退けては取りに行く。多数が同時に出発すると、退けた直後の
        # 一瞬を別の1本に取られる事が在り、その時は次の周で「相手が生きている」を見て
        # 正しく死ぬ。周回を使い切っても取れない = 退けられない事情が在る。走らない。
        for attempt in (1, 2, 3):
            try:
                # ★中途半端な姿を読み手に見せない。書き終えた file を link で**現れさせる**。
                os.link(tmp, MUTATION_LOCK)
                return
            except FileExistsError:
                held = _live_lock_owner(MUTATION_LOCK)
                if held is not None:
                    die(_held_msg(held))
                if attempt == 3:
                    die(f"古い印を退けられない({MUTATION_LOCK})。手で消してから走らせる事")
                _steal_stale_lock()
            except OSError as e:
                die(f"走行の印を立てられない({MUTATION_LOCK}): {e}")
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _drop_run_lock():
    # ★先に子を落としてから印を降ろす。順序が逆だと、子がまだ死んでいる最中に配備の門が
    #   開く。atexit は登録の逆順に走るので、明示的に呼ぶのが順序を決める唯一の手
    #   (`_reap_children` は `_CHILD_PGIDS` を空にするので、後から走る登録は素通りする)。
    _reap_children()
    # ★自分の印**だけ**を消す。他人の印を消すと、その走行の最中に門が開く。
    d = _read_run_lock(MUTATION_LOCK)
    if d is None or d.get("pid") != str(os.getpid()):
        return
    try:
        os.unlink(MUTATION_LOCK)
    except OSError:
        pass


# ★2本を同時に走らせない。8/02 に実際に起きた形 = 2本が同じ log へ tee して混ざり、
#   片方の対照がもう片方の囮を見て赤くなった。今までこれを止めていたのは私の記憶だけで、
#   機械は何も見ていなかった。判定は `_take_run_lock()` の**1箇所だけ**が下す。
#
#   以前は此処に「速い普通の道」として同じ判定の写しを置いていた(`_HELD`)。8/04 の変異で
#   **緑のまま生き残った** = 壊しても振舞いが変わらない。取得が原子的になった時点で、
#   生きた主を見つけて死ぬ役目は `os.link` の EEXIST 側へ完全に移っていたからである。
#   同じ問いに答える場所が2つ在ると、片方だけ直して片方が腐る —— `tools/mutation-run-live.sh`
#   の頭に書いた、判定を1箇所へ集めた理由そのものなので、写しの方を畳んだ。
_take_run_lock()
atexit.register(_drop_run_lock)
print(f"走行の印を立てた: {MUTATION_LOCK}(pid={os.getpid()})", flush=True)

# --- `--lock-selftest`: 印の**書き手と読み手が噛み合う事**を外から駆動する口 ---------
#
# `--verdict` / `--env-death` と同じ作法。此処に置いてあるのが肝で、上の `_take_run_lock()`
# = **本走行が使うのと同じ呼び出し**を経てから止まる。対照が印を手で書く形にすると、
# 書式が食い違った日に対照だけが緑のまま残る —— この repo が何度も踏んだ「写しを撃つ
# 対照」そのものになる。
if "--lock-selftest" in sys.argv:
    print(f"LOCKED {MUTATION_LOCK} {os.getpid()}", flush=True)
    time.sleep(float(os.environ.get("RC_LOCK_SELFTEST_S", "30")))
    sys.exit(0)

# 作業コピーは中断路(die / 対象行が無くて continue)でも必ず消す。
# 木まるごとのコピーなので、放置すると /var/folders に何本も残る(実際に残っていた)。
LIVE = []
atexit.register(lambda: [shutil.rmtree(d, ignore_errors=True) for d in LIVE])

# ── 走る前に木を**凍らせる**(2026-08-03 に実際に壊れた形の是正)────────────────
#
# 何が起きたか: 197 件の走行は 3 時間半かかる。その間に私は同じ repo の `tools/` を
# 10 回書き換えた。`copy_tree()` は変異1件ごとに**その時の** SRC を写していたので、
# 走行の前半と後半で違う木を測っていた。しかも書き換えの1つが repo 自身の散文規則
# (注釈が repo 外の file を行番号つきで引かない)に触れて `npm test` を赤にしたので、
# **それ以降の変異は全部「検出」と記録された** —— 変異を殺したからではなく、
# 変異と無関係な検査が落ちていたから。素通り(= 検査の穴)が丸ごと隠れる。
#
# ここが厄介なのは、壊れ方が**緑の方向**に出る事。要約は「素通り 0 件」と書く。
# 走行の log を見ても、進捗行は同じ形のまま並んでいて、境目が見えない。
#
# 是正は2つ:
#   (a) 開始時に一度だけ写して**凍結**し、以後の変異はその凍結から写す。
#       = 走行中に手元を編集しても測定は汚れない(編集を禁じるのは非現実的)。
#   (b) 終了時に手元の木が動いたかを見て、動いていたら**報告が何を説明する物か**を明示する。
#       凍結してあるので結果は有効だが、それは「開始時の木」の話であって
#       「今の木」の話ではない。ここを黙ると、読んだ人が今の木の緑として持ち帰る。
#
# ★指紋(hash)ではなく**変わった file 名**を出す。hash は「何かが動いた」しか言わない。
#   名前が出れば、それが測定に効く変更かを人がその場で判断できる。
_SCOPE = ("src", "test", "tools", "package.json")

def _manifest(root):
    """`_SCOPE` の下の全 file を (相対path -> (大きさ, mtime_ns)) で数え上げる。"""
    man = {}
    for s in _SCOPE:
        p = os.path.join(root, s)
        if os.path.isfile(p):
            st = os.stat(p)
            man[s] = (st.st_size, st.st_mtime_ns)
            continue
        for dirpath, dirnames, filenames in os.walk(p):
            dirnames[:] = [d for d in dirnames if d not in ("node_modules", ".git")]
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                st = os.stat(full)
                man[os.path.relpath(full, root)] = (st.st_size, st.st_mtime_ns)
    return man

START_MANIFEST = _manifest(SRC)

_FROZEN_HOLDER = tempfile.mkdtemp(prefix="mut-frozen-")
atexit.register(lambda: shutil.rmtree(_FROZEN_HOLDER, ignore_errors=True))
FROZEN = os.path.join(_FROZEN_HOLDER, "rc")
shutil.copytree(SRC, FROZEN, ignore=shutil.ignore_patterns("node_modules", ".git"))
print(f"木を凍結した({len(START_MANIFEST)} file)。以降の変異はこの写しから作る"
      f" —— 走行中に手元を編集しても測定は汚れない\n", flush=True)

def tree_moved():
    """走行中に**手元の**木が動いたか。動いた file 名を返す(空 = 動いていない)。"""
    now = _manifest(SRC)
    moved = sorted(set(k for k in set(now) | set(START_MANIFEST)
                       if now.get(k) != START_MANIFEST.get(k)))
    return moved

def copy_tree():
    d = tempfile.mkdtemp(prefix="mut-")
    LIVE.append(d)
    dst = os.path.join(d, "rc")
    shutil.copytree(FROZEN, dst)
    return d, dst

# --- 対照2枚: 測る前に「この台本は赤を見分けられる」ことを証明する ---
# これが無いと、書式が変わった機械で全部緑(あるいは全部検出)を報告し続ける。
d, dst = copy_tree()
c1sink = []
NO_SUMMARY.clear()
cu, ce = suites(dst, sink=c1sink)
c1blind = blind_labels(NO_SUMMARY)
v1 = control1_verdict(cu, ce, c1blind)
if v1 == "tree-red":
    die("対照1(無変異): 手を加えていない木で検査が落ちた。まず作業ツリーを緑にする事\n"
        + _failing(c1sink, {n for n, f in (("単体", cu), ("e2e", ce))
                            if f is True and n not in c1blind}))
if v1 == "unmeasured":
    die_unmeasured(
        "対照1(無変異): 検査が**結果を出す前に**死んだ(要約行が無い)。\n"
        "  木には手を加えていないのだから、これは「検査が落ちた」ではない ——\n"
        "  本当に落ちたなら要約行(`# fail N`)が出る。出ていない = 子が結果を出す前に消えた。\n"
        "  ありうる相手: 混み合い(この台本の二重起動) / メモリ切れ / 外からの kill / 環境死。\n"
        "  次の一手:\n"
        "    1. `cd rc-backend && npm test` を単独で回す。緑ならこれは木の話ではない。\n"
        "    2. `pgrep -fl mutation-controls` —— 同じ台本が既に走っていないか見る。\n"
        "    3. 単独で回しても赤なら、その時こそ作業ツリーの話。\n"
        + "\n".join(t for _, t in NO_SUMMARY))
shutil.rmtree(d, ignore_errors=True)
d, dst = copy_tree()
p = os.path.join(dst, INJ)
orig = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write('throw new Error("canary");\n' + orig)
c2sink = []
cu, ce = suites(dst, sink=c2sink)
v2 = control2_verdict(cu, ce, canary_seen(c2sink))
if v2 == "not-red":
    die(f"対照2(故意に壊した木): 赤にならなかった(単体={cu} e2e={ce})。"
        "落ちるはずの木で落ちない = この台本は何も測れていない")
if v2 == "red-without-canary":
    die_unmeasured(
        "対照2(故意に壊した木): 赤くはなったが、**仕込んだ合言葉 canary が出力に無い**。\n"
        "  赤い理由が仕込みだと言えない = 混み合いで死んだ赤と見分けが付いていない。\n"
        "  『何かが赤くなった』は「この台本は赤を見分けられる」の証明にならない。\n"
        + _tail(c2sink, {"単体", "e2e"}, 20))
shutil.rmtree(d, ignore_errors=True)
print("対照 OK: 無変異=緑 / 故意に壊した木=canary で赤。以降の判定は意味を持つ\n")

rows = []
blind = []          # 要約が読めないまま落ちた検査を含む変異(行8)
timed = []          # 脚が時間切れになった変異(= その脚は未測定)
# ★進捗を1行ずつ出す(行4)。以前は 50 分間まるごと無言で、走っているのか固まったのかが
#   外から区別できなかった(実測: 78 件 x 37 秒)。`flush=True` が要る — stdout が
#   file にリダイレクトされると Python は既定でブロックバッファリングになり、
#   進捗を出しているつもりで最後にまとめて吐く = 出していないのと同じになる。
t0 = time.time()
for i, m in enumerate(MUT_RUN, 1):
    name, f = m[0], m[1]
    olds, news = as_list(m[2]), as_list(m[3])
    why = m[4] if len(m) > 4 else None  # 有れば「測った上で到達しないと分かっている」注記
    print(f"[{i}/{len(MUT_RUN)}] {int(time.time()-t0)}s {name[:60]}", flush=True)
    d, dst = copy_tree()
    p = os.path.join(dst, f)
    src_text = open(p).read()
    if any(o not in src_text for o in olds):
        # 走行中に返す(下の atexit が最後に拾うので**漏れてはいない**が、
        # 木まるごとのコピーなので走っている間の /var/folders を無駄に太らせない)。
        shutil.rmtree(d, ignore_errors=True)
        rows.append((name, "対象行が無い", "?", "?", why)); continue
    mutated = src_text
    for _o, _n in zip(olds, news):
        mutated = mutated.replace(_o, _n, 1)
    open(p, "w").write(mutated)
    NO_SUMMARY.clear()
    TIMED_OUT.clear()
    # ★変異の脚は timeout_fatal=False。対照2枚は上で既に die 付きで通してある =
    #   「この台本は赤を見分けられる」証明は取れているので、ここでの時間切れは
    #   台本の故障ではなく**その変異の測定失敗**として1件だけ切り離せる。
    ufail, efail = suites(dst, timeout_fatal=False)
    blind_here = list(NO_SUMMARY)
    verdict = verdict_of(ufail, efail, why, blind_here)
    if verdict.startswith("検出") or verdict == "★注記を外せる":
        if blind_here:
            blind.append((name, blind_here))
    if TIMED_OUT:
        timed.append((name, verdict, [lab for lab, _ in TIMED_OUT], list(TIMED_OUT)))
    rows.append((name, verdict, leg_text(ufail, "unit"), leg_text(efail, "e2e"), why))
    shutil.rmtree(d, ignore_errors=True)

w = max(len(r[0]) for r in rows)
print(f"{'変異'.ljust(w)} | 結果         | unit       | e2e")
for r in rows:
    print(f"{r[0].ljust(w)} | {r[1]:12} | {r[2]:10} | {r[3]}")

# ★「捕まえた」の内訳(行8)。要約行が読めないまま落ちた検査は、**変異を捕まえたのか
#   検査自体が起動段で死んだのか区別が付いていない**。判定は赤のままで正しいが、
#   その数を「守れている件数」として読むと成績の水増しになる。数を明示して人に返す。
if blind:
    # 写しは走行中に既に取ってある(NO_SUMMARY)。**場所を印字する**まで含めて1つの報告。
    bd = os.path.join(SRC, ".harness", "mutation-blind")
    os.makedirs(bd, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    print(f"\n★検出のうち **{len(blind)}件** は要約行が読めないまま落ちた"
          f"(= 変異を捕まえたのか検査が死んだのか区別できていない)。写しを読む事:")
    for _bi, (name, items) in enumerate(blind, 1):
        # ★族の文字は `FAM` から取る(2026-08-03)。ここが `M\d+` 固定だった為、M 以外の
        #   写しが全部 `M?` になっていた = **どの変異の物か名前から言えない**上、同じ秒に
        #   2件落ちると上書きで片方が消える。番号の接尾辞(`P12b`)も拾う。
        _mo = re.match(rf"[{FAM}]\d+[a-z]?", name)
        tag = _mo.group(0) if _mo else f"unnamed{_bi}"
        path = os.path.join(bd, f"{stamp}-{tag}.txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(name + "\n\n" + "\n\n".join(f"=== {lab} ===\n{txt}" for lab, txt in items))
        print(f"  - {name}\n      要約が読めなかった検査: {', '.join(lab for lab, _ in items)}"
              f"\n      写し: {path}")
else:
    print("\n検出はすべて要約行つき(= 何件がどう落ちたかまで読めている)")

# ★時間切れの内訳。**判定に関わらず**出す —— 「unit が捕まえたから良い」で畳むと、
#   e2e 側に穴が在るのか固まっただけなのかを誰も追えなくなる。
if timed:
    td = os.path.join(SRC, ".harness", "mutation-timeout")
    os.makedirs(td, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    print(f"\n★脚が時間切れになった変異 **{len(timed)}件**"
          f"({CHILD_TIMEOUT_S}秒。その脚は緑でも赤でもなく**未測定**):")
    for _ti, (name, verdict, labels, items) in enumerate(timed, 1):
        _mo = re.match(rf"[{FAM}]\d+[a-z]?", name)
        tag = _mo.group(0) if _mo else f"unnamed{_ti}"
        path = os.path.join(td, f"{stamp}-{tag}.txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(name + "\n\n" + "\n\n".join(f"=== {lab} ===\n{txt}" for lab, txt in items))
        print(f"  - {name}\n      判定: {verdict} / 時間切れの脚: {', '.join(labels)}"
              f"\n      写し: {path}")
    print("  固まる系の欠陥を撃つ変異では、脚が固まる事自体がその欠陥の症状な事がある。"
          "\n  「その脚に検査が無い」と読む前に、写しの末尾でどこで止まったかを見る事。")

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

# ★この報告が**どの木**を説明するかを、要約行より前に言う。凍結してあるので
#   走行中の編集で結果が汚れる事は無いが、汚れない事と「今の木の話である」事は別。
_moved = tree_moved()
if _moved:
    print(f"\n★走行中に手元の木が {len(_moved)} file 動いた。"
          f"この報告が説明するのは**走行開始時の木**であって、今の木ではない。")
    for k in _moved[:20]:
        print(f"    {k}")
    if len(_moved) > 20:
        print(f"    …他 {len(_moved) - 20} file")
    print("  今の木の判定が要るなら回し直す事(凍結のおかげで、この結果自体は有効)。")

print("\n素通りした変異:", missed if missed else "なし")

# 終了コード: 1 = 素通りあり(検査の穴) / **2 = 未測定あり** / 0 = 全部測れて穴なし。
# 2 を 0 に丸めないのがこの file の一貫した約束(read_suite / ENV_DEATH と同じ扱い)。
# 素通りと未測定が両方在る時は 1 —— 穴が確定している方が重いが、上の節で未測定も出ている。
unmeasured = [r[0] for r in rows if r[1] == "★未測定(時間切れ)"]
if unmeasured:
    print("未測定(時間切れで判定できなかった変異):", unmeasured)
sys.exit(1 if missed else (2 if unmeasured else 0))
