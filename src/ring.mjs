// SSE 再接続追いつき用の固定長イベントリング。
//
// なぜ要るか: 本家 RC は再接続の再構築中に発生した更新をキューし、回復後に配送する
// (v2.1.207 でこの取りこぼしを修正した経緯が公式に残っている)。同じ穴を最初から
// 掘らないための部品。クライアントは Last-Event-ID(= seq)を持って再接続し、
// since(seq) で差分を受け取る。リングから溢れていたら gap=true — その時クライアントは
// 差分でなく /history の読み直しへ倒す(嘘の連続性を作らない)。
export class EventRing {
  constructor(capacity = 512) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error(`EventRing: capacity must be a positive integer, got ${capacity}`);
    }
    this.capacity = capacity;
    this.buf = [];
    this.nextSeq = 1;
  }

  /** イベントを積んで seq を返す。 */
  push(data) {
    const seq = this.nextSeq++;
    this.buf.push({ seq, data });
    if (this.buf.length > this.capacity) this.buf.shift();
    return seq;
  }

  /**
   * seq より後のイベント列を返す。返り値は Array で、リングから溢れて
   * 連続性を保証できない場合のみ .gap = true が付く。
   */
  since(seq) {
    const out = this.buf.filter((e) => e.seq > seq);
    // 溢れ判定: 要求 seq の「次」の要素がもう保持されていなければ、間が失われている。
    // 空リングでは oldestHeld = nextSeq となり、まだ何も失っていない起点(seq=nextSeq-1
    // 以上)からの購読では偽にならない。
    const oldestHeld = this.buf.length > 0 ? this.buf[0].seq : this.nextSeq;
    if (seq + 1 < oldestHeld) out.gap = true;
    return out;
  }
}
