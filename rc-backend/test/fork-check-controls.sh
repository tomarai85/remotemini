#!/bin/bash
# controls-for: tools/live-fork-check.mjs
# `tools/live-fork-check.mjs` が**計器として壊れていないか**を測る対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# あの台本は上限が明けた夜に**1回だけ**撃つ物で、撃ち直しが利かない。その1回で
# 「○○が判った」と書くなら、**判らない時にちゃんと判らないと言う**事を先に見ておく。
# 本物の claude を使うと上限を食うので、ここでは**偽の claude** を4通りに振る舞わせる:
#
#   本物どおり  : resume=同じ sid に追記 / fork=新 sid の別 file  → 台本は **0**
#   壊れた側    : resume も新 sid の別 file(= 追記しない)        → 台本は **1**(緑にしない)
#   上限        : is_error + 上限の告知                            → 台本は **3**(未測定)
#   ゴミ        : JSON ですらない                                  → 台本は **2**(未測定)
#
# ★対照が両方向に要る理由: 「期待どおりなら 0」だけでは、**常に 0 を返す台本**と区別が
#   付かない。壊れた側で 1 が出て初めて、0 は測定結果になる。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${RC_FORK_CHECK_BIN:-$ROOT/tools/live-fork-check.mjs}"
NODE="${RC_NODE_BIN:-node}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

FAKEDIR="$(mktemp -d /tmp/rc-fakeclaude.XXXXXX)" || exit 1
trap 'find "$FAKEDIR" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; rmdir "$FAKEDIR" 2>/dev/null' EXIT

# ── 偽の claude ─────────────────────────────────────────────────────────
# 本物と同じ場所(= cwd の符号を名前にした転写 dir)に JSONL を書く。
# `RC_FAKE_MODE` で振る舞いを変える。
cat > "$FAKEDIR/claude" <<'FAKE'
#!/usr/bin/env node
import { mkdirSync, appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
const mode = process.env.RC_FAKE_MODE || "true";
const argv = process.argv.slice(2);
const resume = argv.includes("--resume") ? argv[argv.indexOf("--resume") + 1] : "";
const fork = argv.includes("--fork-session");

if (mode === "limit") {
  console.log(JSON.stringify({
    type: "result", is_error: true,
    result: "You've hit your weekly limit · resets 12am (Asia/Tokyo)",
    session_id: "00000000-0000-0000-0000-000000000000",
    usage: { input_tokens: 0, output_tokens: 0 }, total_cost_usd: 0,
  }));
  process.exit(1);
}
if (mode === "garbage") { console.log("<<not json>>"); process.exit(1); }
if (mode === "logout") {
  console.log(JSON.stringify({ type: "result", is_error: true,
    result: "Not logged in \u00b7 Please run /login",
    session_id: "22222222-0000-4000-8000-000000000000" }));
  process.exit(1);
}
if (mode === "dirty-limit") {
  // ★先に転写 dir を作ってから落ちる = 本物が実際にやった振る舞い(2026-08-02 実測)
  const slug0 = process.cwd().replace(/[^A-Za-z0-9]/g, "-");
  const d0 = join(homedir(), ".claude", "projects", slug0);
  mkdirSync(join(d0, "memory"), { recursive: true });
  appendFileSync(join(d0, "33333333-0000-4000-8000-000000000000.jsonl"), "{}\n");
  console.log(JSON.stringify({ type: "result", is_error: true,
    result: "You've hit your weekly limit \u00b7 resets 12am (Asia/Tokyo)",
    session_id: "33333333-0000-4000-8000-000000000000" }));
  process.exit(1);
}
if (mode === "errored") {
  console.log(JSON.stringify({ type: "result", is_error: true,
    result: "API Error: 500", session_id: "11111111-0000-4000-8000-000000000000" }));
  process.exit(1);
}

const slug = process.cwd().replace(/[^A-Za-z0-9]/g, "-");
const dir = join(homedir(), ".claude", "projects", slug);
mkdirSync(dir, { recursive: true });

let sid;
if (!resume) sid = "aaaaaaaa-0000-4000-8000-" + String(Date.now()).slice(-12);
else if (fork) sid = "ffffffff-0000-4000-8000-" + String(Date.now()).slice(-12);
else if (mode === "broken") sid = "bbbbbbbb-0000-4000-8000-" + String(Date.now()).slice(-12);
else sid = resume;   // 本物どおり: 既定の resume は sid を変えない

appendFileSync(join(dir, sid + ".jsonl"), JSON.stringify({ role: "user", sid }) + "\n");
console.log(JSON.stringify({ type: "result", is_error: false, result: "ok", session_id: sid }));
FAKE
chmod +x "$FAKEDIR/claude"

# 偽物は ESM を使うので拡張子ではなく package.json で型を宣言する
echo '{"type":"module"}' > "$FAKEDIR/package.json"

run_case() {  # $1=mode $2=期待 exit $3=説明
    local mode="$1" want="$2" desc="$3" out rc
    out="$(RC_FAKE_MODE="$mode" "$NODE" "$CHECK" --bin "$FAKEDIR/claude" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ]; then
        ok "F-$mode $desc(exit $rc)"
    else
        ng "F-$mode $desc" "exit $want を期待して $rc / 末尾: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    fi
    # ★どの筋でも**残骸を残さない**事まで見る。台本の自己申告(印字)だけでなく、
    #   **file system を直に**数える —— 初版は転写 dir を成功路でしか消しておらず、
    #   自己申告は cwd しか見ていなかったので気付けなかった(edith で projects が
    #   14 → 15 に増えて発覚)。
    printf '%s' "$out" | grep -q '★残っている' && ng "F-$mode 片付け(自己申告)" "残骸が出た"
    local left
    left=$(ls -d "$HOME"/.claude/projects/-private-tmp-rc-fork-* 2>/dev/null | wc -l | tr -d " ")
    if [ "$left" != "0" ]; then
        ng "F-$mode 片付け(実地)" "転写 dir が $left 件残った"
        ls -d "$HOME"/.claude/projects/-private-tmp-rc-fork-* 2>/dev/null |
          while read -r r; do find "$r" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
            find "$r" -type d 2>/dev/null | awk '{print length, $0}' | sort -rn | cut -d" " -f2- |
              while read -r d; do rmdir "$d" 2>/dev/null; done; done
    fi
    LAST_OUT="$out"
}

echo "=== F1) 本物どおりの振る舞い → 0 ==="
run_case true 0 "既定=追記 / fork=別 file を正しく 0 と判定"

echo "=== F2) 追記しない木(陰性対照) → 1 ==="
# ここが 0 のままなら、台本は**何を渡しても緑**を返す病気。
run_case broken 1 "追記しない振る舞いを緑にしない"

echo "=== F3) 上限 → 3(未測定であって「違った」ではない) ==="
run_case limit 3 "上限を 1 に丸めない"

echo "=== F4) JSON ですらない → 2(未測定) ==="
run_case garbage 2 "走っていない事を分類より先に言う"

echo "=== F8) 転写 dir を作ってから上限で落ちる → 3 かつ**残骸ゼロ** ==="
# 本物が実際にこうだった。中断路の片付けが抜けていると、ここだけが赤くなる。
run_case dirty-limit 3 "中断路でも転写 dir を畳む"

echo "=== F9) 未ログイン → 2 で、しかも**原因を名指しする** ==="
run_case logout 2 "鍵束が開いていない事を名指しする"
if printf '%s' "$LAST_OUT" | grep -q 'gui/501'; then
    ok "F9b 直し方(launchd gui/501 越しに走らせる)まで出す"
else
    ng "F9b 直し方の提示" "未ログインとだけ言って、経路の直し方を出していない"
fi

echo "=== F7) is_error だが上限ではない → 2(未測定。「違った」ではない) ==="
# 上限だけを特別扱いすると、他の失敗が「設計の前提が崩れた」に化ける。
run_case errored 2 "上限以外の失敗も未測定に倒す"

# ── F5) 既に在る転写 dir には触らない ────────────────────────────────────
# 台本は「不在を確かめてから作った物だけ消す」。既存に当たったら中断(2)する筈。
echo "=== F5) 転写 dir が既に在る → 2 で中断し、その dir を消さない ==="
PROBE_CWD="$(mktemp -d /tmp/rc-fork.XXXXXX)"
PROBE_SLUG="$(/usr/bin/python3 -c 'import sys,os;print(os.path.realpath(sys.argv[1]).replace("/","-").replace(".","-").replace("_","-"))' "$PROBE_CWD" 2>/dev/null)"
echo "  (この筋は台本が自分で mktemp するので直接は当てられない — 代わりに**論理**を見る)"
if grep -q 'TDIR_PREEXISTED' "$CHECK" && grep -q 'if (!TDIR_PREEXISTED) rmTree(TDIR)' "$CHECK"; then
    ok "F5 既存の転写 dir を消す経路が『不在だった時』に閉じている"
else
    ng "F5 既存 dir の保護" "TDIR_PREEXISTED の門が見当たらない — 他人の転写を消し得る"
fi
rmdir "$PROBE_CWD" 2>/dev/null

# ── F6) 信頼一覧に**書く**経路が無い ─────────────────────────────────────
# ★注釈を落としてから見る。初版は `~/.claude.json` という**語**を探していて、
#   「この道具は ~/.claude.json に触らない」と書いた**自分の注釈**に一致して赤を出した。
#   名前の一致は事象ではない —— 分類器は自分の入力に自分が混じっていないか先に見る。
#   (`[[:space:]]` は BSD grep 用。`\s` は効かない)
code_only="$(grep -vE '^[[:space:]]*(\*|//|/\*)' "$CHECK")"
if printf '%s' "$code_only" | grep -qE '\.claude\.json'; then
    ng "F6 信頼一覧" "台本の**コード**が ~/.claude.json に触れている — 信頼の自動付与は禁じ手"
else
    ok "F6 ~/.claude.json に触れる経路がコードに無い(注釈は除いて確認)"
fi

echo ""
echo "FORK-CHECK-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
