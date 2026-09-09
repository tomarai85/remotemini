#!/bin/bash
# controls-for: ios/UITests
#
# UI 検査の class が **門から到達できる**事を、毎回 全数で確かめる門。
#
# ── なぜ要るか(2026-09-08、2 度目)────────────────────────────────────────────
# 1 度目 = `.harness/evidence-2026-09-08/ui-tests-were-never-in-the-commit-path.md`:
#   UI 検査 8 本が赤いまま出荷された。誰も走らせていなかったので、赤である事すら
#   判らなかった。其の時は `composer-surface-control.sh` を1本作って塞いだ。
# 2 度目 = 同日の掃引: **27 class 中 10 本が、どの台本からも名指しされていない**。
#   其の中に `ListRenameUITests` —— 同じ日に「名前変更が机を叩かない」欠陥を直した、
#   其の直しを守る為に書いた検査が入っていた。1 本ずつ塞ぐ限り、次の1本が同じ穴に落ちる。
#
# ★**変更点だけ見る門は、古い門が通した物に永久に盲目**(memory:
#   `method_a_change_gate_cannot_see_what_an_older_gate_admitted`)。
#   だから此の門は staged な file を見ない —— 走るたびに `ios/UITests/*.swift` を
#   **全部数え直す**。既に木に居る到達不能な class も毎回名指しされる。
#
# 判定:
#   到達可能 = class 名が `ios/tools` / `rc-backend/tools` / `rc-backend/test` / `.harness` の
#              どこかに現れる。`-only-testing:RemoteMiniUITests/X` でも
#              `CLASSES=(X …)` の配列でも拾える(**書き方に依存しない**)。
#   宣言済み = 下の `DECLARED` に「名前|理由」で載っている。理由は 12 文字以上。
#   其れ以外 = 赤。
#
# ★`DECLARED` は免除の札ではなく**事実の宣言**。「走らせられない理由」を書く場所であって、
#   「今は面倒だから」を書く場所ではない。理由が腐ったら此の門ではなく理由を直す。
#
# ── 此の門が測らないもの(2026-09-09、Codex の 2 巡目が名指し)────────────────
# 証明しているのは「登録済みの台本の中に、走る形の文字列が在る」= **文字列の同居**で
# あって、其の class が実際に `xcodebuild test` の選択子へ流れた事ではない。
# 通ってしまう配置(Codex の原文):
#     ios/tools/nightly-ui.sh に  LEGACY_TESTS=("RemoteMiniUITests/PaymentUITests")
#     同 file の実行行は          xcodebuild test -only-testing:"RemoteMiniUITests/LoginUITests"
#   配列は誰にも読まれないのに、`PaymentUITests` は到達可能に数えられる。
# 之を閉じるには「走った物」を観測して台帳に落とし、門が其れを読む形が要る
# (`run-controls-ledger` / `parity-ledger` と同じ作り)。今は入れていない ——
# 台帳は走行が無い日に腐り、腐った台帳は文字列より悪い。
# ★代わりに、今日の 21 本は**実際に走った所を見て**居る:
#   `.harness/evidence-2026-09-09/uitest-classes-observed-running.md`。
#   文字列だけを根拠にした class は今 1 本も無い。
#   ★退却条件: 到達可能と数えられている class が、対照の log に現れなくなったら台帳へ移す。
#
# 終了コード: 0=全部到達可能か宣言済み / 1=到達不能な class が在る / 2=測れなかった
set -uo pipefail

IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$IOS/.." && pwd)"
UITESTS="$IOS/UITests"

# 走らせられない事が**性質**である class。名前|理由(12 文字以上)。
DECLARED=(
  "LiveSmokeUITests|走者の環境に RC_LIVE_URL と RC_LIVE_KEY が無ければ XCTSkip する(本物の机に繋ぐ煙検査)。門は鍵を持たないので、門から走らせると必ず skip になり、緑が何も意味しなくなる"
  "ToolOutputFoldUITests|ios/tools/device-ui-check.sh が走らせる = Tom の実機を繋いで人が撃つ検査。門は実機を持たないので構造的に走らせられない"
  "SearchJumpUITests|ios/tools/device-ui-check.sh が走らせる = 実機を繋いで人が撃つ検査。門は実機を持たない"
  "SearchHighlightUITests|ios/tools/device-ui-check.sh が走らせる = 実機を繋いで人が撃つ検査。門は実機を持たない"
  "ListSearchUITests|ios/tools/device-ui-check.sh が走らせる = 実機を繋いで人が撃つ検査。門は実機を持たない"
  "EmptySessionListHintUITests|ios/tools/device-ui-check.sh が走らせる = 実機を繋いで人が撃つ検査。門は実機を持たない"
)

# ★下限。列挙が壊れて 0 本になった時に「全部到達可能」と読ませない ——
#   空の網は「違反 0 件」に見える(`port-coverage-gate` / `orphan-instrument-scan` と同じ床)。
FLOOR="${RC_UITEST_FLOOR:-25}"   # 実測 27。緩い方との突き合わせが主で、之は粗い網

[ -d "$UITESTS" ] || { echo "uitest-reachability: $UITESTS が無い = 測っていない"; exit 2; }

# ★列挙は**2 通りで数えて突き合わせる**(Codex 2026-09-09 の指摘)。
#   厳しい方の regex は行頭の `final class X` しか拾わないので、`@MainActor final class`
#   や字下げされた宣言、`UITests` で終わらない名前が入った日に**黙って見えなくなる** ——
#   見えない class は「到達不能」ですらなく、門の視界の外に落ちる = 最悪の偽の緑。
#   SwiftSyntax を持ち出さずに其れを掴む安い方法が、**緩い方の数と一致するか**を見る事。
#   食い違ったら判定しない(不一致の内容も出す)。今日の実測は 27 = 27。
classes="$(grep -rhoE '^(final )?class [A-Za-z0-9_]+UITests' "$UITESTS"/*.swift 2>/dev/null | awk '{print $NF}' | sort -u)"
loose="$(grep -rhoE 'class +[A-Za-z0-9_]+ *:' "$UITESTS"/*.swift 2>/dev/null | sed 's/class  *//; s/ *:.*//' | sort -u)"
n_total="$(printf '%s\n' "$classes" | grep -c . )"
n_loose="$(printf '%s\n' "$loose" | grep -c . )"
if [ "$n_total" != "$n_loose" ]; then
    echo "uitest-reachability: 列挙が食い違う(厳 $n_total / 緩 $n_loose)= どちらかが取り零している。判定しない"
    echo "  緩い方にだけ在る: $(comm -13 <(printf '%s\n' "$classes") <(printf '%s\n' "$loose") | tr '\n' ' ')"
    exit 2
fi
if [ "$n_total" -lt "$FLOOR" ]; then
    echo "uitest-reachability: class を $n_total 本しか数えられなかった(下限 $FLOOR)= 列挙が壊れている。判定しない"
    exit 2
fi

declared_names=""
for row in "${DECLARED[@]}"; do
    nm="${row%%|*}"; why="${row#*|}"
    if [ "${#why}" -lt 12 ]; then
        echo "uitest-reachability: $nm の理由が短すぎる(12 文字以上)= 宣言になっていない"
        exit 2
    fi
    declared_names="$declared_names $nm"
done

# 走らせる側を探す木。`ios/UITests` 自身は**除く**(自分の中の言及で到達可能に見えてしまう)。
SEARCH=("$IOS/tools" "$ROOT/rc-backend/tools" "$ROOT/rc-backend/test" "$ROOT/.harness")
seen_dirs=0
for d in "${SEARCH[@]}"; do [ -d "$d" ] && seen_dirs=$((seen_dirs+1)); done
[ "$seen_dirs" -gt 0 ] || { echo "uitest-reachability: 探す木が1つも無い = 測っていない"; exit 2; }

unreachable=""; n_reach=0; n_decl=0
while IFS= read -r c; do
    [ -n "$c" ] || continue
    # ★探すのは **`RemoteMiniUITests/<class>`** という走る形の文字列。class 名だけを
    #   探すと、註や `.harness/evidence-*` の言及まで「到達可能」に数える ——
    #   最初に書いた版が其れで、**27/27 緑**という嘘を返した(結論を grep する検査)。
    #   実際の走らせ方は2通りだが、どちらも此の文字列を含む:
    #     `-only-testing:RemoteMiniUITests/X`(device-ui-check / 各対照)
    #     `CLASSES=("RemoteMiniUITests/X" …)`(composer-surface-control)
    # ★更に **名指しした file 自身が門に載っているか**まで見る。載っていなければ
    #   「人が撃てば走る」であって「門が走らせる」ではない —— 赤いまま出荷される。
    hit=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # ★照合は **repo 相対 path** で行う。basename だと ある .harness の smoke 台本 と
        #   ios/tools の同名の smoke 台本 が同じ物に見え、登録していない方が登録済みに化ける
        #   (Codex 2026-09-09。今の木に衝突は無いが、述語としては不健全)。
        #   `run-controls.sh` は ../ios/tools/… の形 の形で持つので、其の綴りで探す。
        rel="${f#$ROOT/}"
        if grep -q "^# controls-for:" "$f" 2>/dev/null \
           || grep -qF "${rel#rc-backend/}" "$ROOT/rc-backend/tools/run-controls.sh" 2>/dev/null \
           || grep -qF "../$rel" "$ROOT/rc-backend/tools/run-controls.sh" 2>/dev/null; then
            hit=1; break
        fi
    done <<< "$(grep -rl --include='*.sh' --include='*.mjs' -- "RemoteMiniUITests/$c" "${SEARCH[@]}" 2>/dev/null)"
    if [ "$hit" = "1" ]; then
        # ★到達可能なのに宣言も持っている = **腐った宣言**。放っておくと
        #   `DECLARED` は「走らせられない理由」から「免除の一覧」へ変わる
        #   (Codex 2026-09-09 の "exemption cemetery")。同じ形を今日
        #   `orphan-instrument-scan` が `no-operator:` の印で名指ししたばかり ——
        #   印は事実の宣言であって免除の札ではない。緑にせず測定不成立で止める。
        case " $declared_names " in
            *" $c "*)
                echo "uitest-reachability: $c は走るのに DECLARED にも載っている = 腐った宣言。宣言を消す事"
                exit 2 ;;
        esac
        n_reach=$((n_reach+1)); continue
    fi
    case " $declared_names " in
        *" $c "*) n_decl=$((n_decl+1)); continue ;;
    esac
    unreachable="$unreachable $c"
done <<< "$classes"

echo "uitest-reachability: class $n_total 本 / 走らせる物が在る $n_reach / 理由つきで宣言 $n_decl"
if [ -n "$unreachable" ]; then
    echo "★到達不能(どの台本も名指しせず、宣言も無い):"
    for c in $unreachable; do echo "    $c"; done
    echo "  直し方は2通り。どちらも file に残る:"
    echo "    走らせる = 対照の \`-only-testing:RemoteMiniUITests/<class>\` か CLASSES 配列に足す"
    echo "    宣言する = 此の門の DECLARED に「名前|なぜ走らせられないか(12 文字以上)」を足す"
    exit 1
fi
exit 0
