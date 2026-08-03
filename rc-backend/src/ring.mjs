// SSE 再接続追いつき用の固定長イベントリング。
//
// なぜ要るか: 本家 RC は再接続の再構築中に発生した更新をキューし、回復後に配送する
// (v2.1.207 でこの取りこぼしを修正した経緯が公式に残っている)。同じ穴を最初から
// 掘らないための部品。クライアントは Last-Event-ID(= seq)を持って再接続し、
// since(seq) で差分を受け取る。リングから溢れていたら gap=true — その時クライアントは
// 差分でなく /history の読み直しへ倒す(嘘の連続性を作らない)。

/**
 * 量の既定上限(1 リングあたり)。
 *
 * 導出: `server.mjs` は 1 会話あたり `new EventRing(256)`、`worker.mjs` は 512。
 * 件数だけの門は**1件の大きさを問わない**ので、tool 結果が数 MB になる 1 行が来ると
 * 256 件 x 数 MB がそのまま常駐する。会話は `feeds` / `this.rings` に溜まり続ける
 * (どちらも掃除する口が無い)ので、上限が件数だけだと**会話数 x 1件の大きさ**で伸びる。
 * 4MiB = 256 件 x 16KiB。会話 20 本でも 80MiB に収まり、Mac mini で生き残る。
 *
 * ★名前の意味を厳密に: これは**保持しているイベント合計の目標上限**であって、
 *   常駐量の硬い天井ではない(`push` の「最新1件は落とさない」を見よ)。
 */
const DEFAULT_MAX_BYTES = 4 * 1024 * 1024;

/**
 * data の大きさ。**送出と同じ物差し**で測る。
 *
 * `JSON.stringify` は下流(`sendEvent` / `res.write(...JSON.stringify(e.data))`)が
 * どの道通す操作なので、ここで測る事は新しい失敗経路を増やさない —— 測れない値は
 * **元々配れない値**である。だから循環参照や BigInt はここで throw させる(fail-closed)。
 * 採番の**前**に測るので、撥ねた時に seq に穴は空かない。
 *
 * ★既知の代償(Codex 指摘、2026-08-04): 同じ物を **2 回** serialize している
 *   (ここで測る分と、送出時の `JSON.stringify(e.data)`)。1 回だけ serialize して
 *   文字列ごと保持し送出でも使い回すのが最善だが、`since()` の返す `e.data` を
 *   `e.data.kind` / `e.data.entries` / `e.data.type` で読んでいる呼び手が
 *   `server.mjs` / `worker.mjs` と検査 8 本に散っているので、別件として置く。
 */
function sizeOf(data) {
  const s = JSON.stringify(data);
  if (s === undefined) {
    // `undefined` / 関数 / Symbol。SSE の data 欄に載らない物が黙って積まれるのを止める。
    throw new Error("EventRing: data must be JSON-serializable (got undefined after stringify)");
  }
  return Buffer.byteLength(s, "utf8");
}

export class EventRing {
  /**
   * @param {number} [capacity] 件数の上限
   * @param {{maxBytes?:number}} [opts] 量の上限(既定 4MiB)
   */
  constructor(capacity = 512, opts = {}) {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new Error(`EventRing: capacity must be a positive integer, got ${capacity}`);
    }
    const maxBytes = opts.maxBytes === undefined ? DEFAULT_MAX_BYTES : opts.maxBytes;
    // ★capacity と**同じ形の門**にする。0 や負を許すと、push の度に量の門が全部落とし、
    //   「最新1件しか残らないリング」が例外も無く静かに出来る(R5 が防いでいる事故の量版)。
    if (!Number.isInteger(maxBytes) || maxBytes < 1) {
      throw new Error(`EventRing: maxBytes must be a positive integer, got ${maxBytes}`);
    }
    this.capacity = capacity;
    this.maxBytes = maxBytes;
    this.buf = [];
    this.bytes = 0; // buf の合計。push の度に増減で持つ(全部足し直すと O(n) になる)
    this.nextSeq = 1;
  }

  /** イベントを積んで seq を返す。 */
  push(data) {
    const bytes = sizeOf(data); // 採番より先。撥ねた時に seq を飛ばさない為
    const seq = this.nextSeq++;
    this.buf.push({ seq, data, bytes });
    this.bytes += bytes;
    // 件数の門(従来)。
    while (this.buf.length > this.capacity) this.bytes -= this.buf.shift().bytes;
    // 量の門。**古い方から**落とすので、溢れは `since()` の既存の gap 判定にそのまま乗る
    // (oldestHeld が前へ進む = 嘘の連続性を作らない)。件数の門と同じ道を通す為の形。
    //
    // ★`length > 1` = **最新の1件は落とさない**。落とすと buf が空になり得て、
    //   下の `: this.nextSeq` が支えている「buf が空 ⟹ nextSeq === 1」が崩れる
    //   (= 退役した変異 R3 の等価性の土台。§R3 の注記を見よ)。
    //   残る穴を名指しで書く: **1件で上限を超えるイベントは、次の push まで残る**。
    //   従ってこのリングの常駐量は `maxBytes` ではなく `max(maxBytes, 最大の1件)`。
    //   それを許すのは、代わりの案が全部もっと悪いから:
    //     - 巨大な1件を**積まずに捨てる** → buf の**途中**に穴が空くが、gap 判定は
    //       先頭しか見ないので `gap` が立たない = **黙って嘘の連続性**を作る。最悪。
    //     - 中身を gap 印に**差し替える** → 印の形は呼び手ごとに違う
    //       (`server.mjs` は `{kind:"gap"}`、`worker.mjs` は `{type:...}`)。
    //       リングが呼び手の約束事を知る事になり、層が壊れる。
    //
    // ★Codex (gpt-5.6-sol xhigh, 2026-08-04) はここを逆向きに押した ——
    //   「不変条件を守る為だけに巨大な1件を保持するのは設計が逆。厳しい量の上限が要るなら
    //     R3 を無効化して、空リングでも `nextSeq` による gap 判定を正として扱う方が自然」。
    //   **採らない。** 理由は不変条件ではなく、**空にすると呼び手側で gap が止まらなくなる**事:
    //   `server.mjs` の poll は 1 件も返せない時に栞を据え置く(`cutSeq === null` → `seq = d.seq`)。
    //   リングが空だと `since()` は毎回 gap を立てるので、次のイベントが来るまで
    //   **poll のたびに電話が /history を読み直す**(最大 280MB の jsonl)。
    //   稀な一時的メモリ山を、稀だが**継続する**読み直し嵐に替える取引になる。
    //   Codex にはこの栞の据え置きを伝えていないので、この一点だけ判断材料が違う。
    //   ★撤回条件: 呼び手が gap の時に栞を先端(`nextSeq - 1`)へ進める様になったら、
    //     嵐は消えるので Codex 案(空を許して量を厳密に縛る)へ倒す。その時は R3 が
    //     **殺せる変異に戻る**(空 + `nextSeq > 1` が現実の入力になる)ので的も戻す事。
    while (this.buf.length > 1 && this.bytes > this.maxBytes) {
      this.bytes -= this.buf.shift().bytes;
    }
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
    // ★この `: this.nextSeq` を `: 0` にしても、**現実に届く入力では挙動が変わらない**
    //   (変異 R3 = 等価変異、2026-08-02 に実測して退役)。差が出るのは since(-1) の1点だけで、
    //   負の seq は src/tail.mjs の `/^\d+$/` で撥ねられ、ここへ到達しない。
    //   ただしそれは「buf が空 ⟹ nextSeq === 1」に依存し、その前提を支える門は**2つ**在る:
    //     (1) constructor の capacity>=1 検査(R5)—— 0 を許すと push の度に全部落ちる
    //     (2) push の量の門の `this.buf.length > 1` —— 最新1件を落とすと空になり得る
    //   **どちらを消してもこの等価性は静かに崩れる。** (2) は 2026-08-04 に量の門を
    //   足した時に生えた支えで、それまでは (1) だけだった —— 門を足すと、既存の等価性が
    //   乗る土台が増える。片方だけ書いておくと、もう片方を消す人に警告が届かない。
    const oldestHeld = this.buf.length > 0 ? this.buf[0].seq : this.nextSeq;
    if (seq + 1 < oldestHeld) out.gap = true;
    return out;
  }
}
