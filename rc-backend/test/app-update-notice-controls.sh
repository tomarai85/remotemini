#!/bin/bash
# controls-for: src/wire.mjs src/ota-published.mjs src/reqlog.mjs
#
# 「机は新しい版を配っている」を電話に言わせる経路の、**机側**の対照。
#
# ★なぜ此の経路が要るか(2026-08-30): CF-11 で私は「4件の指摘は反映済み」と報告したが、
#   其の修正は **Tom が持っているどの版にも入っていなかった**(commit は署名の3分後)。
#   CF-17 の実測では配布口に `client=app` が **path を問わず1本も来ていない** ——
#   栞は一度も叩かれていない。つまり「新しい版が在る」を伝える経路が
#   **私が思い出して言う**しか無かった。私の記憶は F3 以来この系の最弱点なので、構造に置く。
#
# ★測る中心は「文面が出るか」ではない。**出してはいけない時に黙るか**。
#   此の帯は一度でも嘘を吐けば(叩いても何も変わらなければ)二度と読まれない。
#
#   A1 配布 > 手元 → 出す(両方の数を文面に入れる)
#   A2 等しい / 手元の方が新しい → 出さない
#   A3 どちらかが読めない → 出さない(推測しない)
#   A4 ★`"96abc"` の様な**詐称できる名乗り**から数字を作らない(UA 由来なので誰でも書ける)
#   A5 読むのは **manifest**(配っている版)であって `.approved-build` ではない
#   A6 配布 dir が2つ在れば読まない(古い秘密の残骸を「配布中」と読まない)
#   A7 封筒 `sessionsBody` が `display.update` に載せる(載せ忘れは画面が痩せるだけで気付けない)
#   A9 帯が指す配布側の番号(電話が「此の版は後で」を憶える鍵。文面から数字を拾わせない)
#   A8 ★電話が**自分で名乗る**ヘッダ(`X-App-Build`)。既定 UA は Apple の契約であって
#      私の物ではない —— 形が変われば「版が判らない」に落ちて帯が黙り、しかも
#      「判らない」と「解析が壊れた」が同じ null なので**壊れた事に気付けない**(Codex)
#
# 変異(→ 赤くなるべき検査):
#   M1 等しい時も出す                → A2
#   M2 全桁が数字の検めを外す        → A4
#   M3 封筒が update を載せない      → A7
#   M4 manifest でなく承認記録を読む → A5
#   M5 dir が2つでも1つ目を選ぶ      → A6
#   M6 ヘッダの判定が UA 用と同じになる → A8
#   M7 文面が無い時にも番号を出す       → A9
#
# 使い方: bash rc-backend/test/app-update-notice-controls.sh
# 終了コード: 0=全部緑 / 1=1本でも赤
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # = rc-backend/
WIRE="$HERE/src/wire.mjs"
OTA="$HERE/src/ota-published.mjs"
for f in "$WIRE" "$OTA"; do [ -f "$f" ] || { echo "測る対象が無い: $f"; exit 1; }; done

pass=0; fail=0
ok() { echo "PASS  $1"; pass=$((pass + 1)); }
ng() { echo "FAIL  $1  ($2)"; fail=$((fail + 1)); }

SB="$(mktemp -d)"
REQLOG="$HERE/src/reqlog.mjs"
SERVER="$HERE/src/server.mjs"
# ★M8 が server.mjs を変異させるので、**控えと復元の対象に入れる**(2026-08-31)。
#   入れ忘れると変異が木に残る = CF-12 で配る寸前まで行った形そのもの。下の Z が之も見る。
cp "$WIRE" "$SB/wire.orig"; cp "$OTA" "$SB/ota.orig"; cp "$REQLOG" "$SB/reqlog.orig"
cp "$SERVER" "$SB/server.orig"
restore() { cp -f "$SB/wire.orig" "$WIRE"; cp -f "$SB/ota.orig" "$OTA"; cp -f "$SB/reqlog.orig" "$REQLOG"; cp -f "$SB/server.orig" "$SERVER"; }
trap 'restore; rm -rf "$SB"' EXIT

# ── 判定の本体。**基準でも変異でも同じ物**を走らせる(別々に書くと、変異が
#    「検査を書き換えた」のか「実装を壊した」のか判らなくなる)。 ──────────────
assert_js() {   # assert_js <名前> → 0=期待どおり
    node --input-type=module -e '
import { updateNotice, updateBuild, sessionsBody } from "'"$WIRE"'";
import { headerBuild } from "'"$REQLOG"'";
import * as REQLOG_EXPORTS from "'"$REQLOG"'";
import { publishedBuild, resetPublishedBuildCache } from "'"$OTA"'";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const bad = [];
const eq = (name, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) bad.push(`${name}: got ${JSON.stringify(got)} want ${JSON.stringify(want)}`); };
const truthy = (name, v) => { if (!v) bad.push(name); };

// A1
const n = updateNotice(105, 96);
truthy("A1-出す", typeof n === "string" && n.includes("96") && n.includes("105"));
// A2
eq("A2-等しい", updateNotice(105, 105), null);
eq("A2-手元が新しい", updateNotice(96, 105), null);
// A3
eq("A3-配布不明", updateNotice(null, 96), null);
eq("A3-手元不明", updateNotice(105, "-"), null);
// A4
eq("A4-詐称", updateNotice(105, "96abc"), null);
eq("A4-空", updateNotice(105, ""), null);

// A5 / A6
const root = mkdtempSync(join(tmpdir(), "otac-"));
const d1 = join(root, "aaa111"); mkdirSync(d1);
writeFileSync(join(d1, "manifest.plist"), "<key>bundle-version</key>\n<string>105</string>\n");
writeFileSync(join(d1, ".approved-build"), "999\n");
resetPublishedBuildCache();
eq("A5-manifest を読む", publishedBuild(root), "105");
// ★2つ目にも**読める** manifest を置く。空の dir を置くと、間違った方を選んでも
//   読めずに null になり、正しい拒否と区別が付かない —— 変異が赤くならず、
//   検査が「守っている」と嘘をつく(2026-08-30、M5 が赤くならずに発覚)。
//   守っている状況は「古い秘密の残骸が**読めるまま**並んでいる」事その物。
const d2 = join(root, "bbb222"); mkdirSync(d2);
writeFileSync(join(d2, "manifest.plist"), "<key>bundle-version</key>\n<string>77</string>\n");
resetPublishedBuildCache();
eq("A6-dir が2つ", publishedBuild(root), null);

// A7
const body = sessionsBody({ sessions: [], scan: {}, paneFault: null, publishedBuild: 105, appBuild: "96" });
truthy("A7-封筒に載る", typeof body.display?.update === "string" && body.display.update.includes("105"));

// A9 帯が指す**配布側の番号**。電話が「此の版は後で」を憶える鍵。
eq("A9-番号を出す", updateBuild(105, 96), "105");
eq("A9-出さない時は番号も無い", updateBuild(105, 105), null);
eq("A9-読めない時も無い", updateBuild(null, 96), null);
truthy("A9-封筒に載る", sessionsBody({ sessions: [], scan: {}, paneFault: null, publishedBuild: 105, appBuild: "96" }).display?.updateBuild === "105");

// A8 電話が**自分で名乗る**ヘッダ。UA は iOS が既定で組み立てる物 = 私が所有していない契約。
eq("A8-素の数字を通す", headerBuild("96"), "96");
eq("A8-空白を落とす", headerBuild(" 96 "), "96");
eq("A8-詐称を拒む", headerBuild("96abc"), "-");
eq("A8-無い時", headerBuild(undefined), "-");
// ★UA 経路は 2026-08-31 に**消した**。`appBuild` は存在しない —— iOS 既定の名乗りが
//   運ぶのは `CFBundleShortVersionString`(売り物の版)であって build 番号ではなく、
//   落ちた先で**売り物の版と build 番号を引き算する**事になっていた。
//   実測: 手元が 短版 0.1 / build 106、机の log の app 要求 861 本が全部 `build=1`。
truthy("A8-UA から版を採る出口が残っていない",
  !Object.keys(REQLOG_EXPORTS).some((k) => /^appBuild$/.test(k)));

if (bad.length) { console.error(bad.join(" | ")); process.exit(1); }
' 2>&1
}

# ── 基準 ──────────────────────────────────────────────────────────────────
out="$(assert_js)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "A1-A7 基準(素の実装で全部通る)"
else ng "A1-A7 基準" "$out"; fi

# ── 変異 ──────────────────────────────────────────────────────────────────
mutate() {  # mutate <file> <元> <後>
    python3 - "$1" "$2" "$3" <<'PY'
import io, sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = io.open(p, encoding="utf-8").read()
if a not in s:
    sys.stderr.write("ANCHOR-MISS\n"); sys.exit(3)
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}

check_red() {  # check_red <名前> <期待して赤くなる検査名の一部>
    local name="$1" want="$2" out rc
    out="$(assert_js)"; rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "$want"; then
        ok "$name → $want が赤くなる"
    else
        ng "$name" "赤くならない(rc=$rc / $out)"
    fi
    restore
}

# ★出所の検査。`assert_js` は wire と reqlog しか読まないので、server.mjs が
#   どちらの入口から版を採るかは**原文を読む**しかない(行番号ではなく書き方で当てる)。
assert_src() {   # 0 = server は版をヘッダからしか採っていない
    local line
    line="$(grep -n 'appBuild: headerBuild' "$SERVER" | head -1)"
    [ -n "$line" ] || { echo "A10: 錨が動いた(appBuild: headerBuild の行が無い)"; return 1; }
    # 其の行に UA を読む形が混ざっていたら赤
    printf '%s' "$line" | grep -q 'user-agent' && { echo "A10: server が UA へ落ちている: $line"; return 1; }
    return 0
}
out="$(assert_src)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "A10 server は版を名乗ったヘッダからしか採らない"
else ng "A10 出所" "$out"; fi

check_red_src() {  # check_red_src <名前>
    local name="$1" out rc
    out="$(assert_src)"; rc=$?
    if [ "$rc" -ne 0 ]; then ok "$name → A10 が赤くなる"
    else ng "$name" "赤くならない(A10 が通った)"; fi
    restore
}

mutate "$WIRE" 'if (pub <= mine) return null;' 'if (pub < mine) return null;' \
    && check_red "M1 等しい時も出す" "A2-等しい" || { ng "M1" "錨が動いた"; restore; }

mutate "$WIRE" 'const digits = (v) => (/^\d{1,9}$/.test(String(v ?? "").trim()) ? Number(String(v).trim()) : NaN);' \
               'const digits = (v) => Number.parseInt(String(v ?? "").trim(), 10);' \
    && check_red "M2 全桁が数字の検めを外す" "A4-詐称" || { ng "M2" "錨が動いた"; restore; }

mutate "$WIRE" '      update: updateNotice(publishedBuild, appBuild),' \
               '      update: null,' \
    && check_red "M3 封筒が update を載せない" "A7-封筒に載る" || { ng "M3" "錨が動いた"; restore; }

mutate "$OTA" 'readFileSync(join(dir, "manifest.plist"), "utf8")' \
              'readFileSync(join(dir, ".approved-build"), "utf8")' \
    && check_red "M4 manifest でなく承認記録を読む" "A5-manifest を読む" || { ng "M4" "錨が動いた"; restore; }

mutate "$OTA" 'return n === 1 ? found : null;' 'return found;' \
    && check_red "M5 dir が2つでも1つ目を選ぶ" "A6-dir が2つ" || { ng "M5" "錨が動いた"; restore; }

mutate "$WIRE" 'return updateNotice(publishedBuild, appBuild) === null
    ? null
    : String(publishedBuild).trim();' 'return String(publishedBuild).trim();' \
    && check_red "M7 文面を出さない時にも番号を出す" "A9-出さない時は番号も無い" \
    || { ng "M7" "錨が動いた"; restore; }

# ★M6 の変異を張り替えた(2026-08-31)。旧版は `appBuild(value)` を呼ばせていたが、
#   其の関数はもう無いので **ReferenceError で赤くなる** —— 検出したのではなく落ちただけ。
#   代わりに「全桁の検めを外す」現実的な緩め方を植える(`"96abc"` を通す形)。
mutate "$HERE/src/reqlog.mjs" 'export function headerBuild(value) {
  const v = String(value ?? "").trim();
  return /^\d{1,9}$/.test(v) ? v : "-";
}' 'export function headerBuild(value) {
  const v = String(value ?? "").trim();
  return v === "" ? "-" : v;
}' \
    && check_red "M6 ヘッダの判定から全桁の検めを外す" "A8-詐称を拒む" \
    || { ng "M6" "錨が動いた"; restore; }

# ── M8 ★UA 経路を**戻す**変異(2026-08-31 の削除が守られているかの対照)────────
#   server.mjs が再び UA へ落ちる形に戻ったら赤くなる事を測る。之が無いと、
#   削除は「今日そうなっている」だけで、明日戻っても誰も気付かない。
mutate "$HERE/src/server.mjs" '        appBuild: headerBuild(req.headers["x-app-build"]),' \
    '        appBuild: headerBuild(req.headers["x-app-build"]) !== "-" ? headerBuild(req.headers["x-app-build"]) : String(req.headers["user-agent"] || "").split("/")[1],' \
    && check_red_src "M8 server が UA へ落ちる形に戻る" \
    || { ng "M8" "錨が動いた"; restore; }

# ★戻せた事を測る。変異対照が木を汚したまま終わると、次に焼いた版へ変異が乗る
#   (CF-12 で実際に配る寸前まで行った形)。
if cmp -s "$WIRE" "$SB/wire.orig" && cmp -s "$OTA" "$SB/ota.orig" && cmp -s "$REQLOG" "$SB/reqlog.orig" \
   && cmp -s "$SERVER" "$SB/server.orig"; then
    ok "Z 木を汚したまま終わらない"
else
    ng "Z 木が汚れている" "手で git checkout -- src/wire.mjs src/ota-published.mjs する事"
fi

echo ""
echo "APP-UPDATE-NOTICE-CONTROLS: pass=$pass fail=$fail"
exit $(( fail > 0 ))
