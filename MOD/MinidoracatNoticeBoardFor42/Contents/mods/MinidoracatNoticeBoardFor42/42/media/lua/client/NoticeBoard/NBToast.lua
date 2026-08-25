require "ISUI/ISPanel"

if not NBSkin then
    require "NoticeBoard/NBSkin"
end

local Skin = NBSkin
if not Skin then
    error("NoticeBoard toast dependencies failed to load")
end

NBToast = ISPanel:derive("NBToast")

local COLORS = Skin.COLORS

local WIDTH = 300
local HEIGHT = 56
local SCREEN_MARGIN = 16
local STACK_TOP = 60
local STACK_GAP = 8
local ENTER_MS = 250
local HOLD_MS = 3000
local EXIT_MS = 400
local MAX_VISIBLE = 3
-- pending 佇列上限：首次同步逐檔通知時，20 則公告 = 73 秒連續彈窗（違反「通知輕量」）。
-- 超過即丟棄——浮窗紅點已足以表示「有多則未讀」。
local MAX_PENDING = 5

NBToast.active = NBToast.active or {}
NBToast.pending = NBToast.pending or {}

-- 逐字遞減會變成 O(n²)（每輪一次 MeasureStringX＋一次 string.sub）；超長訊息會讓主執行緒凍結數秒。
-- 先硬性截到 MAX_FIT_UNITS，再二分搜尋合適長度，量測次數降為 O(log n)。
local MAX_FIT_UNITS = 512

local function isHighSurrogate(unit)
    return unit ~= nil and unit >= 55296 and unit <= 56319
end

local function fitText(text, maximumWidth)
    local manager = getTextManager()
    if manager:MeasureStringX(UIFont.NewSmall, text) <= maximumWidth then
        return text
    end

    if string.len(text) > MAX_FIT_UNITS then
        local cut = MAX_FIT_UNITS
        if isHighSurrogate(string.byte(text, cut)) then
            cut = cut - 1
        end
        text = string.sub(text, 1, cut)
    end

    local suffix = "..."
    local low, high, best = 0, string.len(text), nil
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local cut = mid
        -- 截點落在 surrogate pair 中間會畫出孤立 surrogate
        if cut > 0 and isHighSurrogate(string.byte(text, cut)) then
            cut = cut - 1
        end
        local candidate = string.sub(text, 1, cut) .. suffix
        if manager:MeasureStringX(UIFont.NewSmall, candidate) <= maximumWidth then
            best = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return best or suffix
end

local function activeIndex(toast)
    local index
    for index = 1, #NBToast.active do
        if NBToast.active[index] == toast then
            return index
        end
    end
    return 1
end

local function activate(message)
    local toast = NBToast:new(message)
    toast:initialise()
    toast:addToUIManager()
    toast:setVisible(true)
    NBToast.active[#NBToast.active + 1] = toast
    return toast
end

function NBToast.dismiss(toast)
    local index
    for index = #NBToast.active, 1, -1 do
        if NBToast.active[index] == toast then
            table.remove(NBToast.active, index)
            break
        end
    end

    toast:setVisible(false)
    toast:removeFromUIManager()

    if #NBToast.pending > 0 and #NBToast.active < MAX_VISIBLE then
        local message = table.remove(NBToast.pending, 1)
        activate(message)
    end
end

function NBToast.show(message)
    if type(message) ~= "string" or message == "" then
        return nil
    end

    if #NBToast.active >= MAX_VISIBLE then
        if #NBToast.pending >= MAX_PENDING then
            return nil
        end
        NBToast.pending[#NBToast.pending + 1] = message
        return nil
    end
    return activate(message)
end

function NBToast:prerender()
    local elapsed = getTimestampMs() - self.startedAtMs
    local totalDuration = ENTER_MS + HOLD_MS + EXIT_MS
    if elapsed >= totalDuration then
        NBToast.dismiss(self)
        return
    end

    local index = activeIndex(self)
    local targetX = getCore():getScreenWidth() - self.width - SCREEN_MARGIN
    local targetY = STACK_TOP + (index - 1) * (self.height + STACK_GAP)
    local x = targetX
    local y = targetY
    local alpha = 1

    if elapsed < ENTER_MS then
        local fraction = elapsed / ENTER_MS
        local startX = getCore():getScreenWidth() + self.width
        x = startX + (targetX - startX) * fraction
        alpha = fraction
    elseif elapsed >= ENTER_MS + HOLD_MS then
        local fraction = (elapsed - ENTER_MS - HOLD_MS) / EXIT_MS
        alpha = 1 - fraction
        y = targetY - 10 * fraction
    end

    self:setX(x)
    self:setY(y)

    -- 四角 r=6；動畫期間 x 是小數，NBSkin 內部會 floor 絕對座標再交給 NinePatchTexture
    local textColor = COLORS.TITLE_TEXT
    Skin.fill(self, 0, 0, self.width, self.height, COLORS.TOAST_BG, false, alpha)
    Skin.border(self, 0, 0, self.width, self.height, COLORS.TOAST_BORDER, false, alpha)
    self:drawText(self.titleText, 8, 7,
        textColor.r, textColor.g, textColor.b, textColor.a * alpha, UIFont.NewSmall)
    self:drawText(self.message, 8, 10 + self.fontHeight,
        textColor.r, textColor.g, textColor.b, textColor.a * alpha, UIFont.NewSmall)
end

function NBToast:new(message)
    local x = getCore():getScreenWidth() + WIDTH
    local o = ISPanel.new(self, x, STACK_TOP, WIDTH, HEIGHT)
    o.background = false
    o.alwaysOnTop = true
    o.startedAtMs = getTimestampMs()
    o.fontHeight = getTextManager():getFontHeight(UIFont.NewSmall)
    o.titleText = getText("IGUI_MinidoracatNB_PanelTitle")
    o.message = fitText(message, WIDTH - 16)
    return o
end

return NBToast
