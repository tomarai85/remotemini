#!/bin/bash
# `tools/coldboot-chain.sh` の対照。
#
# なぜ要るか: これは**渡米後に物理で直せない物**を見張る道具なので、一番危ない
# 壊れ方は「見張っているつもりで何も見ていない」= 常に 0 を返す形。
# 実際に前身(deploy 9b の heredoc)がその形だった —— 注釈は 7 つの性質を名指し
# しているのに、コードは 4 つしか測っていなかった。**heredoc には対照が書けない**
# ので、ずれが在っても誰も気付けなかった。切り出した理由がこれ。
#
# ★入力の作り方(run-controls.sh 冒頭の規則 (1)「入力は本物の生成元から取る」):
#   - plist は**本物の PlistBuddy** に本物の plist を読ませる(偽の PlistBuddy を
#     書くと「PlistBuddy の出力の形についての思い込み」ごと緑になる)。
#     実測した形: 辞書 = `Dict {` で始まる複数行 / 鍵が無い = **stdout は空**で rc=1。
#   - `pmset -g` は実物を写した:
#       ` disksleep            10`
#       ` sleep                1 (sleep prevented by powerd, caffeinate, Dia, ...)`
#       ` displaysleep         30 (display sleep prevented by Dia)`
#       ` SleepDisabled\t\t1`
#     ★この 4 行が並ぶ事が本題。`/sleep/` の部分一致で書いた版は C11 で倒れる。
#   - `fdesetup status` の実物 = `FileVault is On.` / `FileVault is Off.`
#   - `defaults read` は鍵が無い時 **stdout が空**で rc=1(註は stderr)。
#
# 継ぎ目: `$COLDBOOT_SCRIPT` = 測る対象そのもの(prove-control.sh が旧版を差し込む口)。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CB="${COLDBOOT_SCRIPT:-$ROOT/tools/coldboot-chain.sh}"

pass=0; fail=0
chk() { # chk <名前> <期待rc> <実rc> <含むべき> <含んではいけない> <出力>
  local name=$1 want=$2 got=$3 must=$4 mustnot=$5 out=$6 bad=""
  [ "$got" = "$want" ] || bad="rc=$got (期待 $want)"
  # 日本語が直後に来る展開は必ず `${...}`(この repo で既に踏んでいる)
  [ -z "$must" ]    || printf '%s' "$out" | grep -qF -- "$must"    || bad="${bad}; 「${must}」が無い"
  [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot" || bad="${bad}; 「${mustnot}」が出ている"
  if [ -n "$bad" ]; then echo "NG  $name -- $bad"; fail=$((fail+1)); else echo "OK  $name"; pass=$((pass+1)); fi
}

SB="$(/usr/bin/mktemp -d -t coldboot)" || exit 2
trap '/bin/rm -rf "$SB" 2>/dev/null' EXIT INT TERM HUP

mkfake() { # mkfake <名前> <本文>
  printf '#!/bin/bash\n%s\n' "$2" > "$SB/$1"; /bin/chmod +x "$SB/$1"
}

# ── 偽の機械状態(既定は「全部繋がっている edith」)──────────────────────────
mkfake fdesetup_off 'echo "FileVault is Off."'
mkfake fdesetup_on  'echo "FileVault is On."'
mkfake fdesetup_mute 'exit 1'                       # 答えない = 測れない
mkfake defaults_ok  'echo "edith"'
mkfake defaults_none 'echo "The domain/default pair ... does not exist" >&2; exit 1'
mkfake defaults_other 'echo "tomtim"'

# 実物の `pmset -g` を写す。$1 = autorestart 行の値、$2 = sleep 行の値(空 = 行ごと出さない)
mk_pmset() { # mk_pmset <名前> <autorestart行 or ''> <sleep値 or ''>
  { printf '#!/bin/bash\n'
    printf 'cat <<'"'"'PM'"'"'\n'
    printf 'System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n standby              1\n Sleep On Power Button 1\n hibernatefile        /var/vm/sleepimage\n powernap             1\n disksleep            10\n'
    [ -n "$3" ] && printf ' sleep                %s (sleep prevented by powerd, caffeinate)\n' "$3"
    [ -n "$2" ] && printf ' autorestart          %s\n' "$2"
    printf ' displaysleep         30 (display sleep prevented by Dia)\n tcpkeepalive         1\n womp                 1\nPM\n'
  } > "$SB/$1"; /bin/chmod +x "$SB/$1"
}
mk_pmset pmset_ok   1 0
mk_pmset pmset_ar0  0 0
mk_pmset pmset_noar '' 0
mk_pmset pmset_sleep1 1 1
mk_pmset pmset_bad  0 1     # 両方壊れている(C17 用)
mkfake  pmset_mute 'exit 1'

# ── 本物の plist を置く(読むのは本物の PlistBuddy)────────────────────────
mk_plist() { # mk_plist <名前> <RunAtLoad の中身 or '-'> <KeepAlive の xml or '-'>
  local p="$SB/$1.plist" ral="$2" ka="$3" body=""
  [ "$ral" != "-" ] && body="${body}  <key>RunAtLoad</key><${ral}/>
"
  [ "$ka" != "-" ] && body="${body}  <key>KeepAlive</key>${ka}
"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict>' "$body" '</dict></plist>' > "$p"
  echo "$p"
}
P_OK="$(mk_plist good true '<true/>')"
P_RAL_FALSE="$(mk_plist ralfalse false '<true/>')"
P_NO_KA="$(mk_plist noka true '-')"
P_KA_DICT="$(mk_plist kadict true '<dict><key>SuccessfulExit</key><false/></dict>')"

# 既定 = 全部繋がっている状態。各対照は「1つだけ」差し替える(何が判定を動かしたか一意に)
run_cb() { # run_cb [KEY=VAL ...]
  env CB_FDESETUP="$SB/fdesetup_off" \
      CB_DEFAULTS="$SB/defaults_ok" \
      CB_PMSET="$SB/pmset_ok" \
      CB_PLIST="$P_OK" \
      CB_USER=edith \
      "$@" bash "$CB" 2>&1
}

# ── C1 全部繋がっていれば緑 ────────────────────────────────────────────────
out=$(run_cb); chk "C1 鎖が繋がっていれば rc=0" 0 $? "繋がっている(7/7)" "★" "$out"

# ── C2 FileVault On は赤 ───────────────────────────────────────────────────
out=$(run_cb CB_FDESETUP="$SB/fdesetup_on")
chk "C2 FileVault On -> 赤(rc=1)" 1 $? "FileVault: On" "繋がっている" "$out"

# ── C3 ★測れない事を赤にも緑にもしない ────────────────────────────────────
#    旧版(deploy 9b)は `|| echo '不明'` で**壊れている扱い**にしていた。
#    「fdesetup が答えない」と「FileVault が On」は別の事実で、対処も違う。
out=$(run_cb CB_FDESETUP="$SB/fdesetup_mute")
chk "C3 ★fdesetup が答えない -> 未測定(rc=2)" 2 $? "測れていない" "繋がっている" "$out"

# ── C4 ★自動ログイン無効は「未測定」ではなく赤 ────────────────────────────
#    非対称を明示的に固定する: 鍵が無い = 設定されていない = はっきり切れている。
out=$(run_cb CB_DEFAULTS="$SB/defaults_none")
chk "C4 ★自動ログイン無効 -> 赤(未測定に逃がさない)" 1 $? "自動ログイン: 無効" "" "$out"

# ── C5 別人の自動ログインも赤 + 欲しい名前を出す ───────────────────────────
out=$(run_cb CB_DEFAULTS="$SB/defaults_other")
chk "C5 別人の自動ログイン -> 赤" 1 $? "欲しいのは edith" "" "$out"

# ── C6 plist が無い時、依存する 2 つは**未測定**(赤を水増ししない)──────────
out=$(run_cb CB_PLIST="$SB/does-not-exist.plist")
chk "C6 plist 不在 -> 赤" 1 $? "plist が" "" "$out"
chk "C7 ★その時 RunAtLoad は未測定と言う(赤の水増しをしない)" 1 1 "RunAtLoad: plist が無いので測れない" "" "$out"

# ── C8 RunAtLoad が false ──────────────────────────────────────────────────
out=$(run_cb CB_PLIST="$P_RAL_FALSE")
chk "C8 RunAtLoad=false -> 赤" 1 $? "RunAtLoad: false" "" "$out"

# ── C9 ★★KeepAlive を実際に見ている事 ────────────────────────────────────
#    旧版(deploy 9b)は注釈で KeepAlive を名指ししながら**一度も読んでいなかった**。
#    切り出した目的そのものなので、ここが倒れないなら切り出した意味が無い。
out=$(run_cb CB_PLIST="$P_NO_KA")
chk "C9 ★KeepAlive が無い -> 赤(旧版はここを見ていなかった)" 1 $? "KeepAlive: 鍵が無い" "" "$out"

# ── C10 ★KeepAlive が辞書 = 自動で裁かない(未測定) ───────────────────────
#     `true でなければ赤` と書くと、正しい条件付き設定を毎回赤にする。
out=$(run_cb CB_PLIST="$P_KA_DICT")
chk "C10 ★KeepAlive が辞書 -> 未測定(rc=2)。赤にも緑にもしない" 2 $? "辞書の形" "繋がっている" "$out"

# ── C11 ★★`pmset -g` の部分一致の罠 ──────────────────────────────────────
#     本物の出力には `disksleep 10` `displaysleep 30` `SleepDisabled 1` が並ぶ。
#     `awk '/sleep/'` で書いた版は値を複数拾って比較が壊れる —— なのに
#     **緑の方向に壊れる事も在る**ので、正常系で固定しておく必要が在る。
out=$(run_cb); chk "C11 ★disksleep/displaysleep/SleepDisabled に釣られない" 0 $? "sleep: 0" "" "$out"

# ── C12 sleep が 0 でない = 電話から届かなくなる ───────────────────────────
out=$(run_cb CB_PMSET="$SB/pmset_sleep1")
chk "C12 ★sleep が非0 -> 赤(旧版はここも見ていなかった)" 1 $? "1 分で眠る" "" "$out"

# ── C13 autorestart=0 は赤 / 一覧に無いのは未測定 ──────────────────────────
out=$(run_cb CB_PMSET="$SB/pmset_ar0")
chk "C13 autorestart=0 -> 赤" 1 $? "autorestart: 0" "" "$out"
out=$(run_cb CB_PMSET="$SB/pmset_noar")
chk "C14 ★autorestart が一覧に無い -> 未測定(旧版は赤にしていた)" 2 $? "一覧に無い" "繋がっている" "$out"

# ── C15 pmset が答えない ───────────────────────────────────────────────────
out=$(run_cb CB_PMSET="$SB/pmset_mute")
chk "C15 pmset が答えない -> 未測定(rc=2)" 2 $? "測れていない" "" "$out"

# ── C16 ★壊れと未測定が同時に在る時は**壊れ**が勝つ ───────────────────────
#     ここを未測定(2)に丸めると、はっきり切れている鎖が「測れませんでした」に化ける。
out=$(run_cb CB_FDESETUP="$SB/fdesetup_on" CB_PMSET="$SB/pmset_noar")
chk "C16 ★壊れ + 未測定 -> 赤(1)。未測定に丸めない" 1 $? "鎖が切れている" "" "$out"

# ── C17 陰性対照: 判定が空振りしていない事 ─────────────────────────────────
#     C1 が緑を返すのは、判定が働いているからか、何も見ずに 0 を返すからか。
#     同じ道で 1 と 2 の両方が出る事(上)と合わせて初めて「見分けている」と言える。
#     ★初稿はここで `pmset_ar0`(autorestart だけ壊れ、sleep は 0 = 正常)を使い、
#       「繋がり 0/7」を期待して赤くなった —— 実際は `sleep: 0` が 1 件通るので 1/7。
#       **倒れたのは道具ではなく対照の期待値**。両方壊れた `pmset_bad` に直した。
out=$(run_cb CB_PLIST="$SB/does-not-exist.plist" CB_FDESETUP="$SB/fdesetup_on" CB_DEFAULTS="$SB/defaults_none" CB_PMSET="$SB/pmset_bad")
chk "C17 陰性対照: 全部壊れていれば繋がり 0 と言う" 1 $? "繋がり 0/" "" "$out"

echo "--- 合計: PASS $pass / FAIL $fail ---"
[ "$fail" = 0 ]
