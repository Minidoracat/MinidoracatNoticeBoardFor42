require "ISUI/ISPanel"
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

NBFloatButton = ISPanel:derive("NBFloatButton")

local COLORS = Skin.COLORS

local BUTTON_SIZE = 40
local RIGHT_MARGIN = 16
local LAYOUT_NAME = "MinidoracatNBFloatButton"

function NBFloatButton:initialise()
    ISPanel.initialise(self)
end

function NBFloatButton:prerender()
    -- 四角 r=6 的方鈕（與面板同一組貼圖）；貼圖缺時 NBSkin 自動退回 drawRect 直角
    Skin.fill(self, 0, 0, self.width, self.height, COLORS.BG_PANEL)
    if self:isMouseOver() then
        Skin.fill(self, 0, 0, self.width, self.height, COLORS.TAB_HOVER_FILL)
    end
    Skin.border(self, 0, 0, self.width, self.height, COLORS.BORDER)

    local textColor = COLORS.TITLE_TEXT
    local fontHeight = getTextManager():getFontHeight(UIFont.Medium)
    self:drawTextCentre("!", self.width / 2, (self.height - fontHeight) / 2,
        textColor.r, textColor.g, textColor.b, textColor.a, UIFont.Medium)

    if self.unread then
        -- 徽章刻意「掛」在右上弧上（UI_DESIGN §2），位置不變
        Skin.dot(self, self.width - 8, -2, 8, COLORS.UNREAD_DOT, COLORS.UNREAD_DOT_OUTLINE)
    end
end

function NBFloatButton:onMouseDown(x, y)
    if not self:getIsVisible() then
        return false
    end
    self.downX = x
    self.downY = y
    self.moving = true
    self.dragged = false
    self:bringToTop()
    return true
end

local function moveButton(button, dx, dy)
    if not button.moving then
        return
    end
    if dx ~= 0 or dy ~= 0 then
        button.dragged = true
    end
    -- 夾在畫面內，否則浮窗可被拖出視野，要等下次啟動 RestoreLayout 才夾回。
    local maximumX = math.max(0, getCore():getScreenWidth() - button.width)
    local maximumY = math.max(0, getCore():getScreenHeight() - button.height)
    button:setX(math.max(0, math.min(button.x + dx, maximumX)))
    button:setY(math.max(0, math.min(button.y + dy, maximumY)))
    button:bringToTop()
end

function NBFloatButton:onMouseMove(dx, dy)
    self.mouseOver = true
    moveButton(self, dx, dy)
end

function NBFloatButton:onMouseMoveOutside(dx, dy)
    self.mouseOver = false
    moveButton(self, dx, dy)
end

function NBFloatButton:onMouseUp(x, y)
    if not self.moving then
        return false
    end
    local wasDragged = self.dragged
    self.moving = false
    self.dragged = false
    if not wasDragged then
        NBPanel.toggle()
    end
    return true
end

function NBFloatButton:onMouseUpOutside(x, y)
    self.moving = false
    self.dragged = false
    return true
end

function NBFloatButton:setUnread(unread)
    self.unread = unread == true
end

function NBFloatButton:RestoreLayout(name, layout)
    local x = tonumber(layout.x)
    local y = tonumber(layout.y)
    if x ~= nil and y ~= nil then
        local maximumX = math.max(0, getCore():getScreenWidth() - self.width)
        local maximumY = math.max(0, getCore():getScreenHeight() - self.height)
        self:setX(math.max(0, math.min(x, maximumX)))
        self:setY(math.max(0, math.min(y, maximumY)))
    end
    self:setVisible(true)
end

function NBFloatButton:SaveLayout(name, layout)
    layout.x = self:getX()
    layout.y = self:getY()
    layout.width = self:getWidth()
    layout.height = self:getHeight()
    layout.visible = "true"
end

function NBFloatButton:new(x, y)
    local o = ISPanel.new(self, x, y, BUTTON_SIZE, BUTTON_SIZE)
    o.background = false
    o.alwaysOnTop = true
    o.moving = false
    o.dragged = false
    o.unread = false
    return o
end

function NBFloatButton.ensureInstance()
    if NBFloatButton.instance then
        NBFloatButton.instance:setVisible(true)
        NBFloatButton.instance:setUnread(#Client.getUnreadIds() > 0)
        return NBFloatButton.instance
    end

    local x = getCore():getScreenWidth() - BUTTON_SIZE - RIGHT_MARGIN
    local y = getCore():getScreenHeight() / 2 - BUTTON_SIZE / 2
    local button = NBFloatButton:new(x, y)
    button:initialise()
    button:addToUIManager()
    button:setVisible(true)
    button:setUnread(#Client.getUnreadIds() > 0)
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
    button:setUnread(type(unreadIds) == "table" and #unreadIds > 0)
end

if not NBFloatButton._eventsInstalled then
    Events.OnGameStart.Add(NBFloatButton.onGameStart)
    Events[Client.UNREAD_CHANGED_EVENT].Add(NBFloatButton.onUnreadChanged)
    NBFloatButton._eventsInstalled = true
end

return NBFloatButton
