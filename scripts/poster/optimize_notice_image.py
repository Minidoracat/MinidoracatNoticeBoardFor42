# -*- coding: utf-8 -*-
"""把公告用圖壓到 MaxImageKB 以內，同時保住文字清晰度。

用法：python scripts/poster/optimize_notice_image.py <來源> <輸出> [上限KB]

策略依序嘗試，取「檔案 < 上限」且色數最多的一版：
RGB 直接壓 → 調色板 256/128/64 色（無 dither，圖文海報用 dither 反而讓文字邊緣糊）。
圖文海報的色塊少、文字銳利，量化幾乎不影響可讀性；縮小尺寸才會傷文字，故不縮圖。
"""
import io
import os
import sys

from PIL import Image


def png_bytes(img, **kw):
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True, compress_level=9, **kw)
    return buf.getvalue()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    limit_kb = float(sys.argv[3]) if len(sys.argv) > 3 else 512.0

    im = Image.open(src)
    orig_kb = os.path.getsize(src) / 1024
    print(f"原圖 {im.size} {im.mode} {orig_kb:.1f} KB  上限 {limit_kb:.0f} KB")

    if im.mode == "RGBA":
        import numpy as np

        opaque = bool((np.asarray(im)[..., 3] == 255).all())
        print(f"  alpha 全不透明: {opaque}（{'可安全轉 RGB' if opaque else '保留 alpha'}）")
    rgb = im.convert("RGB")

    # 原檔本身也是候選：來源若已是調色板 PNG，轉 RGB 反而更大（踩過：154KB → 270KB）
    with open(src, "rb") as f:
        cands = [("原檔不變", f.read())]
    cands.append(("RGB", png_bytes(rgb)))
    for colors in (256, 128, 64):
        q = rgb.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        cands.append((f"{colors} 色調色板", png_bytes(q)))

    orig_bytes = len(cands[0][1])
    for name, data in cands:
        kb = len(data) / 1024
        flags = []
        flags.append("OK" if kb < limit_kb else "超上限")
        if len(data) > orig_bytes:
            flags.append("比原檔大")
        print(f"  {name:16} {kb:7.1f} KB  {' / '.join(flags)}")

    # 通過上限且不比原檔大者中，取畫質最高的（cands 已依畫質降序，原檔排最前）
    ok = [(n, d) for n, d in cands if len(d) / 1024 < limit_kb and len(d) <= orig_bytes]
    if not ok:
        print("FAIL: 無可用候選（全部超上限）——需縮圖或提高 MaxImageKB")
        return 2
    name, data = ok[0]
    with open(dst, "wb") as f:
        f.write(data)
    print(f"\n採用 {name} → {dst}  {len(data)/1024:.1f} KB（原圖的 {len(data)/orig_bytes*100:.0f}%）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
