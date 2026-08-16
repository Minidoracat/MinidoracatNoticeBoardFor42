require "PZAPI/ModOptions"

-- 玩家端的 MOD 設定，掛在遊戲原生的「選項 -> MODS」分頁（不是自己另做一個視窗）。
-- 走 PZ 內建的 PZAPI.ModOptions（media/lua/client/PZAPI/ModOptions.lua）：
--   * MainOptions:create() 只在 #PZAPI.ModOptions.Data ~= 0 時建立那個分頁
--     （MainOptions.lua:409-411），所以**註冊必須在檔案載入當下就做**，不能等遊戲內事件；
--     主選單初始化比任何 OnGameStart 都早。
--   * 值由 PZAPI.ModOptions:load() 從 <cachedir>/Lua/ModOptions.ini 讀回
--     （ModOptions.lua:292-320，`類型|模組ID|選項ID|值` 的一行一筆格式），
--     由 addModOptionsPanel() 在建立分頁時呼叫（MainOptions.lua:2796）；
--     按下 Apply 時 options:apply() + ModOptions:save() 寫回（MainOptions.lua:3760-3766）。
--   * 因此本檔**不自己讀寫檔案**：多一份持久化就是多一個與 ModOptions.ini 分岔的來源。
--     這也是它與語系偏好（NoticeBoard/settings.ini）的分工——那份是 MOD 自己的狀態，
--     而音效是玩家偏好，交給引擎的設定檔統一管理。
NBOptions = NBOptions or {}

local OPTIONS_ID = "MinidoracatNoticeBoard"
-- 預設 60%：自帶音效不受玩家的「音效音量」選項影響（見 NBPanel 的 NOTIFY_SOUND 註解），
-- 資產本身已壓在峰值 0.32，再乘 0.6 是「聽得到但不搶戲」的起點；玩家可自行拉到 100。
local DEFAULT_VOLUME = 60
local VOLUME_STEP = 5

NBOptions.SOUND_ENABLED = "sound_enabled"
NBOptions.SOUND_VOLUME = "sound_volume"

local function registerOptions()
    if type(PZAPI) ~= "table" or type(PZAPI.ModOptions) ~= "table" then
        return nil
    end
    local existing = PZAPI.ModOptions:getOptions(OPTIONS_ID)
    if existing then
        return existing
    end

    local options = PZAPI.ModOptions:create(OPTIONS_ID,
        getText("IGUI_MinidoracatNB_PanelTitle"))
    options:addTickBox(NBOptions.SOUND_ENABLED,
        getText("IGUI_MinidoracatNB_OptSoundEnabled"), true,
        getText("IGUI_MinidoracatNB_OptSoundEnabledTip"))
    options:addSlider(NBOptions.SOUND_VOLUME,
        getText("IGUI_MinidoracatNB_OptSoundVolume"),
        0, 100, VOLUME_STEP, DEFAULT_VOLUME,
        getText("IGUI_MinidoracatNB_OptSoundVolumeTip"))
    return options
end

-- 註冊失敗（PZAPI 不存在＝跑在沒有 client Lua 的環境，或測試 harness）不得讓整個 MOD 掛掉：
-- 讀值那邊一律有預設值可退。
local registerOk, registered = pcall(registerOptions)
if not registerOk then
    print("[MinidoracatNoticeBoardFor42] mod options register failed: " .. tostring(registered))
    registered = nil
end
NBOptions._options = registered

-- ModOptions.ini 的值只由 PZAPI.ModOptions:load() 讀回，而全庫唯一的呼叫點是
-- MainOptions:addModOptionsPanel()（MainOptions.lua:2796）——也就是「有人建立過選項畫面」。
-- 正常流程確實會走到（MainScreen 初始化就 MainOptions:new，MainScreen.lua:177），但把
-- 「玩家的設定有沒有生效」押在別人的建立時機上太脆弱：這裡自己補一次，只做一次、
-- 失敗就退回預設值。重複 load 無害（它只是照 ini 覆寫 option.value），而玩家在遊戲中
-- 按下 Apply 走的是 options:apply() + save()（MainOptions.lua:3760-3766），改的是同一份
-- option.value，所以先 load 過不會蓋掉之後的修改。
local loadAttempted = false

local function ensureLoaded()
    if loadAttempted then
        return
    end
    loadAttempted = true
    if type(PZAPI) ~= "table" or type(PZAPI.ModOptions) ~= "table"
        or type(PZAPI.ModOptions.load) ~= "function" then
        return
    end
    local ok, loadError = pcall(function()
        PZAPI.ModOptions:load()
    end)
    if not ok then
        print("[MinidoracatNoticeBoardFor42] mod options load failed: " .. tostring(loadError))
    end
end

local function optionValue(id, fallback)
    ensureLoaded()
    local options = NBOptions._options
    if type(options) ~= "table" or type(options.getOption) ~= "function" then
        return fallback
    end
    -- getValue 是選項自己身上的 closure（ModOptions.lua:43,215），選項不存在時回 nil。
    local ok, value = pcall(function()
        local option = options:getOption(id)
        if option == nil or type(option.getValue) ~= "function" then
            return nil
        end
        return option:getValue()
    end)
    if not ok or value == nil then
        return fallback
    end
    return value
end

-- 提示音的最終音量（0..1）。0 = 不要播。
-- 勾選框與滑桿是兩個獨立語意：關掉勾選＝完全不響（保留音量設定值），
-- 音量拉到 0 也是不響——兩者都要看，不能只看其中一個。
function NBOptions.soundVolume()
    if optionValue(NBOptions.SOUND_ENABLED, true) ~= true then
        return 0
    end
    local volume = tonumber(optionValue(NBOptions.SOUND_VOLUME, DEFAULT_VOLUME))
    if volume == nil then
        volume = DEFAULT_VOLUME
    end
    if volume <= 0 then
        return 0
    end
    if volume > 100 then
        volume = 100
    end
    return volume / 100
end

return NBOptions
