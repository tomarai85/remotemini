#!/bin/bash
# controls-for: tools/live-resume-cwd-check.mjs
# `tools/live-resume-cwd-check.mjs` が**計器として壊れていないか**を測る対照。
#
# ── なぜ要るか ──────────────────────────────────────────────────────────
# あの台本も上限のある相手に**1回だけ**撃つ物で、撃ち直しが利かない。しかも判定が
# `live-fork-check.mjs` より1段むずかしい —— あちらは「①②③が全部通る前提で中身を比べる」
# だけだが、こちらは**③が落ちる事**を期待する。「落ちた」を根拠に結論を書く計器は、
# **落ちた理由を取り違える**危険を必ず抱える。だから偽の claude を cwd 込みで振らせて、
# 取り違えが起きない事を先に見る:
#
#   pinned       : cwd の符号に在る時だけ引き当てる(= §3-V のとおり)      → 台本は **0**
#   pinned-json  : 同上。ただし断り文句を **JSON の is_error** で返す       → 台本は **0**
#   global       : cwd を無視して横断で引き当てる(= §3-V 崩壊)            → 台本は **1**
#   silent-new   : 別 cwd で断らず**黙って別会話**を建てる                  → 台本は **1**
#   anchor-broken: 同じ cwd でも引き当てない(= 錨が立たない)              → 台本は **2**
#   weird        : 別 cwd で落ちるが**断り文句が違う**                      → 台本は **2**
#   limit        : 上限                                                      → 台本は **3**
#   garbage      : JSON ですらない                                          → 台本は **2**
#   logout       : 鍵束が開いていない                                        → 台本は **2**
#
# ★`anchor-broken` と `weird` が此の対照の本体。
#   - `anchor-broken` が 0 になる台本は、**resume が全面的に壊れていても「cwd 固定を確認」**と
#     報告する。②(同じ cwd)を撃つ意味がそこで消える。
#   - `weird` が 0 になる台本は、**断り文句が変わっただけ**で「予言どおり」と言う。
#     `claude` の文言は版で変わるので、これは実際に起こる。
#   どちらも「③が落ちた」までは pinned と**全く同じ観測**になる。区別できて初めて計器。
#
# 終了コード: 0 = 全部期待どおり / 1 = どれかが違う
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="${RC_RESUME_CWD_CHECK_BIN:-$ROOT/tools/live-resume-cwd-check.mjs}"
NODE="${RC_NODE_BIN:-node}"

pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS  $1"; }
ng() { fail=$((fail+1)); echo "FAIL  $1  ($2)"; }

FAKEDIR="$(mktemp -d /tmp/rc-fakeclaude-rcwd.XXXXXX)" || exit 1
trap 'find "$FAKEDIR" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null; rmdir "$FAKEDIR" 2>/dev/null' EXIT

# ── 偽の claude ─────────────────────────────────────────────────────────
# 本物と同じ場所(= cwd の符号を名前にした転写 dir)に JSONL を書く。
# ★横断で探す `global` でも、走査するのは**使い捨ての符号だけ**に絞る。
#   `~/.claude/projects/*` を丸ごと舐めると、対照が Tom の本物の転写 dir を触る。
cat > "$FAKEDIR/claude" <<'FAKE'
#!/usr/bin/env node
import { mkdirSync, appendFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";

const mode = process.env.RC_FAKE_MODE || "pinned";
const argv = process.argv.slice(2);
const resume = argv.includes("--resume") ? argv[argv.indexOf("--resume") + 1] : "";

const PROJECTS = join(homedir(), ".claude", "projects");
const slug = process.cwd().replace(/[^A-Za-z0-9]/g, "-");
const here = join(PROJECTS, slug);
const DISPOSABLE = /^-private-tmp-rc-rcwd-[ab]-/;   // 走査はこの符号だけに絞る

const emit = (o) => { console.log(JSON.stringify(o)); };
const okResult = (sid) => emit({ type: "result", is_error: false, result: "ok", session_id: sid });

// ★`--version` は**何より先**に返す。台本は判定に版を載せる為に此れを撃つが、
//   偽物にとって `--resume` の無い呼び出しは「会話を建てる」筋なので、素通しすると
//   **台本の cwd(= この repo)の本物の転写 dir に会話を1本書く**。実際に踏んだ:
//   2026-08-07、対照1回で `-Users-...-rc-backend` に 6本 残した(対照は全部緑のまま)。
//   偽物が本物の場所へ書ける唯一の口が此処なので、先頭で閉じる。
if (process.argv.slice(2).some((a) => a === "--version" || a === "-v")) {
  console.log("2.1.223 (Claude Code)");
  process.exit(0);
}

if (mode === "limit") {
  emit({ type: "result", is_error: true,
    result: "You've hit your weekly limit · resets 12am (Asia/Tokyo)",
    session_id: "00000000-0000-0000-0000-000000000000" });
  process.exit(1);
}
if (mode === "garbage") { console.log("<<not json>>"); process.exit(1); }
if (mode === "logout") {
  emit({ type: "result", is_error: true, result: "Not logged in · Please run /login",
    session_id: "22222222-0000-4000-8000-000000000000" });
  process.exit(1);
}

// ── 会話を建てる(resume なし)。どの mode でも同じ ──────────────────────
if (!resume) {
  mkdirSync(here, { recursive: true });
  const sid = "aaaaaaaa-0000-4000-8000-" + String(Date.now()).slice(-12);
  appendFileSync(join(here, sid + ".jsonl"), JSON.stringify({ role: "user", sid }) + "\n");
  okResult(sid);
  process.exit(0);
}

// ── resume ──────────────────────────────────────────────────────────────
const mine = join(here, resume + ".jsonl");
const foundHere = existsSync(mine);

if (mode === "anchor-broken") {
  // 同じ cwd でも引き当てない = ②の錨が立たない。台本は③を解釈してはいけない。
  console.log(`No conversation found with session ID: ${resume}`);
  process.exit(1);
}

if (foundHere) {                       // 現在地に在る = ②の筋。どの mode でも通す
  appendFileSync(mine, JSON.stringify({ role: "user", sid: resume }) + "\n");
  okResult(resume);
  process.exit(0);
}

// ここから先は「現在地に無い」= ③の筋。mode ごとに振る舞いを変える。
if (mode === "global") {
  // cwd を無視して横断で引き当てる(= §3-V 崩壊の形)
  let hit = "";
  try {
    for (const d of readdirSync(PROJECTS)) {
      if (!DISPOSABLE.test(d)) continue;
      const p = join(PROJECTS, d, resume + ".jsonl");
      if (existsSync(p)) { hit = p; break; }
    }
  } catch {}
  if (hit) {
    appendFileSync(hit, JSON.stringify({ role: "user", sid: resume }) + "\n");
    okResult(resume);                  // ★元の会話を、元の file に伸ばす
    process.exit(0);
  }
}

if (mode === "silent-new") {
  // 断らずに、現在地へ**別 ID の会話**を建てる
  mkdirSync(here, { recursive: true });
  const sid = "cccccccc-0000-4000-8000-" + String(Date.now()).slice(-12);
  appendFileSync(join(here, sid + ".jsonl"), JSON.stringify({ role: "user", sid }) + "\n");
  okResult(sid);
  process.exit(0);
}

if (mode === "weird") {
  // 落ちるが、断り文句が違う(版が上がって文言が変わった時の形)
  console.log(`Session lookup failed: unknown id ${resume}`);
  process.exit(1);
}

if (mode === "pinned-json") {
  emit({ type: "result", is_error: true,
    result: `No conversation found with session ID: ${resume}`, session_id: resume });
  process.exit(1);
}

// mode === "pinned"(既定): 生の文字列で断る = `claude` 本体の読みどおりの形
console.log(`No conversation found with session ID: ${resume}`);
process.exit(1);
FAKE
chmod +x "$FAKEDIR/claude"
echo '{"type":"module"}' > "$FAKEDIR/package.json"

leftovers() { ls -d "$HOME"/.claude/projects/-private-tmp-rc-rcwd-* 2>/dev/null | wc -l | tr -d " "; }

# ★偽物が**使い捨ての符号の外**へ書いていないか。上の `leftovers` は使い捨ての dir しか
#   見ないので、本物の転写 dir へ書かれても 0 のまま緑になる —— 2026-08-07 に実際に
#   起きた: 台本へ `--version` を足した所、偽物が其れを「会話を建てる」呼び出しと読み、
#   対照1回で `-Users-...-rc-backend` に 6本 置いた。対照は全部緑だった。
#   偽物の sid は前置が固定なので、其の名前を符号の外で数えれば型ごと捕まる。
foreign_fakes() {
    find "$HOME/.claude/projects" -maxdepth 2 -type f \
         \( -name 'aaaaaaaa-0000-4000-8000-*.jsonl' -o -name 'cccccccc-0000-4000-8000-*.jsonl' \) 2>/dev/null |
      grep -v '/-private-tmp-rc-rcwd-' || true
}

sweep_leftovers() {
    ls -d "$HOME"/.claude/projects/-private-tmp-rc-rcwd-* 2>/dev/null |
      while read -r r; do
        find "$r" -type f -print0 2>/dev/null | xargs -0 /bin/rm -f 2>/dev/null
        find "$r" -type d 2>/dev/null | awk '{print length, $0}' | sort -rn | cut -d" " -f2- |
          while read -r d; do rmdir "$d" 2>/dev/null; done
      done
}

run_case() {  # $1=mode $2=期待 exit $3=説明
    local mode="$1" want="$2" desc="$3" out rc
    out="$(RC_FAKE_MODE="$mode" "$NODE" "$CHECK" --bin "$FAKEDIR/claude" 2>&1)"; rc=$?
    if [ "$rc" -eq "$want" ]; then
        ok "R-$mode $desc(exit $rc)"
    else
        ng "R-$mode $desc" "exit $want を期待して $rc / 末尾: $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
    fi
    # 片付けは自己申告と実地の両方で見る(fork-check が実地で1回落ちている)。
    printf '%s' "$out" | grep -q '★残っている' && ng "R-$mode 片付け(自己申告)" "残骸が出た"
    local left; left="$(leftovers)"
    if [ "$left" != "0" ]; then
        ng "R-$mode 片付け(実地)" "転写 dir が $left 件残った"
        sweep_leftovers
    fi
    local foreign; foreign="$(foreign_fakes)"
    if [ -n "$foreign" ]; then
        ng "R-$mode 符号の外への書き込み" "本物の転写 dir に $(printf '%s\n' "$foreign" | wc -l | tr -d ' ') 件"
        printf '%s\n' "$foreign" | while read -r f; do [ -n "$f" ] && /bin/rm -f "$f"; done
    fi
    LAST_OUT="$out"
}

echo "=== R1) cwd に固定(§3-V のとおり) → 0 ==="
run_case pinned 0 "②通る/③断られる を正しく 0 と判定"

echo "=== R2) 断り文句が JSON の is_error で来る → 同じく 0 ==="
# 生の文字列と JSON の両方の形を掴めないと、版が上がった時に「未測定」に化ける。
run_case pinned-json 0 "断り文句の器が変わっても掴む"

echo "=== R3) 横断で引き当てる(陰性対照) → 1 ==="
# ここが 0 のままなら、台本は**何を渡しても §3-V を追認**する病気。
run_case global 1 "別 cwd から引き当てた事を緑にしない"

echo "=== R4) 断らず黙って別会話を建てる → 1 ==="
run_case silent-new 1 "沈黙の別会話を『予言どおり』にしない"

echo "=== R5) ★錨が立たない(同じ cwd でも引き当てない) → 2 ==="
# ③だけ見ると R1 と区別が付かない筋。ここが 0 なら②を撃つ意味が無い。
run_case anchor-broken 2 "錨が落ちたら③を解釈しない"
if printf '%s' "$LAST_OUT" | grep -q '陽性の錨'; then
    ok "R5b 錨が落ちた事を名指しする"
else
    ng "R5b 錨の名指し" "未測定とだけ言って、どの観測が欠けたか出していない"
fi

echo "=== R6) ★断り文句が違う → 2(0 に丸めない) ==="
run_case weird 2 "文言が変わっただけで『予言どおり』と言わない"

echo "=== R7) 上限 → 3(未測定であって「違った」ではない) ==="
run_case limit 3 "上限を 1 に丸めない"

echo "=== R8) JSON ですらない → 2(未測定) ==="
run_case garbage 2 "走っていない事を分類より先に言う"

echo "=== R9) 未ログイン → 2 で、しかも原因を名指しする ==="
run_case logout 2 "鍵束が開いていない事を名指しする"
if printf '%s' "$LAST_OUT" | grep -q 'gui/501'; then
    ok "R9b 直し方(launchd gui/501 越しに走らせる)まで出す"
else
    ng "R9b 直し方の提示" "未ログインとだけ言って、経路の直し方を出していない"
fi

# ── R10) 既に在る転写 dir には触らない ───────────────────────────────────
if grep -q 'T1_PRE' "$CHECK" && grep -q 'if (!T1_PRE) rmTree(T1)' "$CHECK" && grep -q 'if (!T2_PRE) rmTree(T2)' "$CHECK"; then
    ok "R10 既存の転写 dir を消す経路が『不在だった時』に閉じている(T1/T2 とも)"
else
    ng "R10 既存 dir の保護" "T1_PRE/T2_PRE の門が見当たらない — 他人の転写を消し得る"
fi

# ── R11) ★HOME を撃たない ────────────────────────────────────────────────
# 台本の約束の本体。別 cwd の代わりに HOME を使うと、引き当てが外れた時の落とし先が
# **Tom の本物の転写 dir** になる。注釈は落としてから見る(名前の一致は事象ではない)。
code_only="$(grep -vE '^[[:space:]]*(\*|//|/\*)' "$CHECK")"
if printf '%s' "$code_only" | grep -qE 'shoot\([^)]*homedir\(\)'; then
    ng "R11 HOME を撃たない" "shoot() に homedir() を渡している — 本物の転写 dir に残骸を置き得る"
else
    ok "R11 shoot() の cwd に homedir() を渡す経路がコードに無い"
fi

# ── R13) 判定に**測った版**が載る ────────────────────────────────────────
# 0 と 1 の意味は claude 本体の版で入れ替わる(2.1.223 で横断の落とし先が増えた)。
# 版の無い「0」は、予言どおりなのか古い版を撃っただけなのかを後から区別できない。
# ★緑の道(0)と赤の道(1)の**両方**で見る。片方だけだと、もう片方が黙って落ちる。
for pair in "pinned 0" "global 1"; do
    set -- $pair
    vout="$(RC_FAKE_MODE="$1" "$NODE" "$CHECK" --bin "$FAKEDIR/claude" 2>&1)"
    sweep_leftovers
    if printf '%s' "$vout" | grep -q '測った claude' && printf '%s' "$vout" | grep -q '2.1.223'; then
        ok "R13-$1 判定に測った版が載る(exit $2 の道)"
    else
        ng "R13-$1 版の記録" "判定に版が出ていない — 後から 0/1 の意味を決められない"
    fi
done

# ── R14) 偽物が使い捨ての符号の外へ書かない ──────────────────────────────
# `run_case` が毎回見ているのと同じ検査を、最後にもう一度**素で**当てる。
# 上の R13 は `run_case` を通らないので、そこで書かれても誰も見ていない事になる。
r14="$(foreign_fakes)"
if [ -z "$r14" ]; then
    ok "R14 本物の転写 dir に偽の会話が残っていない"
else
    ng "R14 符号の外への書き込み" "$(printf '%s\n' "$r14" | wc -l | tr -d ' ') 件残った"
    printf '%s\n' "$r14" | while read -r f; do [ -n "$f" ] && /bin/rm -f "$f"; done
fi

# ── R12) 信頼一覧に**書く**経路が無い ────────────────────────────────────
if printf '%s' "$code_only" | grep -qE '\.claude\.json'; then
    ng "R12 信頼一覧" "台本の**コード**が ~/.claude.json に触れている — 信頼の自動付与は禁じ手"
else
    ok "R12 ~/.claude.json に触れる経路がコードに無い(注釈は除いて確認)"
fi

echo ""
echo "RESUME-CWD-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
