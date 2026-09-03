#!/bin/bash
# 公開用の写しを作って(任意で)push する(2026-09-03、Tom の裁定「private と public を両方作る」)。
#
# 形: 生の repo は**触らない**。捨てクローン → `git filter-repo --replace-text`(規則 + 走行時の hostname)→
#     書き換え後の clone に PII 検出器(作業木 + 履歴)→ 秘密の走査 → 緑なら public remote へ push。
#
# ★filter-repo は入力が同じなら出力の sha も同じ = 同じ規則で再変換すれば、public 側には差分だけが
#   fast-forward で乗る。規則を変えた時だけ履歴が変わる(其の時は `--force` を明示する)。
# ★生の repo に public の remote を**登録しない**。public へ書くのは此の台本の一時 clone だけ。
#   生の repo から誤って public へ push する事故を、remote が存在しない事で塞ぐ。
#
# 使い方:
#   bash .harness/publish-public.sh                 # 変換 + 検査だけ(push しない)
#   bash .harness/publish-public.sh --push <url>    # 検査が緑なら push(fast-forward のみ)
#   bash .harness/publish-public.sh --push <url> --force   # 規則を変えた時だけ
set -uo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo"; exit 2; }
RULES="$ROOT/.harness/redaction-rules.txt"
PUSH=""; FORCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --push) PUSH="${2:-}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done
[ -s "$RULES" ] || { echo "rules missing: $RULES"; exit 2; }
command -v git-filter-repo >/dev/null 2>&1 || { echo "git-filter-repo が無い"; exit 2; }
if grep -vqE '==>' "$RULES"; then echo "★規則 file に ==> の無い行が在る(註釈は禁止)"; exit 2; fi

T="$(mktemp -d "${TMPDIR:-/tmp}/publish-public.XXXXXX")" || exit 2
[ "${KEEP:-0}" = "1" ] || trap 'rm -rf "$T"' EXIT INT TERM HUP
echo "==> sandbox: $T"
git clone -q --no-hardlinks "$ROOT" "$T/clone" || { echo "clone failed"; exit 2; }
cp "$RULES" "$T/rules.txt"
HOST_SELF="$(hostname -s 2>/dev/null || true)"
if [ -n "$HOST_SELF" ] && [ "${#HOST_SELF}" -ge 6 ]; then
  printf 'regex:(?i)%s==>host-redacted\n' "$(printf '%s' "$HOST_SELF" | sed 's/[.[\*^$()+?{}|\\/]/\\&/g')" >> "$T/rules.txt"
fi
( cd "$T/clone" && git filter-repo --replace-text "$T/rules.txt" --force --quiet ) || { echo "filter-repo failed"; exit 2; }
echo "==> rewritten: $(git -C "$T/clone" rev-list --count HEAD) commits, HEAD $(git -C "$T/clone" rev-parse --short HEAD)"

# 1. PII 検出器(作業木 + 履歴)。赤なら push しない
pii_out="$(cd "$T/clone" && bash rc-backend/tools/check-no-pii.sh 2>&1)"; pii_rc=$?
echo "==> check-no-pii: exit $pii_rc"; [ "$pii_rc" = 0 ] || { printf '%s\n' "$pii_out" | tail -12; echo "PUBLISH BLOCKED (pii)"; exit 1; }

# 2. 秘密の走査。2 段: 艦隊の構造規則(`~/bin/secret-sweep.py <root>`、作業木)+ 履歴の全 revision に
#    「形 + 本体」の正規表現(鍵・token・webhook・秘密鍵)。検査 fixture の伏字(本体が AAAA…)は除く。
#    道具が無ければ止める(無い = 測れていない、を緑にしない)。
[ -f "$HOME/bin/secret-sweep.py" ] || { echo "★secret-sweep.py が無い = 秘密を測れていない"; exit 2; }
sec_out="$(cd "$T/clone" && python3 "$HOME/bin/secret-sweep.py" . 2>&1)"; sec_rc=$?
echo "==> secret-sweep(tree): exit $sec_rc"; [ "$sec_rc" = 0 ] || { printf '%s\n' "$sec_out" | tail -12; echo "PUBLISH BLOCKED (secret)"; exit 1; }
SECRET_PAT='(AKIA[0-9A-Z]{16}|sk-(proj-|ant-)?[A-Za-z0-9_-]{20,}|gh[pos]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |OPENSSH |EC |DSA |PGP )?PRIVATE KEY|hooks\.slack\.com/services/T[A-Za-z0-9]+/B|discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{35}|ya29\.[A-Za-z0-9_-]{30,}|eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,})'
hist_hits="$(cd "$T/clone" && git grep -ohIE "$SECRET_PAT" $(git rev-list --all) 2>/dev/null | grep -vE 'AAAAAAAA|0000-0000|1111-2222' | sort -u)"
if [ -n "$hist_hits" ]; then
  echo "==> secret(history): 本物の形をした物が在る"; printf '%s\n' "$hist_hits" | head -8 | cut -c1-60; echo "PUBLISH BLOCKED (secret in history)"; exit 1
fi
echo "==> secret(history): 0"

echo "PUBLISH CLEAN"
[ -n "$PUSH" ] || { echo "(push しない。--push <url> で送る)"; exit 0; }

# 3. push(fast-forward のみ。規則を変えた時だけ --force)
( cd "$T/clone" && git remote add public "$PUSH" && git push ${FORCE:+--force} public HEAD:main ) || { echo "push failed"; exit 1; }
echo "PUSHED $(git -C "$T/clone" rev-parse --short HEAD) -> $PUSH"
