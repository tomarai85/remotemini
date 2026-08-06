#!/usr/bin/env python3
# no-control: 出力の PNG を commit 済み。作り直すのは図案を変える時だけで、対照を置くより目視が安い
"""ホーム画面用のアイコンを作る。依存ゼロ(zlib と struct だけ)。

なぜ生成するか: リポジトリの規律が「ビルド無し・依存ゼロ」なので、画像編集ツールや
npm パッケージを持ち込まない。結果の PNG だけを置き、この生成器も残して作り直せる様にする。

図案: 端末のプロンプト( `>` と `_` )。文字を使わないのはフォント差で崩れない為。
3倍で描いて縮める = 縁を滑らかにする(アンチエイリアス)。
"""
import struct
import sys
import zlib

S = 180          # 出来上がりの一辺(apple-touch-icon の推奨)
SS = 3           # 3倍で描いて縮める
BG = (0x11, 0x16, 0x1c)
FG = (0xE7, 0xEC, 0xF2)
ACCENT = (0x6A, 0xA8, 0xFF)


def dist_to_segment(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    L2 = vx * vx + vy * vy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / L2))
    cx, cy = ax + t * vx, ay + t * vy
    return ((px - cx) ** 2 + (py - cy) ** 2) ** 0.5


def render():
    n = S * SS
    # 太さ・座標は出来上がり基準で書き、描くときだけ SS 倍する
    half = 9.0 * SS
    chevron = [((58, 52), (98, 90)), ((98, 90), (58, 128))]
    bar = ((104, 122), (140, 122))

    rows = []
    for y in range(n):
        row = bytearray()
        for x in range(n):
            px, py = x + 0.5, y + 0.5
            d_ch = min(dist_to_segment(px, py, a[0] * SS, a[1] * SS, b[0] * SS, b[1] * SS)
                       for a, b in chevron)
            d_bar = dist_to_segment(px, py, bar[0][0] * SS, bar[0][1] * SS,
                                    bar[1][0] * SS, bar[1][1] * SS)
            if d_ch <= half:
                row += bytes(FG)
            elif d_bar <= half * 0.78:
                row += bytes(ACCENT)
            else:
                row += bytes(BG)
        rows.append(bytes(row))
    return downsample(rows, n)


def downsample(rows, n):
    out = []
    for y in range(S):
        row = bytearray()
        for x in range(S):
            r = g = b = 0
            for dy in range(SS):
                src = rows[y * SS + dy]
                for dx in range(SS):
                    i = ((x * SS + dx) * 3)
                    r += src[i]
                    g += src[i + 1]
                    b += src[i + 2]
            k = SS * SS
            row += bytes((r // k, g // k, b // k))
        out.append(bytes(row))
    return out


def write_png(path, rows):
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon.png"
    size = write_png(out, render())
    print(f"{out}: {S}x{S}, {size} bytes")
