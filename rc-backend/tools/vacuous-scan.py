#!/usr/bin/env python3
"""否定だけで出来ている検査を数える。

「何も起きなかった」しか主張していない検査は、**前提が一度も成立しなくても緑**になる。
`assert.deepEqual(hits, [])` は、走査が本当に綺麗でも、走査が一件も回っていなくても通る。
(Codex 2026-08-04 Q3。今日 2026-08-05 に私自身が2回踏んだ形でもある —— `check-no-pii.sh` を
未 stage で走らせて「0件」を緑と読み、`no-linerefs.test.mjs` が `.md` を走査していない事を
確かめずに「機械が見ている」と書いた。)

**これは報告専用の道具**(report-only)。ここで挙がる検査が全部悪いわけではない —— 否定しか
主張しない検査が正しい場面は在る(「この入力では何も起きない」を固定したい時)。
挙がった検査に対して人が問うべきは1つ:

  **「前提が壊れたら、この検査は赤くなるか?」**

赤くならないなら、肯定の錨(件数・具体値・分母)を足す。それが `no-linerefs.test.mjs` の
`assert.ok(n >= t.floor)` であり、この道具自身が下に持っている floor でもある。

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


def is_negative(call: str) -> bool:
    one = " ".join(call.split())
    return bool(NEG.match(one) or NEG_ARGS.search(one) or NEG_SELF.search(one))


def scan_text(src: str, spec) -> list:
    """1 file 分。戻り値 = [(検査名, 主張の件数)] で **全部が否定**の物だけ。"""
    out = []
    for m in spec["test"].finditer(src):
        name = m.group(2) if m.lastindex and m.lastindex >= 2 else m.group(1)
        body = body_of(src, m.end())
        calls = [call_text(body, c.start()) for c in spec["call"].finditer(body)]
        if calls and all(is_negative(c) for c in calls):
            out.append((name, len(calls)))
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
            for name, n in scan_text(src, spec):
                flagged.append((str(f.relative_to(repo)), name, n))
        print(f"[{key:5s}] {spec['dir']:18s} file={len(files):3d} 検査={n_tests:4d} "
              f"(floor={spec['floor']})")
        if len(files) < spec["floor"]:
            unverifiable.append(
                f"{key}: 走査 {len(files)} 件 < floor {spec['floor']} = 数え方が壊れている")
        total_files += len(files)
        total_tests += n_tests

    print()
    for path, name, n in flagged:
        print(f"  {path}")
        print(f"    否定{n}件のみ  {name[:70]}")
    print(f"\n--- file {total_files} / 検査 {total_tests} / 否定だけの検査 {len(flagged)} 本 ---")

    if unverifiable:
        print("\n**測っていない**:")
        for u in unverifiable:
            print(f"  - {u}")
        return 2
    if flagged:
        print("\n報告専用。各件に問う事: 「前提が壊れたら、この検査は赤くなるか?」")
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


def self_test() -> int:
    js, sw = TREES["js"], TREES["swift"]
    cases = [
        ("否定だけの JS を挙げる",          SELF_JS_VACUOUS,   js, 1),
        ("肯定の錨が在れば挙げない",         SELF_JS_ANCHORED,  js, 0),
        ("throws を肯定として数える",        SELF_JS_THROWS,    js, 0),
        ("入れ子 arrow で打ち切らない",      SELF_JS_NESTED,    js, 0),
        ("否定だけの Swift を挙げる",        SELF_SWIFT_VACUOUS, sw, 1),
        ("件数比較が在れば挙げない(Swift)", SELF_SWIFT_ANCHORED, sw, 0),
    ]
    bad = 0
    for desc, src, spec, want in cases:
        got = len(scan_text(src, spec))
        ok = got == want
        bad += 0 if ok else 1
        print(f"  {'OK  ' if ok else 'FAIL'} {desc}(挙がった={got} 期待={want})")
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
