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

MUT = [
 ("M1 メニュー判定を外す(CHOICE を返さない)", INJ,
  'if (menuAt(s)) return { state: "CHOICE", activity, composer: -1, limited };',
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
  'if (menuAt(s)) return { state: "CHOICE", activity, composer: -1, limited };',
  'if (activity === "observed") return { state: "UNKNOWN", activity, composer: -1 };\n  if (menuAt(s)) return { state: "CHOICE", activity, composer: -1, limited };'),
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
  '        text: `${note}本文は残してあります。送り直すと二重に入ることがあります。`,\n        keepText: true,',
  '        text: `${note}本文は残してあります。送り直すと二重に入ることがあります。`,\n        keepText: false,'),
 ("M61 二重注入の注意を落とす(送り直しが二重に入る事を人に伝えない)", VIE,
  '`${note}本文は残してあります。送り直すと二重に入ることがあります。`',
  '`${note}本文は残してあります。`'),
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
      return work === "動いている"
        ? { kind: "tmux", short: "動いている・★上限", text: "机で開いている・動いている(★画面に利用上限の告知が残っている)", screen: v.screen || "" }
        : { kind: "tmux", short: "★利用上限", text: "机で開いている・★利用上限(答えは返りません)", screen: v.screen || "" };
    }
''',
  ''),
 # ★M77 は「上限を出す」方向でなく「**出しすぎる**」方向の退行を撃つ(2026-08-02 追加)。
 # 8/02 朝までの実装がこれそのもので、`limited` が `動いている` を無条件に押し退けていた。
 # 症状は静かで、検査も緑のままだった — `limited:true` と `activity:"observed"` を
 # **同時に**与える検査が1本も無かったから。組み合わせを測らない検査は、
 # 個々の枝を全部緑にしたまま、その交差点を丸ごと見落とす。
 ("M77 上限を動きより優先させる(生成中の画面に「答えは返りません」と出す)", VIE,
  '      return work === "動いている"',
  '      return false'),
 # ★M78 は**継ぎ目**を撃つ(2026-08-02 追加)。分類器(M74/M75)と電話の表示(M76/M77)は
 # それぞれ撃っていたのに、その間の `server.mjs` が `limited` を JSON に載せる所は
 # 誰も撃っていなかった。両端が緑でも、間で落ちれば人には届かない。
 # ★この変異が「素通り」で返ってきたら、それは**継ぎ目に検査が無い**という答えで、
 #   その時は e2e に `live.limited` の assert を足す。台本に答えを出させる為に置く。
 ("M78 サーバの応答から limited を落とす(分類器は見えているのに電話へ渡らない)", SRV,
  '    return { screen: s.state, activity: s.activity, limited: s.limited };',
  '    return { screen: s.state, activity: s.activity };'),
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
  "if (q.length >= maxWaiters) {",
  "if (q.length > maxWaiters) {"),
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
  "      await enqueue(key, signal); // ここを抜けた = 自分が持ち主",
  "      queueOf(key); // 直列化しない"),
 ("M94 鍵の値を無視して全部1本にする(並列性を殺す)", MTX,
  "  async function run(key, fn, { signal, maxWaiters = defaultMaxWaiters } = {}) {",
  "  async function run(key0, fn, { signal, maxWaiters = defaultMaxWaiters } = {}) {\n    const key = typeof key0 === 'string' && key0 ? 'ALL' : key0;"),

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
 ("W4 止めていないのに「止めた」と返す", INJ,
  "      if (e?.code === MUTEX_BUSY || e?.code === MUTEX_ABORTED) return false;",
  "      if (e?.code === MUTEX_BUSY || e?.code === MUTEX_ABORTED) return true;"),
 ("W5 割り込みを鍵の外へ出す(Escape が本文と Enter の間に落ちる)", INJ,
  """      return await this.mutex.run(
        pane,
        () => {
          this.tmux.run(["send-keys", "-t", pane, "Escape"]);
          return true;
        },
        { signal },
      );""",
  """      this.tmux.run(["send-keys", "-t", pane, "Escape"]);
      return true;"""),
 # ★W6 は**継ぎ目**を撃つ(M78 と同じ狙い)。注入器が false を返しても、サーバが
 #   200 で「止めた」と返せば、電話には「止めた」と出る。両端が緑でも間で落ちる。
 #   素通りで返ってきたら、それは**継ぎ目に検査が無い**という答え。
 ("W6 断られた割り込みを 200 で返す(まだ止めていないのに電話へ「止めた」が出る)", SRV,
  "        if (!stopped) {",
  "        if (false) {"),
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
        text: "送りましたが、サーバの返事を読めませんでした。本文は残してあります。送り直すと二重に入ることがあります。",
        keepText: true,
      };
    }""",
  "    void body;"),
 ("P9 読めない本文でも入力欄を空にする(打った文が黙って消える)", VIE,
  '        text: "送りましたが、サーバの返事を読めませんでした。本文は残してあります。送り直すと二重に入ることがあります。",\n        keepText: true,',
  '        text: "送りましたが、サーバの返事を読めませんでした。本文は残してあります。送り直すと二重に入ることがあります。",\n        keepText: false,'),
 ("P2 その守りを広げすぎる(delivered の無い正当な worker 応答まで warn にする)", VIE,
  "    if (body == null) {\n      return {\n        kind: \"warn\",",
  "    if (!b.delivered) {\n      return {\n        kind: \"warn\","),
 ("P3 割り込み 200 で読めない本文を「対象が無かった」と断定する", VIE,
  '      return { kind: "warn", text: "止めたかどうか確認できませんでした。画面を見て確かめてください。" };',
  '      return { kind: "warn", text: "止める対象がありませんでした。" };'),
 ("P4 読めなかった応答を `{}` に捏造して判定層へ渡す(送信・割り込みの両方)", APP,
  ["    const body = await r.json().catch(() => null);\n    const v = sendResult(r.status, body);",
   "    const body = await r.json().catch(() => null); // ★send() と同じ。読めない事を値にしない"],
  ["    const body = await r.json().catch(() => ({}));\n    const v = sendResult(r.status, body);",
   "    const body = await r.json().catch(() => ({}));"]),
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

 # --- 子プロセスの生き死に (X) = H2「1つの転写に書き手が2人」を守る層 -------------
 # ★★この族は **復元** である。原本は 2026-08-02 16:43 開始の 119 件走行の中にしか存在せず、
 #   走行中(16:55)に台本が上書きされて disk からも 12 commit 全部からも消えた。走行ログに
 #   残った題名だけが手掛かり = **同じ的を書き直したという保証は無い**。走行時は X1〜X9 が
 #   あり X2-X7/X9 の7件が検出された。X1/X8 は当時**素通り**し、その素通りを根拠に
 #   `entry.retired` 旗そのものが削除された(`src/worker.mjs:230-233` と `:274-275` に
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
  "return { fork: !head || undead, resumeId: head || sessionId };",
  "return { fork: !head, resumeId: head || sessionId };"),
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
  "return { fork: !head || undead, resumeId: head || sessionId };",
  "return { fork: !head || undead, resumeId: sessionId };"),
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
 ("R1 溢れても切り捨てない(固定長リングが無限に伸びる)", RNG,
  "    if (this.buf.length > this.capacity) this.buf.shift();",
  "    void 0;"),
 ("R2 溢れを黙って連続として渡す(gap を立てない = 嘘の連続性)", RNG,
  "    if (seq + 1 < oldestHeld) out.gap = true;",
  "    void oldestHeld;"),
 # ★R3 は**退役**(2026-08-02)。素通りしたが、これは検査の穴ではなく**等価変異**だった。
 #   的: `... : this.nextSeq` を `... : 0` に変える(空リングの起点)。
 #   実測で挙動が変わる入力は **`since(-1)` の1点だけ**(orig gap=true / mut gap=false)。
 #   そして負の seq は `src/tail.mjs:59` の `/^\d+$/` で撥ねられるので **since() に到達しない**
 #   (唯一の呼び口は `server.mjs:848` の検証済み `d.seq` と、その薄い委譲 `worker.mjs:88`)。
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
]

# ★変異の番号は一意でなければならない(2026-08-02 追加。実際に M69-M73 を重複させた)。
# 重複しても走行は正しいが、**報告と `--only` がどちらの変異の事か言えなくなる**。
# 「対象行が無い」で片方が空振りしても、もう片方が検出なら人は番号で見分けられない。
# 番号は人が結果を追う為の同一性なので、機械で見張る。台本の起動段で落とす(測る前に止める)。
# ★接頭辞の集合は「読む場所」の一覧そのもの: M = 部品の中身 / W = 繋ぎ目 /
#   X = H2(1つの転写に書き手が2人)を守る層 / P = 電話に何が見えるか /
#   R = 追いつきリング(再接続で「間が失われた」を黙って連続に見せない層)。
#   2026-08-02: ここが `[MW]` だった為、走行中のメモリにしか無かった X 系を書き戻そうとすると
#   台本自身が起動段で落ちる状態だった = **この検査が X の復元を機械的に禁じていた**。
#   新しい族を足す時はここも足す。足し忘れると「番号で始まっていない」で止まる(fail-closed)。
_named = [(re.match(r"[MWXPR]\d+(?=[ (])", m[0]), m[0]) for m in MUT]
_unnamed = [t for mo, t in _named if not mo]
if _unnamed:
    sys.exit("★台本を止める: 番号で始まっていない変異がある: " + " / ".join(_unnamed[:3]))
_ids = [mo.group(0) for mo, _ in _named]
_dupes = sorted({i for i in _ids if _ids.count(i) > 1}, key=lambda s: int(s[1:]))
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
    if re.fullmatch(r"[MWXPR]", word):                      # 族まるごと
        return [m for m in MUT if m[0].startswith(word) and m[0][1:2].isdigit()], f"族 {word}"
    if re.fullmatch(r"[MWXPR]\d+", word):                    # 番号ちょうど1件
        return [m for m in MUT if re.match(rf"{word}(?=[ (])", m[0])], f"番号 {word}"
    return [m for m in MUT if word in m[0]], f"題名に「{word}」を含む"

if ONLY is None:
    MUT_RUN = MUT
else:
    MUT_RUN, _how = _select(ONLY)
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
#   ここに引っ掛かったら測定は失敗であって「検出」ではないので、下では die する。
CHILD_TIMEOUT_S = 600

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

def run_child(cmd, cwd, label):
    p = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         stdin=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        pgid = os.getpgid(p.pid)
    except ProcessLookupError:
        pgid = p.pid            # 即死した = 群 ID は pid と同じ(start_new_session の性質)
    _CHILD_PGIDS.add(pgid)
    timed_out = False
    try:
        out, err = p.communicate(timeout=CHILD_TIMEOUT_S)
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
        die(f"{label}: {CHILD_TIMEOUT_S} 秒を超えた(実測は 0.7〜35 秒)。\n"
            f"これは**測定の失敗**であって「変異を検出した」ではないので、"
            f"検出に丸めずここで止める。\n"
            f"--- stdout 末尾 ---\n" + "\n".join(out.splitlines()[-8:]) +
            f"\n--- stderr 末尾 ---\n" + "\n".join(err.splitlines()[-8:]))
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)

def suites(dst):
    u = run_child(["npm", "test", "--silent"], dst, "単体")
    e = run_child(["node", "test/e2e-local.mjs"], dst, "e2e")
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
blind = []          # 要約が読めないまま落ちた検査を含む変異(行8)
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
    ufail, efail = suites(dst)
    blind_here = list(NO_SUMMARY)
    if ufail or efail:
        verdict = "★注記を外せる" if why else ("検出(要約なしで落ちた)" if blind_here else "検出")
        if blind_here:
            blind.append((name, blind_here))
    else:
        verdict = "未到達(注記)" if why else "★素通り"
    rows.append((name, verdict, "unit落ちる" if ufail else "unit通る",
                 "e2e落ちる" if efail else "e2e通る", why))
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
    for name, items in blind:
        tag = re.match(r"M\d+", name).group(0) if re.match(r"M\d+", name) else "M?"
        path = os.path.join(bd, f"{stamp}-{tag}.txt")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(name + "\n\n" + "\n\n".join(f"=== {lab} ===\n{txt}" for lab, txt in items))
        print(f"  - {name}\n      要約が読めなかった検査: {', '.join(lab for lab, _ in items)}"
              f"\n      写し: {path}")
else:
    print("\n検出はすべて要約行つき(= 何件がどう落ちたかまで読めている)")

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
