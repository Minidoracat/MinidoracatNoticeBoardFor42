-- NBFloatButton：家族 UI 框架 FloatButton 的 thin wrapper。
--
-- 浮鈕本體（setCapture 拖曳＋4px 門檻、每幀 clamp、hover 疊色、圓角皮膚）
-- 已上移框架 `MinidoracatUI/Widgets/FloatButton.lua`。本檔只剩本 MOD 業務：
--   1. 內容繪製：置中喇叭圖標＋未讀紅點（徽章刻意「掛」在右上弧，UI_DESIGN §2）
--   2. 點擊 = NBPanel.toggle()
--   3. 位置持久化 = ISLayoutManager（layout.ini；RestoreLayout/SaveLayout
--      掛在框架實例上——DefaultRestoreWindow 呼叫的是實例方法）
--   4. 未讀事件（MinidoracatNB_UnreadChanged）→ setUnread
--
-- 【退回】框架 FloatButton 能力缺席時不建浮鈕（degraded：無浮動入口，
-- 面板仍可由重新載入鈕／其他入口開啟）；不自帶降級實作。

require "ISUI/ISLayoutManager"

if not NBClient then
    require "NoticeBoard/NBClient"
end
if not NBPanel then
    require "NoticeBoard/NBPanel"
end
if not NBSkin then
    require "NoticeBoard/NBSkin"
end

local Client = NBClient
local Skin = NBSkin
if not Client or not NBPanel or not Skin then
    error("NoticeBoard floating button dependencies failed to load")
end

NBFloatButton = NBFloatButton or {}

local COLORS = Skin.COLORS

local BUTTON_SIZE = 40
local RIGHT_MARGIN = 16
local LAYOUT_NAME = "MinidoracatNBFloatButton"

-- 喇叭圖標（MOD 自帶）。資產存 48px、顯示 24px：2:1 縮放在 GL_LINEAR 下最銳利
-- （貼圖 flags=0/4 → GL_LINEAR，`TextureID.java:423-424`）。
-- 圖是彩色的，drawTextureScaled 的 r/g/b 一律傳 1 保留原色（頂點色乘算，
-- `ISUIElement.lua:1032-1040`）——傳主題色會把它染成單色。
local ICON_PATH = "media/ui/NoticeBoard/nb_megaphone.png"
local ICON_SIZE = 24

local function frameworkFloatButton()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.floatButton == true then
        return ui.FloatButton
    end
    return nil
end

-- 內容繪製（框架畫完皮膚後回呼）：置中喇叭圖標＋未讀點
-- 圖標在建立時載入一次（btn.icon）；載不到就退回文字，per-frame 不重試貼圖
local function drawContent(btn)
    if btn.icon then
        btn:drawTextureScaled(btn.icon,
            math.floor((btn.width - ICON_SIZE) / 2),
            math.floor((btn.height - ICON_SIZE) / 2),
            ICON_SIZE, ICON_SIZE, 1, 1, 1, 1)
    else
        local textColor = COLORS.TITLE_TEXT
        local fontHeight = getTextManager():getFontHeight(UIFont.Medium)
        btn:drawTextCentre("!", btn.width / 2, (btn.height - fontHeight) / 2,
            textColor.r, textColor.g, textColor.b, textColor.a, UIFont.Medium)
    end
    if btn.unread then
        Skin.dot(btn, btn.width - 8, -2, 8, COLORS.UNREAD_DOT, COLORS.UNREAD_DOT_OUTLINE)
    end
end

function NBFloatButton.setUnread(unread)
    local btn = NBFloatButton.instance
    if btn then
        btn.unread = unread == true
    end
end

function NBFloatButton.ensureInstance()
    if NBFloatButton.instance then
        NBFloatButton.instance:setVisible(true)
        NBFloatButton.instance.unread = #Client.getUnreadIds() > 0
        return NBFloatButton.instance
    end

    local FW = frameworkFloatButton()
    if not FW then
        return nil -- 框架能力缺席：無浮鈕（面板其他入口不受影響）
    end

    local button = FW.new({
        size = BUTTON_SIZE,
        x = getCore():getScreenWidth() - BUTTON_SIZE - RIGHT_MARGIN,
        y = getCore():getScreenHeight() / 2 - BUTTON_SIZE / 2,
        colors = {
            surface = COLORS.BG_PANEL,
            hover = COLORS.TAB_HOVER_FILL,
            border = COLORS.BORDER,
        },
        drawContent = drawContent,
        onClick = function() NBPanel.toggle() end,
        -- 位置持久化走 ISLayoutManager（下方 Restore/SaveLayout），
        -- onMoved 不另存——SaveLayout 在遊戲存檔時機由引擎呼叫
    })
    button.unread = #Client.getUnreadIds() > 0

    -- 圖標載入一次就好（`getTexture` 走 `Texture.getSharedTexture`，本身有快取；
    -- 但仍不放在 drawContent 裡以免每幀查表）。dedicated 端回 null
    -- （`Texture.java:414-416`）、路徑打錯也是 null，兩者都退回文字繪製。
    local ok, tex = pcall(getTexture, ICON_PATH)
    button.icon = (ok and tex) or nil

    -- ISLayoutManager 整合：DefaultRestoreWindow/DefaultSaveWindow 呼叫
    -- window:RestoreLayout/SaveLayout（實例方法）——掛在框架實例上
    function button:RestoreLayout(name, layout)
        local x = tonumber(layout.x)
        local y = tonumber(layout.y)
        if x and y then
            self:setPosition(x, y) -- 框架 setPosition 內建 clamp（存檔位置超界夾回）
        end
        self:setVisible(true)
    end
    function button:SaveLayout(name, layout)
        layout.x = self:getX()
        layout.y = self:getY()
        layout.visible = "true"
    end

    NBFloatButton.instance = button
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, NBFloatButton, button)
    button:setVisible(true)
    return button
end

function NBFloatButton.onGameStart()
    NBFloatButton.ensureInstance()
end

function NBFloatButton.onUnreadChanged(unreadIds)
    local button = NBFloatButton.ensureInstance()
    if button then
        button.unread = type(unreadIds) == "table" and #unreadIds > 0
    end
end

if not NBFloatButton._eventsInstalled then
    Events.OnGameStart.Add(NBFloatButton.onGameStart)
    Events[Client.UNREAD_CHANGED_EVENT].Add(NBFloatButton.onUnreadChanged)
    NBFloatButton._eventsInstalled = true
end

return NBFloatButton
