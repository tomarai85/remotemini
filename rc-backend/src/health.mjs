// 生存信号の**判定**だけを持つ層。DESIGN §7-P。
//
// なぜ台本(shell)でなくここに在るか: 台本の中に判定を書くと、単体でも変異でも掴めない
// (§2.13 の `resumeDecision` / `app.html` と同じ理由)。監視の判定は「鳴らない」形で
// 壊れるのが一番怖い —— 鳴らない事は放っておくと**一生気付けない**ので、
// 検査の届く層に置く事が特に効く。
//
// node の API を import しない。時刻も乱数も**引数で受ける**(純関数)。
// 台本側が `date +%s` を渡す。ここで `Date.now()` を呼ぶと検査が時計に依存する。

/** 監視を始めた直後の状態。まだ一度も測っていない = `unknown`。 */
export function initialHealthState() {
    return { status: "unknown", fails: 0, firstFailAt: null, owed: null };
}

/**
 * 「借り」を返した = 通知が出し先に**渡り終えた**事を記録する。
 *
 * ★状態の項は `owed` ひとつで、意味もひとつ:
 *   **「Tom にまだ伝えていない変化」**。`null` = 借り無し。
 *
 * なぜ `status` と別に持つか(2026-08-02、実際に再現させてから足した):
 * 元は `status === "down"` の一語が「落ちていると観測した」と「もう知らせた」の
 * 二役を持っていた。すると **通知に失敗しても『知らせた』側が確定する** ので、
 * 次からは `notify === null` になり、落ちたままなのに永久に沈黙する。
 * 再現した実測: 出し先を壊した状態で3回叩く → 状態は `down` に確定・通知 0 通 →
 * **出し先を直して更に3回叩いても 0 通**。ログには「鳴らさない」と正常同然に出る。
 * これは yoda の 46 時間と同じ「静かに鳴らない」形 = この層が防ぐ為に在る当のもの。
 *
 * ★なぜ真偽値(`announced`)をやめて借用書そのものを持つか(同日、更に一段深い再現):
 * 真偽値は**落下にしか付いていなかった**ので、「戻りました」が届かなかった時に
 * 鳴り直す術が無かった。実測: 落下は届く / 復帰だけ出し先が壊れている並びで
 * **落下は3回鳴り直し、復帰は0回** —— Tom は復旧済みの物を落ちたままだと思い続ける。
 * 種類を問わず「未配達の変化」を1つ持てば、この非対称は構造から消える。
 */
export function markDelivered(state) {
    return { ...state, owed: null };
}

/**
 * 1回の観測を状態に畳む。
 *
 * @param prev   {{status:"unknown"|"up"|"down", fails:number, firstFailAt:number|null}}
 * @param probe  {{ok:boolean, reason?:string}}  ok=false の理由は文字列で持ち回る
 * @param now    {number}  epoch 秒(台本が渡す)
 * @param opts   {{threshold?:number}}  既定 3 回連続で「落ちた」
 * @returns {{state:object, notify:null|{kind:"down"|"recovered", since:number, seconds:number, reason:string}}}
 */
export function healthTransition(prev, probe, now, opts = {}) {
    const threshold = opts.threshold === undefined ? 3 : opts.threshold;

    // ★閾値を守る。0 や負や小数を許すと「何回失敗しても鳴らない」監視が黙って作れる。
    //   `ring.mjs` の capacity と同じ形の門(素通りさせると下流の前提が崩れる)。
    if (!Number.isInteger(threshold) || threshold < 1) {
        throw new Error(`threshold は 1 以上の整数(受け取った値: ${String(threshold)})`);
    }
    if (!Number.isFinite(now)) {
        throw new Error(`now は数値(受け取った値: ${String(now)})`);
    }

    if (probe.ok) {
        // ★「戻った」は**落ちたと言った後**だけ。`unknown` からの初回成功で祝わない
        //   (監視を入れた瞬間に「復帰しました」と鳴るのは、何も起きていないのに鳴る事)。
        if (prev.status === "down") {
            const note = {
                kind: "recovered",
                since: prev.firstFailAt,
                seconds: prev.firstFailAt === null ? 0 : now - prev.firstFailAt,
                reason: "",
            };
            return {
                state: { status: "up", fails: 0, firstFailAt: null, owed: note },
                notify: note,
            };
        }
        // ★届かなかった「戻りました」は、届くまで鳴らし直す(落下と同じ扱い)。
        //   文面は**凍結**する —— 復旧はもう起きた出来事なので、落ちていた長さは動かない。
        //   ここを再計算すると「1時間落ちていました」が10分ごとに伸びる嘘になる。
        if (prev.owed !== null && prev.owed !== undefined && prev.owed.kind === "recovered") {
            const note = { ...prev.owed };
            return {
                state: { status: "up", fails: 0, firstFailAt: null, owed: note },
                notify: note,
            };
        }
        return {
            state: { status: "up", fails: 0, firstFailAt: null, owed: null },
            notify: null,
        };
    }

    const firstFailAt = prev.fails === 0 ? now : prev.firstFailAt;
    const fails = prev.fails + 1;
    const reason = probe.reason === undefined ? "" : probe.reason;

    // ★「落ちていると**既に伝え終えた**」= down かつ借り無し。この一行だけが黙る条件。
    //   `prev.status === "down"` を落とすと、借り無しの `up`/`unknown` まで「伝え済み」に
    //   見えて **初回の落下が一度も鳴らない**。境界をここで1行にして固定する。
    //   ★`null`(= 借り無し = 返済済み)と `undefined`(= 項が無い = **伝えたか分からない**)
    //   を混ぜない。古い状態ファイルには項が無く、それを「返済済み」と読むと
    //   **上げ直した瞬間に落下が一度も鳴らない**。分からない時は必ず「伝えていない」側へ。
    const toldItsDown = prev.status === "down" && prev.owed === null;

    // ★既に「落ちた」と**届いた**後は、失敗が続いても鳴らさない。
    //   10分ごとに鳴り続ける監視は、見る側が黙らせるので結局気付けなくなる。
    //   逆に**届いていない**なら、閾値を越えている限り毎回鳴らし直す —— 出し先が
    //   直った瞬間に届く事の方が、重複より遥かに大事(重複は騒々しいだけ、沈黙は致命)。
    if (fails >= threshold && !toldItsDown) {
        // 未配達の「戻りました」が残っていても、ここで**上書きする**。
        // 借りは常に「今の状態」を指すべきで、過去の履歴を溜める箱ではない
        // (今落ちているのに『戻りました』を後から配達するのは、嘘を遅れて届ける事)。
        const note = { kind: "down", since: firstFailAt, seconds: now - firstFailAt, reason };
        return { state: { status: "down", fails, firstFailAt, owed: note }, notify: note };
    }

    // 閾値未満 = まだ「落ちた」と言わない。ただし `up` とも言い張らない。
    // 状態はそのまま持ち越す(実行中に閾値を上げた場合に、落ちている物を黙って
    // `up` に戻さない為)。借りも持ち越す —— まだ返していないので。
    return {
        state: { status: prev.status, fails, firstFailAt, owed: prev.owed },
        notify: null,
    };
}

/**
 * 通知の文面。**中身を載せない**(§7-P「落ちた事実 + 何時から、まで」)。
 * セッション名も cwd も会話も入れない = 通知経路に秘密を流さない。
 */
export function healthMessage(notify, host, fmtTime) {
    if (notify === null) return null;
    const when = fmtTime(notify.since);
    if (notify.kind === "down") {
        const why = notify.reason === "" ? "" : `(${notify.reason})`;
        return `rc-backend が応答しません: ${host} — ${when} から ${humanSeconds(notify.seconds)} ${why}`.trim();
    }
    return `rc-backend が戻りました: ${host} — ${when} から ${humanSeconds(notify.seconds)} 落ちていました`;
}

/** 秒を人の語に。分未満は秒で言う(「0分」と言わない為)。 */
export function humanSeconds(sec) {
    if (!Number.isFinite(sec) || sec < 0) return "不明な時間";
    if (sec < 60) return `${Math.floor(sec)}秒`;
    const m = Math.floor(sec / 60);
    if (m < 60) return `${m}分`;
    const h = Math.floor(m / 60);
    const rem = m % 60;
    return rem === 0 ? `${h}時間` : `${h}時間${rem}分`;
}
