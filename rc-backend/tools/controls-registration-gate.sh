#!/bin/bash
# 対照を**新設・改名**した commit が、全掃きの一覧(rc-backend/tools/run-controls.sh)を
# 触っていなければ止める。
#
# ── なぜ要るか(2026-08-06 の実測)────────────────────────────────────────
# 2026-08-05 21:41 の `a3d6b58` で「登録漏れ6本」をまとめて直した。その commit 以降、
# `run-controls.sh` は**一度も触られていない**。一方その翌日に書いた対照は8本 ——
# 8本とも未登録だった(disk 57 本 / 未登録 8 本、2026-08-06 実測)。
#
# 未登録が赤くなるのは全掃き(手で叩く物)を回した時だけで、commit の門は
# 「その commit が触れた対照は回す」ので緑を出し続ける。つまり登録を守っていたのは
# **私の記憶だけ**で、記憶に懸けた守りは1日で同じ形に戻った。
# 前回の教訓(「緑が何を測っているか言える事」)は言える様になる事しか要求していない。
# 言えても、次に書く対照が登録される訳ではない。だから機械に置く。
#
# ── 何を要求するか ──────────────────────────────────────────────────────
# 対照 file を**新設(A)または改名(R)**した commit は、同じ commit で
# `rc-backend/tools/run-controls.sh` も staged にする事。
# LOCAL / EDITH / EXCLUDED のどれに入れたかは**問わない**(EXCLUDED は理由必須 =
# 向こうの掟がすでに見ている)。此処が見るのは「触ったか」だけ。
#
# ── 何を要求しないか ────────────────────────────────────────────────────
# 既存の対照を**変更しただけ**の commit は止めない。登録は新設の時に1度決まれば足りる。
# 毎回止める門は「今回は飛ばす」を習慣にし、最後には門ごと外される。
#
# ★手書きの dir 一覧を**持たない**。名前(`*-control.sh` / `*-controls.sh`)だけで判る形に
#   した。走査 dir の外へ対照を置く事自体が別の穴(門がその対照を見ない)なので、
#   **どこに置いても**止める方が強い。この repo が5回踏んだ再発の真因は
#   「手で同期する一覧が2本」なので、2本目を作らない(pre-commit-gates.sh の注釈参照)。
#   代償: 対照ではない道具に同じ名前を付けると1度だけ誤って止まる(現在 3 本 ——
#   prove-control.sh / prove-all-controls.sh / run-controls.sh —— は既に追跡済なので
#   A でも R でもなく、当たらない)。その時は下の降ろす口に理由を書く。
#
# 対照 = rc-backend/test/controls-registration-gate-controls.sh
# 終了コード: 0=通す / 1=止める / 2=測れていない(git が読めない等。緑に丸めない)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REG="rc-backend/tools/run-controls.sh"

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "controls-registration-gate: git repo として読めない(測っていない)" >&2
    exit 2
}

# 新設・改名された対照。`--diff-filter=AR` の R は `R100<TAB>旧<TAB>新` なので最終列が新しい名前。
# (path に空白を含む file は此の repo に無い。入れたらこの awk から直す事)
added="$(git -C "$ROOT" diff --cached --name-status --diff-filter=AR \
    | awk '{print $NF}' \
    | grep -E '(^|/)[^/]*-controls?\.sh$' || true)"

[ -z "$added" ] && exit 0

if git -C "$ROOT" diff --cached --name-only | grep -qxF "$REG"; then
    exit 0
fi

# 降ろす口。理由を書かせる(空では降りない)。vacuous-gate の RC_VACUOUS_OK と同じ形。
if [ -n "${RC_CTLREG_OK:-}" ]; then
    echo "controls-registration-gate: 降ろした —— ${RC_CTLREG_OK}"
    exit 0
fi

echo "controls-registration-gate: ★commit しない: 新しい対照が全掃きの一覧に登録されていない" >&2
echo "$added" | sed 's/^/  新設: /' >&2
cat >&2 <<'EOS'
  直し方: rc-backend/tools/run-controls.sh を同じ commit で触る。
          既定は LOCAL_CTLS へ足す。edith の上でしか動かないなら EDITH_CTLS、
          外すなら EXCLUDED_CTLS へ理由を1行書いて入れる。
  なぜ止めるか: commit の門はこの commit が触れた対照しか回さないので、
          未登録でも緑が出る。未登録は全掃きを手で叩いた時にしか赤くならず、
          2026-08-06 の実測では8本が同じ形で一日ぶん溜まっていた。
  降ろす: RC_CTLREG_OK='理由' git commit ...(理由は出力に残る)
EOS
exit 1
