#!/usr/bin/env node
// 机に置いた束を電話へ渡すだけの、極小の静的配信(2026-08-28)。
//
// ★なぜ rc-backend の中に入れなかったか。此処が配る道は**認証を付けられない** ——
//   iOS の `installd` が manifest と .ipa を取りに来る時、独自の header を送らないから。
//   其れを電話の生命線である rc-backend の中へ足すと、認証を外す分岐が本体に1本増える。
//   欠陥が出た時に壊れるのが「配布」だけで済む様に、**別のプロセスに切る**。
//   死んでも Tom の会話は生きている。
//
// ★守りは3つ。認証が無い代わりに、此の3つが全部要る:
//   1. 127.0.0.1 にしか listen しない。外へ出るのは `tailscale serve` の経路だけで、
//      其れは tailnet 限定。
//   2. path は `ROOT` の中へ**解決してから**比較する(`realpath` の前後で確かめる)。
//      `..` も symlink も此処で死ぬ。
//   3. **一覧を返さない**。dir を叩かれたら index.html だけ返し、無ければ 404。
//      配る path の秘密の一段は、一覧が出た瞬間に秘密でなくなる ——
//      Tom の tailnet には今も edith(2026-08-20 に譲渡した機体)が居る。
//
// ★GET と HEAD 以外は受けない。書き込みの口を1つも作らない。
//
// 使い方: OTA_ROOT=~/ota OTA_PORT=8788 node tools/ota-server.mjs

import { createServer } from "node:http";
import { createReadStream, statSync, realpathSync } from "node:fs";
import { join, extname, resolve, sep } from "node:path";
import { homedir } from "node:os";

const ROOT = realpathSync(resolve(process.env.OTA_ROOT || join(homedir(), "ota")));
const PORT = Number(process.env.OTA_PORT || 8788);

// 表に在る型だけ。知らない拡張子は `application/octet-stream` に落とす ——
// 推測して text/html を返すと、置いた覚えの無い file が頁として解釈されうる。
const TYPES = {
  ".ipa": "application/octet-stream",
  ".plist": "application/xml",
  ".html": "text/html; charset=utf-8",
};

/** ROOT の中へ解決できた実体の path。出来なければ null(= 404 にする)。 */
function safeResolve(urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath.split("?")[0]);
  } catch {
    return null; // 壊れた %エスケープ。推測しない
  }
  if (decoded.includes("\0")) return null;
  const candidate = resolve(join(ROOT, "." + decoded));
  let real;
  try {
    real = realpathSync(candidate);
  } catch {
    return null; // 無い
  }
  // ★`startsWith(ROOT)` だけでは足りない: `/Users/x/ota-evil` が `/Users/x/ota` で
  //   始まってしまう。区切りまで含めて比べる。
  if (real !== ROOT && !real.startsWith(ROOT + sep)) return null;
  return real;
}

const server = createServer((req, res) => {
  const done = (code, body = "") => {
    res.writeHead(code, { "content-type": "text/plain; charset=utf-8" });
    res.end(body);
  };

  if (req.method !== "GET" && req.method !== "HEAD") return done(405, "GET only\n");

  let target = safeResolve(req.url || "/");
  if (!target) return done(404, "not found\n");

  let st;
  try {
    st = statSync(target);
  } catch {
    return done(404, "not found\n");
  }

  if (st.isDirectory()) {
    // ★一覧を作らない。index.html が在ればそれ、無ければ 404。
    const idx = join(target, "index.html");
    try {
      st = statSync(idx);
      target = idx;
    } catch {
      return done(404, "not found\n");
    }
  }
  if (!st.isFile()) return done(404, "not found\n");

  const type = TYPES[extname(target).toLowerCase()] || "application/octet-stream";
  res.writeHead(200, {
    "content-type": type,
    "content-length": String(st.size),
    // 束は焼き直しで同じ名前のまま中身が変わる。電話に古い物を掴ませない。
    "cache-control": "no-store",
  });
  if (req.method === "HEAD") return res.end();
  createReadStream(target).pipe(res);
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[ota] ${ROOT} を 127.0.0.1:${PORT} で配る(GET/HEAD のみ・一覧なし)`);
});
