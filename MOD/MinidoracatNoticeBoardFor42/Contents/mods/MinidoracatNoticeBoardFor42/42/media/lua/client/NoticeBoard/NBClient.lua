if not NBCore then
    require "NoticeBoard/NBCore"
end
if not NBReader then
    require "NoticeBoard/NBReader"
end

local Core = NBCore
local Reader = NBReader
if not Core or not Reader then
    error("NoticeBoard shared modules failed to load")
end

NBClient = NBClient or {}

NBClient.CONTENT_READY_EVENT = "MinidoracatNB_ContentReady"
NBClient.UNREAD_CHANGED_EVENT = "MinidoracatNB_UnreadChanged"
-- 語系相關的失敗回報。沿用既有事件機制（不新增全域輪詢）：面板 Add 一個 handler 就能出 toast。
-- payload 一律是 table，欄位見 NBClient.getLanguageStatus 上方的說明。
NBClient.LANGUAGE_STATUS_EVENT = "MinidoracatNB_LanguageStatus"
-- 範例包生成的結果回報。與語系狀態同一套機制（面板 Add 一個 handler 就能出 toast），
-- 但**必須是獨立事件**：語系狀態事件的 payload 形狀（save-failed／switch-exhausted 等）
-- 是面板已在解讀的 enum，混進來只會讓兩邊都得先猜這則是誰的。
NBClient.EXAMPLES_STATUS_EVENT = "MinidoracatNB_ExamplesStatus"

local LOG_NAME = "MinidoracatNoticeBoardFor42"
local LOG_PREFIX = "[MinidoracatNoticeBoardFor42]"
-- 收進 NoticeBoard/ 底下（getFileWriter 會自動建目錄），不要散在 Zomboid/Lua/ 根目錄
local READ_STATE_FILE = Reader.NOTICE_ROOT .. getFileSeparator() .. "readstate.ini"
-- 語系偏好是**全域**的玩家設定，不進 readstate.ini（那份是 per-server 的已讀狀態，
-- 而且每次標記已讀都會整檔重寫）。另開一個簡單的 key=value ini。
local SETTINGS_FILE = Reader.NOTICE_ROOT .. getFileSeparator() .. "settings.ini"
-- 語系切換在 server 端有**自己的**短冷卻桶（NBServer LANGUAGE_COOLDOWN_MS=3s，與
-- register/resync 的 10 秒桶分開，理由見該常數）。client 端鏡像同一個桶，切換才能回報
-- 「還要等幾秒」而不是送出去被靜默丟棄。register/resync 那個桶這邊不需要鏡像：
-- registerOnTick／retryRegister 自己的 REGISTER_RETRY_MS 節流就是它的上游。
local LANGUAGE_COOLDOWN_MS = 3000
local REGISTER_RETRY_MS = 5000
local REGISTER_RETRY_LIMIT = 6
local REGISTER_BACKOFF_MS = 60000
local RESYNC_INTERVAL_MS = 10000
local PENDING_TIMEOUT_MS = 10000
local RESYNC_LIMIT = 3
-- 換語系的 register 最多送幾次。送出成功不代表 server 採用（語系冷卻可能擋下），
-- 所以要重送到「manifest 帶回這一次的序號」為止；但也不能無限重送，否則卡住的 client
-- 會永遠每 3 秒灌一包。5 次 x LANGUAGE_COOLDOWN_MS = 15 秒的窗（桶從 10 秒縮到 3 秒後，
-- 沿用舊的 3 次只剩 9 秒，異常時會在 server 的補推機制還沒跑完就先跳「切換未完成」）。
local LANGUAGE_SWITCH_SEND_LIMIT = 5
-- resync 用盡後，同一 v/sid 上仍每 5 分鐘重試一次，避免「manifest 到了但 chunk 永遠湊不齊」時整場凍結。
local RESYNC_RESET_MS = 300000
-- settings.ini 落地失敗後的重試間隔。磁碟滿／檔案被鎖是會恢復的，記憶體裡已經是新值，
-- 只差把它寫回去；不重試就會變成「這場好好的、下次進場莫名回到舊語系」。
local SETTINGS_RETRY_MS = 30000
-- 範例包 ack 的合法 kind 白名單。server 是權威，但 payload 走網路來，形狀仍是信任邊界：
-- 白名單外的值一律丟棄並寫一行 log，**不猜、不當成成功**（面板會據此出 toast，
-- 讓「不認識的 kind」變成靜默成功比顯示錯誤訊息更糟）。
local EXAMPLES_RESULT_KINDS = {
    success = true,
    failed = true,
    cooldown = true,
    forbidden = true,
}
-- 受管檔數是 wire contract（server 端 EXAMPLE_PACK_FILE_COUNT）。一次生成寫的是
-- 共用兩份（categories.txt、README.txt）加選定語系三份，恰好 5 份；只有「5 份全成功」
-- 才能回 success，其他數字代表不完整或版本不相容，不可拿來告訴 admin「範例已生成」。
local EXAMPLES_EXPECTED_COUNT = 5
-- 生成選單的語系白名單，與 server 的 EXAMPLE_PACK_LANGS 同一份契約。
-- **不走 Core.LANGS**：那份有 29 個語系，而範例文字只有這兩份資源存在，
-- 拿它驗會讓面板送得出 server 一定拒收的值（白吃一次來回）。
local EXAMPLE_PACK_LANGS = {
    CH = true,
    EN = true,
}

local function newState()
    return {
        readState = {},
        readStateLoaded = false,
        currentSnapshot = nil,
        currentSidHash = nil,
        currentHashes = {},
        unread = {},
        unreadIds = {},
        registerLanguage = nil,
        languagePreference = nil,
        languageSwitchPending = false,
        languageSwitchArmed = false,
        -- 目前這份快照是不是「我要求的那一次切換的結果」（見 applySnapshot）
        languageSwitchMatched = true,
        -- 「這份快照要不要靜音」與「pending 能不能清掉」是兩件事，不可共用同一個判斷：
        -- 前者只看語系有沒有變（換語系會讓每份公告的 hash 都變），後者要看請求序號。
        languageSwitchSilence = false,
        -- 上一份已套用的快照的語系（nil = 還沒收過，或 server 沒送 lang 欄位）
        lastSnapshotLanguage = nil,
        languageSwitchSends = 0,
        -- 送出額度用盡（切換失敗）。只在剛用盡的那一次寫 log／發事件，之後不再重複。
        languageSwitchExhausted = false,
        -- 語系切換請求的序號。0 = 本場還沒切換過（首次 register 也送 0）。
        -- **完成判定必須用序號而不是語系值**：EN -> JP -> EN 這種來回切換時，
        -- 一份剛好也是 EN 的舊快照會讓語系值比對誤判成「切換完成」，pending 被清掉、
        -- 重送計數歸零，之後 JP 快照到達也不會重新進入 pending -> 面板永久停在錯的語系。
        langSeq = 0,
        -- 側欄收合偏好：nil = 玩家沒按過收合鈕，面板預設展開。
        -- 與 languagePreference 同一次讀檔載入（見 ensureSettingsLoaded）。
        sidebarPreference = nil,
        -- 落地失敗、等著重試的偏好值（nil = 沒有待寫入的）。
        settingsPending = nil,
        -- 側欄偏好寫失敗時，維護輪補寫同一份 settings.ini；不需要另存一份值，
        -- sidebarPreference 本身就是本場生效且最後要落地的權威值。
        sidebarSettingsPending = false,
        -- settings.ini 首次讀取失敗時保持 true；維護輪成功重讀前不得用 fallback 值截斷覆寫整檔。
        settingsLoadPending = false,
        lastSettingsRetryMs = 0,
        registerRetryCount = 0,
        lastRegisterAttemptMs = 0,
        -- 語系切換的冷卻鏡像（對應 server 的 langCooldownAt）。與 lastRegisterAttemptMs
        -- 分開：resync／register 重送不得吃掉玩家換語系的額度。
        lastLanguageAttemptMs = 0,
        registerBackoffLogged = false,
        firstManifestReceived = false,
        observedManifest = nil,
        manifestReceivedAtMs = 0,
        resyncVersion = nil,
        resyncSid = nil,
        resyncCount = 0,
        resyncExhaustedLogged = false,
        lastResyncAttemptMs = 0,
        lastCommandErrorLogMs = 0,
        -- 範例包 ack 被丟棄的 log 節流（見 logExamplesDrop）。
        lastExamplesDropLogMs = 0,
    }
end

NBClient.state = NBClient.state or newState()

local function logLine(message)
    local line = LOG_PREFIX .. " " .. tostring(message)
    print(line)
    pcall(function()
        writeLog(LOG_NAME, line)
    end)
end

local function safeLogValue(value, maxUnits)
    return Core.sanitizeName(value, maxUnits)
end

-- settings.ini 是玩家可手動編輯的檔案，內容長度不受限；進 log 前必須截長
-- （writeLog 到 10MB 是整檔截斷非輪替，會沖掉排查紀錄）。
local LOG_VALUE_LIMIT = 64

local function closeReader(reader)
    if reader then
        pcall(function()
            reader:close()
        end)
    end
end

local function closeWriter(writer)
    if writer then
        pcall(function()
            writer:close()
        end)
    end
end

local function loadReadState()
    local reader = nil
    local parsed = {}
    local ok, readError = pcall(function()
        reader = getFileReader(READ_STATE_FILE, false)
        if not reader then
            return
        end

        while true do
            local line = reader:readLine()
            if line == nil then
                break
            end

            local sidHash, fileId, hash = string.match(
                line,
                "^(%x%x%x%x%x%x%x%x)|(.+)=(%x%x%x%x%x%x%x%x)$"
            )
            if sidHash and fileId and fileId ~= "" and hash then
                sidHash = string.lower(sidHash)
                hash = string.lower(hash)
                local files = rawget(parsed, sidHash)
                if not files then
                    files = {}
                    parsed[sidHash] = files
                end
                files[fileId] = hash
            end
        end

        reader:close()
        reader = nil
    end)

    closeReader(reader)
    if not ok then
        NBClient.state.readStateLoaded = false
        return false, tostring(readError)
    end

    NBClient.state.readState = parsed
    NBClient.state.readStateLoaded = true
    return true, nil
end

local function writeReadState()
    local state = NBClient.state
    if not state.readStateLoaded then
        return false, "read state was not loaded"
    end

    local writer = nil
    local ok, writeError = pcall(function()
        writer = getFileWriter(READ_STATE_FILE, true, false)
        if not writer then
            error("getFileWriter returned nil")
        end

        local sidHashes = {}
        local sidHash, files
        for sidHash, files in pairs(state.readState) do
            if type(sidHash) == "string" and type(files) == "table" then
                sidHashes[#sidHashes + 1] = sidHash
            end
        end
        Core.sortSafe(sidHashes)

        local sidIndex
        for sidIndex = 1, #sidHashes do
            sidHash = sidHashes[sidIndex]
            files = rawget(state.readState, sidHash)
            local fileIds = {}
            local fileId, hash
            for fileId, hash in pairs(files) do
                if type(fileId) == "string" and fileId ~= "" and type(hash) == "string" then
                    fileIds[#fileIds + 1] = fileId
                end
            end
            Core.sortSafe(fileIds)

            local fileIndex
            for fileIndex = 1, #fileIds do
                fileId = fileIds[fileIndex]
                hash = rawget(files, fileId)
                writer:write(sidHash .. "|" .. fileId .. "=" .. hash .. "\n")
            end
        end

        writer:close()
        writer = nil
    end)

    closeWriter(writer)
    if not ok then
        return false, tostring(writeError)
    end
    return true, nil
end

-- settings.ini：一行一個 key=value，目前是 lang（語系偏好）與 sidebar（側欄收合偏好）。
-- 讀寫比照 ReadState（整段 pcall 包覆、失敗只寫 log 不拋出），玩家手改壞了不得讓面板進不去。
-- 讀是**整檔一次**、寫是**整檔重寫**：一個 key 各配一支讀寫函式的話，寫 lang 會把 sidebar
-- 那行洗掉——getFileWriter(path, true, false) 的第三個參數是 append，false 等於截斷重寫。
local function loadSettings()
    local reader = nil
    local values = {}
    local ok, readError = pcall(function()
        reader = getFileReader(SETTINGS_FILE, false)
        if not reader then
            return
        end

        while true do
            local line = reader:readLine()
            if line == nil then
                break
            end
            local key, raw = string.match(line, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if key ~= nil then
                values[key] = raw
            end
        end

        reader:close()
        reader = nil
    end)

    closeReader(reader)
    if not ok then
        return nil, tostring(readError)
    end
    return values, nil
end

-- 側欄收合偏好只有三態：true／false／沒設過。玩家手改成別的字樣一律當沒設過，
-- 讓面板回到「預設展開」，而不是被一個壞值鎖死在某一邊。
local function normalizeSidebarPreference(raw)
    if raw == "true" then
        return true
    end
    if raw == "false" then
        return false
    end
    return nil
end

-- 整檔重寫。preference 是語系代碼或 AUTO_LANGUAGE；sidebar 是 nil／true／false。
local function writeSettings(preference, sidebar)
    local writer = nil
    local ok, writeError = pcall(function()
        writer = getFileWriter(SETTINGS_FILE, true, false)
        if not writer then
            error("getFileWriter returned nil")
        end
        writer:write("lang=" .. preference .. "\n")
        -- 沒設過就不寫這一行：「檔案裡有 sidebar=」本身就是「玩家按過收合鈕」的證據。
        if sidebar ~= nil then
            writer:write("sidebar=" .. tostring(sidebar) .. "\n")
        end
        writer:close()
        writer = nil
    end)

    closeWriter(writer)
    if not ok then
        return false, tostring(writeError)
    end

    -- pcall 成功**不代表真的落地**：引擎的 LuaFileWriter 只是 PrintWriter 的轉呼叫殼
    -- （LuaManager.java:12751-12769，write/close 直接委派給 PrintWriter），而 PrintWriter
    -- 把建構後的 IOException 記在內部 trouble 旗標裡、從不往外拋，wrapper 也沒有暴露
    -- checkError()。也就是說磁碟滿或檔案被鎖時我們會拿到一個「成功」的 pcall。
    -- 引擎既然沒給可檢查的介面，唯一能確認的方式就是讀回來比對——這個檔只有兩行，成本可接受。
    local values, readError = loadSettings()
    if readError then
        return false, "verify read failed: " .. tostring(readError)
    end
    local storedLanguage = rawget(values, "lang")
    if storedLanguage ~= preference then
        return false, "verify mismatch: stored=" .. tostring(storedLanguage)
    end
    local storedSidebarRaw = rawget(values, "sidebar")
    if normalizeSidebarPreference(storedSidebarRaw) ~= sidebar then
        return false, "verify mismatch: sidebar=" .. tostring(storedSidebarRaw)
    end
    return true, nil
end

-- 首次呼叫讀檔；讀取失敗時不把 fallback auto 當成「已載入」，而是交給維護輪重試。
-- force 只由維護輪使用，避免每個 getter／tick 都重新打一次失敗 IO。
local function ensureSettingsLoaded(force)
    local state = NBClient.state
    if state.languagePreference ~= nil and not state.settingsLoadPending then
        return true
    end
    if state.settingsLoadPending and not force then
        return false
    end

    local values, readError = loadSettings()
    if not values then
        if not state.settingsLoadPending then
            logLine("settings load failed: " .. safeLogValue(readError, 160))
        end
        state.settingsLoadPending = true
        return false
    end

    local raw = rawget(values, "lang")
    local preference = Core.normalizeLanguagePreference(raw)
    if raw ~= nil and raw ~= Core.AUTO_LANGUAGE and preference == Core.AUTO_LANGUAGE then
        logLine("settings lang not recognized value=" .. safeLogValue(raw, LOG_VALUE_LIMIT)
            .. "; using auto")
    end
    state.settingsLoadPending = false
    -- 讀檔失敗期間玩家可能已改偏好：pending 的記憶體值優先；未改的欄位才從磁碟補回。
    if state.settingsPending == nil then
        state.languagePreference = preference
    end
    if not state.sidebarSettingsPending then
        state.sidebarPreference = normalizeSidebarPreference(rawget(values, "sidebar"))
    end
    return true
end

local function ensureReadStateLoaded()
    if NBClient.state.readStateLoaded then
        return true
    end

    local loaded, readError = loadReadState()
    if not loaded then
        logLine("read state load failed: " .. safeLogValue(readError))
    end
    return loaded
end

local function unreadSetsEqual(left, right)
    local fileId
    for fileId in pairs(left) do
        if rawget(right, fileId) ~= true then
            return false
        end
    end
    for fileId in pairs(right) do
        if rawget(left, fileId) ~= true then
            return false
        end
    end
    return true
end

local function orderedUnreadIds(snapshot, unread)
    local result = {}
    local files = rawget(snapshot, "files") or {}
    local index
    for index = 1, #files do
        local fileId = rawget(files[index], "id")
        if type(fileId) == "string" and rawget(unread, fileId) == true then
            result[#result + 1] = fileId
        end
    end
    return result
end

local function copyArray(values)
    local result = {}
    local index
    for index = 1, #values do
        result[index] = values[index]
    end
    return result
end

local function triggerClientEvent(eventName, argument)
    local ok, eventError = pcall(function()
        triggerEvent(eventName, argument)
    end)
    if not ok then
        logLine("event failed name=" .. eventName .. " error=" .. safeLogValue(eventError))
    end
end

-- 落地一次，並把結果變成「面板看得到的狀態」。舊版失敗只寫一行 log 就算了，回傳值
-- 只描述網路送出：玩家改了語系、這場生效、下次進場莫名回到舊值，全程沒有任何提示。
local function persistLanguagePreference(preference)
    local state = NBClient.state
    local written = false
    local writeError = "settings not loaded"
    if not state.settingsLoadPending then
        -- 側欄偏好一起帶進去：整檔重寫，漏帶就等於把玩家的收合狀態洗掉。
        written, writeError = writeSettings(preference, state.sidebarPreference)
    end
    if written then
        state.sidebarSettingsPending = false
        if state.settingsPending ~= nil then
            state.settingsPending = nil
            triggerClientEvent(NBClient.LANGUAGE_STATUS_EVENT, {
                kind = "save-recovered",
                preference = preference,
            })
        end
        return true
    end

    -- 記下待寫入值，之後（維護輪／玩家再次選取）重試。記憶體裡的偏好照常生效。
    -- log 與事件只在「待寫入值有變化」時發：重試輪每 30 秒跑一次，無條件發等於
    -- 每 30 秒灌一行 log（writeLog 到 10MB 是整檔截斷）並在面板端每 30 秒彈一則 toast。
    local previousPending = state.settingsPending
    state.settingsPending = preference
    if previousPending == preference then
        return false
    end
    local detail = safeLogValue(writeError, 160)
    logLine("settings write failed pref=" .. safeLogValue(preference, LOG_VALUE_LIMIT)
        .. " error=" .. detail)
    triggerClientEvent(NBClient.LANGUAGE_STATUS_EVENT, {
        kind = "save-failed",
        preference = preference,
        detail = detail,
    })
    return false
end

local clientLanguage
local sendLanguageRegister

local function armLanguageSwitch(language)
    local state = NBClient.state
    state.registerLanguage = language
    state.languageSwitchPending = true
    state.languageSwitchArmed = true
    state.languageSwitchSends = 0
    state.languageSwitchExhausted = false
    if state.langSeq >= Core.MAX_LANGUAGE_SEQ then
        state.langSeq = 1
    else
        state.langSeq = state.langSeq + 1
    end
end

local function pumpSettingsRetry(now)
    local state = NBClient.state
    if state.settingsPending == nil and not state.sidebarSettingsPending
        and not state.settingsLoadPending then
        return
    end
    if state.lastSettingsRetryMs ~= 0
        and now - state.lastSettingsRetryMs < SETTINGS_RETRY_MS then
        return
    end
    state.lastSettingsRetryMs = now
    if state.settingsLoadPending then
        if not ensureSettingsLoaded(true) then
            return
        end
        -- 首次失敗時可能已用 fallback 語系完成 register；讀回真正偏好後要立即補切換。
        local recoveredLanguage = clientLanguage()
        if state.registerLanguage ~= nil and recoveredLanguage ~= state.registerLanguage then
            armLanguageSwitch(recoveredLanguage)
            sendLanguageRegister(now)
        end
    end
    if not state.sidebarSettingsPending and state.settingsPending == nil then
        return
    end
    if state.settingsPending ~= nil then
        persistLanguagePreference(state.settingsPending)
        return
    end
    local written = writeSettings(state.languagePreference, state.sidebarPreference)
    if written then
        state.sidebarSettingsPending = false
        logLine("settings sidebar write recovered")
        triggerClientEvent(NBClient.LANGUAGE_STATUS_EVENT, {
            kind = "sidebar-save-recovered",
        })
    end
end

local function cleanupReadState(sidHash, manifestIds)
    local state = NBClient.state
    local files = rawget(state.readState, sidHash)
    if type(files) ~= "table" then
        return false
    end

    local stale = {}
    local fileId
    for fileId in pairs(files) do
        if rawget(manifestIds, fileId) ~= true then
            stale[#stale + 1] = fileId
        end
    end
    if #stale == 0 then
        return false
    end

    local index
    for index = 1, #stale do
        files[stale[index]] = nil
    end
    return true
end

local function applySnapshot(snapshot)
    if type(snapshot) ~= "table" then
        error("snapshot is not a table")
    end

    local sid = rawget(snapshot, "sid")
    local files = rawget(snapshot, "files")
    if type(sid) ~= "string" or sid == "" or type(files) ~= "table" then
        error("invalid snapshot")
    end

    local state = NBClient.state
    local readStateAvailable = ensureReadStateLoaded()
    local sidHash = Core.djb2Hex(sid)
    local manifestIds = {}
    local currentHashes = {}
    local unread = {}
    local readFiles = nil
    if readStateAvailable then
        readFiles = rawget(state.readState, sidHash)
    end

    local index
    for index = 1, #files do
        local entry = files[index]
        local fileId = rawget(entry, "id")
        local hash = rawget(entry, "h")
        if type(fileId) ~= "string" or fileId == "" or type(hash) ~= "string" then
            error("invalid snapshot file at index " .. tostring(index))
        end

        manifestIds[fileId] = true
        currentHashes[fileId] = hash
        if not readFiles or rawget(readFiles, fileId) ~= hash then
            unread[fileId] = true
        end
    end

    if readStateAvailable and cleanupReadState(sidHash, manifestIds) then
        local written, writeError = writeReadState()
        if not written then
            logLine("read state cleanup write failed: " .. safeLogValue(writeError))
        end
    end

    local unreadChanged = not unreadSetsEqual(state.unread, unread)
    state.currentSnapshot = snapshot
    state.currentSidHash = sidHash
    state.currentHashes = currentHashes
    state.unread = unread
    state.unreadIds = orderedUnreadIds(snapshot, unread)

    -- 換語系的完成判定認的是**請求序號**，不是語系值。
    -- 語系值比對在 EN -> JP -> EN 這種來回切換下會壞掉：選 JP 送出後、10 秒內選回 EN
    -- 被鏡像冷卻擋下（只寫了 registerLanguage="EN"），此時一份舊的 EN 快照抵達，
    -- snapshotLanguage == registerLanguage 成立 -> 誤判完成 -> pending 清掉、送出計數歸零，
    -- 隨後 JP 快照到達雖然 mismatch 卻不會重新設回 pending，pumpLanguageSwitch 也不再重試，
    -- 面板永久停在 JP；玩家再選 EN 又被 setLanguagePreference 的 unchanged 早退吞掉。
    -- 序號是單調遞增的，舊快照帶的一定是舊序號，不可能誤判。
    -- 舊版 server 沒有 lseq 欄位（nil）-> 沿用既有的語系值比對，互通不受影響。
    local snapshotSeq = rawget(snapshot, "lseq")
    local snapshotLanguage = rawget(snapshot, "lang")
    -- 語系相符：舊版 server 不送 lang、或 client 還沒 register 過時一律視為相符。
    local languageMatches = snapshotLanguage == nil
        or state.registerLanguage == nil
        or snapshotLanguage == state.registerLanguage
    if snapshotSeq ~= nil then
        -- 序號**與**語系都要相符才算完成。只比序號會被「帶著這一次的序號、內容卻是舊語系」
        -- 的快照騙過：resync 在 server 端已有註冊時會忽略 args.lang（NBServer handleResync），
        -- 但仍把 client 送來的新序號寫進 state.langSeq，推回來的就是這種快照。判成完成會清掉
        -- pending，pumpLanguageSwitch 不再重送，玩家就永久停在舊語系。
        state.languageSwitchMatched = snapshotSeq == state.langSeq and languageMatches
    else
        state.languageSwitchMatched = languageMatches
    end
    if state.languageSwitchMatched then
        state.languageSwitchPending = false
        state.languageSwitchSends = 0
        state.languageSwitchExhausted = false
    elseif snapshotSeq ~= nil and not languageMatches then
        -- 序號不符**而且**畫面上的語系不是玩家要求的那一個 -> 這次切換確實還沒生效，重新掛上
        -- pending。序號不符但語系相符（同語系的舊快照）不算分岔：畫面語系已經是對的。
        -- 這條同時是亂序的防呆：server->client 的 Lua 命令封包走 RELIABLE 而非
        -- RELIABLE_ORDERED（PacketTypes.java:498 的 ClientCommand(1, 2, ...) ->
        -- UdpConnection.java:303-318 -> RakNetPeerInterface.java:43-44 的 RELIABLE = 2），
        -- 不保證順序。萬一亂序讓 pending 已經清掉又收到不符的快照，沒有這行就再也沒有任何
        -- 自癒路徑——pumpLanguageSwitch 看 pending、選單重選同一語系又會被 unchanged 早退吞掉。
        state.languageSwitchPending = true
    end

    -- 靜音判定與上面的完成判定**刻意分開**。連續換語系（選 EN、2 秒內再選 JP）時，
    -- 先抵達的 EN 快照序號不符、不算切換完成，但它一樣把每份公告的內容整個換掉、
    -- hash 全變，照「一般內容更新」走就是每份公告噴一則 toast。
    -- 因此只要「這份快照的語系與上一份不同」就靜音，不管它是不是玩家最後要求的那一個。
    local currentLanguage = rawget(snapshot, "lang")
    local languageChanged = type(currentLanguage) == "string"
        and state.lastSnapshotLanguage ~= nil
        and currentLanguage ~= state.lastSnapshotLanguage
    if type(currentLanguage) == "string" then
        state.lastSnapshotLanguage = currentLanguage
    end
    -- 舊版 server 不送 lang，無從比對語系變化：沿用既有的 armed + matched 判斷。
    state.languageSwitchSilence = languageChanged
        or (state.languageSwitchArmed and state.languageSwitchMatched)

    triggerClientEvent(NBClient.CONTENT_READY_EVENT, snapshot)
    if unreadChanged then
        triggerClientEvent(NBClient.UNREAD_CHANGED_EVENT, copyArray(state.unreadIds))
    end
end

local function applySnapshotSafely(snapshot)
    local ok, applyError = pcall(applySnapshot, snapshot)
    if not ok then
        logLine("snapshot apply failed: " .. safeLogValue(applyError))
    end
end

-- 玩家在面板選的語系優先；auto（預設）才跟隨遊戲語系。
clientLanguage = function()
    local preference = NBClient.getLanguagePreference()
    if preference ~= Core.AUTO_LANGUAGE then
        return preference
    end

    local ok, language = pcall(function()
        return Translator.getLanguage():name()
    end)
    if ok and type(language) == "string" and rawget(Core.LANGS, language) == true then
        return language
    end
    return "EN"
end

local function maybeLogCommandError(command, commandError, now)
    local state = NBClient.state
    if state.lastCommandErrorLogMs ~= 0
        and now - state.lastCommandErrorLogMs < RESYNC_INTERVAL_MS then
        return
    end
    state.lastCommandErrorLogMs = now
    logLine("client command failed cmd=" .. command .. " error=" .. safeLogValue(commandError))
end

local function sendCommand(command, args, now)
    if not isClient() then
        return false
    end

    local ok, commandError = pcall(function()
        sendClientCommand(Reader.MODULE, command, args)
    end)
    if not ok then
        maybeLogCommandError(command, commandError, now)
        return false
    end
    return true
end

-- 送出目前的語系。回傳 "sent" / "cooldown" / "failed" 與冷卻剩餘秒數。
-- MP 下「送出成功」不等於「server 採用」：server 的 register 冷卻擋下時內容不會被推，
-- 所以 pending 一路留到 applySnapshot 收到該語系的快照才清，中途由 pumpLanguageSwitch 補送。
sendLanguageRegister = function(now)
    local state = NBClient.state
    if not isClient() then
        -- SP：沒有網路層，走既有的本地命令管道通知同 VM 的 NBServer（與 imgreq 同一條路）。
        -- pending 不在這裡清：SP 的完成判定與 MP 共用 applySnapshot 的序號比對，
        -- 提早清掉會讓「排進去了但快照沒回來」變成無法自癒（SP 沒有 pumpLanguageSwitch）。
        local ok, commandError = pcall(function()
            triggerEvent(Reader.LOCAL_CMD_EVENT, Reader.MODULE, "setlang",
                { lang = state.registerLanguage, lseq = state.langSeq })
        end)
        if not ok then
            maybeLogCommandError("setlang", commandError, now)
            return "failed", 0
        end
        return "sent", 0
    end

    local waited = now - state.lastLanguageAttemptMs
    if state.lastLanguageAttemptMs ~= 0 and waited < LANGUAGE_COOLDOWN_MS then
        return "cooldown", math.ceil((LANGUAGE_COOLDOWN_MS - waited) / 1000)
    end

    -- 送失敗也記時戳：否則 pending 會每個 tick 重試一次，變成逐 tick 灌送。
    state.lastLanguageAttemptMs = now
    if not sendCommand("register",
        { lang = state.registerLanguage, lseq = state.langSeq }, now) then
        return "failed", 0
    end
    state.languageSwitchSends = state.languageSwitchSends + 1
    return "sent", 0
end

local function pumpLanguageSwitch(receiver, now)
    local state = NBClient.state
    if not state.languageSwitchPending then
        return
    end
    -- manifest 已經帶回這一次的序號**且語系相符** = server 已受理、正在推分塊，這裡必須停手：
    -- server 的 enqueueJob 是覆寫語意，再送一次 register 會讓推送從 manifest／fileIndex=1
    -- 重頭開始，一份大內容在多人佇列（4 人／32 則／單人 8 則 per tick）下就永遠推不完。
    -- 「manifest 到了但分塊湊不齊」本來就有專屬路徑：requestResync 的 pending-timeout。
    -- 語系也要比：只比序號會被 resync 回帶新序號的舊語系 manifest 騙過（見 applySnapshot）。
    if rawget(receiver, "lseq") == state.langSeq
        and rawget(receiver, "language") == state.registerLanguage then
        return
    end
    -- 上限用盡後就停手，但 pending 維持 true：玩家在選單再點一次同一個語系仍然送得出去
    -- （setLanguagePreference 的 unchanged 早退需要 pending 為 false），不會變成無聲的死路。
    -- 本檔其餘的重試迴圈（retryRegister／requestResync）退出時都會寫 log，這條先前沒有：
    -- 切換就這樣停住，玩家與服主兩邊都拿不到任何訊號。剛用盡的那一次補一則 log 與事件。
    if state.languageSwitchSends >= LANGUAGE_SWITCH_SEND_LIMIT then
        if not state.languageSwitchExhausted then
            state.languageSwitchExhausted = true
            logLine("language switch send limit reached lang="
                .. safeLogValue(state.registerLanguage, LOG_VALUE_LIMIT)
                .. " seq=" .. tostring(state.langSeq)
                .. "; select the language again to retry")
            triggerClientEvent(NBClient.LANGUAGE_STATUS_EVENT, {
                kind = "switch-exhausted",
                language = state.registerLanguage,
            })
        end
        return
    end
    sendLanguageRegister(now)
end

local function hasPending(receiver)
    local pending = rawget(receiver, "pending")
    if type(pending) ~= "table" then
        return false
    end
    local _
    for _ in pairs(pending) do
        return true
    end
    return false
end

local function observeReceiver(receiver, now)
    local state = NBClient.state
    local manifest = rawget(receiver, "manifest")
    if manifest ~= state.observedManifest then
        state.observedManifest = manifest
        if manifest ~= nil then
            state.firstManifestReceived = true
            state.manifestReceivedAtMs = now
        end
    end

    local version = rawget(receiver, "v")
    local sid = rawget(receiver, "sid")
    if version ~= state.resyncVersion or sid ~= state.resyncSid then
        state.resyncVersion = version
        state.resyncSid = sid
        state.resyncCount = 0
        state.resyncExhaustedLogged = false
        state.lastResyncAttemptMs = 0
    elseif state.resyncCount >= RESYNC_LIMIT
        and state.lastResyncAttemptMs ~= 0
        and now - state.lastResyncAttemptMs >= RESYNC_RESET_MS then
        -- 同一 v/sid 仍卡著：長退避後解鎖再試一輪，防永久凍結。
        state.resyncCount = 0
        state.resyncExhaustedLogged = false
    end
end

local function retryRegister(now)
    local state = NBClient.state
    if state.firstManifestReceived then
        return
    end

    local interval = REGISTER_RETRY_MS
    if state.registerRetryCount >= REGISTER_RETRY_LIMIT then
        interval = REGISTER_BACKOFF_MS
    end
    if now - state.lastRegisterAttemptMs < interval then
        return
    end

    state.lastRegisterAttemptMs = now
    if not sendCommand("register",
        { lang = state.registerLanguage, lseq = state.langSeq }, now) then
        return
    end

    if state.registerRetryCount < REGISTER_RETRY_LIMIT then
        state.registerRetryCount = state.registerRetryCount + 1
        if state.registerRetryCount == REGISTER_RETRY_LIMIT
            and not state.registerBackoffLogged then
            state.registerBackoffLogged = true
            logLine("register retries exhausted; continuing every 60 seconds")
        end
    end
end

local function requestResync(receiver, now)
    local state = NBClient.state
    if state.resyncCount >= RESYNC_LIMIT then
        if not state.resyncExhaustedLogged then
            state.resyncExhaustedLogged = true
            logLine("resync exhausted v=" .. tostring(rawget(receiver, "v"))
                .. "; retrying after backoff")
        end
        return
    end
    if state.lastResyncAttemptMs ~= 0
        and now - state.lastResyncAttemptMs < RESYNC_INTERVAL_MS then
        return
    end

    local reason = nil
    if rawget(receiver, "needsResync") == true then
        reason = "receiver-error"
    elseif rawget(receiver, "manifest") ~= nil
        and hasPending(receiver)
        and now - state.manifestReceivedAtMs >= PENDING_TIMEOUT_MS then
        reason = "pending-timeout"
    end
    if not reason then
        return
    end

    state.lastResyncAttemptMs = now
    -- register 與 resync 在 server 端共用同一個冷卻桶（NBServer usePushCooldown）；client 端的
    -- 鏡像也必須一起推進，否則 retryRegister 會以為還有額度、送出去卻被靜默丟棄。
    -- 語系切換不在這裡：它走 server 的獨立語系桶，鏡像是 lastLanguageAttemptMs。
    state.lastRegisterAttemptMs = now
    -- 帶著 lang：若 server 端註冊已遺失，resync 可當作重新註冊處理（見 NBServer.handleResync）。
    -- 也帶著 lseq：重送回來的快照必須帶著 client 目前等待的序號，否則會被判為不相符而白等。
    if not sendCommand("resync",
        { lang = state.registerLanguage, lseq = state.langSeq }, now) then
        return
    end

    state.resyncCount = state.resyncCount + 1
    logLine("resync requested v=" .. tostring(rawget(receiver, "v"))
        .. " attempt=" .. tostring(state.resyncCount)
        .. " reason=" .. reason)
end

local function maintenanceOnTick()
    local now = getTimestampMs()
    -- settings.ini 的重試不需要網路，SP 也要跑：SP 沒有 server 幫忙記語系，settings.ini
    -- 就是唯一的記憶體。寫檔失敗（磁碟滿／防毒鎖檔）後若完全不重試，玩家只會吃到一則
    -- save-failed toast，下次進場靜默回到舊語系。其餘的泵都要網路，維持只在 MP 跑。
    pumpSettingsRetry(now)
    if not isClient() then
        return
    end

    local receiver = Reader.getReceiverState()
    if type(receiver) ~= "table" then
        return
    end

    observeReceiver(receiver, now)
    pumpLanguageSwitch(receiver, now)
    retryRegister(now)
    requestResync(receiver, now)
end

local function installMaintenance()
    if NBClient._maintenanceInstalled then
        return
    end
    Events.OnTick.Add(maintenanceOnTick)
    NBClient._maintenanceInstalled = true
end

function NBClient.markRead(fileId)
    if type(fileId) ~= "string" or fileId == "" then
        return false
    end

    local state = NBClient.state
    local currentHash = rawget(state.currentHashes, fileId)
    if type(currentHash) ~= "string" or not state.currentSidHash then
        return false
    end
    if not ensureReadStateLoaded() then
        return false
    end

    local files = rawget(state.readState, state.currentSidHash)
    if not files then
        files = {}
        state.readState[state.currentSidHash] = files
    end

    local previousHash = rawget(files, fileId)
    if previousHash ~= currentHash then
        files[fileId] = currentHash
        local written, writeError = writeReadState()
        if not written then
            if previousHash == nil then
                files[fileId] = nil
            else
                files[fileId] = previousHash
            end
            logLine("read state write failed: " .. safeLogValue(writeError))
            return false
        end
    end

    if rawget(state.unread, fileId) == true then
        state.unread[fileId] = nil
        state.unreadIds = orderedUnreadIds(state.currentSnapshot, state.unread)
        triggerClientEvent(NBClient.UNREAD_CHANGED_EVENT, copyArray(state.unreadIds))
    end
    return true
end

function NBClient.getLanguagePreference()
    ensureSettingsLoaded()
    return NBClient.state.languagePreference or Core.AUTO_LANGUAGE
end

-- 側欄收合偏好。nil = 玩家沒按過收合鈕（面板預設展開），true/false = 玩家設過。
function NBClient.getSidebarCollapsedPreference()
    ensureSettingsLoaded()
    return NBClient.state.sidebarPreference
end

-- 回傳是否確實寫進 settings.ini。失敗時本場仍套用記憶體值，並排入共用 settings 維護輪；
-- LANGUAGE_STATUS_EVENT 讓面板如實提示「尚未保存」與之後的恢復。
function NBClient.setSidebarCollapsedPreference(collapsed)
    if type(collapsed) ~= "boolean" then
        return false
    end
    local settingsReady = ensureSettingsLoaded()
    local state = NBClient.state
    local wasPending = state.sidebarSettingsPending
    state.sidebarPreference = collapsed
    local written = false
    local writeError = "settings not loaded"
    if settingsReady then
        written, writeError = writeSettings(state.languagePreference, collapsed)
    end
    if written then
        state.sidebarSettingsPending = false
        return true
    end
    state.sidebarSettingsPending = true
    if not wasPending then
        local detail = safeLogValue(writeError, 160)
        logLine("settings sidebar write failed error=" .. detail)
        triggerClientEvent(NBClient.LANGUAGE_STATUS_EVENT, {
            kind = "sidebar-save-failed",
            detail = detail,
        })
    end
    return false
end

-- 面板語系選單的入口。value 是 NBCore.AUTO_LANGUAGE 或 LANGS 白名單內的代碼，
-- 其餘一律當 auto。
-- 回傳三個值：
--   status      "unchanged" / "sent" / "cooldown" / "failed"（描述**網路送出**）
--   waitSeconds cooldown 時的剩餘秒數，其餘為 0
--   saved       偏好是否已確實寫進 settings.ini（false = 這場生效、下次進場會回到舊值；
--               已記為待重試，並已發出 LANGUAGE_STATUS_EVENT 的 save-failed）
function NBClient.setLanguagePreference(value)
    local state = NBClient.state
    local preference = Core.normalizeLanguagePreference(value)
    local settingsReady = ensureSettingsLoaded()
    local currentPreference = state.languagePreference or Core.AUTO_LANGUAGE
    local saved = true
    if preference ~= currentPreference or not settingsReady then
        -- 寫不進去不影響本場：記憶體裡的偏好照常生效，維護輪負責補寫。
        state.languagePreference = preference
        saved = persistLanguagePreference(preference)
    elseif state.settingsPending ~= nil then
        -- 值沒變但上次沒寫成功：玩家再點一次同一個語系＝手動重試落地。
        saved = persistLanguagePreference(preference)
    end

    local language = clientLanguage()
    if language == state.registerLanguage and not state.languageSwitchPending then
        return "unchanged", 0, saved
    end
    armLanguageSwitch(language)
    local status, waitSeconds = sendLanguageRegister(getTimestampMs())
    return status, waitSeconds, saved
end

-- 面板用的狀態快照（唯讀）。toast 由面板負責，這裡只把狀態如實暴露出來。
--   preference      目前的偏好值（AUTO_LANGUAGE 或語系代碼）
--   requested       最後一次送出的語系代碼（nil = 還沒 register 過）
--   switchPending   切換已發出但尚未收到相符的快照
--   switchExhausted 送出額度已用盡（切換失敗，再選一次同語系即可重試）
--   saveFailed      settings.ini 尚未寫入成功（重試中）
--   seq             目前的切換請求序號（除錯用）
function NBClient.getLanguageStatus()
    local state = NBClient.state
    return {
        preference = NBClient.getLanguagePreference(),
        requested = state.registerLanguage,
        switchPending = state.languageSwitchPending == true,
        switchExhausted = state.languageSwitchExhausted == true,
        saveFailed = state.settingsPending ~= nil,
        seq = state.langSeq,
    }
end

-- 換語系會讓每一份公告的 hash 都變（內容真的換了一種語言），若照常走「內容有更新」的
-- 提示，玩家會一次吃到 N 則 toast。面板據此把換語系後的第一份快照靜音，只重建文件樹。
function NBClient.consumeLanguageSwitch()
    local state = NBClient.state
    if not state.languageSwitchSilence then
        return false
    end
    state.languageSwitchSilence = false
    state.languageSwitchArmed = false
    return true
end

function NBClient.isUnread(fileId)
    return type(fileId) == "string" and rawget(NBClient.state.unread, fileId) == true
end

function NBClient.getUnreadIds()
    return copyArray(NBClient.state.unreadIds)
end

function NBClient.getSnapshot()
    return Reader.getSnapshot()
end

-- admin 面板的「重建範例」按鈕。language 是選單選出來的語系代碼（"CH" 或 "EN"）：
-- 它決定 server 要覆寫哪個語系目錄底下的三份公告，所以**必須是精確的白名單值**。
-- 這裡驗一次不是為了防惡意（server 端才是權威），而是為了不讓面板的 bug 變成
-- 「送出去了、admin 看到已送出、結果 server 靜默回 failed」那種難查的兩段式失敗。
-- 回傳值只描述**送出**（true = 指令已交給網路層）：真正的結果由 server 的
-- examplesResult 帶回，經 EXAMPLES_STATUS_EVENT 交給面板。
-- SP 一律回 false：範例包只在權威端有意義，而 SP 的權威端就是玩家本人，沒有 player
-- 物件也就沒有 ack 收件人；NBPanel:createChildren 同樣以 isClient() 隱藏這顆按鈕。
function NBClient.requestExamplePack(language)
    if not isClient() then
        return false
    end
    if type(language) ~= "string" or rawget(EXAMPLE_PACK_LANGS, language) ~= true then
        return false
    end
    return sendCommand("examples", { lang = language }, getTimestampMs())
end

-- 丟棄的 ack 也要留 log（否則 admin 回報「按了沒反應」時完全無跡可循），但**必須節流**：
-- ack 是 server 主動送的，惡意 server 可以無限灌，而 writeLog 到 10MB 是整檔截斷、
-- 會沖掉真正要排查的紀錄。沿用 maybeLogCommandError 的 10 秒窗，理由與它相同。
local function logExamplesDrop(reason)
    local state = NBClient.state
    local now = getTimestampMs()
    if state.lastExamplesDropLogMs ~= 0
        and now - state.lastExamplesDropLogMs < RESYNC_INTERVAL_MS then
        return
    end
    state.lastExamplesDropLogMs = now
    logLine("examples result dropped " .. reason)
end

-- server 的範例包 ack。形狀壞掉一律丟棄：這條路徑的下游只有 toast，
-- 把不認識的 payload 當成成功等於騙 admin「範例已生成」。
local function receiveExamplesResult(args)
    if type(args) ~= "table" then
        logExamplesDrop("reason=not-a-table")
        return
    end
    local kind = rawget(args, "kind")
    if type(kind) ~= "string" or rawget(EXAMPLES_RESULT_KINDS, kind) ~= true then
        logExamplesDrop("kind=" .. safeLogValue(kind, LOG_VALUE_LIMIT))
        return
    end

    local count = nil
    if kind == "success" then
        count = rawget(args, "count")
        if type(count) ~= "number" or count ~= EXAMPLES_EXPECTED_COUNT then
            logExamplesDrop("reason=bad-count count="
                .. safeLogValue(count, LOG_VALUE_LIMIT))
            return
        end
    end

    triggerClientEvent(NBClient.EXAMPLES_STATUS_EVENT, {
        kind = kind,
        count = count,
    })
end

if not NBClient._eventsInstalled then
    LuaEventManager.AddEvent(NBClient.CONTENT_READY_EVENT)
    LuaEventManager.AddEvent(NBClient.UNREAD_CHANGED_EVENT)
    LuaEventManager.AddEvent(NBClient.LANGUAGE_STATUS_EVENT)
    LuaEventManager.AddEvent(NBClient.EXAMPLES_STATUS_EVENT)

    -- 範例包 ack 自己收，不走 NBReader.receive：那支是內容同步協定（manifest／chunk／
    -- imgchunk）的分派器，把一個純 client 端的 UI 回報塞進去會讓 shared 模組認識
    -- 一條它既不產生也不使用的命令。module 與 command 都在這裡過濾，
    -- 其他 MOD 的 OnServerCommand 一律不進來。
    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= Reader.MODULE or command ~= "examplesResult" then
            return
        end
        receiveExamplesResult(args)
    end)

    local loaded, readError = loadReadState()
    if not loaded then
        logLine("read state load failed: " .. safeLogValue(readError))
    end

    Reader.onSnapshot = function(snapshot)
        applySnapshotSafely(snapshot)
    end

    local registerOnTick = nil
    registerOnTick = function()
        if not isClient() then
            Events.OnTick.Remove(registerOnTick)
            -- SP 沒有 register 要送，但維護輪仍得裝上：pumpSettingsRetry 是 SP 下
            -- settings.ini 寫入失敗後唯一的自動自癒路徑（見 maintenanceOnTick）。
            installMaintenance()
            return
        end

        local player = getPlayer()
        if not player or player:getOnlineID() == -1 then
            return
        end

        local state = NBClient.state
        local now = getTimestampMs()
        -- 送出失敗時不 Remove、下一 tick 再試；但要有 5s 間隔，否則變成逐 tick 灌送。
        if state.lastRegisterAttemptMs ~= 0
            and now - state.lastRegisterAttemptMs < REGISTER_RETRY_MS then
            return
        end
        state.registerLanguage = clientLanguage()
        state.lastRegisterAttemptMs = now
        -- langSeq 此時仍是 0（本場還沒切換過）；server 原樣回帶 0，快照即視為相符。
        if not sendCommand("register",
            { lang = state.registerLanguage, lseq = state.langSeq }, now) then
            return
        end

        -- 原版同型：media/lua/shared/Camping/ISCampingMenu.lua:444-456
        -- ISCampingMenu.onDropCorpse 先宣告 local func；條件成立時在 func 內 Remove，否則每 tick 重試。
        Events.OnTick.Remove(registerOnTick)
        installMaintenance()
    end
    Events.OnTick.Add(registerOnTick)

    NBClient._eventsInstalled = true

    local snapshot = Reader.getSnapshot()
    if snapshot then
        applySnapshotSafely(snapshot)
    end
end

return NBClient
