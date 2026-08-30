#!/bin/bash
# controls-for: tools/fleet-plist-parity-check.sh
#
# fleet-plist-parity-check.sh の**挙動**対照。本物の friday は叩かない ——
# 叩けば検査の結果が本番の今の状態に依存し、「壊れているから赤い」と
# 「本番がたまたまずれているから赤い」を読者が区別できなくなる。
# `RC_FLEET_SSH` に偽の ssh を差して、向こうの出力をこちら側で作る。
#
# ★此の対照が守る一線は「**緑しか出せない計器**にしない」事。
#   検査が赤を出せない事は、対象が健全な事の証拠にはならない。
#   だから全項が「壊した時に赤が出るか」の形で書いてある。
#
#   C1 一致・全 load  → 緑(rc=0)
#   C2 中身がずれる   → 赤(rc=1)
#   C3 file が無い    → 赤(rc=1)
#   C4 一致but未load  → 赤(rc=1)  ★「置いた事は動いている事ではない」
#   C5 repo に無い job が向こうに居る → 赤(rc=1)。**消せとは言わない**
#   C6 ssh が失敗     → rc=2(測定不成立)。**0 にも 1 にも丸めない**
#   C7 向こうの出力が空 → rc=2
#   C8 repo の glob が 0 本 → rc=2(「全部一致」に見せない)
#   C9 雛形の1本が向こうに無い → 赤(除外が「見ていない」に化けていない事)
#   C12 雛形が repo に無い → 赤。ただし『基準が無い』と言う(値の食い違いに見せない)
#   C13 向こうの launchctl が動かない → rc=2(全件を「未登録」に化けさせない)
#
# 使い方: bash rc-backend/test/fleet-plist-parity-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
SUT="$HERE/tools/fleet-plist-parity-check.sh"
[ -f "$SUT" ] || { echo "測る対象が無い: $SUT"; exit 1; }

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
PDIR="$SB/plists"; mkdir -p "$PDIR"

# repo 側の見立て: 2本の実 plist。中身は何でもよく、md5 が決まっていれば足りる。
printf 'PLIST-A\n' > "$PDIR/com.fleet.rc-backend.plist"
printf 'PLIST-B\n' > "$PDIR/com.fleet.rc-ota.plist"
MA="$(md5 -q "$PDIR/com.fleet.rc-backend.plist")"
MB="$(md5 -q "$PDIR/com.fleet.rc-ota.plist")"

# 雛形。byte は比べないが**固定値は比べる**ので、砂場にも本物と同じ形の雛形が要る。
cat > "$PDIR/com.fleet.rc-health-observer.plist.example" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.fleet.rc-health-observer</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>__PATH__/tools/health-observer.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
</dict></plist>
XML

# 偽の ssh。`FAKE_OUT` の中身をそのまま向こうの出力として返し、`FAKE_RC` で失敗も作れる。
FAKE="$SB/fake-ssh.sh"
cat > "$FAKE" <<'EOF'
#!/bin/bash
[ "${FAKE_RC:-0}" -ne 0 ] && exit "$FAKE_RC"
# ★SUT は向こうを**2回**引く。1回目 = md5/登録/固定値、2回目 = launchd の有効定義
#   (`python3 -` に台本を流し込む形)。同じ塊を両方へ返すと、2回目が
#   「有効定義を読めない」に化けて全件が赤くなる(2026-08-30 に実際にそうなった)。
case "$*" in
    *python3*) printf '%s' "${FAKE_LOADED-}" ;;
    *)         printf '%s' "${FAKE_OUT:-}" ;;
esac
exit 0
EOF
chmod +x "$FAKE"

run() {  # run <期待 rc> <名前> ; FAKE_OUT / FAKE_RC は呼ぶ側が export する
    local want="$1" name="$2" out rc
    # 有効定義は既定で「全部一致」を作る(其の次元を測りたい対照だけが上書きする)。
    # ★自動生成にする理由: 既存の対照 14 本それぞれに手で書かせると、
    #   label を1つ足した日に**書き忘れた対照だけ**が赤くなる。
    if [ -z "${FAKE_LOADED_OVERRIDE-}" ]; then
        FAKE_LOADED="$(printf '%s\n' "${FAKE_OUT:-}" | awk '
            $1 == "MD5" { l[$3] = 1 }
            $1 == "REG" { l[$3] = 1 }
            $1 == "KV"  { l[$2] = 1 }
            END { for (k in l) print "LOADED " k " same" }' | sort)"
    else
        FAKE_LOADED="$FAKE_LOADED_OVERRIDE"
    fi
    export FAKE_LOADED
    out="$(RC_FLEET_PLIST_DIR="$PDIR" RC_FLEET_SSH="$FAKE" bash "$SUT" 2>&1)"; rc=$?
    LAST_OUT="$out"
    if [ "$rc" = "$want" ]; then ok "$name (rc=$rc)"; else ng "$name" "期待 rc=$want 実測 rc=$rc / $(printf '%s' "$out" | tail -1)"; fi
}

OBS="com.fleet.rc-health-observer"
# ★命令置換 `$(…)` は**末尾の改行を落とす**ので、雛形の行を $(obs_lines) で埋めると
#   直後の LOADED 行と1行に繋がり、偽の出力そのものが壊れる(初版で C1 が赤くなった原因)。
#   行を変数に持たせ、改行は此処で明示する。
# 雛形の1本は byte を比べない代わりに**固定値3つと実行 path**を比べる(Codex の指摘3)。
# 偽の出力もその欄を持たないと、健全な走行を再現できない。
OBS_LINES="MD5 deadbeef $OBS
REG yes $OBS
KV $OBS Label $OBS
KV $OBS StartInterval 600
KV $OBS RunAtLoad true
KV $OBS Prog1 /Users/athenas/rc-observer/tools/health-observer.sh"

# ── C1 一致・全 load ───────────────────────────────────────────────────────
export FAKE_RC=0
export FAKE_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
$OBS_LINES
REG yes com.fleet.rc-backend
REG yes com.fleet.rc-ota
"
run 0 "C1 一致して全部登録済なら緑"

# ── C2 中身がずれる ───────────────────────────────────────────────────────
export FAKE_OUT="LAUNCHCTL ok
MD5 ffffffffffffffffffffffffffffffff com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
$OBS_LINES
REG yes com.fleet.rc-backend
REG yes com.fleet.rc-ota
"
run 1 "C2 1本ずれたら赤"
printf '%s' "$LAST_OUT" | grep -q "ずれている" || ng "C2b ずれた事が文面に出る" "出ていない"
printf '%s' "$LAST_OUT" | grep -q "ずれている" && ok "C2b ずれた事が文面に出る"

# ── C3 向こうに file が無い ───────────────────────────────────────────────
# ★2026-08-30、Codex の指摘4で**契約を訂正した**。初版は rc=2(測定不成立)を期待し、
#   12/12 緑のまま**誤った契約を固定していた**。不在は「測れなかった」ではなく
#   「据えていない」という**確定した事実**なので、ずれ = rc=1。
#   rc=2 は ssh / md5 / 解析そのものが成立しない時だけに絞る。
export FAKE_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
$OBS_LINES
REG yes com.fleet.rc-backend
"
run 1 "C3 1本が向こうに無い = **ずれ**(1)。測定不成立ではない"

# ── C4 一致しているが load されていない ★中核 ────────────────────────────
export FAKE_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
$OBS_LINES
REG yes com.fleet.rc-backend
"
run 1 "C4 中身は一致でも未登録なら赤(置いた≠動いている)"
printf '%s' "$LAST_OUT" | grep -q "登録されていない" \
  && ok "C4b 未登録である事を名指しする" || ng "C4b 未 load を名指し" "文面に無い"

# ── C5 repo に無い job が向こうに居る ─────────────────────────────────────
export FAKE_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
MD5 abc123 com.fleet.rc-mystery
$OBS_LINES
REG yes com.fleet.rc-backend
REG yes com.fleet.rc-ota
"
run 1 "C5 repo に無い job が居たら赤"
if printf '%s' "$LAST_OUT" | grep -q "消さない"; then
    ok "C5b 見知らぬ job は**消さない**と明記する(所有者不明で消すのが最悪手)"
else ng "C5b 消さないと明記" "文面に無い"; fi

# ── C6 / C7 測れない ──────────────────────────────────────────────────────
export FAKE_RC=255
run 2 "C6 ssh が失敗したら 2(一致とは言わない)"
export FAKE_RC=0 FAKE_OUT=""
run 2 "C7 向こうの出力が空でも 2"

# ── C8 repo 側の glob が 0 本 ─────────────────────────────────────────────
EMPTY="$SB/empty"; mkdir -p "$EMPTY"
out="$(RC_FLEET_PLIST_DIR="$EMPTY" RC_FLEET_SSH="$FAKE" FAKE_OUT="x" bash "$SUT" 2>&1)"; rc=$?
[ "$rc" = "2" ] && ok "C8 repo に1本も無ければ 2(『全部一致』に見せない)" \
                || ng "C8 repo が空なら 2" "rc=$rc"

# ── C9 雛形の1本が向こうに無い ────────────────────────────────────────────
# 除外は「比べない」であって「見ない」ではない。居ない事は赤。
export FAKE_RC=0
export FAKE_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
REG yes com.fleet.rc-backend
REG yes com.fleet.rc-ota
"
run 1 "C9 雛形の1本が向こうに無ければ赤(除外が『見ていない』に化けない)"

# ── C12 雛形が repo に無い時 ──────────────────────────────────────────────
# ★`PlistBuddy` は file が無いと "File ... Will Create: <path>" を **stdout** に出して
#   exit 0 する。素朴に書くとその文字列が「雛形の値」として比較に入り、
#   **検査の入力が壊れているのに「雛形と違う」というもっともらしい赤**が出る。
#   入力の不在は、入力の不在として言わせる。
NOEX="$SB/noex"; mkdir -p "$NOEX"
cp "$PDIR/com.fleet.rc-backend.plist" "$NOEX/"
cp "$PDIR/com.fleet.rc-ota.plist" "$NOEX/"
export FAKE_RC=0
export FAKE_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
$OBS_LINES
REG yes com.fleet.rc-backend
REG yes com.fleet.rc-ota
"
out="$(RC_FLEET_PLIST_DIR="$NOEX" RC_FLEET_SSH="$FAKE" bash "$SUT" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "比べる基準が存在しない"; then
    ok "C12 雛形が無い時は『基準が無い』と言う(値の食い違いに見せない)"
else ng "C12 雛形が無い時の文面" "rc=$rc / $(printf '%s' "$out" | grep 観測 -m1; printf '%s' "$out" | grep -m1 health-observer)"; fi

# ── C13 launchctl 自体が動かない ──────────────────────────────────────────
# ★`launchctl list | awk` を使っていた初版は、launchctl が失敗すると awk が静かに 0 行を
#   返し、**全件が「未登録」**に化けた = 本番に対する嘘の赤。測れない事を測れないと言う。
export FAKE_OUT="LAUNCHCTL fail
"
run 2 "C13 向こうの launchctl が動かなければ 2(全件を未登録に化けさせない)"
printf '%s' "$LAST_OUT" | grep -q "嘘の赤" && ok "C13b 嘘の赤にしない事を文面で言う" \
                                          || ng "C13b 文面" "無い"

# ── C14-C16 launchd が実際に読み込んでいる定義(2026-08-30 追加)────────────
# ★此処までの対照は「disk が repo と一致」「登録済み」しか測っていなかった。
#   plist を書き換えて **bootout+bootstrap を忘れる**と、disk も登録も緑のまま
#   launchd は古い定義で走り続ける —— `kickstart` では定義は読み直されないので、
#   之は「うっかり」ではなく**起こる方が普通**の取り違え。
GREEN_OUT="LAUNCHCTL ok
MD5 $MA com.fleet.rc-backend
MD5 $MB com.fleet.rc-ota
$OBS_LINES
REG yes com.fleet.rc-backend
REG yes com.fleet.rc-ota
"

export FAKE_RC=0
export FAKE_OUT="$GREEN_OUT"
export FAKE_LOADED_OVERRIDE="LOADED com.fleet.rc-backend differ
LOADED com.fleet.rc-ota same
LOADED $OBS same"
run 1 "C14 disk は一致しているのに launchd が古い定義なら赤"
printf '%s' "$LAST_OUT" | grep -q "古い定義で走っている" \
    && ok "C14b 何が起きているかを名指しする(bootout+bootstrap の忘れ)" \
    || ng "C14b 文面" "$(printf '%s' "$LAST_OUT" | tail -1)"

export FAKE_LOADED_OVERRIDE=" "
run 2 "C15 有効定義を読めなければ 2(disk の一致を根拠に緑を出さない)"

export FAKE_LOADED_OVERRIDE="LOADED com.fleet.rc-ota same
LOADED $OBS same"
run 1 "C16 一覧に居ない label は緑にしない(黙って照合から抜けさせない)"

export FAKE_LOADED_OVERRIDE="LOADED com.fleet.rc-backend na
LOADED com.fleet.rc-ota same
LOADED $OBS same"
run 1 "C17 『比べられない』(na)も緑にしない —— 一致とは別物"
unset FAKE_LOADED_OVERRIDE

echo ""
echo "FLEET-PLIST-PARITY-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
