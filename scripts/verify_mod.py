# -*- coding: utf-8 -*-
"""發版前驗證閘門：一次跑完全部靜態檢查，任一失敗以非零碼結束。

用法（repo 根目錄或任意位置）：
    python scripts/verify_mod.py

零設定：自動偵測 MOD/<folder>/Contents/mods/<folder>/42/。
涵蓋的檢查與其對應的實際事故（皆有反編譯出處，詳見 AGENTS.md 踩坑錄）：

  1. luac -p 語法        — 需要 PATH 有 luac；沒有則列為 SKIP 而非 PASS
  2. BOM / CRLF          — 有 BOM 或 CRLF 的翻譯檔會被引擎「靜默忽略」
  3. 翻譯鍵集一致          — 缺鍵的語系會顯示原始 key
  4. 裸 % 檢查           — 42.20.1 起 formatted() 遇裸 % 崩潰；只允許 %1-%9 與 %%
  5. 重建範例覆寫警告       — CH/EN 選單必須明示會覆寫 categories.txt；這是動手前唯一警告
  6. Kahlua 禁用全域       — next/assert/xpcall 不存在（BaseLib 未註冊），呼叫→
                           「Object tried to call nil」。luac 與標準 Lua 測試都攔不住
                           （語法合法、標準 Lua 有這些函式），只能靜態掃描
  7. table.sort 禁用      — Kahlua 的 sort 是遞迴 quicksort（coroutine 堆疊上限 3000），
                           已排序輸入退化 O(n) 深度、數百筆即溢位；一律用迭代 merge sort
  8. MOD/ 樹雜物          — .omc/.claude/.gitnexus；Workshop 整包上傳不看 .gitignore
  9. 佔位符殘留            — {{TOKEN}} 漏替換
 10. Steam 描述位元組      — 各語言 ≤8000 UTF-8 bytes（中日文 3 bytes/字，容易低估）
 11. 沙盒選項翻譯配對       — 每個 option 要有 Sandbox_<translation> 標題＋ _tooltip＋分頁名
 12. CHANGELOG 洩漏掃描     — bullet 會被整段貼到公開的 Workshop 更新說明；掃基礎設施
                           樣式（/home/ 路徑、IP、SteamID64、ssh、主機名）當最後防線。
                           攻擊配方與玩家識別資訊機器認不出來，靠撰寫規則（AGENTS.md）
 13. Lua 單元測試          — scripts/test_mdparser.lua（MDParser 純模組）與
                           scripts/test_nbpanel.lua（載入原版 ISRichTextPanel + NBPanel
                           實跑預檢）。需要 PATH 有 lua；test_nbpanel 另需本機有 PZ
                           安裝，缺任一者列為 SKIP 而非 PASS
 14. （已移除）UI 皮膚貼圖 — 貼圖與生成器已上移家族框架 MinidoracatUIFor42
                           （42/media/ui/MinidoracatUI/，該 repo verify_mod.py 第 12 項驗），
                           本 repo 不再攜帶 PNG；NBSkin 是框架 thin adapter，缺框架退直角
 15. 提示音音檔           — 42/media/sound/MinidoracatNBNotify.wav 與語音提示音
                           MinidoracatNBVoice{CH,EN,JP}.wav（面板語音語系選項）過
                           scripts/prep_notify_sound.py 的 verify_notify_sound：未壓縮
                           16-bit PCM／聲道 1-2／取樣率白名單／長度 ≤5s／峰值在
                           0.05-0.60 之間。**刻意只驗規格不比對內容**——音效是服主可以
                           替換的（docs/ADMIN_GUIDE.md「換掉提示音」）。playUISound 對
                           找不到的音效名是靜默無聲，Lua 測試也只斷言傳入的名字、從不讀
                           .wav，所以這是唯一會擋住「音檔不見／格式壞掉／長到變背景音樂／
                           大聲到炸耳」的閘門（自帶音效不受玩家音量選項影響，峰值上限
                           是硬需求）。原創備援音效由 scripts/gen_notify_sound.py 生成
 16. 封面資產             — Workshop preview 與遊戲 poster 必須是相同、可完整解碼的
                           512×512 RGB PNG；preview ≤1,024,000 bytes
 17. Steam 介面預覽       — 固定清單的 JPG 必須可完整解碼、維持 1920×1032 RGB，
                          且每張 ≤280,000 bytes（Steamworks AddItemPreviewFile 實測上限 274KB～314KB 之間）

新增檢查時：同步把對應的坑記進 AGENTS.md 踩坑錄，並依「踩坑進化協議」回流到
pz-mod-template（見 AGENTS.md）。
"""
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []

# 豁免清單（選用）：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
# 命中樣式的 finding 會列出但不計 FAIL——用於「已逐一查證屬合理例外」的殘留
# （例：翻譯包鏡像了來源 MOD 原文的裸 %）。每個樣式旁必須有註解說明查證依據。
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
    details = details or []
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


def iter_files(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git",)]
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

LUA_FILES = [f for m in MEDIA_DIRS for f in iter_files(os.path.join(m, "lua"), {".lua"})
             if os.path.isdir(os.path.join(m, "lua"))]

# ---- 1. luac 語法 ----
luac = shutil.which("luac")
if not luac:
    skip("Lua 語法（luac -p）", "PATH 沒有 luac")
else:
    bad = []
    for f in LUA_FILES:
        r = subprocess.run([luac, "-p", f], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append(r.stderr.strip().splitlines()[-1] if r.stderr else f)
    fail("Lua 語法（luac -p）", bad) if bad else ok(f"Lua 語法（luac -p，{len(LUA_FILES)} 檔）")

# ---- 2. BOM / CRLF ----
bad = []
for m in MEDIA_DIRS:
    for f in iter_files(m, {".lua", ".json", ".txt"}):
        with open(f, "rb") as fh:
            data = fh.read()
        rel = os.path.relpath(f, REPO)
        if data.startswith(b"\xef\xbb\xbf"):
            bad.append(f"BOM: {rel}")
        if b"\r" in data:
            bad.append(f"CRLF: {rel}")
fail("BOM / CRLF（42/media 下）", bad) if bad else ok("BOM / CRLF（42/media 下）")

# ---- 3+4. 翻譯鍵集一致 / 裸 % ----
# 裸 % 的判定分兩種模式：
#   嚴格（家族自製 MOD，語系含 EN 等四語）：只認引擎 Translator.formatted() 的 %1-%9 與 %%
#   寬容（翻譯包，語系 ⊆ {CH,CN}）：另接受 printf 指令（%s/%d/%.1f…）——第三方 MOD 常用
#     string.format(getText(...)) 消費譯文，這時保留 %d 才是對的，逸出反而弄壞
# 刻意不含 printf 旗標字元（-+空白#0）：含空白旗標會讓「50% done」的「% d」被解析成
# 合法指令而漏抓——翻譯實務上只會出現簡單的 %s/%d/%.1f，罕見旗標用法交給豁免清單
PRINTF_RE = re.compile(r"%\d*(?:\.\d+)?[sdifuxXcqgGeE]")


def find_bare_pct(value, tolerant):
    s = str(value)
    i = 0
    while i < len(s):
        if s[i] != "%":
            i += 1
            continue
        if i + 1 < len(s) and s[i + 1] in "123456789%":
            i += 2          # 消耗合法配對——lookahead 不消耗會把 "40%%" 誤報（踩過）
            continue
        if tolerant:
            mm = PRINTF_RE.match(s, i)
            if mm:
                i = mm.end()
                continue
        return True
    return False


for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    tolerant = set(langs) <= {"CH", "CN"}   # 翻譯包偵測
    names = sorted({n for l in langs for n in os.listdir(os.path.join(troot, l)) if n.endswith(".json")})
    mismatch, badpct, broken, example_warning = [], [], [], []
    for n in names:
        keysets = {}
        for l in langs:
            p = os.path.join(troot, l, n)
            if not os.path.isfile(p):
                mismatch.append(f"{n}: {l} 缺檔")
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception as e:
                broken.append(f"{l}/{n}: {e}")
                continue
            keysets[l] = set(data)
            for k, v in data.items():
                if find_bare_pct(v, tolerant):
                    badpct.append(f"{l}/{n} 的 {k}")
            if n == "IG_UI.json":
                for warning_key in (
                    "IGUI_MinidoracatNB_ExamplesLangCH",
                    "IGUI_MinidoracatNB_ExamplesLangEN",
                ):
                    warning = data.get(warning_key)
                    if not isinstance(warning, str) or "categories.txt" not in warning:
                        example_warning.append(
                            f"{l}/{n} 的 {warning_key} 未明示覆寫 categories.txt")
        if len(keysets) > 1:
            base = next(iter(keysets.values()))
            for l, ks in keysets.items():
                if ks != base:
                    mismatch.append(f"{n}: {l} 鍵集不一致（差 {len(ks ^ base)} 鍵）")
    if broken:
        fail("翻譯 JSON 可解析", broken)
    else:
        ok("翻譯 JSON 可解析")
    fail("翻譯鍵集一致", mismatch) if mismatch else ok(f"翻譯鍵集一致（{'/'.join(langs)}）")
    pct_label = "翻譯值無裸 %（翻譯包模式：另接受 printf 指令）" if tolerant else "翻譯值無裸 %（僅 %1-%9 與 %%）"
    fail(pct_label, sorted(set(badpct))) if badpct else ok(pct_label)
    fail("重建範例選單明示覆寫 categories.txt", example_warning) if example_warning \
        else ok("重建範例選單明示覆寫 categories.txt")

# ---- 5+6. Kahlua 禁用全域 / table.sort ----
FORBIDDEN = ("next", "assert", "xpcall")
hits_forbidden, hits_sort = [], []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            for name in FORBIDDEN:
                for mm in re.finditer(rf"(?<![\w_:.]){name}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
            if re.search(r"(?<![\w_])table\.sort\s*\(", code):
                hits_sort.append(f"{rel}:{lineno}")
fail("Kahlua 禁用全域（next/assert/xpcall）", hits_forbidden) if hits_forbidden \
    else ok("Kahlua 禁用全域（next/assert/xpcall）")
fail("無 table.sort（用迭代 sortSafe，見 AGENTS.md）", hits_sort) if hits_sort \
    else ok("無 table.sort")

# ---- 7. MOD/ 樹雜物 ----
junk = []
for base, dirs, _ in os.walk(os.path.join(REPO, "MOD")):
    for d in list(dirs):
        if d in (".omc", ".claude", ".gitnexus"):
            junk.append(os.path.relpath(os.path.join(base, d), REPO))
            dirs.remove(d)
fail("MOD/ 樹無 AI 工具狀態目錄", junk) if junk else ok("MOD/ 樹無 AI 工具狀態目錄")

# ---- 8. 佔位符殘留 ----
tokens = []
SELF = os.path.abspath(__file__)   # 本檔 docstring 有 {{TOKEN}} 範例字樣，排除自己
for base, dirs, files in os.walk(REPO):
    dirs[:] = [d for d in dirs if d not in (".git", ".omc", ".claude", ".gitnexus", "__pycache__")]
    for name in files:
        p = os.path.join(base, name)
        if os.path.abspath(p) == SELF:
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        for mm in re.finditer(r"\{\{[A-Z_]+\}\}", text):
            tokens.append(f"{os.path.relpath(p, REPO)}: {mm.group()}")
fail("無 {{TOKEN}} 佔位符殘留", tokens) if tokens else ok("無 {{TOKEN}} 佔位符殘留")

# ---- 9. Steam 描述位元組 ----
descs = [f for f in os.listdir(REPO) if f.startswith("STEAM_DESCRIPTION") and f.endswith(".md")]
over = []
for f in descs:
    size = os.path.getsize(os.path.join(REPO, f))
    if size > 8000:
        over.append(f"{f}: {size} bytes（上限 8000）")
if descs:
    fail("Steam 描述 ≤8000 bytes", over) if over else ok(f"Steam 描述 ≤8000 bytes（{len(descs)} 檔）")

# ---- 10. 沙盒選項翻譯配對 ----
for m in MEDIA_DIRS:
    sb = os.path.join(m, "sandbox-options.txt")
    if not os.path.isfile(sb):
        continue
    with open(sb, encoding="utf-8") as fh:
        txt = fh.read()
    opts = set(re.findall(r"translation\s*=\s*(\S+?)\s*,", txt))
    pages = set(re.findall(r"page\s*=\s*(\S+?)\s*,", txt))
    ch = os.path.join(m, "lua", "shared", "Translate", "CH", "Sandbox.json")
    if not os.path.isfile(ch):
        fail("沙盒選項翻譯配對", ["有 sandbox-options.txt 但無 CH/Sandbox.json"])
        continue
    with open(ch, encoding="utf-8") as fh:
        keys = set(json.load(fh))
    miss = [f"缺標題: Sandbox_{o}" for o in opts if f"Sandbox_{o}" not in keys]
    miss += [f"缺 tooltip: Sandbox_{o}_tooltip" for o in opts if f"Sandbox_{o}_tooltip" not in keys]
    miss += [f"缺分頁名: Sandbox_{p}" for p in pages if f"Sandbox_{p}" not in keys]
    fail("沙盒選項翻譯配對", miss) if miss else ok(f"沙盒選項翻譯配對（{len(opts)} 選項）")

# ---- 11. CHANGELOG 洩漏掃描 ----
LEAK_PATTERNS = [
    (re.compile(r"/home/\w+"), "Linux 家目錄路徑"),
    (re.compile(r"[A-Z]:\\Users\\"), "Windows 使用者路徑"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "IPv4 位址"),
    (re.compile(r"\b7656\d{13}\b"), "SteamID64"),
    (re.compile(r"\bssh\b", re.IGNORECASE), "ssh 字樣"),
    (re.compile(r"pz-?server", re.IGNORECASE), "伺服器主機名"),
]
_cl = os.path.join(REPO, "CHANGELOG.md")
if os.path.isfile(_cl):
    leaks = []
    with open(_cl, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for pat, desc in LEAK_PATTERNS:
                mm = pat.search(line)
                if mm:
                    leaks.append(f"CHANGELOG.md:{lineno} {desc}（{mm.group()[:40]}）")
    fail("CHANGELOG 無基礎設施洩漏樣式", leaks) if leaks else ok("CHANGELOG 無基礎設施洩漏樣式")

# ---- 12. Lua 單元測試 ----
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

# ---- 13. UI 皮膚貼圖：已上移家族框架 MinidoracatUIFor42 ----
# 貼圖（mui_*.png）與 gen_ui_textures.py 隨框架 repo 驗證與上傳；本 repo 的 NBSkin
# 只是 thin adapter（框架缺席退直角），不再攜帶任何 PNG 資產，故無貼圖閘門。

# ---- 14. 提示音音檔 ----
# 與貼圖同一個理由：playUISound 對「找不到音效名」是靜默無聲、不拋錯
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
    # 語音提示音（MinidoracatNBVoiceCH/EN/JP）同一組規格：面板的語音語系選項直接
    # playUISound 這些名字，換聲音是使用者的權利，所以一樣只驗規格不比對內容。
    _snd_problems = []
    for _rel in (_SND_REL,) + _VOICE_RELS:
        _snd_problems += [f"{os.path.basename(_rel)}: {p}"
                          for p in _verify_sound(os.path.join(REPO, _rel))]
    fail("提示音音檔（prep_notify_sound.verify_notify_sound）", _snd_problems) if _snd_problems \
        else ok(f"提示音音檔（提示音＋語音 {len(_VOICE_RELS)} 語過規格檢查）")

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
_steam_shot_names = {
    os.path.join("zh", "01-markdown-headings.jpg"),
    os.path.join("zh", "02-markdown-inline-and-images.jpg"),
    os.path.join("zh", "03-richtext-and-emoji-limitations.jpg"),
    os.path.join("zh", "04-sandbox-options-zh.jpg"),
    os.path.join("en", "01-panel-document-tree.jpg"),
    os.path.join("en", "02-language-menu.jpg"),
    os.path.join("en", "03-server-language-folders.jpg"),
    os.path.join("en", "04-sandbox-options.jpg"),
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
                _size = _probe.size
                _probe.verify()
            with _CoverImage.open(_path) as _decoded:
                _decoded.load()
        except (OSError, SyntaxError, ValueError) as _error:
            _steam_shot_problems.append(f"{_name}: JPEG 解碼失敗（{_error}）")
            continue
        if _format != "JPEG" or _mode != "RGB" or _size != (1920, 1032):
            _steam_shot_problems.append(
                f"{_name}: {_format}/{_mode}/{_size}，預期 JPEG/RGB/(1920, 1032)")
        if os.path.getsize(_path) > 280_000:
            _steam_shot_problems.append(
                f"{_name}: {os.path.getsize(_path):,} bytes，超過 280,000（publish_workshop.py --mode screenshots 會被 Steam 拒絕）")
    fail("Steam 介面預覽圖", _steam_shot_problems) if _steam_shot_problems \
        else ok(f"Steam 介面預覽圖（{len(_steam_shot_names)} 張 1920×1032 RGB JPG，皆 ≤280KB）")

# ---- 總結 ----
print()
print(f"PASS {len(passed)} / FAIL {len(failed)} / SKIP {len(skipped)}")
sys.exit(1 if failed else 0)
