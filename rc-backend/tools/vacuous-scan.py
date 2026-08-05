#!/usr/bin/env python3
"""否定だけで出来ている検査を数える。

「何も起きなかった」しか主張していない検査は、**前提が一度も成立しなくても緑**になる。
`assert.deepEqual(hits, [])` は、走査が本当に綺麗でも、走査が一件も回っていなくても通る。
(Codex 2026-08-04 Q3。今日 2026-08-05 に私自身が2回踏んだ形でもある —— `check-no-pii.sh` を
未 stage で走らせて「0件」を緑と読み、`no-linerefs.test.mjs` が `.md` を走査していない事を
確かめずに「機械が見ている」と書いた。)

否定しか主張しない検査が正しい場面は在る(「この入力では何も起きない」を固定したい時)。
だから挙がる事自体は罪ではない。問うべきは1つだけ:

  **「前提が壊れたら、この検査は赤くなるか?」**

この問いは **錨がどこに在るか** で決まる。2026-08-05 に 54 本を全部読んで、錨の置き場所は
3通り在ると分かった。**この道具はその3通りを機械で判定し、どれにも当たらない物だけを出す**。

  錨1 literal  = 入力が call の中に書いてある。空が**仕様そのもの**で、絶対に空回りしない。
      `assert.equal(errSlug("bad body: hello"), "")`      (reqlog.test.mjs)
      `ReadablePoll.check(["items": "nope"])`             (ReadablePollTests.swift)

  錨2 producer = 走査で作った入力だが、**作る側の helper が自分で floor を持っている**。
      `no-linerefs.test.mjs` の `scanFiles()` が輪の中で `assert.ok(n >= t.floor)` を撃つ。
      呼んだ全員が守られるので、検査の本体だけ読むこの道具には**構造的に見えない**。
      ★入力の出所が1つなら錨も1つでよい。重複を各検査へ配るより此方が良い場面が在る。
      判定は定義を**2段まで**辿る(`unverifiedCites()` の床は1段下の `scanFiles()` に在った)。

  錨3 兄弟    = 同じ file の**別の検査**が、同じ派生に肯定側の主張をしている。
      app-html.test.mjs の「view.mjs と frames.mjs だけを import する」が `IMPORTS` の鍵を
      実値で固定するので、`IMPORTS` が空になれば其方が赤くなる。
      ★但し**兄弟も否定だけなら錨にならない**(自己検査の
      `SELF_JS_SIB_NEG` が其れを固定している)。

  本物       = 走査・派生した入力に対する「無い」で、上の3つが**どこにも無い**。
      `assert.deepEqual(unlisted(SRC), [])`               (live-http-swallow.test.mjs)
      直し方 = 走ったであろう件数を先に固定する。生成側が常に非空とは限らない場合
      (`bareCatches` は素の catch が無い file では正当に 0)は、検査**自身の中に**置く。

実測(2026-08-05): 否定だけの検査 58 本、そのうち **本物 0 本**(literal 11 / producer 10 /
兄弟 37)。分類前は 58 本を人手で読めと言う出力で、偽陽性率 98% だった —— **98% の雑音を
出す報告は、無い方が良い**。「空回り検査を走らせた」という嘘の安心に化けるからである。

★錨は**遠い入力ではなく、直に食う派生**に置く(この日2回間違えた)。`HTML` を実値で固定
している兄弟が居ても、`IMPORTS` の空回りは守らない。変異も同じで、遠い入力(`SRC` を空に)
ではなく派生(`IMPORTS = new Map()`)を潰して初めて本当の答えが出た。
★短絡で錨が飛ぶ形が在る: `a().filter((p) => !b().includes(p))` —— 床を持つ `b()` は callback
の中に居るので、`a()` が空なら**一度も呼ばれない**。callback の中の錨は錨ではない。
★一番良い錨の書き方は数字を発明しない: `assert.ok(hits.some((h) => h.rel === rel))`
(session-guard.test.mjs)。自分の許可一覧に対して「現に走査に掛かった」を主張する形。

★分類器の穴を1つ塞いだ(2026-08-05)。`assert.deepEqual(x, [], "説明")` の様に**説明文を1つ
足すだけ**で挙がらなくなっていた —— この repo の主流の書き方なので素通りの範囲は広い。
塞いだ結果 36 → 50 本(**28% が見えていなかった**)。見つけたのは出力を眺めた事ではなく、
**実物を空にする変異**を当てた事: live-http-swallow の `SRC` を空にしたら 10 本中 9 本が
赤くなり、緑のまま残った1本を道具は挙げていなかった。挙げていない事の方が答えだった。
→ 対照 test/vacuous-scan-controls.sh の 7。

★「要人手 0 本」は**分類が潰れた時と字面が同じ**。だから対照 8/9 が両向き(常に錨あり /
常に錨なし)に壊して両方赤くなる事を測る。それが無い限り、0 本は測定ではなく既定値である。

出口(この repo の作法): 0 = 緑 / 1 = 挙がった / **2 = 測っていない**。
走査が floor を下回ったら 2 を返す —— 「0件見つかった」と「そもそも見ていない」を
同じ緑にしない為。旧版(scratchpad 置き)はここが無く、分母を出さずに合計だけ出していた。

使い方:
    python3 rc-backend/tools/vacuous-scan.py            # 全部
    python3 rc-backend/tools/vacuous-scan.py --tree js  # 片方だけ
    python3 rc-backend/tools/vacuous-scan.py --self-test
"""
import re
import sys
import pathlib

# ── repo の根を marker で探す。絶対パスを埋め込まない(旧版はこれで移植不能だった)──
VERBOSE = "--why" in sys.argv     # 錨ありの分類根拠まで出す


def find_repo(start: pathlib.Path):
    for d in [start, *start.parents]:
        if (d / "DESIGN.md").is_file() and (d / "rc-backend").is_dir():
            return d
    return None


# ── 木ごとの定義。floor は「これを下回ったら数え方が壊れている」線 ──────────────
#    合計で持たない: 片方の walk が丸ごと空振りしても、もう片方の件数で
#    下限を越えてしまい **0件が緑の下に隠れる**(no-linerefs.test.mjs と同じ理由)。
TREES = {
    "js": {
        "dir": "rc-backend/test",
        "glob": "**/*.test.mjs",     # ★ 再帰。旧版は `*.test.mjs` で部分木を落としていた
        "floor": 25,                 # 実測 29 本 (2026-08-05)
        # 肯定の錨を**広く**取る。旧版は equal|deepEqual|ok|match の4つしか数えず、
        # `assert.throws` / `strictEqual` / `notEqual` を見落として、それらを含む
        # 検査を「否定だけ」と誤って挙げていた(偽陽性)。
        "call": re.compile(r"\bassert\.[A-Za-z]+\s*\("),
        "test": re.compile(r"\btest\s*\(\s*(['\"`])(.*?)\1", re.S),
    },
    "swift": {
        "dir": "ios/Tests",
        "glob": "**/*Tests.swift",
        "floor": 15,                 # 実測 19 本 (2026-08-05)
        "call": re.compile(r"\bXCTAssert[A-Za-z]*\s*\(|\bXCTUnwrap\s*\("),
        "test": re.compile(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\("),
    },
}

# 「何も起きなかった」しか言っていない主張。**呼び出し1件ごとに**当てる。
NEG = re.compile(
    r"""^(?:
        assert\.ok\s*\(\s*!                  # ok(!x)
      | assert\.(?:not|doesNotThrow|doesNotReject)   # notEqual / doesNotThrow …
      | XCTAssertFalse\s*\(
      | XCTAssertNil\s*\(
      | XCTAssertNoThrow\s*\(
      | XCTAssertTrue\s*\(\s*!
    )""",
    re.X,
)
# 引数まで見ないと判らない形(空・0・undefined・null と比べているだけ)
NEG_ARGS = re.compile(
    r""",\s*(?:
        \[\s*\]            # , []
      | \{\s*\}            # , {}
      | 0                  # , 0
      | undefined
      | null
      | ""
      | ''
    )\s*\)\s*$""",
    re.X,
)
NEG_SELF = re.compile(r"\.(?:length|count)\s*,\s*0\s*\)|\.isEmpty\s*\)")


def call_text(src: str, start: int) -> str:
    """`assert.foo(` の頭から、対応する閉じ括弧までを返す。

    旧版は `\\n}});` までを正規表現で粗く切っていた為、本体の中に入れ子の
    arrow function が在ると**そこで打ち切って**主張を数え落としていた。
    括弧を数えるのが唯一の正しい切り方。
    """
    i = src.index("(", start)
    depth, j, n = 0, i, len(src)
    in_str, esc = None, False
    while j < n:
        c = src[j]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == in_str:
                in_str = None
        elif c in "\"'`":
            in_str = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return src[start:j + 1]
        j += 1
    return src[start:]


def body_of(src: str, start: int) -> str:
    """検査1本の本体を `{` … 対応する `}` で切り出す。"""
    i = src.find("{", start)
    if i < 0:
        return ""
    depth, j, n = 0, i, len(src)
    in_str, esc = None, False
    while j < n:
        c = src[j]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == in_str:
                in_str = None
        elif c in "\"'`":
            in_str = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    return src[i:]


def split_args(call: str) -> tuple:
    """`f(a, b, c)` を `("f", ["a", "b", "c"])` へ。深さ0のカンマだけで切る。

    入れ子の arrow / 配列 / object / 文字列の中のカンマでは切らない。
    """
    i = call.find("(")
    if i < 0:
        return call, []
    head, depth, buf, args = call[:i], 0, [], []
    in_str, esc = None, False
    for j in range(i, len(call)):
        c = call[j]
        if in_str:
            buf.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == in_str:
                in_str = None
            continue
        if c in "\"'`":
            in_str = c
            buf.append(c)
        elif c in "([{":
            depth += 1
            if depth > 1:
                buf.append(c)
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(buf).strip())
                break
            buf.append(c)
        elif c == "," and depth == 1:
            args.append("".join(buf).strip())
            buf = []
        else:
            buf.append(c)
    return head, [a for a in args if a != ""]


# 説明文は**繋がっている**事が多い(長いので `"…" + "…"` で折る)。1本だけの形しか
# 見ないと、折られた説明文が「説明文でない引数」に見えて剥がされず、また素通りする。
# (2026-08-05、最初の修正がまだ足りていなかった。no-linerefs の「★backtick で引いた
#  ファイル名が全部実在する」が挙がらず、隣の同型だけが挙がっていて気付いた)
_STR = r"""(?:"[^"]*"|'[^']*'|`[^`]*`)"""
MSG_ARG = re.compile(rf"^{_STR}(?:\s*\+\s*{_STR})*$")


def strip_message(call: str) -> str:
    """末尾の**説明文だけ**の引数を落とす。

    ★これが無いと、この repo の主流の書き方が丸ごと素通りする(2026-08-05 実測)。
      `assert.deepEqual(unlisted(SRC), [])`            → 否定と判る
      `assert.deepEqual(unlisted(SRC), [], "…が在る")` → **判らなかった**
    NEG_ARGS / NEG_SELF が閉じ括弧に錨を打っていた為で、説明文を1つ足すだけで
    空回りする検査が緑側へ隠れていた。説明文は主張の一部ではないので、当てる前に外す。
    (見つけ方: live-http-swallow の `SRC` を空にする変異を作ったら、道具が挙げていない
     検査が1本だけ緑のまま残った —— 挙げられていない事の方が答えだった)
    """
    head, args = split_args(call)
    if len(args) >= 2 and MSG_ARG.match(args[-1]):
        args = args[:-1]
        return f"{head}({', '.join(args)})"
    return call


def is_negative(call: str) -> bool:
    one = " ".join(call.split())
    for form in (one, strip_message(one)):
        if NEG.match(form) or NEG_ARGS.search(form) or NEG_SELF.search(form):
            return True
    return False


# ── 錨の在り処を見分ける(= 偽陽性を3類に落とす)────────────────────────────
# 2026-08-05 の実測: 挙げた 54 本のうち **本物はゼロ**、全部が下の3類だった。
# 偽陽性率 98% の報告は読まれなくなり、「空回り検査を走らせた」という嘘の安心だけが残る。
# だから道具側で3類を機械的に落とし、**錨がどこにも無い物だけ**を人手に回す。
#   1 literal  … 入力が call の中に書かれている(`parseMenu("…")`)。空になり得ない。
#   2 producer … 食っている関数の定義の中に床が在る(`assert.ok(out.size >= 15)`)。
#   3 sibling  … 同じ派生に触る**肯定の**検査が同じ file に在る(app-html:67 の形)。
# ★ 3 は「兄弟の名前」を証拠として一緒に出す。名前が出ない分類は監査できない。
JS_SYM = re.compile(
    r"^(?:export\s+)?(?:const|let|var|class|(?:async\s+)?function)\s+([A-Za-z_$][\w$]*)", re.M)
SWIFT_SYM = re.compile(
    r"^ {0,4}(?:(?:private|fileprivate|static)\s+)*(?:let|var|func)\s+([A-Za-z_$][\w$]*)", re.M)
IMPORT_NAMES = re.compile(r"\bimport\s*\{([^}]*)\}\s*from")
# ★ `A.b(...)` を1つの呼び出しとして読む。`ReadablePoll.check([…])` の頭を裸の識別子と
#   数えていた為、Swift 側の literal 入力 7 本が丸ごと「錨なし」へ落ちていた(2026-08-05)。
IDENT = re.compile(r"(?<![.\w$])([A-Za-z_$][\w$]*)(?:\s*\.\s*[A-Za-z_$][\w$]*)*\s*(\()?")
# 値を外から運んでこない語。これらが裸で居ても「外から来た入力」とは見なさない。
# Swift の型名を含める —— `[String: Any]()` の `String`/`Any` は入力ではなく型注釈。
INERT = {"true", "false", "null", "undefined", "nil", "new", "await", "typeof",
         "Set", "Map", "Object", "JSON", "Array", "String", "Number", "Boolean",
         "Error", "Date", "Math", "RegExp", "Promise", "return", "throw",
         "Any", "AnyHashable", "Int", "Double", "Float", "Bool", "Data",
         "URL", "UUID", "NSNull", "Dictionary", "Optional", "as"}


def norm(text: str) -> str:
    """`.` はメンバ参照の合図として使うので、spread の `...` を先に潰す。

    これを忘れると `[...IMPORTS.keys()]` の `IMPORTS` が「`.` の後ろ」に見えて
    記号として数えられず、**錨が在るのに無いと判定する**(逆に、その式しか無い
    検査は「識別子ゼロ = 入力は call の中」と誤って literal 側へ落ちる)。
    """
    return text.replace("...", " ")


def module_symbols(src: str, key: str) -> set:
    """file の頭で定義 / import されている名前。検査の中の局所変数は**入れない**。"""
    rx = SWIFT_SYM if key == "swift" else JS_SYM
    out = {m.group(1) for m in rx.finditer(src)}
    for m in IMPORT_NAMES.finditer(src):
        for part in m.group(1).split(","):
            n = part.split(" as ")[-1].strip()
            if n:
                out.add(n)
    return {s for s in out if len(s) >= 2}


def paren_span(text: str, open_idx: int) -> str:
    """`(` の位置から、対応する `)` の手前までを返す。"""
    depth, i = 0, open_idx
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
        i += 1
    return text[open_idx + 1:]


SWIFT_LABEL = re.compile(r"(?<![.\w$])[A-Za-z_$][\w$]*:(?!:)")


def literal_input(call: str, syms: set = frozenset(), key: str = "js") -> bool:
    """主張が、call の中に書かれた入力だけで立っているか。

    `errSlug("bad body: hello")` → True(文字列は call に在る = 黙って空にならない)
    `unlisted(SRC)`             → False(SRC は外から来る)
    """
    _, args = split_args(strip_message(" ".join(call.split())))
    text = norm(re.sub(_STR, '""', ", ".join(args)))
    if key == "swift":
        # `Backoff.ms(attempt: 0)` の `attempt:` は**引数ラベル**で、値ではない。
        # 値と数えると「外から運ばれた入力」に見え、literal な検査が錨なし側へ落ちる。
        # 空白を挟まない `名前:` だけを落とす(三項の `a ? b : c` を巻き込まない為)。
        text = SWIFT_LABEL.sub(" ", text)
    for m in IDENT.finditer(text):
        name, is_call = m.group(1), m.group(2)
        if name in INERT:
            continue
        if not is_call:
            return False                      # 裸の識別子 = 外から運ばれた値
        # ★ `IMPORTS.keys()` と `errSlug("…")` を分ける。前者は module 級の値から
        #   member を辿っているので**外から来た入力**、後者は literal に関数を当てた形。
        #   これを混ぜると、引数ゼロの member 呼び出しが「入力は call の中」に化ける。
        if "." in m.group(0).split("(")[0] and name in syms:
            return False
        inner = norm(re.sub(_STR, '""', paren_span(text, m.end() - 1)))
        for x in IDENT.finditer(inner):       # 呼び出しの引数にも外の値が居ないか
            if x.group(1) not in INERT:
                return False
    return True


def anchored_producer(sym: str, defs: dict, seen: set, depth: int = 2):
    """記号の定義に床が在るか。**2段まで辿る**。

    `unverifiedCites()` は自分では撃たず、中で呼ぶ `scanFiles()` が
    `assert.ok(n >= t.floor)` を持つ —— 1段しか見ないと、床が在るのに無いと判定する。
    """
    if depth <= 0 or sym in seen:
        return None
    seen.add(sym)
    body = defs.get(sym, "")
    if not body:
        return None
    if "assert" in body.lower() or "XCTAssert" in body:
        return sym
    for m in IDENT.finditer(norm(body)):
        if m.group(2) and m.group(1) in defs:
            found = anchored_producer(m.group(1), defs, seen, depth - 1)
            if found:
                return found
    return None


def classify(body: str, calls: list, syms: set, defs: dict, siblings: list, key: str = "js") -> tuple:
    """(類, 証拠)。類が "" = 錨がどこにも無い = 人手に回す物。"""
    if all(literal_input(c, syms, key) for c in calls):
        return "literal", "入力が call の中に在る"
    nbody = norm(body)
    used = sorted(s for s in syms if re.search(rf"(?<![.\w$]){re.escape(s)}\b", nbody))
    for s in used:
        anchor = anchored_producer(s, defs, set())
        if anchor:
            return "producer", f"{anchor}() の中に床" + ("" if anchor == s else f"({s} 経由)")
    for s in used:
        for sname, sbody in siblings:
            if re.search(rf"(?<![.\w$]){re.escape(s)}\b", norm(sbody)):
                return "sibling", f"{s} を肯定側で使う「{sname[:34]}」"
    return "", ""


def definitions(src: str, syms: set) -> dict:
    """記号 -> その定義の本体(床が中に在るかを見る為)。"""
    out = {}
    for s in syms:
        m = re.search(rf"^(?:export\s+)?(?:async\s+)?(?:function|func)\s+{re.escape(s)}\s*\(", src, re.M)
        if m:
            open_idx = src.index("(", m.start())
            close = open_idx + len(paren_span(src, open_idx)) + 2
            out[s] = body_of(src, close)
    return out


def scan_text(src: str, spec, key: str = "js") -> list:
    """1 file 分。戻り値 = [(検査名, 主張の件数, 類, 証拠)] で **全部が否定**の物だけ。"""
    tests = []
    for m in spec["test"].finditer(src):
        name = m.group(2) if m.lastindex and m.lastindex >= 2 else m.group(1)
        body = body_of(src, m.end())
        calls = [call_text(body, c.start()) for c in spec["call"].finditer(body)]
        tests.append((name, body, calls))

    syms = module_symbols(src, key)
    defs = definitions(src, syms)
    out = []
    for name, body, calls in tests:
        if not (calls and all(is_negative(c) for c in calls)):
            continue
        # 兄弟 = 自分以外で、肯定の主張を1つ以上持つ検査
        siblings = [(n, b) for n, b, cs in tests
                    if n != name and cs and not all(is_negative(c) for c in cs)]
        kind, why = classify(body, calls, syms, defs, siblings, key)
        out.append((name, len(calls), kind, why))
    return out


def run(repo: pathlib.Path, only=None):
    total_files = total_tests = 0
    flagged, unverifiable = [], []
    for key, spec in TREES.items():
        if only and key != only:
            continue
        root = repo / spec["dir"]
        files = sorted(root.glob(spec["glob"])) if root.is_dir() else []
        n_tests = 0
        for f in files:
            try:
                src = f.read_text("utf8")
            except OSError as e:
                # ★黙って continue しない。読めなかった事自体が測定の欠落。
                unverifiable.append(f"{f.relative_to(repo)}: 読めない ({e})")
                continue
            n_tests += len(list(spec["test"].finditer(src)))
            for name, n, kind, why in scan_text(src, spec, key):
                flagged.append((str(f.relative_to(repo)), name, n, kind, why))
        print(f"[{key:5s}] {spec['dir']:18s} file={len(files):3d} 検査={n_tests:4d} "
              f"(floor={spec['floor']})")
        if len(files) < spec["floor"]:
            unverifiable.append(
                f"{key}: 走査 {len(files)} 件 < floor {spec['floor']} = 数え方が壊れている")
        total_files += len(files)
        total_tests += n_tests

    print()
    naked = [x for x in flagged if not x[3]]
    for path, name, n, kind, why in naked:
        print(f"  {path}")
        print(f"    否定{n}件のみ・錨なし  {name[:66]}")

    by_kind = {k: sum(1 for x in flagged if x[3] == k) for k in ("literal", "producer", "sibling")}
    print(f"\n--- file {total_files} / 検査 {total_tests} / 否定だけの検査 {len(flagged)} 本 "
          f"(錨あり: literal {by_kind['literal']} / producer {by_kind['producer']} / "
          f"兄弟 {by_kind['sibling']} → **要人手 {len(naked)} 本**) ---")

    if VERBOSE:
        print("\n錨ありの内訳(= 分類の根拠。読めない分類は監査できない):")
        for path, name, n, kind, why in flagged:
            if kind:
                print(f"  [{kind:8s}] {name[:44]:44s} {why}")

    if unverifiable:
        print("\n**測っていない**:")
        for u in unverifiable:
            print(f"  - {u}")
        return 2
    if naked:
        print("\n各件に問う事: 「前提が壊れたら、この検査は赤くなるか?」")
        return 1
    return 0


# ── 自己検査。この道具自身が空振りしていない事の負の対照 ──────────────────────
SELF_JS_VACUOUS = '''
test("否定だけ", () => {
  assert.deepEqual(hits, []);
  assert.ok(!broken);
});
'''
SELF_JS_ANCHORED = '''
test("錨が在る", () => {
  assert.deepEqual(hits, []);
  assert.ok(n >= 25, "分母");
});
'''
SELF_JS_THROWS = '''
test("throws は肯定", () => {
  assert.ok(!bad);
  assert.throws(() => parse("x"), /bad/);
});
'''
SELF_JS_NESTED = '''
test("入れ子の arrow で打ち切らない", () => {
  const f = () => { return 1; };
  assert.deepEqual(out, []);
  assert.equal(f(), 1);
});
'''
SELF_JS_VACUOUS_MSG = '''
test("説明文を足しただけ", () => {
  assert.deepEqual(hits, [], "飲んでよい理由が書かれていない catch が在る");
});
'''
SELF_JS_ANCHORED_MSG = '''
test("説明文つきでも錨が在れば挙げない", () => {
  assert.deepEqual(hits, [], "説明");
  assert.equal(n, 3, "分母");
});
'''
SELF_JS_VACUOUS_MSG_CONCAT = '''
test("折られた説明文", () => {
  assert.deepEqual(bad, [], "実在しない名前を引いている" +
    "(2026-08-03 の実例: 存在しない名前と、その中の存在しない環境変数)");
});
'''
SELF_JS_STRING_2ND = '''
test("2引数の末尾が説明文でない文字列を、説明文と誤認しない", () => {
  assert.equal(kind, "message");
});
'''
SELF_SWIFT_VACUOUS = '''
func testNothingHappens() {
    XCTAssertNil(model.error)
    XCTAssertTrue(model.items.isEmpty)
}
'''
SELF_SWIFT_ANCHORED = '''
func testHasAnchor() {
    XCTAssertNil(model.error)
    XCTAssertEqual(model.items.count, 3)
}
'''
SELF_SWIFT_VACUOUS_MSG = '''
func testNothingHappensWithMessage() {
    XCTAssertNil(model.error, "説明")
    XCTAssertEqual(model.items.count, 0, "説明")
}
'''


SELF_JS_LITERAL = '''
test("入力は call の中", () => {
  assert.equal(errSlug("bad body: hello"), "");
});
'''
SELF_JS_PRODUCER = '''
function reasons() {
  const out = walk();
  assert.ok(out.size >= 15, "取り出しが壊れている");
  return [...out];
}
test("否定だけだが producer に床が在る", () => {
  assert.deepEqual(reasons().filter((r) => r === ""), []);
});
'''
SELF_JS_SIBLING = '''
const IMPORTS = parseImports(SCRIPT);
test("並びが期待通り(肯定)", () => {
  assert.deepEqual([...IMPORTS.keys()].sort(), ["/a.mjs", "/b.mjs"]);
});
test("否定だけだが兄弟が同じ派生を肯定側で押さえている", () => {
  for (const [p] of IMPORTS) assert.ok(!used(p));
});
'''
SELF_JS_SIB_NEG = '''
const IMPORTS = parseImports(SCRIPT);
test("否定だけ その1", () => {
  for (const [p] of IMPORTS) assert.ok(!used(p));
});
test("否定だけ その2", () => {
  assert.deepEqual([...IMPORTS.keys()].filter(Boolean), []);
});
'''


SELF_SWIFT_LITERAL = '''
final class T: XCTestCase {
    func testItemsNotAnArrayIsUnreadable() {
        XCTAssertFalse(ReadablePoll.check(["items": "nope"]))
    }
}
'''
SELF_SWIFT_SCANNED = '''
final class T: XCTestCase {
    let SOURCES = repoRoot()
    func testNoStraySession() {
        XCTAssertTrue(scan(SOURCES).isEmpty)
    }
}
'''


def self_test() -> int:
    js, sw = TREES["js"], TREES["swift"]
    cases = [
        ("否定だけの JS を挙げる",          SELF_JS_VACUOUS,   js, 1),
        ("肯定の錨が在れば挙げない",         SELF_JS_ANCHORED,  js, 0),
        ("throws を肯定として数える",        SELF_JS_THROWS,    js, 0),
        ("入れ子 arrow で打ち切らない",      SELF_JS_NESTED,    js, 0),
        ("否定だけの Swift を挙げる",        SELF_SWIFT_VACUOUS, sw, 1),
        ("件数比較が在れば挙げない(Swift)", SELF_SWIFT_ANCHORED, sw, 0),
        # ★2026-08-05 追加。説明文を1つ足すだけで素通りしていた(この repo の主流の書き方)
        ("説明文つきの否定だけを挙げる",      SELF_JS_VACUOUS_MSG, js, 1),
        ("説明文つきでも錨が在れば挙げない",  SELF_JS_ANCHORED_MSG, js, 0),
        ("折られた説明文つきの否定だけを挙げる", SELF_JS_VACUOUS_MSG_CONCAT, js, 1),
        ("説明文でない第2引数を剥がさない",   SELF_JS_STRING_2ND, js, 0),
        ("説明文つきの否定だけ(Swift)",     SELF_SWIFT_VACUOUS_MSG, sw, 1),
        # ★2026-08-05 追加。挙がった 54 本が全部偽陽性だったので、3類を機械で落とす。
        #   最後の1件が要 —— 「兄弟が居れば錨」ではない事(兄弟も否定だけなら錨にならない)を
        #   示さないと、この分類は**常に錨あり**へ潰れて、報告が空になるだけの道具になる。
        ("入力が call の中 = literal",       SELF_JS_LITERAL,   js, 1, 0),
        ("producer の中の床を錨と見る",      SELF_JS_PRODUCER,  js, 1, 0),
        ("兄弟の肯定を錨と見る",             SELF_JS_SIBLING,   js, 1, 0),
        ("兄弟も否定だけなら錨にしない",     SELF_JS_SIB_NEG,   js, 2, 2),
        # `A.b(literal)` を呼び出しと読む事 / それでも走査入力は literal にしない事。
        # 対で持つ: 前者だけだと「Swift は全部 literal」へ潰れても気付けない。
        ("member 呼び出しの literal 入力",   SELF_SWIFT_LITERAL, sw, 1, 0),
        ("走査した入力は literal にしない",  SELF_SWIFT_SCANNED, sw, 1, 1),
    ]
    bad = 0
    for case in cases:
        desc, src, spec, want = case[:4]
        want_naked = case[4] if len(case) > 4 else want
        got_all = scan_text(src, spec, "swift" if spec is sw else "js")
        got, naked = len(got_all), len([g for g in got_all if not g[2]])
        ok = got == want and naked == want_naked
        bad += 0 if ok else 1
        print(f"  {'OK  ' if ok else 'FAIL'} {desc}"
              f"(挙がった={got}/{want} 錨なし={naked}/{want_naked})")
    print(f"\nSELF-TEST: pass={len(cases) - bad} fail={bad}")
    return 1 if bad else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    only = None
    if "--tree" in sys.argv:
        only = sys.argv[sys.argv.index("--tree") + 1]
        if only not in TREES:
            print(f"木の名前が違う: {only}(有効 = {', '.join(TREES)})", file=sys.stderr)
            return 2
    repo = find_repo(pathlib.Path(__file__).resolve().parent)
    if repo is None:
        print("repo の根が見つからない(DESIGN.md + rc-backend/ を目印にしている)= 測っていない",
              file=sys.stderr)
        return 2
    return run(repo, only)


if __name__ == "__main__":
    sys.exit(main())
