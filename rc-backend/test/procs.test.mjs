// プロセスの実測 — ps の出力の読み方だけを検査する。
//
// なぜこの層が要るか(2026-08-01): 「そのペインに claude が居るか」を tmux の
// `#{pane_current_command}` = 名前で答えていたが、名前は機械ごとに違う値になる
// (edith="2.1.220" / MBP="bash" ← retry ラッパが exec せず claude を子として起動するため)。
// 名前をやめて ps の実測に替えたので、**その読み取りが実物の形と合っていること**を
// ここで固定する。下の固定文字列は実機の `ps -axww -o pid=,tty=,pgid=,tpgid=,lstart=,command=`
// からそのまま採った行(2026-08-01 MBP)。
import { test } from "node:test";
import assert from "node:assert/strict";
import { parsePs, psSnapshot, looksLikeClaudeProc, normTty, PS_ARGS } from "../src/procs.mjs";

// 実機からそのまま採った行。整形しないこと(空白の数まで込みで検査対象)。
const REAL = [
  "40845 ttys000  40845 40845 Sat Aug  1 15:49:03 2026     Claude",
  "41675 ttys000  40845 40845 Sat Aug  1 15:49:05 2026     node /Users/tomtim/.npm-global/bin/google-calendar-mcp",
  " 1086 ??        1086    0 Fri Jul 31 18:23:27 2026     /bin/bash /Users/tomtim/.claude/tools/claude-api-health-monitor.sh",
  "54850 ttys012  54850 54850 Sat Aug  1 14:02:11 2026     /Users/tomtim/.local/share/claude/versions/2.1.220",
  "54851 ttys013  54851 54787 Sat Aug  1 14:02:12 2026     /Users/tomtim/.local/share/claude/versions/2.1.220",
].join("\n") + "\n";

test("実機の ps 1行を pid / tty / 前面 / 誕生時刻に分解できる", () => {
  const { byPid } = parsePs(REAL);
  const p = byPid.get(40845);
  assert.equal(p.tty, "ttys000");
  assert.equal(p.foreground, true, "pgid == tpgid");
  assert.equal(p.command, "Claude");
  assert.equal(new Date(p.startMs).getFullYear(), 2026);
  assert.ok(p.startMs > 0, "★日付が1桁の日(Aug  1 = 空白2つ)でも読めること");
});

test("★前面かどうかは pgid == tpgid(Ctrl-Z で止めた claude を生きていると読まない)", () => {
  const { byPid } = parsePs(REAL);
  assert.equal(byPid.get(54850).foreground, true);
  assert.equal(byPid.get(54851).foreground, false, "tpgid がシェルに移っている = 停止中");
});

test("★★claude が前面に居る tty の集合を作る(名前でなくここで判定する)", () => {
  const { claudeTtys } = parsePs(REAL);
  assert.ok(claudeTtys.has("ttys000"), "アプリ名 'Claude' も拾う");
  assert.ok(claudeTtys.has("ttys012"));
  assert.equal(claudeTtys.has("ttys013"), false, "★停止中は前面ではないので入れない");
});

test("tty を持たないプロセス(??)は集合に入れない", () => {
  // 1086 は claude を名前に含むが tty が ?? = どのペインの前面でもない。
  // 入れてしまうと "??" というキーが出来て、tty 未取得のペインと当たりかねない。
  const { claudeTtys } = parsePs(REAL);
  assert.equal(claudeTtys.has("??"), false);
  assert.equal([...claudeTtys].every((t) => t.startsWith("ttys")), true);
});

test("claude の判定は広い(近くに居るかを探す用途。許可の判定には使わない)", () => {
  assert.equal(looksLikeClaudeProc("/Users/x/.local/share/claude/versions/2.1.220"), true);
  assert.equal(looksLikeClaudeProc("Claude"), true);
  assert.equal(looksLikeClaudeProc("bash /Users/x/.claude/tools/claude-retry-wrapper.sh"), true);
  assert.equal(looksLikeClaudeProc("vim notes.md"), false);
  assert.equal(looksLikeClaudeProc(""), false);
  assert.equal(looksLikeClaudeProc(undefined), false);
});

test("tmux の /dev/ttys000 と ps の ttys000 を同じ形に揃える", () => {
  assert.equal(normTty("/dev/ttys000"), "ttys000");
  assert.equal(normTty("ttys000"), "ttys000");
  assert.equal(normTty(""), "");
  assert.equal(normTty(null), "");
});

test("読めない行は黙って捨てる(ヘッダ・空行・途中で切れた行で全体を落とさない)", () => {
  const { byPid } = parsePs("  PID TTY\n\n" + REAL + "garbage\n");
  assert.equal(byPid.size, 5);
});

test("★ps を叩けない時は available:false(= 分からない。死んでいる ではない)", () => {
  const snap = psSnapshot(() => { throw new Error("ENOENT"); });
  assert.equal(snap.available, false);
  assert.equal(snap.procOf(40845), null);
  assert.equal(snap.claudeTtys, null, "空集合ではなく null = 判断材料が無いと呼び手に伝える");
});

test("★出力が空 / 1行も解釈できない場合も available:false", () => {
  // 形が変わった OS で「全プロセスが死んだ」と読むと、開いている TUI に対して
  // ワーカーが起きる(lost-update)。解釈できない = 分からない、に倒す。
  assert.equal(psSnapshot(() => "").available, false);
  assert.equal(psSnapshot(() => "PID TTY TIME CMD\n").available, false);
});

test("ps を叩けた時は pid 引きと tty 集合を返す", () => {
  const snap = psSnapshot((args) => {
    assert.deepEqual(args, PS_ARGS, "要求する列の並びが変わったら読み側と揃っているか確かめる");
    return REAL;
  });
  assert.equal(snap.available, true);
  assert.equal(snap.procOf(54850).tty, "ttys012");
  assert.equal(snap.procOf(999999), null);
  assert.ok(snap.claudeTtys.has("ttys012"));
});
