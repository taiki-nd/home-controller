#!/usr/bin/env python3
"""アイコン用の Space Grotesk Bold (静的インスタンス) を作る。

app/assets/fonts/SpaceGrotesk.ttf は wght 300-700 の可変フォントで、既定インスタンスは
Light(300)。resvg は可変軸を動かさないので、そのまま渡すと細い字で描かれてしまう。
そこで wght=700 で静的化し、さらに Basic Latin だけに subset して同梱する。
生成物 (SpaceGrotesk-Bold.ttf) はコミット済み。再生成が要るときだけこれを走らせる:

    python3 tools/icon-gen/fonts/make-font.py

Space Grotesk は SIL OFL 1.1。インスタンス化・subset とも許諾されている (OFL.txt 同梱)。
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE.parent.parent.parent / "app" / "assets" / "fonts" / "SpaceGrotesk.ttf"
DST = HERE / "SpaceGrotesk-Bold.ttf"

FAMILY = "Space Grotesk"
SUBFAMILY = "Bold"


def main() -> int:
    if not SRC.exists():
        sys.exit(f"元フォントが見つからない: {SRC}")

    tmp = HERE / "_instance.ttf"
    # 1. wght=700 で静的化
    subprocess.run(
        [sys.executable, "-m", "fontTools.varLib.instancer", str(SRC), "wght=700", "-o", str(tmp)],
        check=True,
    )
    # 2. Basic Latin のみに subset (アイコンの文字だけ描ければよい)
    subprocess.run(
        [
            sys.executable, "-m", "fontTools.subset", str(tmp),
            "--unicodes=U+0020-007E",
            "--layout-features=kern,liga",
            f"--output-file={DST}",
        ],
        check=True,
    )
    tmp.unlink()

    # 3. font-family "Space Grotesk" / Bold で引けるように name テーブルを整える
    from fontTools.ttLib import TTFont

    font = TTFont(DST)
    name = font["name"]
    for nid, value in ((1, FAMILY), (2, SUBFAMILY), (4, f"{FAMILY} {SUBFAMILY}"),
                       (6, f"{FAMILY.replace(' ', '')}-{SUBFAMILY}"), (16, FAMILY), (17, SUBFAMILY)):
        name.setName(value, nid, 3, 1, 0x409)
        name.setName(value, nid, 1, 0, 0)
    font["OS/2"].usWeightClass = 700
    # BOLD を立て REGULAR は落とす (両立させると fontTools が警告を出す)
    font["OS/2"].fsSelection = (font["OS/2"].fsSelection | 1 << 5) & ~(1 << 6)
    font["head"].macStyle |= 1  # Bold
    font.save(DST)

    print(f"✓ {DST} ({DST.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
