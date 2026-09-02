#!/bin/bash
# controls-for: tools/wire-shape-capture.mjs
#
# `wire-shape-capture` の**必須鍵の抽出器**の負の対照。
#
# ── なぜ此れが要るか(2026-09-01、書いた当日に3回 間違えた)────────────────
# 此の道具は「電話の `Decodable` が必須とする鍵」を Swift の原文から静的に採る。
# 書いている最中に**私自身が 3 つの誤りを出し、3 つとも「机の欠陥」の顔で現れた**:
#   1. 修飾名 `A.B` を短名で解決 → `HealthzClient.Wire` が **口座の鍵**を要求すると報告
#   2. 入れ子の型のプロパティが親に混ざる → `HistoryEntry` が `who` を要求すると報告
#   3. `var x: T { … }` の計算プロパティを格納と数える → `SessionRow` が `displayTitle` を要求
# 3 番は**本番の机へ「鍵が足りない」と報告する寸前**まで行った。机は正しく、計器が嘘をついていた。
#
# ★だから此の対照が測るのは「今 正しい事」ではなく、**其の 3 つが二度と戻らない事**。
#   各項は「戻すと赤くなる」形に書いてある(検体の Swift を此処に置き、期待値を名指しする)。
# ★加えて**陽性対照**を 1 本置く: 抽出器が本当に鍵を見つけられる事。
#   之が無いと、常に空集合を返す実装で全部の否定が通る(0 件は「探した範囲に無い」以上を意味しない)。
#
# 本番にも tailnet にも触らない —— 測るのは抽出器の純関数だけ。門から回して安全。
# 終了コード: 0 = 全部 通った / 1 = 1 本でも落ちた
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MJS="$HERE/../tools/wire-shape-capture.mjs"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s  (%s)\n' "$1" "$2"; fail=$((fail+1)); }

[ -f "$MJS" ] || { echo "  FAIL 対象が無い: $MJS"; echo "--- 合計: PASS 0 / FAIL 1 ---"; exit 1; }

TMP="$(mktemp -d)"
trap 'find "$TMP" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; find "$TMP" -type d -depth -exec /bin/rmdir {} + 2>/dev/null' EXIT

# 検体の Swift を置く木。抽出器は `ios/Sources` を再帰で読むので、其の形を作る。
SRC="$TMP/ios/Sources/Core"
mkdir -p "$SRC"

cat > "$SRC/Probe.swift" <<'SWIFT'
import Foundation

// ① 同名の入れ子が2つ。短名で解決すると片方に当たる。
enum AlphaClient {
    struct Wire: Decodable { let alphaOnly: String; let shared: Int }
}
enum BetaClient {
    struct Wire: Decodable { let betaOnly: String; let shared: Int }
}

// ② 入れ子の子プロパティが親へ漏れないか。親自身の必須は `outer` だけ。
struct Parent: Decodable {
    struct Child: Decodable {
        let childOnly: String
    }
    let outer: Child
}

// ③ 計算プロパティは復号に参加しない。必須は `stored` だけ。
struct Computed: Decodable {
    let stored: String
    var derived: String { stored + "!" }
    var flag: Bool { stored.isEmpty }
}

// ④ 1行宣言(`;` 区切り)。4つとも必須。
struct OneLine: Decodable { let a: Bool; let b: Int; let c: String; let d: Double }

// ⑤ 明示的な復号器: decode = 必須、decodeIfPresent = 任意。
struct Explicit: Decodable {
    let must: Int
    let maybe: Bool
    private enum CodingKeys: String, CodingKey { case must, maybe }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        must = try c.decode(Int.self, forKey: .must)
        maybe = try c.decodeIfPresent(Bool.self, forKey: .maybe) ?? false
    }
}

// ⑥ CodingKeys で線の綴りへ改名する。必須として出るのは線の側の綴り。
struct Renamed: Decodable {
    let classification: String
    private enum CodingKeys: String, CodingKey { case classification = "screen" }
}

// ⑦ Optional は必須でない。
struct AllOptional: Decodable {
    let a: String?
    let b: Int?
}
SWIFT

run_case() { # $1=型名  $2=期待(ソート済みカンマ区切り)  $3=説明
  local got
  got="$(RC_SHAPE_SWIFT_ROOT="$TMP/ios/Sources" node --input-type=module -e "
    import { requiredKeys } from '$MJS';
    const r = requiredKeys('$1');
    console.log(r === null ? 'NULL' : r.sort().join(','));
  " 2>&1 | tail -1)"
  [ "$got" = "$2" ] && ok "$3" || no "$3" "期待=$2 実測=$got"
}

echo "== 3 つの再発を塞ぐ(戻すと赤くなる) =="
run_case "AlphaClient.Wire" "alphaOnly,shared" "① 修飾名 A.B は A の中の B に当たる(別の同名型を掴まない)"
run_case "BetaClient.Wire"  "betaOnly,shared"  "① 同名の2つ目も正しく解決する"
run_case "Parent"           "outer"            "② 入れ子の子プロパティが親の必須へ漏れない"
run_case "Computed"         "stored"           "③ 計算プロパティを格納として数えない"

echo "== 其の他の書き方 =="
run_case "OneLine"     "a,b,c,d"  "④ セミコロン区切りの1行宣言を全部 拾う"
run_case "Explicit"    "must"     "⑤ decode は必須 / decodeIfPresent は任意"
run_case "Renamed"     "screen"   "⑥ CodingKeys の改名先(線の綴り)で出る"
run_case "AllOptional" ""         "⑦ Optional だけの型は必須鍵ゼロ"

echo "== 陽性対照(否定が空回りしていない事) =="
# 常に空集合を返す実装では上の否定系が全部 通ってしまう。1 本でも実際に拾える事を見る。
run_case "Parent.Child" "childOnly" "★入れ子の型を名指しすれば、その子の鍵は拾える"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" -eq 0 ]
