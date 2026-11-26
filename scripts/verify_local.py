# -*- coding: utf-8 -*-
"""NoticeBoard 專屬的檢查：scripts/verify_mod.py 第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。
2026-11-26 verify_mod.py 換成家族模板時，從舊副本原樣搬來（門檻與掃描範圍不變）：

  5. 重建範例覆寫警告       — CH/EN 選單必須明示會覆寫 categories.txt；這是動手前唯一警告
 13. Lua 單元測試          — scripts/test_mdparser.lua（MDParser 純模組）與
                           scripts/test_nbpanel.lua（載入原版 ISRichTextPanel + NBPanel
                           實跑預檢）。需要 PATH 有 lua；test_nbpanel 另需本機有 PZ
                           安裝，缺任一者列為 SKIP 而非 PASS
 15. 提示音音檔           — 42/media/sound/MinidoracatNBNotify.wav 與語音提示音
                           MinidoracatNBVoice{CH,EN,JP}{,Stacy,Yui}.wav（面板語音：語系×聲音）過
                           scripts/prep_notify_sound.py 的 verify_notify_sound：未壓縮
                           16-bit PCM／聲道 1-2／取樣率白名單／長度 ≤5s／峰值在
                           0.05-0.60 之間。**刻意只驗規格不比對內容**——音效是服主可以
                           替換的（docs/ADMIN_GUIDE.md「換掉提示音」）。playUISound 對
                           找不到的音效名是靜默無聲，Lua 測試也只斷言傳入的名字、從不讀
                           .wav，所以這是唯一會擋住「音檔不見／格式壞掉／長到變背景音樂／
                           大聲到炸耳」的閘門（自帶音效不受玩家音量選項影響，峰值上限
                           是硬需求）。原創備援音效由 scripts/gen_notify_sound.py 生成
 16. 封面資產             — Workshop preview 與遊戲 poster 必須是相同、可完整解碼的
                           512×512 RGB PNG；preview ≤1,024,000 bytes（缺 Pillow 列 SKIP）
 17. Steam 介面預覽       — docs/screenshots/steam/ 的 JPG（作品頁預覽圖兼 Steam 指南的圖）必須正好是固定清單、
                          可完整解碼的 RGB JPEG，且每張 ≤280,000 bytes（家族 release.md 的上限）；尺寸不限（缺 Pillow 列 SKIP）
hook 的 uv run 環境沒有 Pillow：本檔載不到 Pillow 時會改用 `uv run --with pillow` 重跑自己，uv 建不起環境（離線又沒快取）
時 16、17 才是 SKIP。
"""
import json
import os
import shutil
import subprocess
import sys

# 載不到 Pillow 就用 uv 帶 Pillow 重跑本檔（2026-11-26），不然 hook 裡 16、17 每次 SKIP。
# 先試建環境：離線又沒快取時建不起來，就照舊往下跑、那兩項列 SKIP，不擋 commit。
try:
    import PIL  # noqa: F401
except ImportError:
    _uv = ["uv", "run", "--quiet", "--no-project", "--with", "pillow", "python"]
    if shutil.which("uv") and not os.environ.get("VERIFY_LOCAL_PILLOW") and \
            subprocess.run(_uv + ["-c", "import PIL"], capture_output=True).returncode == 0:
        sys.exit(subprocess.run(_uv + [os.path.abspath(__file__)],
                                env={**os.environ, "VERIFY_LOCAL_PILLOW": "1"}).returncode)

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []

# 豁免清單與 verify_mod.py 共用：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
IGNORE_PATTERNS = []
_ign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_ignore.txt")
if os.path.isfile(_ign):
    with open(_ign, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if _line and not _line.startswith("#"):
                IGNORE_PATTERNS.append(_line)


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def fail(label, details=None):
    if not details:  # 說失敗卻沒附細節（例：子程序結束碼非零但沒輸出）也是失敗；空清單走下面會記成 PASS
        failed.append(label)
        print(f"  FAIL  {label}")
        return
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        if waived:
            ok(f"{label}（{len(waived)} 筆豁免）")
        else:
            ok(label)
        return
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in kept:
        print(f"        {d}")


def skip(label, why):
    skipped.append(label)
    print(f"  SKIP  {label} — {why}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

# ---- 5. 重建範例選單明示覆寫 categories.txt ----
# 缺檔與 JSON 壞掉由 verify_mod.py 的「翻譯鍵集一致」「翻譯 JSON 可解析」報，這裡只看讀得到的 IG_UI.json。
for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    example_warning = []
    for l in langs:
        n = "IG_UI.json"
        p = os.path.join(troot, l, n)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            continue
        for warning_key in (
            "IGUI_MinidoracatNB_ExamplesLangCH",
            "IGUI_MinidoracatNB_ExamplesLangEN",
        ):
            warning = data.get(warning_key)
            if not isinstance(warning, str) or "categories.txt" not in warning:
                example_warning.append(
                    f"{l}/{n} 的 {warning_key} 未明示覆寫 categories.txt")
    fail("重建範例選單明示覆寫 categories.txt", example_warning) if example_warning \
        else ok("重建範例選單明示覆寫 categories.txt")

# ---- 13. Lua 單元測試 ----
# 這些測試是 MDParser／NBPanel 唯一的行為防線（luac -p 只驗語法），沒有進閘門就等於
# 下一個人不會跑到。test_nbpanel 依賴本機 PZ 安裝、找不到時自己以退出碼 0 跳過，
# 所以這裡認輸出開頭的 SKIP 字樣，把「沒跑」列成 SKIP 而不是 PASS。
lua_bin = shutil.which("lua")
LUA_TESTS = [t for t in ("scripts/test_mdparser.lua", "scripts/test_nbpanel.lua")
             if os.path.isfile(os.path.join(REPO, t))]
if not lua_bin:
    skip("Lua 單元測試", "PATH 沒有 lua")
elif not LUA_TESTS:
    skip("Lua 單元測試", "找不到 scripts/test_*.lua")
else:
    for t in LUA_TESTS:
        r = subprocess.run([lua_bin, t], capture_output=True, cwd=REPO)
        out = (r.stdout + r.stderr).decode("utf-8", "replace").strip()
        lines = out.splitlines() or [f"rc={r.returncode}"]
        if r.returncode != 0:
            fail(f"Lua 單元測試（{t}）", lines[-3:])
        else:
            # 任一行以 SKIP 開頭都列 SKIP：整檔跳過（首行）或段落級跳過（如
            # test_mdparser 的 NBSkin 段缺框架 repo）都代表該防線沒完整跑到，
            # 不得記 PASS
            _skip_line = next((l for l in lines if l.startswith("SKIP")), None)
            if _skip_line:
                skip(f"Lua 單元測試（{t}）", _skip_line)
            else:
                ok(f"Lua 單元測試（{t}：{lines[-1]}）")

# ---- 15. 提示音音檔 ----
# playUISound 對「找不到音效名」是靜默無聲、不拋錯
# （SoundManager.java:193-227 找不到 GameSound 就 return 0），Lua 測試也只 stub
# getSoundManager 斷言傳入的名字，從不讀 .wav。所以音檔不見／壞掉不會讓任何測試變紅。
# 驗的是**資產規格**而不是「等於某一份特定 PCM」：音效是服主可以替換的
# （見 docs/ADMIN_GUIDE.md「換掉提示音」），閘門要擋的是引擎讀不了的格式、
# 長到變背景音樂、以及大聲到炸耳——自帶音效不受玩家音量控制，峰值上限是硬需求。
try:
    from prep_notify_sound import (DEFAULT_OUT as _SND_REL, VOICE_OUTS as _VOICE_RELS,
                                   verify_notify_sound as _verify_sound)
except ImportError as _e:
    skip("提示音音檔", f"無法載入 prep_notify_sound（{_e}）")
else:
    # 語音提示音（MinidoracatNBVoice<語系><聲音>，經典無後綴）同一組規格：面板的語音選單直接
    # playUISound 這些名字，換聲音是使用者的權利，所以一樣只驗規格不比對內容。
    _snd_problems = []
    for _rel in (_SND_REL,) + _VOICE_RELS:
        _snd_problems += [f"{os.path.basename(_rel)}: {p}"
                          for p in _verify_sound(os.path.join(REPO, _rel))]
    fail("提示音音檔（prep_notify_sound.verify_notify_sound）", _snd_problems) if _snd_problems \
        else ok(f"提示音音檔（提示音＋語音 {len(_VOICE_RELS)} 檔過規格檢查）")

# ---- 16. Workshop preview / 遊戲 poster ----
# PZ 42.20.4 SteamWorkshopItem.validatePreviewImage:487-500：preview 必須是可讀 PNG、
# 正方形 256/512，且 ≤1,024,000 bytes。這裡固定家族輸出為 512 RGB，要求 poster
# 與 preview 位元組一致；一次性來源依使用者要求不留在 repo。
try:
    from PIL import Image as _CoverImage
except ImportError as _cover_import_error:
    skip("封面資產（preview/poster）", f"無法載入 Pillow（{_cover_import_error}）")
else:
    _cover_root = os.path.join(REPO, "MOD", "MinidoracatNoticeBoardFor42")
    _cover_paths = {
        "preview.png": (
            os.path.join(_cover_root, "preview.png"), (512, 512)),
        "poster.png": (
            os.path.join(
                _cover_root, "Contents", "mods", "MinidoracatNoticeBoardFor42",
                "42", "poster.png"),
            (512, 512)),
    }
    _cover_generator = os.path.join(REPO, "scripts", "poster", "finish_poster.py")
    _cover_problems = []
    _cover_assets = {}
    for _label, (_path, _expected_size) in _cover_paths.items():
        if not os.path.isfile(_path):
            _cover_problems.append(f"{_label}: 缺檔")
            continue
        try:
            with _CoverImage.open(_path) as _probe:
                _format = _probe.format
                _mode = _probe.mode
                _size = _probe.size
                _probe.verify()          # chunk／CRC／IEND 結構
            with _CoverImage.open(_path) as _decoded:
                _decoded.load()          # 強制解壓完整 IDAT
            with open(_path, "rb") as _fh:
                _data = _fh.read()
        except (OSError, SyntaxError, ValueError) as _error:
            _cover_problems.append(f"{_label}: PNG 解碼失敗（{_error}）")
            continue
        _cover_assets[_label] = {
            "data": _data, "format": _format, "mode": _mode, "size": _size,
        }
        if _format != "PNG" or _mode != "RGB":
            _cover_problems.append(
                f"{_label}: format/mode={_format}/{_mode}，預期 PNG/RGB")
        if _size != _expected_size:
            _cover_problems.append(
                f"{_label}: 尺寸 {_size[0]}x{_size[1]}，"
                f"預期 {_expected_size[0]}x{_expected_size[1]}")

    _preview_asset = _cover_assets.get("preview.png")
    _poster_asset = _cover_assets.get("poster.png")
    if _preview_asset and len(_preview_asset["data"]) > 1_024_000:
        _cover_problems.append(
            f"preview.png: {len(_preview_asset['data']):,} bytes，超過 1,024,000")
    if not _preview_asset or not _poster_asset \
            or _preview_asset["data"] != _poster_asset["data"]:
        _cover_problems.append("preview.png 與 poster.png 位元組不一致")

    if not os.path.isfile(_cover_generator):
        _cover_problems.append("finish_poster.py: 缺少外部來源轉換工具")

    fail("封面資產（preview/poster）", _cover_problems) if _cover_problems \
        else ok(f"封面資產（512×512 RGB PNG，{len(_preview_asset['data']):,} bytes）")

# ---- 17. Steam 詳情頁介面預覽 ----
# 這個目錄是作品頁預覽圖（家族 workshop_previews.js 的 sync 照目錄同步：多的追加、少的從作品頁移除），
# 也是 Steam 指南的圖（家族 steam_guide.js 依裸檔名找）。檔名集合釘在這裡，誤刪一張時下一次同步才不會把作品頁那張也刪掉；
# 增刪圖要一起改這份清單，同一張圖重拍沿用原檔名就不用改。尺寸不釘：重拍照家族 guide-shots 情境，大小跟著 E2E 視窗走。
_steam_shot_names = {
    os.path.join("zh", "01-markdown-headings.jpg"),
    os.path.join("zh", "02-markdown-inline-and-images.jpg"),
    os.path.join("zh", "03-richtext-and-emoji-limitations.jpg"),
    os.path.join("zh", "04-sandbox-options-zh.jpg"),
    os.path.join("en", "01-panel-document-tree.jpg"),
    os.path.join("en", "02-language-menu.jpg"),
    os.path.join("en", "03-server-language-folders.jpg"),
    os.path.join("en", "04-sandbox-options.jpg"),
    os.path.join("en", "05-markdown-headings-en.jpg"),
    os.path.join("en", "06-markdown-inline-and-images-en.jpg"),
    os.path.join("en", "07-richtext-and-emoji-limitations-en.jpg"),
}
_steam_shot_root = os.path.join(REPO, "docs", "screenshots", "steam")
_steam_shot_problems = []
if "_CoverImage" not in globals():
    skip("Steam 介面預覽圖", "無法載入 Pillow")
else:
    _actual_steam_shots = {
        os.path.relpath(os.path.join(directory, name), _steam_shot_root)
        for directory, _, names in os.walk(_steam_shot_root)   # 缺目錄→空集合
        for name in names
        if name.lower().endswith((".jpg", ".jpeg"))
    }
    if _actual_steam_shots != _steam_shot_names:
        _steam_shot_problems.append(
            "JPG 集合不一致："
            f"缺少={sorted(_steam_shot_names - _actual_steam_shots)}，"
            f"多出={sorted(_actual_steam_shots - _steam_shot_names)}")
    for _name in sorted(_steam_shot_names & _actual_steam_shots):
        _path = os.path.join(_steam_shot_root, _name)
        try:
            with _CoverImage.open(_path) as _probe:
                _format = _probe.format
                _mode = _probe.mode
                _probe.verify()
            with _CoverImage.open(_path) as _decoded:
                _decoded.load()
        except (OSError, SyntaxError, ValueError) as _error:
            _steam_shot_problems.append(f"{_name}: JPEG 解碼失敗（{_error}）")
            continue
        if _format != "JPEG" or _mode != "RGB":
            _steam_shot_problems.append(f"{_name}: {_format}/{_mode}，預期 JPEG/RGB")
        if os.path.getsize(_path) > 280_000:
            _steam_shot_problems.append(
                f"{_name}: {os.path.getsize(_path):,} bytes，超過 280,000（家族 release.md 的上限）")
    fail("Steam 介面預覽圖", _steam_shot_problems) if _steam_shot_problems \
        else ok(f"Steam 介面預覽圖（{len(_steam_shot_names)} 張 RGB JPG，皆 ≤280KB）")

sys.exit(1 if failed else 0)
