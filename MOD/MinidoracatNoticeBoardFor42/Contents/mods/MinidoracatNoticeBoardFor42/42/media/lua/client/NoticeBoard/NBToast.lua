-- NBToast：家族 UI 框架 Toast 的 thin wrapper。
--
-- 通知堆疊本體（滑入/停留/淡出動畫、MAX_VISIBLE 3、pending 5、surrogate-safe
-- 截字）已上移框架 `MinidoracatUI/Widgets/Toast.lua`，且堆疊是**全域共用**
-- ——本 MOD 與其他家族 MOD 同時通知不會互相重疊。本檔只剩：
--   1. 保留 `NBToast.show(message)` 既有簽章（12 個呼叫端不動）
--   2. 帶上本 MOD 的 title（面板標題）與色票（TOAST_BG/TOAST_BORDER/TITLE_TEXT）
--
-- 【退回】框架 Toast 能力缺席（CAPABILITIES.toast ~= true）時 show 靜默 no-op
-- 回 nil——通知是輔助回饋，面板本體與浮鈕紅點不受影響；不自帶降級實作。

if not NBSkin then
    require "NoticeBoard/NBSkin"
end

local Skin = NBSkin
if not Skin then
    error("NoticeBoard toast dependencies failed to load")
end

NBToast = NBToast or {}

local COLORS = Skin.COLORS

local function frameworkToast()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.toast == true then
        return ui.Toast
    end
    return nil
end
local FW = frameworkToast()

-- 色票整顆傳框架（color table 引用；NBSkin.COLORS 是唯一權威）
local TOAST_COLORS = {
    surface = COLORS.TOAST_BG,
    border = COLORS.TOAST_BORDER,
    text = COLORS.TITLE_TEXT,
}

function NBToast.show(message)
    if not FW then
        return nil
    end
    if type(message) ~= "string" or message == "" then
        return nil
    end
    return FW.show({
        title = getText("IGUI_MinidoracatNB_PanelTitle"),
        message = message,
        colors = TOAST_COLORS,
    })
end

return NBToast
