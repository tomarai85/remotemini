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


// ── 1要求1行の記録(2026-08-30)────────────────────────────────────────────────
// なぜ要るか: この口は build 89 を Tom の電話へ運んだ経路だが、何も記録していなかった ——
// 「開いたが入らなかった」と「一度も開いていない」が**ログから区別できない**。
// 実際 2026-08-29 に「tap したか」を答えられず、Tom に口頭で訊く以外に手が無かった。
//
// ★秘密の一段を**そのまま書かない**。この口の唯一の守りは推測できない 24 桁 hex で、
//   それを log に書けば、log を読める者に配布物が渡る(friday には athenas 以外に
//   tomtim / udagawa が居る = 08-28 に `chmod 700 ~/ota` で塞いだのと同じ穴)。
//   残すのは**形だけ**: `/<secret>/RemoteMini.ipa` → `/:secret/RemoteMini.ipa`。
// ★UA も生で書かない。`src/reqlog.mjs` の `clientClass` と同じ**閉じた語**へ落とす ——
//   生の UA には端末の型番と OS 版が入る。分類は独立の実装にせず綴りだけ合わせる
//   (此処は tools/ で src/ を import しない層なので、写しである事を明示しておく)。
// ★2026-08-30、Codex の指摘1: 「長い hex を畳む」は**文字列のヒューリスティック**で、
//   percent-encoding(`/ab%63d…`)・接尾辞(`/<secret>;x`)・absolute-form
//   (`GET http://host/<secret>x`)で秘密がそのまま出る。堅い形は長さでも文字種でもなく
//   **既知のルートだけを型で記録し、それ以外は1つの定数へ畳む**事。
//   副作用として、長大 URL による**ログ増幅(指摘2)も同時に塞がる** —— 行長が有界になる。
const KNOWN_LEAF = new Set(["manifest.plist", "index.html", ""]);
const IPA = /\.ipa$/i;

/**
 * 記録に出す path。**元の文字列を一切通さない**(白名簿から組み立てる)。
 *   `/<secret>/manifest.plist` → `/:secret/manifest.plist`
 *   `/<secret>/RemoteMini.ipa` → `/:secret/:ipa`
 *   `/<secret>/`               → `/:secret/`
 *   それ以外(404 の的・攻撃・打ち間違い)→ `/:other`
 */
export function otaPathShape(urlPath) {
  const clean = String(urlPath || "/").split("?")[0].split("#")[0];
  const parts = clean.split("/");
  // 期待する形は ["", <secret>, <leaf>] の3片だけ。増減はすべて `/:other`。
  if (parts.length !== 3 || parts[0] !== "") return "/:other";
  const leaf = parts[2];
  if (IPA.test(leaf)) return "/:secret/:ipa";
  if (KNOWN_LEAF.has(leaf)) return `/:secret/${leaf}`;
  return "/:other";
}

/** `src/reqlog.mjs` の `clientClass` と同じ語彙(app / probe / tool / none / other)。 */
export function otaClientClass(userAgent) {
  const ua = String(userAgent || "");
  if (!ua) return "none";
  if (/^rc-live-/i.test(ua)) return "probe";
  // iOS の installd はここに落ちる(CFNetwork/Darwin)。Safari も同じ語になるが、
  // **この口に来る CFNetwork は installd か Safari のどちらか**で、どちらも「電話が来た」。
  if (/CFNetwork|Darwin/i.test(ua)) return "app";
  if (/curl|wget|node|undici|python|libwww/i.test(ua)) return "tool";
  return "other";
}

function logReq(req, code, bytes) {
  // 1行6欄。増やす時は此処だけ。`[ota] req` を頭に置くのは rc-backend の `[rc-backend] req` と
  // 同じ形にして、grep を1つの流儀で済ませる為。
  //
  // ★`bytes` / `code=200` は「**Node が OS へ渡し切った**」であって「電話が受け取って
  //   入れられた」ではない(Codex の指摘3)。この計器が答えられるのは
  //   「取りに来たか」「途中で切れたか」までで、install の成否は答えられない。
  // ★書き込みのエラーを飲む。stdout は launchd が普通のファイルへ向けているので、
  //   ディスクが満杯だと write が投げてプロセスごと落ちうる —— 配布が止まる方が、
  //   1行記録できない事より遥かに高くつく。
  try {
    process.stdout.write(
      `[ota] req ${new Date().toISOString()} ${req.method} ${otaPathShape(req.url)} `
      + `client=${otaClientClass(req.headers["user-agent"])} code=${code} bytes=${bytes}\n`,
      () => {},
    );
  } catch { /* 記録できない事は配布を止める理由にならない */ }
}

const server = createServer((req, res) => {
  const done = (code, body = "") => {
    res.writeHead(code, { "content-type": "text/plain; charset=utf-8" });
    res.end(body);
    logReq(req, code, Buffer.byteLength(body));
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
  const head = {
    "content-type": type,
    "content-length": String(st.size),
    // 束は焼き直しで同じ名前のまま中身が変わる。電話に古い物を掴ませない。
    "cache-control": "no-store",
  };
  // HEAD は中身を開けない —— 開く必要が無い上に、開けば下の失敗経路を無駄に踏む。
  if (req.method === "HEAD") { res.writeHead(200, head); logReq(req, 200, 0); return res.end(); }

  // ★★読み取りの失敗で**プロセスごと死ぬ**穴を塞ぐ(2026-08-30、実測で落として確認)。
  //   `stream.pipe(res)` は読み手のエラーを転送せず、`error` に聞き手が居なければ
  //   Node は投げる = **配布口が丸ごと落ちる**。実演: 束を `chmod 000` にして1回叩くと
  //   `EACCES` で死に、以後は正常な file も `000`(接続すら出来ない)になった。
  //   `statSync` が通っても `open` は落ちうる —— stat は読み権限を要らないし、
  //   stat と open の間に消える事も在る。同時要求が増えれば `EMFILE` も同じ形で来る
  //   (**それは此の口が晒されている連打そのもの**)。
  //
  //   ★`open` を待ってから頭を書く。初版の順(先に 200 を書いてから開く)だと、
  //     失敗した時には既に 200 が出ているので、**嘘の 200 を送った後で切る**しか無い。
  //     開けた事を確かめてから 200 を書けば、失敗は素直に 404 として出せる。
  let sent = 0;
  const stream = createReadStream(target);

  stream.once("error", () => {
    // 頭がまだなら 404。既に出ていれば切るしかない(`close` が code=0 を残す)。
    if (!res.headersSent) return done(404, "not found\n");
    res.destroy();
  });

  stream.once("open", () => {
    // 開く前に客が切っていたら、頭も書かず fd も持ち続けない。
    if (res.destroyed || res.writableEnded) return stream.destroy();
    res.writeHead(200, head);
    // ★送った**実バイト**を自分で数える。初版は `res.bytesWritten` を書いたが、あれは
    //   `ServerResponse` に存在しない属性で、ログに `bytes=undefined` が出ていた。
    //   タスクの verifier は GET の行数しか数えないので**緑のまま通った** ——
    //   「検査が測っていない範囲」の実例なので、直しと一緒に此処へ残す。
    // ★`finish` ではなく `close` で記録する。`finish` は送り切った時しか出ないので、
    //   中断(電話が圏外へ出た / installd が諦めた)が**1行も残らない** —— それは
    //   「tap したのに入らなかった」を潰す当の欠陥と同じ形。`close` は必ず出る。
    //   送り切ったかは `writableFinished` で分け、中断は `code=0`
    //   (`src/reqlog.mjs` の実ログが `code=0 reason=aborted` を使うので綴りを合わせる)。
    stream.on("data", (chunk) => { sent += chunk.length; });
    res.on("close", () => { logReq(req, res.writableFinished ? 200 : 0, sent); stream.destroy(); });
    stream.pipe(res);
  });
});

// ★最後の網。上で塞いだ経路の外にも、まだ知らない投げ方が在りうる —— 配布口が
//   黙って消えるより、一行残して生き続ける方が良い(此の口は無人で回る)。
//   ★これは上の `stream.once("error")` の**代わりではない**。此処だけに頼ると
//     「落ちはしないが、その要求に何が起きたか分からない」状態になる。
process.on("uncaughtException", (e) => {
  try { process.stdout.write(`[ota] uncaught ${new Date().toISOString()} ${e?.code || ""} ${e?.message || e}\n`, () => {}); } catch { /* 記録できない事は配布を止める理由にならない */ }
});

// ★送信の上限(2026-08-30、Codex の指摘3の後半)。客が**切らずに読むのを止める**と、
//   `close` が出ないので**1行も記録されない** —— 「取りに来たのに終わらなかった」が
//   計器から消える、この計器が塞ぐべき当の穴と同じ形。
//   5分 = tailnet 越しに 1.9MB の束を配るのに桁で足りる長さ(実測は秒)。
//   切った時は `close` が出るので `code=0` として残る。
server.requestTimeout = 0;                 // 要求の読みは即終わる(GET/HEAD のみ)
server.headersTimeout = 30_000;
server.on("connection", (socket) => { socket.setTimeout(300_000, () => socket.destroy()); });

server.listen(PORT, "127.0.0.1", () => {
  console.log(`[ota] ${ROOT} を 127.0.0.1:${PORT} で配る(GET/HEAD のみ・一覧なし)`);
});
