-- NBSkin：本 MOD 色票的唯一權威來源＋家族 UI 框架（MinidoracatUIFor42）的 thin adapter。
--
-- 圓角繪製核心（NinePatchTexture 生命週期、fill/border/dot、直角退回）已上移框架
-- `MinidoracatUI/V1.lua`（該 repo docs/ARCHITECTURE.md），本檔只剩三件事：
--   1. 色票 COLORS（含本 MOD 自有 token：TAB_*／LINK／UNREAD_*／TOAST_*／ERROR_*）
--   2. 轉發 fill/border/dot/fits/reset 到框架 Skin（公開簽章與換皮前逐位相同，
--      topOnly boolean 直通——框架 shape 參數相容 boolean）
--   3. 框架不可用時的直角退回（drawRect／drawRectBorder／方點）
--
-- 【退回紅線】框架缺席（未安裝、版本不合、載入失敗）時本 MOD 的 UI 仍要能開——
-- 一律退直角，絕不 error。正式發佈以 mod.info 的 `require=MinidoracatUIFor42`
-- 保證框架先載入（引擎依賴先排 load order，ZomboidFileSystem.java:807-833）；
-- 這裡的動態檢查涵蓋測試 harness 與異常環境。
--
-- 【API 契約】框架同 major 只做 additive 變更；本 MOD 需要 API v1 rev>=1
-- （fill/border/dot/fits/_resetForTests）。breaking 變更＝框架開新 MOD ID，
-- 本檔的檢查會讓舊框架自然走退回而不是帶病運行。

if not (MinidoracatUI and MinidoracatUI.v1) then
    -- 測試環境／異常順序防禦：Kahlua require 對缺檔的行為未查證，pcall 包住
    pcall(require, "MinidoracatUI/V1")
end

NBSkin = NBSkin or {}

-- 全 MOD 色票的唯一權威來源（docs/UI_DESIGN.md §0）。r,g,b,a 皆 0-1 浮點。
-- 值刻意保持字面（不從框架 theme 取）：框架缺席時色票也要在。
NBSkin.COLORS = {
    BG_PANEL = { r = 0, g = 0, b = 0, a = 0.8 },
    BORDER = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 },
    TITLE_TEXT = { r = 1, g = 1, b = 1, a = 1.0 },
    -- 標題列疊色：畫在 BG_PANEL 面板底之上，取代原生 Panel_TitleBar.png（直角條與 r=6 相衝）
    TITLEBAR_FILL = { r = 1, g = 1, b = 1, a = 0.10 },
    TAB_TRAY_BG = { r = 0, g = 0, b = 0, a = 0.5 },
    TAB_SELECTED_FILL = { r = 1, g = 1, b = 1, a = 0.12 },
    TAB_HOVER_FILL = { r = 1, g = 1, b = 1, a = 0.06 },
    TAB_TEXT_SELECTED = { r = 1, g = 1, b = 1, a = 1.0 },
    TAB_TEXT_UNSELECTED = { r = 0.7, g = 0.7, b = 0.7, a = 1.0 },
    ACCENT_AMBER = { r = 1, g = 0.85, b = 0.4, a = 1.0 },
    LINK = { r = 0.45, g = 0.75, b = 1.0, a = 1.0 },
    -- 與 LINK 的落差刻意拉大：原本 (0.65,0.85,1.0) 只比 LINK 稍亮，玩家看不出游標在連結上
    LINK_HOVER = { r = 0.9, g = 0.97, b = 1.0, a = 1.0 },
    UNREAD_DOT = { r = 0.85, g = 0.15, b = 0.15, a = 1.0 },
    UNREAD_DOT_OUTLINE = { r = 0, g = 0, b = 0, a = 0.6 },
    ERROR_BG = { r = 0.3, g = 0.05, b = 0.05, a = 0.5 },
    ERROR_TEXT = { r = 0.9, g = 0.35, b = 0.3, a = 1.0 },
    PLACEHOLDER_TEXT = { r = 0.55, g = 0.55, b = 0.55, a = 1.0 },
    TOAST_BG = { r = 0, g = 0, b = 0, a = 0.85 },
    TOAST_BORDER = { r = 1, g = 0.85, b = 0.4, a = 0.9 },
}

-- 載入期綁定：mod.info require= 保證框架的 lua 已全部先執行（見檔頭）。
-- 版本不合＝當框架不存在處理（走退回），不帶半套狀態運行。
local FW = nil
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 1 and ui.Skin then
        FW = ui.Skin
    end
end

-- 只給測試用：三態環境切換時清框架的貼圖載入狀態
function NBSkin.reset()
    if FW then
        FW._resetForTests()
    end
end

-- 矩形夠不夠大到能走 9-slice。框架缺席一律 false（沒有貼圖可畫，fill/border 直接退直角）。
function NBSkin.fits(width, height, topOnly)
    if FW then
        return FW.fits(width, height, topOnly)
    end
    return false
end

-- 圓角填色。topOnly=true 只圓上兩角（標題列、頁籤）。alphaScale 是動畫用的 alpha 乘數。
function NBSkin.fill(element, x, y, width, height, color, topOnly, alphaScale)
    if FW then
        return FW.fill(element, x, y, width, height, color, topOnly, alphaScale)
    end
    element:drawRect(x, y, width, height,
        (color.a or 1) * (alphaScale or 1), color.r, color.g, color.b)
end

-- 1px 圓角邊框。topOnly=true 是上圓、底邊開放的 3 邊框（頁籤）。
function NBSkin.border(element, x, y, width, height, color, topOnly, alphaScale)
    if FW then
        return FW.border(element, x, y, width, height, color, topOnly, alphaScale)
    end
    element:drawRectBorder(x, y, width, height,
        (color.a or 1) * (alphaScale or 1), color.r, color.g, color.b)
end

-- 未讀圓點：框架畫光暈＋主點；退回方點＋描邊。
function NBSkin.dot(element, x, y, size, color, outline)
    if FW then
        return FW.dot(element, x, y, size, color, outline)
    end
    element:drawRect(x, y, size, size, color.a or 1, color.r, color.g, color.b)
    if outline then
        element:drawRectBorder(x, y, size, size,
            outline.a or 1, outline.r, outline.g, outline.b)
    end
end

return NBSkin
