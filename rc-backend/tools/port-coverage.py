#!/usr/bin/env python3
"""C群移植の**分母**を測る —— JS の検査が実際に食わせた入力が、Swift の検査にも在るか。

## 何故これが要るか(2026-08-05、訂正6-1 の直後に書いた)

C群 = client の状態に依存するので JS と Swift の**2実装が併存する**唯一の場所。
担保の建て付けは「サーバ側で一度検査した物を電話側が再利用する」= だから
Sprint 2/3 のブリーフは「**JS の検査ケースを1件残らず Swift へ移す**」と書いている。

その規則は書いてあったのに、`nextHistoryLimit` で破れた。
JS `view.test.mjs` の検査「★nextHistoryLimit: 押すたびに必ず増える」が持つ
`nextHistoryLimit(0) === 150`(理由付きで「まだ0件でも先へ進む」)が Swift に
移っておらず、しかも移っていないその入力こそが `||` と `??` の割れ目だった
(JS 150 / Swift 100)。

原因は「移し忘れ」ではなく**数える道具が無かった**事。ブリーフは `mergeHistory` の
6 件は表にしたのに `nextHistoryLimit` は散文で済ませた。規則の適用範囲は両方なのに、
それを数える物が片方にしか無い = 落ちても誰も気付かない。
DESIGN §2.18-10「守りの届く範囲が、欠陥と一緒に縮む」の、ブリーフ版。

## 測れる物と、測れない物(★ここを読まずに出力を信じない)

第1引数が**スカラ**(数値 / 文字列リテラル / null / undefined / 識別子)なら機械で
突き合わせられる。**構造体**(`{...}` / `[...]` / 関数呼び出し)は突き合わせられない ——
JS と Swift で書き方がまるで違うので、素朴な照合は騒ぐだけ。

実測(2026-08-05、この repo の C群 6 関数):

| 種別 | 出た件数 | 本物 | 偽 |
|---|---|---|---|
| スカラ | 3(`nextHistoryLimit` の `0` / `120` / `480`) | **3** | 0 |
| 構造体 | 13(`readablePoll` 11 / `mergeHistory` 1 / `relTime` 1) | 0 | **13** |

構造体は 13/13 が偽 —— `readablePoll` の Swift 側は 15 本の検査で JS の 12 入力を
名前で全部覆っていた。だからこの道具は**構造体を赤にしない**。
「機械では突き合わせられない: N 件」と数だけ出す。分母を落とさない為であって、
それが緑だと言っている訳ではない。読むのは人。

## 出口
  0 = スカラの入力が全部 Swift 側にも在る
  1 = 見当たらないスカラ入力が在る
  2 = 測れなかった。**0 にも 1 にも丸めない**。3通り在る:
      Swift の検査 file が無い / JS 側に呼び出しが無い /
      JS の検査を名指ししている Swift の検査が**移植表に無い**(= 分母が痩せている)
  ★2 は 1 より強い。分母が信用できない走行で「赤は3件」と言うのは、
    数え漏らした分を 0 と言うのと同じだから。赤の一覧は 2 の時も必ず出す。

## 継ぎ目
  PC_ROOT   … repo の根(既定 = この台本の2つ上)。対照が砂場を指す為に在る
  PC_PORTS  … 移植表の差し替え。`fn=相対path[,相対path];fn=...`
  PC_JS     … JS の検査 file(根からの相対。既定 rc-backend/test/view.test.mjs)
"""
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(os.environ.get(
    "PC_ROOT", pathlib.Path(__file__).resolve().parent.parent.parent))
JS_TEST = ROOT / os.environ.get("PC_JS", "rc-backend/test/view.test.mjs")

# JS 関数 -> その移植を検査している Swift の file。
#
# ★この表は手で同期する一覧なので、**それ自体が訂正6-1 と同じ形の入口**。
#   1行足し忘れると分母が静かに痩せ、痩せた事は誰も報告しない。
#   だから `unlisted_ports()` が disk 側から逆に数える —— JS の検査 file を
#   名指ししている Swift の検査 file で、この表に居ない物を「測っていない」として
#   名前で出す(出口 2)。「表に書いた物が実在するか」(P8)とは**向きが逆**で、
#   守りたいのはこちらの向きの方。
#
# ★導出しきれない分は残っている: 目印の綴りを持たない Swift の検査は逆側から
#   見えない(実測 2026-08-05 = `BackoffTests.swift` の `nextAttempt` が該当。
#   表に在るので今は害が無いが、同種を新設して**表にも書かなければ**素通りする)。
#   取らなかった上限として、黙らせずに書いておく。
DEFAULT_PORTS = {
    "mergeHistory":     ["ios/Tests/Core/MergeHistoryTests.swift"],
    "nextHistoryLimit": ["ios/Tests/Core/NextHistoryLimitTests.swift"],
    "freshness":        ["ios/Tests/Core/FreshnessTests.swift"],
    "relTime":          ["ios/Tests/Core/RelTimeTests.swift"],
    "readablePoll":     ["ios/Tests/Core/ReadablePollTests.swift"],
    "nextAttempt":      ["ios/Tests/Core/BackoffTests.swift"],
}


# 「移していない」が正しい事も在る。だがそれを**散文で片付けると計器が死ぬ** ——
# 永久に赤い計器は、次に読む人が読まなくなるから。だから受理は理由付きで此処に置き、
# 集計に必ず件数で出す(黙って緑にはしない)。
#
# ★受理の一覧もまた腐る手動の一覧なので、**使われていない受理は赤にする**。
#   `test/no-linerefs.test.mjs` の「死んだ免除を残さない」と同じ形。
DEFAULT_ACCEPTED = {
    ("nextHistoryLimit", "480"):
        "Swift は同じ上限の節を `450` で踏んでいる(450+100=550 で栓が効く事まで見える)。"
        "入力の綴りが違うだけで、JS の `480` が測っている性質は移っている。",
}


def load_accepted():
    """継ぎ目 `PC_ACCEPT`(`fn:arg=理由;fn:arg=理由`)。対照が受理の側を測る為に在る。
    ★空文字を渡せば「受理ゼロ」= 受理の機構そのものを外した版も測れる。"""
    raw = os.environ.get("PC_ACCEPT")
    if raw is None:
        return dict(DEFAULT_ACCEPTED)
    out = {}
    for chunk in raw.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        key, _, reason = chunk.partition("=")
        fn, _, arg = key.partition(":")
        out[(fn.strip(), arg.strip())] = reason.strip() or "(理由が空)"
    return out


ACCEPTED = load_accepted()


def load_ports():
    raw = os.environ.get("PC_PORTS")
    if not raw:
        return dict(DEFAULT_PORTS)
    ports = {}
    for chunk in raw.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        fn, _, paths = chunk.partition("=")
        ports[fn.strip()] = [p.strip() for p in paths.split(",") if p.strip()]
    return ports


def first_arg(call_text):
    """呼び出しの中身から、トップレベルの最初の引数だけを返す。
    括弧と引用符の中の `,` では割らない。"""
    depth, quote, cur = 0, None, ""
    for ch in call_text:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
            continue
        if ch in "\"'`":
            quote = ch
            cur += ch
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            break
        cur += ch
    return cur.strip()


def calls_of(text, fn):
    """`fn( … )` の中身を、括弧の対応を数えて取り出す。正規表現だけだと
    入れ子の `)` で切れるので、対応を数える方で書く。"""
    out = []
    for m in re.finditer(r"\b" + re.escape(fn) + r"\s*\(", text):
        i, depth, start, quote = m.end(), 1, m.end(), None
        while i < len(text) and depth:
            ch = text[i]
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "\"'`":
                quote = ch
            elif ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            i += 1
        if depth == 0:
            out.append(text[start:i - 1])
    return out


LIT_NUM = re.compile(r"^-?[\d_]+(\.[\d_]+)?$")
LIT_STR = re.compile(r"^([\"'])(?:[^\\]|\\.)*?\1$")
IDENT = re.compile(r"^[A-Za-z_$][\w$]*$")
KEYWORDS = ("null", "undefined", "true", "false", "NaN", "Infinity")


def classify(arg):
    """★照合できるのは**リテラルだけ**。2026-08-05 実測で、識別子は両方向に壊れた:

      - 偽の赤: `freshness(T, …)`(`view.test.mjs` の検査
        「★古さの境目を一覧と共有する」)の `T` は JS の局所変数。
        Swift 側は別の名前を使っているので「移っていない」と出る —— 移っている。
      - 偽の緑: 同じ関数の `freshness(t0, …)` は、Swift 側がたまたま同名の局所
        `let t0` を持っていた(`FreshnessTests.swift` の
        `testSixtySecondBoundaryEndsTheJustNowClaim`)ので「在る」と出る。
        **名前が一致しただけで、入力が移った証拠は何も無い。**

    偽の緑の方が悪い。だから識別子は判定しない。
    ★同じ理由で、`for (const bad of [0, null, …])` の様に**ループ変数**で食わせている
      入力は、そもそも呼び出し口に値が無いので此処からは見えない(`view.test.mjs` の
      「★一覧の古さ — 測った時刻が分からない時は「新しい」側へ倒さない」)。
      この道具は「呼び出し口に書かれたリテラル」の分母しか持っていない。
    """
    if LIT_NUM.match(arg):
        return "num"
    if LIT_STR.match(arg):
        return "str"
    if arg in KEYWORDS:
        return "keyword"   # null/undefined/NaN は Swift に対応する綴りが無い
    if IDENT.match(arg):
        return "ident"     # 局所変数 / ループ変数 —— 呼び出し口に値が無い
    return "struct"        # {...} / [...] / 関数呼び出し


def found_in(arg, kind, swift_text):
    """★語境界で探す。素朴な部分一致だと JS の `12` が Swift の `120` に
    当たって**在る事にされる**。偽の緑はこの道具の一番痛い壊れ方。
    数値の区切り `_` は JS と Swift で書き方が揺れる(`1_000_000` / `1000000`)ので
    両方の綴りを試す。"""
    if kind == "str":
        return arg[1:-1] in swift_text
    forms = {arg}
    if kind == "num":
        forms.add(arg.replace("_", ""))
        bare = arg.replace("_", "")
        if bare.lstrip("-").isdigit() and len(bare.lstrip("-")) > 3:
            # 1000000 -> 1_000_000
            s = bare.lstrip("-")
            grouped = "{:,}".format(int(s)).replace(",", "_")
            forms.add(("-" if bare.startswith("-") else "") + grouped)
    for f in forms:
        if re.search(r"(?<![\w.$])" + re.escape(f) + r"(?![\w.$])", swift_text):
            return True
    return False


def unlisted_ports(ports):
    """★disk の側から逆に数える。JS の検査 file を名指ししている Swift の検査で、
    移植表に居ない物を返す。

    表に書いた物が実在するかは P8 が見ている。此処が見るのは**逆向き** ——
    「実在するのに表に書き忘れた」。訂正6-1 で落ちたのはこちらの向きだった。
    名前は `JS_TEST` の basename から取るので `PC_JS` の継ぎ目に追随する。
    """
    listed = {p for paths in ports.values() for p in paths}
    tests_root = ROOT / "ios" / "Tests"
    if not tests_root.is_dir():
        return []
    out = []
    for p in sorted(tests_root.rglob("*.swift")):
        try:
            if JS_TEST.name not in p.read_text():
                continue
        except OSError:
            continue
        if str(p.relative_to(ROOT)) not in listed:
            out.append(str(p.relative_to(ROOT)))
    return out


def main():
    ports = load_ports()
    if not JS_TEST.exists():
        print(f"★測れない: JS の検査 file が無い -- {JS_TEST}")
        return 2

    # import 行とコメント行は呼び出しではない
    js_body = "\n".join(
        ln for ln in JS_TEST.read_text().splitlines()
        if not ln.strip().startswith(("import", "//", "*", "/*")))

    print(f"JS の検査: {JS_TEST}")
    print(f"移植表: {len(ports)} 関数\n")

    red, unmeasured, structural_total = [], [], 0
    accepted_hit = set()

    for fn in sorted(ports):
        sw_files = ports[fn]
        calls = calls_of(js_body, fn)
        if not calls:
            print(f"■ {fn}: ★測れない -- JS 側に呼び出しが 0 件")
            unmeasured.append(f"{fn}(JS 側に呼び出し無し)")
            print()
            continue

        missing_files = [p for p in sw_files if not (ROOT / p).exists()]
        if missing_files:
            print(f"■ {fn}: ★測れない -- Swift の検査 file が無い: {missing_files}")
            unmeasured.append(f"{fn}(Swift の検査 file 不在)")
            print()
            continue

        swift_text = "".join((ROOT / p).read_text() for p in sw_files)

        args = []
        for c in calls:
            a = first_arg(c)
            if a and a not in args:
                args.append(a)

        kinds = {a: classify(a) for a in args}
        lits = [a for a in args if kinds[a] in ("num", "str")]
        opaque = [a for a in args if kinds[a] not in ("num", "str")]
        structural_total += len(opaque)

        raw_miss = [a for a in lits if not found_in(a, kinds[a], swift_text)]
        # 受理した差し替えは赤から外すが、**消さない**。理由ごと出す。
        miss = [a for a in raw_miss if (fn, a) not in ACCEPTED]
        acc = [a for a in raw_miss if (fn, a) in ACCEPTED]
        accepted_hit.update((fn, a) for a in acc)

        print(f"■ {fn}: JS 呼び出し {len(calls)} 件 / 相異なる第1引数 {len(args)} 件"
              f"(リテラル {len(lits)} / 照合できない {len(opaque)})")
        if miss:
            print(f"   ★Swift に見当たらないリテラル入力: {len(miss)} / {len(lits)}")
            for a in miss:
                print(f"       - {a}")
            red += [f"{fn}({a})" for a in miss]
        elif lits and not acc:
            print(f"   リテラルは全部 Swift 側にも在る({len(lits)}/{len(lits)})")
        elif not lits:
            print("   照合できるリテラルが 0 件 -- この関数はこの道具では測れない")
        for a in acc:
            print(f"   受理した差し替え: {fn}({a}) -- {ACCEPTED[(fn, a)]}")
        if opaque:
            by = {}
            for a in opaque:
                by[kinds[a]] = by.get(kinds[a], 0) + 1
            detail = " / ".join(f"{k} {v}" for k, v in sorted(by.items()))
            print(f"   照合できない: {len(opaque)} 件({detail})-- 人が読む")
        print()

    for p in unlisted_ports(ports):
        print(f"■ ★測れない -- JS の検査を名指ししているのに移植表に無い: {p}")
        unmeasured.append(f"{p}(移植表に行が無い)")
        print()

    # ★受理の一覧も腐る。当たらなくなった受理は**残っている事自体が偽の主張**なので赤。
    #   (`test/no-linerefs.test.mjs` の「死んだ免除を残さない」と同じ)
    #   ★集計を刷る**前に**足す事。後で足すと赤の一覧に載らず、出口だけが 1 になって
    #     「何が赤いのか出力に書いていない赤」になる(P15b が此処を見ている)。
    dead = [k for k in ACCEPTED if k not in accepted_hit]
    red += [f"死んだ受理 {fn}({a})" for fn, a in dead]

    print("=== 集計 ===")
    print(f"  赤(移っていないリテラル入力 + 死んだ受理): {len(red)}")
    for r in red:
        print(f"      - {r}")
    print(f"  照合できなかった入力: {structural_total} 件"
          f"(★緑ではない。数えているだけ。ident=局所/ループ変数、"
          f"struct=構造体、keyword=null 等)")
    print(f"  測れなかった関数: {len(unmeasured)}")
    for u in unmeasured:
        print(f"      - {u}")
    print(f"  受理した差し替え: {len(accepted_hit)} / 死んでいる受理: {len(dead)}")
    for fn, a in dead:
        print(f"      - ★{fn}({a}) はもう見当たらない入力ではない = 受理を畳む事")

    if unmeasured:
        return 2
    return 1 if red else 0


if __name__ == "__main__":
    sys.exit(main())
