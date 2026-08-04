#!/bin/bash
# controls-for: test/session-guard.test.mjs
# `test/session-guard.test.mjs` が**効くか**を測る対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# この検査は「違反が 0 件」を緑で返す。緑は2通りの理由で出る:
#   (a) 本当に違反が無い          (b) 走査が何も見ていない
# 走らせても (a)(b) は見分けられない —— どちらも緑なのだから。見分かるのは
# **違反を1件植えて赤になるか**を見た時だけ。それがこの対照。
#
# ── 測る5つ ────────────────────────────────────────────────────────────
#   ① 電話側に違反を1件植えると**赤**        (= 走査が ios/Sources に届いている)
#   ② 植えなければ緑                          (= ①が巻き添えでない)
#   ③ 注釈の中の言及は**緑のまま**            (= 直しが増やした注釈で赤くならない)
#   ④ 電話側の木が居ない部分木では**緑**      (= 変異走行を巻き添えにしない)
#   ⑤ 錨の file が消えると**赤**              (= 空振りが緑の下に隠れない)
#
# ★④が要る理由: 変異走行は `rc-backend/` だけの部分木で回る。そこでこの検査が
#   赤い造りだと、走行中の**全件**が「検出」と記録される —— 素通りが丸ごと隠れ、
#   要約は「素通り 0件」と書く。壊れ方が緑の方向に出るので後から気付けない。
#   (`test/no-linerefs-controls.sh` が同じ理由で同じ項を持っている)
#
# ★⑤が要る理由: 検査は自分が何を見たか報告しない。木が動いても改名されても
#   「違反 0 件」で緑になる。錨(許可一覧の file が実際に走査に掛かる事)が
#   本当に赤を出せるかは、錨を外して初めて判る。
#
# ★live の木には**足すだけ**で、既存の file には一度も触らない(`sed -i` で壊して
#   戻す造りは、復元の失敗が repo を壊れたまま残す)。足した物は最後に**不在で**確かめる。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う / 2 = 測れなかった
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
TEST="$ROOT/test/session-guard.test.mjs"
IOS_SOURCES="$REPO/ios/Sources"
NODE="${RC_NODE_BIN:-node}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

[ -f "$TEST" ] || { echo "測れない: 検査本体が居ない ($TEST)"; exit 2; }
command -v "$NODE" >/dev/null 2>&1 || { echo "測れない: node が居ない"; exit 2; }
[ -d "$IOS_SOURCES" ] || { echo "測れない: 電話側の木が居ない ($IOS_SOURCES) = 部分木で回されている"; exit 2; }

PLANT="$IOS_SOURCES/__session_guard_control_probe.swift"
SCRATCH="$(mktemp -d /tmp/rc-sessguard.XXXXXX)" || exit 2
cleanup() {
    /bin/rm -f "$PLANT" 2>/dev/null
    find "$SCRATCH" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
    find "$SCRATCH" -type d -depth -exec /bin/rmdir {} \; 2>/dev/null
}
trap cleanup EXIT

run_live() { (cd "$ROOT" && "$NODE" --test test/session-guard.test.mjs >"$SCRATCH/out.txt" 2>&1); }

# ── ② 先に素の状態が緑である事を見る。ここが赤ければ①は何も証明しない ──
if run_live; then ok "② 何も植えていない live の木は緑"; else ng "② 何も植えていない live の木は緑" "素で赤い"; fi

# ── ① 違反を1件植える ────────────────────────────────────────────────
cat >"$PLANT" <<'SWIFT'
import Foundation
// 対照用。session-guard-controls.sh が置いて消す。
struct ControlProbeClient {
    func fetch() async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://control.invalid")!)
        return data
    }
}
SWIFT
if run_live; then
    ng "① 違反を植えると赤" "植えても緑のまま = 走査が ios/Sources に届いていない"
else
    if grep -q '__session_guard_control_probe.swift' "$SCRATCH/out.txt"; then
        ok "① 違反を植えると赤(違反した file を名指ししている)"
    else
        ng "① 違反を植えると赤" "赤くはなったが植えた file を名指ししていない = 別の理由で落ちた"
    fi
fi
/bin/rm -f "$PLANT"

# ── ③ 注釈の中の言及では赤くならない ──────────────────────────────────
# 検査の限界を明示的に固定する。ここが赤いと、直しが増やした注釈で検査が鳴り続け、
# 次の人が検査の方を弱める —— 守りが緩む一番よくある経路。
cat >"$PLANT" <<'SWIFT'
import Foundation
/// 対照用。`URLSession` に注釈で言及しても違反ではない。
// URLSession.shared を使ってはいけない、という説明そのもの。
struct ControlProbeCommentOnly {
    let note = "ok"
}
SWIFT
if run_live; then ok "③ 注釈の中の言及は緑のまま"; else ng "③ 注釈の中の言及は緑のまま" "注釈で赤くなる"; fi
/bin/rm -f "$PLANT"

# ── ④⑤ 砂場の木で測る(live の木は触らない) ──────────────────────────
# ★ここで `ios/` を先に作らない事。作ってしまうと④は「木が居ない」を測れず、
#   ⑤(錨が居ない)を測る事になる —— 別の物を測って緑を貰う形。初回に踏んだ。
mkdir -p "$SCRATCH/rc-backend/test"
cp "$TEST" "$SCRATCH/rc-backend/test/session-guard.test.mjs"
run_scratch() { (cd "$SCRATCH/rc-backend" && "$NODE" --test test/session-guard.test.mjs >"$SCRATCH/out.txt" 2>&1); }

# ④ 電話側の木が丸ごと居ない = 変異走行の部分木
if run_scratch; then
    if grep -q '測っていない' "$SCRATCH/out.txt"; then
        ok "④ 電話側の木が居なければ緑(かつ測っていない事を名指しする)"
    else
        ng "④ 電話側の木が居なければ緑" "緑だが黙っている = 測っていない事が記録に残らない"
    fi
else
    ng "④ 電話側の木が居なければ緑" "部分木で赤くなる = 変異走行の全件が『検出』に化ける"
fi

# ⑤ 木は在るが錨の file が居ない
mkdir -p "$SCRATCH/ios/Sources/Core"
cat >"$SCRATCH/ios/Sources/Core/SomeOtherFile.swift" <<'SWIFT'
import Foundation
struct Whatever { let x = 1 }
SWIFT
if run_scratch; then
    ng "⑤ 錨の file が消えると赤" "錨が居ないのに緑 = 空振りが緑の下に隠れる"
else
    if grep -q 'BackendSession.swift' "$SCRATCH/out.txt"; then
        ok "⑤ 錨の file が消えると赤(消えた錨を名指ししている)"
    else
        ng "⑤ 錨の file が消えると赤" "赤くはなったが錨を名指ししていない"
    fi
fi

echo
echo "PASS $pass / FAIL $fail"
[ -e "$PLANT" ] && { echo "FAIL  植えた物が残っている: $PLANT"; exit 1; }
echo "植えた物は残っていない(確認済み): $PLANT"
[ "$fail" -eq 0 ] || exit 1
exit 0
