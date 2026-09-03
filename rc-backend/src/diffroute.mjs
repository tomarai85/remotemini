/**
 * `GET /api/sessions/<id>/diff` の口の**挙動**(2026-09-03、Codex #4 の 4)。
 *
 * `server.mjs` は import した瞬間に listen するので、口の挙動を単体から呼べなかった =
 * 検査は正規表現(`test/diff-routes.test.mjs`)だけで、`onClose` を空にしても listener を解除
 * しなくても通っていた。此処に切り出して、偽の `req` / `res` で**実際に**通す
 * (`test/diff-route-handler.test.mjs`)。`server.mjs` は此の関数へ委ねるだけ。
 *
 * 守る線(全部 挙動で測る):
 *   - cwd 無し → 200 + `reason: "no_cwd"`、git は撃たない
 *   - 要求の `close` → AbortSignal が鳴る(順番待ちから外れる)。`aborted` には**何も書かない**
 *   - `busy` → **503**(封筒は普段の形)
 *   - 普通 → 200
 *   - 応答の前後で `close` の listener を必ず外す(keep-alive の接続で溜めない)
 *
 * @param {object} o
 * @param {import("node:events").EventEmitter} o.req  `on` / `off` を持つ物
 * @param {object} o.res
 * @param {string|null} o.cwd
 * @param {Function} o.readWorkingDiff  `(cwd, {signal}) => Promise<{files,truncated,totalBytes,reason}>`
 * @param {Function} o.json  `(res, code, obj) => any`
 * @param {Function} o.diffBody  封筒(`wire.mjs`)
 */
export async function handleDiffGet({ req, res, cwd, readWorkingDiff, json, diffBody }) {
  if (!cwd) {
    return json(res, 200, diffBody({ files: [], truncated: false, totalBytes: 0, reason: "no_cwd" }));
  }
  const ac = new AbortController();
  const onClose = () => ac.abort();
  req.on("close", onClose);
  let r;
  try {
    r = await readWorkingDiff(cwd, { signal: ac.signal });
  } finally {
    req.off("close", onClose);
  }
  if (r.reason === "aborted") return undefined; // 相手が居ない。書く先が無い
  if (r.reason === "busy") return json(res, 503, diffBody(r));
  return json(res, 200, diffBody(r));
}
