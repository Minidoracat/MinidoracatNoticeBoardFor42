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
local LISTBOX_FILE = VANILLA_LUA .. "/client/ISUI/ISScrollingListBox.lua"

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
local SCREEN_WIDTH = 1920
local SCREEN_HEIGHT = 1080
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
        -- 原版 ISLayoutManager 每個函式開頭都問 game mode（Tutorial 一律早退，
        -- 連 ini 都不讀）：回 Sandbox 才驗得到真正的讀寫路徑。
        getGameMode = function() return "Sandbox" end,
        getScreenWidth = function() return SCREEN_WIDTH end,
        getScreenHeight = function() return SCREEN_HEIGHT end,
        getOptionDoVideoEffects = function() return false end,
    }
end
_G.Core = { getInstance = function()
    return { getOptionDoVideoEffects = function() return false end }
end }
_G.getKeyName = function() return "K" end
_G.getMouseX = function() return 0 end
_G.getMouseY = function() return 0 end

local TEXTURE_SIZES = {}
_G.getTexture = function(path)
    local size = TEXTURE_SIZES[path]
    if not size then
        return nil
    end
    -- path 只給測試用：圖示是「一堆長得一樣的白色貼圖」，繪製呼叫裡沒有它就分不出
    -- 畫的是 chevron 還是 folder。引擎的 Texture 沒有這個欄位，實作端不得依賴它。
    return {
        path = path,
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
-- 父層改寬時就地重排子層：只錨右的子層與右緣保持固定距離（原生在 Java 端做，
-- UIElement.resizeChildren）。這件事不能留成 no-op：工具列的動態 minimumWidth 會在
-- createChildren 當下把面板夾寬，右側按鈕的 x 若不跟著走，「左右兩組不得重疊」
-- 這類斷言就變成拿脫節的座標在比，永遠是綠的。
function Base:setWidth(width)
    local delta = width - (self.width or width)
    self.width = width
    local children = self.children
    if delta == 0 or children == nil then
        return
    end
    local index
    for index = 1, #children do
        local child = children[index]
        if child.anchorRight and not child.anchorLeft then
            child:setX(child:getX() + delta)
        end
    end
end
function Base:setScrollHeight(height) self.scrollHeight = height end
function Base:getScrollHeight() return self.scrollHeight or 0 end
function Base:noBackground() self.background = false end
-- 真實 listbox 是否需要 vscroll 的最小行為：有 vscroll 且 scrollHeight 超過 viewport。
function Base:isVScrollBarVisible()
    return self.vscroll ~= nil and self:getScrollHeight() > self.height
end
function Base:getYScroll() return 0 end
function Base:getXScroll() return 0 end
function Base:setYScroll() end
function Base:getHeight() return self.height end
function Base:getWidth() return self.width end
function Base:getX() return self.x end
function Base:setX(x) self.x = x end
function Base:setY(y) self.y = y end
function Base:getY() return self.y end
-- 頂層視窗（NBPanel／NBFloatButton／NBToast 都直接掛在 UIManager 上）：絕對座標 = 自身座標
function Base:getAbsoluteX() return self.x end
function Base:getAbsoluteY() return self.y end
function Base:getMouseX() return 0 end
function Base:getMouseY() return 0 end
function Base:isMouseOver() return false end
function Base:getIsVisible() return true end
function Base:addChild(child)
    if child == nil then
        return
    end
    self.children = self.children or {}
    self.children[#self.children + 1] = child
end
function Base:addScrollBars() end
function Base:setAnchorsTBLR(top, bottom, left, right)
    self.anchorTop, self.anchorBottom = top, bottom
    self.anchorLeft, self.anchorRight = left, right
end
function Base:setFont() end
function Base:setStencilRect() end
function Base:clearStencilRect() end
function Base:repaintStencilRect() end
function Base:drawText() end
function Base:drawTextCentre() end
function Base:drawTextRight() end
function Base:drawTextureScaled() end
function Base:recalcSize() end
function Base:drawRect() end
function Base:drawRectBorder() end
function Base:setVisible() end
function Base:updateScrollbars() end
-- 框架 widget（FloatButton/Toast）所需的最小補充面
function Base:setCapture(v) self.captured = v end
function Base:bringToTop() end
function Base:addToUIManager() end
function Base:removeFromUIManager() end
_G.ISPanel = Base
_G.ISBaseObject = Base
_G.ISUIElement = Base
function Base:render() end
function Base:prerender() end
function Base:update() end
-- ISScrollingListBox 與 ISRichTextPanel 同樣**載原版**（不移植、不重寫）：文件樹側欄的
-- addItem／clear／rowAt／ensureVisible／捲動高度全部靠它，自己寫一份模擬器等於讓模擬器
-- 與實作一起錯時兩邊都看不出來。它 derive 自 ISPanelJoypad，本 harness 把那一層當 Base。
_G.ISPanelJoypad = Base:derive("ISPanelJoypad")

dofile(ENGINE_FILE)
dofile(LISTBOX_FILE)
dofile(VANILLA_LUA .. "/client/RadioCom/ISUIRadio/ISSliderPanel.lua")

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
local READ_MARKS = {}
-- 側欄收合偏好：harness 端當成一顆可讀寫的記憶體格子（真模組寫 settings.ini）。
local SIDEBAR_PREFERENCE = { value = nil, writes = 0, allow = true }
local VOICE_PREFERENCE = { value = "chime" }
-- 範例重建請求：harness 端記次數與**選到的語系**，並可切成「送不出去」，
-- 驗面板的兩條送出 toast 分支與「選單選了哪個語系就送哪個」。
local EXAMPLE_REQUESTS = { count = 0, allow = true, langs = {} }
_G.NBClient = { CONTENT_READY_EVENT = "e1", UNREAD_CHANGED_EVENT = "e2",
    LANGUAGE_STATUS_EVENT = "e3",
    isUnread = function(fileId) return UNREAD_IDS[fileId] == true end,
    markRead = function(fileId)
        READ_MARKS[#READ_MARKS + 1] = fileId
        UNREAD_IDS[fileId] = nil
        return true
    end,
    getVoiceLanguagePreference = function() return VOICE_PREFERENCE.value end,
    setVoiceLanguagePreference = function(value)
        VOICE_PREFERENCE.value = value
        return true
    end,
    getSidebarCollapsedPreference = function() return SIDEBAR_PREFERENCE.value end,
    setSidebarCollapsedPreference = function(collapsed)
        SIDEBAR_PREFERENCE.writes = SIDEBAR_PREFERENCE.writes + 1
        if not SIDEBAR_PREFERENCE.allow then
            return false
        end
        SIDEBAR_PREFERENCE.value = collapsed
        return true
    end,
    getUnreadIds = function() return {} end,
    EXAMPLES_STATUS_EVENT = "e5",
    requestExamplePack = function(language)
        EXAMPLE_REQUESTS.count = EXAMPLE_REQUESTS.count + 1
        EXAMPLE_REQUESTS.langs[#EXAMPLE_REQUESTS.langs + 1] = language
        return EXAMPLE_REQUESTS.allow
    end }
_G.NBToast = { show = function() end }
-- 玩家端音效設定（真模組會去讀 PZAPI.ModOptions／ModOptions.ini，harness 沒有那一套）。
-- 音量預設 1 = 滿音量，這樣「不呼叫 setVolume」是可斷言的行為；下面音效那段會改它。
local SOUND_VOLUME = { value = 1, saves = 0 }
_G.NBOptions = {
    soundVolume = function() return SOUND_VOLUME.value end,
    volumePercent = function() return SOUND_VOLUME.value * 100 end,
    setVolumePercent = function(value, persist)
        SOUND_VOLUME.value = value / 100
        if persist then SOUND_VOLUME.saves = SOUND_VOLUME.saves + 1 end
        return true
    end,
}
_G.ISCollapsableWindowJoypad = Base:derive("ISCollapsableWindowJoypad")
-- 版面常數（原生公式 ISCollapsableWindow.lua:298-303 代入本 harness 的假字高 18）：
-- titleBarHeight = max(16, 18+1) = 19；resizeWidgetHeight = (18+6)/2 + 2 = 14。
-- 下方版面測試的期望值就是用這兩個數字手算出來的字面值。
function ISCollapsableWindowJoypad:titleBarHeight() return 19 end
function ISCollapsableWindowJoypad:resizeWidgetHeight() return 14 end
-- ISButton 的建構參數比 Base:new 多三個（title／target／onclick）。工具列按鈕的
-- 「標題取自哪個翻譯鍵、按下去呼叫誰」是可觀察契約：Base:new 把它們丟掉的話，
-- 把某顆按鈕接到錯的 callback（貼上時很容易發生）測試完全看不出來。
_G.ISButton = Base:derive("ISButton")
function ISButton:new(x, y, width, height, title, target, onclick)
    local instance = Base.new(self, x, y, width, height)
    instance.title = title
    instance.target = target
    instance.onclick = onclick
    return instance
end
-- 原生 context menu。語系選單與重建範例選單都靠它，而「按下按鈕之後開出哪些選項、
-- 選項接到誰、帶什麼參數」是那兩顆按鈕唯一的可觀察契約：ISContextMenu.get 在原生端
-- 是可以回 nil 的（沒有這位玩家的 UI），所以 allow=false 那條路徑也必須驗。
local CONTEXT_MENUS = { list = {}, allow = true }
_G.ISContextMenu = Base:derive("ISContextMenu")
function ISContextMenu.get(playerIndex, x, y)
    if not CONTEXT_MENUS.allow then
        return nil
    end
    local menu = { playerIndex = playerIndex, x = x, y = y, options = {} }
    menu.addOption = function(_, title, target, callback, param)
        local option = {
            title = title,
            target = target,
            callback = callback,
            param = param,
        }
        menu.options[#menu.options + 1] = option
        return option
    end
    menu.setOptionChecked = function(_, option, checked)
        option.checked = checked
    end
    CONTEXT_MENUS.list[#CONTEXT_MENUS.list + 1] = menu
    return menu
end
_G.Events = setmetatable({}, { __index = function(events, key)
    -- handlers 只給測試用：「面板把哪個函式掛到哪個事件上」是按鈕按下去之後有沒有人接的
    -- 唯一契約，Add 什麼都不記就驗不到漏註冊（事件本身在 harness 裡不會真的觸發）。
    local event = { handlers = {} }
    event.Add = function(handler)
        event.handlers[#event.handlers + 1] = handler
    end
    event.Remove = function(handler)
        local index
        for index = 1, #event.handlers do
            if event.handlers[index] == handler then
                table.remove(event.handlers, index)
                return
            end
        end
    end
    rawset(events, key, event)
    return event
end })

-- ISLayoutManager 走**原版**，不 stub RegisterWindow：舊版把 RestoreLayout/SaveLayout
-- 掛在框架實例上，而原版呼叫的是 funcs.X(target, name, layout)
-- （ISLayoutManager.lua:99-113）——掛錯位置的回呼永遠不會被呼叫，浮鈕位置每次開遊戲
-- 都跳回預設；stub 掉 RegisterWindow 的測試對這種錯是全綠的。
-- layout.ini 用一顆記憶體字串頂替 getFileReader/getFileWriter：序列化格式本身也一起
-- 驗到（往返真的經過文字），而且絕不碰玩家真正的設定檔。
local LAYOUT_INI = { text = "" }
_G.getFileReader = function(name)
    if name ~= "layout.ini" then
        return nil
    end
    local text = LAYOUT_INI.text
    if text ~= "" and text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    return {
        readLine = string.gmatch(text, "(.-)\r?\n"),
        close = function() end,
    }
end
_G.getFileWriter = function(name, _, append)
    if name ~= "layout.ini" then
        return nil
    end
    if not append then
        LAYOUT_INI.text = ""
    end
    return {
        write = function(_, text) LAYOUT_INI.text = LAYOUT_INI.text .. text end,
        close = function() end,
    }
end
_G.luautils = { stringStarts = function(text, prefix)
    return string.sub(text, 1, string.len(prefix)) == prefix
end }
dofile(VANILLA_LUA .. "/client/ISUI/ISLayoutManager.lua")
do
    -- Model visible toolbar labels, not long translation keys that inflate minimumWidth.
    local toolbarLabels = {
        IGUI_MinidoracatNB_Reload = "Reload",
        IGUI_MinidoracatNB_Examples = "Rebuild examples",
        IGUI_MinidoracatNB_ResetSize = "Reset size",
        IGUI_MinidoracatNB_Language = "Language",
        IGUI_MinidoracatNB_VoiceLanguage = "Voice",
        IGUI_MinidoracatNB_Volume = "Volume",
        IGUI_MinidoracatNB_Sidebar = "Contents",
        IGUI_MinidoracatNB_ExpandAll = "Expand all",
        IGUI_MinidoracatNB_CollapseAll = "Collapse all",
    }
    _G.getText = function(key) return toolbarLabels[key] or "[" .. tostring(key) .. "]" end
end
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

-- 事件註冊必須在**第一次**載入之後立刻驗：下面的圖示段會為了重算 Icons 綁定再 dofile
-- 一次 NBPanel.lua，那會把 NBPanel.onExamplesStatus 換成新的 closure，而註冊表裡留著的
-- 是第一次載入的那一個（_eventsInstalled 讓註冊只跑一次），比對就會誤判成沒註冊。
;(function()
    local function registeredOn(eventName, handler)
        local handlers = Events[eventName].handlers
        local index
        for index = 1, #handlers do
            if handlers[index] == handler then
                return true
            end
        end
        return false
    end
    check(registeredOn(NBClient.EXAMPLES_STATUS_EVENT, NBPanel.onExamplesStatus),
        "面板必須把 onExamplesStatus 掛上 NBClient.EXAMPLES_STATUS_EVENT，"
            .. "否則 server 的範例包結果永遠沒人接")
    check(registeredOn(NBClient.CONTENT_READY_EVENT, NBPanel.onContentReady),
        "前提檢查：既有的內容就緒事件也必須在同一份註冊表裡（證明比對方式有效）")
end)()

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
-- 面板 1382×950 是 NBPanel.defaultSize() 在 1920×1080 stub 下的結果（0.72／0.88 比例）。
-- ---------------------------------------------------------------------------
;(function()
    local panel = NBPanel:new()
    panel:createChildren()

    -- 版面回歸紅線：工具列與內容區的 rect／margins 逐像素釘死。
    -- 期望值全是字面數字（toolbarY 19 + toolbarHeight 18+6=24 → 43；950-43-14 → 893；
    -- 側欄 clamp(180, floor(1382*0.26)=359, 300) → 300；內文寬 1382-300 → 1082；捲軸寬 13）。
    checkEqual(panel.height, 950, "面板預設高（1080×0.88）")
    checkEqual(panel.toolbarY, 19, "工具列 y = titleBarHeight")
    checkEqual(panel.toolbarHeight, 24, "工具列高 = 字高 + 6")
    checkEqual(panel.contentY, 43, "內容區 y = toolbarY + toolbarHeight")
    checkEqual(panel:contentHeight(), 893, "內容區高 = height - contentY - resizeWidgetHeight")

    local savedScreenWidth, savedScreenHeight = SCREEN_WIDTH, SCREEN_HEIGHT
    SCREEN_WIDTH, SCREEN_HEIGHT = 800, 600
    local sizedWidth, sizedHeight = NBPanel.defaultSize()
    check(sizedWidth == 576 and sizedHeight == 520,
        "800×600：寬走 72%、高由螢幕邊界 600-80 夾到 520")
    SCREEN_WIDTH, SCREEN_HEIGHT = 2560, 1440
    sizedWidth, sizedHeight = NBPanel.defaultSize()
    check(sizedWidth == 1440 and sizedHeight == 1080,
        "2560×1440：預設尺寸吃 1440×1080 上限")
    SCREEN_WIDTH, SCREEN_HEIGHT = 300, 250
    sizedWidth, sizedHeight = NBPanel.defaultSize()
    check(sizedWidth == 420 and sizedHeight == 260,
        "極小畫面：仍由 420×260 最小值保底")
    SCREEN_WIDTH, SCREEN_HEIGHT = savedScreenWidth, savedScreenHeight
    checkEqual(panel:sidebarWidth(), 300, "側欄寬吃上限 300（floor(1382*0.26)=359 被夾）")
    checkEqual(panel.docTree.x, 0, "文件樹貼齊內容區左緣")
    checkEqual(panel.docTree.y, 43, "文件樹 y = contentY")
    checkEqual(panel.docTree.width, 300, "文件樹寬 = 側欄寬")
    checkEqual(panel.docTree.height, 893, "文件樹高 = 內容區高")
    checkEqual(panel.docTree.itemheight, 24, "文件樹列高 = 字高 18 + padY 3 x 2")
    checkEqual(panel.sidebarButton.x, 6, "側欄開關獨立貼齊工具列左側")
    checkEqual(panel.richText.x, 300, "richText 從側欄右緣起算")
    checkEqual(panel.richText.y, 43, "richText y 不得改變")
    checkEqual(panel.richText.width, 1082, "richText 寬 = 面板寬 - 側欄寬")
    checkEqual(panel.richText.height, 893, "richText 高不得改變（height - contentY - resizeWidgetHeight）")
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
    -- 內容尚未同步（contentState="syncing"）：面板這一層只畫工具列、側欄分隔線與占位字，
    -- 側欄裡的列由 NBDocTree 這個子元件自己畫（見下方文件樹段落）。

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
    local bgRect = findRect(rects, 0, 0, 1382, 950)
    check(bgRect ~= nil and nearly(bgRect.a, 0.8) and bgRect.r == 0,
        "E0 面板底必須退回 drawRect(0,0,w,h) BG_PANEL：" .. describe(bgRect))
    local titleRect = findRect(rects, 0, 0, 1382, 19)
    check(titleRect ~= nil and nearly(titleRect.a, 0.10) and titleRect.r == 1,
        "E0 標題列疊色必須退回 drawRect(0,0,w,th) TITLEBAR_FILL：" .. describe(titleRect))
    check(findRect(rects, 0, 18, 1382, 1) ~= nil, "標題列下緣 1px 分隔線 (0, th-1, w, 1)")
    check(findRect(rects, 0, 19, 1382, 24) ~= nil, "工具列底 (0, toolbarY, w, toolbarHeight)")
    check(findRect(rects, 0, 42, 1382, 1) ~= nil,
        "工具列下緣分隔線 (0, toolbarY+toolbarHeight-1, w, 1) 橫貫整個面板寬")
    check(findRect(rects, 299, 43, 1, 893) ~= nil,
        "側欄與內文之間的 1px 分隔線 (sidebarWidth-1, contentY, 1, contentHeight)")
    -- 舊的橫向頁籤（每個頁籤一塊填色＋3 邊框＋底線＋未讀點）已整批移除
    checkEqual(findRect(rects, 0, 41, 100, 2), nil, "不得再有選中頁籤的 2px 底線")
    checkEqual(findRect(borders, 0, 19, 100, 24), nil, "不得再有頁籤外框")
    check(findRect(rects, 0, 936, 1382, 1) ~= nil, "resize 列上緣 1px 分隔線 (0, height-rh, w, 1)")
    check(#scaled == 1 and scaled[1].x == 1369 and scaled[1].y == 937
        and scaled[1].w == 10 and scaled[1].h == 10,
        "resize 把手圖示：原位 (w-rh+1, height-rh+1)、邊長 rh-4（留在分隔線下方、直角在弧線內）")
    local frameBorder = findRect(borders, 0, 0, 1382, 950)
    check(frameBorder ~= nil and nearly(frameBorder.a, 1) and nearly(frameBorder.r, 0.4),
        "E0 面板外框退回 drawRectBorder(0,0,w,H) BORDER：" .. describe(frameBorder))
    checkEqual(#patches, 0, "E0 不可能有 9-slice 落點")

    -- stencil 收支：UIElement.stencilLevel 是 static、只在 UIManager.render 開頭歸零
    -- （UIManager.java:274），元素之間不重設。set 與 clear 必須成對。
    -- 頁籤區那一層巢狀 stencil 隨著橫向頁籤一起消失了：側欄現在是**子元件**
    -- （NBDocTree），它的裁切由原版 ISScrollingListBox:prerender 自己收支。
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
        checkEqual(maxLevel, 1, "面板只開一層 stencil（頁籤區那層巢狀已隨頁籤移除）")
        checkEqual(#repaints, 0, "沒有巢狀 stencil 就不該有 repaintStencilRect")
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
    local bgPatch = findPatch("mui_round_fill.png", 100, 50, 1382, 950)
    check(bgPatch ~= nil and nearly(bgPatch.a, 0.8) and bgPatch.r == 0,
        "E1 面板底 mui_round_fill 落在絕對座標 (100,50,1382,950) 染 BG_PANEL")
    local titlePatch = findPatch("mui_roundtop_fill.png", 100, 50, 1382, 19)
    check(titlePatch ~= nil and nearly(titlePatch.a, 0.10) and titlePatch.r == 1,
        "E1 標題列 mui_roundtop_fill (100,50,1382,19) 染 TITLEBAR_FILL")
    local framePatch = findPatch("mui_round_border.png", 100, 50, 1382, 950)
    check(framePatch ~= nil and nearly(framePatch.a, 1) and nearly(framePatch.r, 0.4),
        "E1 面板外框 mui_round_border (100,50,1382,950) 染 BORDER")
    checkEqual(#patches, 3, "E1 一幀恰好 3 次 9-slice：底、標題、外框（頁籤那 3 次已移除）")
    check(findRect(rects, 0, 0, 1382, 950) == nil and findRect(rects, 0, 0, 1382, 19) == nil
        and findRect(borders, 0, 0, 1382, 950) == nil,
        "E1 走了 9-slice 就不得再畫直角底／標題／外框（會疊成雙倍 alpha）")
    check(findRect(rects, 0, 42, 1382, 1) ~= nil and findRect(rects, 299, 43, 1, 893) ~= nil
        and findRect(rects, 0, 936, 1382, 1) ~= nil,
        "E1 工具列分隔線／側欄分隔線／resize 分隔線仍是 drawRect")
    checkEqual(#scaled, 1, "E1 drawTextureScaled 只剩 resize 把手（未讀點移到 NBDocTree）")
    -- 首呼叫回 null 的引擎行為：每張貼圖恰好呼叫兩次；第二幀不再呼叫（已快取）
    local roundFillCalls = good.calls["media/ui/MinidoracatUI/mui_round_fill.png"]
    checkEqual(roundFillCalls, 2, "E1 getSharedTexture 連呼兩次繞過首呼叫回 null")
    clearDraws()
    drawFrame()
    checkEqual(good.calls["media/ui/MinidoracatUI/mui_round_fill.png"], 2,
        "E1 第二幀不得再呼叫 getSharedTexture（框架 Skin 已快取）")
    checkEqual(#patches, 3, "E1 第二幀仍是 3 次 9-slice")

    -- 收合（釘選解除後滑鼠離開 ISCollapsableWindow.lua:237-244，或 layout.ini pin=false）：
    -- 面板只剩標題列一條。原版靠 drawRect／drawTextCentre 的 isCollapsed 守衛
    -- （ISUIElement.lua:1191-1197,:1280-1284）不畫內容；9-slice 沒有那道守衛，NBPanel 要自己跳過：
    -- 標題疊色改四角圓（下兩角不從面板底弧線外露出）、不畫分隔線、不畫頁籤／占位／resize 列。
    panel.isCollapsed = true
    panel.contentState = "error"
    clearDraws()
    drawFrame()
    check(findPatch("mui_round_fill.png", 100, 50, 1382, 19) ~= nil,
        "收合：面板底 mui_round_fill 只畫標題列高 (100,50,1382,19)")
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
    check(findPatch("mui_round_border.png", 100, 50, 1382, 19) ~= nil, "收合：外框 mui_round_border (100,50,1382,19)")
    checkEqual(#patches, 3, "收合：一幀恰好 3 次 9-slice（底、標題疊色、外框），頁籤／錯誤區塊不畫")
    checkEqual(#rects, 0, "收合：不畫分隔線／工具列底／側欄線／resize 線（drawRect 0 次）")
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
    check(findRect(rects, 0, 0, 1382, 950) ~= nil and findRect(borders, 0, 0, 1382, 950) ~= nil,
        "E2a 貼圖 nil 時面板底／外框退回 drawRect／drawRectBorder")
    local badTotal = 0
    local badPath
    for badPath in pairs(bad.calls) do
        badTotal = badTotal + bad.calls[badPath]
        checkEqual(bad.calls[badPath], 2, "E2a 每張壞貼圖恰好呼叫兩次：" .. badPath)
    end
    checkEqual(badTotal, 6, "E2a 一幀碰到 3 張貼圖 × 2 次")
    clearDraws()
    drawFrame()
    local badTotalAfter = 0
    for badPath in pairs(bad.calls) do
        badTotalAfter = badTotalAfter + bad.calls[badPath]
    end
    checkEqual(badTotalAfter, 6, "E2a 第二幀不得重試同名壞貼圖")

    -- E2b：getSharedTexture 給了物件但 render 會拋（PNG 解碼失敗 → texture 為 null）
    local broken = { calls = {}, throwOnRender = true, renderAttempts = 0 }
    _G.NinePatchTexture = makeNinePatchStub(broken)
    NBSkin.reset()
    clearDraws()
    local okFrame = pcall(drawFrame)
    check(okFrame, "E2b render 拋錯不得外洩到 prerender/render")
    checkEqual(broken.renderAttempts, 3, "E2b 3 張貼圖各只嘗試 render 一次就標為壞")
    check(findRect(rects, 0, 0, 1382, 950) ~= nil and findRect(borders, 0, 0, 1382, 950) ~= nil,
        "E2b render 拋錯的同一幀就退回 drawRect／drawRectBorder")
    clearDraws()
    drawFrame()
    checkEqual(broken.renderAttempts, 3, "E2b 第二幀不再嘗試 render 壞掉的貼圖")

    -- 浮鈕與 Toast 已上移家族框架：dofile 真框架 widget，驗 wrapper 端到端
    -- （wrapper 業務：色票/標題/內容/位置 clamp → 框架繪製落點與舊版逐位相同）。
    -- widget 本體行為（拖曳門檻/佇列上限/動畫細節）由框架 repo harness 覆蓋。
    local MUI_DIR = MUI_V1:gsub("V1%.lua$", "")
    dofile(MUI_DIR .. "Widgets/FloatButton.lua")
    dofile(MUI_DIR .. "Widgets/Toast.lua")
    check(MinidoracatUI.v1.CAPABILITIES.floatButton == true
        and MinidoracatUI.v1.CAPABILITIES.toast == true, "框架 widget 能力已翻 true")
    -- 浮鈕候選原始碼可用 NB_FLOAT_LUA 覆寫（家族跨 repo 對照時指到暫存候選檔）；
    -- 沒有 override 就走本 repo 的 production。
    dofile(os.getenv("NB_FLOAT_LUA")
        or (MEDIA_LUA .. "client/NoticeBoard/NBFloatButton.lua"))
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBToast.lua")

    _G.NinePatchTexture = makeNinePatchStub({ calls = {} })
    NBSkin.reset()

    -- 浮鈕：wrapper 經框架建立；prerender 有玩家（框架的無玩家自我隱藏另在框架 harness 驗）
    local savedGetPlayer = _G.getSpecificPlayer
    _G.getSpecificPlayer = function() return {} end
    patches = {}
    -- 建立前先在記憶體 layout.ini 放一筆本解析度的紀錄（含舊版寫過的 visible 欄）：
    -- 原版 RegisterWindow 當下就會 TryRestore → funcs.RestoreLayout(target, ...)，
    -- 所以「位置有沒有真的被套用」是建立完就看得到的結果。
    LAYOUT_INI.text = "[1920x1080]\nMinidoracatNBFloatButton x=640 y=480 visible=false\n"
    ISLayoutManager.layouts = nil
    ISLayoutManager.windows = {}
    local button = NBFloatButton.ensureInstance()
    check(button ~= nil, "wrapper 經框架 FloatButton 建立浮鈕")
    check(button:getX() == 640 and button:getY() == 480,
        "建立當下就套用 layout.ini 裡本解析度的位置（回呼掛錯位置就會留在預設槽位）")
    button.unread = true
    button:setPosition(10, 20)
    local buttonScaled = {}
    button.drawTextureScaled = function(_, texture, x, y, w, h, a, r, g, b)
        buttonScaled[#buttonScaled + 1] = { x = x, y = y, w = w, h = h, a = a, r = r }
    end
    button:prerender()
    checkEqual(#patches, 2, "浮窗一幀 = 底 + 框（沒 hover）")
    check(patches[1].path == "media/ui/MinidoracatUI/mui_round_fill.png" and patches[1].x == 10
        and patches[1].y == 20 and patches[1].w == 40 and patches[1].h == 40 and nearly(patches[1].a, 0.8),
        "浮窗底 mui_round_fill (10,20,40,40) BG_PANEL——與換皮前逐位相同")
    check(patches[2].path == "media/ui/MinidoracatUI/mui_round_border.png" and patches[2].x == 10
        and patches[2].y == 20 and patches[2].w == 40 and patches[2].h == 40,
        "浮窗框 mui_round_border (10,20,40,40)")
    check(#buttonScaled == 2 and buttonScaled[1].x == 31 and buttonScaled[1].y == -3
        and buttonScaled[1].w == 10 and buttonScaled[2].x == 32 and buttonScaled[2].y == -2
        and buttonScaled[2].w == 8,
        "浮窗未讀點掛角位置不變 (w-8, -2, 8)：光暈 (31,-3,10) 主點 (32,-2,8)")

    -- 點擊業務綁定：onClick → NBPanel.toggle（stub 計數，不真開面板）
    local savedToggle = NBPanel.toggle
    local toggles = 0
    NBPanel.toggle = function() toggles = toggles + 1 end
    button.onClick(button)
    NBPanel.toggle = savedToggle
    checkEqual(toggles, 1, "浮鈕點擊綁 NBPanel.toggle")

    -- ---------------------------------------------------------------------
    -- 位置持久化：原版 ISLayoutManager ＋ 記憶體 layout.ini，整條序列化往返都跑到。
    -- ---------------------------------------------------------------------
    -- 真的拖一次（框架 setCapture 五件套）：放開那一刻就得落地，不能等遊戲存檔——
    -- 拖完直接 ESC 離開的玩家最多，等 OnPostSave 等於白拖。
    local savedMouseX, savedMouseY = _G.getMouseX, _G.getMouseY
    local mouseX, mouseY = 500, 600
    _G.getMouseX = function() return mouseX end
    _G.getMouseY = function() return mouseY end
    button:setPosition(300, 400)
    button:onMouseDown(0, 0)
    mouseX, mouseY = 560, 640
    button:onMouseMove(60, 40)
    button:onMouseUp(0, 0)
    _G.getMouseX, _G.getMouseY = savedMouseX, savedMouseY
    check(button:getX() == 360 and button:getY() == 440,
        "前提：拖曳確實把浮鈕移到 (360,440)")
    -- 原版 WriteIni 用 pairs 走欄位，欄序不是規格；比對欄本身，不比對順序。
    check(contains(LAYOUT_INI.text, "MinidoracatNBFloatButton")
        and contains(LAYOUT_INI.text, "x=360") and contains(LAYOUT_INI.text, "y=440"),
        "拖曳放開就把落點寫進 layout.ini（不等 OnPostSave 存檔時機）")
    check(not contains(LAYOUT_INI.text, "visible="),
        "保存只寫座標：舊版留下的 visible 欄要清掉（原版會拿它強開／強關浮鈕）")

    -- 下一次開遊戲：重新 ReadIni 再 TryRestore，位置要從那串文字回得來
    button:setPosition(0, 0)
    ISLayoutManager.layouts = nil
    ISLayoutManager.TryRestore("MinidoracatNBFloatButton")
    check(button:getX() == 360 and button:getY() == 440,
        "重讀 layout.ini 之後還原到拖曳落點（序列化往返）")

    -- 可見性不屬於 layout。本 harness 的 Base:setVisible 是 no-op，所以只給浮鈕實例
    -- 單獨接一份真的，才驗得到「還原不碰可見性」。
    button.visible = true
    button.setVisible = function(self, value) self.visible = value end
    button.getIsVisible = function(self) return self.visible end
    button:setVisible(false)
    ISLayoutManager.layouts = nil
    ISLayoutManager.TryRestore("MinidoracatNBFloatButton")
    check(button:getIsVisible() == false,
        "還原只套座標：玩家藏起來的浮鈕不得被 layout 開回來")
    button:setVisible(true)

    -- layout.ini 是玩家改得到的純文字，壞值不得把浮鈕推到摸不到的地方。
    -- inf 特別危險：與 inf 的大小比較永遠不成立，會整條躲過每幀夾限。
    local BAD_COORDS = {
        { text = "x=99999 y=-5", x = 1920 - 40, y = 0, why = "超界數值夾回螢幕內" },
        { text = "x=1e999 y=1e999", x = 360, y = 440, why = "inf 直接拒絕（躲得過夾限）" },
        { text = "x=abc y=10", x = 360, y = 440, why = "非數值直接拒絕，維持現有位置" },
    }
    for _, case in ipairs(BAD_COORDS) do
        button:setPosition(360, 440)
        LAYOUT_INI.text = "[1920x1080]\nMinidoracatNBFloatButton " .. case.text .. "\n"
        ISLayoutManager.layouts = nil
        ISLayoutManager.TryRestore("MinidoracatNBFloatButton")
        check(button:getX() == case.x and button:getY() == case.y,
            "layout.ini 壞值：" .. case.why)
    end

    -- 解析度變更：原版只在 RegisterWindow 那一次 TryRestore，常駐浮鈕得自己重套當前
    -- profile（Core.java:2242-2262 已先更新尺寸才發事件，所以這裡讀到的是新尺寸）。
    local savedScreenW, savedScreenH = SCREEN_WIDTH, SCREEN_HEIGHT
    LAYOUT_INI.text = "[1920x1080]\nMinidoracatNBFloatButton x=300 y=400\n"
        .. "[1280x720]\nMinidoracatNBFloatButton x=100 y=110\n"
    ISLayoutManager.layouts = nil
    SCREEN_WIDTH, SCREEN_HEIGHT = 1280, 720
    NBFloatButton.onResolutionChange()
    check(button:getX() == 100 and button:getY() == 110,
        "換解析度：套用新解析度自己的紀錄，不是沿用舊解析度的座標")

    SCREEN_WIDTH, SCREEN_HEIGHT = 1024, 768
    NBFloatButton.onResolutionChange()
    check(button:getX() == 1024 - 40 - 16 and button:getY() == 768 / 2 - 20,
        "換到沒有紀錄的解析度：回本 MOD 的預設槽位（右緣 16px、垂直居中）")

    button:setVisible(false)
    SCREEN_WIDTH, SCREEN_HEIGHT = 1920, 1080
    NBFloatButton.onResolutionChange()
    check(button:getIsVisible() == false and button:getX() == 300 and button:getY() == 400,
        "解析度事件只動座標：隱藏中的浮鈕維持隱藏")
    button:setVisible(true)
    SCREEN_WIDTH, SCREEN_HEIGHT = savedScreenW, savedScreenH

    -- ensureInstance 是重生／未讀事件的共同入口，不得把玩家拖好的位置重設回預設
    button:setPosition(555, 222)
    check(NBFloatButton.ensureInstance() == button
        and button:getX() == 555 and button:getY() == 222,
        "重複 ensureInstance 不新建浮鈕，也不把拖曳位置重設回預設槽位")
    _G.getSpecificPlayer = savedGetPlayer

    -- Toast：wrapper 轉發（標題＋色票），動畫落點與換皮前逐位相同
    local FWToast = MinidoracatUI.v1.Toast
    FWToast._resetForTests()
    _G.getTimestampMs = function() return 0 end
    local toast = NBToast.show("hello")
    check(toast ~= nil and toast.titleText == "[IGUI_MinidoracatNB_PanelTitle]",
        "wrapper 帶面板標題進框架 Toast")
    check(NBToast.show("") == nil, "空訊息拒絕（wrapper 前置檢查）")
    patches = {}
    -- 進場第 100ms（ENTER 250ms）：x = 2220 + (1604-2220)*0.4 = 1973.6，alpha 0.4
    _G.getTimestampMs = function() return 100 end
    toast:prerender()
    _G.getTimestampMs = function() return 0 end
    checkEqual(#patches, 2, "Toast 一幀 = 底 + 框")
    check(patches[1].path == "media/ui/MinidoracatUI/mui_round_fill.png" and patches[1].x == 1973
        and patches[1].y == 60 and patches[1].w == 300 and patches[1].h == 56,
        "Toast 動畫中的小數 x 必須 floor 後才交給 NinePatchTexture（1973.6 → 1973）")
    check(nearly(patches[1].a, 0.85 * 0.4) and nearly(patches[2].a, 0.9 * 0.4),
        "Toast 底／框的 alpha 要乘上動畫 alpha（wrapper 色票 TOAST_BG/TOAST_BORDER）")
    check(patches[2].path == "media/ui/MinidoracatUI/mui_round_border.png" and patches[2].x == 1973
        and nearly(patches[2].r, 1) and nearly(patches[2].g, 0.85),
        "Toast 框 mui_round_border 染 TOAST_BORDER（琥珀）")
    FWToast._resetForTests()

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
                end, stopSoundLocal = function() end }
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

    -- Select through the actual toolbar menu, then observe the next notification.
    local panel = NBPanel:new()
    panel:createChildren()
    panel.voiceButton.onclick(panel, panel.voiceButton)
    local menu = CONTEXT_MENUS.list[#CONTEXT_MENUS.list]
    checkEqual(#menu.options, 5, "voice menu offers original, auto and three languages")
    local savedTranslator = _G.Translator
    local gameLanguage = "CN"
    _G.Translator = { getLanguage = function()
        return { name = function() return gameLanguage end }
    end }
    local expectedSounds = {
        chime = "MinidoracatNBNotify", auto = "MinidoracatNBVoiceCH",
        CH = "MinidoracatNBVoiceCH", EN = "MinidoracatNBVoiceEN",
        JP = "MinidoracatNBVoiceJP",
    }
    for _, option in ipairs(menu.options) do
        sounds = {}
        option.callback(option.target, option.param)
        checkEqual(sounds[1], expectedSounds[option.param],
            "selecting a voice immediately previews that voice")
        sounds, toasts = {}, {}
        NBPanel.notifyUnread(snapshot, nil)
        checkEqual(sounds[1], expectedSounds[option.param],
            "selected voice controls notification playback")
        panel.voiceButton.onclick(panel, panel.voiceButton)
        local checkedCount = 0
        for _, reopened in ipairs(CONTEXT_MENUS.list[#CONTEXT_MENUS.list].options) do
            if reopened.checked then
                checkedCount = checkedCount + 1
                checkEqual(reopened.param, option.param, "reopened menu marks selected voice")
            end
        end
        checkEqual(checkedCount, 1, "voice menu has exactly one selected option")
    end
    VOICE_PREFERENCE.value = "auto"
    gameLanguage = "FR"
    sounds = {}
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(sounds[1], "MinidoracatNBVoiceEN", "unsupported game language uses English")
    SOUND_VOLUME.value = 0
    sounds = {}
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#sounds, 0, "voice selection cannot bypass player mute")
    SOUND_VOLUME.value = 1
    _G.SandboxVars = { MinidoracatNB = { NotifySound = false } }
    NBPanel.notifyUnread(snapshot, nil)
    checkEqual(#sounds, 0, "voice selection cannot bypass server mute")
    VOICE_PREFERENCE.value = "chime"
    _G.Translator = savedTranslator

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

-- findLinkAt 吃**內容座標**：兩個呼叫端（getMouseX/Y 與 onMouseUp 參數）給的座標
-- 都已扣掉捲動（ISUIElement.lua:339-350、UIElement.java:1311-1321），這裡不得再加
-- getYScroll() 補償。踩過：加了一次 → 捲動後判定區上移，「要在連結上方才觸發」。
;(function()
    local panel = NBPanel:new()
    panel.linkHitRegions = {
        {
            url = "https://discord.gg/Gur2V67",
            segments = { { x1 = 10, x2 = 50, y1 = 100, y2 = 110 } },
        },
    }
    -- 模擬捲動中的 richText：getYScroll 回傳 -50（往下捲了 50px）
    panel.richText = { getYScroll = function() return -50 end }

    local hit = panel:findLinkAt(20, 105)
    check(hit ~= nil and hit.url == "https://discord.gg/Gur2V67",
        "內容座標直接命中，不受捲動影響")
    check(panel:findLinkAt(20, 55) == nil,
        "舊實作（加 scrollY）會在文字上方 50px 誤命中——不得復發")
    check(panel:findLinkAt(20, 130) == nil, "區域外不命中")
end)()

-- 連結 hover 提示（NBPanel:renderLinkTooltip）：顯示完整網址、過長截斷、邊界 clamp。
-- 直接呼叫 renderLinkTooltip 而不跑整個 render：這裡要驗的是提示框自己的幾何與文字，
-- 不是 render 的其他部分（那些已在上面的 stencil／頁籤測試涵蓋）。
;(function()
    local panel = NBPanel:new()
    panel.isCollapsed = false
    panel.width, panel.height = 400, 300
    panel.contentState = "ready"

    local rects, texts = {}, {}
    panel.drawRect = function(_, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end
    panel.drawRectBorder = function() end
    panel.drawText = function(_, str, x, y) texts[#texts + 1] = { str = str, x = x, y = y } end

    local hovered = nil
    panel.getHoveredLink = function() return hovered end
    local mouseX, mouseY = 0, 0
    panel.getMouseX = function() return mouseX end
    panel.getMouseY = function() return mouseY end
    local function reset() rects, texts = {}, {} end

    -- 無 hover：一筆都不該畫
    reset()
    panel:renderLinkTooltip()
    checkEqual(#texts, 0, "沒有 hover 的連結時不畫提示")
    checkEqual(#rects, 0, "沒有 hover 的連結時不畫提示底")

    -- hover：顯示完整網址（含底框）
    hovered = { url = "https://discord.gg/Gur2V67" }
    mouseX, mouseY = 40, 50
    reset()
    panel:renderLinkTooltip()
    checkEqual(#texts, 1, "hover 連結時畫出一段提示文字")
    checkEqual(texts[1].str, "https://discord.gg/Gur2V67", "提示顯示完整網址")
    check(#rects >= 1, "提示要有底框（框架缺席時 Skin.fill 退 drawRect）")
    checkEqual(texts[1].x, 40 + 12 + 6, "提示文字 x = 游標 +12 偏移 +6 padding")

    -- 摺疊時跳過：Skin.fill/border 沒有 isCollapsed 守衛，靠這裡擋
    panel.isCollapsed = true
    reset()
    panel:renderLinkTooltip()
    checkEqual(#texts, 0, "面板摺疊時不畫連結提示")
    panel.isCollapsed = false

    -- 過長網址截斷：stub 的 MeasureStringX = 字數 × 8，maxWidth = 400 - 6*2 - 8 = 380
    -- → 可容納 47 字元；截斷後長度含 "..." 不得超過該上限
    local longUrl = "https://example.com/" .. string.rep("a", 120)
    hovered = { url = longUrl }
    reset()
    panel:renderLinkTooltip()
    checkEqual(#texts, 1, "過長網址仍畫出提示")
    check(string.len(texts[1].str) < string.len(longUrl), "過長網址要被截斷")
    check(string.sub(texts[1].str, -3) == "...", "截斷後補省略號")
    check(string.len(texts[1].str) * 8 <= 380, "截斷後寬度不超過可用寬度")
    checkEqual(string.sub(texts[1].str, 1, 20), "https://example.com/", "截斷從尾端砍，網域保留")

    -- 快取：同一網址重畫不重算（換網址才更新）
    local firstText = texts[1].str
    reset()
    panel:renderLinkTooltip()
    checkEqual(texts[1].str, firstText, "同一網址的截斷結果一致（走快取）")

    -- 右邊界 clamp：游標貼近右緣時提示不得超出面板
    hovered = { url = "https://discord.gg/Gur2V67" }
    mouseX, mouseY = 395, 50
    reset()
    panel:renderLinkTooltip()
    local box = rects[#rects]
    check(box.x + box.w <= panel.width - 4, "提示框不超出面板右緣")
    check(box.x >= 4, "提示框不超出面板左緣")

    -- 下方空間不足時翻到游標上方
    mouseX, mouseY = 40, 295
    reset()
    panel:renderLinkTooltip()
    box = rects[#rects]
    check(box.y < 295, "下方空間不足時提示翻到游標上方")
end)()

-- ---------------------------------------------------------------------------
-- A 款文件樹側欄：分類展開／收合、未讀聚合、選取保存、強制收合與偏好。
-- 用真的 ISScrollingListBox（上方 dofile 原版）：items／rowAt／捲動高度都是引擎的，
-- 這裡驗的是 NBPanel 疊在上面的模型與繪製。
-- ---------------------------------------------------------------------------
;(function()
    local function newSidebarPanel()
        local panel = NBPanel:new()
        panel:createChildren()
        panel.resizeWidget = { getIsVisible = function() return true end }
        return panel
    end

    local function file(id, title, category, content)
        return { id = id, title = title, category = category, h = id,
            content = content or ("# " .. title) }
    end

    local function kinds(panel)
        local result = {}
        local index
        for index = 1, #panel.docTree.items do
            local entry = panel.docTree.items[index].item
            result[index] = entry.kind .. ":" .. (entry.kind == "category"
                and entry.key or entry.id)
        end
        return table.concat(result, ",")
    end

    -- 舊版 server 的快照：沒有 categories、files 也沒有 category 欄位。
    local legacy = { sid = "s", files = {
        file("alpha", "Alpha"), file("beta", "Beta"),
    } }
    local panel = newSidebarPanel()
    panel:setSnapshot(legacy, nil)
    checkEqual(kinds(panel), "category:,file:alpha,file:beta",
        "舊快照（無 categories／category）顯示單一語系根層分類，公告全掛在它底下")
    checkEqual(panel.docTree.items[1].item.label, "[IGUI_MinidoracatNB_CategoryRoot]",
        "根層分類用翻譯 key，不是硬寫的字面文字")
    checkEqual(panel.selectedFileId, "alpha", "沒有 preferredId 時選第一份公告")
    check(panel:selectFile("beta", false), "舊快照的每一份公告都選得到")
    checkEqual(panel.selectedFileId, "beta", "選取以裸檔名保存")

    -- 伺服器分類：order 依 snapshot.categories，空分類不顯示，未宣告的分類補在最後。
    local snapshot = { sid = "s",
        categories = {
            { key = "10_rules", label = "Rules" },
            { key = "20_events", label = "Events" },
            { key = "90_empty", label = "Empty" },
        },
        files = {
            file("welcome", "Welcome", ""),
            file("rule1", "No griefing", "10_rules"),
            file("rule2", "Base rules", "10_rules"),
            file("party", "Summer party", "20_events"),
            file("stray", "Stray notice", "99_undeclared"),
        } }
    panel = newSidebarPanel()
    panel:setSnapshot(snapshot, nil)
    checkEqual(kinds(panel),
        "category:,file:welcome,category:10_rules,file:rule1,file:rule2,"
            .. "category:20_events,file:party,category:99_undeclared,file:stray",
        "順序：語系根層 -> snapshot 宣告的分類 -> 未宣告的漏網分類；空分類整列不出現")
    checkEqual(panel.docTree.items[3].item.label, "Rules",
        "伺服器分類用 snapshot 給的 label")
    checkEqual(panel.docTree.items[8].item.label, "99_undeclared",
        "沒有 label 的分類退回 key，服主看得出是哪個目錄")

    -- 展開／收合：分類列點擊只切換展開，不改選取
    panel:selectFile("rule2", false)
    checkEqual(panel.selectedFileId, "rule2", "先選一份 10_rules 底下的公告")
    panel:onTreeRowClicked(panel.docTree.items[3].item)
    checkEqual(kinds(panel),
        "category:,file:welcome,category:10_rules,category:20_events,file:party,"
            .. "category:99_undeclared,file:stray",
        "收合分類後它底下的公告列整批消失（重建可見 items，不是設 height=0）")
    checkEqual(panel.selectedFileId, "rule2", "點分類列不得改變選取的公告")
    checkEqual(panel.docTree.selected, -1, "選取的公告被收起來時 listbox 沒有選中列")
    panel:onTreeRowClicked(panel.docTree.items[3].item)
    checkEqual(kinds(panel),
        "category:,file:welcome,category:10_rules,file:rule1,file:rule2,"
            .. "category:20_events,file:party,category:99_undeclared,file:stray",
        "再點一次展開回來")
    checkEqual(panel.docTree.selected, 5, "展開後 listbox 的 selected 對回選取的公告")

    -- 收合的分類裡有 preferredId：setSnapshot 必須展開父分類再選
    panel:onTreeRowClicked(panel.docTree.items[3].item)
    check(panel.docTree.items[4].item.kind == "category", "10_rules 現在是收合狀態")
    panel:setSnapshot(snapshot, "rule1")
    checkEqual(panel.selectedFileId, "rule1", "preferredId 被選中")
    checkEqual(kinds(panel),
        "category:,file:welcome,category:10_rules,file:rule1,file:rule2,"
            .. "category:20_events,file:party,category:99_undeclared,file:stray",
        "preferredId 落在收合分類時，父分類必須被展開")

    -- 未讀聚合：分類的紅點是子項的 OR，收合起來也還在
    UNREAD_IDS = {}
    UNREAD_IDS.rule2 = true
    panel = newSidebarPanel()
    panel:setSnapshot(snapshot, nil)
    checkEqual(panel.docTree.items[3].item.unread, true, "有未讀子項的分類要亮紅點")
    checkEqual(panel.docTree.items[5].item.unread, true, "未讀的公告列自己也亮紅點")
    checkEqual(panel.docTree.items[6].item.unread, false, "沒有未讀子項的分類不亮")
    panel:onTreeRowClicked(panel.docTree.items[3].item)
    checkEqual(panel.docTree.items[3].item.unread, true,
        "分類收合後紅點仍在（否則未讀會整批消失在看不見的地方）")
    panel:onTreeRowClicked(panel.docTree.items[3].item)

    -- markRead 之後紅點立刻消失，且不重建（捲動位置不被洗掉）
    READ_MARKS = {}
    panel:selectFile("rule2", true)
    checkEqual(READ_MARKS[1], "rule2", "選取時 markRead 走裸檔名")
    checkEqual(panel.docTree.items[5].item.unread, false, "markRead 後公告列的紅點立刻消失")
    checkEqual(panel.docTree.items[3].item.unread, false, "最後一個未讀清掉後分類紅點也跟著滅")
    UNREAD_IDS = {}

    -- 側欄幾何：clamp(180, floor(width*0.26), 300)
    panel = newSidebarPanel()
    panel.width = 500
    checkEqual(panel:sidebarWidth(), 0, "寬度 <640 強制收合，側欄寬 0")
    check(panel:isSidebarForcedCollapsed(), "500px 屬於強制收合區間")
    panel.width = 640
    checkEqual(panel:sidebarWidth(), 180,
        "640px 剛好不強制收合；floor(640*0.26)=166 被下限 180 夾住")
    panel.width = 900
    checkEqual(panel:sidebarWidth(), 234, "900px：floor(900*0.26)=234 落在夾限之間")
    panel.width = 2000
    checkEqual(panel:sidebarWidth(), 300, "2000px：floor(2000*0.26)=520 被上限 300 夾住")

    -- 強制收合時 richText 吃滿全寬，工具列按鈕照樣在
    panel.width = 500
    panel:updateLayout()
    checkEqual(panel.richText.x, 0, "強制收合：內文從最左緣起算")
    checkEqual(panel.richText.width, 500, "強制收合：內文吃滿面板全寬")
    checkEqual(panel.docTree.width, 0, "強制收合：文件樹寬 0")
    check(panel.langButton ~= nil and panel.resetButton ~= nil
        and panel.sidebarButton ~= nil,
        "收合狀態仍保留工具列按鈕（語言／重設大小／側欄開關）")

    -- 內容寬度改變必須重跑 renderSelected，讓圖片尺寸與連結區依新寬度重建；
    -- 只設 textDirty 只會 paginate 舊的 <IMAGE:path,w,h>。
    panel.selectedFileId = "wide"
    panel.fileEntries.wide = { id = "wide", file = file("wide", "Wide") }
    local rerenders = {}
    local originalRenderSelected = panel.renderSelected
    panel.renderSelected = function(_, markRead)
        rerenders[#rerenders + 1] = markRead
    end
    panel.width = 900
    panel:updateLayout()
    checkEqual(#rerenders, 1, "側欄／視窗改變內容寬度時必須重跑目前公告")
    checkEqual(rerenders[1], false, "幾何重排不得把公告誤標成已讀")
    panel.renderSelected = originalRenderSelected
    panel.selectedFileId = nil
    panel.fileEntries.wide = nil

    -- 偏好：手動切換寫進 NBClient，拉寬視窗後回到偏好值
    SIDEBAR_PREFERENCE.value = nil
    SIDEBAR_PREFERENCE.writes = 0
    panel.width = 1382
    panel:onSidebarToggle()
    checkEqual(SIDEBAR_PREFERENCE.writes, 1, "手動切換寫一次偏好")
    checkEqual(SIDEBAR_PREFERENCE.value, true, "從展開切到收合，偏好記 true")
    checkEqual(panel:sidebarWidth(), 0, "偏好收合時側欄寬 0")
    panel.width = 500
    panel:onSidebarToggle()
    checkEqual(SIDEBAR_PREFERENCE.value, false,
        "強制收合期間切換照樣記下偏好（玩家的意思是「我要目錄」）")
    checkEqual(panel:sidebarWidth(), 0, "但視窗還是太窄，實際仍收合")
    panel.width = 1382
    checkEqual(panel:sidebarWidth(), 300, "拉寬之後偏好生效，側欄自己回來")

    -- 沒有偏好時一律展開：目錄是這個面板的主要導覽，不再依公告數／有無分類猜。
    -- 舊版的門檻（>4 份或有 server 分類）刻意連同常數一起刪掉，這幾條就是它的墓碑。
    SIDEBAR_PREFERENCE.value = nil
    panel = newSidebarPanel()
    panel:setSnapshot(legacy, nil)
    checkEqual(panel:sidebarWidth(), 300, "無偏好 + 無分類 + 只有 2 份公告 -> 仍然預設展開")
    panel = newSidebarPanel()
    panel:setSnapshot(snapshot, nil)
    checkEqual(panel:sidebarWidth(), 300, "無偏好但伺服器有分類 -> 預設展開")
    panel = newSidebarPanel()
    panel:setSnapshot({ sid = "s", files = { file("only", "Only") } }, nil)
    checkEqual(panel:sidebarWidth(), 300, "無偏好、只有 1 份公告 -> 一樣展開（不再有數量門檻）")
    SIDEBAR_PREFERENCE.value = true
    panel = newSidebarPanel()
    panel:setSnapshot(snapshot, nil)
    checkEqual(panel:sidebarWidth(), 0, "偏好收合時照偏好走，換快照也不會被翻回展開")
    SIDEBAR_PREFERENCE.value = false
    panel = newSidebarPanel()
    panel:setSnapshot(legacy, nil)
    checkEqual(panel:sidebarWidth(), 300, "偏好展開時照偏好走")
    SIDEBAR_PREFERENCE.value = nil

    -- 列的繪製：選中公告的 2px 琥珀線在左緣、未讀紅點在右緣、分類有展開記號。
    -- **這一段是「沒有圖示」的版面**：圖示資產（mui_icon_*.png）還沒註冊進 TEXTURE_SIZES，
    -- 框架的 Icons.draw 一律回 false，所以走的是 ASCII 記號 + 18/26 縮排那條退回路徑。
    -- 圖示版面（chevron／folder／document 與加寬的按鈕）在下面獨立一段驗。
    UNREAD_IDS = {}
    UNREAD_IDS.party = true
    panel = newSidebarPanel()
    panel:setSnapshot(snapshot, nil)
    local tree = panel.docTree
    local rowRects, rowTexts = {}, {}
    tree.drawRect = function(_, x, y, w, h, a, r, g, b)
        rowRects[#rowRects + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
    end
    tree.drawRectBorder = function(_, x, y, w, h)
        rowRects[#rowRects + 1] = { x = x, y = y, w = w, h = h, border = true }
    end
    tree.drawText = function(_, text, x, y)
        rowTexts[#rowTexts + 1] = { text = text, x = x, y = y }
    end
    -- mui_dot.png 在上方的皮膚段落已註冊進 TEXTURE_SIZES，所以未讀點走的是框架的
    -- 貼圖路徑（光暈 + 主點兩次 drawTextureScaled），不是 E0 那條方點退回。
    local rowScaled = {}
    tree.drawTextureScaled = function(_, texture, x, y, w, h)
        rowScaled[#rowScaled + 1] = { x = x, y = y, w = w, h = h }
    end
    local function drawRow(index)
        rowRects, rowTexts, rowScaled = {}, {}, {}
        tree.items[index].index = index
        tree:doDrawItem(0, tree.items[index], false)
    end

    drawRow(2) -- file:welcome（目前選中的第一份公告）
    checkEqual(panel.selectedFileId, "welcome", "第一份公告預設被選中")
    local accent = nil
    local rowIndex
    for rowIndex = 1, #rowRects do
        if rowRects[rowIndex].w == 2 and rowRects[rowIndex].x == 0 then
            accent = rowRects[rowIndex]
        end
    end
    check(accent ~= nil and accent.h == 23 and accent.r == 1 and accent.g == 0.85,
        "選中公告的左緣 2px 琥珀線（高 = 列高 24 - 1）")
    checkEqual(rowTexts[1].x, 26, "公告列的文字縮排在分類之下（x=26）")

    drawRow(6) -- category:20_events（有未讀子項 party）
    checkEqual(rowTexts[1].text, "-", "展開中的分類記號是 ASCII 的 -")
    checkEqual(rowTexts[1].x, 6, "分類記號畫在最左的記號欄")
    checkEqual(rowTexts[2].x, 18, "分類文字接在記號右側")
    checkEqual(#rowScaled, 2, "未讀點 = 光暈 + 主點兩次 drawTextureScaled")
    check(rowScaled[2].x == 300 - 14 and rowScaled[2].y == 8
        and rowScaled[2].w == 8 and rowScaled[2].h == 8,
        "未讀紅點畫在列的右緣（width-14）並垂直置中")

    panel:onTreeRowClicked(tree.items[6].item)
    drawRow(6)
    checkEqual(rowTexts[1].text, "+", "收合中的分類記號是 ASCII 的 +")

    -- 長標題依側欄寬截斷（stub 量測是每 byte 8px）
    panel = newSidebarPanel()
    panel:setSnapshot({ sid = "s", files = {
        file("long", string.rep("W", 200)),
    } }, nil)
    tree = panel.docTree
    rowTexts = {}
    tree.drawText = function(_, text, x, y)
        rowTexts[#rowTexts + 1] = { text = text, x = x, y = y }
    end
    tree.items[2].index = 2
    tree:doDrawItem(0, tree.items[2], false)
    check(string.len(rowTexts[1].text) < 200, "過長標題必須截斷")
    check(string.sub(rowTexts[1].text, -3) == "...", "截斷後補省略號")
    check(string.len(rowTexts[1].text) * 8 <= tree.width - 26 - 20,
        "截斷後寬度不超過側欄可用寬（width - 文字 x - 右側留白）")

    local emoji = "😀"
    panel = newSidebarPanel()
    panel:setSnapshot({ sid = "s", files = {
        file("emoji", "prefix-" .. string.rep(emoji, 100)),
    } }, nil)
    tree = panel.docTree
    rowTexts = {}
    tree.drawText = function(_, value)
        rowTexts[#rowTexts + 1] = value
    end
    tree:doDrawItem(0, tree.items[2], false)
    local fitted = rowTexts[1]
    check(string.sub(fitted, -3) == "...", "emoji 長標題截斷後仍要補省略號")
    check(string.sub(fitted, -7, -4) == emoji,
        "標準 Lua 的 UTF-8 測試環境不得把 emoji 砍在續接位元組中間")
    UNREAD_IDS = {}
end)()

-- ---------------------------------------------------------------------------
-- 工具列的「全部展開」／「全部收合」：一次點擊處理整棵樹。
-- 每一條都經由**按鈕自己的 onclick**跑（原生 ISButton 就是 onclick(target, self)），
-- 不直接呼叫方法：兩顆按鈕接到對調的 callback（貼上時最常見的錯）只有這樣驗得出來。
-- 這一段在圖示資產註冊之前，所以兩顆是純文字按鈕——批次行為與有沒有圖示無關。
-- ---------------------------------------------------------------------------
;(function()
    local savedPreferenceValue = SIDEBAR_PREFERENCE.value

    local function file(id, title, category)
        return { id = id, title = title, category = category, h = id,
            content = "# " .. title }
    end
    local snapshot = { sid = "s",
        categories = {
            { key = "10_rules", label = "Rules" },
            { key = "20_events", label = "Events" },
        },
        files = {
            file("welcome", "Welcome", ""),
            file("rule1", "No griefing", "10_rules"),
            file("rule2", "Base rules", "10_rules"),
            file("party", "Summer party", "20_events"),
        } }
    local ALL_EXPANDED = "category:,file:welcome,category:10_rules,file:rule1,"
        .. "file:rule2,category:20_events,file:party"

    local function kinds(panel)
        local result = {}
        local index
        for index = 1, #panel.docTree.items do
            local entry = panel.docTree.items[index].item
            result[index] = entry.kind .. ":" .. (entry.kind == "category"
                and entry.key or entry.id)
        end
        return table.concat(result, ",")
    end
    -- 真的按下去。原生 ISButton 的 onclick 收 (target, button)。
    local function click(button)
        button.onclick(button.target, button)
    end
    local function newPanel()
        local panel = NBPanel:new()
        panel:createChildren()
        panel:setSnapshot(snapshot, nil)
        return panel
    end
    -- 重建次數是這兩顆按鈕的效能合約：逐一分類各自 rebuildTree 也會通過下面每一條
    -- 狀態斷言，但分類多的伺服器上一次點擊就是一次看得見的頓卡。
    local function countCalls(panel, methodName)
        local counter = { count = 0 }
        local original = panel[methodName]
        panel[methodName] = function(...)
            counter.count = counter.count + 1
            return original(...)
        end
        return counter
    end

    -- 兩顆按鈕對每個玩家都存在：純本地操作，不經過網路，與 admin 權限無關。
    local panel = newPanel()
    check(panel.expandAllButton ~= nil and panel.collapseAllButton ~= nil,
        "非 admin 的連線玩家也有全部展開／全部收合")
    local savedIsClient = _G.isClient
    _G.isClient = function() return false end
    local spPanel = NBPanel:new()
    spPanel:createChildren()
    _G.isClient = savedIsClient
    checkEqual(spPanel.adminVisible, false, "前提：SP 環境沒有 admin 按鈕")
    check(spPanel.expandAllButton ~= nil and spPanel.collapseAllButton ~= nil,
        "SP 同樣要有這兩顆按鈕（它們不送任何網路封包）")

    -- 全部收合：整棵樹只剩分類列，選取／內文／未讀／側欄偏好一概不動。
    UNREAD_IDS = {}
    UNREAD_IDS.party = true
    SIDEBAR_PREFERENCE.value = false
    panel = newPanel()
    checkEqual(kinds(panel), ALL_EXPANDED, "前提：分類預設全部展開")
    panel:selectFile("rule2", false)
    checkEqual(panel.selectedFileId, "rule2", "前提：先選一份 10_rules 底下的公告")
    local rebuilds = countCalls(panel, "rebuildTree")
    local renders = countCalls(panel, "renderSelected")
    READ_MARKS = {}
    SIDEBAR_PREFERENCE.writes = 0
    click(panel.collapseAllButton)
    checkEqual(kinds(panel), "category:,category:10_rules,category:20_events",
        "全部收合：所有公告列一次消失，只剩三列分類")
    checkEqual(rebuilds.count, 1,
        "一次點擊只准重建一棵樹（不是每個分類重建一次）")
    local index
    for index = 1, #panel.categoryOrder do
        local key = panel.categoryOrder[index]
        checkEqual(panel.expandedCategories[key], false,
            "全部收合：分類「" .. key .. "」的狀態必須是布林 false")
    end
    checkEqual(panel.selectedFileId, "rule2", "全部收合不得改變選取的公告")
    checkEqual(renders.count, 0, "全部收合的點擊處理器本身不得重跑公告內容")
    checkEqual(#READ_MARKS, 0, "全部收合不得把任何公告標成已讀")
    checkEqual(panel.docTree.items[3].item.unread, true,
        "全部收合後未讀仍在（分類紅點是整個 bucket 的 OR）")
    checkEqual(panel.docTree.selected, -1,
        "選取的公告被收起來時 listbox 沒有選中列（與單列收合同一條紀律）")
    checkEqual(SIDEBAR_PREFERENCE.writes, 0, "全部收合不得寫側欄偏好")
    check(panel:sidebarWidth() > 0, "全部收合不得把側欄一起關掉")

    -- server refresh 仍沿用既有「選中的公告必須在目錄裡看得見」不變式：只重新展開
    -- selectedFileId 的父分類，其他分類維持批次收合狀態。
    local refreshPanel = newPanel()
    refreshPanel:selectFile("rule2", false)
    click(refreshPanel.collapseAllButton)
    refreshPanel:setVisible(false)
    refreshPanel:setSnapshot(snapshot, nil)
    checkEqual(kinds(refreshPanel),
        "category:,category:10_rules,file:rule1,file:rule2,category:20_events",
        "快照刷新只重新展開選中公告的父分類")
    checkEqual(refreshPanel.expandedCategories[""], false,
        "快照刷新不得展開沒有選中公告的根分類")
    checkEqual(refreshPanel.expandedCategories["10_rules"], true,
        "快照刷新必須展開選中公告所在分類")
    checkEqual(refreshPanel.expandedCategories["20_events"], false,
        "快照刷新不得展開其他分類")
    checkEqual(refreshPanel.selectedFileId, "rule2",
        "快照刷新後仍選中原公告")
    READ_MARKS = {}

    -- 全部展開：公告列全部回來，選取自己對回去。
    rebuilds.count = 0
    click(panel.expandAllButton)
    checkEqual(kinds(panel), ALL_EXPANDED, "全部展開：所有公告列一次回來")
    checkEqual(rebuilds.count, 1, "全部展開同樣只重建一棵樹")
    for index = 1, #panel.categoryOrder do
        local key = panel.categoryOrder[index]
        checkEqual(panel.expandedCategories[key], true,
            "全部展開：分類「" .. key .. "」的狀態必須是布林 true")
    end
    checkEqual(panel.selectedFileId, "rule2", "全部展開不得改變選取的公告")
    checkEqual(panel.docTree.selected, 5,
        "全部展開後 listbox 的 selected 對回選取的公告")
    checkEqual(renders.count, 0, "全部展開的點擊處理器本身不得重跑公告內容")
    checkEqual(#READ_MARKS, 0, "全部展開不得把任何公告標成已讀")
    checkEqual(panel.docTree.items[7].item.unread, true, "未讀狀態不受批次操作影響")
    checkEqual(SIDEBAR_PREFERENCE.writes, 0,
        "側欄本來就開著時全部展開不得多寫一次偏好")

    -- 批次操作不得配置「每分類一個」的 UI 元件：兩顆工具列按鈕就是全部的介面，
    -- 面板的子層數在點擊前後必須一模一樣。
    local childrenBefore = #panel.children
    click(panel.collapseAllButton)
    click(panel.expandAllButton)
    checkEqual(#panel.children, childrenBefore,
        "批次操作不得新增任何子元件（可見列仍只由 docTree 的 items 表示）")

    -- 唯一直接呼叫 setter 的一條：正規化是它自己的合約，按鈕永遠只傳字面 true／false。
    -- expandedCategories 混進 "yes"／1 這類值時，isCategoryExpanded 的 `~= false`
    -- 會把它們一律當展開，狀態就再也對不回按鈕按的是哪一顆。
    panel:setAllCategoriesExpanded("yes")
    checkEqual(panel.expandedCategories[panel.categoryOrder[1]], false,
        "只有布林 true 算展開：非布林的真值一律正規化成 false（全檔的 == true 紀律）")
    click(panel.expandAllButton)

    -- 玩家自己把側欄收起來：全部展開必須一併把目錄打開，否則按了畫面上毫無反應。
    SIDEBAR_PREFERENCE.value = nil
    panel = newPanel()
    click(panel.sidebarButton)
    checkEqual(panel:sidebarWidth(), 0, "前提：玩家手動收起側欄")
    checkEqual(SIDEBAR_PREFERENCE.value, true, "前提：收起側欄的偏好已寫下")
    SIDEBAR_PREFERENCE.writes = 0
    click(panel.collapseAllButton)
    checkEqual(SIDEBAR_PREFERENCE.writes, 0,
        "全部收合不碰側欄偏好，側欄已經收起時也一樣")
    checkEqual(panel.sidebarCollapsed, true, "全部收合不得把側欄翻回展開")
    click(panel.expandAllButton)
    checkEqual(panel.sidebarCollapsed, false,
        "全部展開必須把玩家收起的側欄一併打開（不然這顆按鈕看起來沒反應）")
    check(panel:sidebarWidth() > 0, "全部展開之後目錄真的看得見")
    checkEqual(SIDEBAR_PREFERENCE.writes, 1, "打開側欄的偏好只寫一次")
    checkEqual(SIDEBAR_PREFERENCE.value, false, "打開側欄的偏好必須被保存")

    -- 窄視窗的強制收合是版面限制、不是玩家的意思：不得硬撐出側欄把內文擠爆。
    panel.width = 500
    panel.sidebarCollapsed = false
    SIDEBAR_PREFERENCE.value = false
    SIDEBAR_PREFERENCE.writes = 0
    click(panel.collapseAllButton)
    click(panel.expandAllButton)
    check(panel:isSidebarForcedCollapsed(), "前提：500px 仍在強制收合區間")
    checkEqual(panel:sidebarWidth(), 0,
        "強制收合期間全部展開不得硬撐出側欄")
    checkEqual(SIDEBAR_PREFERENCE.writes, 0,
        "側欄偏好本來就是展開時，強制收合期間也不得多寫一次")
    for index = 1, #panel.categoryOrder do
        checkEqual(panel.expandedCategories[panel.categoryOrder[index]], true,
            "強制收合期間分類照樣全部打開（拉寬視窗就看得到）")
    end
    -- 但玩家明確收起過側欄時，偏好照樣記下「我要目錄」——與側欄開關同一條紀律。
    panel.sidebarCollapsed = true
    SIDEBAR_PREFERENCE.value = true
    SIDEBAR_PREFERENCE.writes = 0
    click(panel.expandAllButton)
    checkEqual(SIDEBAR_PREFERENCE.value, false,
        "強制收合期間也照樣記下「我要目錄」的偏好")
    checkEqual(SIDEBAR_PREFERENCE.writes, 1, "偏好仍然只寫一次")
    checkEqual(panel:sidebarWidth(), 0, "但視窗還是太窄，實際仍收合")

    -- 舊的單列 toggle 不得退化：批次之後單獨點一列仍然只影響那一列。
    SIDEBAR_PREFERENCE.value = false
    panel = newPanel()
    click(panel.collapseAllButton)
    panel:onTreeRowClicked(panel.docTree.items[2].item) -- category:10_rules
    checkEqual(kinds(panel),
        "category:,category:10_rules,file:rule1,file:rule2,category:20_events",
        "全部收合之後單獨展開一列，只有那一列展開")
    click(panel.expandAllButton)
    panel:onTreeRowClicked(panel.docTree.items[6].item) -- category:20_events
    checkEqual(kinds(panel),
        "category:,file:welcome,category:10_rules,file:rule1,file:rule2,"
            .. "category:20_events",
        "全部展開之後單獨收合一列，只有那一列收合")

    -- 還沒收到快照時兩顆按鈕就已經可以按：空樹不得拋錯。
    local emptyPanel = NBPanel:new()
    emptyPanel:createChildren()
    checkEqual(#emptyPanel.categoryOrder, 0, "前提：還沒收到快照時沒有任何分類")
    click(emptyPanel.collapseAllButton)
    click(emptyPanel.expandAllButton)
    checkEqual(#emptyPanel.docTree.items, 0, "空樹批次操作後仍是空樹，且不得拋錯")

    -- 宣告了卻沒有檔案的分類不得被批次操作復活成一列。
    local emptyCategoryPanel = NBPanel:new()
    emptyCategoryPanel:createChildren()
    emptyCategoryPanel:setSnapshot({ sid = "s",
        categories = { { key = "90_empty", label = "Empty" } },
        files = { file("only", "Only", "") } }, nil)
    click(emptyCategoryPanel.collapseAllButton)
    click(emptyCategoryPanel.expandAllButton)
    checkEqual(kinds(emptyCategoryPanel), "category:,file:only",
        "全部展開不得把空分類變出一列（可見列的來源仍是 categoryOrder）")
    checkEqual(emptyCategoryPanel.expandedCategories["90_empty"], nil,
        "空分類不在 categoryOrder 裡，展開狀態也不該被寫進去")

    UNREAD_IDS = {}
    READ_MARKS = {}
    SIDEBAR_PREFERENCE.value = savedPreferenceValue
    SIDEBAR_PREFERENCE.writes = 0
end)()

-- ---------------------------------------------------------------------------
-- A 設計稿的圖示（框架 Icons，API v1 rev>=2）：文件樹的 chevron／folder／document，
-- 以及工具列四顆按鈕的 sidebar／language／resetSize／reload。
-- 玩家實際會遇到三種環境，三種都要驗——圖示是外觀升級，缺了不能吃掉文字或操作：
--   I1 框架有能力但**資產缺**（服主換掉圖、檔名打錯、舊資產包）→ draw 回 false，退回 ASCII；
--   I2 資產齊全 → 圖示版面（座標、tint、按鈕加寬）；
--   I0 **舊框架**（rev 1）→ NBPanel 綁定期就當沒有圖示，資產在也一律 ASCII。
-- 順序刻意是 I1 -> I2 -> I0：I0 放在資產已註冊之後，才證明得了「擋的是 API 版本、不是資產」。
-- ---------------------------------------------------------------------------
;(function()
    local UI = MinidoracatUI.v1
    check(UI.API_REVISION >= 2 and UI.CAPABILITIES.icons == true and UI.Icons ~= nil,
        "前提：框架已發布 Icons（rev>=2 + capability + 模組），否則以下三段驗不到東西")

    -- 契約表（家族共用，見框架 repo 的 Icons 段）：key -> 檔名。任一邊改名這段就紅。
    local ICON_DIR = "media/ui/MinidoracatUI/"
    local ICON_FILES = {
        sidebar = "mui_icon_sidebar.png",
        folder = "mui_icon_folder.png",
        document = "mui_icon_document.png",
        chevronRight = "mui_icon_chevron_right.png",
        chevronDown = "mui_icon_chevron_down.png",
        language = "mui_icon_language.png",
        reload = "mui_icon_reload.png",
        resetSize = "mui_icon_reset_size.png",
    }
    local function iconPath(key)
        return ICON_DIR .. ICON_FILES[key]
    end
    -- NBSkin.reset() 連 Icons 的「載不到」黑名單一起清（框架的 Icons 與 Skin 共用同一份
    -- 貼圖快取），否則前面段落記下的 false 會讓 I2 永遠看不到圖示。
    local function setIconAssets(present)
        local key
        for key in pairs(ICON_FILES) do
            TEXTURE_SIZES[iconPath(key)] = present and { 32, 32 } or nil
        end
        NBSkin.reset()
    end

    local function file(id, title, category)
        return { id = id, title = title, category = category, h = id,
            content = "# " .. title }
    end
    local snapshot = { sid = "s",
        categories = { { key = "10_rules", label = "Rules" } },
        files = {
            file("welcome", "Welcome", ""),
            file("rule1", "No griefing", "10_rules"),
        } }
    -- items：1 = 語系根層分類、2 = file:welcome、3 = category:10_rules、4 = file:rule1

    -- 面板 + 一棵被攔下所有繪製呼叫的文件樹。drawRow 回傳這一列畫了哪些文字與貼圖。
    local function newPanel()
        local panel = NBPanel:new()
        panel:createChildren()
        panel:setSnapshot(snapshot, nil)
        local tree = panel.docTree
        local texts, images = {}, {}
        tree.drawRect = function() end
        tree.drawRectBorder = function() end
        tree.drawText = function(_, text, x, y, r, g, b)
            texts[#texts + 1] = { text = text, x = x, y = y,
                tint = string.format("%s,%s,%s", tostring(r), tostring(g), tostring(b)) }
        end
        tree.drawTextureScaled = function(_, texture, x, y, w, h, a, r, g, b)
            images[#images + 1] = { path = texture and texture.path, x = x, y = y,
                w = w, h = h,
                tint = string.format("%s,%s,%s", tostring(r), tostring(g), tostring(b)) }
        end
        local function drawRow(index)
            texts, images = {}, {}
            tree.items[index].index = index
            tree:doDrawItem(0, tree.items[index], false)
            return texts, images
        end
        return panel, tree, drawRow
    end

    -- I1：資產缺 → 版面與「從來沒有圖示」的舊版逐位相同
    setIconAssets(false)
    local panel, tree, drawRow = newPanel()
    local texts, images = drawRow(1)
    checkEqual(texts[1].text, "-", "I1 資產缺：分類記號退回 ASCII 的 -")
    checkEqual(texts[1].x, 6, "I1 資產缺：ASCII 記號留在原本的記號欄 x=6")
    checkEqual(texts[2].x, 18, "I1 資產缺：分類文字留在 x=18，不留圖示的空欄")
    checkEqual(#images, 0, "I1 資產缺：一顆圖示都不畫")
    texts = drawRow(2)
    checkEqual(texts[1].x, 26, "I1 資產缺：公告文字留在 x=26")
    checkEqual(panel.sidebarButton.iconTexture, nil, "I1 資產缺：側欄開關沒有 iconTexture")
    checkEqual(panel.langButton.iconTexture, nil, "I1 資產缺：語系按鈕沒有 iconTexture")
    checkEqual(panel.resetButton.iconTexture, nil, "I1 資產缺：重設大小按鈕沒有 iconTexture")
    checkEqual(panel.expandAllButton.iconTexture, nil,
        "I1 資產缺：全部展開沒有 iconTexture（純文字按鈕照樣可按）")
    checkEqual(panel.collapseAllButton.iconTexture, nil,
        "I1 資產缺：全部收合沒有 iconTexture")
    local plainSidebarWidth = panel.sidebarButton.width
    local plainLangWidth = panel.langButton.width
    local plainExpandWidth = panel.expandAllButton.width
    local plainCollapseWidth = panel.collapseAllButton.width


    -- 核心 tree icon 任一張缺失時整棵退回文字，避免分類有圖示縮排、公告卻比它更靠左。
    setIconAssets(true)
    TEXTURE_SIZES[iconPath("document")] = nil
    NBSkin.reset()
    panel, tree, drawRow = newPanel()
    texts, images = drawRow(1)
    checkEqual(texts[1].text, "-", "I1 單張 document 缺失時整棵 tree 退回 ASCII")
    texts = drawRow(2)
    checkEqual(texts[1].x, 26, "I1 單張缺失時公告文字也回純文字縮排，不與分類倒置")
    -- I2：資產齊全 → 圖示版面
    setIconAssets(true)
    panel, tree, drawRow = newPanel()
    texts, images = drawRow(1)
    checkEqual(#texts, 1, "I2 分類列只剩標籤一段文字（ASCII 記號由 chevron 取代）")
    checkEqual(texts[1].x, 38, "I2 分類文字讓開 chevron 與 folder（x=38）")
    checkEqual(#images, 2, "I2 展開中的分類 = chevron + folder 兩顆圖示")
    checkEqual(images[1].path, iconPath("chevronDown"), "I2 展開中的分類畫 chevronDown")
    check(images[1].x == 4 and images[1].y == 5 and images[1].w == 14 and images[1].h == 14,
        "I2 chevron 落在 (4, 列高 24 置中 → 5)、邊長 14")
    checkEqual(images[2].path, iconPath("folder"), "I2 分類的第二顆圖示是 folder")
    checkEqual(images[2].x, 20, "I2 folder 接在 chevron 右側（x=20）")
    checkEqual(images[1].tint, "0.7,0.7,0.7", "I2 未選中列的圖示染 TAB_TEXT_UNSELECTED")
    checkEqual(texts[1].tint, images[1].tint,
        "I2 圖示必須與同列文字同色，否則圖示看起來像壞掉的資產")

    panel:onTreeRowClicked(tree.items[3].item) -- 收合 10_rules
    texts, images = drawRow(3)
    checkEqual(images[1].path, iconPath("chevronRight"), "I2 收合中的分類畫 chevronRight")

    texts, images = drawRow(2) -- file:welcome（預設選中）
    checkEqual(images[1].path, iconPath("document"), "I2 公告列畫 document")
    checkEqual(images[1].x, 22, "I2 document 落在 folder 與分類文字之間（x=22）")
    checkEqual(texts[1].x, 40, "I2 公告文字讓開 document（x=40）")
    checkEqual(images[1].tint, "1,1,1", "I2 選中的公告列圖示染 TAB_TEXT_SELECTED")

    checkEqual(panel.sidebarButton.iconTexture.path, iconPath("sidebar"),
        "I2 側欄開關掛 sidebar 圖示")
    checkEqual(panel.sidebarButton.joypadTextureWH, 14,
        "I2 圖示尺寸走原生 joypadTextureWH（預設 32 對 24px 高的工具列太大）")
    checkEqual(panel.langButton.iconTexture.path, iconPath("language"),
        "I2 語系按鈕掛 language 圖示")
    checkEqual(panel.resetButton.iconTexture.path, iconPath("resetSize"),
        "I2 重設大小按鈕掛 resetSize 圖示")
    checkEqual(panel.sidebarButton.width - plainSidebarWidth, 19,
        "I2 有圖示的按鈕寬 = 純文字寬 + 圖示 14 + 原生間距 5")
    checkEqual(panel.langButton.width - plainLangWidth, 19,
        "I2 加寬規則對每顆按鈕都一樣（少加會把標題推出按鈕右緣）")
    checkEqual(panel.expandAllButton.iconTexture.path, iconPath("chevronDown"),
        "I2 全部展開掛 chevronDown（與展開中的分類列同一張資產）")
    checkEqual(panel.collapseAllButton.iconTexture.path, iconPath("chevronRight"),
        "I2 全部收合掛 chevronRight（與收合中的分類列同一張資產）")
    checkEqual(panel.expandAllButton.joypadTextureWH, 14,
        "I2 批次按鈕的圖示尺寸與其他工具列按鈕一致")
    checkEqual(panel.collapseAllButton.joypadTextureWH, 14,
        "I2 兩顆批次按鈕的圖示尺寸都不得留在原生預設 32")
    checkEqual(panel.expandAllButton.width - plainExpandWidth, 19,
        "I2 全部展開的加寬規則與其他按鈕相同")
    checkEqual(panel.collapseAllButton.width - plainCollapseWidth, 19,
        "I2 全部收合的加寬規則與其他按鈕相同")
    -- 左組順序（由左往右）：目錄 -> 全部展開 -> 全部收合。順序寫成斷言是因為它是
    -- 肌肉記憶，而且三顆的功能相鄰（都只動目錄的可見範圍），接錯位置玩家會按錯。
    checkEqual(panel.sidebarButton:getX(), 6,
        "I2 目錄仍貼在工具列最左（左緣留一個 6px 間距）")
    checkEqual(panel.expandAllButton:getX(),
        panel.sidebarButton:getX() + panel.sidebarButton:getWidth() + 6,
        "I2 全部展開緊接在目錄右邊（間距與其他按鈕相同）")
    checkEqual(panel.collapseAllButton:getX(),
        panel.expandAllButton:getX() + panel.expandAllButton:getWidth() + 6,
        "I2 全部收合緊接在全部展開右邊")
    check(panel.expandAllButton.anchorLeft == true
        and panel.expandAllButton.anchorRight == false,
        "I2 批次按鈕錨左：視窗變寬時留在目錄旁邊，不跟著右緣跑")
    -- 範例包會寫伺服器磁碟，非 admin 連按鈕都不該有（server 端仍是權威）
    checkEqual(panel.examplesButton, nil, "I2 非 admin 不得建立範例按鈕")
    checkEqual(panel.reloadButton, nil, "前提檢查：非 admin 同樣沒有重新載入按鈕")

    -- SP／本地權威端沒有 player-targeted ack 收件人，admin 字串即使存在也不能建立兩顆
    -- 永遠無反應的網路操作按鈕。
    local savedAccess = _G.getAccessLevel
    local savedIsClient = _G.isClient
    _G.getAccessLevel = function() return "admin" end
    _G.isClient = function() return false end
    local localAdminPanel = NBPanel:new()
    localAdminPanel:createChildren()
    checkEqual(localAdminPanel.adminVisible, false,
        "非 client 環境不得把 admin 網路操作標成可見")
    checkEqual(localAdminPanel.examplesButton, nil,
        "非 client 環境不得建立重建範例按鈕")
    checkEqual(localAdminPanel.reloadButton, nil,
        "非 client 環境不得建立重新載入按鈕")
    _G.isClient = savedIsClient

    -- 重新載入只有 admin 看得到，單獨換一次權限建面板
    _G.getAccessLevel = function() return "admin" end
    local adminPanel = NBPanel:new()
    adminPanel:createChildren()
    _G.getAccessLevel = savedAccess
    checkEqual(adminPanel.reloadButton.iconTexture.path, iconPath("reload"),
        "I2 admin 的重新載入按鈕掛 reload 圖示")
    checkEqual(adminPanel.examplesButton.iconTexture.path, iconPath("folder"),
        "I2 admin 的範例按鈕掛 folder 圖示（與文件樹的分類同一張資產）")
    checkEqual(adminPanel.examplesButton.joypadTextureWH, 14,
        "I2 範例按鈕的圖示尺寸與其他工具列按鈕一致")
    -- 右側順序（addToolbarButton 由右往左排）：重新載入最右、範例在它左邊，
    -- 再往左是重設大小與語系。順序寫成斷言是因為它是肌肉記憶：每天要按的那顆留在最右。
    checkEqual(adminPanel.width - 6 - adminPanel.reloadButton:getWidth(),
        adminPanel.reloadButton:getX(),
        "I2 重新載入必須貼在工具列最右（右緣留一個 6px 間距）")
    check(adminPanel.examplesButton:getX() + adminPanel.examplesButton:getWidth()
        < adminPanel.reloadButton:getX(),
        "I2 範例按鈕必須排在重新載入的左邊")
    check(adminPanel.resetButton:getX() + adminPanel.resetButton:getWidth()
        < adminPanel.examplesButton:getX(),
        "I2 重設大小必須排在範例按鈕的左邊")
    check(adminPanel.langButton:getX() + adminPanel.langButton:getWidth()
        < adminPanel.resetButton:getX(),
        "I2 語系必須排在重設大小的左邊（右側整組維持既有相對順序）")
    check(adminPanel.minimumWidth > panel.minimumWidth,
        "I2 多一顆 admin 按鈕必須把動態 minimumWidth 一起撐大，否則工具列會重疊")
    -- 左組的右緣是**最右那顆**（全部收合），不是側欄開關：拿側欄開關算會少算兩顆按鈕，
    -- 左右兩組就會在預設寬度下重疊。
    check(adminPanel.voiceButton:getX() + adminPanel.voiceButton:getWidth()
        < adminPanel.langButton:getX(), "voice and notice language buttons do not overlap")
    check(adminPanel.collapseAllButton:getX() + adminPanel.collapseAllButton:getWidth() + 6
        <= adminPanel.voiceButton:getX(),
        "I2 預設寬度下左／右工具列群不得重疊")

    -- 小畫面／大字型／admin 四鈕：建立當下就要把目前寬度夾到動態 minimum，
    -- 不能只改限制值後仍讓這一幀維持重疊。
    local savedScreenW, savedScreenH = SCREEN_WIDTH, SCREEN_HEIGHT
    SCREEN_WIDTH, SCREEN_HEIGHT = 640, 480
    _G.getAccessLevel = function() return "admin" end
    local narrowAdmin = NBPanel:new()
    narrowAdmin:createChildren()
    _G.getAccessLevel = savedAccess
    check(narrowAdmin.minimumWidth > 460,
        "I2 640×480 admin 工具列需要的動態 minimumWidth 應高於 72% 預設寬 460")
    checkEqual(narrowAdmin.width, narrowAdmin.minimumWidth,
        "I2 createChildren 必須立即把目前寬度夾到動態 minimumWidth")
    narrowAdmin:setWidth(700)
    narrowAdmin:resetToDefaultSize()
    checkEqual(narrowAdmin.width, narrowAdmin.minimumWidth,
        "I2 重設大小也不得把面板重新縮回工具列會重疊的寬度")
    SCREEN_WIDTH, SCREEN_HEIGHT = savedScreenW, savedScreenH

    -- 真實 vscroll：捲軸出現時文字留白與未讀點一起讓開 17px。原生 stencil 右緣收到
    -- vscroll.x + 3 = 寬-13（ISScrollingListBox.lua:494-496），而紅點原本從 寬-14 起、
    -- 邊長 8——只剩 1px 露在裁切範圍內，看起來就是紅點消失了。
    UNREAD_IDS.rule1 = true
    panel, tree, drawRow = newPanel()
    texts, images = drawRow(4) -- file:rule1（未讀、未選中）
    checkEqual(images[#images].x, 300 - 14, "捲軸不可見時未讀點仍在 width-14")
    local availableNoScroll = tree.items[4].item.fitWidth
    tree.height = 48
    tree.vscroll = {
        x = tree.width - 16,
        width = 17,
        height = tree.height,
        getWidth = function(self) return self.width end,
        getHeight = function(self) return self.height end,
    }
    check(tree:isVScrollBarVisible(), "vscroll 必須由實際 scrollHeight > viewport 觸發")
    local stencilRect = nil
    tree.setStencilRect = function(_, x, y, w, h)
        stencilRect = { x = x, y = y, w = w, h = h }
    end
    tree.clearStencilRect = function() end
    tree:prerender()
    check(stencilRect ~= nil and stencilRect.w == tree.width - 13,
        "原生 listbox prerender 在 vscroll 可見時把 stencil 右緣收到 width-13")
    texts, images = drawRow(4)
    checkEqual(images[#images].x, 300 - 17 - 14,
        "捲軸可見時未讀點左移 17px（避開 stencil 右緣，不被裁掉）")
    checkEqual(tree.items[4].item.fitWidth, availableNoScroll - 17,
        "捲軸可見時文字可用寬同步少 17px（紅點與文字之間的 6px 間距不變）")
    tree.vscroll = nil
    UNREAD_IDS = {}

    -- I0：舊框架（rev 1）→ 綁定期就當沒有圖示。資產仍註冊著，所以擋的是 API 版本。
    local savedRevision = UI.API_REVISION
    UI.API_REVISION = 1
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBPanel.lua") -- Icons 綁定重算：此環境下為 nil
    panel, tree, drawRow = newPanel()
    texts, images = drawRow(1)
    checkEqual(texts[1].text, "-", "I0 舊框架：分類記號退回 ASCII，資產在也不畫圖示")
    checkEqual(texts[2].x, 18, "I0 舊框架：分類文字留在 x=18")
    checkEqual(#images, 0, "I0 舊框架：不畫任何圖示")
    checkEqual(panel.sidebarButton.iconTexture, nil, "I0 舊框架：工具列按鈕沒有 iconTexture")
    checkEqual(panel.sidebarButton.width, plainSidebarWidth,
        "I0 舊框架：按鈕寬回到純文字寬（不留圖示的空欄）")
    checkEqual(panel.collapseAllButton.iconTexture, nil,
        "I0 舊框架：批次按鈕同樣沒有 iconTexture")
    checkEqual(panel.collapseAllButton.width, plainCollapseWidth,
        "I0 舊框架：批次按鈕寬回到純文字寬")
    UI.API_REVISION = savedRevision
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBPanel.lua") -- 還原正常綁定
    setIconAssets(false)
end)()

-- ---------------------------------------------------------------------------
-- 重建範例按鈕的互動（按鈕 -> 語系選單 -> 送出）與六則 toast。
-- 這顆按鈕會**直接覆寫伺服器 live tree** 的 categories.txt、README.txt 與選定語系的
-- 三份公告，所以互動契約本身就是安全機制：
--   * 按下按鈕**不得送出任何東西**，只開一個選單（誤觸不該覆寫服主的分類設定）；
--   * 選單恰好兩項（CH／EN），兩項的文字都必須明說會覆寫 categories.txt；
--   * 選了哪個語系就必須送哪個語系（接錯參數＝重建錯語系，服主的公告被換掉）；
--   * 送出成功／送不出去各一則 toast（送出 != 伺服器已寫好）；
--   * server 的四種結果各一則，成功那則必須把檔數帶進文字；
--   * 非 admin 呼叫任一入口都不得送出（按鈕本來就不存在，這是第二層）。
-- getText 的 stub 平常只回 "[key]"，這一段臨時換成會把參數接在後面的版本——
-- 否則「成功幾檔」與「送出的是哪個語系」進不進 toast 完全驗不到。
-- ---------------------------------------------------------------------------
;(function()
    local savedAccess = _G.getAccessLevel
    local savedGetText = _G.getText
    local savedToastShow = NBToast.show
    local toasts = {}
    NBToast.show = function(message)
        toasts[#toasts + 1] = message
    end
    _G.getText = function(key, ...)
        local parts = { tostring(key) }
        local values = { ... }
        local index
        for index = 1, #values do
            parts[#parts + 1] = tostring(values[index])
        end
        return "[" .. table.concat(parts, "|") .. "]"
    end

    local function resetRequests()
        EXAMPLE_REQUESTS.count = 0
        EXAMPLE_REQUESTS.langs = {}
        CONTEXT_MENUS.list = {}
        toasts = {}
    end

    _G.getAccessLevel = function() return "admin" end
    local panel = NBPanel:new()
    panel:createChildren()

    -- 按鈕的 callback 必須真的是 onExamples：測試若自己直接呼叫 onExamples，
    -- 接錯 callback（例如貼上成 onReload）這一段就完全看不出來。
    checkEqual(panel.examplesButton.onclick, NBPanel.onExamples,
        "重建範例按鈕的 callback 必須是 NBPanel.onExamples")
    checkEqual(panel.examplesButton.title, "[IGUI_MinidoracatNB_Examples]",
        "重建範例按鈕的標題走自己的翻譯鍵")

    -- --- 1. 按一下只開選單，**零送出** ------------------------------------------
    resetRequests()
    EXAMPLE_REQUESTS.allow = true
    panel.examplesButton.onclick(panel, panel.examplesButton)
    checkEqual(EXAMPLE_REQUESTS.count, 0,
        "按下按鈕不得送出任何請求（誤觸不該覆寫伺服器的 categories.txt）")
    checkEqual(#toasts, 0, "按下按鈕不得出 toast（還沒送出任何東西）")
    checkEqual(#CONTEXT_MENUS.list, 1, "按下按鈕必須恰好開一個原生 context menu")

    local menu = CONTEXT_MENUS.list[1]
    checkEqual(#menu.options, 2, "選單必須恰好兩項（CH／EN），不得列出其他語系")
    checkEqual(menu.options[1].title, "[IGUI_MinidoracatNB_ExamplesLangCH]",
        "第一項是繁體中文，走自己的翻譯鍵")
    checkEqual(menu.options[2].title, "[IGUI_MinidoracatNB_ExamplesLangEN]",
        "第二項是 English，走自己的翻譯鍵")
    local optionIndex
    for optionIndex = 1, #menu.options do
        checkEqual(menu.options[optionIndex].callback,
            NBPanel.onExamplesLanguageSelected,
            "選單每一項都必須接到 onExamplesLanguageSelected（接錯就重建錯東西）")
        checkEqual(menu.options[optionIndex].target, panel,
            "選單每一項的 target 必須是面板自己")
    end
    checkEqual(menu.options[1].param, "CH", "第一項必須帶 CH")
    checkEqual(menu.options[2].param, "EN", "第二項必須帶 EN")
    -- 選單開在按鈕正下方（與語系選單同一套定位）
    checkEqual(menu.x, panel.examplesButton:getAbsoluteX(),
        "選單必須對齊按鈕左緣")
    checkEqual(menu.y,
        panel.examplesButton:getAbsoluteY() + panel.examplesButton:getHeight(),
        "選單必須開在按鈕正下方")

    -- --- 2. 兩個語系各選一次：送出的語系必須與選項一致 ---------------------------
    local SELECTED = { "CH", "EN" }
    local selectIndex
    for selectIndex = 1, #SELECTED do
        local language = SELECTED[selectIndex]
        resetRequests()
        panel.examplesButton.onclick(panel, panel.examplesButton)
        local option = CONTEXT_MENUS.list[1].options[selectIndex]
        option.callback(option.target, option.param)
        checkEqual(EXAMPLE_REQUESTS.count, 1,
            "選了語系才送出，而且恰好一次：" .. language)
        checkEqual(EXAMPLE_REQUESTS.langs[1], language,
            "送出的語系必須就是選單那一項帶的值：" .. language)
        checkEqual(#toasts, 1, "送出後必須有一則回饋：" .. language)
        checkEqual(toasts[1], "[IGUI_MinidoracatNB_ExamplesSent|" .. language .. "]",
            "送出成功顯示『已送出』並帶語系（連按兩次不同語系要分得出來）：" .. language)
    end

    -- --- 3. 送不出去（網路層拋錯／client 端語系驗證失敗） -----------------------
    resetRequests()
    EXAMPLE_REQUESTS.allow = false
    panel:onExamplesLanguageSelected("CH")
    checkEqual(EXAMPLE_REQUESTS.count, 1, "送出失敗仍必須真的嘗試過一次")
    checkEqual(toasts[1], "[IGUI_MinidoracatNB_ExamplesSendFailed]",
        "送不出去必須明說，不得靜默（否則分不出按鈕壞了還是伺服器沒反應）")
    EXAMPLE_REQUESTS.allow = true

    -- --- 4. 原生端沒有可用的 context menu -------------------------------------
    resetRequests()
    CONTEXT_MENUS.allow = false
    local menuOk = pcall(function()
        panel.examplesButton.onclick(panel, panel.examplesButton)
    end)
    CONTEXT_MENUS.allow = true
    check(menuOk, "ISContextMenu.get 回 nil 時不得拋錯")
    checkEqual(EXAMPLE_REQUESTS.count, 0, "開不出選單時不得改成直接送出")
    checkEqual(#toasts, 0, "開不出選單時不得出誤導的 toast")

    -- --- 5. 權限當場被撤掉：按鈕還在畫面上，但兩個入口都不得動作 ----------------
    resetRequests()
    _G.getAccessLevel = function() return "None" end
    panel:onExamples(panel.examplesButton)
    checkEqual(#CONTEXT_MENUS.list, 0, "非 admin 不得開出重建範例選單")
    panel:onExamplesLanguageSelected("CH")
    checkEqual(EXAMPLE_REQUESTS.count, 0, "非 admin 不得送出重建範例請求")
    checkEqual(#toasts, 0, "非 admin 的點擊不得留下任何 toast")
    _G.getAccessLevel = function() return "admin" end

    -- --- 6. server 的四種結果：走的是真正註冊上去的那個 handler -----------------
    toasts = {}
    NBPanel.onExamplesStatus({ kind = "success", count = 5 })
    checkEqual(toasts[1], "[IGUI_MinidoracatNB_ExamplesDone|5]",
        "成功的 toast 必須帶上實際寫出的檔數")

    toasts = {}
    NBPanel.onExamplesStatus({ kind = "failed" })
    checkEqual(toasts[1], "[IGUI_MinidoracatNB_ExamplesWriteFailed]",
        "伺服器寫入失敗必須有自己的訊息（不可與送出失敗共用）")

    toasts = {}
    NBPanel.onExamplesStatus({ kind = "cooldown" })
    checkEqual(toasts[1], "[IGUI_MinidoracatNB_ExamplesCooldown]",
        "冷卻中必須明說，不得看起來像成功")

    toasts = {}
    NBPanel.onExamplesStatus({ kind = "forbidden" })
    checkEqual(toasts[1], "[IGUI_MinidoracatNB_ExamplesForbidden]",
        "權限不足必須明說")

    -- 形狀壞掉不得炸面板、也不得出無意義的 toast
    toasts = {}
    NBPanel.onExamplesStatus(nil)
    NBPanel.onExamplesStatus("success")
    NBPanel.onExamplesStatus({})
    NBPanel.onExamplesStatus({ kind = "partial" })
    checkEqual(#toasts, 0, "不認識的狀態 payload 一律不出 toast")

    CONTEXT_MENUS.list = {}
    EXAMPLE_REQUESTS.count = 0
    EXAMPLE_REQUESTS.langs = {}
    _G.getAccessLevel = savedAccess
    _G.getText = savedGetText
    NBToast.show = savedToastShow
end)()

-- Real ISSliderPanel input -> existing volume option -> local preview.
;(function()
    local savedManager, savedToast, savedSandbox = getSoundManager, NBToast.show, SandboxVars
    local active, played, messages = {}, 0, {}
    local emitter = {
        setVolume = function(_, ref, volume) active[ref].volume = volume end,
        stopSoundLocal = function(_, ref) active[ref] = nil end,
    }
    _G.getSoundManager = function()
        return {
            getUIEmitter = function() return emitter end,
            playUISound = function(_, name)
                played = played + 1
                active[played] = { name = name, volume = 1 }
                return played
            end,
        }
    end
    NBToast.show = function(message) messages[#messages + 1] = message end
    _G.SandboxVars = {}
    SOUND_VOLUME.value, SOUND_VOLUME.saves = 1, 0
    local panel = NBPanel:new()
    panel:createChildren()
    local slider = panel.volumeSlider
    slider.parent = panel
    panel:onVoiceLanguageSelected("EN")
    checkEqual(active[1].name, "MinidoracatNBVoiceEN", "language selection previews immediately")
    panel:onVoiceLanguageSelected("JP")
    check(active[1] == nil and active[2].name == "MinidoracatNBVoiceJP",
        "new selection replaces only the previous preview")

    local bar = slider.sliderBarDim
    slider:onMouseDown(bar.x + bar.w, 5)
    checkEqual(SOUND_VOLUME.value, 1, "grabbing the current knob does not change volume")
    checkEqual(active[2], nil, "same-value drag still stops the preceding sample")
    slider.getMouseX = function() return bar.x + bar.w * 0.25 end
    slider:onMouseMove(0, 0)
    checkEqual(SOUND_VOLUME.value, 0.25, "drag changes live volume")
    checkEqual(SOUND_VOLUME.saves, 0, "drag does not write on each pointer movement")
    check(active[2] == nil, "drag stops the old sample before changing volume")
    slider.getMouseX = function() return bar.x + bar.w * 0.75 end
    slider:onMouseMoveOutside(0, 0)
    checkEqual(SOUND_VOLUME.value, 0.75, "native outside drag changes live volume")
    slider:onMouseUpOutside(0, 0)
    checkEqual(SOUND_VOLUME.saves, 1, "outside release saves once")
    checkEqual(active[3].volume, 0.75, "release previews at the final volume")
    slider:onJoypadDirLeft()
    check(active[3] == nil and active[4].volume == 0.7,
        "joypad adjustment replaces preview at the new volume")
    slider:onMouseDown(bar.x, 5)
    slider:onMouseUp(0, 0)
    checkEqual(played, 4, "zero percent stops preview without starting a new sound")
    checkEqual(active[4], nil, "zero percent silences the preceding sample")
    check(contains(messages[#messages], "PreviewMuted"), "mute produces visible feedback")
    _G.SandboxVars = { MinidoracatNB = { NotifySound = false } }
    slider:onJoypadDirRight()
    checkEqual(played, 4, "server mute applies to manual previews")
    _G.SandboxVars = {}
    panel:onVoiceLanguageSelected("EN")
    checkEqual(played, 5, "positive volume can preview again")
    panel:setVisible(false)
    checkEqual(active[5], nil, "closing the panel stops its sample")

    -- Java visibility changes do not call NBPanel:setVisible.
    local visible = true
    panel.getIsVisible = function() return visible end
    panel:onVoiceLanguageSelected("EN")
    visible = false
    panel:update()
    checkEqual(active[6], nil, "native Toggle UI stops the sample through update")
    visible = true
    local savedCount = SOUND_VOLUME.saves
    slider:onMouseDown(bar.x + bar.w * 0.25, 5)
    visible = false
    panel:update()
    checkEqual(SOUND_VOLUME.saves, savedCount + 1, "hiding mid-drag commits once without preview")
    visible = true
    slider.getMouseX = function() return bar.x + bar.w * 0.9 end
    slider:onMouseMove(0, 0)
    panel:update()
    checkEqual(SOUND_VOLUME.value, 0.25, "showing UI again cannot continue a released drag")
    checkEqual(SOUND_VOLUME.saves, savedCount + 1, "visibility recovery does not save twice")
    checkEqual(played, 6, "native hiding never starts a preview")

    local drawn = {}
    slider.drawText = function(_, text) drawn[#drawn + 1] = text end
    SOUND_VOLUME.value = 0.45
    slider:render()
    checkEqual(drawn[#drawn], "45%", "slider reflects changes from the other settings surface")
    panel.isCollapsed = true
    drawn = {}
    slider:render()
    checkEqual(#drawn, 0, "collapsed panel does not render slider labels")
    check(panel.voiceButton:getX() + panel.voiceButton:getWidth() < slider:getX()
        and slider:getX() + slider:getWidth() < panel.langButton:getX(),
        "voice, volume and text-language controls do not overlap")
    _G.getSoundManager = savedManager
    NBToast.show, _G.SandboxVars = savedToast, savedSandbox
    SOUND_VOLUME.value, VOICE_PREFERENCE.value = 1, "chime"
end)()

-- Native ModOptions serialization: one volume source, verified saves and retry.
;(function()
    local savedOptions, savedAPI = NBOptions, PZAPI
    local savedReader, savedWriter, savedSplit = getFileReader, getFileWriter, luautils.split
    local disk = "slider|MinidoracatNoticeBoard|sound_volume|60\n"
        .. "tickbox|Other|enabled|false\n"
    local writes, dropWrites, failReads = 0, false, false
    _G.getFileReader = function(path)
        assert(path == "ModOptions.ini")
        if failReads then error("read unavailable") end
        local lines = string.gmatch(disk, "[^\r\n]+")
        return { readLine = function() return lines() end, close = function() end }
    end
    _G.getFileWriter = function(path)
        assert(path == "ModOptions.ini")
        writes = writes + 1
        local text = ""
        return {
            write = function(_, value) text = text .. value end,
            close = function() if not dropWrites then disk = text end end,
        }
    end
    luautils.split = string.split
    dofile(VANILLA_LUA .. "/client/PZAPI/ModOptions.lua")
    local other = PZAPI.ModOptions:create("Other", "Other")
    other:addTickBox("enabled", "Enabled", true)
    _G.NBOptions = nil
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBOptions.lua")
    checkEqual(NBOptions.volumePercent(), 60, "load existing volume from native settings")
    check(NBOptions.setVolumePercent(25, false), "live adjustment accepted")
    checkEqual(NBOptions.soundVolume(), 0.25, "live adjustment affects notification gain")
    checkEqual(writes, 0, "uncommitted adjustment never saves")
    check(NBOptions.setVolumePercent(75, true), "committed volume verifies on disk")
    other:getOption("enabled"):setValue(true) -- Clear the live value before testing durable reload.
    PZAPI.ModOptions:load()
    checkEqual(NBOptions.volumePercent(), 75, "native reload restores committed volume")
    checkEqual(other:getOption("enabled"):getValue(), false, "save preserves other mods' settings")
    dropWrites = true
    checkEqual(NBOptions.setVolumePercent(80, true), false, "silent write loss is reported")
    checkEqual(NBOptions.volumePercent(), 80, "failed save retains the live adjustment")
    dropWrites = false
    check(NBOptions.setVolumePercent(80, true), "same value can retry a failed save")
    NBOptions._options:getOption(NBOptions.SOUND_ENABLED):setValue(false)
    checkEqual(NBOptions.volumePercent(), 80, "muting does not erase the configured volume")
    checkEqual(NBOptions.soundVolume(), 0, "muting still disables playback")
    checkEqual(NBOptions.setVolumePercent(0 / 0, true), false, "NaN never enters native settings")
    check(NBOptions.setVolumePercent(200, true), "out-of-range volume is clamped")
    checkEqual(NBOptions.volumePercent(), 100, "volume cannot exceed 100 percent")
    failReads = true
    _G.NBOptions = nil
    dofile(MEDIA_LUA .. "client/NoticeBoard/NBOptions.lua")
    local previousWrites = writes
    checkEqual(NBOptions.setVolumePercent(35, true), false, "failed initial load blocks saving")
    checkEqual(writes, previousWrites, "failed load cannot overwrite unread settings")
    failReads = false
    check(NBOptions.setVolumePercent(35, true), "user can retry after an initial load failure")
    checkEqual(NBOptions.volumePercent(), 35, "retry restores editable volume")
    _G.NBOptions, _G.PZAPI = savedOptions, savedAPI
    _G.getFileReader, _G.getFileWriter, luautils.split = savedReader, savedWriter, savedSplit
end)()

print("Step 2 tests passed: " .. assertionCount .. " assertions")
