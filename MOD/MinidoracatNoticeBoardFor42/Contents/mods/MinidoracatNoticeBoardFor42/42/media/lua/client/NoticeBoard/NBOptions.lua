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
NBOptions.VOICE_ACTOR = "voice_actor"
-- 公告欄入口（家族工具列那一格，或沒有工具列時的浮動喇叭鈕）要不要顯示；預設顯示。
NBOptions.SHOW_BUTTON = "show_button"
-- 語音聲音（同 AutoDrive 的 MDAD_Voice.lua:64-68）：Stacy／Yui 是 ElevenLabs 的聲音，
-- classic＝改版前的 Fish Audio 語音。combo 存的是 index（ModOptions.lua:272-273、:319-320），
-- 所以這份順序是持久化契約：index 1（Stacy）為預設，新聲音一律接在尾端。
NBOptions.VOICE_ACTORS = { "stacy", "yui", "classic" }

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
    -- addItem 自己會 getText（ModOptions.lua:131-136），這裡傳翻譯鍵。
    local actor = options:addComboBox(NBOptions.VOICE_ACTOR,
        getText("IGUI_MinidoracatNB_OptVoiceActor"),
        getText("IGUI_MinidoracatNB_OptVoiceActorTip"))
    for index = 1, #NBOptions.VOICE_ACTORS do
        actor:addItem("IGUI_MinidoracatNB_VoiceActor_" .. NBOptions.VOICE_ACTORS[index], index == 1)
    end
    options:addTickBox(NBOptions.SHOW_BUTTON,
        getText("IGUI_MinidoracatNB_OptShowButton"), true,
        getText("IGUI_MinidoracatNB_OptShowButtonTip"))
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
local loadSucceeded = false

local function ensureLoaded(retry)
    if loadAttempted and not retry then
        return loadSucceeded
    end
    loadAttempted = true
    if type(PZAPI) ~= "table" or type(PZAPI.ModOptions) ~= "table"
        or type(PZAPI.ModOptions.load) ~= "function" then
        return false
    end
    local ok, loadError = pcall(function()
        PZAPI.ModOptions:load()
    end)
    if not ok then
        print("[MinidoracatNoticeBoardFor42] mod options load failed: " .. tostring(loadError))
    end
    loadSucceeded = ok
    return ok
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

-- Slider display stays independent of the notification mute switch.
function NBOptions.volumePercent()
    local volume = tonumber(optionValue(NBOptions.SOUND_VOLUME, DEFAULT_VOLUME))
    if volume == nil or volume ~= volume then
        volume = DEFAULT_VOLUME
    end
    if volume <= 0 then
        return 0
    end
    if volume > 100 then
        volume = 100
    end
    return volume
end

-- Sets the live option; persist also saves and verifies our own row. The native setter
-- also updates an already-created MODS widget (PZAPI/ModOptions.lua:138-143,216-220).
local function writeOption(id, rowType, value, persist)
    if not ensureLoaded(not loadSucceeded) then
        return false
    end
    local reader
    local ok, saveError = pcall(function()
        NBOptions._options:getOption(id):setValue(value)
        if not persist then
            return
        end
        PZAPI.ModOptions:save()
        -- PrintWriter can swallow I/O errors; verify only our row without
        -- reloading every mod's live options or creating a second settings file.
        reader = getFileReader("ModOptions.ini", false)
        if not reader then error(id .. " readback unavailable") end
        local stored
        local pattern = "^" .. rowType .. "|" .. OPTIONS_ID .. "|" .. id .. "|(.*)$"
        while true do
            local line = reader:readLine()
            if line == nil then break end
            local raw = string.match(line, pattern)
            if raw then stored = tonumber(raw) end
        end
        reader:close()
        reader = nil
        if stored ~= value then error(id .. " readback mismatch") end
    end)
    if reader then pcall(function() reader:close() end) end
    if not ok then
        print("[MinidoracatNoticeBoardFor42] " .. id .. " save failed: " .. tostring(saveError))
    end
    return ok
end

-- Dragging updates the existing option; release saves once.
function NBOptions.setVolumePercent(value, persist)
    if type(value) ~= "number" or value ~= value then
        return false
    end
    value = math.max(0, math.min(100, math.floor(value + 0.5)))
    return writeOption(NBOptions.SOUND_VOLUME, "slider", value, persist)
end

-- 缺值、index 越界或非整數（手改過的 ini）一律退 Stacy。
function NBOptions.voiceActor()
    return NBOptions.VOICE_ACTORS[optionValue(NBOptions.VOICE_ACTOR, 1)] or NBOptions.VOICE_ACTORS[1]
end

-- 選了就存：選單點一下就是確定，沒有拖曳中的暫態。
function NBOptions.setVoiceActor(actor)
    for index = 1, #NBOptions.VOICE_ACTORS do
        if NBOptions.VOICE_ACTORS[index] == actor then
            return writeOption(NBOptions.VOICE_ACTOR, "combobox", index, true)
        end
    end
    return false
end

-- Notification and preview share both mute switches and the same 0..1 gain.
function NBOptions.soundVolume()
    if optionValue(NBOptions.SOUND_ENABLED, true) ~= true then
        return 0
    end
    return NBOptions.volumePercent() / 100
end

-- 入口顯示與否：Dock 每次輪詢都會問（框架允許每幀），而 optionValue 每次都建 closure，
-- 所以快取成布林——第一次讀（順便補 load）與玩家按套用時才重讀。ini 沒值、壞值或讀不到
-- 一律當顯示（只有明確的 false 才藏）。
local showButton = true
local showButtonRead = false

local function readShowButton()
    showButton = optionValue(NBOptions.SHOW_BUTTON, true) ~= false
    showButtonRead = true
end

function NBOptions.showButton()
    if not showButtonRead then
        readShowButton()
    end
    return showButton
end

-- 玩家按「套用」：MainOptions 先把畫面上的值寫回 option（gameOptions:apply，MainOptions.lua:3760），
-- 再逐頁呼叫 options:apply()（:3761-3763；原生是空函式，PZAPI/ModOptions.lua:21-22），最後
-- PZAPI.ModOptions:save()（:3766）。所以這裡**只讀 option 身上的值，不得經 optionValue**：
-- 這次啟動還沒讀過值時，optionValue 的 ensureLoaded 會在 apply 中途呼叫全域 load，把所有 MOD
-- 頁剛套用的值蓋回 ini 舊值，緊接的 save 再寫回去——玩家這次的改動全部消失。
-- 入口在這裡立即跟上；NBFloatButton 呼叫時查表（載入序在本檔之後）。
if registered then
    function registered:apply()
        local option = self:getOption(NBOptions.SHOW_BUTTON)
        showButton = option == nil or option:getValue() ~= false
        showButtonRead = true
        if NBFloatButton and NBFloatButton.onOptionsApplied then
            NBFloatButton.onOptionsApplied()
        end
    end
end

return NBOptions
