#!/usr/bin/env node
/**
 * 本番の応答の**形**だけを取る。値は出さない。
 *
 * ── なぜ要るか ────────────────────────────────────────────────────────
 * 電話側のデコーダは、仕様書の散文からではなく**実際に返ってくる物**から組む。
 * 仕様書は既にずれている: §2-2 は `display.routeLabel` / `display.scanLine` と書くが、
 * サーバが返す鍵は `display.route` / `display.scan` —— `src/server.mjs` の `/api/sessions` が
 * `display: { route: routeLabel(live), subtitle: subtitleOf(s) }` と
 * `display: { scan: scanLine(scanBody) }` を組む所。**関数名が routeLabel / scanLine で、
 * 鍵名が route / scan** という食い違いが、散文の側の名前を生んだのだと思われる。
 * 散文の方の名前で `Decodable` を書くと、**デコードは通る**(欠けた鍵が optional なら nil)
 * のに画面が空になる —— 緑のまま嘘をつく形。
 *
 * ── 出さない物 ────────────────────────────────────────────────────────
 * 文字列の値は既定で**型名に潰す**。一覧には会話の題・直近の発言・作業 dir が載る。
 * 形を知るのに中身は要らないので、要らない物は最初から取らない。
 * 値を出すのは下の `VALUE_KEYS` だけ —— どれも閉じた語彙(経路名・故障の種別・画面の分類)で、
 * デコーダ側が enum を組むのに**値そのものが要る**鍵に限る。
 *
 * 鍵は argv に置かない(`ps` に出る)。`RC_KEY` 環境変数から取り、出力には一切載せない。
 *
 * 使い方(edith の中で):
 *   RC_KEY=$(cat ~/.rc-backend/api.key) node tools/wire-shape.mjs /api/sessions
 * 会話ごとの口(`{id}` を書くと**自分で一覧を引いて差し込む**):
 *   RC_KEY=... node tools/wire-shape.mjs '/api/sessions/{id}/history?limit=50'
 *   RC_SESSION_INDEX=2 ... で一覧の何本目を使うか選ぶ(既定 0 = 最新)
 * 網を使わずに形だけ畳む(対照が使う口。鍵も要らない):
 *   node tools/wire-shape.mjs - < payload.json
 * 終了コード: 0 = 取れた / 1 = HTTP が 200 以外 or 本文が JSON でない / 2 = 準備段で中断
 *
 * ── `{id}` を道具の側に持たせた理由 ──────────────────────────────────
 * 会話ごとの口は URL に session id が要る。id は**会話の識別子そのもの**で、
 * 手で調べるには一覧の値を一度画面に出すしかない —— それは この道具が
 * 存在する理由(値を出さない)を、この道具を使う為に破る事になる。
 * だから解決を中に入れて、**印字するのは差し込む前の雛形**にした。
 * id は取得と URL 組み立てにしか通らず、出力にも log にも一切載らない。
 */
import { request } from "node:http";

/** 値をそのまま出してよい鍵。**閉じた語彙だけ**。増やす時は理由を書く事。 */
const VALUE_KEYS = new Set([
  "kind", // display.route.kind / items[].kind — 描き分けの分岐そのもの
  "route", // live.route = "tmux" | "worker"
  "reason", // paneFault.reason / blocked の理由 — 分岐に使う
  "screen", // classifyScreen の分類語
  "short", // routeLabel の短い帯。固定語彙
  "activity", // "observed" | "unknown"
  // ↓ 会話の口(`/history` / `/messages`)の為に 2026-08-05 追加。どちらも閉じた語彙で、
  //   **値そのものが吹き出しの描き分けの分岐**になる(何本目が誰の発言かで形が変わる)。
  //   中身は一切載らない: `role` は生成元の種別、`who` はサーバが決め打つ3語のどれか。
  //   これを型名へ潰すと「string が来る」しか判らず、`tool` 行が在る事に気付かないまま
  //   吹き出しを2種類で組む事になる(`sessions.mjs` は 3 種類を積む)。
  "role", // history[].role = "user" | "assistant" | "tool"
  "who", // display.who = "Tom" | "Claude" | "道具"(= whoOf の戻り値。サーバ側で計算済み)
]);

const HOST = process.env.RC_HOST || "127.0.0.1";
const PORT = Number(process.env.RC_PORT || 8787);
const PATHNAME = process.argv[2] || "/api/sessions";
const KEY = process.env.RC_KEY;

/** 網を張らずに標準入力の JSON を畳むだけの口。★対照はこちらを使う —— 畳み方と
 *  伏せ方(下の `VALUE_KEYS`)は網とは無関係な純粋な処理なので、本物のサーバも鍵も
 *  持ち出さずに測れる。ここを持たないと「伏せられているか」を測る手段が
 *  「本番を叩いて目で見る」しか無くなり、対照が書けない = 一度も測られない。 */
const FROM_STDIN = PATHNAME === "-";

if (!FROM_STDIN && !KEY) {
  console.error("測れない: RC_KEY が無い(argv には置かない事)");
  process.exit(2);
}

/** 値 → 形。文字列は VALUE_KEYS の時だけ値を残す。 */
function shapeOf(value, key) {
  if (value === null) return "null";
  if (Array.isArray(value)) return shapeOfArray(value);
  switch (typeof value) {
    case "string":
      return VALUE_KEYS.has(key) ? `"${value}"` : "string";
    case "number":
      return "number";
    case "boolean":
      return "boolean";
    case "object": {
      const out = {};
      for (const [k, v] of Object.entries(value)) out[k] = shapeOf(v, k);
      return out;
    }
    default:
      return typeof value;
  }
}

/**
 * 配列は要素の形を**畳んで**1つにする。★ここで「どの要素にも在る鍵」と
 * 「一部にしか無い鍵」を分けるのが肝 —— 分けないと、たまたま全部に在った回の観測から
 * 「必須」と読んで `Decodable` を non-optional で書き、次の回に落ちる。
 */
function shapeOfArray(arr) {
  if (arr.length === 0) return { "<empty>": 0 };
  const shapes = arr.map((v) => shapeOf(v, null));
  const objects = shapes.filter((s) => s && typeof s === "object" && !Array.isArray(s));
  if (objects.length !== shapes.length) {
    // 混在。畳まずに種類だけ列挙する(嘘の統一形を作らない)
    return { "<mixed>": [...new Set(shapes.map((s) => (typeof s === "object" ? "object" : s)))] };
  }
  const counts = new Map();
  const merged = {};
  for (const o of objects) {
    for (const [k, v] of Object.entries(o)) {
      counts.set(k, (counts.get(k) || 0) + 1);
      if (!(k in merged)) merged[k] = new Set();
      merged[k].add(JSON.stringify(v));
    }
  }
  const out = { "<count>": arr.length };
  for (const [k, variants] of Object.entries(merged)) {
    const n = counts.get(k);
    const shape = variants.size === 1 ? JSON.parse([...variants][0]) : [...variants].map((s) => JSON.parse(s));
    // 全要素に在れば鍵のまま、欠けが在れば「N/M」を鍵に足す = optional の証拠
    out[n === arr.length ? k : `${k} (${n}/${arr.length})`] = shape;
  }
  return out;
}

/** 本文 → 形。網から来ても標準入力から来ても、通る道は1本にする(片方だけ伏せ忘れる事故を作らない)。 */
function emit(body, label) {
  let parsed;
  try {
    parsed = JSON.parse(body);
  } catch (e) {
    console.error(`JSON ではない: ${e.message}`);
    process.exit(1);
  }
  console.log(`${label} (${body.length} バイト)`);
  console.log(JSON.stringify(shapeOf(parsed, null), null, 2));
}

/** 網を1回叩いて `{status, body}` を返すだけ。伏せる判断はここでは一切しない。 */
function get(path) {
  return new Promise((resolve, reject) => {
    const req = request(
      { host: HOST, port: PORT, path, method: "GET", headers: { authorization: `Bearer ${KEY}` } },
      (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (c) => (body += c));
        res.on("end", () => resolve({ status: res.statusCode, body }));
      },
    );
    req.on("error", reject);
    req.end();
  });
}

/**
 * 一覧を引いて `sessions[IDX].id` を返す。**この値は返り値として URL の組み立てに
 * しか渡さない** —— 呼ぶ側は印字しない事。
 * 解決に失敗した時は 2(未測定)で止める: 「取れなかった」と「取ったら空だった」を
 * 同じ籠に入れると、形が空である事の観測と、形を観測できなかった事が見分けられない。
 */
async function resolveSessionId() {
  const idx = Number(process.env.RC_SESSION_INDEX || 0);
  if (!Number.isInteger(idx) || idx < 0) {
    console.error(`測れない: RC_SESSION_INDEX が非負の整数でない`);
    process.exit(2);
  }
  let r;
  try {
    r = await get("/api/sessions");
  } catch (e) {
    console.error(`測れない: 一覧に届かない(${e.message})`);
    process.exit(2);
  }
  if (r.status !== 200) {
    console.error(`測れない: 一覧が HTTP ${r.status}(本文は出さない。${r.body.length} バイト)`);
    process.exit(2);
  }
  let parsed;
  try {
    parsed = JSON.parse(r.body);
  } catch (e) {
    console.error(`測れない: 一覧が JSON ではない(${e.message})`);
    process.exit(2);
  }
  const list = Array.isArray(parsed?.sessions) ? parsed.sessions : null;
  if (!list) {
    console.error(`測れない: 一覧に sessions 配列が無い`);
    process.exit(2);
  }
  // 件数は出す(値ではないので伏せる対象ではない)。何本目を選べるかが判らないと使えない。
  console.log(`一覧: ${list.length} 本 / RC_SESSION_INDEX=${idx} を使う`);
  if (idx >= list.length) {
    console.error(`測れない: ${idx} 本目は一覧に無い(0..${list.length - 1})`);
    process.exit(2);
  }
  const id = list[idx]?.id;
  if (typeof id !== "string" || id === "") {
    console.error(`測れない: ${idx} 本目に id が無い`);
    process.exit(2);
  }
  return id;
}

async function main() {
  let path = PATHNAME;
  if (PATHNAME.includes("{id}")) {
    const id = await resolveSessionId();
    path = PATHNAME.split("{id}").join(encodeURIComponent(id));
  }
  let r;
  try {
    r = await get(path);
  } catch (e) {
    console.error(`届かない: ${e.message}`);
    process.exit(1);
  }
  if (r.status !== 200) {
    // ★本文は出さない。401 の本文に鍵は載らないが、5xx はスタックを載せうる。
    //   道も出さない —— 差し込み済みの道には id が入っている。
    console.error(`HTTP ${r.status}(本文は出さない。${r.body.length} バイト)`);
    process.exit(1);
  }
  // ★印字するのは**雛形**(`PATHNAME`)であって差し込み済みの `path` ではない。
  emit(r.body, `GET ${PATHNAME} → 200`);
}

if (FROM_STDIN) {
  let body = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => (body += c));
  process.stdin.on("end", () => emit(body, "stdin"));
} else {
  main();
}
