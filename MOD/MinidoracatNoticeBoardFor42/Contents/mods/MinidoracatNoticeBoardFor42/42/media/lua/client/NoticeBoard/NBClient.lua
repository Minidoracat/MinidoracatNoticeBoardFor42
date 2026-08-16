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
        -- 落地失敗、等著重試的偏好值（nil = 沒有待寫入的）。
        settingsPending = nil,
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

-- settings.ini：一行一個 key=value，目前只有 lang。讀寫比照 ReadState（整段 pcall 包覆、
-- 失敗只寫 log 不拋出），玩家手改壞了不得讓面板進不去。
-- 第三個回傳值是**檔案裡的原始字串**（沒有 lang= 這行則為 nil）：正規化會把「沒檔案」、
-- 「值壞掉」、「寫到一半截斷」全部壓成同一個合法值 auto，呼叫端要能分辨才寫得出有用的 log。
local function loadLanguagePreference()
    local reader = nil
    local value = nil
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
            if key == "lang" then
                value = raw
            end
        end

        reader:close()
        reader = nil
    end)

    closeReader(reader)
    if not ok then
        return nil, tostring(readError), nil
    end
    return Core.normalizeLanguagePreference(value), nil, value
end

local function writeLanguagePreference(preference)
    local writer = nil
    local ok, writeError = pcall(function()
        writer = getFileWriter(SETTINGS_FILE, true, false)
        if not writer then
            error("getFileWriter returned nil")
        end
        writer:write("lang=" .. preference .. "\n")
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
    -- 引擎既然沒給可檢查的介面，唯一能確認的方式就是讀回來比對——這個檔只有一行，成本可接受。
    local _, readError, raw = loadLanguagePreference()
    if readError then
        return false, "verify read failed: " .. tostring(readError)
    end
    if raw ~= preference then
        return false, "verify mismatch: stored=" .. tostring(raw)
    end
    return true, nil
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
    local written, writeError = writeLanguagePreference(preference)
    if written then
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

local function pumpSettingsRetry(now)
    local state = NBClient.state
    if state.settingsPending == nil then
        return
    end
    if state.lastSettingsRetryMs ~= 0
        and now - state.lastSettingsRetryMs < SETTINGS_RETRY_MS then
        return
    end
    state.lastSettingsRetryMs = now
    persistLanguagePreference(state.settingsPending)
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
local function clientLanguage()
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
local function sendLanguageRegister(now)
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

-- 首次呼叫才讀檔（clientLanguage 在第一個 OnTick 就會問，比事件安裝還早）。
function NBClient.getLanguagePreference()
    local state = NBClient.state
    if state.languagePreference == nil then
        local preference, readError, raw = loadLanguagePreference()
        if not preference then
            logLine("settings load failed: " .. safeLogValue(readError, 160))
            preference = Core.AUTO_LANGUAGE
        elseif raw ~= nil
            and raw ~= Core.AUTO_LANGUAGE
            and preference == Core.AUTO_LANGUAGE then
            -- 檔案裡確實有 lang=，但正規化後變成 auto：手改成小寫 jp、寫成 zh_TW、
            -- 或上次寫到一半被截斷都會落在這裡。靜默丟棄會讓玩家以為自己改對了。
            logLine("settings lang not recognized value=" .. safeLogValue(raw, LOG_VALUE_LIMIT)
                .. "; using auto")
        end
        state.languagePreference = preference
    end
    return state.languagePreference
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
    local saved = true
    if preference ~= NBClient.getLanguagePreference() then
        -- 寫不進去不影響本場：記憶體裡的偏好照常生效，只是下次進場會回到上一個值。
        state.languagePreference = preference
        saved = persistLanguagePreference(preference)
    elseif state.settingsPending ~= nil then
        -- 值沒變但上次沒寫成功：玩家再點一次同一個語系＝手動重試落地。
        -- 早退不可以把重試路徑一起吃掉，那會讓失敗變成完全無法自救。
        saved = persistLanguagePreference(preference)
    end

    local language = clientLanguage()
    if language == state.registerLanguage and not state.languageSwitchPending then
        return "unchanged", 0, saved
    end

    state.registerLanguage = language
    state.languageSwitchPending = true
    state.languageSwitchArmed = true
    -- 玩家自己再點一次＝重新開始計次，讓上限用盡後仍有手動自救的路。
    state.languageSwitchSends = 0
    state.languageSwitchExhausted = false
    -- 每次發出切換請求就推進序號（回繞見 NBCore.MAX_LANGUAGE_SEQ 的說明）。
    -- 序號在**送出前**推進：送不出去（cooldown/failed）時 pumpLanguageSwitch 補送的是同一個序號，
    -- 而先前那次切換的快照回來時序號一定對不上，不會被誤判成這一次的結果。
    if state.langSeq >= Core.MAX_LANGUAGE_SEQ then
        state.langSeq = 1
    else
        state.langSeq = state.langSeq + 1
    end
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
-- 提示，玩家會一次吃到 N 則 toast。面板據此把換語系後的第一份快照靜音，只重建頁籤。
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

if not NBClient._eventsInstalled then
    LuaEventManager.AddEvent(NBClient.CONTENT_READY_EVENT)
    LuaEventManager.AddEvent(NBClient.UNREAD_CHANGED_EVENT)
    LuaEventManager.AddEvent(NBClient.LANGUAGE_STATUS_EVENT)

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
