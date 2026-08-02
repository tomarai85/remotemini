#!/usr/bin/env node
// 観測1回分を状態に畳んで、鳴らすべきなら文面を1行出す**だけ**の繋ぎ。
// 判定は `src/health.mjs`(純関数・単体 25 本 + 変異の的 13 枚)に在り、ここには置かない。
//
//   node tools/health-step.mjs <状態ファイル> <ok|ng> <理由> <epoch秒> [閾値] [ホスト名]
//   node tools/health-step.mjs --mark-delivered <状態ファイル>   ← 配達が済んだ後だけ
//
// 終了コードで種類を返す(shell が mention の有無を決められる様に):
//   0  = 鳴らさない          10 = 落ちた(mention 付き)      11 = 戻った(ping 無し)
//   3  = ★状態ファイルが壊れている / 書けない(= 監視自体が死んでいる)
//
// なぜ 3 を分けるか: 状態が読めないと `fails` が毎回 0 に戻り、**何回失敗しても閾値に
// 届かない** = 永久に鳴らない監視になる。yoda の 46 時間と同じ「壊れ方が静か」な形なので、
// 「読めなかった」を「異常なし」に丸めず、呼び手が別建てで騒げる様に外へ出す。
import { readFileSync, writeFileSync, renameSync, existsSync, unlinkSync } from "node:fs";
import {
    initialHealthState,
    healthTransition,
    healthMessage,
    markDelivered,
} from "../src/health.mjs";

const argv = process.argv.slice(2);

function die(code, msg) {
    process.stderr.write(`health-step: ${msg}\n`);
    process.exit(code);
}

// ── 状態を読む / 書く(両方の入口が使う)────────────────────────────
function writeState(stateFile, state) {
    // 途中で落ちても半端な JSON を残さない様に、別名で書いてから rename(同一 FS 内なら原子的)。
    const tmp = `${stateFile}.tmp.${process.pid}`;
    try {
        writeFileSync(tmp, `${JSON.stringify(state)}\n`, "utf8");
        renameSync(tmp, stateFile);
    } catch (e) {
        try { if (existsSync(tmp)) unlinkSync(tmp); } catch { /* 後片付けの失敗で本体の理由を隠さない */ }
        die(3, `状態ファイルが書けない(${stateFile}): ${e.message}`);
    }
}

// ── 別入口: 配達が済んだ事だけを記録する ────────────────────────────
//   台本が**出し先から 0 が返った後**にだけ呼ぶ。これを本体と同じ回に書かないのが要点 ——
//   「知らせると決めた」時点で記録すると、届かなかった時に永久に鳴らない監視になる。
if (argv[0] === "--mark-delivered") {
    const f = argv[1];
    if (!f) die(2, "使い方: health-step.mjs --mark-delivered <状態ファイル>");
    if (!existsSync(f)) die(3, `状態ファイルが無い(${f}): 配達済みを記録できない`);
    let cur;
    try {
        cur = JSON.parse(readFileSync(f, "utf8"));
    } catch (e) {
        die(3, `状態ファイルが読めない/壊れている(${f}): ${e.message}`);
    }
    writeState(f, markDelivered(cur));
    process.exit(0);
}

const [stateFile, verdict, reason, nowRaw, thresholdRaw, host] = argv;

if (!stateFile || !verdict || nowRaw === undefined) {
    die(2, "使い方: health-step.mjs <状態ファイル> <ok|ng> <理由> <epoch秒> [閾値] [ホスト名]");
}
const now = Number(nowRaw);
if (!Number.isFinite(now)) die(2, `epoch 秒が数値でない: ${nowRaw}`);
const threshold = thresholdRaw === undefined || thresholdRaw === "" ? 3 : Number(thresholdRaw);

// ── 前の状態を読む ────────────────────────────────────────────────
let prev = initialHealthState();
if (existsSync(stateFile)) {
    let raw;
    try {
        raw = readFileSync(stateFile, "utf8");
    } catch (e) {
        die(3, `状態ファイルが読めない(${stateFile}): ${e.message}`);
    }
    let parsed;
    try {
        parsed = JSON.parse(raw);
    } catch {
        die(3, `状態ファイルが壊れている(${stateFile})。中身を捨てて 0 から数え直すと**永久に鳴らない**ので止まる`);
    }
    // 形も見る。JSON として読めても中身が違えば同じ「静かな壊れ方」になる。
    const okShape =
        parsed !== null &&
        typeof parsed === "object" &&
        ["unknown", "up", "down"].includes(parsed.status) &&
        Number.isInteger(parsed.fails) &&
        parsed.fails >= 0 &&
        (parsed.firstFailAt === null || Number.isFinite(parsed.firstFailAt)) &&
        // `owed`(= まだ Tom に伝えていない変化)は後から足した項。**無い事は壊れている事
        // ではない**(古い状態ファイルを「形が違う」と切ると、上げ直した瞬間に監視が壊れたと
        // 騒ぐ)。無い時は `undefined` のまま下へ渡す = 「伝えたか分からない」= 鳴らし直す側。
        // ★旧版の `announced` は**見ない**。あっても形の違反にしない ——
        //   読み違えるより「もう一度鳴る」方へ倒す(重複は騒々しいだけ、沈黙は致命)。
        (parsed.owed === undefined ||
            parsed.owed === null ||
            (typeof parsed.owed === "object" &&
                ["down", "recovered"].includes(parsed.owed.kind)));
    if (!okShape) die(3, `状態ファイルの形が違う(${stateFile}): ${raw.slice(0, 200)}`);
    prev = {
        status: parsed.status,
        fails: parsed.fails,
        firstFailAt: parsed.firstFailAt,
        // 項が無ければ **undefined のまま渡す**。`null`(返済済み)に丸めると、
        // 古い状態ファイルを「もう伝えた」と読んで落下が鳴らなくなる。
        owed: parsed.owed,
    };
}

// ── 畳む ──────────────────────────────────────────────────────────
let result;
try {
    result = healthTransition(prev, { ok: verdict === "ok", reason: reason || "" }, now, { threshold });
} catch (e) {
    die(2, e.message);
}

// ── 書く(書けない事を成功にしない)────────────────────────────────
// ★ここで書くのは**観測した事実**だけ。「知らせ終えた」は書かない —— それは配達の後に
//   台本が `--mark-delivered` で別に書く(この分離が無いと、届かなかった時に沈黙する)。
writeState(stateFile, result.state);

// ── 鳴らす物が在れば1行 ────────────────────────────────────────────
if (result.notify === null) process.exit(0);

const fmtTime = (epoch) =>
    new Date(epoch * 1000).toLocaleString("ja-JP", { hour12: false });
process.stdout.write(`${healthMessage(result.notify, host || "(ホスト未設定)", fmtTime)}\n`);
process.exit(result.notify.kind === "down" ? 10 : 11);
