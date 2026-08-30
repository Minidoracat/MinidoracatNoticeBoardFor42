# -*- coding: utf-8 -*-
"""把外部 1920x1080 完成稿轉成 PZ 需要的 512x512 preview / poster。

只做等比縮放與純黑 letterbox：完整原圖縮成 512x288、水平置中，
上下各補 112px 黑邊。不裁切、不拉伸、不重畫、不修改來源內容。

用法：python scripts/poster/finish_poster.py <source.png>
來源是一次性輸入，不留在 repo；出貨只保留生成後的 preview.png / poster.png。
"""
import io
from pathlib import Path
import sys

from PIL import Image, ImageOps

SP = Path(__file__).resolve().parent
REPO = SP.parent.parent
MOD = REPO / "MOD" / "MinidoracatNoticeBoardFor42"

SIZE = 512
SOURCE_SIZE = (1920, 1080)
FOREGROUND_SIZE = (512, 288)
MAX_BYTES = 1_024_000

TARGETS = [
    SP / "posters" / "preview.png",
    SP / "posters" / "poster.png",
    MOD / "preview.png",
    MOD / "Contents" / "mods" / "MinidoracatNoticeBoardFor42" / "42" / "poster.png",
]


def build(source_path):
    with Image.open(source_path) as source:
        art = source.convert("RGB")
    if art.size != SOURCE_SIZE:
        raise ValueError(f"source size {art.size}, expected {SOURCE_SIZE}")

    foreground = ImageOps.contain(art, (SIZE, SIZE), Image.LANCZOS)
    if foreground.size != FOREGROUND_SIZE:
        raise ValueError(f"foreground size {foreground.size}, expected {FOREGROUND_SIZE}")

    canvas = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    canvas.paste(foreground, ((SIZE - foreground.width) // 2, (SIZE - foreground.height) // 2))
    return canvas


def encode(image):
    buffer = io.BytesIO()
    image.save(buffer, "PNG", optimize=True)
    return buffer.getvalue()


def validate(data):
    with Image.open(io.BytesIO(data)) as image:
        if image.format != "PNG" or image.mode != "RGB" or image.size != (SIZE, SIZE):
            raise ValueError(f"output {image.format}/{image.mode}/{image.size}")
        image.verify()
    if len(data) > MAX_BYTES:
        raise ValueError(f"output size {len(data)} > {MAX_BYTES}")


def main(argv):
    if len(argv) != 2:
        raise SystemExit("用法：python scripts/poster/finish_poster.py <source.png>")
    source_path = Path(argv[1]).resolve()
    data = encode(build(source_path))
    validate(data)
    for target in TARGETS:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if target.read_bytes() != data:
            raise IOError(f"write verification failed: {target}")
        print("寫出:", target.relative_to(REPO).as_posix())
    print(f"512x512 RGB PNG  {len(data):,} / {MAX_BYTES:,} bytes  四個輸出位元組一致")


if __name__ == "__main__":
    main(sys.argv)
