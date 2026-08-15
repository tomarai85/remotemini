#!/usr/bin/env python3
"""焼き上がった app の中の種(既定の接続先)を読み戻して照合する。

★何故 shell の中の here-doc ではなく file なのか(2026-08-15)。
`ios/tools/build.sh` は同じ読み戻しを**実機の道でだけ**持っていた。simulator へ
入れる道を足すにあたって同じ python を書き写すと、照合の実装が2本になる。
食い違った時に出るのは嘘の合格で、其れは種が無い app を「種が在る」と言う ——
今回 Tom が実際に踏んだ形(電話に入っていた束に `RCBaseURL` が無かった)を
機械が見逃す道そのもの。だから写さずに1本にして、両方の道から呼ぶ。

使い方:
    printf '%s' "$KEY" | seed-verify.py present <plist> <url>
    seed-verify.py absent <plist>

★値は絶対に印字しない。plistlib の例外本文は書こうとした値を含み得るので、
例外は握り潰して定型文だけを出す(`build.sh` の刻む側と同じ約束)。
"""

import plistlib
import sys

URL_KEY = "RCBaseURL"
KEY_KEY = "RCAPIKey"


def load(path):
    try:
        with open(path, "rb") as f:
            return plistlib.load(f)
    except Exception:
        sys.stderr.write("焼き上がった app の Info.plist が読めない\n")
        raise SystemExit(1)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: seed-verify.py present <plist> <url> | absent <plist>\n")
        return 2

    verb, path = argv[1], argv[2]
    doc = load(path)

    if verb == "absent":
        # 種無しで焼いたなら、焼き上がった物に残っていない事まで見る。build/ は
        # 消さずに再利用するので、前回の焼きの鍵を抱えたまま出荷する道が在る。
        if doc.get(URL_KEY) or doc.get(KEY_KEY):
            sys.stderr.write("種無しで焼いたのに app に種が残っている\n")
            return 1
        return 0

    if verb != "present":
        sys.stderr.write("verb は present か absent\n")
        return 2

    if len(argv) < 4:
        sys.stderr.write("present には url が要る\n")
        return 2

    url = argv[3]
    key = sys.stdin.read().strip()
    if not key:
        sys.stderr.write("鍵が空\n")
        return 1
    if doc.get(URL_KEY) != url:
        sys.stderr.write("焼き上がった app の URL が刻んだ物と違う\n")
        return 1
    if doc.get(KEY_KEY) != key:
        sys.stderr.write("焼き上がった app の鍵が刻んだ物と違う\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
