require "ISUI/ISCollapsableWindowJoypad"
require "ISUI/ISRichTextPanel"
require "ISUI/ISButton"
require "ISUI/ISContextMenu"
require "ISUI/ISLayoutManager"

if not NBCore then
    require "NoticeBoard/NBCore"
end
if not MDParser then
    require "NoticeBoard/MDParser"
end
if not NBClient then
    require "NoticeBoard/NBClient"
end
if not NBImageCache then
    require "NoticeBoard/NBImageCache"
end
if not NBToast then
    require "NoticeBoard/NBToast"
end
if not NBSkin then
    require "NoticeBoard/NBSkin"
end
if not NBOptions then
    require "NoticeBoard/NBOptions"
end

local Core = NBCore
local Parser = MDParser
local Client = NBClient
local ImageCache = NBImageCache
local Skin = NBSkin
local Options = NBOptions
if not Core or not Parser or not Client or not ImageCache or not NBToast or not Skin
    or not Options then
    error("NoticeBoard UI dependencies failed to load")
end

NBPanel = ISCollapsableWindowJoypad:derive("NBPanel")

-- 色票的唯一權威來源在 NBSkin.COLORS（三個 UI 檔共用；docs/UI_DESIGN.md §0）
local COLORS = Skin.COLORS

-- 預設尺寸取螢幕比例，讓各種解析度都佔差不多的視覺比重（固定像素在 1080p 剛好、在 4K 會小得可笑）。
-- 但寬高都要設上限：純文字一行太長就難讀了，不能讓 4K 開出一條橫幅。
-- 玩家調整過尺寸後由 ISLayoutManager 記憶（layout.ini），這裡只影響「沒有既有紀錄」的第一次開窗；
-- 已經開過面板的玩家要按「重設大小」才會吃到新的預設值（同一份 defaultSize()）。
-- 比例從 0.52/0.68 調到 0.62/0.80（1080p：998×734 -> 1190×864）：實測 998 寬在有圖的公告上
-- 一開就得手動拉大，而 864 高把可見內文從 ~24 行拉到 ~29 行。上限同步從 1100×820 提到
-- 1280×960：1280 扣掉左右 margin 10＋捲軸 13 後文字寬約 1247，仍在單行可讀範圍內，
-- 4K 也不至於只佔畫面三分之一。
local DEFAULT_WIDTH_RATIO = 0.62
local DEFAULT_HEIGHT_RATIO = 0.80
local MAX_DEFAULT_WIDTH = 1280
local MAX_DEFAULT_HEIGHT = 960
local SCREEN_MARGIN = 80
local MINIMUM_WIDTH = 420
local MINIMUM_HEIGHT = 260
local TAB_BUTTON_GAP = 6
local SCROLLBAR_WIDTH = 13
local LINK_TOOLTIP_PAD = 6
local POPUP_WAIT_MS = 10000
local POPUP_ALWAYS = 1
local POPUP_UNREAD = 2
local POPUP_NEVER = 3
-- 新公告提示音。**MOD 自帶的音檔，不是遊戲內建音效**：檔案在
-- 42/media/sound/MinidoracatNBNotify.wav，且**是可替換的資產**——服主自備的素材由
-- scripts/prep_notify_sound.py 處理成合規音檔（修剪／單聲道／壓峰值／淡入淡出），
-- 不想用外部素材時 scripts/gen_notify_sound.py 能生一顆原創的上升琶音頂上。
-- 替換方式與授權責任見 docs/ADMIN_GUIDE.md「換掉提示音」。
-- 這條路不需要 FMOD bank：GameSounds.getSound(name) 找不到 event:/<name> 時會依序探測
-- media/sound/<name>.ogg 與 .wav（GameSounds.java:95-137），命中就建一個 file clip；
-- 播放走 FMODSoundEmitter 的 file 分支（:968-998）掛在 channel group "InGameNonBank"
-- （FMODManager.java:156）。**音效名＝檔名（不含副檔名），而且只能放在 media/sound/ 正下方**
-- ——那個 fallback 沒有子目錄，所以檔名帶 MOD 前綴避免與其他 MOD 撞名。
-- 音量（決定了生成端把 PEAK 壓在 0.32 的理由）：file 音效的 channel 音量每幀被設成
-- emitter volume x clip.volume x gameSound.userVolume（FMODSoundEmitter.java:1242 的
-- FileSound.tick -> :1559-1562 getVolume -> GameSoundClip.java:68-70 getEffectiveVolume），
-- 而這三個因子在本 MOD 的情境**全是 1.0**：playClip 固定傳 1.0（FMODSoundEmitter.java:495-498）、
-- non-bank fallback 建的 clip 沒設 volume（預設 1.0，GameSoundClip.java:18）、userVolume 要
-- enableAdvancedSoundOptions 才非 1.0 而那個旗標全庫沒有任何呼叫點設 true
-- （SystemDisabler.java:20,67-72；MainOptions.lua:2130 的逐音效音量 UI 因此永不顯示）。
-- 另一邊，玩家的「音效音量」選項是 FMOD Studio 的 VCA vca:/Settings_Sfx
-- （SoundManager.java:783-790），只作用於 event 音效，而 file 音效掛在 channel group
-- InGameNonBank（FMODManager.java:156，該 group 只被 pause/unpause 操作，
-- SoundManager.java:320,332,336）——**不經那條 VCA**。
-- 也就是說：這條路的音量基準就是音檔本身的振幅（所以資產端把峰值壓在 0.32），
-- 而**執行期的音量與開關在玩家手上**——playNoticeSound 讀 NBOptions（遊戲的
-- 「選項 -> MODS」分頁）後，用 playUISound 回傳的 instance ref 呼叫
-- getUIEmitter():setVolume 套用 0..1 的倍率（細節見該函式的註解）。
-- 沙盒 NotifySound 則是服主端的總開關，與玩家設定是 AND 關係。
local NOTIFY_SOUND = "MinidoracatNBNotify"
local LAYOUT_NAME = "MinidoracatNBPanel"

local OFFICIAL_URL_ROOTS = {
    "https://steamcommunity.com",
    "https://projectzomboid.com",
    "https://theindiestone.com",
    "https://pzwiki.net",
}

local function trim(text)
    text = string.gsub(text or "", "^%s+", "")
    return string.gsub(text, "%s+$", "")
end

local function normalizeVisibleText(text)
    text = tostring(text or "")
    text = string.gsub(text, "<[A-Z][A-Z0-9_]*:[^<>]*>", "")
    text = string.gsub(text, "<[A-Z][A-Z0-9_]*>", "")
    text = string.gsub(text, "&lt;", "<")
    text = string.gsub(text, "&gt;", ">")
    text = string.gsub(text, "%s+", " ")
    return trim(text)
end

-- 清單項開頭的記號不是連結文字的一部分：無序是 MDParser 統一產生的 "- "，
-- 有序是自動編號的 "n. "。渲染側與 link.text 側**必須用同一份規則**——只剝一邊的話，
-- 顯示文字本身以 "- " 或 "N. " 開頭的連結（`[1. 規則](url)`）會永遠比不到，點不出區域。
local function strippedVisibleText(text)
    local result = normalizeVisibleText(text)
    result = string.gsub(result, "^%-%s*", "")
    result = string.gsub(result, "^%d+%.%s*", "")
    return result
end

local function richTextColorPush(color)
    -- 前後補空白：這個字串會取代 Parser.LINK_PREFIX，若不補會把 tag 黏回前面的文字，
    -- 導致該段文字被 ISRichTextPanel tokenizer 當成 command 丟棄（:468-486）。
    return " <PUSHRGB:" .. tostring(color.r) .. ","
        .. tostring(color.g) .. "," .. tostring(color.b) .. "> "
end

local function replaceAllLiteral(text, needle, replacement)
    local result = {}
    local position = 1
    while true do
        local first, last = string.find(text, needle, position, true)
        if not first then
            result[#result + 1] = string.sub(text, position)
            break
        end
        result[#result + 1] = string.sub(text, position, first - 1)
        result[#result + 1] = replacement
        position = last + 1
    end
    return table.concat(result)
end

local function splitLogicalLines(text)
    local lines = {}
    local position = 1
    while true do
        local first, last = string.find(text, "<LINE>", position, true)
        if not first then
            lines[#lines + 1] = string.sub(text, position)
            break
        end
        lines[#lines + 1] = string.sub(text, position, first - 1)
        position = last + 1
    end
    return lines
end

-- 只接受形狀合法、長度有界的 http(s) URL 進剪貼簿；擋掉 javascript:/file: 與控制字元 payload。
local function isCopyableUrl(url)
    return type(url) == "string"
        and string.len(url) <= 2048
        -- 路徑/查詢字串允許的字元要夠寬（[ ] { } | 在真實網址中常見），否則合法連結會被誤擋；
        -- 真正的防護是「必須 http(s):// 起頭」，擋掉 javascript:／file: 這類 scheme。
        and string.match(url, "^https?://[%w%-%.]+[%w%-%./%?&=#%%~%+:@_,;!%$%*'%(%)%[%]{}|]*$") ~= nil
end

local function isOfficialUrl(url)
    if type(url) ~= "string" then
        return false
    end
    local index
    for index = 1, #OFFICIAL_URL_ROOTS do
        local root = OFFICIAL_URL_ROOTS[index]
        if url == root or string.sub(url, 1, string.len(root) + 1) == root .. "/" then
            return true
        end
    end
    return false
end

local NBLinkRichTextPanel = ISRichTextPanel:derive("NBLinkRichTextPanel")

function NBLinkRichTextPanel:paginate()
    local ok, pageError = pcall(function()
        ISRichTextPanel.paginate(self)
    end)
    if not ok then
        self.textDirty = false
        self.lines = {}
        self.lineX = {}
        self.lineY = {}
        self.images = {}
        self.videos = {}
        if self.owner then
            self.owner:onRichTextFailure(pageError)
        end
        return false, pageError
    end

    -- 純圖片行的高度不會進捲動範圍，這裡補回去。
    -- 引擎的 paginate 只在「這一行有非空文字」時才把 lineImageHeight 累進 y
    -- （ISRichTextPanel.lua:550-556 的 `elseif self.lines[lines] and self.lines[lines] ~= ''`），
    -- 而 `![圖](路徑)` 自己一行時該行只剩 image command、文字是空字串，於是整張圖的高度
    -- 被丟棄，接著 setScrollHeight(marginTop + y + marginBottom)（:566）算出來的範圍
    -- 就不含圖片——圖比內容區高時完全捲不動，圖下面的公告等於看不到。
    -- 修法不動引擎：paginate 已經把每張圖的實際落點記在 imageY／imageH（:172-175，
    -- render 用同一組座標畫圖 :594-595），拿它們算出真正的內容底部，比引擎算的高就補上。
    -- 只加不減：文字比圖長時引擎算的才是對的。
    self:extendScrollHeightForImages()

    if self.owner then
        self.owner:rebuildLinkHitRegions()
    end
    return true, nil
end

-- 內容底部 = max(imageY + imageH) + 上下 margin。imageY 可能是負的
-- （:172 的 y+(lineHeight-lineImageHeight)/2 在圖比行高時為負），加上 imageH 之後仍是
-- 該圖底部的相對位置，所以直接取最大值即可。
function NBLinkRichTextPanel:extendScrollHeightForImages()
    local images = self.images
    if type(images) ~= "table" or #images == 0 then
        return
    end

    local bottom = 0
    local index
    for index = 1, #images do
        local imageY = self.imageY and self.imageY[index] or nil
        local imageH = self.imageH and self.imageH[index] or nil
        if type(imageY) == "number" and type(imageH) == "number" then
            local candidate = imageY + imageH
            if candidate > bottom then
                bottom = candidate
            end
        end
    end
    if bottom <= 0 then
        return
    end

    local needed = self.marginTop + bottom + self.marginBottom
    -- getScrollHeight 走 javaObject，測試 harness 沒有那層時回 0；取 max 後照樣安全。
    local ok, current = pcall(function()
        return self:getScrollHeight()
    end)
    if ok and type(current) == "number" and current >= needed then
        return
    end
    pcall(function()
        self:setScrollHeight(needed)
    end)
end

function NBLinkRichTextPanel:render()
    if self.textDirty then
        local paginated = self:paginate()
        if not paginated then
            return
        end
    end

    local hovered = nil
    if self.owner then
        hovered = self.owner:getHoveredLink()
    end

    local previousColors = {}
    if hovered and self.rgb then
        local index
        for index = 1, #hovered.indices do
            local lineIndex = hovered.indices[index]
            previousColors[#previousColors + 1] = {
                index = lineIndex,
                color = self.rgb[lineIndex],
            }
            self.rgb[lineIndex] = COLORS.LINK_HOVER
        end
    end

    local ok, renderError = pcall(function()
        ISRichTextPanel.render(self)
    end)

    local restoreIndex
    for restoreIndex = 1, #previousColors do
        local previous = previousColors[restoreIndex]
        self.rgb[previous.index] = previous.color
    end

    if not ok then
        pcall(function()
            self:clearStencilRect()
        end)
        if self.owner then
            self.owner:onRichTextFailure(renderError)
        end
        return
    end

    if hovered then
        local scrollY = self:getYScroll()
        local index
        for index = 1, #hovered.segments do
            local segment = hovered.segments[index]
            if segment.y2 + scrollY >= 0 and segment.y1 + scrollY <= self.height then
                self:drawRect(segment.x1, segment.y2 - 1,
                    math.max(1, segment.x2 - segment.x1), 1,
                    COLORS.LINK_HOVER.a,
                    COLORS.LINK_HOVER.r, COLORS.LINK_HOVER.g, COLORS.LINK_HOVER.b)
            end
        end
    end
end

-- 伺服器同步來的圖以 <IMAGE:NBCACHE_<hash>> 進 RichText，真正的絕對路徑在這裡才換回去。
-- 原因：paginate 以空白切 token（ISRichTextPanel.lua:459），玩家家目錄含空白時
-- 直接把絕對路徑寫進標記會被切斷；到了 processCommand 這層已經不再經過 tokenizer，換路徑才安全。
function NBLinkRichTextPanel:processCommand(command, x, y, lineImageHeight, lineHeight)
    -- rest 是預檢算好的 ",寬,高"（縮放用），原樣保留交給原生實作。
    -- 兩種標記都要接，但**主要路徑是 IMAGE**：markdown 的 `![]()` 由 preflightImages 換成
    -- <IMAGE:>（靠左的行內元素，不用會強制水平置中的 IMAGECENTRE——見 MDParser 的 NBIMG 註解）；
    -- IMAGECENTRE 則是服主自己在公告裡手寫的原生標記。這兩條路在引擎裡是不同分支、
    -- imageY 與高度的算法都不一樣（ISRichTextPanel.lua:155-175 vs :320-336），
    -- 所以改動圖片相關行為時**兩條都要各自驗過**，不能拿其中一條的結果當另一條的保證。
    -- 引擎是用子字串比對，而 "IMAGECENTRE:" 不含 "IMAGE:"（中間隔了 C），兩者不會互相誤判。
    local kind, hash, rest = string.match(command,
        "^(IMAGECENTRE:)" .. ImageCache.TOKEN_PREFIX .. "([0-9a-f]+)(.*)$")
    if not kind then
        kind, hash, rest = string.match(command,
            "^(IMAGE:)" .. ImageCache.TOKEN_PREFIX .. "([0-9a-f]+)(.*)$")
    end
    if hash then
        local path = ImageCache.pathForHash(hash)
        if not path then
            -- 預檢通過後才會產生這個 token，理論上到不了；真的到了就當作沒有這張圖，不畫也不崩。
            return x, y, lineImageHeight
        end
        command = kind .. path .. rest
    end

    -- 原生 <IMAGE:> 把圖片垂直置中對齊「一行文字」：
    --   imageY = y + (lineHeight - lineImageHeight) / 2        （ISRichTextPanel.lua:172）
    -- lineHeight 是呼叫前算好的字型行高（約 20px），lineImageHeight 卻是圖片高度（可達數百 px），
    -- 於是算出大負數，圖片被畫到自己那一行的上方、直接蓋住前面的文字。
    -- 改用 <IMAGECENTRE:> 可以繞開，但它會強制水平置中，而 markdown 的 ![]() 是靠左的。
    -- 所以維持 <IMAGE:>（水平位置本來就對），只在原生實作跑完後把 Y 拉回該行頂端。
    -- 垂直空間不必自己算：原生實作已把 lineImageHeight 設成圖高，paginate 對下一個 token
    -- 取 lineHeight = max(字型行高, lineImageHeight)，接著的 <LINE> 就會推進整個圖高。
    -- 用回傳的 nextY 而不是入參 y：原生實作在 `x + w >= width - (marginLeft+marginRight)` 時會
    -- 先 `x = 0; y = y + lineHeight` 換行才寫 imageY（ISRichTextPanel.lua:161-164），而且
    -- 之後就是 `return x, y, lineImageHeight`（:353）。拿舊的 y 覆寫等於把換行後那張圖拉回上一行，
    -- 一列排兩張縮圖時會直接疊在一起。沒換行時 nextY == y，行為與原本一致。
    local isImageCommand = string.find(command, "IMAGE:", 1, true) == 1
    local beforeCount = self.imageCount
    local nextX, nextY, nextLineImageHeight =
        ISRichTextPanel.processCommand(self, command, x, y, lineImageHeight, lineHeight)
    if isImageCommand and self.imageCount > beforeCount then
        self.imageY[self.imageCount - 1] = nextY
        -- 換了行（原生實作只在 x + w 超出可用寬度時動 y，ISRichTextPanel.lua:162-165）：
        -- 新的一行目前只有這一張圖，但原生實作沒有在換行時重設 lineImageHeight——
        -- 它只在「比現值大」時抬高（:167-169），所以上一行那張 200px 圖的高度會被這一行的
        -- 50px 圖繼承下去。paginate 對下一個 token 取 lineHeight = max(字型行高, lineImageHeight)
        -- （:482-484），接著的 <LINE> 就多推進 150px，下一行憑空多出一大段空白。
        -- 這是原版既有行為（paginate 自己的文字換行路徑倒是有重設，:510），只是原版幾乎踩不到；
        -- 「一列排兩張縮圖」正是尺寸語法帶來的新版型，所以在這裡一併修掉。
        if nextY ~= y then
            nextLineImageHeight = self.imageH[self.imageCount - 1] or nextLineImageHeight
        end
    end
    return nextX, nextY, nextLineImageHeight
end

function NBLinkRichTextPanel:onMouseDown(x, y)
    return true
end

function NBLinkRichTextPanel:onMouseUp(x, y)
    if self.owner then
        return self.owner:onRichTextMouseUp(x, y)
    end
    return false
end

function NBLinkRichTextPanel:new(x, y, width, height, owner)
    local o = ISRichTextPanel.new(self, x, y, width, height)
    o.owner = owner
    return o
end

local function hasAdminAccess()
    local ok, accessLevel = pcall(function()
        return getAccessLevel()
    end)
    return ok and type(accessLevel) == "string"
        and string.lower(accessLevel) == "admin"
end

function NBPanel:initialise()
    ISCollapsableWindowJoypad.initialise(self)
end

function NBPanel:createChildren()
    ISCollapsableWindowJoypad.createChildren(self)

    self.tabY = self:titleBarHeight()
    self.tabHeight = getTextManager():getFontHeight(UIFont.Small) + 6
    self.adminVisible = hasAdminAccess()

    -- 按鈕放在頁籤列右端，而不是自己獨占一條橫帶：單一按鈕撐開一整列會留下大片空白，
    -- 視覺上像是壞掉的工具列，也白白吃掉內容高度。由右往左依序擺放。
    local contentY = self.tabY + self.tabHeight
    local rightEdge = self.width - TAB_BUTTON_GAP

    local function addTabRowButton(labelKey, callback)
        local title = getText(labelKey)
        local buttonWidth = getTextManager():MeasureStringX(UIFont.NewSmall, title) + 16
        local button = ISButton:new(
            rightEdge - buttonWidth,
            self.tabY + 1,
            buttonWidth,
            self.tabHeight - 2,
            title,
            self,
            callback
        )
        button:initialise()
        button:setFont(UIFont.NewSmall)
        -- 錨定右上：視窗變寬時按鈕跟著右邊走
        button:setAnchorsTBLR(true, false, false, true)
        self:addChild(button)
        rightEdge = rightEdge - buttonWidth - TAB_BUTTON_GAP
        return button
    end

    if self.adminVisible then
        self.reloadButton = addTabRowButton("IGUI_MinidoracatNB_Reload", NBPanel.onReload)
    end
    -- 重設大小對所有玩家可見：尺寸被 layout.ini 記憶後，沒有這個入口就只能去編輯 ini
    self.resetButton = addTabRowButton("IGUI_MinidoracatNB_ResetSize", NBPanel.resetToDefaultSize)
    -- 語系選擇放在「重設大小」左邊（addTabRowButton 由右往左排，故後加的在左邊）
    self.langButton = addTabRowButton("IGUI_MinidoracatNB_Language", NBPanel.onLanguageButton)

    self.contentY = contentY
    local contentHeight = self.height - contentY - self:resizeWidgetHeight()
    self.richText = NBLinkRichTextPanel:new(0, contentY, self.width, contentHeight, self)
    self.richText:initialise()
    self.richText:setAnchorsTBLR(true, true, true, true)
    self.richText.autosetheight = false
    self.richText.clip = true
    self.richText.doRepaintStencil = true
    -- 左右邊界**必須對稱**，否則置中的行（`#` 標題、`<CENTRE>`）會偏。
    -- ISRichTextPanel 的置中算在 [marginLeft, width - marginRight] 之間
    -- （ISRichTextPanel.lua:649：lineX = marginLeft + (width - marginLeft - marginRight - lineLength)/2），
    -- 所以文字中心 = marginLeft + (width - marginLeft - marginRight)/2，與文字長度無關；
    -- 右邊多預留捲軸寬（13）而左邊沒有時，中心恆偏左 (marginRight - marginLeft)/2 = 6.5px，
    -- 與標題列的標題（drawTextCentre(title, width/2)，正中）差 6.5px、肉眼看得出兩行沒對齊。
    -- 代價是左側留白從 10 變 23（文字可用寬少 13px），換來所有置中元素與標題列對齊。
    self.richText:setMargins(10 + SCROLLBAR_WIDTH, 10, 10 + SCROLLBAR_WIDTH, 0)
    self:addChild(self.richText)
    self.richText:addScrollBars()
    self.richText:setVisible(false)
end

function NBPanel:RestoreLayout(name, layout)
    local visible = layout.visible
    layout.visible = nil
    ISCollapsableWindowJoypad.RestoreLayout(self, name, layout)
    layout.visible = visible
    self:setVisible(false)
end

function NBPanel:SaveLayout(name, layout)
    ISCollapsableWindowJoypad.SaveLayout(self, name, layout)
end

function NBPanel:onReload()
    if not hasAdminAccess() or not isClient() then
        return
    end
    -- reload 沒有 ack；發送失敗若靜默吞掉，admin 會無法區分「按鈕壞了」與「檔案沒改對」。
    local ok = pcall(function()
        sendClientCommand(NBReader.MODULE, "reload", {})
    end)
    if ok then
        NBToast.show(getText("IGUI_MinidoracatNB_ReloadSent"))
    else
        NBToast.show(getText("IGUI_MinidoracatNB_ReloadFailed"))
    end
end

-- 只列「伺服器實際有內容的語系」（manifest 的 langs），加上跟隨遊戲語系的自動選項。
-- 沒有這個欄位的舊版 server 會只剩自動，行為與現況一致。
function NBPanel:onLanguageButton(button)
    local menu = ISContextMenu.get(0,
        button:getAbsoluteX(), button:getAbsoluteY() + button:getHeight())
    if not menu then
        return
    end

    local current = Client.getLanguagePreference()
    local option = menu:addOption(getText("IGUI_MinidoracatNB_LanguageAuto"),
        self, NBPanel.onLanguageSelected, Core.AUTO_LANGUAGE)
    menu:setOptionChecked(option, current == Core.AUTO_LANGUAGE)

    local languages = NBReader.getLanguages()
    local preferenceListed = false
    local index
    for index = 1, #languages do
        local code = languages[index]
        if code == current then
            preferenceListed = true
        end
        option = menu:addOption(code, self, NBPanel.onLanguageSelected, code)
        menu:setOptionChecked(option, current == code)
    end

    -- 偏好語系的目錄被服主清空後它就不在 manifest 的 langs 內，而偏好本身仍然有效：
    -- 沒有這一列的話「自動」與所有語系都不會打勾，整份選單零勾選，玩家看不出目前生效的是什麼。
    -- 補一列代表目前偏好並標成已勾選，文字說明該語系現在沒有內容；點它仍然可以重送切換請求。
    if not preferenceListed and current ~= Core.AUTO_LANGUAGE then
        option = menu:addOption(getText("IGUI_MinidoracatNB_LanguageMissing", current),
            self, NBPanel.onLanguageSelected, current)
        menu:setOptionChecked(option, true)
    end
end

function NBPanel:onLanguageSelected(code)
    local status, waitSeconds = Client.setLanguagePreference(code)
    -- 冷卻中不是靜默失敗：偏好已經存下、切換也已排入重試，但要讓玩家知道還要等。
    if status == "cooldown" then
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageCooldown", tostring(waitSeconds)))
    elseif status == "failed" then
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageFailed"))
    elseif status == "sent" then
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageSwitching"))
    else
        -- unchanged：偏好確實已寫下（例如遊戲語系是 CH、偏好也是 CH 時選「自動」），
        -- 但畫面不會有任何變化。沒有回饋玩家只會覺得按鈕壞了。
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageUnchanged"))
    end
end

-- 語系相關的非同步狀態（settings.ini 落地失敗／補寫成功／切換送出額度用盡）。
-- NBClient 對同一次失敗只發一次事件，所以這裡直接出 toast 不會洗版。
local function onLanguageStatus(payload)
    if type(payload) ~= "table" then
        return
    end
    local kind = rawget(payload, "kind")
    if kind == "save-failed" then
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageSaveFailed"))
    elseif kind == "save-recovered" then
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageSaveRecovered"))
    elseif kind == "switch-exhausted" then
        NBToast.show(getText("IGUI_MinidoracatNB_LanguageSwitchExhausted"))
    end
end

-- 圖片端唯一需要對玩家講話的狀態：寫入時間窗的額度用盡。誠實伺服器永遠走不到
-- （合法上界遠低於窗額度），所以這不是雜訊；NBImageCache 一個窗只發一次，
-- 這裡直接出 toast 不會洗版。其餘圖片狀態（淘汰、回收、重試）只寫 log：
-- 那些是背景行為，玩家看到的只會是「圖出現了」。
local function onImageStatus(payload)
    if type(payload) ~= "table" then
        return
    end
    if rawget(payload, "kind") == "budget" then
        NBToast.show(getText("IGUI_MinidoracatNB_ImageBudget",
            tostring(rawget(payload, "minutes"))))
    end
end

function NBPanel:onRichTextFailure(renderError)
    self.contentState = "error"
    self.contentError = tostring(renderError or "")
    self.linkHitRegions = {}
    if self.richText then
        self.richText:setVisible(false)
    end
    print("[MinidoracatNoticeBoardFor42] UI render error: " .. self.contentError)
end

-- 貼圖尺寸不可控——伺服器同步的圖是服主直接丟進目錄的原始 PNG，圖包 MOD 的貼圖同樣是
-- 服主自己做的。ISRichTextPanel 的 <IMAGE:路徑>（不帶寬高）會用貼圖原始像素尺寸畫
-- （ISRichTextPanel.lua:158-161），一張 4000x3000 會橫向被 stencil 裁掉、縱向把捲動區撐到 3000+。
-- 所以**兩條路徑都無條件走這裡**（伺服器同步圖、圖包 MOD 貼圖、服主手寫的原生 tag）。
-- 這裡把貼圖實際尺寸與公告要求的尺寸交給 NBCore.fitImageSize 夾限（純數學，可單元測試），
-- 回傳 nil 代表不需要尺寸參數 -> 產出仍是不帶逗號的 <IMAGE:路徑>，塞得下的圖行為完全不變。
-- ponytail: 縮放在 render 當下計算，縮放視窗後要等下一次重畫（切頁籤／內容更新）才會重算。
function NBPanel:imageFitSize(texture, requestedWidth, requestedHeight)
    local ok, width, height = pcall(function()
        return texture:getWidth(), texture:getHeight()
    end)
    if not ok then
        return nil
    end

    -- 再扣 12px：原生實作在 x + w >= 可用寬度時會先換行，且每張圖左右各補 IMAGE_PAD(5)，
    -- 剛好等寬會多換一行並貼齊邊界。
    local maximum = (self.richText.width or 0)
        - (self.richText.marginLeft or 0) - (self.richText.marginRight or 0) - 12
    -- 高度上限取內容高度的 3 倍：比面板高一點還能捲著看，但一張圖不該吃掉整個捲動區。
    local maximumHeight = math.max(64, math.floor((self.richText.height or 0) * 3))
    return Core.fitImageSize(width, height, requestedWidth, requestedHeight,
        maximum, maximumHeight)
end

function NBPanel:preflightImages(parsed)
    local rendered = replaceAllLiteral(
        parsed.richText,
        Parser.LINK_PREFIX,
        richTextColorPush(COLORS.LINK)
    )
    local placeholderPrefix = richTextColorPush(COLORS.PLACEHOLDER_TEXT)

    local function imagePlaceholder(alt)
        local text
        if type(alt) == "string" and alt ~= "" then
            text = "[" .. alt .. "]"
        else
            text = getText("IGUI_MinidoracatNB_ImagePlaceholder")
        end
        return placeholderPrefix .. Core.escapeRichText(text) .. Parser.LINK_SUFFIX
    end

    -- 第一圈：把 MDParser 放的唯一佔位 token（<NBIMG:n>）換成真正的 <IMAGE:...> 或占位文字。
    -- token 唯一，所以不會與服主手寫的同路徑 tag 混淆；游標只是為了讓整輪維持線性。
    local searchAt = 1
    local index
    for index = 1, #parsed.images do
        local image = parsed.images[index]
        -- `images/<檔名>` 走伺服器同步的本機快取；其他路徑（media/... 的 MOD 貼圖）行為完全不變。
        local cacheHash = ImageCache.hashForPath(image.path)
        local replacement = nil
        if cacheHash then
            -- 先確認貼圖真的載得起來：<IMAGE:> 遇 nil texture 會直接拋錯
            -- （ISRichTextPanel.lua:157-160）。快取檔尚未寫完時 resolved 為 nil，
            -- 不會走到這裡，也就不會把檔名寫進 Texture 的 nullTextures 永久黑名單。
            local resolved = ImageCache.pathForHash(cacheHash)
            if resolved then
                local textureOk, texture = pcall(function()
                    return getTexture(resolved)
                end)
                if textureOk and texture ~= nil then
                    local width, height = self:imageFitSize(texture, image.width, image.height)
                    replacement = Core.imageTag("<IMAGE:",
                        ImageCache.TOKEN_PREFIX .. cacheHash, width, height)
                end
            end
        elseif string.find(image.path, ",", 1, true) == nil then
            -- 檔名含逗號的貼圖沒辦法寫成原生 tag：引擎只要在 command 內看到逗號就把它當成
            -- 「路徑,寬,高」去拆（ISRichTextPanel.lua:149-154），高度那段是 nil 就整份公告死掉。
            -- 第二圈本來就會把這種 tag 換成占位，但那時已經對不回 alt 了；在這裡擋下才留得住
            -- 替代文字，服主看得出是哪一張圖。
            local textureOk, texture = pcall(function()
                return getTexture(image.path)
            end)
            if textureOk and texture ~= nil then
                -- 圖包 MOD 的貼圖也走同一份夾限：沒寫尺寸的圖以前是原樣交給引擎，
                -- 一張 4000x3000 會直接畫爆版面。塞得下的圖 fitImageSize 回 nil ->
                -- 產出仍是不帶逗號的 <IMAGE:路徑>，既有公告一個位元組都不會變。
                -- 顏色護欄不在這裡加：第二圈本來就會重建**每一個**存活的圖片 tag
                -- （含服主手寫的），在那個唯一的收口處包一次就好，否則會包兩層。
                local width, height = self:imageFitSize(texture, image.width, image.height)
                replacement = Core.imageTag("<IMAGE:", image.path, width, height)
            end
        end

        if replacement == nil then
            replacement = imagePlaceholder(image.alt)
        end
        rendered, searchAt = Core.replaceNextLiteral(rendered, searchAt, image.tag, replacement)
    end

    -- 第二圈：所有存活下來的原生圖片 tag（含服主直接手寫在公告裡的）都得重建一次。
    -- 只驗路徑是不夠的——手寫 <IMAGE:path,100000,100000> 的尺寸會被引擎原樣採用
    -- （:149-154 取 vs[2]/vs[3]，:173-174 直接寫進 imageW/imageH），完全繞過夾限；
    -- 而 <IMAGE:path,600>（只給一個逗號參數）會讓引擎對 nil 呼叫 string.trim 而拋錯，
    -- 由 paginate 的 pcall 接住 -> 整份公告變成錯誤占位。形狀不合法一律換成占位，
    -- 讓服主看得出是哪一張圖壞掉。
    local searchPosition = 1
    while true do
        local imageStart = string.find(rendered, "<IMAGE:", searchPosition, true)
        local centredStart = string.find(rendered, "<IMAGECENTRE:", searchPosition, true)
        local tagStart = imageStart
        local tagPrefix = "<IMAGE:"
        if centredStart and (not tagStart or centredStart < tagStart) then
            tagStart = centredStart
            tagPrefix = "<IMAGECENTRE:"
        end
        if not tagStart then
            break
        end

        local pathOffset = string.len(tagPrefix)
        local tagEnd = string.find(rendered, ">", tagStart + pathOffset, true)
        if not tagEnd then
            break
        end
        local path, requestedWidth, requestedHeight, shapeOk = Core.parseImageTagArguments(
            string.sub(rendered, tagStart + pathOffset, tagEnd - 1))

        local replacement = nil
        if not shapeOk or path == "" then
            replacement = imagePlaceholder(nil)
        else
            -- 第一圈放進去的快取替身 token 不是真的貼圖路徑，要換回實際檔案才驗得動
            -- （直接 getTexture(token) 會把它寫進 Texture 的 nullTextures 永久黑名單）。
            local texturePath = path
            local prefixLength = string.len(ImageCache.TOKEN_PREFIX)
            if string.sub(path, 1, prefixLength) == ImageCache.TOKEN_PREFIX then
                texturePath = ImageCache.pathForHash(string.sub(path, prefixLength + 1))
            end
            local texture = nil
            if texturePath then
                local textureOk, loaded = pcall(function()
                    return getTexture(texturePath)
                end)
                if textureOk then
                    texture = loaded
                end
            end

            if texture == nil then
                replacement = imagePlaceholder(nil)
            else
                -- 無條件重建（不只在有尺寸參數時）：不帶尺寸的 <IMAGE:路徑> 以前是原樣放行的，
                -- 引擎就會按貼圖原始像素畫。夾限是冪等的——第一圈已經夾好的 tag 再走一次會得到
                -- 同一個字串，塞得下的圖兩次都拿到 nil，產出仍是不帶逗號的 <IMAGE:路徑>。
                local width, height =
                    self:imageFitSize(texture, requestedWidth, requestedHeight)
                -- 路徑含指令觸發字樣時包上顏色護欄（NBCore.IMAGE_GUARD_PREFIX 的註解有引擎出處）。
                -- 這裡是所有圖片 tag 的唯一收口：第一圈放進來的、服主手寫的，都會經過這一趟，
                -- 且每個 tag 只會被走訪一次（searchPosition 跳過整段替換內容），不會疊層。
                -- 判危險字樣要看 texturePath 而不是 path：同步圖的 path 是 NBCACHE_<hash>
                -- 替身（恆為乾淨十六進位），引擎真正看到的是換回去之後的絕對路徑。
                replacement = Core.imageTagGuarded(tagPrefix, path, width, height, texturePath)
            end
        end

        if replacement == nil then
            searchPosition = tagEnd + 1
        else
            rendered = string.sub(rendered, 1, tagStart - 1)
                .. replacement
                .. string.sub(rendered, tagEnd + 1)
            searchPosition = tagStart + string.len(replacement)
        end
    end
    return rendered
end

function NBPanel:renderSelected(markRead)
    local tab = self.tabs[self.selectedIndex]
    if not tab then
        self.contentState = "empty"
        self.currentParsed = nil
        self.currentRenderedText = nil
        self.linkHitRegions = {}
        self.richText:setVisible(false)
        return
    end

    local resetScroll = self.lastRenderedFileId ~= tab.id
    local ok, renderError = pcall(function()
        local parsed = Parser.parse(tab.file.content)
        local rendered = self:preflightImages(parsed)
        self.currentParsed = parsed
        self.currentRenderedText = rendered
        self.contentState = "ready"
        self.contentError = nil
        self.richText.text = rendered
        self.richText.textDirty = true
        self.richText:setVisible(true)
        if resetScroll then
            self.richText:setYScroll(0)
        end
        local paginated, pageError = self.richText:paginate()
        if not paginated then
            error(pageError)
        end
        self.lastRenderedFileId = tab.id
    end)

    if not ok then
        self:onRichTextFailure(renderError)
    end

    -- 即使渲染失敗也標記已讀：玩家確實開啟並看到了錯誤占位。若保留未讀，一個永久壞掉的公告檔
    -- 會讓 PopupMode=unread 每場強制彈窗糾纏玩家（違反「玩家不被打擾」），比丟失未讀點更糟；
    -- 渲染失敗本身已寫 console log 供服主排查。
    if markRead then
        Client.markRead(tab.id)
    end
end

function NBPanel:collectRenderedGroups()
    local richText = self.richText
    local groups = {}
    local font = richText.defaultFont
    local orientation = "left"
    local index
    for index = 1, #(richText.lines or {}) do
        if richText.fonts and richText.fonts[index] then
            font = richText.fonts[index]
        end
        if richText.orient and richText.orient[index] then
            orientation = richText.orient[index]
        end

        local y = richText.lineY[index] or 0
        local group = groups[#groups]
        if not group or group.y ~= y then
            group = {
                y = y,
                parts = {},
                textParts = {},
                indices = {},
                maxFontHeight = 0,
            }
            groups[#groups + 1] = group
        end

        local text = trim(richText.lines[index] or "")
        if text ~= "" then
            local width = getTextManager():MeasureStringX(font, text)
            local fontHeight = getTextManager():getFontHeight(font)
            group.parts[#group.parts + 1] = {
                index = index,
                text = text,
                width = width,
                lineX = richText.lineX[index] or 0,
                font = font,
                orientation = orientation,
            }
            group.textParts[#group.textParts + 1] = text
            group.indices[#group.indices + 1] = index
            if fontHeight > group.maxFontHeight then
                group.maxFontHeight = fontHeight
            end
        end
    end

    local groupIndex
    for groupIndex = 1, #groups do
        local group = groups[groupIndex]
        group.text = normalizeVisibleText(table.concat(group.textParts, " "))
        if #group.parts > 0 then
            local lineLength = 0
            local partIndex
            for partIndex = 1, #group.parts do
                lineLength = lineLength + group.parts[partIndex].width
            end
            local centerX = richText.marginLeft
                + (richText.width - richText.marginLeft - richText.marginRight - lineLength) / 2
            local minimumX = nil
            local maximumX = nil
            for partIndex = 1, #group.parts do
                local part = group.parts[partIndex]
                local x1
                local x2
                if part.orientation == "centre" then
                    x1 = centerX + part.lineX
                    x2 = x1 + part.width
                elseif part.orientation == "right" then
                    x2 = richText.marginLeft + part.lineX
                    x1 = x2 - part.width
                else
                    x1 = richText.marginLeft + part.lineX
                    x2 = x1 + part.width
                end
                minimumX = minimumX and math.min(minimumX, x1) or x1
                maximumX = maximumX and math.max(maximumX, x2) or x2
            end
            group.segment = {
                x1 = minimumX,
                x2 = maximumX,
                y1 = group.y + richText.marginTop,
                y2 = group.y + richText.marginTop + group.maxFontHeight,
            }
        end
    end
    return groups
end

local function firstCandidateGroup(groups, logicalLines, logicalLine)
    local nonEmptyBefore = 0
    local index
    for index = 1, math.max(0, (logicalLine or 1) - 1) do
        if normalizeVisibleText(logicalLines[index] or "") ~= "" then
            nonEmptyBefore = nonEmptyBefore + 1
        end
    end

    local seen = 0
    for index = 1, #groups do
        if groups[index].text ~= "" then
            if seen >= nonEmptyBefore then
                return index
            end
            seen = seen + 1
        end
    end
    return 1
end

local function matchLinkGroups(groups, startIndex, target)
    local candidateStart
    for candidateStart = startIndex, #groups do
        if groups[candidateStart].text ~= "" then
            local combined = ""
            local candidateEnd
            for candidateEnd = candidateStart, #groups do
                local groupText = groups[candidateEnd].text
                if groupText == "" then
                    if combined ~= "" then
                        break
                    end
                else
                    if combined == "" then
                        combined = groupText
                    else
                        combined = combined .. " " .. groupText
                    end
                    local comparable = strippedVisibleText(combined)
                    if comparable == target then
                        return candidateStart, candidateEnd
                    end
                    if string.len(comparable) > string.len(target)
                        or string.sub(target, 1, string.len(comparable)) ~= comparable then
                        break
                    end
                end
            end
        end
    end
    return nil, nil
end

function NBPanel:rebuildLinkHitRegions()
    self.linkHitRegions = {}
    if not self.currentParsed or not self.currentRenderedText then
        return
    end

    local groups = self:collectRenderedGroups()
    local logicalLines = splitLogicalLines(self.currentRenderedText)
    local cursor = 1
    local linkIndex
    for linkIndex = 1, #self.currentParsed.links do
        local link = self.currentParsed.links[linkIndex]
        local target = strippedVisibleText(link.text)
        local minimum = firstCandidateGroup(groups, logicalLines, link.line)
        if minimum < cursor then
            minimum = cursor
        end
        local first, last = matchLinkGroups(groups, minimum, target)
        if first then
            local region = {
                text = link.text,
                url = link.url,
                logicalLine = link.line,
                segments = {},
                indices = {},
            }
            local groupIndex
            for groupIndex = first, last do
                local group = groups[groupIndex]
                if group.segment then
                    region.segments[#region.segments + 1] = group.segment
                end
                local index
                for index = 1, #group.indices do
                    region.indices[#region.indices + 1] = group.indices[index]
                end
            end
            self.linkHitRegions[#self.linkHitRegions + 1] = region
            cursor = last + 1
        end
    end
end

-- x, y 必須是**內容座標**（paginate 座標系，不含捲動）。兩個呼叫端給的都已經是：
--   getMouseX/getMouseY = 螢幕座標 - absXY - javaObject 的 scroll（ISUIElement.lua:339-350）
--   onMouseUp 的參數    = 引擎派發時已 `y - this.yScroll`（UIElement.java:1311-1321）
-- segment.x/y 是 paginate 產物（內容座標），所以直接比對即可。
-- 【踩過】這裡曾再加一次 getYScroll() 補償——沒捲動時 scrollY=0 等價所以看不出來，
-- 捲動後判定區整體上移 |scrollY|，症狀是「滑鼠要移到連結上方才觸發 hover」時好時壞。
function NBPanel:findLinkAt(x, y)
    local linkIndex
    for linkIndex = 1, #(self.linkHitRegions or {}) do
        local region = self.linkHitRegions[linkIndex]
        local segmentIndex
        for segmentIndex = 1, #region.segments do
            local segment = region.segments[segmentIndex]
            if x >= segment.x1 and x <= segment.x2
                and y >= segment.y1 and y <= segment.y2 then
                return region
            end
        end
    end
    return nil
end

function NBPanel:getHoveredLink()
    if self.contentState ~= "ready" or not self.richText:isMouseOver() then
        return nil
    end
    return self:findLinkAt(self.richText:getMouseX(), self.richText:getMouseY())
end

function NBPanel:onRichTextMouseUp(x, y)
    local region = self:findLinkAt(x, y)
    if not region then
        return false
    end

    -- 剪貼簿也只接受形狀合法的 http(s) URL：markdown 的 [顯示文字](payload) 讓 label 與實際內容脫鉤，
    -- 無條件寫剪貼簿＋「已複製」提示會被拿來把 `curl evil|bash` 之類塞進玩家剪貼簿。
    if not isCopyableUrl(region.url) then
        NBToast.show(getText("IGUI_MinidoracatNB_LinkBlocked"))
        return true
    end

    local copied = pcall(function()
        Clipboard.setClipboard(region.url)
    end)
    if copied then
        -- 顯示本地化「已複製」＋網域：直接印完整網址會被 toast 寬度截斷而失去意義，
        -- 但網域正是 label/payload 脫鉤時玩家最該看到的部分（顯示文字可造假，網域不行）。
        local host = string.match(region.url, "^https?://([^/]+)") or ""
        NBToast.show(trim(getText("IGUI_MinidoracatNB_LinkCopied") .. " " .. host))
    else
        NBToast.show(getText("IGUI_MinidoracatNB_LinkCopyFailed"))
    end
    if isOfficialUrl(region.url) then
        pcall(function()
            openUrl(region.url)
        end)
    end
    return true
end

-- 頁籤可用寬度要扣掉右側按鈕，否則頁籤會捲到按鈕底下被蓋住／點不到。
-- 直接讀按鈕的即時 X（它們錨定右側），縮放視窗後仍然正確——用建立當下算好的常數會失準。
function NBPanel:tabAreaWidth()
    local limit = self.width
    if self.langButton then
        limit = math.min(limit, self.langButton:getX() - TAB_BUTTON_GAP)
    end
    if self.resetButton then
        limit = math.min(limit, self.resetButton:getX() - TAB_BUTTON_GAP)
    end
    if self.reloadButton then
        limit = math.min(limit, self.reloadButton:getX() - TAB_BUTTON_GAP)
    end
    return math.max(0, limit)
end

function NBPanel:getTotalTabWidth()
    local total = 0
    local index
    for index = 1, #self.tabs do
        total = total + self.tabs[index].width
    end
    return total
end

function NBPanel:updateSmoothTabScroll()
    if not self.smoothScrollTargetX then
        return
    end
    local difference = self.smoothScrollTargetX - self.smoothScrollX
    local maximum = math.max(0, self:getTotalTabWidth() - self:tabAreaWidth())
    local frameFraction = UIManager.getMillisSinceLastRender() / 33.3
    local target = self.smoothScrollX + difference * 0.25 * frameFraction
    if target > 0 then
        target = 0
    elseif target < -maximum then
        target = -maximum
    end
    if math.abs(target - self.smoothScrollTargetX) > 1 then
        self.tabScrollX = math.floor(target)
        self.smoothScrollX = target
    else
        self.tabScrollX = self.smoothScrollTargetX
        self.smoothScrollX = self.tabScrollX
        self.smoothScrollTargetX = nil
    end
end

function NBPanel:layoutTabs()
    local x = self.tabScrollX
    local index
    for index = 1, #self.tabs do
        local tab = self.tabs[index]
        tab.x = x
        x = x + tab.width
    end
end

function NBPanel:ensureTabVisible(index)
    local tab = self.tabs[index]
    if not tab then
        return
    end
    self:layoutTabs()
    if not self.smoothScrollTargetX then
        self.smoothScrollX = self.tabScrollX
    end
    if tab.x < 0 then
        self.smoothScrollTargetX = self.tabScrollX - tab.x
    elseif tab.x + tab.width > self:tabAreaWidth() then
        self.smoothScrollTargetX = self.tabScrollX - (tab.x + tab.width - self:tabAreaWidth())
    end
end

function NBPanel:drawTabs()
    self:updateSmoothTabScroll()
    self:layoutTabs()

    local tray = COLORS.TAB_TRAY_BG
    local border = COLORS.BORDER
    self:drawRect(0, self.tabY, self.width, self.tabHeight,
        tray.a, tray.r, tray.g, tray.b)
    -- 軌道線：頁籤是上圓、底邊開放的 3 邊框，站在這條線上；選中頁籤的 2px 底線蓋掉它，
    -- 形成「與內容相連」的感覺。畫在 stencil 之前、頁籤之前。
    self:drawRect(0, self.tabY + self.tabHeight - 1, self:tabAreaWidth(), 1,
        border.a, border.r, border.g, border.b)

    local mouseX = self:getMouseX()
    local mouseY = self:getMouseY()
    local hoveringRow = self:isMouseOver()
        and mouseY >= self.tabY and mouseY < self.tabY + self.tabHeight

    self:setStencilRect(0, self.tabY, self:tabAreaWidth(), self.tabHeight)
    local index
    for index = 1, #self.tabs do
        local tab = self.tabs[index]
        if tab.x + tab.width >= 0 and tab.x <= self:tabAreaWidth() then
            local selected = index == self.selectedIndex
            local hovered = hoveringRow and mouseX >= tab.x and mouseX < tab.x + tab.width
            if selected then
                Skin.fill(self, tab.x, self.tabY, tab.width, self.tabHeight,
                    COLORS.TAB_SELECTED_FILL, true)
            elseif hovered then
                Skin.fill(self, tab.x, self.tabY, tab.width, self.tabHeight,
                    COLORS.TAB_HOVER_FILL, true)
            end

            Skin.border(self, tab.x, self.tabY, tab.width, self.tabHeight, border, true)
            local textColor = selected and COLORS.TAB_TEXT_SELECTED
                or COLORS.TAB_TEXT_UNSELECTED
            self:drawTextCentre(tab.title, tab.x + tab.width / 2, self.tabY + 3,
                textColor.r, textColor.g, textColor.b, textColor.a, UIFont.Small)

            if selected then
                local accent = COLORS.ACCENT_AMBER
                self:drawRect(tab.x, self.tabY + self.tabHeight - 2, tab.width, 2,
                    accent.a, accent.r, accent.g, accent.b)
            end

            if Client.isUnread(tab.id) then
                -- 8x8 圓點的圓心 (right-6, +6) 正好是右上弧的圓心，半徑 4 < 邊框內緣 5，不壓弧線
                Skin.dot(self, tab.x + tab.width - 10, self.tabY + 2, 8,
                    COLORS.UNREAD_DOT, COLORS.UNREAD_DOT_OUTLINE)
            end
        end
    end
    self:clearStencilRect()
    -- 巢狀 stencil 收尾用 repaint 而不是再 set 一次：clearStencilRect 只把 stencilLevel 減一，
    -- 頁籤區在 stencil buffer 裡仍是 level+1，要用 repaintStencilRect（ALWAYS/REPLACE，
    -- UIElement.java:1928-1940）寫回父層 level 才能再畫；再 set 一次會讓 set/clear 不成對，
    -- 每幀淨 +1，render 的 clear 回不到 0 → 外框畫不出來、同幀之後的元件（alwaysOnTop 的
    -- 浮窗／Toast）整個被 stencil 擋掉。原版同款：ISRichTextPanel.lua:688-690。
    self:repaintStencilRect(0, self.tabY, self:tabAreaWidth(), self.tabHeight)
end

function NBPanel:drawContentPlaceholder()
    if self.contentState == "ready" then
        return
    end

    local y = self.contentY
    local height = self.height - y - self:resizeWidgetHeight()
    if self.contentState == "error" then
        local blockHeight = 48
        local blockY = y + math.max(8, (height - blockHeight) / 2)
        local textColor = COLORS.ERROR_TEXT
        Skin.fill(self, 10, blockY, self.width - 20, blockHeight, COLORS.ERROR_BG)
        self:drawTextCentre(getText("IGUI_MinidoracatNB_ParseError"),
            self.width / 2, blockY + 15,
            textColor.r, textColor.g, textColor.b, textColor.a, UIFont.NewSmall)
        return
    end

    local key = "IGUI_MinidoracatNB_Syncing"
    if self.contentState == "timeout" then
        key = "IGUI_MinidoracatNB_SyncTimeout"
    elseif self.contentState == "empty" then
        key = "IGUI_MinidoracatNB_NoContent"
    end
    local textColor = COLORS.PLACEHOLDER_TEXT
    self:drawTextCentre(getText(key), self.width / 2,
        y + math.max(8, height / 2 - getTextManager():getFontHeight(UIFont.NewSmall) / 2),
        textColor.r, textColor.g, textColor.b, textColor.a, UIFont.NewSmall)
end

-- prerender／render 整段覆寫、不再呼叫父類版本：父類（ISCollapsableWindow.lua:152-177 /
-- :179-204）畫的是直角面板底＋ Panel_TitleBar.png／Panel_StatusBar.png 直角貼圖條，塞進 r=6
-- 的圓角會露角。順序與父類逐行對應、只換繪製呼叫；父類的 drawFrame／background 旗標在本面板
-- 恆為 true，不再分支。版面數字（titleBarHeight／resizeWidgetHeight／stencil 範圍）一個都不動。
function NBPanel:prerender()
    local width = self:getWidth()
    local height = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then
        height = th
    end
    -- 面板底一次畫滿（父類分「標題列」與「內容區」兩段 drawRect），四角 r=6；
    -- 標題列疊一層上圓下直的淺色，取代原生 Panel_TitleBar.png；下緣只留 1px 分隔線，外框由 render 統一畫。
    -- 收合時面板只剩標題列這一條：疊色改四角圓（否則下兩角的直角會從面板底的弧線外露出來）、
    -- 不畫分隔線（外框就是底線）、不畫頁籤與占位——原版 drawRect／drawTextCentre 靠 isCollapsed
    -- 守衛不畫（ISUIElement.lua:1191-1197,:1280-1284），9-slice 沒有那道守衛，得自己跳過。
    Skin.fill(self, 0, 0, width, height, COLORS.BG_PANEL)
    Skin.fill(self, 0, 0, width, th, COLORS.TITLEBAR_FILL, not self.isCollapsed)
    if not self.isCollapsed then
        local border = COLORS.BORDER
        self:drawRect(0, th - 1, width, 1, border.a, border.r, border.g, border.b)
    end

    if self.clearStentil then
        self:setStencilRect(0, 0, self.width, height)
    end

    if self.title ~= nil then
        self:drawTextCentre(self.title, width / 2, 1, 1, 1, 1, 1, self.titleBarFont)
    end

    if not self.isCollapsed then
        self:drawTabs()
        self:drawContentPlaceholder()
    end
end

function NBPanel:render()
    local width = self:getWidth()
    local height = self:getHeight()
    local th = self:titleBarHeight()
    if self.isCollapsed then
        height = th
    end
    if not self.isCollapsed and self.resizable and self.resizeWidget:getIsVisible() then
        local rh = self:resizeWidgetHeight()
        local border = COLORS.BORDER
        -- 底部 resize 列：只留上緣 1px 分隔線（Panel_StatusBar.png 不再用）；
        -- 把手圖示原位（width-rh+1, height-rh+1，分隔線下方 1px）但邊長縮 2px（rh-4），
        -- 讓三角形的直角落在圓弧之內；整個圖示留在 resize 列裡、不壓分隔線
        self:drawRect(0, height - rh, width, 1, border.a, border.r, border.g, border.b)
        self:drawTextureScaled(self.resizeimage, width - rh + 1, height - rh + 1,
            rh - 4, rh - 4, 1, 1, 1, 1)
    end

    if self.clearStentil then
        self:clearStencilRect()
    end
    -- 外框在子元件之後畫（同父類），蓋在 richText 邊緣上
    Skin.border(self, 0, 0, width, height, COLORS.BORDER)

    if self.drawJoypadFocus then
        self:drawRectBorder(0, 0, width, self:getHeight(), 0.4, 0.2, 1.0, 1.0)
        self:drawRectBorder(1, 1, width - 2, self:getHeight() - 2, 0.4, 0.2, 1.0, 1.0)
    end

    -- 連結提示畫在最後：stencil 已 clear，才不會被內容區裁掉
    self:renderLinkTooltip()
end

-- 連結 hover 提示：顯示完整網址。Markdown 的顯示文字與實際網址可以脫鉤
-- （`[看似無害的字](惡意網址)`），所以在點下去之前就把真正會被複製的網址攤開來。
function NBPanel:renderLinkTooltip()
    if self.isCollapsed then
        -- Skin.fill/border 沒有 isCollapsed 守衛（drawRect／drawText 有，
        -- ISUIElement.lua:1191-1197,:1295-1296），摺疊時要自己跳過
        return
    end
    local region = self:getHoveredLink()
    if not region then
        return
    end

    local textManager = getTextManager()
    local font = UIFont.Small
    local maxWidth = self.width - LINK_TOOLTIP_PAD * 2 - 8
    -- 截斷結果快取：量測是 render 內的呼叫，同一個網址不重算（per-frame 不配置新 table）
    local cache = self.linkTooltipCache
    if not cache or cache.url ~= region.url or cache.maxWidth ~= maxWidth then
        local text = region.url
        if textManager:MeasureStringX(font, text) > maxWidth then
            -- 從尾端砍：網域在前面，那是玩家最該看清的部分
            while string.len(text) > 1
                and textManager:MeasureStringX(font, text .. "...") > maxWidth do
                text = string.sub(text, 1, string.len(text) - 1)
            end
            text = text .. "..."
        end
        cache = {
            url = region.url,
            maxWidth = maxWidth,
            text = text,
            width = textManager:MeasureStringX(font, text),
        }
        self.linkTooltipCache = cache
    end

    local boxWidth = cache.width + LINK_TOOLTIP_PAD * 2
    local boxHeight = textManager:getFontHeight(font) + LINK_TOOLTIP_PAD
    local x = self:getMouseX() + 12
    local y = self:getMouseY() + 18
    if x + boxWidth > self.width - 4 then
        x = self.width - 4 - boxWidth
    end
    if x < 4 then
        x = 4
    end
    if y + boxHeight > self.height - 4 then
        y = self:getMouseY() - boxHeight - 6 -- 下方不夠就翻到游標上方
    end
    x = math.floor(x)
    y = math.floor(y)

    Skin.fill(self, x, y, boxWidth, boxHeight, COLORS.TOAST_BG)
    Skin.border(self, x, y, boxWidth, boxHeight, COLORS.TOAST_BORDER)
    local textColor = COLORS.TITLE_TEXT
    self:drawText(cache.text, x + LINK_TOOLTIP_PAD, y + math.floor(LINK_TOOLTIP_PAD / 2),
        textColor.r, textColor.g, textColor.b, textColor.a, font)
end

function NBPanel:tabAt(x)
    self:layoutTabs()
    local index
    for index = 1, #self.tabs do
        local tab = self.tabs[index]
        if x >= tab.x and x < tab.x + tab.width then
            return index
        end
    end
    return nil
end

function NBPanel:onMouseDown(x, y)
    if y >= self.tabY and y < self.tabY + self.tabHeight then
        self.pressedTab = self:tabAt(x)
        return true
    end
    if y < self:titleBarHeight() then
        return ISCollapsableWindowJoypad.onMouseDown(self, x, y)
    end
    return true
end

function NBPanel:onMouseUp(x, y)
    if self.pressedTab then
        local pressed = self.pressedTab
        self.pressedTab = nil
        if y >= self.tabY and y < self.tabY + self.tabHeight
            and self:tabAt(x) == pressed then
            self:selectTab(pressed, self:getIsVisible())
        end
        return true
    end
    return ISCollapsableWindowJoypad.onMouseUp(self, x, y)
end

function NBPanel:onMouseWheel(del)
    local mouseY = self:getMouseY()
    if mouseY < self.tabY or mouseY >= self.tabY + self.tabHeight then
        return false
    end

    local maximum = math.max(0, self:getTotalTabWidth() - self:tabAreaWidth())
    if maximum == 0 then
        return true
    end
    if not self.smoothScrollTargetX then
        self.smoothScrollX = self.tabScrollX
        self.smoothScrollTargetX = self.tabScrollX
    end
    self.smoothScrollTargetX = self.smoothScrollTargetX + del * 40
    if self.smoothScrollTargetX > 0 then
        self.smoothScrollTargetX = 0
    elseif self.smoothScrollTargetX < -maximum then
        self.smoothScrollTargetX = -maximum
    end
    return true
end

function NBPanel:selectTab(index, markRead)
    if not self.tabs[index] then
        return false
    end
    self.selectedIndex = index
    self:ensureTabVisible(index)
    self:renderSelected(markRead == true)
    return true
end

function NBPanel:selectTabById(fileId, markRead)
    local index
    for index = 1, #self.tabs do
        if self.tabs[index].id == fileId then
            return self:selectTab(index, markRead)
        end
    end
    return false
end

function NBPanel:setSnapshot(snapshot, preferredId)
    self.snapshot = snapshot
    local previousId = preferredId
    if not previousId and self.tabs[self.selectedIndex] then
        previousId = self.tabs[self.selectedIndex].id
    end

    self.tabs = {}
    local files = type(snapshot) == "table" and rawget(snapshot, "files") or nil
    if type(files) == "table" then
        local index
        for index = 1, #files do
            local file = files[index]
            local title = rawget(file, "title")
            if type(title) ~= "string" or title == "" then
                title = rawget(file, "id") or ""
            end
            self.tabs[index] = {
                id = rawget(file, "id"),
                title = title,
                file = file,
                width = math.max(80,
                    getTextManager():MeasureStringX(UIFont.Small, title) + 28),
            }
        end
    end

    self.tabScrollX = 0
    self.smoothScrollX = 0
    self.smoothScrollTargetX = nil
    self.selectedIndex = nil

    if #self.tabs == 0 then
        self:renderSelected(false)
        return
    end

    if previousId and self:selectTabById(previousId, self:getIsVisible()) then
        return
    end
    self:selectTab(1, self:getIsVisible())
end

function NBPanel:setVisible(visible)
    ISCollapsableWindowJoypad.setVisible(self, visible)
    if visible then
        self:bringToTop()
        if self.selectedIndex then
            self:renderSelected(true)
        elseif not self.snapshot then
            self.contentState = NBPanel.session.timedOut and "timeout" or "syncing"
            self.richText:setVisible(false)
        end
    end
end

-- 預設尺寸抽成共用函式：開窗與「恢復預設大小」必須用同一份計算，
-- 否則兩處各算一次遲早會不一致。
function NBPanel.defaultSize()
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    -- 比例 → 可讀性上限 → 螢幕邊界 → 最小尺寸，四道依序夾限
    local width = math.floor(screenWidth * DEFAULT_WIDTH_RATIO)
    local height = math.floor(screenHeight * DEFAULT_HEIGHT_RATIO)
    width = math.min(width, MAX_DEFAULT_WIDTH, screenWidth - SCREEN_MARGIN)
    height = math.min(height, MAX_DEFAULT_HEIGHT, screenHeight - SCREEN_MARGIN)
    return math.max(MINIMUM_WIDTH, width), math.max(MINIMUM_HEIGHT, height)
end

-- 尺寸由 ISLayoutManager 記憶在 layout.ini，改過就回不去了；提供這個入口讓玩家不必去編輯 ini。
function NBPanel:resetToDefaultSize()
    local width, height = NBPanel.defaultSize()
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    self:setWidth(width)
    self:setHeight(height)
    self:setX(math.max(0, math.floor(screenWidth / 2 - width / 2)))
    self:setY(math.max(0, math.floor(screenHeight / 2 - height / 2)))
end

function NBPanel:new()
    local width, height = NBPanel.defaultSize()
    local screenWidth = getCore():getScreenWidth()
    local screenHeight = getCore():getScreenHeight()
    local x = math.max(0, math.floor(screenWidth / 2 - width / 2))
    local y = math.max(0, math.floor(screenHeight / 2 - height / 2))
    local o = ISCollapsableWindowJoypad.new(self, x, y, width, height)
    o.title = getText("IGUI_MinidoracatNB_PanelTitle")
    o.resizable = true
    o.minimumWidth = MINIMUM_WIDTH
    o.minimumHeight = MINIMUM_HEIGHT
    o.tabs = {}
    o.selectedIndex = nil
    o.tabScrollX = 0
    o.smoothScrollX = 0
    o.smoothScrollTargetX = nil
    o.linkHitRegions = {}
    o.contentState = "syncing"
    return o
end

NBPanel.session = NBPanel.session or {
    startedAtMs = 0,
    waiting = false,
    timedOut = false,
    contentReceived = false,
    hashes = {},
    imageReadyVersion = 0,
}

function NBPanel.ensureInstance()
    if NBPanel.instance then
        return NBPanel.instance
    end

    local panel = NBPanel:new()
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(false)
    NBPanel.instance = panel
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, NBPanel, panel)
    panel:setVisible(false)
    return panel
end

function NBPanel.show(preferredId)
    local panel = NBPanel.ensureInstance()
    if preferredId then
        panel:selectTabById(preferredId, false)
    end
    panel:setVisible(true)
    return panel
end

function NBPanel.toggle()
    local panel = NBPanel.ensureInstance()
    panel:setVisible(not panel:getIsVisible())
    return panel:getIsVisible()
end

local function popupMode()
    local options = type(SandboxVars) == "table"
        and rawget(SandboxVars, "MinidoracatNB") or nil
    local value = type(options) == "table" and tonumber(rawget(options, "PopupMode")) or nil
    if value ~= POPUP_ALWAYS and value ~= POPUP_UNREAD and value ~= POPUP_NEVER then
        return POPUP_UNREAD
    end
    return value
end

-- 服主端的總開關（沙盒 boolean，預設開；缺 SandboxVars 分頁時也是開，與其他預設值同款）。
-- `false` 才關——CustomBooleanSandboxOption 走 Boolean.parseBoolean
-- （CustomBooleanSandboxOption.java:18），所以引擎給進來的一定是布林。
-- 玩家端另有自己的開關與音量（NBOptions，遊戲的「選項 -> MODS」分頁）：
-- 服主關掉時玩家怎麼設都不響，兩層是 AND 關係。
local function notifySoundEnabled()
    local options = type(SandboxVars) == "table"
        and rawget(SandboxVars, "MinidoracatNB") or nil
    if type(options) ~= "table" then
        return true
    end
    return rawget(options, "NotifySound") ~= false
end

-- 只在**這一批**確實跳了 toast 時響一次，而不是每則公告一次：首次同步逾時那條路徑
-- 會一次帶出所有未讀（notifyUnread(snapshot, nil)），逐則播就是連續叭好幾聲。
-- 音效名與音檔來源看 NOTIFY_SOUND 的註解（本檔上方），這裡不重複。
-- 播放本身：getSoundManager():playUISound（LuaManager.java:8028-8031 暴露；實作
-- SoundManager.java:193-227）在 uiSoundMuted、找不到音效名、或該 GameSound 沒有 clip 時
-- **自己回 0、不拋錯**，所以「沒聲音」不會有任何 Lua 端訊號——音檔是否真的在
-- MOD 裡由 scripts/verify_mod.py 的第 14 項閘門把關。
-- dedicated server 走 DummySoundManager.java:209 的空實作，但這支檔案只在 client 跑。
--
-- 音量：playUISound 沒有音量參數，但它回傳的就是 uiEmitter.playClip 的 instance ref
-- （SoundManager.java:201），而 uiEmitter 本身是公開的（getUIEmitter，:875-880；
-- BaseSoundEmitter 標 @UsedFromLua，BaseSoundEmitter.java:9）。對那個 ref 呼叫
-- setVolume 會寫進 Sound.volume（FMODSoundEmitter.java:284-298），而 FileSound.tick
-- 每幀把 channel 音量重算成 volume x clip.getEffectiveVolume()（:1242 -> :1559-1562），
-- 所以這個設定會**持續生效、不會被下一幀蓋掉**。這條路仍然是 UI emitter（與 playUISound
-- 同一個聲場、純本地），**刻意不用** character:getEmitter():playSound()——那個在 client 端
-- 會 INetworkPacket.send(PlaySound) 或 PlayWorldSound（:389-400），把個人通知廣播給其他玩家。
-- 只有音量 < 1 才呼叫：滿音量本來就是預設值，少一次 Java 呼叫。
local function playNoticeSound()
    if not notifySoundEnabled() then
        return
    end
    local volume = Options.soundVolume()
    if volume <= 0 then
        return
    end
    -- pcall：音效不是功能，任何一個環節出錯都不該讓「有新公告」這件事跟著失敗。
    local ok, soundError = pcall(function()
        local manager = getSoundManager()
        local reference = manager:playUISound(NOTIFY_SOUND)
        if volume < 1 and reference ~= nil and reference ~= 0 then
            manager:getUIEmitter():setVolume(reference, volume)
        end
    end)
    if not ok then
        print("[MinidoracatNoticeBoardFor42] notice sound failed: " .. tostring(soundError))
    end
end

local function firstUnreadId(snapshot)
    local files = type(snapshot) == "table" and rawget(snapshot, "files") or nil
    if type(files) ~= "table" then
        return nil
    end
    local index
    for index = 1, #files do
        local fileId = rawget(files[index], "id")
        if Client.isUnread(fileId) then
            return fileId
        end
    end
    return nil
end

local function snapshotHashes(snapshot)
    local hashes = {}
    local files = type(snapshot) == "table" and rawget(snapshot, "files") or nil
    if type(files) == "table" then
        local index
        for index = 1, #files do
            local file = files[index]
            hashes[rawget(file, "id")] = rawget(file, "h")
        end
    end
    return hashes
end

local function changedFileIds(snapshot, previousHashes)
    local changed = {}
    local files = type(snapshot) == "table" and rawget(snapshot, "files") or nil
    if type(files) == "table" then
        local index
        for index = 1, #files do
            local file = files[index]
            local fileId = rawget(file, "id")
            if rawget(previousHashes, fileId) ~= rawget(file, "h") then
                changed[fileId] = true
            end
        end
    end
    return changed
end

local function notifyUnread(snapshot, changed)
    local files = type(snapshot) == "table" and rawget(snapshot, "files") or nil
    if type(files) ~= "table" then
        return
    end
    local notified = false
    local index
    for index = 1, #files do
        local file = files[index]
        local fileId = rawget(file, "id")
        if (changed == nil or rawget(changed, fileId) == true) and Client.isUnread(fileId) then
            NBToast.show(getText("IGUI_MinidoracatNB_ToastNewContent", rawget(file, "title")))
            notified = true
        end
    end
    -- 一批一聲，且只有真的跳了 toast 才響（NBToast 自己還有 MAX_PENDING 的丟棄邏輯，
    -- 但那是視覺上的節流；聲音在這裡就已經收斂成一次，不受它影響）。
    if notified then
        playNoticeSound()
    end
end

-- **測試專用的閘，不是執行期入口**（比照 NBServer 暴露 processQueue／scanImages 的理由）：
-- 出貨路徑一個呼叫點都沒有，handleContentReady 走的是上面那個 local。
-- 留著是因為「一批公告只響一聲」與「沙盒關掉就不響」光讀碼保證不了，而從
-- handleContentReady 那端跑要把整個進場流程（ensureInstance／setSnapshot／頁籤重建）
-- 都 stub 起來，測到的多半是 stub 而不是這裡的收斂邏輯。
NBPanel.notifyUnread = notifyUnread

local function applyInitialPopup(snapshot)
    local mode = popupMode()
    local unreadId = firstUnreadId(snapshot)
    if mode == POPUP_ALWAYS then
        NBPanel.show(unreadId)
    elseif mode == POPUP_UNREAD and unreadId then
        NBPanel.show(unreadId)
    end
end

local handleContentReady

handleContentReady = function(snapshot)
    if type(snapshot) ~= "table" then
        return
    end

    local session = NBPanel.session
    if session.waiting and session.startedAtMs ~= 0
        and getTimestampMs() - session.startedAtMs >= POPUP_WAIT_MS then
        session.waiting = false
        session.timedOut = true
    end
    local firstContent = not session.contentReceived
    local languageSwitched = Client.consumeLanguageSwitch()
    local changed = changedFileIds(snapshot, session.hashes)
    session.hashes = snapshotHashes(snapshot)
    session.contentReceived = true
    session.waiting = false

    local preferred = firstContent and firstUnreadId(snapshot) or nil
    local panel = NBPanel.ensureInstance()
    panel:setSnapshot(snapshot, preferred)

    if firstContent then
        if session.timedOut then
            notifyUnread(snapshot, nil)
        elseif session.startedAtMs ~= 0 then
            applyInitialPopup(snapshot)
        end
    elseif not languageSwitched then
        notifyUnread(snapshot, changed)
    end
end

function NBPanel.onGameStart()
    local session = NBPanel.session
    session.startedAtMs = getTimestampMs()
    session.waiting = true
    session.timedOut = false
    session.contentReceived = false
    session.hashes = {}

    local panel = NBPanel.ensureInstance()
    panel.snapshot = nil
    panel.tabs = {}
    panel.selectedIndex = nil
    panel.contentState = "syncing"
    panel.richText:setVisible(false)
    panel:setVisible(false)

    if NBFloatButton and NBFloatButton.ensureInstance then
        NBFloatButton.ensureInstance()
    end

    local snapshot = Client.getSnapshot()
    if snapshot then
        handleContentReady(snapshot)
    end
end

function NBPanel.onTick()
    local session = NBPanel.session
    -- 圖片是漸進同步的：某張圖寫檔完成後要把目前這頁重畫一次，否則玩家會一直停在 [替代文字] 占位。
    local readyVersion = ImageCache.getReadyVersion()
    if readyVersion ~= session.imageReadyVersion then
        session.imageReadyVersion = readyVersion
        local panel = NBPanel.instance
        if panel and panel.selectedIndex then
            panel:renderSelected(false)
        end
    end

    if not session.waiting or session.contentReceived or session.startedAtMs == 0 then
        return
    end
    if getTimestampMs() - session.startedAtMs < POPUP_WAIT_MS then
        return
    end

    session.waiting = false
    session.timedOut = true
    local panel = NBPanel.instance
    if panel and not panel.snapshot then
        panel.contentState = "timeout"
        panel.richText:setVisible(false)
    end
end

function NBPanel.onContentReady(snapshot)
    handleContentReady(snapshot)
end

function NBPanel.onUnreadChanged(unreadIds)
    if NBPanel.instance then
        NBPanel.instance.unreadIds = unreadIds
    end
end

if not NBPanel._eventsInstalled then
    Events.OnGameStart.Add(NBPanel.onGameStart)
    Events.OnTick.Add(NBPanel.onTick)
    Events[Client.CONTENT_READY_EVENT].Add(NBPanel.onContentReady)
    Events[Client.UNREAD_CHANGED_EVENT].Add(NBPanel.onUnreadChanged)
    Events[Client.LANGUAGE_STATUS_EVENT].Add(onLanguageStatus)
    Events[ImageCache.STATUS_EVENT].Add(onImageStatus)
    NBPanel._eventsInstalled = true
end

return NBPanel
