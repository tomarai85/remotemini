// 口座の使用量の**測り直しの間隔**が、失敗中に暴走しないか(2026-08-29、Codex の指摘1)。
//
// ── 何を守るか ────────────────────────────────────────────────────────────────
// `usageCache.at` は「最後に**成功**した時刻」。当初の実装は測り直しの可否をこれだけで
// 決めていたので、期限切れの後に測り直しが失敗し続けると `at` が永久に古いまま =
// **要求のたびに** `security` + `cswap` の子プロセスが立った。single-flight は同時実行を
// 1本にするだけで、連続実行を止めない。
//
// 実測(2026-08-29 friday): `/api/account` は 20-23 回/時。恒久障害(keychain が締まる /
// 道具が消える)なら、その頻度で子プロセスを起こし続けていた。
//
// 直しは「**試した時刻**(`lastAttemptAt`)を成功時刻から分ける」+ 指数 backoff。
//
// ★此処が測るのは**純関数の判定だけ**(`usageRefreshDue` / `usageBackoffMs`)。
//   子プロセスの実起動は測らない —— 起こすと検査が机の keychain に触る。
import { test } from "node:test";
import assert from "node:assert/strict";
import { usageRefreshDue, usageBackoffMs } from "../src/usage.mjs";

const TTL = 300_000;
const base = () => ({ at: 0, byEmail: null, inflight: null, lastAttemptAt: 0, failures: 0 });

test("失敗 0 回なら TTL だけが効く(従来の振る舞いを壊していない)", () => {
  const s = { ...base(), at: 1_000_000 };
  assert.equal(usageRefreshDue(s, 1_000_000 + TTL - 1, TTL), false, "TTL 内は測り直さない");
  assert.equal(usageRefreshDue(s, 1_000_000 + TTL + 1, TTL), true, "TTL を過ぎたら測り直す");
});

test("飛んでいる最中は決して重ねない(single-flight)", () => {
  const s = { ...base(), at: 0, inflight: Promise.resolve(), failures: 5, lastAttemptAt: 0 };
  assert.equal(usageRefreshDue(s, 10 ** 12, TTL), false);
});

test("★失敗中は backoff が支配する —— 要求のたびに立てない(此れが本題)", () => {
  // 1回失敗した直後: 30 秒は待つ
  const s = { ...base(), at: 0, failures: 1, lastAttemptAt: 1_000_000 };
  assert.equal(usageRefreshDue(s, 1_000_000 + 1_000, TTL), false, "1秒後に再試行してはいけない");
  assert.equal(usageRefreshDue(s, 1_000_000 + 29_000, TTL), false, "29秒後もまだ");
  assert.equal(usageRefreshDue(s, 1_000_000 + 30_000, TTL), true, "30秒経てば再試行してよい");

  // ★対照の核心: 直す前の判定(`at` だけを見る)なら、同じ入力で**必ず true**になる。
  //   `at = 0`(一度も成功していない)なので `now - 0 > TTL` は常に真 = 毎回子プロセス。
  const oldPredicate = (st, now) => now - st.at > TTL;
  assert.equal(oldPredicate(s, 1_000_000 + 1_000), true,
    "旧判定は1秒後でも測り直しに行く = 此の検査が守っている当の欠陥");
});

test("backoff は指数で伸び、上限で止まる(青天井にしない)", () => {
  assert.equal(usageBackoffMs(0), 0, "失敗していなければ待たない");
  assert.equal(usageBackoffMs(1), 30_000);
  assert.equal(usageBackoffMs(2), 60_000);
  assert.equal(usageBackoffMs(3), 120_000);
  // 上限 30 分で頭打ち。伸び続けると、直った時に何時間も気付かない。
  assert.equal(usageBackoffMs(20), 30 * 60_000);
  assert.ok(usageBackoffMs(7) <= 30 * 60_000);
});

test("恒久障害でも子プロセスの起動回数が有界(1時間あたり)", () => {
  // 失敗が続く1時間に何回起動するかを数える。要求は1分に1回来ると仮定(実測 20-23回/時 より多い)。
  const s = { ...base(), at: 0, failures: 0, lastAttemptAt: 0 };
  let spawns = 0;
  for (let t = 0; t <= 3_600_000; t += 60_000) {
    if (usageRefreshDue(s, t, TTL)) {
      spawns += 1;
      s.lastAttemptAt = t;
      s.failures += 1; // 毎回失敗する世界
    }
  }
  // 30s,60s,120s,240s,480s,960s,1920s… と伸びるので、1時間で 10 回未満に収まる。
  assert.ok(spawns < 10, `1時間の起動が ${spawns} 回 = 多すぎる(backoff が効いていない)`);
  // 旧判定なら 61 回(1分ごとの全要求で起動)。
  assert.ok(spawns < 20, "旧実装の 61 回から桁で減っている事");
});
