#!/bin/bash
# deploy-to-friday.sh — rc-backend を Friday(athenas)へ配備する入口。2026-08-25 新設。
#
# 中身は `deploy-to-edith.sh` そのもの。**env を被せて呼ぶだけの薄い殻**で、
# 順序も安全側の性質(仮置きで緑を取るまで本番の木に触らない / 失敗したら複製から戻す)も
# 全部あちらの物をそのまま使う。
#
# ★なぜ台本を「deploy-to-host.sh」に改名しなかったか(2026-08-25 の判断)
#   `deploy-to-edith` と `RC_EDITH_*` という名前を、対照テスト4本を含む 14 file が
#   **検査の錨として持っている**(実測: RC_EDITH_HOST が 17 箇所)。改名は錨 27 本の
#   付け替えを発生させる —— 2026-08-18 に文言の英語化で錨 40 本を付け替えた時と同じ代金を、
#   機能を1つも増やさずに払う事になる。名前は古いが、env は既にパラメータ化の機構として
#   効いている。**動く物の名前が古い事より、検査が外れる事の方が高くつく。**
#
# ★edith と違う所は3つだけ(どれもこの機体の実測に基づく):
#   1. serve の入口が 443 ではなく **9443**。443 は `~/Personal/resonance-os` が持っていて
#      AllowFunnel = true(公開インターネットへ露出)= 相乗りすると操縦面が公開される。
#      Funnel が使えるのは 443 / 8443 / 10000 の3つだけなので、9443 は構造的に公開できない。
#      入口ポートは plist の `RC_SERVE_PORT` が持つ(起動ラッパが読む)。ここでは指定しない
#      —— 配備台本は serve を触らないので、ここで持つと**読まれない設定**になる。
#   2. launchd の Label が `com.fleet.rc-backend`。Friday には未 load の `com.edith.*` が
#      23 本残っているので、同名前空間に生きた job を混ぜない。
#   3. HOME が /Users/athenas。
#
# 使い方:
#   bash tools/deploy-to-friday.sh            # 仮置き → Friday で緑 → 入れ替え → 再起動を観測
#   bash tools/deploy-to-friday.sh --dry-run  # 仮置きの rsync 差分だけ見る(転送しない)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ★ここから下は**1本の代入の連鎖**。途中に何も挟まない(空行もコメントも)。
#   2026-08-26 に2回続けて踏んだ: `\` の次の行がコメントだと、そこで連鎖が切れ、
#   **コメントより上の代入が全部 exec に届かなくなる**。bash は文句を言わない ——
#   上半分はただの一時代入として捨てられ、下半分だけが渡る。
#   症状は「Friday へ配備した筈が edith を叩いて 12 分後に timeout」。
#   届いている事は test/deploy-to-friday-controls.sh が env で実測している。
# ★`$HOME` も書かない。この殻は Jervis で走るので手元で展開され、
#   /Users/tomtim/... を Friday 上で探しに行く。宛先は向こうの絶対パスで書く。
RC_EDITH_HOST="${RC_FRIDAY_HOST:-athenas}" \
RC_EDITH_DIR="/Users/athenas/rc-backend" \
RC_EDITH_STAGE="/Users/athenas/rc-staging" \
RC_EDITH_RELEASES="/Users/athenas/rc-releases" \
RC_DEPLOY_MARK="/Users/athenas/.rc-backend/deploy-in-progress" \
RC_DEPLOY_LOCK="/Users/athenas/.rc-backend/deploy.lock" \
RC_JOB_LABEL="com.fleet.rc-backend" \
RC_REMOTE_LOG_DIR="/Users/athenas/Library/Logs/rc-backend" \
RC_COLDBOOT_PLIST="/Users/athenas/Library/LaunchAgents/com.fleet.rc-backend.plist" \
RC_COLDBOOT_USER="athenas" \
RC_OBSERVER_DEPLOY="$HERE/deploy-observer-to-friday.sh" \
exec bash "$HERE/deploy-to-edith.sh" "$@"
