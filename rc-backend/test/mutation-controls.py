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
import shutil, subprocess, sys, os, tempfile

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INJ = "src/inject.mjs"
REG = "src/registry.mjs"
PRC = "src/procs.mjs"

MUT = [
 ("M1 メニュー判定を外す(CHOICE を返さない)", INJ,
  'if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };',
  '// mutated: menuAt 無効'),
 ("M2 入力欄の罫線条件を外す(裸の ❯ を入力欄と認める)", INJ,
  'if (BOX_RULE.test(lines[i - 1] ?? "") && BOX_RULE.test(lines[i + 1] ?? "")) return i;',
  'return i;'),
 ("M3 入力欄の下部限定を外す(画面のどこの ❯ でも拾う)", INJ,
  'const floor = Math.max(0, lines.length - 8);',
  'const floor = 0;'),
 ("M4 本文送信後の再観測を外す(modal の割り込みを見ない)", INJ,
  'if (menuAt(t)) return "modal";',
  '// mutated: 待っている間の menu 見張りを外す'),
 ("M5 本文が載ったかの確認を外す(送れた事にして Enter を押す)", INJ,
  'if (echo.tag !== "echoed") {',
  'if (false) {'),
 ("M6 メニューを番号行1つで成立させる(自己ロックが復活する)", INJ,
  'if (cluster.length >= 2 && cluster.some((x) => x.cursor)) return true;',
  'if (cluster.length >= 1) return true;'),
 ("M7 生成中を送信の遮断条件に戻す(旧設計への退行)", INJ,
  'if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };',
  'if (activity === "observed") return { state: "UNKNOWN", activity, composer: -1 };\n  if (menuAt(s)) return { state: "CHOICE", activity, composer: -1 };'),
 ("M8 scrollback を読む(-S を付ける)", INJ,
  'return this.tmux.run(["capture-pane", "-t", pane, "-p"]);',
  'return this.tmux.run(["capture-pane", "-t", pane, "-p", "-S", "-200"]);'),
 ("M9 Enter 後に入力欄が消えていたら verified と言う", INJ,
  'return left !== null && !left.includes(probe) ? "cleared" : null;',
  'return left === null || !left.includes(probe) ? "cleared" : null;'),
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
]

rows = []
for name, f, old, new in MUT:
    d = tempfile.mkdtemp(prefix="mut-")
    dst = os.path.join(d, "rc")
    shutil.copytree(SRC, dst, ignore=shutil.ignore_patterns("node_modules", ".git"))
    p = os.path.join(dst, f)
    s = open(p).read()
    if old not in s:
        rows.append((name, "変異を適用できない(対象の行が無い)", "?", "?")); continue
    open(p, "w").write(s.replace(old, new, 1))
    u = subprocess.run(["npm", "test", "--silent"], cwd=dst, capture_output=True, text=True)
    e = subprocess.run(["node", "test/e2e-local.mjs"], cwd=dst, capture_output=True, text=True)
    ufail = "# fail 0" not in u.stdout
    efail = "fail=0" not in e.stdout
    rows.append((name, "検出" if (ufail or efail) else "★素通り",
                 "unit落ちる" if ufail else "unit通る", "e2e落ちる" if efail else "e2e通る"))
    shutil.rmtree(d, ignore_errors=True)

w = max(len(r[0]) for r in rows)
print(f"{'変異'.ljust(w)} | 結果   | unit       | e2e")
for r in rows:
    print(f"{r[0].ljust(w)} | {r[1]:6} | {r[2]:10} | {r[3]}")
print()
missed = [r[0] for r in rows if r[1] != "検出"]
print("素通りした変異:", missed if missed else "なし")
sys.exit(1 if missed else 0)
