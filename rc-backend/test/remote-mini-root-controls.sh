#!/bin/bash
# controls-for: external:~/.claude/tools/remote-mini.sh
#   (道具は repo の外に在る。staged な path からは選べないので `external:` を付ける)
# remote-mini.sh の「宛先パス写像」対照。
#
# 何を守っているか(2026-08-03):
#   設計書 §8-2 は「edith 上で Tom が sudo mkdir -p /Users/tomtim を1回走らせる」という
#   人間ゲートだった。根拠は「resume には両機で同一絶対パスが要る」という **仮定**。
#   測ったら FALSE で(証拠 = ../.harness/evidence-2026-08-03/resume-scope-measurement.md)、
#   探索鍵は起動 cwd から作る slug ディレクトリ名だけだった。だから宛先を
#   $MIRROR_ROOT/<project-id>/worktree へ写し、記録を **写像後のパスから作った slug** に
#   置けば sudo は要らない。この対照はその置き換えが本当に成立しているかを見る。
#
#   同時に、写像を入れた事で新しく出来た事故経路も見る。宛先が「書けない場所」だった
#   偶然(= /Users/tomtim が作れない)が防波堤を兼ねていたのが、写像先は書ける場所なので
#   その偶然はもう働かない。rsync --delete の宛先が化ける事故がここで一番怖い。
#
# 冒頭で読む2行は tools/run-controls.sh のヘッダに在る。ここでの適用:
#   (1) 入力は本物の生成元から: slug 規則の対照は **実在する ~/.claude/projects の
#       ディレクトリ名と、その中の transcript が自分で書いた cwd** の対を使う。手書きしない。
#   (2) 直す前の版で赤になるか個別に見る: 各対照は `fix`(旧版で赤になる事まで確認する)/
#       `regression`(旧版でも緑のままである事を確認する)/ `mutant:<名前>`(新版から
#       その修正だけを外した変異体で赤になる事を確認する)を宣言する。
#
# 安全:
#   - 実 ssh / 実 rsync は使わない。偽物へ差し替える(REMOTE_MINI_SSH / REMOTE_MINI_RSYNC)。
#   - 偽 ssh は **tmux を含むコマンドを実行しない**。実 tmux `work` は Tom の作業場なので、
#     偽 ssh が手元でコマンドを走らせる以上、ここを塞がないと本物へ send-keys が飛ぶ。
#   - HOME は手元側・宛先側とも temp に差し替える。REMOTE_MINI_SKIP_SETTINGS=1 固定で
#     settings.json には一切触らない(実 ~/.claude/settings.json は hook で保護対象)。
#   - 作る物は全部 mktemp -d の下。終了時に消す。
#
# 終了コード: 0=全緑 / 1=1本でも赤。
set -uo pipefail

NEW="${REMOTE_MINI_SCRIPT:-$HOME/.claude/tools/remote-mini.sh}"
OLD="${REMOTE_MINI_OLD:-$HOME/.claude/tools/remote-mini.sh.bak.20260803-161222-pre-mirror-root}"
REAL_RSYNC="/usr/bin/rsync"

PASS=0; FAIL=0
FAILED_NAMES=()

ok(){   printf '  \033[32mgreen\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad(){  printf '  \033[31mRED\033[0m    %s -- %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); }

# ── 偽物を1式作る ────────────────────────────────────────────────
# $1 = 置き場。$FAKE/ssh, $FAKE/rsync, $FAKE/ssh.log, $FAKE/rsync.log
make_fakes(){
  local fake="$1"
  mkdir -p "$fake"
  cat > "$fake/ssh" <<'FAKESSH'
#!/bin/bash
# 偽 ssh: 宛先コマンドを **宛先 HOME を差し替えて手元で** 走らせる。
# 実 ssh と同じく cwd = 宛先の home から始める(`~` の展開バグを見えるようにする為)。
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2;;
    *) args+=("$1"); shift;;
  esac
done
cmd="${args[1]:-}"
printf '%s\n' "SSH $cmd" >> "$FAKE_SSH_LOG"
# 実 tmux は Tom の作業場。偽 ssh は手元で走るので、ここを通すと本物へ届く。
case "$cmd" in
  *tmux*|*osascript*|*curl*|*wget*)
    printf '%s\n' "BLOCKED $cmd" >> "$FAKE_SSH_LOG"; exit 1;;
esac
cd "$FAKE_REMOTE_HOME" || exit 1
HOME="$FAKE_REMOTE_HOME" /bin/bash -c "$cmd"
FAKESSH
  cat > "$fake/rsync" <<'FAKERSYNC'
#!/bin/bash
# 偽 rsync: `host:path` の形の被演算子を偽宛先 home 配下の実パスへ書き換えて実 rsync を呼ぶ。
out=()
for a in "$@"; do
  case "$a" in
    -*) out+=("$a"); continue;;
  esac
  case "$a" in
    */*:*|*:*)
      host="${a%%:*}"; path="${a#*:}"
      case "$host" in
        */*) out+=("$a");;
        *)   case "$path" in
               "~/"*) path="$FAKE_REMOTE_HOME/${path#\~/}";;
             esac
             out+=("$path");;
      esac
      ;;
    *) out+=("$a");;
  esac
done
printf '%s\n' "RSYNC ${out[*]}" >> "$FAKE_RSYNC_LOG"
exec /usr/bin/rsync "${out[@]}"
FAKERSYNC
  chmod +x "$fake/ssh" "$fake/rsync"
}

# 手元 slug を **script とは独立に** 作る。実装が滑ったら e2e 側が落ちるようにする為、
# ここでは script の slug_of を呼ばない。
py_slug(){ python3 -c '
import re,sys
sys.stdout.write(re.sub(r"[^-\w]", "-", sys.argv[1], flags=re.UNICODE).replace("_","-"))' "$1"; }

# 対照用の作業場を1つ組む。標準出力に「TMP LOCAL_HOME REMOTE_HOME WORKDIR SID SLUG」を返す。
setup_env(){
  local tmp; tmp="$(mktemp -d)"
  # mktemp -d は macOS で /var/folders/... を返すが、/var は /private/var へのリンク。
  # script 側は cwd を `pwd -P` で解決してから slug を作るので、ここで揃えないと
  # 対照だけが存在しない slug を見に行って「セッションが無い」で落ちる。
  tmp="$(cd "$tmp" && pwd -P)"
  local lh="$tmp/local" rh="$tmp/remote" wd="$tmp/work/proj"
  mkdir -p "$lh/.claude/projects" "$rh" "$wd"
  make_fakes "$tmp/fake"
  # 作業ツリーの中身(戻ってきたか判るように印を置く)
  printf 'v1\n' > "$wd/file.txt"
  mkdir -p "$wd/sub"; printf 'sub-v1\n' > "$wd/sub/deep.txt"
  local slug; slug="$(py_slug "$wd")"
  local sid="11111111-2222-3333-4444-555555555555"
  mkdir -p "$lh/.claude/projects/$slug"
  # transcript: 1行1 JSON。中身の cwd は敢えて **別のパス** にしておく。
  # 実測 #3 で「transcript 内の cwd は照合に使われない」と出ているので、写像後もこれで動く筈。
  {
    printf '{"type":"user","cwd":"/Users/somebody/elsewhere","sessionId":"%s"}\n' "$sid"
    printf '{"type":"assistant","cwd":"/Users/somebody/elsewhere","sessionId":"%s"}\n' "$sid"
    printf '{"type":"user","cwd":"/Users/somebody/elsewhere","sessionId":"%s"}\n' "$sid"
  } > "$lh/.claude/projects/$slug/$sid.jsonl"
  printf '%s %s %s %s %s %s\n' "$tmp" "$lh" "$rh" "$wd" "$sid" "$slug"
}

# script を対照環境で走らせる共通口。標準出力/エラーを $OUT に落とす。
run_rm(){
  local script="$1" tmp="$2" lh="$3" rh="$4"; shift 4
  HOME="$lh" \
  FAKE_SSH_LOG="$tmp/fake/ssh.log" FAKE_RSYNC_LOG="$tmp/fake/rsync.log" \
  FAKE_REMOTE_HOME="$rh" \
  REMOTE_MINI_SSH="$tmp/fake/ssh" REMOTE_MINI_RSYNC="$tmp/fake/rsync" \
  REMOTE_MINI_MIRROR_ROOT="$rh/mirror/remote-mini" \
  REMOTE_MINI_SKIP_SETTINGS=1 \
  /bin/bash "$script" "$@"
}

# script の関数だけ読み込んで1つ叩く(bottom の case は `status` で無害に抜ける)。
# 部分集合しか要らない対照はこちらが速い。必ず subshell で呼ぶ事(die が exit する)。
call_fn(){
  local script="$1" tmp="$2" rh="$3"; shift 3
  HOME="$tmp/local" \
  FAKE_SSH_LOG="$tmp/fake/ssh.log" FAKE_RSYNC_LOG="$tmp/fake/rsync.log" \
  FAKE_REMOTE_HOME="$rh" \
  REMOTE_MINI_SSH="$tmp/fake/ssh" REMOTE_MINI_RSYNC="$tmp/fake/rsync" \
  REMOTE_MINI_MIRROR_ROOT="${CALLFN_MIRROR_ROOT:-$rh/mirror/remote-mini}" \
  REMOTE_MINI_SKIP_SETTINGS=1 \
  /bin/bash -c '
    source "$1" status >/dev/null 2>&1
    shift
    "$@"
  ' _ "$script" "$@"
}
# 注: bash の `source file args` は sourced file の実行中だけ位置パラメータを差し替え、
# 終わったら復元する(実測済)。だから上の shift は呼び出し側の引数に効く。

# ══════════════════════════════════════════════════════════════════
# 対照本体。引数 $1 = 試す script。0=緑 / 非0=赤。
# ══════════════════════════════════════════════════════════════════

# 1. slug 規則。**本物の生成元**(実在する projects/ のディレクトリ名 × その中の
#    transcript 自身が書いた cwd)と突き合わせる。手書きの入力は使わない。
ctl_slug_real(){
  local script="$1" tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/fake"; make_fakes "$tmp/fake" >/dev/null 2>&1
  local pairs="$tmp/pairs.tsv"
  python3 - "$pairs" <<'PY'
import json, pathlib, sys
proj = pathlib.Path.home()/".claude/projects"
out = []
if proj.is_dir():
    for d in sorted(p for p in proj.iterdir() if p.is_dir()):
        cwd = None
        for js in sorted(d.glob("*.jsonl"), key=lambda f: f.stat().st_mtime, reverse=True)[:3]:
            try:
                with js.open(errors="replace") as f:
                    for i, line in enumerate(f):
                        if i > 400: break
                        try: r = json.loads(line)
                        except Exception: continue
                        if isinstance(r, dict) and r.get("cwd"):
                            cwd = r["cwd"]; break
            except Exception:
                pass
            if cwd: break
        if cwd:
            out.append((cwd, d.name))
pathlib.Path(sys.argv[1]).write_text("".join(f"{c}\t{n}\n" for c, n in out))
PY
  local n; n="$(wc -l < "$pairs" | tr -d ' ')"
  # 標本ゼロで緑になる対照は対照ではない。下限を置く。
  if [ "${n:-0}" -lt 10 ]; then
    echo "    (real pairs = ${n:-0} < 10 — 標本が足りない)" >&2
    rm -rf "$tmp"; return 1
  fi
  local bad=0 cwd want got
  while IFS=$'\t' read -r cwd want; do
    got="$(call_fn "$script" "$tmp" "$tmp/remote" slug_of "$cwd" 2>/dev/null)"
    [ "$got" = "$want" ] || bad=$((bad+1))
  done < "$pairs"
  echo "    (real pairs=$n mismatch=$bad)" >&2
  rm -rf "$tmp"
  [ "$bad" -eq 0 ]
}

# 2. project-id は basename では衝突する。~/Infra/mobile-work と ~/Personal/mobile-work は
#    同じ宛先を指してはいけない(指すと rsync --delete が互いを消す)。決定性も見る。
ctl_pid_collision(){
  local script="$1" tmp; tmp="$(mktemp -d)"; mkdir -p "$tmp/fake"; make_fakes "$tmp/fake" >/dev/null 2>&1
  local a b a2
  a="$(call_fn  "$script" "$tmp" "$tmp/remote" project_id "/Users/tomtim/Infra/mobile-work" 2>/dev/null)"
  b="$(call_fn  "$script" "$tmp" "$tmp/remote" project_id "/Users/tomtim/Personal/mobile-work" 2>/dev/null)"
  a2="$(call_fn "$script" "$tmp" "$tmp/remote" project_id "/Users/tomtim/Infra/mobile-work" 2>/dev/null)"
  rm -rf "$tmp"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] && [ "$a" = "$a2" ] \
    && case "$a" in mobile-work-*) true;; *) false;; esac
}

# 3. --delete の宛先の形。ここが緩いと1回で作業ツリーが消える。
ctl_mirror_shape(){
  local script="$1" tmp; tmp="$(mktemp -d)"; mkdir -p "$tmp/fake"; make_fakes "$tmp/fake" >/dev/null 2>&1
  local root="$tmp/remote/mirror/remote-mini" pid="proj-abcdef0123456789" rc=0
  # 通るべき1本
  call_fn "$script" "$tmp" "$tmp/remote" assert_mirror_path "$root/$pid/worktree" "$pid" >/dev/null 2>&1 || rc=1
  # 弾くべき物(1本でも通ったら赤)
  local badpath
  for badpath in "" "$root" "$root/$pid" "$root/$pid/worktree/x" "/" "/Users" "/Users/Shared" "$root/other/worktree"; do
    if call_fn "$script" "$tmp" "$tmp/remote" assert_mirror_path "$badpath" "$pid" >/dev/null 2>&1; then
      echo "    (accepted a destination it must refuse: '${badpath:-<empty>}')" >&2; rc=1
    fi
  done
  # pid が空でも通ってはいけない
  if call_fn "$script" "$tmp" "$tmp/remote" assert_mirror_path "$root//worktree" "" >/dev/null 2>&1; then
    echo "    (accepted an empty project id)" >&2; rc=1
  fi
  # 浅い MIRROR_ROOT は形が合っていても深さで弾く(`/x/<pid>/worktree` = 深さ3)
  if CALLFN_MIRROR_ROOT=/x call_fn "$script" "$tmp" "$tmp/remote" \
       assert_mirror_path "/x/$pid/worktree" "$pid" >/dev/null 2>&1; then
    echo "    (accepted a destination only 3 levels deep)" >&2; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# 4. sentinel。宛先が本当にこのプロジェクトの物かを、実物を読んで確かめてから --delete する。
ctl_sentinel(){
  local script="$1" tmp; tmp="$(mktemp -d)"; mkdir -p "$tmp/fake" "$tmp/local"; make_fakes "$tmp/fake" >/dev/null 2>&1
  local rh="$tmp/remote" root="$tmp/remote/mirror/remote-mini" pid="proj-abcdef0123456789" src="/Users/tomtim/Infra/mobile-work" rc=0
  mkdir -p "$root/$pid"
  # 一致 → 通る
  printf 'pid=%s\nsrc=%s\n' "$pid" "$src" > "$root/$pid/ID"
  call_fn "$script" "$tmp" "$rh" verify_sentinel "$pid" "fakehost" "$src" >/dev/null 2>&1 || rc=1
  # pid 違い → 止まる
  printf 'pid=%s\nsrc=%s\n' "other-0000000000000000" "$src" > "$root/$pid/ID"
  call_fn "$script" "$tmp" "$rh" verify_sentinel "$pid" "fakehost" "$src" >/dev/null 2>&1 && { echo "    (passed a pid mismatch)" >&2; rc=1; }
  # src 違い → 止まる(別プロジェクトが同じ宛先を掴んでいる場合)
  printf 'pid=%s\nsrc=%s\n' "$pid" "/Users/tomtim/Personal/mobile-work" > "$root/$pid/ID"
  call_fn "$script" "$tmp" "$rh" verify_sentinel "$pid" "fakehost" "$src" >/dev/null 2>&1 && { echo "    (passed a src mismatch)" >&2; rc=1; }
  # sentinel 不在 → 止まる
  rm -f "$root/$pid/ID"
  call_fn "$script" "$tmp" "$rh" verify_sentinel "$pid" "fakehost" "$src" >/dev/null 2>&1 && { echo "    (passed a missing sentinel)" >&2; rc=1; }
  rm -rf "$tmp"
  return "$rc"
}

# 5. $HOME / システム根の拒否。写像を入れた今、ここが唯一の防波堤になった
#    (昔は「宛先に /Users/tomtim を作れない」という permission の偶然が止めていた)。
#    拒否しただけでなく **rsync を1回も呼んでいない** 事まで見る。
ctl_home_refusal(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  local rc=0 out
  out="$(run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$lh" --dest fakehost 2>&1)"
  if [ $? -eq 0 ]; then echo "    (accepted \$HOME as the working dir)" >&2; rc=1; fi
  case "$out" in *refusing*) : ;; *) echo "    (no refusal message)" >&2; rc=1;; esac
  if [ -s "$tmp/fake/rsync.log" ]; then echo "    (rsync ran despite the refusal)" >&2; rc=1; fi
  rm -rf "$tmp"
  return "$rc"
}

# 6. 二重持ち出しの拒否。同じ会話の書ける複製が2つ出来ると、どちらが正本か決められなくなる。
ctl_double_checkout(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  local rc=0
  run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$wd" --dest fakehost >/dev/null 2>&1 || { echo "    (first out failed)" >&2; rm -rf "$tmp"; return 1; }
  if run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$wd" --dest fakehost >/dev/null 2>&1; then
    echo "    (a second out was accepted)" >&2; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# 7. 持ち出し中に手元の作業ツリーが動いていたら、黙って潰さず止まる(exit 3)。
ctl_back_tree_conflict(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  local rc=0
  run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$wd" --dest fakehost >/dev/null 2>&1 || { echo "    (out failed)" >&2; rm -rf "$tmp"; return 1; }
  printf 'local-edit\n' >> "$wd/file.txt"
  run_rm "$script" "$tmp" "$lh" "$rh" back --dir "$wd" >/dev/null 2>&1
  [ $? -eq 3 ] || { echo "    (back did not refuse with exit 3)" >&2; rc=1; }
  grep -q 'local-edit' "$wd/file.txt" || { echo "    (the local edit was destroyed)" >&2; rc=1; }
  rm -rf "$tmp"
  return "$rc"
}

# 8. 持ち出し中に **手元でも同じ会話が伸びていたら** 止まる。作業ツリーが無傷でも
#    会話だけ潰れる経路が在り、指紋だけでは見えない(2026-08-03 に足した門)。
ctl_back_session_conflict(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  local rc=0
  run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$wd" --dest fakehost >/dev/null 2>&1 || { echo "    (out failed)" >&2; rm -rf "$tmp"; return 1; }
  printf '{"type":"user","cwd":"%s","sessionId":"%s","local":"added-after-out"}\n' "$wd" "$sid" \
    >> "$lh/.claude/projects/$slug/$sid.jsonl"
  run_rm "$script" "$tmp" "$lh" "$rh" back --dir "$wd" >/dev/null 2>&1
  [ $? -eq 3 ] || { echo "    (back did not refuse with exit 3 on a longer local transcript)" >&2; rc=1; }
  grep -q 'added-after-out' "$lh/.claude/projects/$slug/$sid.jsonl" \
    || { echo "    (the local transcript was overwritten)" >&2; rc=1; }
  rm -rf "$tmp"
  return "$rc"
}

# 9. session_lines は **shell の大域オプションに依存せず** 必ず数字を返す。
#    会話の衝突ゲート(#8)は `[ "$local_lines" -gt "$sent_lines" ]` に乗っているので、
#    空文字が返ると整数エラーになり、門は止めるべき所で黙って通す。
#
#    ★訂正の記録(2026-08-03): 私は最初、旧実装 `wc -l < f | tr -d ' ' || echo 0` が
#    存在しないファイルで空文字を返す欠陥だと判定した。**それは誤診**だった —— 手元の
#    zsh で再現したが、script は先頭で `set -o pipefail` を立てているので、bash では
#    パイプの終段でなく wc の失敗が拾われて `|| echo 0` が発火し、旧実装でも 0 が返る。
#    残る本物の問題は「この関数の正しさが 100 行離れた `set` 行に依存している」事だけ。
#    だから対照は pipefail を **切った** 状態で測る。そこが両者を分ける唯一の点だから。
ctl_session_lines_number(){
  local script="$1" tmp; tmp="$(mktemp -d)"; mkdir -p "$tmp/fake"; make_fakes "$tmp/fake" >/dev/null 2>&1
  local n
  n="$(/bin/bash -c '
        source "$1" status >/dev/null 2>&1
        set +o pipefail
        shift
        "$@"' _ "$script" session_lines "$tmp/definitely-missing.jsonl" 2>/dev/null)"
  rm -rf "$tmp"
  case "$n" in ''|*[!0-9]*) return 1;; *) return 0;; esac
}

# 10. 壊れた transcript は名前を持たない。`.partial` のまま落とす。
#     「名前が付いている物は完全」を構造にしているので、ここが緩いと壊れた記録が正本になる。
ctl_landing_rejects_garbage(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  printf 'not json at all\nstill not json\n' > "$lh/.claude/projects/$slug/$sid.jsonl"
  local rc=0
  if run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$wd" --dest fakehost >/dev/null 2>&1; then
    echo "    (out succeeded with a transcript holding no valid records)" >&2; rc=1
  fi
  # 壊れた物が正体を得ていない事
  if find "$rh/.claude/projects" -name "$sid.jsonl" 2>/dev/null | grep -q .; then
    echo "    (a garbage transcript landed under its real name)" >&2; rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}

# 11. ★本命。宛先は $MIRROR_ROOT 配下で、記録は **写像後のパスから作った slug** に置かれる。
#     手元 slug の側には置かれない。往復して中身が戻る。
ctl_roundtrip_mapped(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  local rc=0
  run_rm "$script" "$tmp" "$lh" "$rh" out --dir "$wd" --dest fakehost >/dev/null 2>&1 \
    || { echo "    (out failed)" >&2; rm -rf "$tmp"; return 1; }

  local root="$rh/mirror/remote-mini"
  local pid rdir rslug
  pid="$(find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1 | xargs -r basename)"
  [ -n "$pid" ] || { echo "    (no project dir under the mirror root)" >&2; rm -rf "$tmp"; return 1; }
  rdir="$root/$pid/worktree"
  rslug="$(py_slug "$rdir")"

  [ -f "$rdir/file.txt" ] || { echo "    (the working tree did not arrive)" >&2; rc=1; }
  [ -f "$root/$pid/ID" ] || { echo "    (no ownership sentinel)" >&2; rc=1; }
  [ -f "$rh/.claude/projects/$rslug/$sid.jsonl" ] \
    || { echo "    (the transcript is not under the MAPPED slug)" >&2; rc=1; }
  [ -e "$rh/.claude/projects/$slug" ] \
    && { echo "    (the transcript was placed under the LOCAL slug — mapping did not happen)" >&2; rc=1; }
  # `~` を単一引用符で括ると宛先に literal `~` ディレクトリが出来る(旧実装の穴)
  [ -e "$rh/~" ] && { echo "    (a literal '~' directory was created on the destination)" >&2; rc=1; }

  # 向こうで編集 → 戻す → 手元に反映されている
  printf 'edited-on-mini\n' > "$rdir/file.txt"
  printf '{"type":"assistant","cwd":"%s","sessionId":"%s","remote":"added-on-mini"}\n' "$rdir" "$sid" \
    >> "$rh/.claude/projects/$rslug/$sid.jsonl"
  run_rm "$script" "$tmp" "$lh" "$rh" back --dir "$wd" >/dev/null 2>&1 \
    || { echo "    (back failed)" >&2; rc=1; }
  grep -q 'edited-on-mini' "$wd/file.txt" 2>/dev/null || { echo "    (the remote edit did not come home)" >&2; rc=1; }
  grep -q 'added-on-mini' "$lh/.claude/projects/$slug/$sid.jsonl" 2>/dev/null \
    || { echo "    (the remote transcript did not come home)" >&2; rc=1; }
  [ -f "$lh/.claude/remote-mini/$slug.json" ] && { echo "    (the state file survived a successful back)" >&2; rc=1; }
  rm -rf "$tmp"
  return "$rc"
}

# 12. 宛先が書けない時に **sudo を勧めない**。勧めた瞬間、消した筈の人間ゲートが戻る。
ctl_no_sudo_advice(){
  local script="$1" line; line="$(setup_env)"
  local tmp lh rh wd sid slug; read -r tmp lh rh wd sid slug <<<"$line"
  local rc=0 out
  # 書けない根を渡す(偽 ssh は手元で走るので、実在するが書けない場所を使う)
  out="$(HOME="$lh" FAKE_SSH_LOG="$tmp/fake/ssh.log" FAKE_RSYNC_LOG="$tmp/fake/rsync.log" \
        FAKE_REMOTE_HOME="$rh" REMOTE_MINI_SSH="$tmp/fake/ssh" REMOTE_MINI_RSYNC="$tmp/fake/rsync" \
        REMOTE_MINI_MIRROR_ROOT="/System/Library/remote-mini-cannot-write-here" \
        REMOTE_MINI_SKIP_SETTINGS=1 \
        /bin/bash "$script" out --dir "$wd" --dest fakehost 2>&1)"
  case "$out" in
    *sudo*) echo "    (the failure message still tells Tom to run sudo)" >&2; rc=1;;
  esac
  case "$out" in
    *REMOTE_MINI_MIRROR_ROOT*) : ;;
    *) echo "    (the failure message does not name the way out)" >&2; rc=1;;
  esac
  rm -rf "$tmp"
  return "$rc"
}

# ══════════════════════════════════════════════════════════════════
# 変異体: 新版から **その修正だけ** を外した写しを作る。対照が赤にならなければ、
# その対照はその欠陥について何も測っていない。
# ══════════════════════════════════════════════════════════════════
make_mutant(){
  local which="$1" dst="$2"
  cp "$NEW" "$dst" || return 1
  case "$which" in
    tilde)   # `~` を単一引用符で括る旧形へ戻す
      python3 - "$dst" <<'PY'
import pathlib, sys, re
p = pathlib.Path(sys.argv[1]); s = p.read_text()
new = s.replace(
  '''$SSH_BIN -o ConnectTimeout=10 "$dest" "mkdir -p \\"\\$HOME/.claude/projects/$rslug\\""''',
  '''$SSH_BIN -o ConnectTimeout=10 "$dest" "mkdir -p '~/.claude/projects/$rslug'"''')
if new == s: sys.exit(9)
p.write_text(new)
PY
      ;;
    lines)   # session_lines を空文字を返す旧形へ戻す
      python3 - "$dst" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
new = s.replace(
  '''session_lines(){ local n; n="$(wc -l < "$1" 2>/dev/null | tr -d ' ')"; echo "${n:-0}"; }''',
  '''session_lines(){ wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }''')
if new == s: sys.exit(9)
p.write_text(new)
PY
      ;;
    newermt) # fingerprint を「修正前」へ戻す = non-git ツリーで常に sha256("") を返す形
      python3 - "$dst" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = r'''    local n; n="$(find "$d" -type f -not -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${n:-0}" -eq 0 ]; then
      # 本当に空のツリー。失う物が無いので、これは定数で構わない。
      echo "empty-tree"; return 0
    fi
    out="$(find "$d" -type f -not -path '*/.git/*' -print0 2>/dev/null \
           | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
  fi
  # ファイルが在るのに空入力のハッシュが返った = 指紋を採れていない。定数を返して
  # 「変化なし」と読ませるのが一番危ないので、比較が必ず外れる値を返して門を閉じる側へ倒す。
  if [ -z "$out" ] || [ "$out" = "$EMPTY_SHA256" ]; then
    echo "unfingerprintable-$(date +%s)-$$"; return 0
  fi
  echo "$out"'''
new = r'''    out="$(find "$d" -type f -not -path '*/.git/*' -newermt '1970-01-01' -print0 2>/dev/null \
           | sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
  fi
  echo "$out"'''
if old not in s: sys.exit(9)
p.write_text(s.replace(old, new))
PY
      ;;
    landing) # 着地検証を抜く = 1件も JSON でない記録でも本名を与えて受理する
      python3 - "$dst" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '''if good == 0:
    print("  landing: no valid records after repair", file=sys.stderr); sys.exit(1)'''
new = '''if False:
    pass'''
if old not in s: sys.exit(9)
p.write_text(s.replace(old, new))
PY
      ;;
    dup)     # 二重持ち出しの拒否を抜く
      python3 - "$dst" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '''  [ -f "$STATE_DIR/$slug.json" ] && die "this directory is already checked out'''
i = s.find(old)
if i < 0: sys.exit(9)
j = s.find('same session."', i)
if j < 0: sys.exit(9)
p.write_text(s[:i] + '  :' + s[j+len('same session."'):])
PY
      ;;
    sessguard) # 会話の行数による衝突ゲートを抜く
      python3 - "$dst" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = '''  if [ -n "$sent_lines" ] && [ "$sent_lines" != "0" ] && [ "$local_lines" -gt "$sent_lines" ]; then'''
new = '''  if false; then'''
if old not in s: sys.exit(9)
p.write_text(s.replace(old, new))
PY
      ;;
    *) return 1;;
  esac
}

# ══════════════════════════════════════════════════════════════════
# 走らせる。列 = 対照名 / 旧版での期待(fix=赤になる筈 / regression=緑のまま / mutant:<名>)
# ══════════════════════════════════════════════════════════════════
#
# ★ なぜ一部が `fix`(= 旧版で赤)ではなく `mutant:` なのか(2026-08-03、測って直した)
#
#   旧版は `require_same_path()` を持つ = 宛先に **同一の絶対パス**が無ければ out を拒む。
#   この試験系の宛先は偽 HOME なので、旧版の out は必ずそこで落ちる。
#   すると「out が完了した後で初めて働く門」(二重持ち出し・戻しの2つの衝突ゲート・
#   記録の着地検証)は、**旧版では一度も実行されない**。旧版で赤くはなるが、赤の理由は
#   「その門が無いから」ではなく「その手前で落ちたから」——つまり当の欠陥を測っていない。
#   run-controls.sh 冒頭の規則(2)が禁じているのは正にこれなので、これらは
#   新版から**その門だけを抜いた変異体**に対して測る。旧版で測れるのは、写像そのものの
#   不在が原因で落ちる対照(slug / project-id / mirror 形 / sentinel / 往復)だけ。
#
CONTROLS=(
  "ctl_slug_real|fix"
  "ctl_pid_collision|fix"
  "ctl_mirror_shape|fix"
  "ctl_sentinel|fix"
  "ctl_home_refusal|regression"
  "ctl_double_checkout|mutant:dup"
  "ctl_back_tree_conflict|mutant:newermt"
  "ctl_back_session_conflict|mutant:sessguard"
  "ctl_session_lines_number|mutant:lines"
  "ctl_landing_rejects_garbage|mutant:landing"
  "ctl_roundtrip_mapped|fix"
  "ctl_no_sudo_advice|fix"
)

echo "remote-mini root-mapping controls"
echo "  new: $NEW"
echo "  old: $OLD"
[ -f "$NEW" ] || { echo "  対象の script が無い: $NEW" >&2; exit 1; }
[ -x "$REAL_RSYNC" ] || { echo "  実 rsync が無い: $REAL_RSYNC" >&2; exit 1; }
echo

MUTANT_DIR="$(mktemp -d)"
trap 'rm -rf "$MUTANT_DIR"' EXIT

echo "── 新版(全部緑であるべき) ─────────────────────────"
for entry in "${CONTROLS[@]}"; do
  name="${entry%%|*}"
  if "$name" "$NEW"; then ok "$name"; else bad "$name" "新版で赤"; fi
done

echo
echo "── 対照の対照(この検査自体が効いているか) ─────────"
for entry in "${CONTROLS[@]}"; do
  name="${entry%%|*}"; expect="${entry##*|}"
  case "$expect" in
    fix)
      if [ ! -f "$OLD" ]; then
        printf '  \033[33mskip\033[0m   %s -- 旧版が無い(%s)\n' "$name" "$OLD"
        continue
      fi
      if "$name" "$OLD" >/dev/null 2>&1; then
        bad "$name(旧版)" "旧版でも緑 = この欠陥について何も測っていない"
      else
        ok "$name(旧版で赤)"
      fi
      ;;
    regression)
      if [ ! -f "$OLD" ]; then
        printf '  \033[33mskip\033[0m   %s -- 旧版が無い\n' "$name"
        continue
      fi
      if "$name" "$OLD" >/dev/null 2>&1; then
        ok "$name(旧版でも緑 = 退行なし)"
      else
        bad "$name(旧版)" "旧版で赤 = regression 宣言が誤りか、旧版が既に壊れていた"
      fi
      ;;
    mutant:*)
      which="${expect#mutant:}"
      mut="$MUTANT_DIR/$which.sh"
      if ! make_mutant "$which" "$mut"; then
        bad "$name(変異体)" "変異体を作れなかった(置換対象の行が見つからない)"
        continue
      fi
      if "$name" "$mut" >/dev/null 2>&1; then
        bad "$name(変異体 $which)" "修正を外しても緑 = この対照は効いていない"
      else
        ok "$name(変異体 $which で赤)"
      fi
      ;;
  esac
done

echo
echo "green=$PASS red=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '赤: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
exit 0
