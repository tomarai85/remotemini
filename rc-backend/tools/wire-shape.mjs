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
 * 網を使わずに形だけ畳む(対照が使う口。鍵も要らない):
 *   node tools/wire-shape.mjs - < payload.json
 * 終了コード: 0 = 取れた / 1 = HTTP が 200 以外 or 本文が JSON でない / 2 = 準備段で中断
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

if (FROM_STDIN) {
  let body = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (c) => (body += c));
  process.stdin.on("end", () => emit(body, "stdin"));
} else {
  const req = request(
    { host: HOST, port: PORT, path: PATHNAME, method: "GET", headers: { authorization: `Bearer ${KEY}` } },
    (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (c) => (body += c));
      res.on("end", () => {
        if (res.statusCode !== 200) {
          // ★本文は出さない。401 の本文に鍵は載らないが、5xx はスタックを載せうる
          console.error(`HTTP ${res.statusCode}(本文は出さない。${body.length} バイト)`);
          process.exit(1);
        }
        emit(body, `GET ${PATHNAME} → 200`);
      });
    },
  );
  req.on("error", (e) => {
    console.error(`届かない: ${e.message}`);
    process.exit(1);
  });
  req.end();
}
