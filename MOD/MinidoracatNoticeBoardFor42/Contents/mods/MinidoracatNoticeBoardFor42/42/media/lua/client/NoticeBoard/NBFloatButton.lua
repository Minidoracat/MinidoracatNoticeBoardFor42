-- NBFloatButton：家族 UI 框架 FloatButton 的 thin wrapper。
--
-- 浮鈕本體（setCapture 拖曳＋4px 門檻、每幀 clamp、hover 疊色、圓角皮膚）
-- 已上移框架 `MinidoracatUI/Widgets/FloatButton.lua`。本檔只剩本 MOD 業務：
--   1. 內容繪製：置中喇叭圖標＋未讀紅點（徽章刻意「掛」在右上弧，UI_DESIGN §2）
--   2. 點擊 = NBPanel.toggle()
--   3. 位置持久化 = ISLayoutManager（layout.ini）：回呼掛在 **NBFloatButton 表**上，
--      因為原版呼叫的是 `funcs.RestoreLayout(target, name, layout)`
--      （`ISLayoutManager.lua:99-113`）——掛在實例上永遠不會被呼叫。
--      拖曳放開即存（onMoved），不等遊戲存檔時機
--   4. 解析度變更：重套當前解析度的紀錄（原版只在 RegisterWindow 時 TryRestore）
--   5. 未讀事件（MinidoracatNB_UnreadChanged）→ setUnread
--   6. 入口顯示選項（「選項 → MODS」的 show_button，NBOptions.showButton）：Dock 入口與浮鈕共用
--   7. 快捷鍵 MinidoracatNoticeBoard_Toggle（選項 → 按鍵綁定）= NBPanel.toggle()
--
-- 【家族工具列】框架有 Dock（CAPABILITIES.dock，API rev 13）時，第一次 ensureInstance
-- 登記成 Dock 入口、不建浮鈕；之後未讀變動改呼叫 Dock.refresh()。登記失敗或框架沒有
-- Dock 才走下面的浮鈕。
-- 【退回】框架 FloatButton 能力也缺席時不建浮鈕（degraded：無浮動入口，
-- 面板仍可由快捷鍵與自動彈出開啟）；不自帶降級實作。

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
if not NBOptions then
    require "NoticeBoard/NBOptions"
end

local Client = NBClient
local Skin = NBSkin
if not Client or not NBPanel or not Skin or not NBOptions then
    error("NoticeBoard floating button dependencies failed to load")
end

NBFloatButton = NBFloatButton or {}

local COLORS = Skin.COLORS

local BUTTON_SIZE = 40
local RIGHT_MARGIN = 16
local LAYOUT_NAME = "MinidoracatNBFloatButton"
-- 快捷鍵綁定名：keyBinding 登記與 Dock 的 bind（提示顯示「名稱（快捷鍵 X）」）共用，避免拼錯
local TOGGLE_BIND = "MinidoracatNoticeBoard_Toggle"

-- 喇叭圖標（MOD 自帶）。資產存 48px、顯示 24px：2:1 縮放在 GL_LINEAR 下最銳利
-- （貼圖 flags=0/4 → GL_LINEAR，`TextureID.java:423-424`）。
-- 圖是彩色的，drawTextureScaled 的 r/g/b 一律傳 1 保留原色（頂點色乘算，
-- `ISUIElement.lua:1032-1040`）——傳主題色會把它染成單色。
local ICON_PATH = "media/ui/NoticeBoard/nb_megaphone.png"
local ICON_SIZE = 24

-- 預設槽位：右緣往內 16px、垂直居中。建立時與「解析度沒有紀錄」時共用同一份公式，
-- 否則換螢幕後浮鈕會落在跟第一次開遊戲不一樣的地方。
local function defaultX() return getCore():getScreenWidth() - BUTTON_SIZE - RIGHT_MARGIN end
local function defaultY() return getCore():getScreenHeight() / 2 - BUTTON_SIZE / 2 end

local function frameworkFloatButton()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.floatButton == true then
        return ui.FloatButton
    end
    return nil
end

-- 未讀狀態：浮鈕紅點與 Dock 徽章共用（事件時更新，Dock 每幀讀它不必配置 table）
local unread = false
local dock = nil -- 登記成功後的 UI.Dock

local function panelTitle() return getText("IGUI_MinidoracatNB_PanelTitle") end
local function togglePanel() NBPanel.toggle() end -- 呼叫時查表（測試與重載會換掉）

-- Dock 回呼每幀可能被呼叫：只讀現成狀態，不建 table、不拋錯
local DOCK_SPEC = {
    id = "noticeboard",
    order = 20,
    label = panelTitle,
    icon = ICON_PATH,
    onClick = togglePanel,
    isActive = function()
        local panel = NBPanel.instance
        return panel ~= nil and panel:getIsVisible() == true
    end,
    getBadge = function()
        if unread then return -1 end
        return 0
    end,
    getStatus = function()
        if unread then return getText("IGUI_MinidoracatNB_DockUnread") end
        return nil
    end,
    -- 玩家選項關掉就不顯示（NBOptions.showButton 讀快取布林，不配置）；
    -- 遊戲外／沒有玩家時的隱藏由 Dock 自己處理，與框架浮鈕的自我隱藏相同。
    isAvailable = function() return NBOptions.showButton() end,
    bind = TOGGLE_BIND,
}

-- 只登記一次；能力缺席或 register 回 false → 回 nil，呼叫端走浮鈕。
local function dockApi()
    if dock then
        return dock
    end
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.CAPABILITIES and ui.CAPABILITIES.dock and ui.Dock
        and ui.Dock.register(DOCK_SPEC) == true then
        dock = ui.Dock
    end
    return dock
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

-- 位置來自可編輯的 layout.ini；拒絕非有限值，普通負值仍交框架夾回。
local function coord(value)
    local number = tonumber(value)
    if number and number == number and number ~= math.huge and number ~= -math.huge then
        return number
    end
    return nil
end

-- ISLayoutManager 回呼（原版：`funcs.RestoreLayout(target, name, layout)`）。
-- 只管座標：可見性是本 MOD 自己的政策（玩家選項，經 ensureInstance 收斂），layout 不得插手，
-- 否則玩家藏起來的浮鈕會在還原時被強開回來。
function NBFloatButton.RestoreLayout(button, name, layout)
    local x, y = coord(layout.x), coord(layout.y)
    if x and y then
        button:setPosition(x, y) -- 框架 setPosition 內建 clamp（存檔位置超界夾回）
    end
end

function NBFloatButton.SaveLayout(button, name, layout)
    layout.x = button:getX()
    layout.y = button:getY()
    layout.visible = nil -- 不再持久化可見性
end

function NBFloatButton.setUnread(value)
    unread = value == true
    local btn = NBFloatButton.instance
    if btn then
        btn.unread = unread
    elseif dock then
        dock.refresh()
    end
end

-- OnGameStart、OnCreatePlayer(0)、未讀事件與選項套用共用的收斂點：可見性一律照玩家選項，
-- 所以任何事件都不會把玩家藏起來的浮鈕叫回來。
function NBFloatButton.ensureInstance()
    unread = #Client.getUnreadIds() > 0
    local show = NBOptions.showButton()
    local existing = NBFloatButton.instance
    if existing then
        existing.unread = unread
        if show then
            existing:setVisible(true)
        else
            existing:hideTooltip() -- 隱藏後 prerender 停跑，提示要在這裡收（框架方法）
            existing:setVisible(false)
        end
        return existing
    end

    local Dock = dockApi()
    if Dock then
        Dock.refresh()
        return nil -- 已收進家族工具列：不建浮鈕
    end
    if not show then
        return nil -- 玩家關掉入口：不建，打開時由 onOptionsApplied 建
    end

    local FW = frameworkFloatButton()
    if not FW then
        return nil -- 框架能力缺席：無浮鈕（面板其他入口不受影響）
    end

    local button = FW.new({
        size = BUTTON_SIZE,
        alwaysOnTop = false, -- 入口不覆蓋後開的設定視窗或確認框。
        x = defaultX(),
        y = defaultY(),
        colors = {
            surface = COLORS.BG_PANEL,
            hover = COLORS.TAB_HOVER_FILL,
            border = COLORS.BORDER,
        },
        drawContent = drawContent,
        onClick = togglePanel,
        getTooltip = panelTitle, -- 純圖示控制項要有名稱（原版側欄每顆都有，ISEquippedItem.lua:751）
        -- 只保存版面，不廣播會觸發其他 listener 的存檔事件。
        onMoved = ISLayoutManager.OnPostSave,
    })
    button.unread = unread

    -- 圖標載入一次就好（`getTexture` 走 `Texture.getSharedTexture`，本身有快取；
    -- 但仍不放在 drawContent 裡以免每幀查表）。dedicated 端回 null
    -- （`Texture.java:414-416`）、路徑打錯也是 null，兩者都退回文字繪製。
    local ok, tex = pcall(getTexture, ICON_PATH)
    button.icon = (ok and tex) or nil

    NBFloatButton.instance = button
    ISLayoutManager.RegisterWindow(LAYOUT_NAME, NBFloatButton, button) -- 內含 TryRestore
    button:setVisible(true)
    return button
end

function NBFloatButton.onGameStart()
    NBFloatButton.ensureInstance()
end

-- Core.java:2242-2262 先更新尺寸才發事件；未建立時不建，還原不改可見性或寫檔。
function NBFloatButton.onResolutionChange()
    local button = NBFloatButton.instance
    if not button then
        return
    end
    button:setPosition(defaultX(), defaultY()) -- 新解析度沒有紀錄時的落點
    ISLayoutManager.TryRestore(LAYOUT_NAME)
end

function NBFloatButton.onUnreadChanged(unreadIds)
    NBFloatButton.ensureInstance()
    NBFloatButton.setUnread(type(unreadIds) == "table" and #unreadIds > 0)
end

-- NBOptions 的 options:apply（玩家按套用）呼叫：已登記 Dock 就請它重算 isAvailable；
-- 否則只在遊戲中（有玩家 0）建立或收起浮鈕，主選單按套用不建任何東西。
function NBFloatButton.onOptionsApplied()
    if dock then
        dock.refresh()
    elseif getSpecificPlayer(0) then
        NBFloatButton.ensureInstance()
    end
end

-- 快捷鍵（選項 → 按鍵綁定 → [MinidoracatNoticeBoard] 可改鍵），寫法同 MiniMap 的 initBinds。
-- 預設 Insert（Keyboard.KEY_INSERT = 210）：原版 shared/keyBinding.lua（42.21.0）未綁；原版 Lua
-- 全樹 0 次（KEY_INSERT 與裸 210）；反編譯 Java 只出現在鍵碼對照表
-- （org/lwjglx/input/KeyCodes.java 210 <-> GLFW 260），沒有遊戲邏輯直接讀；家族 MOD 未用；
-- 本機 Workshop 424 個項目只有預設關閉的開發工具（PZIceAndFireComplete AttachmentTweaker），
-- 以及 KI5 兩台車（91range、87toyotaMR2）寫死 key == 210 開關天窗、只在坐進該車時作用。
-- 按鍵設定畫面顯示「INSERT」。
function NBFloatButton.onGameBoot()
    table.insert(keyBinding, { value = "[MinidoracatNoticeBoard]" })
    table.insert(keyBinding, { value = TOGGLE_BIND, key = Keyboard.KEY_INSERT })
end

-- OnKeyPressed 在放開時觸發、文字輸入中不派送（GameKeyboard.java:43-52）；綁定被清空或
-- 不存在時 getKey 回 0（Core.java:2812-2821），所以先擋 0。主選單沒有玩家 0：不開面板。
-- 與入口顯示選項無關：藏起按鈕的玩家靠它開公告欄。
function NBFloatButton.onKeyPressed(key)
    if key ~= 0 and key == getCore():getKey(TOGGLE_BIND) and getSpecificPlayer(0) then
        NBPanel.toggle() -- 呼叫時查表（測試與重載會換掉）
    end
end

if not NBFloatButton._eventsInstalled then
    Events.OnGameBoot.Add(NBFloatButton.onGameBoot)
    Events.OnKeyPressed.Add(NBFloatButton.onKeyPressed)
    Events.OnGameStart.Add(NBFloatButton.onGameStart)
    Events.OnCreatePlayer.Add(function(playerNum)
        if playerNum == 0 then NBFloatButton.ensureInstance() end
    end)
    Events.OnResolutionChange.Add(NBFloatButton.onResolutionChange)
    Events[Client.UNREAD_CHANGED_EVENT].Add(NBFloatButton.onUnreadChanged)
    NBFloatButton._eventsInstalled = true
end

return NBFloatButton
