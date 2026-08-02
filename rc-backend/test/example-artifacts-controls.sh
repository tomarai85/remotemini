#!/bin/bash
# 「見本(`*.example` / plist)が、据える瞬間に**初めて**壊れている事が判る」を潰す対照。
#
# ── なぜ要るか(2026-08-02、実物で踏んだ) ────────────────────────────────
# Phase P① で `tools/com.fleet.rc-health-observer.plist.example` を書いた。
# 一度も構文を通していなかったので、3つ落としていた:
#   1. Apple の DOCTYPE 行が無い(repo の実物 2 枚は持っている)
#   2. XML コメントの中に `-` が二つ連続(`--inject-fail` と書いた) = XML 違反
#   3. 差し替え箇所を `<台本の絶対パス>` と書いた = **タグに化けて**閉じ対応が崩れた
# どれも `plutil -lint` が一発で言う。**言わせていなかっただけ**。
#   ★型: 見本は「読む物」なので実行されず、壊れていても誰も気付かない。
#     `method_a_verification_script_that_never_ran` と同じ病気の、静かな方の顔。
#
# ★族を**書き写さない**: plist は glob で拾い、設定の鍵は台本 `health-observer.sh` から
#   取り出す。伸ばす方向(見本を1枚足す)に、この file を1文字も直さずに追随する事。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 陰性対照が「壊した写し」を指すための差し替え口。既定は本体の木。
TOOLS_DIR="${RC_EXAMPLE_TOOLS_DIR:-$ROOT/tools}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

# ══ A) plist の見本と実物が、全部 `plutil -lint` を通る ═══════════════════
# 一覧を持たずに glob で拾う。0 枚なら**赤で止まる**(黙って緑にしない)。
plists=()
for f in "$TOOLS_DIR"/*.plist "$TOOLS_DIR"/*.plist.example; do
    [ -e "$f" ] && plists+=("$f")
done
if [ "${#plists[@]}" -ge 1 ]; then
    ok "A0 plist を ${#plists[@]} 枚見つけた(一覧を写していない)"
else
    ng "A0 plist の発見" "$TOOLS_DIR に1枚も無い — glob か置き場所が変わった"
fi
for f in "${plists[@]:-}"; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    if out="$(plutil -lint "$f" 2>&1)"; then
        ok "A1 $b が plutil -lint を通る"
    else
        ng "A1 $b の構文" "$(printf '%s' "$out" | tr '\n' '/')"
    fi
    # ★`plutil -lint` だけでは足りない(2026-08-02 実測)。実際に踏んだ欠陥 #2 —
    #   XML コメント中の `-` 二連 — を **plutil は OK と言う**。xmllint だけが落とす:
    #     plutil : OK / xmllint: parser error : Comment must not contain '--'
    #   plist の値としては正しいが XML としては壊れている、という隙間。
    #   陰性対照を撃った時にこの検査だけ赤くならず、**器の方が弱い**と判った。
    if command -v xmllint >/dev/null 2>&1; then
        if out="$(xmllint --noout "$f" 2>&1)"; then
            ok "A3 $b が xmllint も通る(XML として壊れていない)"
        else
            ng "A3 $b の XML" "$(printf '%s' "$out" | head -2 | tr '\n' '/')"
        fi
    fi
    # DOCTYPE は plutil が無くても通す。**実物2枚が持っている形**に揃える。
    if head -3 "$f" | grep -q 'DOCTYPE plist PUBLIC'; then
        ok "A2 $b に Apple の DOCTYPE 行がある"
    else
        ng "A2 $b の DOCTYPE" "1-3 行目に DOCTYPE が無い(実物の plist は持っている)"
    fi
done

# ══ B) 設定の見本が、台本の**知っている鍵**しか使っていない ═══════════════
# 鍵の一覧を写さない: 台本 `health-observer.sh` の `${RC_HEALTH_…:-}` から取り出す。
# 見本に typo があると、その行は黙って無視される = 「設定したのに効かない」の温床。
CONF="$TOOLS_DIR/observer.conf.example"
OBS="$TOOLS_DIR/health-observer.sh"
if [ -f "$CONF" ] && [ -f "$OBS" ]; then
    known="$(grep -o 'RC_HEALTH_[A-Z_]*' "$OBS" | sort -u)"
    used="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$CONF" | sort -u)"
    if [ -n "$known" ] && [ -n "$used" ]; then
        ok "B0 鍵の一覧を台本から取り出せた(台本 $(printf '%s' "$known" | wc -l | tr -d ' ')件 / 見本 $(printf '%s' "$used" | wc -l | tr -d ' ')件)"
    else
        ng "B0 鍵の取り出し" "台本側=[$known] 見本側=[$used] — どちらかが空。下の照合は当てにならない"
    fi
    unknown="$(comm -23 <(printf '%s\n' "$used") <(printf '%s\n' "$known"))"
    if [ -z "$unknown" ]; then
        ok "B1 見本の鍵が全部、台本の読む鍵と一致する"
    else
        ng "B1 見本の鍵" "台本が読まない鍵: $(printf '%s' "$unknown" | tr '\n' ' ')— typo なら黙って無視される"
    fi
    # ドットで読まれる物なので、shell として読めない = 台本が起動段で死ぬ。
    # ★ここに逆引用符を書かない: 二重引用符の中では**コマンド置換として実行される**。
    HOMEDIR="$(mktemp -d /tmp/exart.XXXXXX)"
    if ( HOME="$HOMEDIR"; . "$CONF" ) >/dev/null 2>&1; then
        ok "B2 見本がドットで読める(台本と同じ読み方)"
    else
        ng "B2 見本の読み込み" "shell 構文として落ちる — 台本は設定を読む所で死ぬ"
    fi
    [ -d "$HOMEDIR" ] && rmdir "$HOMEDIR" 2>/dev/null
else
    ng "B 設定の見本" "$CONF か $OBS が無い"
fi

# ══ C) 設計文書が指す repo 内の path が、実在する ═══════════════════════
# 見本と同じ族: **読む為の物は実行されないので、壊れていても誰も気付かない**。
# 手順書が改名で置き去りにされると、次に据える人が**据える瞬間に初めて**気付く。
#   実測 2026-08-02: DESIGN.md + HANDOFF に repo 相対の参照が 162件・不在 0件。
#   同日に1件、`tools/rc-pane-register.sh` と裸で書いてあったが基準が `~/.claude` の方
#   だった物を見つけて絶対の形へ直した(この検査は `~` 始まりを対象外にする)。
DOC_DIR="${RC_EXAMPLE_DOC_DIR:-$(cd "$ROOT/.." && pwd)}"
c_out="$(RC_C_ROOT="$ROOT" RC_C_DOCS="$DOC_DIR" python3 - <<'PY' 2>&1
import re, os, sys
repo=os.environ["RC_C_ROOT"]; docs_dir=os.environ["RC_C_DOCS"]
docs=["DESIGN.md","HANDOFF-NEXT-SESSION.md"]
# 逆引用符で囲まれた repo 相対 path だけを見る。`~/…` や `/…` は別の木なので対象外。
pat=re.compile(r'`((?:src|test|tools)/[A-Za-z0-9_./*-]+)`')
found=0; missing=[]
for d in docs:
    p=os.path.join(docs_dir,d)
    if not os.path.exists(p): print(f"NODOC {d}"); sys.exit(0)
    for ln,l in enumerate(open(p,encoding="utf8"),1):
        for m in pat.finditer(l):
            q=m.group(1)
            if "*" in q or q.endswith("/"): continue   # glob 形は実在を問えない
            if os.path.exists(os.path.join(repo,q)): found+=1
            else: missing.append(f"{d}:{ln} {q}")
print(f"FOUND {found}")
for x in missing[:8]: print(f"MISS {x}")
print(f"NMISS {len(missing)}")
PY
)"
if printf '%s' "$c_out" | grep -q '^NODOC'; then
    ng "C0 設計文書の発見" "$(printf '%s' "$c_out" | grep '^NODOC') — 置き場所が変わった"
else
    c_found="$(printf '%s' "$c_out" | sed -n 's/^FOUND //p')"
    c_miss="$(printf '%s' "$c_out" | sed -n 's/^NMISS //p')"
    if [ "${c_found:-0}" -ge 20 ] 2>/dev/null; then
        ok "C0 設計文書から repo 相対の参照を ${c_found}件 取り出せた"
    else
        ng "C0 参照の取り出し" "取れたのは ${c_found:-空}件 — 正規表現か書式が変わった。下の照合は当てにならない"
    fi
    if [ "${c_miss:-1}" = "0" ]; then
        ok "C1 設計文書の指す path が全部実在する"
    else
        ng "C1 実在しない参照 ${c_miss}件" "$(printf '%s' "$c_out" | grep '^MISS' | sed 's/^MISS //' | tr '\n' ' ')"
    fi
fi

# ══ D) plist の Label が、file 名とも手順書とも一致する ═══════════════════
# `launchctl kickstart <label>` は**存在しない label を静かに何もしない**形で受ける事が在る。
# file を改名して Label を直し忘れる(逆も)と、手順書どおり叩いても何も起きない。
#   ここで「文書に出てくる com.* を全部 plist と突き合わせる」形にはしない —— edith には
#   私の物でない job(`com.edith.gateway` 等)が居て、それを欠陥として数えるのは嘘になる。
#   問えるのは**この repo が持つ plist について**の一致だけ。
for f in "${plists[@]:-}"; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"
    stem="${b%.example}"; stem="${stem%.plist}"
    label="$(grep -A1 '<key>Label</key>' "$f" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' | head -1)"
    if [ -z "$label" ]; then
        ng "D1 $b の Label" "Label キーが読めない"
    elif [ "$label" = "$stem" ]; then
        ok "D1 $b の Label が file 名と一致($label)"
    else
        ng "D1 $b の Label" "Label=$label / file 名=$stem — 改名の片側だけが直っている"
    fi
    # 手順書に一度も出てこない plist = 据え方が書かれていない。
    if [ -n "$label" ] && [ -f "$DOC_DIR/DESIGN.md" ]; then
        if grep -qF "$label" "$DOC_DIR/DESIGN.md" "$DOC_DIR/HANDOFF-NEXT-SESSION.md" 2>/dev/null; then
            ok "D2 $label が手順書に出てくる"
        else
            ng "D2 $label" "設計文書のどこにも出てこない — 据え方が書かれていない plist"
        fi
    fi
done

echo ""
echo "EXAMPLE-ARTIFACTS-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
