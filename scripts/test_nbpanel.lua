-- NBPanel 的圖片預檢，跑在**原版 ISRichTextPanel.lua 之上**。
--
-- 為什麼要有這一支：test_mdparser.lua 只載 shared/ 的純模組，NBPanel.lua 一行都沒被載入過，
-- 所以「預檢兩圈到底有沒有呼叫夾限／護欄」完全沒有防線——把守衛加回第一圈、或把第二圈的
-- `else` 改回 `elseif requestedWidth ~= nil then`，整份 test_mdparser.lua 仍然全綠。
-- 這裡直接 dofile 原版引擎與 NBPanel.lua 本體，用真的 paginate/processCommand 驗結果，
-- 不移植、不重寫 paginate／processCommand（模擬器與實作一起錯的話兩邊都看不出來）。
-- **唯一的例外是 colorOf**：它手寫了 render() 的整行套色與顏色延續（:606-617），
-- 因為 render 要真的畫。改它等於改守門員，動之前先對照引擎那幾行。
--
-- 用法（在 repo 根目錄）：lua scripts/test_nbpanel.lua
-- 找不到遊戲本體時直接跳過（退出碼 0）：這支測試依賴 PZ 安裝，不是每台機器都有。
-- 退出碼 0 代表「沒跑」與「跑過且全過」看起來一樣，所以閘門那端（scripts/verify_mod.py）
-- 認輸出開頭的 SKIP 字樣，把它列成 SKIP 而不是 PASS。
-- 遊戲裝在別處時用 PZ_LUA 指到 <遊戲>/media/lua。

local MEDIA_LUA = "MOD/MinidoracatNoticeBoardFor42/Contents/mods/"
    .. "MinidoracatNoticeBoardFor42/42/media/lua/"
local VANILLA_LUA = os.getenv("PZ_LUA")
    or "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua"
local ENGINE_FILE = VANILLA_LUA .. "/client/ISUI/ISRichTextPanel.lua"

local probe = io.open(ENGINE_FILE, "r")
if not probe then
    print("SKIP test_nbpanel: engine source not found at " .. ENGINE_FILE)
    print("     (set PZ_LUA=<ProjectZomboid>/media/lua to run it)")
    os.exit(0)
end
probe:close()

package.path = MEDIA_LUA .. "shared/?.lua;" .. package.path

local assertionCount = 0

local function check(condition, message)
    assertionCount = assertionCount + 1
    assert(condition, message)
end

local function checkEqual(actual, expected, message)
    assertionCount = assertionCount + 1
    assert(
        actual == expected,
        (message or "values differ")
            .. "\nexpected: " .. tostring(expected)
            .. "\nactual:   " .. tostring(actual)
    )
end

local function contains(text, fragment)
    return string.find(text, fragment, 1, true) ~= nil
end

-- tag 之間的空白數量不是規格（規格是「至少一個」，見 MDParser 檔頭）；
-- 比對整串產出時把空白收斂掉，才不會被無關的排版差異卡住。
local function norm(text)
    text = string.gsub(tostring(text), "%s+", " ")
    text = string.gsub(text, "^%s+", "")
    return string.gsub(text, "%s+$", "")
end

local function checkNormEqual(actual, expected, message)
    return checkEqual(norm(actual), norm(expected), message)
end

-- ---------------------------------------------------------------------------
-- PZ 全域 stub。只補到「原版 ISRichTextPanel 與 NBPanel 載得起來、跑得動預檢」為止。
-- ---------------------------------------------------------------------------
local realRequire = require
_G.require = function() return nil end

function _G.string.trim(text)
    return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end
function _G.string.contains(text, fragment)
    return string.find(text, fragment, 1, true) ~= nil
end
-- Java 端 StringLib.split（StringLib.java:1401-1412）就是 Java 的 String.split(regex)：
--   * 分隔符是 **regex**——本專案所有呼叫點都是 "," / "<LINE>"（無 metachar），
--     所以這裡用字面比對就夠；哪天出現 metachar 分隔符，這個 stub 會比引擎寬容。
--   * **尾端空欄會被丟掉**（limit=0）。所以 "IMAGE:a.png,0," 在引擎是 vs[3]=nil ->
--     string.trim(nil) 拋錯 -> 整份公告變錯誤占位；stub 若保留尾端空欄就會給假綠燈
--     （這正是 NBCore.parseImageTagArguments 要求逗號參數只能 0 或 2 個的理由）。
function _G.string.split(text, separator)
    local first = string.find(text, separator, 1, true)
    if not first then
        -- Java 的快速路徑：一個分隔符都沒有時原樣回傳整串
        return { text }
    end
    local parts = {}
    local position = 1
    while true do
        local from, to = string.find(text, separator, position, true)
        if not from then
            parts[#parts + 1] = string.sub(text, position)
            break
        end
        parts[#parts + 1] = string.sub(text, position, from - 1)
        position = to + 1
    end
    while #parts > 0 and parts[#parts] == "" do
        parts[#parts] = nil
    end
    return parts
end

_G.UIFont = { NewSmall = "NewSmall", Small = "Small", Medium = "Medium",
    Large = "Large", Intro = "Intro", Cred1 = "Cred1", Cred2 = "Cred2" }

-- 字型量測是假的（每字 8px、行高 18px）：像素換行點與實機不同，所以本檔只斷言
-- 顏色與圖片尺寸，不斷言「一列排幾張圖」這種需要真實字寬的結論。
local CHAR_WIDTH = 8
local LINE_HEIGHT = 18
_G.getTextManager = function()
    return {
        MeasureStringX = function(_, _, text) return string.len(text or "") * CHAR_WIDTH end,
        getFontFromEnum = function() return { getLineHeight = function() return LINE_HEIGHT end } end,
        getFontHeight = function() return LINE_HEIGHT end,
    }
end

local function colorStub(r, g, b)
    return { getR = function() return r end, getG = function() return g end,
        getB = function() return b end }
end
_G.getCore = function()
    return {
        getGoodHighlitedColor = function() return colorStub(0.1, 0.9, 0.1) end,
        getBadHighlitedColor = function() return colorStub(0.9, 0.1, 0.1) end,
        getKey = function() return 1 end,
        getScreenWidth = function() return 1920 end,
        getScreenHeight = function() return 1080 end,
        getOptionDoVideoEffects = function() return false end,
    }
end
_G.Core = { getInstance = function()
    return { getOptionDoVideoEffects = function() return false end }
end }
_G.getKeyName = function() return "K" end

local TEXTURE_SIZES = {}
_G.getTexture = function(path)
    local size = TEXTURE_SIZES[path]
    if not size then
        return nil
    end
    return {
        getWidth = function() return size[1] end,
        getHeight = function() return size[2] end,
    }
end
_G.Joypad = { Texture = { fromCommand = function() return nil end } }
_G.getVideo = function() return nil end

local Base = {}
Base.__index = Base
local derivedClasses = {}
function Base:derive(name)
    local class = setmetatable({}, self)
    self.__index = self
    class.Type = name
    -- NBLinkRichTextPanel 是 NBPanel.lua 的區域變數，外面拿不到；在這裡側錄，
    -- 才驗得到它的 processCommand 覆寫（NBCACHE_ 替身換回絕對路徑那一段）。
    derivedClasses[name] = class
    return class
end
function Base:new(x, y, width, height)
    local instance = setmetatable({}, self)
    self.__index = self
    instance.x, instance.y = x, y
    instance.width, instance.height = width, height
    return instance
end
function Base:initialise() end
function Base:createChildren() end
function Base:setHeight(height) self.height = height end
function Base:setScrollHeight(height) self.scrollHeight = height end
function Base:getYScroll() return 0 end
function Base:getXScroll() return 0 end
function Base:setYScroll() end
function Base:getHeight() return self.height end
function Base:getWidth() return self.width end
function Base:getX() return self.x end
function Base:setX(x) self.x = x end
function Base:setY(y) self.y = y end
-- 頂層視窗（NBPanel／NBFloatButton／NBToast 都直接掛在 UIManager 上）：絕對座標 = 自身座標
function Base:getAbsoluteX() return self.x end
function Base:getAbsoluteY() return self.y end
function Base:getMouseX() return 0 end
function Base:getMouseY() return 0 end
function Base:isMouseOver() return false end
function Base:getIsVisible() return true end
function Base:addChild() end
function Base:addScrollBars() end
function Base:setAnchorsTBLR() end
function Base:setFont() end
function Base:setStencilRect() end
function Base:clearStencilRect() end
function Base:repaintStencilRect() end
function Base:drawText() end
function Base:drawTextCentre() end
function Base:drawTextRight() end
function Base:drawTextureScaled() end
function Base:drawRect() end
function Base:drawRectBorder() end
function Base:setVisible() end
function Base:updateScrollbars() end
_G.ISPanel = Base
_G.ISBaseObject = Base

dofile(ENGINE_FILE)

local NBCore = realRequire "NoticeBoard/NBCore"
_G.NBCore = NBCore
_G.NBImage = realRequire "NoticeBoard/NBImage"
local MDParser = realRequire "NoticeBoard/MDParser"
_G.MDParser = MDParser

-- NBImageCache：只 stub 出預檢與 processCommand 覆寫會碰到的三個面。
local CACHE_HASH_OF_PATH = {}
local CACHE_PATH_OF_HASH = {}
_G.NBImageCache = {
    TOKEN_PREFIX = "NBCACHE_",
    STATUS_EVENT = "e4",
    hashForPath = function(path) return CACHE_HASH_OF_PATH[path] end,
    pathForHash = function(hash) return CACHE_PATH_OF_HASH[hash] end,
}
local UNREAD_IDS = {}
_G.NBClient = { CONTENT_READY_EVENT = "e1", UNREAD_CHANGED_EVENT = "e2",
    LANGUAGE_STATUS_EVENT = "e3",
    isUnread = function(fileId) return UNREAD_IDS[fileId] == true end,
    getUnreadIds = function() return {} end }
_G.NBToast = { show = function() end }
-- 玩家端音效設定（真模組會去讀 PZAPI.ModOptions／ModOptions.ini，harness 沒有那一套）。
-- 音量預設 1 = 滿音量，這樣「不呼叫 setVolume」是可斷言的行為；下面音效那段會改它。
local SOUND_VOLUME = { value = 1 }
_G.NBOptions = { soundVolume = function() return SOUND_VOLUME.value end }
_G.ISCollapsableWindowJoypad = Base:derive("ISCollapsableWindowJoypad")
-- 版面常數（原生公式 ISCollapsableWindow.lua:298-303 代入本 harness 的假字高 18）：
-- titleBarHeight = max(16, 18+1) = 19；resizeWidgetHeight = (18+6)/2 + 2 = 14。
-- 下方版面測試的期望值就是用這兩個數字手算出來的字面值。
function ISCollapsableWindowJoypad:titleBarHeight() return 19 end
function ISCollapsableWindowJoypad:resizeWidgetHeight() return 14 end
_G.ISButton = Base:derive("ISButton")
_G.ISContextMenu = Base:derive("ISContextMenu")
_G.ISLayoutManager = { RegisterWindow = function() end }
_G.Events = setmetatable({}, { __index = function(events, key)
    local event = { Add = function() end, Remove = function() end }
    rawset(events, key, event)
    return event
end })
_G.getText = function(key) return "[" .. tostring(key) .. "]" end
_G.getTimestampMs = function() return 0 end
_G.getSpecificPlayer = function() return nil end
_G.getAccessLevel = function() return "None" end
_G.Clipboard = { setClipboard = function() end }
_G.openUrl = function() end
_G.getFileSeparator = function() return "/" end
_G.Translator = { getLanguage = function() return { name = function() return "EN" end } end }
_G.SandboxVars = {}
_G.writeLog = function() end

-- 皮膚：先載家族框架（MinidoracatUIFor42 的 V1.lua，繪製核心所在），再載 NBSkin
-- （現為框架 thin adapter）。框架 repo 預設在本 repo 同層（家族慣例，同反編譯快照），
-- 放別處用 MUI_LUA 指到 V1.lua。harness 沒有 NinePatchTexture 全域＝驗「引擎沒有
-- 9-slice／dedicated」的退回路徑；有貼圖的路徑在下方用 stub 另外驗。
local MUI_V1 = os.getenv("MUI_LUA")
    or "../MinidoracatUIFor42/MOD/MinidoracatUIFor42/Contents/mods/MinidoracatUIFor42/42/media/lua/client/MinidoracatUI/V1.lua"
do
    -- 缺框架 repo＝前置條件不滿足，走既有 SKIP 紀律（同上方引擎源檢查）——
    -- 不是 FAIL：單 repo clone／CI 沒 checkout 框架時要能誠實跳過而非 traceback。
    local fh = io.open(MUI_V1, "rb")
    if not fh then
        print("SKIP test_nbpanel: framework V1.lua not found at " .. MUI_V1)
        print("     (clone MinidoracatUIFor42 beside this repo, or set MUI_LUA=<path to V1.lua>)")
        os.exit(0)
    end
    fh:close()
end
dofile(MUI_V1)
check(MinidoracatUI ~= nil and MinidoracatUI.v1 ~= nil, "框架 facade 已發布（NBSkin 靠它綁定）")
dofile(MEDIA_LUA .. "client/NoticeBoard/NBSkin.lua")
dofile(MEDIA_LUA .. "client/NoticeBoard/NBPanel.lua")

local NBLinkRichTextPanel = derivedClasses["NBLinkRichTextPanel"]
check(NBLinkRichTextPanel ~= nil, "沒有側錄到 NBLinkRichTextPanel（NBPanel.lua 結構變了？）")

-- ---------------------------------------------------------------------------
-- 測試用具
-- ---------------------------------------------------------------------------
local PANEL_WIDTH = 600
local PANEL_HEIGHT = 400
-- imageFitSize 的上限：寬 = width - marginLeft - marginRight - 12、高 = height * 3
local MAX_IMAGE_WIDTH = PANEL_WIDTH - 20 - 10 - 12
local MAX_IMAGE_HEIGHT = PANEL_HEIGHT * 3

local function newRichText()
    local panel = NBLinkRichTextPanel:new(0, 0, PANEL_WIDTH, PANEL_HEIGHT, nil)
    panel:initialise()
    panel.marginLeft, panel.marginTop = 20, 10
    panel.marginRight, panel.marginBottom = 10, 10
    panel.maxLines = 0
    panel.defaultFont = UIFont.NewSmall
    panel.autosetheight = false
    panel.text = ""
    return panel
end

-- 真的跑 NBPanel:preflightImages（兩圈都跑），回傳交給引擎的 richText
local function preflight(markdown)
    local richText = newRichText()
    local owner = setmetatable({ richText = richText }, { __index = NBPanel })
    return owner:preflightImages(MDParser.parse(markdown)), richText
end

-- 真的跑 paginate（含 NBLinkRichTextPanel 的 processCommand 覆寫）
local function paginate(text)
    local panel = newRichText()
    panel.text = text
    local ok, pageError = panel:paginate()
    check(ok, "paginate 拋錯（整份公告會變成錯誤占位）：" .. tostring(pageError))
    return panel
end

-- ---------------------------------------------------------------------------
-- 純圖片行必須進得了捲動範圍。
-- 引擎的 paginate 只在「這一行有非空文字」時才把 lineImageHeight 累進 y
-- （ISRichTextPanel.lua:550-556），`![圖](路徑)` 自己一行時該行文字是空字串，整張圖的高度
-- 因此被丟棄、setScrollHeight 不含圖片 -> 圖比內容區高時完全捲不動，圖下面的公告看不到。
-- 這一段先端到端證明「引擎真的漏算」（否則修正就是無效的加工），再驗補算的算式。
-- ---------------------------------------------------------------------------
;(function()
    TEXTURE_SIZES["media/textures/pack/scroll_big.png"] = { 200, 1200 }

    local scrolls = {}
    local panel = newRichText()
    panel.getScrollHeight = function() return 0 end
    panel.setScrollHeight = function(_, h) scrolls[#scrolls + 1] = h end
    panel.text = " <IMAGECENTRE:media/textures/pack/scroll_big.png> "
    local ok = panel:paginate()
    check(ok, "純圖片內容不得讓 paginate 失敗")

    -- 引擎自己算的那一次（marginTop + y + marginBottom）不含圖高；我們補的那一次才含。
    check(#scrolls >= 2,
        "paginate 應先由引擎設一次捲動高度，再由 extendScrollHeightForImages 補一次")
    local engineHeight = scrolls[1]
    local finalHeight = scrolls[#scrolls]
    check(engineHeight < 1200,
        "前提檢查：引擎算的捲動高度本來就不含圖片高度（實際 " .. tostring(engineHeight) .. "）")
    check(finalHeight >= 1200,
        "補算後的捲動高度必須蓋過圖片底部（實際 " .. tostring(finalHeight) .. "）")

    -- **markdown 的 ![]() 走的是 <IMAGE:> 不是 <IMAGECENTRE:>**（MDParser 的註解：
    -- ![]() 是靠左的行內元素，故不用會強制置中的 IMAGECENTRE），而兩者在引擎裡是不同分支、
    -- 高度與 imageY 的算法都不同（ISRichTextPanel.lua:155-175 vs :320-336），
    -- 且 <IMAGE:> 的 imageY 還被 NBLinkRichTextPanel:processCommand 拉回該行頂端。
    -- 使用者實際踩到的就是這條路徑，所以要獨立驗一次端到端。
    TEXTURE_SIZES["media/textures/pack/scroll_md.png"] = { 200, 1500 }
    local mdScrolls = {}
    local mdPanel = newRichText()
    mdPanel.getScrollHeight = function() return 0 end
    mdPanel.setScrollHeight = function(_, h) mdScrolls[#mdScrolls + 1] = h end
    mdPanel.text = preflight("![大圖](media/textures/pack/scroll_md.png)")
    check(mdPanel:paginate(), "markdown 圖片內容不得讓 paginate 失敗")
    check(string.find(mdPanel.text, "<IMAGE:", 1, true) ~= nil,
        "前提：markdown ![]() 產生的是 <IMAGE:>（不是 IMAGECENTRE）")
    local mdBottom = (mdPanel.imageY[1] or 0) + (mdPanel.imageH[1] or 0)
    check(mdBottom > 0, "圖片底部必須算得出來（imageY 已被 processCommand 拉回行頂）")
    check(mdScrolls[1] < mdBottom,
        "前提檢查：<IMAGE:> 分支的引擎捲動高度同樣不含圖片（實際 "
            .. tostring(mdScrolls[1]) .. " < " .. tostring(mdBottom) .. "）")
    check(mdScrolls[#mdScrolls] >= mdBottom,
        "補算後必須蓋過 markdown 圖片的底部（實際 " .. tostring(mdScrolls[#mdScrolls]) .. "）")

    -- 算式：max(imageY + imageH) + 上下 margin。imageY 為負（圖比行高時 :172 的
    -- (lineHeight-lineImageHeight)/2 是負值）也要算得對。
    scrolls = {}
    panel.images = { "tex" }
    panel.imageY = { -100 }
    panel.imageH = { 900 }
    panel.marginTop, panel.marginBottom = 10, 5
    panel:extendScrollHeightForImages()
    checkEqual(scrolls[1], 815, "捲動高度 = (imageY + imageH) + marginTop + marginBottom")

    -- 只加不減：引擎算的已經夠高（文字比圖長）就不要覆蓋掉
    scrolls = {}
    panel.getScrollHeight = function() return 5000 end
    panel:extendScrollHeightForImages()
    checkEqual(#scrolls, 0, "引擎算的已經夠高時不得再設一次（文字比圖長的情形）")

    -- 沒有圖片時完全不動作
    scrolls = {}
    panel.images = {}
    panel.getScrollHeight = function() return 0 end
    panel:extendScrollHeightForImages()
    checkEqual(#scrolls, 0, "沒有圖片就不該碰捲動高度")
end)()

-- render 實際會用的顏色：整行套用、未被覆寫的行沿用前一行（ISRichTextPanel.lua:613-617）
local function colorOf(panel, fragment)
    local carried = nil
    local index
    for index = 1, #panel.lines do
        if panel.rgb[index] then
            carried = panel.rgb[index]
        end
        if panel.lines[index] and contains(panel.lines[index], fragment) then
            if not carried then
                return "nil"
            end
            return string.format("%s,%s,%s", tostring(carried.r), tostring(carried.g),
                tostring(carried.b))
        end
    end
    return "MISSING:" .. fragment
end

-- ---------------------------------------------------------------------------
-- D1：圖包 MOD 的貼圖（media/...）也走尺寸夾限。
-- 這幾條就是「把第一圈的 if image.width or image.height 守衛加回去」會紅的那幾條。
-- ---------------------------------------------------------------------------
TEXTURE_SIZES["media/textures/pack/huge.png"] = { 4000, 3000 }
TEXTURE_SIZES["media/textures/pack/small.png"] = { 100, 80 }
TEXTURE_SIZES["media/textures/pack/tall.png"] = { 100, 5000 }

local hugeExpectedHeight = math.floor(3000 * MAX_IMAGE_WIDTH / 4000)
checkNormEqual(
    preflight("![圖](media/textures/pack/huge.png)"),
    " <TEXT> <INDENT:0> <IMAGE:media/textures/pack/huge.png,"
        .. MAX_IMAGE_WIDTH .. "," .. hugeExpectedHeight .. "> ",
    "沒寫尺寸的 MOD 貼圖必須被夾限（第一圈的無條件夾限）"
)
checkNormEqual(
    preflight("![圖](media/textures/pack/small.png)"),
    " <TEXT> <INDENT:0> <IMAGE:media/textures/pack/small.png> ",
    "塞得下的 MOD 貼圖產出必須完全不變（不得多出逗號參數）"
)
-- 服主手寫、不帶尺寸的原生 tag：走的是第二圈的 else 分支
checkNormEqual(
    preflight("<IMAGE:media/textures/pack/huge.png>"),
    " <TEXT> <INDENT:0> <IMAGE:media/textures/pack/huge.png,"
        .. MAX_IMAGE_WIDTH .. "," .. hugeExpectedHeight .. "> ",
    "手寫且不帶尺寸的原生 tag 也必須被夾限（第二圈必須無條件重建）"
)
-- 冪等：把上一輪的產出當成手寫公告再跑一次，結果不得再變（第二圈會重跑第一圈的產物）
checkNormEqual(
    preflight("<IMAGE:media/textures/pack/huge.png," .. MAX_IMAGE_WIDTH .. ","
        .. hugeExpectedHeight .. ">"),
    " <TEXT> <INDENT:0> <IMAGE:media/textures/pack/huge.png,"
        .. MAX_IMAGE_WIDTH .. "," .. hugeExpectedHeight .. "> ",
    "夾限必須冪等（每次重畫都會再跑一次第二圈）"
)
-- 窄而極高的圖靠高度上限夾住
checkNormEqual(
    preflight("![圖](media/textures/pack/tall.png)"),
    " <TEXT> <INDENT:0> <IMAGE:media/textures/pack/tall.png,"
        .. math.floor(100 * MAX_IMAGE_HEIGHT / 5000) .. "," .. MAX_IMAGE_HEIGHT .. "> ",
    "窄而極高的圖必須受高度上限夾限"
)

-- 同一份公告出現兩次相同路徑：尺寸必須落在指定的那一張。
-- 第一圈是靠 replaceNextLiteral 帶著游標逐一消耗 <NBIMG:n>（同路徑的 token 仍不同），
-- 游標算錯就會把尺寸貼到另一張上，而兩張的路徑一樣、光看路徑看不出來。
checkNormEqual(
    preflight("![甲](media/textures/pack/small.png =60x40) ![乙](media/textures/pack/small.png)"),
    " <TEXT> <INDENT:0> <IMAGE:media/textures/pack/small.png,60,40>"
        .. " <IMAGE:media/textures/pack/small.png> ",
    "同路徑兩張圖時，尺寸必須落在寫了尺寸的那一張"
)

-- 引擎真的採用夾限後的尺寸（:158-161 只有在 w==0 時才回頭問貼圖原始尺寸）
local clampedPanel = paginate(preflight("![圖](media/textures/pack/huge.png)"))
checkEqual(clampedPanel.imageW[1], MAX_IMAGE_WIDTH, "引擎採用的寬度不是夾限後的值")
checkEqual(clampedPanel.imageH[1], hugeExpectedHeight, "引擎採用的高度不是夾限後的值")

-- 貼圖載不起來時整張換成占位，不得把壞路徑丟給引擎（:157-160 會對 nil 呼叫 getWidth）
check(contains(preflight("![替代文字](media/textures/pack/missing.png)"), "[替代文字]"),
    "載不到的貼圖必須換成替代文字占位")

-- 服主手寫的 <IMAGECENTRE:>（MDParser 的原生 tag 白名單放行，MDParser.lua:226，
-- 形狀交由這裡的預檢負責）只有第二圈這一道夾限與護欄——上面每一條都是 <IMAGE:>，
-- 把第二圈的 IMAGECENTRE 那半邊拿掉時它們照樣全綠。
checkNormEqual(
    preflight("<IMAGECENTRE:media/textures/pack/huge.png>"),
    " <TEXT> <INDENT:0> <IMAGECENTRE:media/textures/pack/huge.png,"
        .. MAX_IMAGE_WIDTH .. "," .. hugeExpectedHeight .. "> ",
    "手寫且不帶尺寸的 <IMAGECENTRE:> 同樣必須被夾限"
)
checkNormEqual(
    preflight("<IMAGECENTRE:media/textures/pack/huge.png,100000,100000>"),
    " <TEXT> <INDENT:0> <IMAGECENTRE:media/textures/pack/huge.png,"
        .. MAX_IMAGE_WIDTH .. "," .. MAX_IMAGE_WIDTH .. "> ",
    "手寫 <IMAGECENTRE:> 的離譜尺寸同樣必須被夾限"
)

-- ---------------------------------------------------------------------------
-- D2 / F1：路徑含顏色字樣的圖片 —— 圖照畫，染色抵銷掉。
-- ---------------------------------------------------------------------------
TEXTURE_SIZES["media/textures/pack/RED_banner.png"] = { 100, 80 }

local hazardPanel = paginate(preflight("前文 ![替代](media/textures/pack/RED_banner.png) 後文"))
checkEqual(colorOf(hazardPanel, "後文"), colorOf(hazardPanel, "前文"),
    "含顏色字樣的路徑不得改變圖片之後的文字顏色")
checkEqual(colorOf(hazardPanel, "後文"), "0.7,0.7,0.7", "抵銷後必須回到本文色")
-- 對照組：同樣的內容不包護欄時，後文會被染紅（證明上面兩條不是恆真）
local barePanel = paginate(" <TEXT> <INDENT:0> 前文  <IMAGE:media/textures/pack/RED_banner.png>  後文 ")
checkEqual(colorOf(barePanel, "後文"), "1,0,0", "對照組：沒有護欄時圖片之後的文字必須被染紅")

-- F1：標題行內的圖片必須還原成**標題色**（<H1>/<H2> 自己不更新 rgbCurrent，
-- 靠 MDParser.H1_PREFIX/H2_PREFIX 補的 <RGB:> 同步；把它拿掉這兩條會變成 0.7,0.7,0.7）
local h1Panel = paginate(preflight("本文\n\n# 標前 ![替代](media/textures/pack/RED_banner.png) 標後"))
checkEqual(colorOf(h1Panel, "標後"), "1,1,1", "H1 標題行內的圖片護欄必須還原成標題色")
local h2Panel = paginate(preflight("本文\n\n## 標前 ![替代](media/textures/pack/RED_banner.png) 標後"))
checkEqual(colorOf(h2Panel, "標後"), "0.8,0.8,0.8", "H2 標題行內的圖片護欄必須還原成標題色")

-- ---------------------------------------------------------------------------
-- F3：含圖片的 `#` 標題行，圖片與文字必須落在**同一套座標系**。
--
-- 這一段的斷言只有 render 驗得到：paginate 留下的是 lineX / imageX，置中位移是 render
-- 當下才加上去的——置中分支算 lineLength 時只累加 MeasureStringX（ISRichTextPanel.lua:644-648，
-- 圖片寬度恆為 0），文字畫在 lineX + self.lineX[c]（:665），圖片卻在**另一個迴圈**用
-- imageX[c] + marginLeft 畫（:595）。所以「richText 字串長得對」完全證明不了圖文不會錯開。
--
-- 期望值寫字面像素值（不引用被測模組的常數）。算法：
--   圖片 x = imageX(0 + IMAGE_PAD 5) + marginLeft 20                       = 25
--   圖後文字 x = lineX(0 + 圖寬 100 + IMAGE_PAD*2 10) + marginLeft 20      = 130
--   置中的純文字 H1 x = marginLeft + (600 - 20 - 10 - 文字寬)/2；
--     "純文字大標" 是 15 bytes、假字型每 byte 8px -> 120px -> 20 + 225      = 245
-- ---------------------------------------------------------------------------
local function renderDraws(panel)
    local texts, images = {}, {}
    -- 實例欄位會蓋掉 Base 的同名方法，所以只攔這一顆 panel
    panel.drawText = function(_, text, x, y, r, g, b, _, font)
        texts[#texts + 1] = { text = text, x = x, y = y,
            color = string.format("%s,%s,%s", tostring(r), tostring(g), tostring(b)),
            font = font }
    end
    panel.drawTextureScaled = function(_, _, x, y, w, h)
        images[#images + 1] = { x = x, y = y, w = w, h = h }
    end
    ISRichTextPanel.render(panel)
    return texts, images
end

local function drawOf(draws, fragment)
    local index
    for index = 1, #draws do
        if contains(draws[index].text, fragment) then
            return draws[index]
        end
    end
    return { text = "MISSING:" .. fragment, x = "MISSING", color = "MISSING", font = "MISSING" }
end

TEXTURE_SIZES["media/textures/pack/head.png"] = { 100, 80 }

local h1ImageTexts, h1ImageImages =
    renderDraws(paginate(preflight("# ![替代](media/textures/pack/head.png) 標題文字")))
checkEqual(h1ImageImages[1] and h1ImageImages[1].x, 25, "含圖 H1：圖片必須畫在內容區最左端")
checkEqual(drawOf(h1ImageTexts, "標題文字").x, 130,
    "含圖 H1：標題文字必須緊接在圖片右側（與圖片同一套座標系，不再被置中位移推走）")
-- 只有 orient 改變：字型與顏色必須與 <H1>（:32-36）一模一樣
checkEqual(drawOf(h1ImageTexts, "標題文字").font, "Large", "含圖 H1 的字型必須仍是 Large")
checkEqual(drawOf(h1ImageTexts, "標題文字").color, "1,1,1", "含圖 H1 的顏色必須仍是純白")

-- 對照組一：不含圖片的 H1 仍然置中，且字型不變
local plainH1Texts = renderDraws(paginate(preflight("# 純文字大標")))
checkEqual(drawOf(plainH1Texts, "純文字大標").x, 245, "不含圖片的 H1 必須維持置中")
checkEqual(drawOf(plainH1Texts, "純文字大標").font, "Large", "不含圖片的 H1 字型必須不變")

-- 對照組二：H2 本來就靠左，落點與含圖 H1 相同 —— 證明 130 確實是「靠左」那個座標
local h2ImageTexts = renderDraws(paginate(preflight("## ![替代](media/textures/pack/head.png) 副標文字")))
checkEqual(drawOf(h2ImageTexts, "副標文字").x, 130, "含圖 H2 的落點必須與含圖 H1 相同")

-- orient 跨行沿用：render 的 orient 只在 self.orient[c] 非 nil 時才更新（:604 迴圈外初值、
-- :619 迴圈內），所以前綴少了 <LEFT> 時，這一行會沿用上一行 <H1> 留下的 centre。
-- 這一條就是釘住 <LEFT> 的那一條：拿掉它，第二個標題的文字會被推回置中位置。
local carryTexts, carryImages = renderDraws(paginate(preflight(
    "# 純文字大標\n# ![替代](media/textures/pack/head.png) 含圖大標")))
checkEqual(drawOf(carryTexts, "純文字大標").x, 245, "跨行沿用：前一個純文字 H1 仍必須置中")
checkEqual(carryImages[1] and carryImages[1].x, 25, "跨行沿用：第二個 H1 的圖片位置")
checkEqual(drawOf(carryTexts, "含圖大標").x, 130,
    "跨行沿用：緊接在置中 H1 之後的含圖 H1 必須自報 <LEFT>，不得沿用上一行的 centre")

-- 服主手寫的原生 <IMAGE:>：白名單放行、走引擎同一個 IMAGE 分支（:146-177，
-- imageX = x + IMAGE_PAD，一樣不吃置中位移），所以落點必須與 markdown 的 ![]() 一致。
local nativeH1Texts, nativeH1Images =
    renderDraws(paginate(preflight("# <IMAGE:media/textures/pack/head.png> 標題文字")))
checkEqual(nativeH1Images[1] and nativeH1Images[1].x, 25,
    "含手寫 <IMAGE:> 的 H1：圖片必須畫在內容區最左端")
checkEqual(drawOf(nativeH1Texts, "標題文字").x, 130,
    "含手寫 <IMAGE:> 的 H1：標題文字落點必須與 markdown 圖片版完全相同")
checkEqual(drawOf(nativeH1Texts, "標題文字").font, "Large",
    "含手寫 <IMAGE:> 的 H1 字型必須仍是 Large")
checkEqual(drawOf(nativeH1Texts, "標題文字").color, "1,1,1",
    "含手寫 <IMAGE:> 的 H1 顏色必須仍是純白")

-- 對照組：<IMAGECENTRE:> 不在修正範圍。引擎把它強制畫在水平正中（:205-206，與 orient
-- 無關），改成 <LEFT> 只會把文字拉到 127（=107+20）而圖片仍在正中。
-- 維持 <H1> 的置中分支：圖片 tag 收尾留下 x=0+100+7=107，置中位移是
-- 20+(600-20-10-96)/2=257，文字落在 257+107=364（96 是「標題文字」的量測寬）。
local centreH1Texts, centreH1Images =
    renderDraws(paginate(preflight("# <IMAGECENTRE:media/textures/pack/head.png> 標題文字")))
checkEqual(centreH1Images[1] and centreH1Images[1].x, 255.0,
    "<IMAGECENTRE:> 的圖片由引擎強制置中，與標題前綴無關")
checkEqual(drawOf(centreH1Texts, "標題文字").x, 364.0,
    "含 <IMAGECENTRE:> 的 H1 必須維持置中前綴（改成 <LEFT> 會落在 127）")

-- 手寫 <IMAGECENTRE:> 的護欄（同樣只有第二圈那半邊在管）
checkNormEqual(
    preflight("<IMAGECENTRE:media/textures/pack/RED_banner.png>"),
    " <TEXT> <INDENT:0> <PUSHRGB:0.7,0.7,0.7>"
        .. " <IMAGECENTRE:media/textures/pack/RED_banner.png> <POPRGB> ",
    "含顏色字樣的 <IMAGECENTRE:> 同樣必須被包上護欄"
)

-- 乾淨路徑：一個 token 都不得多出來
check(not contains(preflight("![圖](media/textures/pack/small.png)"), "PUSHRGB"),
    "乾淨路徑不得被包上護欄")

-- ---------------------------------------------------------------------------
-- F2：伺服器同步圖的危險字樣在**絕對路徑**上（richText 裡是 NBCACHE_ 替身）。
-- 玩家家目錄全大寫含 RED/GREEN 時，圖必須照畫、顏色照樣被抵銷。
-- ---------------------------------------------------------------------------
local HAZARD_ABS = "C:/Users/FRED/Zomboid/Lua/NoticeBoard/cache/abcd1234.png"
local CLEAN_ABS = "C:/Users/Ann/Zomboid/Lua/NoticeBoard/cache/beef5678.png"
CACHE_HASH_OF_PATH["images/hazard.png"] = "abcd1234"
CACHE_HASH_OF_PATH["images/clean.png"] = "beef5678"
CACHE_PATH_OF_HASH["abcd1234"] = HAZARD_ABS
CACHE_PATH_OF_HASH["beef5678"] = CLEAN_ABS
TEXTURE_SIZES[HAZARD_ABS] = { 100, 80 }
TEXTURE_SIZES[CLEAN_ABS] = { 100, 80 }

-- 期望值寫字面值，不引用被測模組自己的常數（引用的話護欄顏色改壞了這條照樣綠）
local cacheHazardText = preflight("前文 ![替代](images/hazard.png) 後文")
check(contains(cacheHazardText, " <PUSHRGB:0.7,0.7,0.7> <IMAGE:NBCACHE_abcd1234> <POPRGB> "),
    "同步圖的護欄必須依換回去之後的絕對路徑判定\n實際：" .. cacheHazardText)
check(not contains(preflight("前文 ![替代](images/clean.png) 後文"), "PUSHRGB:0.7"),
    "乾淨的絕對路徑不得被包護欄")

-- 真的走一次 NBLinkRichTextPanel:processCommand（替身換回絕對路徑後才進引擎）
local cachePanel = paginate(cacheHazardText)
checkEqual(colorOf(cachePanel, "後文"), colorOf(cachePanel, "前文"),
    "同步圖的絕對路徑含顏色字樣時同樣不得改變後續文字顏色")
checkEqual(cachePanel.imageW[1], 100, "同步圖仍必須被畫出來（不是退回占位）")

-- ---------------------------------------------------------------------------
-- 護欄的形狀：前後空白與「只包一層」。
-- ---------------------------------------------------------------------------
-- 護欄自帶的前後空白**在這一層驗不到**，別在這裡加測試：進到預檢的每個圖片 tag
-- 兩邊一定已經有空白——markdown 圖片是 " <NBIMG:n> "，服主手寫的原生 tag 也被 MDParser
-- 正規化成 " <IMAGE:...> "（緊貼寫 "前文<IMAGE:x>後文" 出來的一樣有空白）。
-- 所以「把 IMAGE_GUARD_PREFIX 的開頭空白拿掉」在這支測試裡是恆綠的。
-- 那條合約是 NBCore.imageTagGuarded 的**單元**合約（保護未來沒有 MDParser 擋在前面的呼叫端），
-- 驗在 test_mdparser.lua 的 tightGuarded 那一段（拿掉前／後空白都會紅）。
--
-- 同理，「第一圈補回 if image.width or image.height 守衛」也是恆綠的：第二圈無條件重建
-- 每一個存活的 tag，第一圈算出來的尺寸一定會被它重算一次（冪等）。第一圈的夾限是
-- 縱深防禦、不是唯一來源，黑箱測不出差異——會紅的是第二圈那一半（見上方 D1 區段）。

-- 只能包一層：第一圈**不得**也呼叫 imageTagGuarded，否則第二圈會再包一次。
-- 疊層雖然仍是配對的（畫面看不出來），但每張圖多兩個 token，且往後任一層改動就會失衡。
local function countOccurrences(text, fragment)
    local total = 0
    local position = 1
    while true do
        local from, to = string.find(text, fragment, position, true)
        if not from then
            return total
        end
        total = total + 1
        position = to + 1
    end
end
local singleWrap = preflight("![替代](media/textures/pack/RED_banner.png)")
checkEqual(countOccurrences(singleWrap, "PUSHRGB"), 1, "危險路徑的護欄只能包一層")
checkEqual(countOccurrences(singleWrap, "POPRGB"), 1, "危險路徑的護欄只能包一層")

-- ---------------------------------------------------------------------------
-- F2：NBImageCache 這一端只能用 COMMAND_HAZARDS 判定「快取路徑不可用」。
-- base 來自玩家家目錄，改不動；顏色類字樣在這裡拒絕，等於帳號叫 FRED／ALFREDO／GREENxx
-- 的玩家永遠看不到任何同步圖，而那正是 NBPanel 的護欄處理得了的情形。
-- ---------------------------------------------------------------------------
local documentFolder = "C:/Users/Ann/Documents"
_G.getMyDocumentFolder = function() return documentFolder end
-- 真模組會做 `NBImageCache = NBImageCache or {}`，直接載會把上面那個 stub 表污染掉
-- （NBPanel 已經在載入時抓走 stub 的參考），所以先清掉全域、載完再把 stub 放回去。
local cacheStub = _G.NBImageCache
_G.NBImageCache = nil
_G.LuaEventManager = { AddEvent = function() end }
_G.isClient = function() return true end
_G.isServer = function() return false end
-- 快取檔名帶伺服器命名空間（跨伺服器毒化的修正，見 NBImageCache 的 sanitizeToken）。
_G.getServerIP = function() return "10.0.0.7" end
_G.getServerPort = function() return "16261" end
_G.NBReader = realRequire "NoticeBoard/NBReader"
local RealImageCache = dofile(MEDIA_LUA .. "client/NoticeBoard/NBImageCache.lua")
_G.NBImageCache = cacheStub

local READY_HASH = "abcd1234"
rawset(RealImageCache.state.ready, READY_HASH, true)
local function pathForHome(home)
    documentFolder = home
    -- 真模組內部是用**全域** NBImageCache 找自己（isReady/state），呼叫期間得把全域換過去；
    -- NBPanel 在載入時就把 stub 抓進 local ImageCache（NBPanel.lua:26），不受影響。
    _G.NBImageCache = RealImageCache
    -- cacheBasePath 只算一次就快取起來，逐條重算才驗得到不同的家目錄
    RealImageCache.state.basePathChecked = false
    RealImageCache.state.basePath = nil
    -- 停用時會 print 一行給服主看，測試輸出不需要它
    local realPrint = print
    _G.print = function() end
    local path = RealImageCache.pathForHash(READY_HASH)
    _G.print = realPrint
    _G.NBImageCache = cacheStub
    return path
end

checkEqual(pathForHome("C:/Users/Ann/Documents"),
    "C:/Users/Ann/Documents/Lua/NoticeBoard/cache/10_46_0_46_0_46_7_95_16261_abcd1234.png",
    "乾淨家目錄必須算得出快取路徑（連組出來的路徑一起驗，不能只驗非 nil）")
check(pathForHome("C:/Users/FRED/Documents") ~= nil,
    "顏色類字樣不得讓整個圖片快取停用（護欄在 NBPanel 那端救得回來）")
check(pathForHome("C:/Users/ALFREDO/Documents") ~= nil, "子字串命中的顏色字樣同樣不得停用快取")
checkEqual(pathForHome("C:/Users/A,B/Documents"), nil,
    "逗號必須繼續硬性拒絕（引擎看到逗號就去拆寬高，護欄救不了）")
checkEqual(pathForHome("C:/Users/A<B/Documents"), nil, "< 必須繼續硬性拒絕（tokenizer 邊界）")
checkEqual(pathForHome("C:/Users/SETX:1/Documents"), nil, "帶冒號的指令字樣必須繼續硬性拒絕")

-- ---------------------------------------------------------------------------
-- 圓角皮膚（NBSkin）換皮：**功能零改動、版面零改動、只換視覺**。
-- 三個環境各跑一次同一份 prerender/render：
--   E0 沒有 NinePatchTexture（本 harness 原生狀態）→ 全部退回 drawRect／drawRectBorder；
--   E1 有貼圖（stub 記錄 render 落點，並模擬引擎「第一次 getSharedTexture 回 null」）；
--   E2 貼圖壞掉（永遠 nil）／render 會拋 → 退回、不拋錯、同名不重試。
-- 面板 1190×864 是 NBPanel.defaultSize() 在 1920×1080 stub 下的結果（0.62／0.80 比例）。
-- ---------------------------------------------------------------------------
;(function()
    local panel = NBPanel:new()
    panel:createChildren()

    -- 版面回歸紅線：內容區 ISRichTextPanel 的 rect 與 margins 逐像素等於換皮前的值。
    -- 期望值全是字面數字（tabY 19 + tabHeight 18+6=24 → 43；864-43-14 → 807；捲軸寬 13）。
    checkEqual(panel.width, 1190, "面板預設寬（1920×0.62）")
    checkEqual(panel.height, 864, "面板預設高（1080×0.80）")
    checkEqual(panel.tabY, 19, "頁籤列 y = titleBarHeight")
    checkEqual(panel.tabHeight, 24, "頁籤列高 = 字高 + 6")
    checkEqual(panel.contentY, 43, "內容區 y = tabY + tabHeight")
    checkEqual(panel.richText.x, 0, "richText x 不得改變")
    checkEqual(panel.richText.y, 43, "richText y 不得改變")
    checkEqual(panel.richText.width, 1190, "richText 寬不得改變")
    checkEqual(panel.richText.height, 807, "richText 高不得改變（height - contentY - resizeWidgetHeight）")
    checkEqual(panel.richText.marginLeft, 23, "richText marginLeft（10 + 捲軸 13，與右邊對稱）")
    checkEqual(panel.richText.marginTop, 10, "richText marginTop 不得改變")
    checkEqual(panel.richText.marginRight, 23, "richText marginRight 不得改變（10 + 捲軸 13）")
    -- 置中不變式：ISRichTextPanel 的置中算在 [marginLeft, width-marginRight] 之間
    -- （:649），左右不對稱時 `#` 標題與 <CENTRE> 會偏離視窗中心 (right-left)/2 像素，
    -- 與標題列的 drawTextCentre(title, width/2) 對不齊。這條比對兩個數字，
    -- 比事後從截圖看「有點歪」可靠得多。
    checkEqual(panel.richText.marginLeft, panel.richText.marginRight,
        "richText 左右邊界必須對稱，否則置中的標題會偏")
    checkEqual(panel.richText.marginBottom, 0, "richText marginBottom 不得改變")

    -- 繪製用具：攔這一顆 panel 的 drawRect／drawRectBorder／drawTextureScaled，
    -- 以及 stub NinePatchTexture 的 render 落點。
    panel.x, panel.y = 100, 50
    panel.resizeWidget = { getIsVisible = function() return true end }
    panel.tabs = {
        { id = "a", title = "Alpha", width = 100 },
        { id = "b", title = "Beta", width = 90 },
    }
    panel.selectedIndex = 1
    UNREAD_IDS.b = true

    local rects, borders, scaled, patches = {}, {}, {}, {}
    local function record(list)
        return function(_, x, y, w, h, a, r, g, b)
            list[#list + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
        end
    end
    panel.drawRect = record(rects)
    panel.drawRectBorder = record(borders)
    panel.drawTextureScaled = function(_, texture, x, y, w, h, a, r, g, b)
        scaled[#scaled + 1] = { texture = texture, x = x, y = y, w = w, h = h,
            a = a, r = r, g = g, b = b }
    end
    local function clearDraws()
        rects, borders, scaled, patches = {}, {}, {}, {}
        panel.drawRect = record(rects)
        panel.drawRectBorder = record(borders)
    end
    local function drawFrame()
        panel:prerender()
        panel:render()
    end
    local function findRect(list, x, y, w, h)
        local index
        for index = 1, #list do
            local entry = list[index]
            if entry.x == x and entry.y == y and entry.w == w and entry.h == h then
                return entry
            end
        end
        return nil
    end
    local function describe(entry)
        if not entry then
            return "nil"
        end
        return string.format("(%s,%s,%s,%s) rgba=%s,%s,%s,%s", tostring(entry.x),
            tostring(entry.y), tostring(entry.w), tostring(entry.h), tostring(entry.r),
            tostring(entry.g), tostring(entry.b), tostring(entry.a))
    end
    local function nearly(actual, expected)
        return type(actual) == "number" and math.abs(actual - expected) < 1e-9
    end
    local function makeNinePatchStub(options)
        local shared = {}
        return {
            getSharedTexture = function(path)
                options.calls[path] = (options.calls[path] or 0) + 1
                if options.alwaysNil then
                    return nil
                end
                -- 引擎行為：第一次呼叫載入完直接回 null，第二次才命中快取（NinePatchTexture.java:56-63）
                if options.calls[path] == 1 then
                    return nil
                end
                if not shared[path] then
                    shared[path] = { render = function(_, x, y, w, h, r, g, b, a)
                        if options.throwOnRender then
                            options.renderAttempts = options.renderAttempts + 1
                            error("simulated null texture")
                        end
                        patches[#patches + 1] = { path = path, x = x, y = y, w = w, h = h,
                            r = r, g = g, b = b, a = a }
                    end }
                end
                return shared[path]
            end,
        }
    end

    -- E0：沒有 NinePatchTexture 全域 → 全部走退回，且落點與換皮前的 drawRect 版完全一致
    checkEqual(_G.NinePatchTexture, nil, "harness 原生狀態不該有 NinePatchTexture")
    drawFrame()
    local bgRect = findRect(rects, 0, 0, 1190, 864)
    check(bgRect ~= nil and nearly(bgRect.a, 0.8) and bgRect.r == 0,
        "E0 面板底必須退回 drawRect(0,0,w,h) BG_PANEL：" .. describe(bgRect))
    local titleRect = findRect(rects, 0, 0, 1190, 19)
    check(titleRect ~= nil and nearly(titleRect.a, 0.10) and titleRect.r == 1,
        "E0 標題列疊色必須退回 drawRect(0,0,w,th) TITLEBAR_FILL：" .. describe(titleRect))
    check(findRect(rects, 0, 18, 1190, 1) ~= nil, "標題列下緣 1px 分隔線 (0, th-1, w, 1)")
    check(findRect(rects, 0, 19, 1190, 24) ~= nil, "頁籤列底 (0, tabY, w, tabHeight)")
    check(findRect(rects, 0, 42, panel:tabAreaWidth(), 1) ~= nil,
        "頁籤軌道線 (0, tabY+tabHeight-1, tabAreaWidth, 1)")
    local tabFill = findRect(rects, 0, 19, 100, 24)
    check(tabFill ~= nil and nearly(tabFill.a, 0.12), "E0 選中頁籤填色退回 drawRect：" .. describe(tabFill))
    check(findRect(rects, 0, 41, 100, 2) ~= nil, "選中頁籤 2px 琥珀底線 (x, tabY+tabHeight-2, w, 2)")
    check(findRect(borders, 0, 19, 100, 24) ~= nil and findRect(borders, 100, 19, 90, 24) ~= nil,
        "E0 兩個頁籤框都退回 drawRectBorder")
    local dotRect = findRect(rects, 180, 21, 8, 8)
    check(dotRect ~= nil and findRect(borders, 180, 21, 8, 8) ~= nil,
        "E0 未讀點退回方點：(right-10, tabY+2, 8, 8) 填色＋描邊：" .. describe(dotRect))
    check(findRect(rects, 0, 850, 1190, 1) ~= nil, "resize 列上緣 1px 分隔線 (0, height-rh, w, 1)")
    check(#scaled == 1 and scaled[1].x == 1177 and scaled[1].y == 851
        and scaled[1].w == 10 and scaled[1].h == 10,
        "resize 把手圖示：原位 (w-rh+1, height-rh+1)、邊長 rh-4（留在分隔線下方、直角在弧線內）")
    local frameBorder = findRect(borders, 0, 0, 1190, 864)
    check(frameBorder ~= nil and nearly(frameBorder.a, 1) and nearly(frameBorder.r, 0.4),
        "E0 面板外框退回 drawRectBorder(0,0,w,H) BORDER：" .. describe(frameBorder))
    checkEqual(#patches, 0, "E0 不可能有 9-slice 落點")

    -- stencil 收支：UIElement.stencilLevel 是 static、只在 UIManager.render 開頭歸零
    -- （UIManager.java:274），元素之間不重設。set 與 clear 必須成對，巢狀的頁籤區用
    -- repaintStencilRect 還回父層（UIElement.java:1928-1940；原版 ISRichTextPanel.lua:688-690）；
    -- 若像過去那樣 clear 後再 set 一次，每幀淨 +1，render 的 clear 回不到 0 → 外框畫不出來、
    -- 同幀之後的 alwaysOnTop 元件（浮窗／Toast）整個被 stencil 擋掉。
    do
        panel.clearStentil = true -- ISCollapsableWindow:new / ISCollapsableWindowJoypad:new:43 在引擎裡恆為 true
        local level, maxLevel, repaints = 0, 0, {}
        panel.setStencilRect = function(_, x, y, w, h)
            level = level + 1
            if level > maxLevel then maxLevel = level end
        end
        panel.clearStencilRect = function()
            check(level > 0, "clearStencilRect 不得在 level 0 呼叫（會 glClear 整個 stencil）")
            level = level - 1
        end
        panel.repaintStencilRect = function(_, x, y, w, h)
            repaints[#repaints + 1] = { x = x, y = y, w = w, h = h, level = level }
        end
        drawFrame()
        checkEqual(level, 0, "一幀畫完 stencilLevel 必須回到 0（set/clear 成對）")
        checkEqual(maxLevel, 2, "頁籤區是面板 stencil 之下的一層巢狀（最深 2）")
        checkEqual(#repaints, 1, "頁籤區 clear 後 repaint 一次還回父層")
        check(repaints[1].x == 0 and repaints[1].y == 19 and repaints[1].w == panel:tabAreaWidth()
            and repaints[1].h == 24 and repaints[1].level == 1,
            "repaint 的 rect 就是頁籤區 (0, tabY, tabAreaWidth, tabHeight)，且在父層 level 1 執行")
        panel.setStencilRect, panel.clearStencilRect, panel.repaintStencilRect = nil, nil, nil
        clearDraws()
    end

    -- E1：有貼圖。落點是絕對座標（panel.x/y = 100/50），尺寸與退回版一模一樣。
    local good = { calls = {} }
    _G.NinePatchTexture = makeNinePatchStub(good)
    TEXTURE_SIZES["media/ui/MinidoracatUI/mui_dot.png"] = { 16, 16 }
    NBSkin.reset()
    clearDraws()
    drawFrame()
    local function findPatch(path, x, y, w, h)
        local index
        for index = 1, #patches do
            local entry = patches[index]
            if entry.path == "media/ui/MinidoracatUI/" .. path and entry.x == x
                and entry.y == y and entry.w == w and entry.h == h then
                return entry
            end
        end
        return nil
    end
    local bgPatch = findPatch("mui_round_fill.png", 100, 50, 1190, 864)
    check(bgPatch ~= nil and nearly(bgPatch.a, 0.8) and bgPatch.r == 0,
        "E1 面板底 mui_round_fill 落在絕對座標 (100,50,1190,864) 染 BG_PANEL")
    local titlePatch = findPatch("mui_roundtop_fill.png", 100, 50, 1190, 19)
    check(titlePatch ~= nil and nearly(titlePatch.a, 0.10) and titlePatch.r == 1,
        "E1 標題列 mui_roundtop_fill (100,50,1190,19) 染 TITLEBAR_FILL")
    local tabPatch = findPatch("mui_roundtop_fill.png", 100, 69, 100, 24)
    check(tabPatch ~= nil and nearly(tabPatch.a, 0.12),
        "E1 選中頁籤 mui_roundtop_fill (100,69,100,24) 染 TAB_SELECTED_FILL")
    check(findPatch("mui_roundtop_border.png", 100, 69, 100, 24) ~= nil
        and findPatch("mui_roundtop_border.png", 200, 69, 90, 24) ~= nil,
        "E1 兩個頁籤框 mui_roundtop_border（3 邊框）")
    local framePatch = findPatch("mui_round_border.png", 100, 50, 1190, 864)
    check(framePatch ~= nil and nearly(framePatch.a, 1) and nearly(framePatch.r, 0.4),
        "E1 面板外框 mui_round_border (100,50,1190,864) 染 BORDER")
    checkEqual(#patches, 6, "E1 一幀恰好 6 次 9-slice：底、標題、選中頁籤、2 頁籤框、外框")
    check(findRect(rects, 0, 0, 1190, 864) == nil and findRect(rects, 0, 0, 1190, 19) == nil
        and findRect(borders, 0, 0, 1190, 864) == nil,
        "E1 走了 9-slice 就不得再畫直角底／標題／外框（會疊成雙倍 alpha）")
    check(findRect(rects, 0, 42, panel:tabAreaWidth(), 1) ~= nil
        and findRect(rects, 0, 41, 100, 2) ~= nil and findRect(rects, 0, 850, 1190, 1) ~= nil,
        "E1 軌道線／底線／resize 分隔線仍是 drawRect")
    -- 未讀圓點：光暈（描邊色、放大一圈）先畫，主點後畫
    checkEqual(#scaled, 3, "E1 drawTextureScaled = resize 把手 + 光暈 + 主點")
    check(scaled[1].x == 179 and scaled[1].y == 20 and scaled[1].w == 10 and scaled[1].h == 10
        and nearly(scaled[1].a, 0.6) and scaled[1].r == 0,
        "E1 光暈 (x-1, y-1, 10, 10) 染 UNREAD_DOT_OUTLINE")
    check(scaled[2].x == 180 and scaled[2].y == 21 and scaled[2].w == 8 and scaled[2].h == 8
        and nearly(scaled[2].r, 0.85) and nearly(scaled[2].a, 1),
        "E1 主點 (right-10, tabY+2, 8, 8) 染 UNREAD_DOT")
    check(scaled[1].texture == scaled[2].texture and scaled[1].texture ~= nil,
        "E1 光暈與主點用同一張 mui_dot.png")
    -- 首呼叫回 null 的引擎行為：每張貼圖恰好呼叫兩次；第二幀不再呼叫（已快取）
    local roundFillCalls = good.calls["media/ui/MinidoracatUI/mui_round_fill.png"]
    checkEqual(roundFillCalls, 2, "E1 getSharedTexture 連呼兩次繞過首呼叫回 null")
    clearDraws()
    drawFrame()
    checkEqual(good.calls["media/ui/MinidoracatUI/mui_round_fill.png"], 2,
        "E1 第二幀不得再呼叫 getSharedTexture（框架 Skin 已快取）")
    checkEqual(#patches, 6, "E1 第二幀仍是 6 次 9-slice")

    -- 收合（釘選解除後滑鼠離開 ISCollapsableWindow.lua:237-244，或 layout.ini pin=false）：
    -- 面板只剩標題列一條。原版靠 drawRect／drawTextCentre 的 isCollapsed 守衛
    -- （ISUIElement.lua:1191-1197,:1280-1284）不畫內容；9-slice 沒有那道守衛，NBPanel 要自己跳過：
    -- 標題疊色改四角圓（下兩角不從面板底弧線外露出）、不畫分隔線、不畫頁籤／占位／resize 列。
    panel.isCollapsed = true
    panel.contentState = "error"
    clearDraws()
    drawFrame()
    check(findPatch("mui_round_fill.png", 100, 50, 1190, 19) ~= nil,
        "收合：面板底 mui_round_fill 只畫標題列高 (100,50,1190,19)")
    local collapsedTitleCount = 0
    local collapsedIndex
    for collapsedIndex = 1, #patches do
        local entry = patches[collapsedIndex]
        if entry.path == "media/ui/MinidoracatUI/mui_round_fill.png" and entry.h == 19
            and nearly(entry.a, 0.10) then
            collapsedTitleCount = collapsedTitleCount + 1
        end
        check(entry.path ~= "media/ui/MinidoracatUI/mui_roundtop_fill.png"
            and entry.path ~= "media/ui/MinidoracatUI/mui_roundtop_border.png",
            "收合：不得有任何上圓下直貼圖（標題疊色改四角圓、頁籤不畫）：" .. entry.path)
        check(entry.y == 50 and entry.h == 19, "收合：所有 9-slice 都只落在標題列 (y=50,h=19)："
            .. entry.path .. " y=" .. tostring(entry.y) .. " h=" .. tostring(entry.h))
    end
    checkEqual(collapsedTitleCount, 1, "收合：標題疊色 TITLEBAR_FILL 改走四角圓 mui_round_fill 一次")
    check(findPatch("mui_round_border.png", 100, 50, 1190, 19) ~= nil, "收合：外框 mui_round_border (100,50,1190,19)")
    checkEqual(#patches, 3, "收合：一幀恰好 3 次 9-slice（底、標題疊色、外框），頁籤／錯誤區塊不畫")
    checkEqual(#rects, 0, "收合：不畫分隔線／頁籤列底／軌道線／resize 線（drawRect 0 次）")
    checkEqual(#borders, 0, "收合：不畫任何 drawRectBorder")
    checkEqual(#scaled, 0, "收合：不畫 resize 把手與未讀點")
    panel.isCollapsed = false
    panel.contentState = "syncing"
    clearDraws()

    -- E2a：貼圖永遠 nil（路徑打錯／進黑名單）→ 退回、不拋錯、每張只試兩次、之後不重試
    local bad = { calls = {}, alwaysNil = true }
    _G.NinePatchTexture = makeNinePatchStub(bad)
    NBSkin.reset()
    clearDraws()
    drawFrame()
    checkEqual(#patches, 0, "E2a 貼圖 nil 時不得有 9-slice 落點")
    check(findRect(rects, 0, 0, 1190, 864) ~= nil and findRect(borders, 0, 0, 1190, 864) ~= nil,
        "E2a 貼圖 nil 時面板底／外框退回 drawRect／drawRectBorder")
    local badTotal = 0
    local badPath
    for badPath in pairs(bad.calls) do
        badTotal = badTotal + bad.calls[badPath]
        checkEqual(bad.calls[badPath], 2, "E2a 每張壞貼圖恰好呼叫兩次：" .. badPath)
    end
    checkEqual(badTotal, 8, "E2a 一幀碰到 4 張貼圖 × 2 次")
    clearDraws()
    drawFrame()
    local badTotalAfter = 0
    for badPath in pairs(bad.calls) do
        badTotalAfter = badTotalAfter + bad.calls[badPath]
    end
    checkEqual(badTotalAfter, 8, "E2a 第二幀不得重試同名壞貼圖")

    -- E2b：getSharedTexture 給了物件但 render 會拋（PNG 解碼失敗 → texture 為 null）
    local broken = { calls = {}, throwOnRender = true, renderAttempts = 0 }
    _G.NinePatchTexture = makeNinePatchStub(broken)
    NBSkin.reset()
    clearDraws()
    local okFrame = pcall(drawFrame)
    check(okFrame, "E2b render 拋錯不得外洩到 prerender/render")
    checkEqual(broken.renderAttempts, 4, "E2b 4 張貼圖各只嘗試 render 一次就標為壞")
    check(findRect(rects, 0, 0, 1190, 864) ~= nil and findRect(borders, 0, 0, 1190, 864) ~= nil,
        "E2b render 拋錯的同一幀就退回 drawRect／drawRectBorder")
    clearDraws()
    drawFrame()
    checkEqual(broken.renderAttempts, 4, "E2b 第二幀不再嘗試 render 壞掉的貼圖")

    -- 浮窗與 Toast：同一份 NBSkin，落點驗絕對座標與 floor
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBFloatButton.lua")
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBToast.lua")
    _G.NinePatchTexture = makeNinePatchStub({ calls = {} })
    NBSkin.reset()
    patches = {}
    local button = NBFloatButton:new(10, 20)
    button.unread = true
    local buttonScaled = {}
    button.drawTextureScaled = function(_, texture, x, y, w, h, a, r, g, b)
        buttonScaled[#buttonScaled + 1] = { x = x, y = y, w = w, h = h, a = a, r = r }
    end
    button:prerender()
    checkEqual(#patches, 2, "浮窗一幀 = 底 + 框（沒 hover）")
    check(patches[1].path == "media/ui/MinidoracatUI/mui_round_fill.png" and patches[1].x == 10
        and patches[1].y == 20 and patches[1].w == 40 and patches[1].h == 40 and nearly(patches[1].a, 0.8),
        "浮窗底 mui_round_fill (10,20,40,40) BG_PANEL")
    check(patches[2].path == "media/ui/MinidoracatUI/mui_round_border.png" and patches[2].x == 10
        and patches[2].y == 20 and patches[2].w == 40 and patches[2].h == 40,
        "浮窗框 mui_round_border (10,20,40,40)")
    check(#buttonScaled == 2 and buttonScaled[1].x == 31 and buttonScaled[1].y == -3
        and buttonScaled[1].w == 10 and buttonScaled[2].x == 32 and buttonScaled[2].y == -2
        and buttonScaled[2].w == 8,
        "浮窗未讀點掛角位置不變 (w-8, -2, 8)：光暈 (31,-3,10) 主點 (32,-2,8)")

    patches = {}
    local toast = NBToast:new("hello")
    NBToast.active = { toast }
    -- 進場第 100ms（ENTER 250ms）：x = 2220 + (1604-2220)*0.4 = 1973.6，alpha 0.4
    _G.getTimestampMs = function() return 100 end
    toast:prerender()
    _G.getTimestampMs = function() return 0 end
    NBToast.active = {}
    checkEqual(#patches, 2, "Toast 一幀 = 底 + 框")
    check(patches[1].path == "media/ui/MinidoracatUI/mui_round_fill.png" and patches[1].x == 1973
        and patches[1].y == 60 and patches[1].w == 300 and patches[1].h == 56,
        "Toast 動畫中的小數 x 必須 floor 後才交給 NinePatchTexture（1973.6 → 1973）")
    check(nearly(patches[1].a, 0.85 * 0.4) and nearly(patches[2].a, 0.9 * 0.4),
        "Toast 底／框的 alpha 要乘上動畫 alpha")
    check(patches[2].path == "media/ui/MinidoracatUI/mui_round_border.png" and patches[2].x == 1973
        and nearly(patches[2].r, 1) and nearly(patches[2].g, 0.85),
        "Toast 框 mui_round_border 染 TOAST_BORDER（琥珀）")

    _G.NinePatchTexture = nil
    NBSkin.reset()
end)()

-- ---------------------------------------------------------------------------
-- 框架缺席退回（adapter 的 FW == nil 分支）：ARCHITECTURE 三層防線的第 3 層。
-- 在 MinidoracatUI 暫時拔掉的環境下**重新載入** NBSkin，驗 adapter 自己的直角／
-- 方點退回真的會畫、fits 恆 false、且絕不 error——這 30 行退回碼是 adapter 模式
-- 存在的理由，不能只有註解在保證。驗完還原正常綁定供後續段落使用。
-- ---------------------------------------------------------------------------
;(function()
    local savedUI = MinidoracatUI
    local function nearly(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end
    MinidoracatUI = nil
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBSkin.lua") -- FW 綁定重算：此環境下為 nil
    local el = { rects = {}, borders = {} }
    el.drawRect = function(_, x, y, w, h, a, r, g, b)
        el.rects[#el.rects + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
    end
    el.drawRectBorder = function(_, x, y, w, h, a, r, g, b)
        el.borders[#el.borders + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
    end
    local okAll = pcall(function()
        NBSkin.fill(el, 1, 2, 300, 50, NBSkin.COLORS.BG_PANEL, false, 0.5)
        NBSkin.border(el, 1, 2, 300, 50, NBSkin.COLORS.BORDER)
        NBSkin.dot(el, 5, 5, 8, NBSkin.COLORS.UNREAD_DOT, NBSkin.COLORS.UNREAD_DOT_OUTLINE)
        NBSkin.reset() -- FW nil 時 reset 也不得炸
    end)
    check(okAll, "框架缺席：fill/border/dot/reset 全程不炸")
    check(#el.rects == 2 and #el.borders == 2,
        "框架缺席：fill→drawRect、border→drawRectBorder、dot→方點＋描邊")
    check(el.rects[1].x == 1 and el.rects[1].w == 300 and nearly(el.rects[1].a, 0.8 * 0.5),
        "框架缺席：退回矩形用相對座標且 alphaScale 有效")
    check(NBSkin.fits(500, 500, false) == false, "框架缺席：fits 恆 false（無貼圖可畫）")
    MinidoracatUI = savedUI
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBSkin.lua") -- 還原：FW 重綁框架
    check(NBSkin.fits(12, 12, false) == true, "還原後 fits 恢復框架夾限（重綁成功哨兵）")
    NBSkin.reset()
end)()

-- ---------------------------------------------------------------------------
-- 新公告提示音：**一批一聲**（不是一則一聲），且沙盒關掉就完全不響。
-- 直接跑 NBPanel.notifyUnread（測試閘，見該行註解）：從 handleContentReady 那端跑要把
-- 整個進場流程 stub 起來，測到的會是 stub 而不是這裡的收斂邏輯。
-- ---------------------------------------------------------------------------
;(function()
    local sounds, toasts, volumes = {}, {}, {}
    _G.getSoundManager = function()
        return {
            playUISound = function(_, name) sounds[#sounds + 1] = name; return 4242 end,
            getUIEmitter = function()
                return { setVolume = function(_, ref, volume)
                    volumes[#volumes + 1] = { ref = ref, volume = volume }
                end }
            end,
        }
    end
    local realToastShow = NBToast.show
    NBToast.show = function(message) toasts[#toasts + 1] = message end

    local snapshot = { files = {
        { id = "a.md", title = "A", h = "1111" },
        { id = "b.md", title = "B", h = "2222" },
        { id = "c.md", title = "C", h = "3333" },
    } }
    UNREAD_IDS = {}
    -- 這個 harness 的 NBClient.isUnread 綁在建立時的 UNREAD_IDS 表上，重新指派全域不會生效，
    -- 所以改內容而不是換表（下面每段都清乾淨再填）。
    local unread = _G.NBClient.isUnread
    local unreadSet = {}
    _G.NBClient.isUnread = function(fileId) return unreadSet[fileId] == true end

    unreadSet["a.md"], unreadSet["b.md"], unreadSet["c.md"] = true, true, true
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#toasts, 3, "三則未讀公告要各跳一則 toast")
    checkEqual(#sounds, 1, "同一批通知只播一次提示音（不是每則一次）")
    checkEqual(sounds[1], "MinidoracatNBNotify",
        "提示音必須是 MOD 自帶的音檔名（media/sound/<name>.wav，見 NBPanel 的 NOTIFY_SOUND）")

    sounds, toasts = {}, {}
    NBPanel.notifyUnread(snapshot, { ["b.md"] = true })
    checkEqual(#toasts, 1, "只有內容變更的那一則跳 toast")
    checkEqual(#sounds, 1, "變更一則也只有一聲")

    sounds, toasts = {}, {}
    unreadSet["a.md"], unreadSet["b.md"], unreadSet["c.md"] = nil, nil, nil
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#toasts, 0, "全部已讀時不跳 toast")
    checkEqual(#sounds, 0, "沒有 toast 就不該有聲音")

    sounds, toasts = {}, {}
    unreadSet["a.md"] = true
    _G.SandboxVars = { MinidoracatNB = { NotifySound = false } }
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#toasts, 1, "關掉提示音不影響 toast")
    checkEqual(#sounds, 0, "沙盒 NotifySound = false 時完全不播")

    _G.SandboxVars = { MinidoracatNB = {} }
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#sounds, 1, "沒設定 NotifySound 時預設要播（缺值＝預設行為）")

    -- 玩家端音量（NBOptions）：滿音量不呼叫 setVolume（少一次 Java 呼叫）、
    -- 中間值要把 playUISound 回傳的 ref 與 0..1 音量原樣交給 UI emitter、
    -- 0 代表關閉（連 playUISound 都不該呼叫）。
    sounds, toasts, volumes = {}, {}, {}
    SOUND_VOLUME.value = 1
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#sounds, 1, "滿音量仍要播")
    checkEqual(#volumes, 0, "滿音量不必呼叫 setVolume")

    sounds, toasts, volumes = {}, {}, {}
    SOUND_VOLUME.value = 0.45
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#sounds, 1, "中間音量要播")
    checkEqual(#volumes, 1, "中間音量必須套用一次 setVolume")
    checkEqual(volumes[1].ref, 4242, "setVolume 要用 playUISound 回傳的 instance ref")
    checkEqual(volumes[1].volume, 0.45, "音量要原樣傳給 UI emitter（0..1）")

    sounds, toasts, volumes = {}, {}, {}
    SOUND_VOLUME.value = 0
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#toasts, 1, "音量 0 不影響 toast")
    checkEqual(#sounds, 0, "音量 0（或玩家關閉）連 playUISound 都不該呼叫")
    SOUND_VOLUME.value = 1

    -- 音效系統整個壞掉（getSoundManager 拋錯）不得讓通知跟著失敗。
    sounds, toasts = {}, {}
    _G.getSoundManager = function() error("no sound device") end
    _G.SandboxVars = {}
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#toasts, 1, "音效拋錯時 toast 仍要照跳")

    _G.NBClient.isUnread = unread
    NBToast.show = realToastShow
    _G.getSoundManager = nil
    _G.SandboxVars = {}
end)()

-- 條數本身也是斷言：整段測試被 `if false then` 包掉或誤刪時，印出來的數字會變小，
-- 但沒有任何東西會紅。加測試時把這個數字一起改大（改小要說得出刪了什麼）。
local EXPECTED_ASSERTIONS = 178
assert(assertionCount == EXPECTED_ASSERTIONS,
    "斷言條數不符：預期 " .. EXPECTED_ASSERTIONS .. "、實際 " .. assertionCount
        .. "（有測試被刪掉或跳過？）")

print("Step 2 tests passed: " .. assertionCount .. " assertions")
