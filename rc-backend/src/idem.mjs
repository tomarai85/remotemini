/**
 * idem.mjs — 同じ送信を2回打たない。2026-08-26 新設。
 *
 * なぜ要るか(実測で確かめた穴)
 *   本番の机に同じ本文を2回投げたら、**2回とも `accepted: true / delivered: verified` で
 *   通り、実画面に2回入った**。電話の `.unreachable` は「もう一度やれば通るかもしれない」と
 *   定義されていて下書きも残るので、**タイムアウトしたが実は届いていた**場合、
 *   再送で同じ指示が2回実行される。Codex 2026-08-26 が「これが1位」と言った所。
 *
 * ★何を鍵にするか: **電話が作る1つの論理送信に1つの鍵**。再送では同じ鍵を使い回す。
 *   本文の hash にしない —— 「同じ文を意図的に2回打つ」が出来なくなる。
 *   2回打ちたい時は新しい鍵で打つ、が正しい形。
 *
 * ★守る一線
 *   1. **同じ鍵で違う本文が来たら断る。** 鍵の使い回しは電話側の間違いで、
 *      黙って通すと「1回目の結果が2回目の応答として返る」= 一番診断しにくい嘘になる。
 *   2. **完了を記録する位置を間違えない。** 打つ**前**に鍵を予約し、打った**後**に結果を
 *      書く。前だけだと落ちた時に永久に打てなくなり、後だけだと同時の2本が両方通る。
 *   3. **憶えている事に上限を置く。** 無限に持つと、長く動いている机で静かに太る。
 *   4. **本文を残さない。** 鍵と結果だけ。この repo が明示的に選んでいる
 *      「打った物の中身をログに残さない」線を、ここでも越えない
 *      (Codex 追認: log は注入され得るエージェントと同じ機械に在るので、
 *       中身を残すのは足すより失う方が大きい)。
 */
import { createHash } from "node:crypto";

/** 憶えておく件数の上限。超えたら古い順に忘れる。 */
export const IDEM_MAX = 500;

/** 憶えておく時間。これを過ぎた鍵は「知らない」に戻る(再送は届かないほど遅い)。 */
export const IDEM_TTL_MS = 10 * 60 * 1000;

/** 鍵の形。電話が作る物なので、受け取る前に形を検める。 */
export function validKey(k) {
  return typeof k === "string" && /^[A-Za-z0-9_-]{8,64}$/.test(k);
}

/**
 * 本文の同一性は**中身を持たずに**比べたい。指紋だけ持つ。
 * ★これは「本文を残さない」線を越えない —— 指紋から本文は戻せない。
 *   ただし**総当たりで当てられる**ので、指紋は log にも応答にも出さない(記憶の中だけ)。
 */
function fingerprint(text) {
  return createHash("sha256").update(String(text), "utf8").digest("hex");
}

export function createIdemStore(o = {}) {
  const max = o.max ?? IDEM_MAX;
  const ttl = o.ttl ?? IDEM_TTL_MS;
  const now = o.now ?? (() => Date.now());
  /** key -> { fp, at, state: "in-flight"|"done", result } */
  const m = new Map();

  const sweep = () => {
    const t = now();
    for (const [k, v] of m) if (t - v.at > ttl) m.delete(k);
    while (m.size > max) m.delete(m.keys().next().value);   // 挿入順 = 古い順
  };

  return {
    /**
     * 打つ**前**に呼ぶ。
     * @returns {{go:true} | {go:false, why:"duplicate", result:any} | {go:false, why:"in-flight"} | {go:false, why:"key-reused"}}
     */
    begin(key, text) {
      // ★掃くのは**読む前**。後にすると、期限切れの記録を先に掴んで
      //   「まだ憶えている」と答えてしまう(検査が掴んだ)。
      sweep();
      const fp = fingerprint(text);
      const prev = m.get(key);
      if (!prev) {
        m.set(key, { fp, at: now(), state: "in-flight", result: null });
        // ★入れた**後**にもう一度だけ上限を見る。前だけだと今入れた1件が
        //   計算から漏れて、1件ずつ超過し続ける(これも検査が掴んだ)。
        while (m.size > max) m.delete(m.keys().next().value);
        return { go: true };
      }
      // ★同じ鍵で違う本文 = 電話側の間違い。黙って通すと嘘の応答を返す事になる。
      if (prev.fp !== fp) return { go: false, why: "key-reused" };
      if (prev.state === "in-flight") return { go: false, why: "in-flight" };
      return { go: false, why: "duplicate", result: prev.result };
    },

    /** 打った**後**に呼ぶ。ここで初めて「済んだ」になる。 */
    finish(key, result) {
      const e = m.get(key);
      if (!e) return;
      e.state = "done";
      e.result = result;
      // ★`at` を更新しない。TTL の起点は**予約した時刻**(= 電話がその送信を始めた時)で、
      //   打ち終わった時刻ではない。更新すると、遅い送信ほど長く憶える事になり、
      //   「憶えている時間」が測る対象と噛み合わなくなる(検査が掴んだ)。
    },

    /**
     * 打つ前に落ちた時に呼ぶ。予約を外して**次の再送が通る様に**する。
     * ★これが無いと、1回失敗した鍵で永久に打てなくなる。
     */
    abandon(key) { m.delete(key); },

    size() { return m.size; },
  };
}

/** 断りの文。**中身も指紋も出さない。** */
export const IDEM_REFUSAL = {
  "in-flight": "The same send is still in flight. Wait for it rather than sending again.",
  "key-reused": "That send id was already used for different text. Use a new one.",
};
