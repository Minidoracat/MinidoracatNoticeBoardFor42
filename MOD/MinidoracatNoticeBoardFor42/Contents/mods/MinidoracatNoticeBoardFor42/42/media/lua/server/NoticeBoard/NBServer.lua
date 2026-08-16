if not NBCore then
    require "NoticeBoard/NBCore"
end
if not NBImage then
    require "NoticeBoard/NBImage"
end
if not NBReader then
    require "NoticeBoard/NBReader"
end

local Core = NBCore
local Image = NBImage
local Reader = NBReader
if not Core or not Image or not Reader then
    error("NoticeBoard shared modules failed to load")
end

NBServer = NBServer or {}

NBServer.MODULE = "MinidoracatNB"
NBServer.AUTHORITY = isServer() or not isClient()

if not NBServer.AUTHORITY then
    return NBServer
end

local LOG_NAME = "MinidoracatNoticeBoardFor42"
local LOG_PREFIX = "[MinidoracatNoticeBoardFor42]"
-- 全部收進 NoticeBoard/ 底下，不要散在 Zomboid/Lua/ 根目錄。
-- 放在 NoticeBoard/ 根層是安全的：掃描只列舉 NoticeBoard/<LANG>/，從不列舉根層。
local SERVER_ID_FILE = Reader.NOTICE_ROOT .. getFileSeparator() .. "serverid.txt"
local REQUEST_COOLDOWN_MS = 10000
-- 語系切換走**獨立**的 per-player 冷卻桶，理由與 imgreq 相同（見 handleImgReq）：
-- REQUEST_COOLDOWN_MS 那個桶是給「進場註冊」與「同步逾時補救（resync）」用的，玩家換語系
-- 若跟它們共用，進場後 10 秒內選語系一定被擋、連續換兩次語系也一定要等——而換語系是玩家
-- 手動點選單的操作，頻率天然低。成本面撐得住：換語系只是拿**既有的預分塊快取**重排一個 job
-- （enqueueJob 不讀檔、不重新編碼），真正的投遞量由 processQueue 的 4 人／32 則／單人 8 則
-- per tick 硬限流決定，冷卻只是第二層。取 3 秒是因為維護輪（MAINTENANCE_INTERVAL_MS=1s）
-- 補推追得上，而惡意 client 交替語系時每 3 秒才換一個 job（舊 job 已被 cancelJob 丟掉，不累積）。
local LANGUAGE_COOLDOWN_MS = 3000
local MAINTENANCE_INTERVAL_MS = 1000
local DEFAULT_POLL_SECONDS = 60
local MIN_POLL_SECONDS = 10
local MAX_POLL_SECONDS = 3600
local MAX_PLAYERS_PER_TICK = 4
local MAX_MESSAGES_PER_TICK = 32
local MAX_MESSAGES_PER_PLAYER_PER_TICK = 8
local LOCAL_JOB_KEY = "__MinidoracatNB_SP__"
-- 圖片推送 job 與內容 job 共用 state.jobs／state.queue，靠 key 前綴區隔，
-- 讓兩者一起吃同一份 4 人／32 訊息 per tick 的限流（不可另開旁路）。
local IMAGE_JOB_PREFIX = "img|"
local IMAGE_DIR = Reader.NOTICE_ROOT .. getFileSeparator() .. Image.IMAGE_DIR

local MOD_ID = "MinidoracatNoticeBoardFor42"

-- 範例公告內容放在 MOD 資源檔（media/NoticeBoardExamples/<LANG>.txt），**不寫在 .lua 裡**：
-- Kahlua 載入 .lua 原始碼時會把每個字元截斷成單一位元組，非 ASCII 字面值一律損毀
-- （踩過：中文範例寫到磁碟後整份變亂碼）。getModFileReader 是 UTF-8
-- （LuaManager.java:6005 InputStreamReader(fis, StandardCharsets.UTF_8)），走資源檔可安全保留中文。
local EXAMPLE_DIR = "media" .. getFileSeparator() .. "NoticeBoardExamples"

-- 資源檔讀不到時的最後防線；這是 .lua 內的字面值，**必須維持純 ASCII**
local WELCOME_FALLBACK = [[# Welcome to the Notice Board

Edit this file to publish your own notice.

- One file becomes one tab.
- Put files in the server's Zomboid/Lua/NoticeBoard/<LANG>/ folder.
]]

local function newState()
    return {
        started = false,
        defaultLanguage = "EN",
        sid = nil,
        version = 0,
        lastPollMs = 0,
        lastMaintenanceMs = 0,
        sourceCaches = {},
        languageCaches = {},
        -- 實際掃到檔案的語系（進 manifest，供面板語系選單列出）。
        availableLanguages = {},
        languagesSignature = nil,
        registrations = {},
        online = {},
        cooldowns = {},
        -- 語系已改、但推送被冷卻擋下的玩家；冷卻到期後由 pumpLanguagePending 補推。
        langPending = {},
        -- 語系切換的獨立冷卻桶（見 LANGUAGE_COOLDOWN_MS）；key = username。
        langCooldownAt = {},
        -- 每位玩家最後收到的語系切換序號（client 送、manifest 原樣回帶）。
        -- 舊版 client 不送 -> nil -> manifest 不帶該欄位 -> 對端沿用語系值比對。
        langSeq = {},
        localLanguage = nil,
        jobs = {},
        queued = {},
        queue = {},
        lastReconcileSignature = nil,
        lastIssueSignature = nil,
        rejectLogAt = {},
        reloadCooldownAt = {},
        imageEntries = {},
        imageByHash = {},
        imageManifest = {},
        imageSignature = nil,
        imageQueue = {},
        imageJob = nil,
        imageTotalBytes = 0,
        imageIssues = {},
        imageIssueSignature = nil,
        imageDirty = false,
        -- 原地覆蓋探測的輪替游標：上一輪最後看過的**檔名**（不是索引，理由見 scanImages）。
        imageProbeCursor = nil,
        imgCooldownAt = {},
        readIntUsable = nil,
    }
end

NBServer.state = NBServer.state or newState()

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

-- 對端可控字串進 log 的統一截長。register 的 lang 由 client 任意指定且每 10 秒可送一次，
-- 沒有上界就能把 writeLog 灌到 10MB（ZLogger 是整檔截斷不是輪替）沖掉服主的排查紀錄。
local LOG_VALUE_LIMIT = 64

local function summarize(values, maximum)
    maximum = maximum or 16
    if #values <= maximum then
        return table.concat(values, ",")
    end

    local shown = {}
    local index
    for index = 1, maximum do
        shown[index] = values[index]
    end
    return table.concat(shown, ",") .. ",+" .. tostring(#values - maximum)
end

local function getSandboxOptions()
    if type(SandboxVars) ~= "table" then
        return nil
    end
    local options = rawget(SandboxVars, "MinidoracatNB")
    if type(options) ~= "table" then
        return nil
    end
    return options
end

-- DefaultLanguage 現在是沙盒 enum，引擎交進來的是 1..29 的索引（見 sandbox-options.txt）。
-- **字串也照樣接受**：舊的 servertest.ini 存的是代碼字串（那時這個選項是 type = string），
-- 而 ini 是服主可以手改的檔案——拒收字串等於讓既有伺服器在升級後靜默退回 EN。
-- 兩條路都走同一份白名單（Core.LANGS），不合法才 fallback。
local function validateDefaultLanguage(writeWarning)
    local options = getSandboxOptions()
    local raw = options and rawget(options, "DefaultLanguage") or nil

    if type(raw) == "string" and rawget(Core.LANGS, raw) == true then
        return raw
    end
    -- tonumber：引擎給的是數字，但 ini 手改後也可能是字串形式的數字（"8"）。
    local byIndex = Core.languageByIndex(tonumber(raw))
    if byIndex then
        return byIndex
    end

    if writeWarning then
        logLine("invalid DefaultLanguage=" .. safeLogValue(raw) .. "; fallback=EN")
    end
    return "EN"
end

local function pollIntervalMs()
    local options = getSandboxOptions()
    local seconds = options and tonumber(rawget(options, "PollIntervalSeconds")) or nil
    if not seconds or seconds ~= math.floor(seconds) then
        seconds = DEFAULT_POLL_SECONDS
    end
    if seconds < MIN_POLL_SECONDS then
        seconds = MIN_POLL_SECONDS
    elseif seconds > MAX_POLL_SECONDS then
        seconds = MAX_POLL_SECONDS
    end
    return seconds * 1000
end

local function closeReader(reader)
    if reader then
        pcall(function()
            reader:close()
        end)
    end
end

local function readServerId()
    local reader = nil
    local ok, sid = pcall(function()
        reader = getFileReader(SERVER_ID_FILE, false)
        if not reader then
            return nil
        end
        local value = reader:readLine()
        reader:close()
        reader = nil
        return value
    end)
    closeReader(reader)
    if not ok then
        return nil, tostring(sid)
    end
    return sid, nil
end

local function validServerId(sid)
    return type(sid) == "string"
        and string.len(sid) == 32
        and string.match(sid, "^[0-9a-f]+$") ~= nil
end

local function generateServerId()
    -- 禁用 math.random：Kahlua 的 MathLib 只註冊 abs/ceil/floor/… 共 24 個函式，**沒有 random**
    -- （se/krka/kahlua/j2se/MathLib.java），呼叫會拋 "Object tried to call nil"。
    -- PZ 的標準亂數是全域 ZombRand(max)／ZombRand(min,max)（LuaManager.java:7063-7088），
    -- 原版 Lua 也是零個 math.random 用例。
    local seed = tostring(getTimestampMs())
        .. ":" .. tostring(getTimestamp())
        .. ":" .. tostring(ZombRand(2147483647))
        .. ":" .. tostring(ZombRand(2147483647))
    return Core.djb2Hex(seed .. ":1")
        .. Core.djb2Hex(seed .. ":2")
        .. Core.djb2Hex(seed .. ":3")
        .. Core.djb2Hex(seed .. ":4")
end

local function writeServerId(sid)
    local writer = nil
    local ok, writeError = pcall(function()
        writer = getFileWriter(SERVER_ID_FILE, true, false)
        if not writer then
            error("getFileWriter returned nil")
        end
        writer:write(sid .. "\n")
        writer:close()
        writer = nil
    end)
    if writer then
        pcall(function()
            writer:close()
        end)
    end
    if not ok then
        return false, tostring(writeError)
    end
    return true, nil
end

local function loadOrCreateServerId()
    if not isServer() then
        return "SP"
    end

    local sid, readError = readServerId()
    if validServerId(sid) then
        return sid
    end
    if readError then
        logLine("server id read failed: " .. safeLogValue(readError))
    elseif sid ~= nil then
        logLine("invalid persisted server id; generating a replacement")
    end

    sid = generateServerId()
    local written, writeError = writeServerId(sid)
    if not written then
        logLine("server id persistence failed: " .. safeLogValue(writeError))
    end
    return sid
end

local function writeTextFile(path, content)
    local writer = nil
    local ok, writeError = pcall(function()
        writer = getFileWriter(path, true, false)
        if not writer then
            error("getFileWriter returned nil")
        end
        writer:write(content)
        writer:close()
        writer = nil
    end)
    if writer then
        pcall(function()
            writer:close()
        end)
    end
    if not ok then
        return false, tostring(writeError)
    end
    return true, nil
end

local function writeBootstrapFile(language, content)
    local separator = getFileSeparator()
    return writeTextFile(Reader.NOTICE_ROOT .. separator .. language
        .. separator .. "10_welcome.txt", content)
end

-- 必須定義在 logLine／safeLogValue 之後：Lua 的 local 只對「宣告之後」的程式碼可見，
-- 提前定義會讓函式內取到全域 nil，執行時才炸（本專案已為此類錯誤付出過代價）。
local function readModAsset(path)
    local reader = nil
    local ok, content = pcall(function()
        reader = getModFileReader(MOD_ID, path, false)
        if not reader then
            return nil
        end
        local lines = {}
        while true do
            local line = reader:readLine()
            if line == nil then
                break
            end
            lines[#lines + 1] = line
        end
        reader:close()
        reader = nil
        return table.concat(lines, "\n") .. "\n"
    end)
    closeReader(reader)

    if ok and type(content) == "string" and content ~= "" then
        return content
    end
    return nil
end

local function readExampleContent(language)
    local content = readModAsset(EXAMPLE_DIR .. getFileSeparator() .. language .. ".txt")
    if content then
        return content
    end
    logLine("example asset unavailable for " .. safeLogValue(language) .. "; using ASCII fallback")
    return WELCOME_FALLBACK
end

local function bootstrapIfEmpty()
    local anyFiles, listError = Reader.hasAnyNoticeFiles()
    if anyFiles == nil then
        logLine("bootstrap skipped; notice directory scan failed: " .. safeLogValue(listError))
        return false
    end
    if anyFiles then
        return false
    end

    local enOk, enError = writeBootstrapFile("EN", readExampleContent("EN"))
    local chOk, chError = writeBootstrapFile("CH", readExampleContent("CH"))
    if enOk and chOk then
        logLine("bootstrap created EN/10_welcome.txt and CH/10_welcome.txt")
        return true
    end

    local errors = {}
    if not enOk then
        errors[#errors + 1] = "EN=" .. safeLogValue(enError)
    end
    if not chOk then
        errors[#errors + 1] = "CH=" .. safeLogValue(chError)
    end
    logLine("bootstrap incomplete: " .. table.concat(errors, ","))
    return false
end

-- images/ 目錄的四語系說明檔。內容同樣放 MOD 資源檔（見 EXAMPLE_DIR 註解：.lua 裡的
-- 非 ASCII 字面值會被 Kahlua 截成單一位元組而全毀）。檔名以 00_ 開頭讓它排在最前面；
-- 副檔名 .txt 會被 listImageNames 靜默略過（只有「.png 但不合法」才報 img-invalid-name）。
-- 觸發條件是「**這個檔案**不存在」而不是「目錄是空的」——既有服主早就有圖了，一樣該拿到說明。
-- 已存在則絕不覆蓋（服主可能加了自己的筆記）。images/ 不存在也沒關係：
-- getFileWriter 會自己 mkdirs（LuaManager.java:6733-6739）。
local IMAGES_README_NAME = "00_README.txt"
local IMAGES_README_ASSET = "media" .. getFileSeparator() .. "NoticeBoardImages"
    .. getFileSeparator() .. "README.txt"

local function ensureImagesReadme()
    local path = IMAGE_DIR .. getFileSeparator() .. IMAGES_README_NAME
    local reader = nil
    local probeOk = pcall(function()
        reader = getFileReader(path, false)
    end)
    closeReader(reader)
    -- 探測失敗時什麼都不做：分不清「不存在」與「讀不到」時，不寫才不會蓋掉服主的筆記。
    if not probeOk or reader ~= nil then
        return false
    end

    local content = readModAsset(IMAGES_README_ASSET)
    if not content then
        logLine("images readme asset unavailable; skipped")
        return false
    end

    local written, writeError = writeTextFile(path, content)
    if not written then
        logLine("images readme write failed: " .. safeLogValue(writeError))
        return false
    end
    logLine("images readme created " .. IMAGES_README_NAME)
    return true
end

local function issueText(issue)
    local language = safeLogValue(issue.language or "?")
    local id = safeLogValue(issue.id or "?")
    if issue.kind == "oversize" then
        return "oversize=" .. language .. "/" .. id .. "(" .. tostring(issue.bytes) .. ")"
    elseif issue.kind == "trimmed" then
        return "trimmed=" .. language .. "/" .. id
    end
    return tostring(issue.kind) .. "=" .. language .. "/" .. id
        .. "(" .. safeLogValue(issue.detail or "unknown") .. ")"
end

local function updateIssueLog(issues)
    local texts = {}
    local index
    for index = 1, #issues do
        texts[index] = issueText(issues[index])
    end
    Core.sortSafe(texts)
    local signature = table.concat(texts, "|")
    local state = NBServer.state
    if signature == state.lastIssueSignature then
        return
    end

    if signature == "" then
        if state.lastIssueSignature and state.lastIssueSignature ~= "" then
            logLine("notice content issues cleared")
        end
    else
        logLine("notice content issues: " .. summarize(texts, 32))
    end
    state.lastIssueSignature = signature
end

-- ---------------------------------------------------------------------------
-- 圖片：掃描 -> 分批讀檔 -> 分批 base64 -> 串流 DJB2 -> 預分塊快取
--
-- 全程分批的理由是硬性要求：純 Lua 逐位元組讀檔＋編碼一張 512KB 的圖要數十萬次迭代，
-- 任何「一次跑完」的路徑都會讓 server 主執行緒可見卡頓。這裡每個 tick 只推進
-- Image.BYTES_PER_TICK 個位元組就 return，下一 tick 從斷點續做。
-- ---------------------------------------------------------------------------

local function addImageIssue(kind, name, detail)
    local state = NBServer.state
    state.imageIssues[#state.imageIssues + 1] = {
        kind = kind,
        name = name,
        detail = detail,
    }
    state.imageIssuesDirty = true
end

local function updateImageIssueLog()
    local state = NBServer.state
    local texts = {}
    local index
    for index = 1, #state.imageIssues do
        local issue = state.imageIssues[index]
        local text = tostring(issue.kind) .. "=" .. safeLogValue(issue.name or "?")
        if issue.detail ~= nil then
            text = text .. "(" .. safeLogValue(issue.detail) .. ")"
        end
        texts[index] = text
    end
    Core.sortSafe(texts)
    local signature = table.concat(texts, "|")
    if signature == state.imageIssueSignature then
        return
    end
    if signature == "" then
        if state.imageIssueSignature and state.imageIssueSignature ~= "" then
            logLine("image issues cleared")
        end
    else
        logLine("image issues: " .. summarize(texts, 32))
    end
    state.imageIssueSignature = signature
end

local function listImageNames()
    local ok, files = pcall(function()
        return listFilesInZomboidLuaDirectory(IMAGE_DIR)
    end)
    if not ok then
        return nil, tostring(files)
    end
    if not files then
        return {}, nil
    end

    local names = {}
    local index
    for index = 0, files:size() - 1 do
        local name = files:get(index)
        if Image.isValidName(name) then
            names[#names + 1] = name
        elseif type(name) == "string" and string.match(string.lower(name), "%.png$") then
            addImageIssue("img-invalid-name", name, nil)
        end
    end
    Core.sortSafe(names)

    -- 大小寫不敏感去重：client 端以小寫檔名建索引（markdown 的 images/foo.png 比對不分大小寫），
    -- 撞名的兩個檔在對端無法區分。Linux 專用機的檔案系統允許 Logo.png 與 logo.png 並存，
    -- 這裡先剔除（排序後保留第一個，結果才穩定）並記 issue，否則問題會被丟到 client 端才爆。
    local unique = {}
    local lowered = {}
    for index = 1, #names do
        local key = string.lower(names[index])
        if rawget(lowered, key) then
            addImageIssue("img-dupname", names[index], nil)
        else
            lowered[key] = true
            unique[#unique + 1] = names[index]
        end
    end
    return unique, nil
end

local function closeImageJob(job)
    if job and job.input then
        pcall(function()
            job.input:close()
        end)
        job.input = nil
    end
end

local function recomputeImageTotal()
    local state = NBServer.state
    local total = 0
    local _, entry
    for _, entry in pairs(state.imageEntries) do
        total = total + entry.b
    end
    state.imageTotalBytes = total
end

local function imagePath(name)
    return Reader.NOTICE_ROOT .. getFileSeparator()
        .. Image.IMAGE_DIR .. getFileSeparator() .. name
end

-- 只問大小、不讀內容：getFileInput 回的是 DataInputStream(FileInputStream)
-- （LuaManager.java:6863-6881），available() 就是剩餘位元組數，開檔後立刻關掉。
-- 回傳 nil + 原因代表「這一輪問不到」，呼叫端必須保留既有 entry（見 scanImages）。
local function imageFileSize(name)
    local input = nil
    local ok, size = pcall(function()
        input = getFileInput(imagePath(name))
        if not input then
            return nil
        end
        return input:available()
    end)
    if input then
        pcall(function()
            input:close()
        end)
    end
    if not ok then
        return nil, tostring(size)
    end
    if type(size) ~= "number" then
        return nil, "unreadable"
    end
    return math.floor(size), nil
end

-- **單一迴圈一次最多開幾個圖檔**。實測單次開檔問 available() 約 0.19ms：服主把
-- MaxImageCount 開到 200 時，一口氣掃完是單 tick 約 38ms（掉幀），20 次約 4ms（無感）。
-- **固定值而非依張數比例**：比例會讓成本隨張數線性回到原點，正是這裡要治的病；固定值
-- 給服主一個與任何設定都無關、講得出口的天花板。
-- 取 20 是因為它等於 MaxImageCount 的預設值——預設設定下每輪仍掃得完全部檔名，
-- 偵測延遲維持 1 輪，行為與分批之前**完全相同**；成本只由把張數調高的服主自己承擔。
-- 兩條會開檔的迴圈**各自**受它限制：scanImages 的原地覆蓋探測、startNextImageJob 的
-- 佇列抽取。輪詢那個 tick 兩者都會跑，所以單 tick 最壞是 2 x 20 = 40 次（約 8ms）。
local MAX_IMAGE_OPENS = 20

-- forceAll=true（startup／admin reload）才會無條件重讀既有檔案；平常輪詢對已編碼過的檔名
-- 只開檔問一次 available()（不讀內容、每輪每個檔名至多一次）與 entry.pb 比對，大小不同
-- 就丟掉 entry 讓下面的迴圈重新排隊 —— 服主原地覆蓋 logo.png 不必再按「重新載入」。
-- 編碼進行中（state.imageJob ~= nil）整輪不探測，理由見迴圈上方。
-- ponytail: 這是**啟發式不是保證**。沒有 mtime API 可用（listFilesInZomboidLuaDirectory
-- 只回檔名），換上一張位元組數**剛好相同**的圖偵測不到，那種情況仍得按「重新載入」。
-- 若日後有檔案時間戳 API，改成比對時間戳即可去掉整段探測。
-- ponytail: 每輪至多 MAX_IMAGE_OPENS 次開檔，游標在**排序過的 names 陣列**上輪替，
-- 下一輪從上次停的位置接著跑。原本整輪掃完不分批，註解寫的是「真的量到卡頓再改」——
-- 量到了（200 張單 tick 38ms），所以改了。游標存**檔名不存索引**：檔名是全序，兩輪之間
-- 新增／刪除檔案只會改變名次、不會改變彼此順序，「從第一個大於游標的檔名接著跑」因此
-- 永不漏掃，也不可能因為服主把 MaxImageCount 調小而指到界外（索引游標兩者都會踩）。
-- 代價：張數越多、原地覆蓋越慢生效——最壞 ceil(張數 / 20) 輪（200 張＝10 輪，
-- 60 秒輪詢即 10 分鐘）。急著生效就按「重新載入」，那條走 forceAll 無條件全讀，不受影響。
local function scanImages(forceAll)
    local state = NBServer.state
    state.imageIssues = {}
    state.imageIssuesDirty = true

    local names, listError = listImageNames()
    if not names then
        addImageIssue("img-list", Image.IMAGE_DIR, listError)
        updateImageIssueLog()
        return
    end

    -- 張數上限是**服主政策**（沙盒選項 MaxImageCount，預設 20），不是寫死的牆。
    -- issue 的 detail 帶上生效中的上限，服主看 log 就知道「這是我自己設的值、可以調」。
    local maxCount = Image.maxImageCount()
    if #names > maxCount then
        local limitText = "max" .. tostring(maxCount)
        local dropIndex
        for dropIndex = maxCount + 1, #names do
            addImageIssue("img-count", names[dropIndex], limitText)
        end
        local kept = {}
        for dropIndex = 1, maxCount do
            kept[dropIndex] = names[dropIndex]
        end
        names = kept
    end

    local present = {}
    local index
    for index = 1, #names do
        present[names[index]] = true
    end

    -- queued 必須在移除迴圈之前算好：正在編碼／已排隊的檔名一律跳過大小比對，
    -- 否則會把推到一半的 job 連同已讀的位元組砍掉，或讓同一個檔名重複排隊。
    local queued = {}
    if state.imageJob then
        queued[state.imageJob.name] = true
    end
    for index = 1, #state.imageQueue do
        queued[state.imageQueue[index]] = true
    end

    -- 有 job 在飛時整輪不探測。getFileInput 把開好的串流存在**static** 欄位
    -- （LuaManager.java:2723 `private static FileInputStream inStream;`）：檔案存在但
    -- new FileInputStream 拋例外時（防毒／FTP 鎖檔、EMFILE），LuaManager.java:6873-6881
    -- 只 log 不 return，照樣 fall-through 到 `return new DataInputStream(inStream)`
    -- —— 拿到的是**上一個成功開啟的串流**。那會讓 available() 回報 job 檔案的剩餘位元組數
    -- （比錯大小、把一張好圖的 entry 靜默丟掉），而且底下的 close() 會直接關掉編碼中的串流。
    -- 不在 job 進行中開檔，NBServer **自己**就不會踩到這個別名窗口；代價只是延後一個
    -- 輪詢週期才偵測到覆蓋。
    -- ponytail: 這道守衛只管得住本檔。SP 下 client 與 server 是同一個 Lua VM、共用同一個
    -- static inStream，NBImageCache.fileSize（NBImageCache.lua:93，由 pumpVerify 在
    -- Events.OnTick 呼叫）也會開 getFileInput；快取檔存在但開啟失敗（防毒鎖檔）時，
    -- 它拿到的就是本檔跨 tick 持有的 job 串流，接著把它 close() 掉。屬既有行為、非本守衛
    -- 引入：後果是該 job 下一批讀取拋錯 -> img-read issue -> 該圖重新排隊（會自癒，但可能
    -- 反覆）。要真正關掉窗口得在 NBCore 放一個「串流使用中」旗標讓兩邊互斥，代價大於現況。
    local canProbe = state.imageJob == nil
    local name
    for name in pairs(state.imageEntries) do
        if not rawget(present, name) or forceAll then
            state.imageEntries[name] = nil
            state.imageDirty = true
        end
    end

    -- 探測走**有序的 names 陣列**，不是 pairs(state.imageEntries)：Kahlua 的 pairs 建立時
    -- 對 keySet 取快照，順序既不保證穩定也不保證與上一輪相同——固定取前 N 個會讓後面的
    -- 檔案永遠掃不到。names 是 listImageNames 排序過的結果，游標跑在它上面才叫「輪替」。
    if canProbe and not forceAll then
        local cursor = state.imageProbeCursor or ""
        -- 只用 `<` 與 `==`（sortSafe 的預設比較子就是字串 `<`，全庫已在用）找出第一個
        -- 嚴格大於游標的檔名；跑過尾端就繞回開頭。
        local start = 1
        while start <= #names and names[start] < cursor do
            start = start + 1
        end
        if start <= #names and names[start] == cursor then
            start = start + 1
        end
        if start > #names then
            start = 1
        end

        -- scanned 保證一輪最多繞一圈（不會重複探測同一個檔名），probes 是開檔次數的硬上界。
        -- 尚未編碼（entry 為 nil）與正在編碼／已排隊的檔名只推進游標、不消耗 probes：
        -- 它們本來就要重讀，拿探測額度去空轉只會排擠真正需要比對的檔名。
        local scanned = 0
        local probes = 0
        local probeIndex = start
        while scanned < #names and probes < MAX_IMAGE_OPENS do
            name = names[probeIndex]
            state.imageProbeCursor = name
            local entry = rawget(state.imageEntries, name)
            if entry and not rawget(queued, name) then
                probes = probes + 1
                local size, sizeError = imageFileSize(name)
                if size == nil then
                    -- 問不到大小**不可以**丟掉 entry：暫時性 IO 錯誤會變成重編碼風暴，
                    -- 而且玩家看到的圖會憑空消失。留著舊的，把原因記在 entry 上。
                    -- **記在 entry 而不是直接 addImageIssue**：分批之後這個壞檔每
                    -- ceil(張數 / 20) 輪才輪到一次，其餘輪次 imageIssues 是空的，簽章就會在
                    -- 「有 img-read」與「空」之間逐圈翻臉——服主會在故障持續中看到
                    -- 「image issues cleared」然後又復發。改由下面的重排迴圈每輪重新掛上，
                    -- 簽章才真的逐輪相同（updateImageIssueLog 只寫一次）。
                    entry.readErr = sizeError or "unreadable"
                elseif size ~= entry.pb then
                    state.imageEntries[name] = nil
                    state.imageDirty = true
                else
                    entry.readErr = nil
                end
            end
            probeIndex = probeIndex + 1
            if probeIndex > #names then
                probeIndex = 1
            end
            scanned = scanned + 1
        end
    end

    if forceAll then
        closeImageJob(state.imageJob)
        state.imageJob = nil
    end
    -- 移除 entry 後總量必須重算，否則舊大小會一直佔額度、之後的圖被 img-total 誤擋。
    recomputeImageTotal()

    if forceAll then
        state.imageQueue = {}
        queued = {}
    end

    for index = 1, #names do
        name = names[index]
        local entry = rawget(state.imageEntries, name)
        if entry == nil then
            if not rawget(queued, name) then
                state.imageQueue[#state.imageQueue + 1] = name
                queued[name] = true
            end
        elseif entry.readErr then
            -- 上次探測問不到大小、這輪還沒輪到重探：issue 每輪都要在，簽章才不會翻臉
            -- （見探測迴圈裡設定 readErr 的地方）。重探成功／檔案被移除／forceAll 都會清掉它。
            addImageIssue("img-read", name, entry.readErr)
        end
    end
end

local function rebuildImageManifest()
    local state = NBServer.state
    local names = {}
    local name
    for name in pairs(state.imageEntries) do
        names[#names + 1] = name
    end
    Core.sortSafe(names)

    local manifest = {}
    local byHash = {}
    local signatureParts = {}
    local index
    for index = 1, #names do
        local entry = rawget(state.imageEntries, names[index])
        manifest[index] = {
            name = entry.name,
            h = entry.h,
            n = entry.n,
            b = entry.b,
        }
        byHash[entry.h] = entry
        signatureParts[index] = string.lower(entry.name) .. ":" .. entry.h
    end

    state.imageManifest = manifest
    state.imageByHash = byHash
    local signature = table.concat(signatureParts, "|")
    local changed = signature ~= state.imageSignature
    state.imageSignature = signature
    return changed
end

-- 抽佇列一樣要限開檔次數。**永久被拒**的圖（img-oversize／img-total／img-empty／img-read）
-- 拿不到 entry，所以 scanImages 每一輪都會把它們重新排隊，而這個迴圈原本會在同一個 tick 把
-- 整條佇列抽乾：200 張全被拒＝單 tick 開 200 個檔（實測 34ms 掉幀），把上面探測迴圈省下來的
-- IO 原樣還回去。佇列本來就跨 tick 存活、pumpImageEncode 每 tick 都跑，攤到後續 tick 抽乾
-- 即可，不會有任何檔名被跳過（只是被拒的 issue 晚幾個 tick 才寫進 log）。
local function startNextImageJob()
    local state = NBServer.state
    local opens = 0
    while #state.imageQueue > 0 and opens < MAX_IMAGE_OPENS do
        local name = table.remove(state.imageQueue, 1)
        if rawget(state.imageEntries, name) == nil then
            opens = opens + 1
            local input = nil
            local ok, size = pcall(function()
                input = getFileInput(imagePath(name))
                if not input then
                    return nil
                end
                return input:available()
            end)

            if not ok or input == nil or type(size) ~= "number" then
                if input then
                    pcall(function()
                        input:close()
                    end)
                end
                addImageIssue("img-read", name, ok and "unreadable" or tostring(size))
            elseif size <= 0 then
                pcall(function()
                    input:close()
                end)
                addImageIssue("img-empty", name, nil)
            elseif size > Image.maxImageBytes() then
                pcall(function()
                    input:close()
                end)
                -- detail 帶上生效中的上限：兩者都是服主可調的沙盒選項（MaxImageKB／
                -- MaxImageTotalKB），log 只寫檔案大小會讓服主誤以為撞到 MOD 寫死的牆。
                -- 分隔用 "/"：sanitizeName 會把空白與 = 換成 _（NBCore.lua:595）。
                addImageIssue("img-oversize", name,
                    tostring(size) .. "/max" .. tostring(Image.maxImageBytes()))
            elseif state.imageTotalBytes + size > Image.maxTotalBytes() then
                pcall(function()
                    input:close()
                end)
                addImageIssue("img-total", name,
                    tostring(size) .. "/max" .. tostring(Image.maxTotalBytes()))
            else
                state.imageJob = {
                    name = name,
                    input = input,
                    size = math.floor(size),
                    read = 0,
                    carry = {},
                    pending = "",
                    chunks = {},
                    hash = Image.hashInit(),
                    method = nil,
                    startMs = getTimestampMs(),
                    maxBatchMs = 0,
                    workMs = 0,
                }
                return true
            end
        end
    end
    return false
end

-- 具名包裝：迴圈內不建立 closure。一張 512KB 的圖要跑十幾萬次，
-- 每次都新建一個 closure 會白白製造 GC 壓力。
local function callReadInt(input)
    return input:readInt()
end

-- 一批讀取：優先用 readInt()（一次呼叫吃 4 bytes，反射呼叫數少 4 倍），
-- 不可用時退回 read()（回傳 0..255，EOF 為 -1，是安全的逐位元組原語）。
-- 探測只做一次（第一次呼叫、且尚未消耗任何位元組時），之後迴圈內不再 pcall——
-- 錯誤直接往上拋給 pumpImageEncode 的 pcall 收。
local function readImageBatch(job, target, maxBytes)
    local remaining = job.size - job.read
    if maxBytes < remaining then
        remaining = maxBytes
    end
    if remaining <= 0 then
        return 0
    end

    local state = NBServer.state
    local input = job.input
    local produced = #target
    local got = 0

    if job.method == nil then
        if state.readIntUsable == false or job.size < 4 then
            job.method = "read"
        else
            local ok, value = pcall(callReadInt, input)
            if ok and type(value) == "number" then
                state.readIntUsable = true
                job.method = "readInt"
                if value < 0 then
                    value = value + 4294967296
                end
                target[produced + 1] = math.floor(value / 16777216)
                target[produced + 2] = math.floor(value / 65536) % 256
                target[produced + 3] = math.floor(value / 256) % 256
                target[produced + 4] = value % 256
                produced = produced + 4
                got = 4
            else
                -- method 不存在時 Kahlua 在讀取前就拋錯，串流位置未動，可安全降級。
                state.readIntUsable = false
                job.method = "read"
            end
        end
    end

    if job.method == "readInt" then
        while remaining - got >= 4 do
            local value = input:readInt()
            if value < 0 then
                value = value + 4294967296
            end
            target[produced + 1] = math.floor(value / 16777216)
            target[produced + 2] = math.floor(value / 65536) % 256
            target[produced + 3] = math.floor(value / 256) % 256
            target[produced + 4] = value % 256
            produced = produced + 4
            got = got + 4
        end
    end

    while got < remaining do
        local value = input:read()
        if type(value) ~= "number" then
            error("read returned " .. tostring(value) .. " at byte "
                .. tostring(job.read + got + 1))
        end
        if value < 0 then
            break
        end
        produced = produced + 1
        target[produced] = value % 256
        got = got + 1
    end

    job.read = job.read + got
    return got
end

local function finishImageJob(job)
    local state = NBServer.state
    Image.flushChunks(job.pending, job.chunks)
    -- pb（probe bytes）＝開檔當下 available() 報的大小，**只**給 scanImages 的原地覆蓋
    -- 比對用；b 是真正編出來的位元組數，manifest 與額度都用它。串流比 available() 宣告的
    -- 早結束時（sparse file／網路掛載／尾段固定讀取失敗）b < pb，此時拿 b 去跟下一輪的
    -- available() 比會永遠不相等 -> 該圖每輪重編一次、每輪重推 manifest 給全體玩家。
    local entry = {
        name = job.name,
        h = Image.hashHex(job.hash),
        n = #job.chunks,
        b = job.read,
        pb = job.size,
        chunks = job.chunks,
    }
    state.imageEntries[job.name] = entry
    recomputeImageTotal()
    state.imageDirty = true

    -- encodeMs 是每批耗時的累加（真正花掉的 server 時間），不是 startMs 到現在的牆鐘差：
    -- 後者包含每個 tick 之間的閒置，會隨伺服器 tick rate 浮動，服主拿來調 BYTES_PER_TICK
    -- 只會得到反向的訊號。牆鐘差另外用 spanMs 呈現（看「這張圖等了多久才好」）。
    logLine("image encoded name=" .. safeLogValue(job.name)
        .. " bytes=" .. tostring(entry.b)
        .. " hash=" .. entry.h
        .. " chunks=" .. tostring(entry.n)
        .. " encodeMs=" .. tostring(math.floor(job.workMs))
        .. " spanMs=" .. tostring(math.floor(getTimestampMs() - job.startMs))
        .. " maxBatchMs=" .. tostring(math.floor(job.maxBatchMs)))
end

-- 推進一批。回傳 true 表示「圖片清單此刻剛剛變更完成」，由呼叫端負責推送
-- （推送需要 enqueueJob，那是本檔後面才定義的 local；在這裡呼叫會取到全域 nil）。
local function pumpImageEncode()
    local state = NBServer.state
    if not state.imageJob and not startNextImageJob() then
        local published = false
        -- 佇列還沒抽乾就不結算。startNextImageJob 回 false 有兩種可能：佇列空了，或是撞到
        -- 每次抽取的開檔上限。後者的 issue 清單還是半套的，這裡結算會逐 tick 寫一行
        -- 「image issues: ...」（越寫越長）並推播還缺圖的 manifest。加上這個條件，
        -- 「回 false ＝佇列已空」這個原本就成立的前提才繼續成立。
        if #state.imageQueue == 0 then
            if state.imageDirty then
                state.imageDirty = false
                published = rebuildImageManifest()
            end
            if state.imageIssuesDirty then
                state.imageIssuesDirty = false
                updateImageIssueLog()
            end
        end
        return published
    end

    local job = state.imageJob
    local batchStartMs = getTimestampMs()
    local ok, batchError = pcall(function()
        local bytes = job.carry
        local carried = #bytes
        local got = readImageBatch(job, bytes, Image.BYTES_PER_TICK)
        local available = carried + got
        -- got == 0 也算收尾：串流比 available() 宣告的還早結束時，若不當成 final
        -- 這個 job 會每 tick 空轉、永遠不完成。
        local isFinal = job.read >= job.size or got == 0

        local usable = available
        if not isFinal then
            usable = math.floor(available / 3) * 3
        end
        if usable > 0 then
            local produced = Image.encodeBytes(bytes, 1, usable, isFinal)
            job.hash = Image.hashUpdate(job.hash, produced)
            job.pending = Image.pushChunks(job.pending, produced,
                job.chunks, Core.CHUNK_UTF16_LIMIT)
        end

        local leftover = {}
        local index
        for index = usable + 1, available do
            leftover[#leftover + 1] = bytes[index]
        end
        job.carry = leftover
        job.done = isFinal
    end)

    local batchMs = getTimestampMs() - batchStartMs
    job.workMs = job.workMs + batchMs
    if batchMs > job.maxBatchMs then
        job.maxBatchMs = batchMs
    end

    if not ok then
        closeImageJob(job)
        state.imageJob = nil
        addImageIssue("img-read", job.name, batchError)
        return false
    end

    if job.done then
        closeImageJob(job)
        state.imageJob = nil
        finishImageJob(job)
    end
    return false
end

local function buildLanguageCaches()
    local state = NBServer.state
    local scanned = Reader.scanAll(state.sourceCaches)
    local caches = {}
    local issues = {}
    local index
    for index = 1, #scanned.issues do
        issues[#issues + 1] = scanned.issues[index]
    end

    local languages = Reader.getLanguageCodes()
    -- 「有內容」看的是該語系目錄本身掃到的檔案，不是 composeLanguage 的結果——
    -- 後者含 defaultLanguage 的 fallback，每個語系都會非空，選單就變成列出全部 29 個。
    local available = {}
    for index = 1, #languages do
        local language = languages[index]
        local cache = Reader.composeLanguage(scanned.languages, language, state.defaultLanguage)
        caches[language] = cache
        local source = rawget(scanned.languages, language)
        if source and #source.files > 0 then
            available[#available + 1] = language
        end
        local trimIndex
        for trimIndex = 1, #cache.trimmed do
            issues[#issues + 1] = {
                kind = "trimmed",
                language = language,
                id = cache.trimmed[trimIndex],
            }
        end
    end

    -- producer 端也走 Core.normalizeLanguageList（先前只有 receiver 呼叫，NBCore 那句
    -- 「producer 與 receiver 共用」的註解是假的，MAX_LANGUAGE_LIST 在產生端從未被強制）。
    -- 這裡驗過再送，壞掉的清單就不會變成「client 靜默丟棄整份 langs、服主毫無線索」。
    -- 失敗只降級成空清單（選單只剩「自動」），絕不可讓伺服器起不來。
    local normalized, listError = Core.normalizeLanguageList(available)
    if not normalized then
        logLine("available language list rejected: " .. safeLogValue(listError, LOG_VALUE_LIMIT))
        normalized = {}
    end

    return {
        sources = scanned.languages,
        caches = caches,
        issues = issues,
        languages = languages,
        available = normalized,
    }
end

local function nextJobMessage(job)
    if job.kind == "image" then
        while job.entryIndex <= #job.entries do
            -- 圖片 job 的 entries 是 { entry = <imageByHash 的條目>, from = <續傳起點> }。
            -- entry 本身是共用且不可變的（imageByHash 直接餵給每位玩家），起點只能包在外面。
            local queued = job.entries[job.entryIndex]
            local entry = queued.entry
            -- chunkIndex 0 = 這個條目還沒開始推，起點吃 client 指定的 from。
            if job.chunkIndex == 0 then
                job.chunkIndex = queued.from
            end
            if job.chunkIndex <= entry.n then
                local chunkIndex = job.chunkIndex
                job.chunkIndex = job.chunkIndex + 1
                return "imgchunk", {
                    h = entry.h,
                    i = chunkIndex,
                    part = entry.chunks[chunkIndex],
                }
            end
            job.entryIndex = job.entryIndex + 1
            job.chunkIndex = 0
        end
        return nil, nil
    end

    if not job.manifestSent then
        job.manifestSent = true
        return "manifest", {
            v = job.v,
            sid = job.sid,
            files = job.cache.manifestFiles,
            images = job.images,
            langs = job.languages,
            -- 這份內容是哪個語系。舊版 client 忽略未知欄位，互通不受影響。
            lang = job.language,
            -- 這份內容對應到 client 的哪一次語系切換請求。client 靠序號（而非語系值）確認
            -- 切換真的完成：EN->JP->EN 這種來回切換下，語系值比對會被一份「剛好同語系」的
            -- 舊快照誤判成完成，序號不會。nil（舊版 client）時該欄位不存在，對端自動退回舊行為。
            lseq = job.lseq,
        }
    end

    -- manifestOnly：圖片清單變更時只需要重送權威快照。client 端 receiveManifest 會沿用
    -- hash 相同的既有內容，因此一則訊息就完成更新，不必把整個語系的分塊再推一次。
    if job.manifestOnly then
        return nil, nil
    end

    while job.fileIndex <= #job.cache.files do
        local entry = job.cache.files[job.fileIndex]
        if job.chunkIndex <= entry.n then
            local chunkIndex = job.chunkIndex
            job.chunkIndex = job.chunkIndex + 1
            return "chunk", {
                v = job.v,
                id = entry.id,
                i = chunkIndex,
                part = entry.chunks[chunkIndex],
            }
        end
        job.fileIndex = job.fileIndex + 1
        job.chunkIndex = 1
    end
    return nil, nil
end

-- 只取消內容推送。圖片 job 與語系無關（內容定址），切語系時沒有理由把傳到一半的圖丟掉；
-- 玩家離線時才由 rebuildOnlinePlayers 一併清掉。
local function cancelJob(key)
    local state = NBServer.state
    state.jobs[key] = nil
end

local function pushQueue(key)
    local state = NBServer.state
    if not rawget(state.queued, key) then
        state.queue[#state.queue + 1] = key
        state.queued[key] = true
    end
end

-- enqueueJob 失敗（語系快取全空＝startup 掃描拋錯後的半殘狀態）在玩家端顯示成
-- 「同步中」->「同步逾時」，服主的 log 卻只有 startup 那一行孤立的 notice refresh failed，
-- 兩邊對不起來。這裡補一行帶 username 與 language 的紀錄，並比照 rejectLogAt 做 per-player
-- 節流——失敗會由 pumpLanguagePending／enqueueAffected 每輪重試，不節流就是每 tick 灌 log。
local function logEnqueueFailure(key, language)
    local state = NBServer.state
    local now = getTimestampMs()
    local logKey = "enq|" .. tostring(key)
    local lastLog = rawget(state.rejectLogAt, logKey) or 0
    if lastLog ~= 0 and now - lastLog < REQUEST_COOLDOWN_MS then
        return
    end
    state.rejectLogAt[logKey] = now
    logLine("enqueue failed username=" .. safeLogValue(key, LOG_VALUE_LIMIT)
        .. " lang=" .. safeLogValue(language, LOG_VALUE_LIMIT)
        .. " reason=no-language-cache")
end

local function enqueueJob(key, language, localDelivery, manifestOnly)
    local state = NBServer.state
    local cache = rawget(state.languageCaches, language)
    if not cache then
        cache = rawget(state.languageCaches, state.defaultLanguage)
    end
    if not cache then
        -- log 放在這裡而不是 10 個呼叫點：只有這一處知道失敗原因，而且改一處就全部覆蓋。
        logEnqueueFailure(key, language)
        return false
    end

    state.jobs[key] = {
        key = key,
        kind = "content",
        username = key,
        language = language,
        -- 這份內容要回帶的語系切換序號。nil＝該玩家的 client 是舊版（沒送過序號）。
        lseq = rawget(state.langSeq, key),
        localDelivery = localDelivery == true,
        manifestOnly = manifestOnly == true,
        cache = cache,
        images = state.imageManifest,
        languages = state.availableLanguages,
        v = state.version,
        sid = state.sid,
        manifestSent = false,
        fileIndex = 1,
        chunkIndex = 1,
    }
    pushQueue(key)
    return true
end

-- 這位玩家是不是已經有「同語系、同切換序號」的完整內容 job 在推送中。
-- enqueueJob 是覆寫語意（state.jobs[key] = {...}）：對飛行中的 job 再排一次會讓它從
-- manifest／fileIndex=1 重頭開始。client 的切換重送每 3 秒一次，一份大內容在多人佇列
-- （4 人／32 則／單人 8 則 per tick）下就永遠推不完，而且重複的 manifest／分塊還會吃掉
-- 全局 32 則的額度拖慢其他玩家。job 送完即由 processQueue 移除，所以「存在」就等於「還在推」。
-- manifestOnly 的 job 不算：它刻意只送 manifest（每份公告的 hash 都沒動），
-- 而換語系要的是整包內容，必須讓它被覆寫掉。
local function contentJobInFlight(username, language, seq)
    local job = rawget(NBServer.state.jobs, username)
    return job ~= nil
        and job.kind == "content"
        and job.manifestOnly ~= true
        and job.language == language
        and job.lseq == seq
end

-- 附加而非覆蓋：內容 job 被取代時會從 manifest 重頭重送，圖片 job 不行——client 的下一次
-- imgreq 刻意排除了「正在接收中」的 hash，所以覆蓋掉推到一半的 job，那張圖剩下的分塊
-- 就再也不會送出，client 只能等 60 秒逾時、累積 attempts，三次後永遠退回 [替代文字]。
local function enqueueImageJob(username, entries, localDelivery)
    local state = NBServer.state
    local key = IMAGE_JOB_PREFIX .. username
    local existing = rawget(state.jobs, key)
    if existing and existing.kind == "image" then
        local index, pendingIndex
        for index = 1, #entries do
            local entry = entries[index]
            local duplicate = false
            -- 只比對「還沒送出」的區段：已送過的 hash 再被要求，代表 client 那邊失敗了，
            -- 應該重送。#entries 上限＝Image.maxImageCount()（服主政策，沙盒上界 200），
            -- 且內層只掃「未送出」的區段（backlog 有界），成本仍然可控。
            for pendingIndex = existing.entryIndex, #existing.entries do
                local queued = existing.entries[pendingIndex]
                if queued.entry.h == entry.entry.h then
                    duplicate = true
                    -- 同一個 hash 又被要求一次而且還沒送出：取兩者較早的續傳起點。
                    -- 不取最小值的話，client 把進度整份丟掉（改送 from=1）會被排在
                    -- 佇列裡的舊 from=k 蓋掉，前 k-1 塊永遠不會送出去。
                    if entry.from < queued.from then
                        queued.from = entry.from
                    end
                    break
                end
            end
            if not duplicate then
                existing.entries[#existing.entries + 1] = entry
            end
        end
        pushQueue(key)
        return key
    end

    state.jobs[key] = {
        key = key,
        kind = "image",
        username = username,
        localDelivery = localDelivery == true,
        entries = entries,
        entryIndex = 1,
        -- 0＝第一個條目還沒開始（見 nextJobMessage：起點由該條目的 from 決定）。
        chunkIndex = 0,
    }
    pushQueue(key)
    return key
end

-- changed = 內容真的變了的語系（要整包重推）。listChanged = 只有「有內容的語系清單」變了
-- （manifest 的 langs），此時每份公告的 hash 都沒動：client 的 receiveManifest 會沿用既有內容，
-- 送 manifest 就夠了，把整個語系的分塊再推一遍純屬浪費頻寬（那批 chunk 全會被丟棄）。
-- 例外是該玩家還有推到一半的 job：manifestOnly 會蓋掉它，讓 client 永遠等不到剩下的分塊，
-- 所以那種情況照常整包重推（與 publishImageManifest 同一套判斷）。
local function enqueueAffected(changed, forceAll, listChanged)
    local state = NBServer.state
    local username, language
    for username, language in pairs(state.registrations) do
        if forceAll or rawget(changed, language) then
            enqueueJob(username, language, false, false)
        elseif listChanged then
            enqueueJob(username, language, false, rawget(state.jobs, username) == nil)
        end
    end
    if state.localLanguage then
        if forceAll or rawget(changed, state.localLanguage) then
            enqueueJob(LOCAL_JOB_KEY, state.localLanguage, true, false)
        elseif listChanged then
            enqueueJob(LOCAL_JOB_KEY, state.localLanguage, true,
                rawget(state.jobs, LOCAL_JOB_KEY) == nil)
        end
    end
end

-- 圖片清單變更後的推送。定義在 enqueueJob 之後（pumpImageEncode 只回報「有變更」）。
-- 只在該玩家沒有進行中的推送時才用 manifestOnly：否則新 job 會蓋掉推到一半的內容 job，
-- 讓 client 收到新版 manifest 卻永遠等不到剩下的分塊（要靠逾時 resync 才救得回來）。
local function publishImageManifest()
    local state = NBServer.state
    state.version = state.version + 1
    local username, language
    for username, language in pairs(state.registrations) do
        enqueueJob(username, language, false, rawget(state.jobs, username) == nil)
    end
    if state.localLanguage then
        enqueueJob(LOCAL_JOB_KEY, state.localLanguage, true,
            rawget(state.jobs, LOCAL_JOB_KEY) == nil)
    end
    logLine("image manifest v=" .. tostring(state.version)
        .. " images=" .. tostring(#state.imageManifest)
        .. " bytes=" .. tostring(state.imageTotalBytes))
end

local function refreshSnapshot(reason, forceAll)
    local state = NBServer.state
    -- 圖片沿用同一輪詢節奏，不另開輪詢；實際的讀檔／編碼由 pumpImageEncode 每 tick 分批做。
    local scanOk, scanError = pcall(scanImages, forceAll == true)
    if not scanOk then
        logLine("image scan failed: " .. safeLogValue(scanError))
    end

    local ok, built = pcall(buildLanguageCaches)
    if not ok then
        logLine("notice refresh failed: " .. safeLogValue(built))
        return false
    end

    local changed = {}
    local changedNames = {}
    local index
    for index = 1, #built.languages do
        local language = built.languages[index]
        local oldCache = rawget(state.languageCaches, language)
        local newCache = rawget(built.caches, language)
        if forceAll or not Reader.languageCachesEqual(oldCache, newCache) then
            changed[language] = true
            changedNames[#changedNames + 1] = language
        end
    end

    -- 語系清單只在 manifest 裡，而 enqueueAffected 只推「內容有變的語系」的玩家：
    -- 新增／移除一個語系目錄時，其他語系的玩家不會收到新 manifest，選單就會過期。
    -- 清單變了就讓所有註冊者都拿到新 manifest（內容沒變的走 manifestOnly，見 enqueueAffected）。
    local languagesSignature = table.concat(built.available, ",")
    local listChanged = languagesSignature ~= state.languagesSignature
    state.languagesSignature = languagesSignature
    -- 服主唯一能看到「這台伺服器實際有哪些語系目錄」的地方。沙盒的 DefaultLanguage 是
    -- 固定清單的下拉（見 sandbox-options.txt 的說明：沙盒選項在載入期就解析完，沒有執行期
    -- 產生選項的機制），所以偵測結果只能用 log 呈現。**只在清單變化時寫**（listChanged），
    -- 不是每輪都寫——writeLog 到 10MB 是整檔截斷而非輪替。空清單寫成 "-"，
    -- 那代表所有語系目錄都沒有合法公告檔（bootstrap 之前就是這個狀態）。
    if listChanged then
        local availableText = "-"
        if #built.available > 0 then
            availableText = summarize(built.available, #Core.LANG_ORDER)
        end
        logLine("notice languages=" .. availableText
            .. " default=" .. safeLogValue(state.defaultLanguage, LOG_VALUE_LIMIT))
    end

    state.sourceCaches = built.sources
    state.languageCaches = built.caches
    state.availableLanguages = built.available
    updateIssueLog(built.issues)

    if #changedNames == 0 and not listChanged then
        return false
    end

    state.version = state.version + 1
    enqueueAffected(changed, forceAll, listChanged)
    local changedText = "-"
    if #changedNames > 0 then
        changedText = summarize(changedNames, 16)
    end
    local message = "snapshot v=" .. tostring(state.version)
        .. " reason=" .. tostring(reason)
        .. " changed=" .. changedText
    if listChanged then
        message = message .. " langs=" .. summarize(built.available, 16)
    end
    logLine(message)
    return true
end

local function countMapEntries(values)
    local count = 0
    local _
    for _ in pairs(values) do
        count = count + 1
    end
    return count
end

local function languageSummary()
    local state = NBServer.state
    local counts = {}
    local _, language
    for _, language in pairs(state.registrations) do
        counts[language] = (rawget(counts, language) or 0) + 1
    end
    if state.localLanguage then
        counts[state.localLanguage] = (rawget(counts, state.localLanguage) or 0) + 1
    end

    local names = {}
    for language in pairs(counts) do
        names[#names + 1] = language
    end
    Core.sortSafe(names)
    local parts = {}
    local index
    for index = 1, #names do
        language = names[index]
        parts[index] = language .. ":" .. tostring(counts[language])
    end
    if #parts == 0 then
        return "-"
    end
    return table.concat(parts, ",")
end

local function writeReconcile(force, abnormal)
    local state = NBServer.state
    local onlineCount
    local registeredCount
    if state.localLanguage then
        onlineCount = 1
        registeredCount = 1
    else
        onlineCount = countMapEntries(state.online)
        registeredCount = countMapEntries(state.registrations)
    end
    local langs = languageSummary()
    local signature = tostring(registeredCount)
        .. "|" .. tostring(onlineCount)
        .. "|" .. tostring(state.version)
        .. "|" .. langs
    if not force and signature == state.lastReconcileSignature then
        return
    end

    local message = "reconcile registered=" .. tostring(registeredCount)
        .. " online=" .. tostring(onlineCount)
        .. " v=" .. tostring(state.version)
        .. " langs=" .. langs
    if abnormal then
        message = message .. " abnormal=" .. tostring(abnormal)
    elseif onlineCount > 0 and registeredCount < onlineCount then
        message = message .. " abnormal=missing-registration"
    end
    logLine(message)
    state.lastReconcileSignature = signature
end

local function rebuildOnlinePlayers()
    local state = NBServer.state
    if not isServer() then
        state.online = {}
        return
    end

    local online = {}
    local players = getOnlinePlayers()
    local index
    for index = 0, players:size() - 1 do
        local player = players:get(index)
        if player then
            local username = player:getUsername()
            if type(username) == "string" and username ~= "" then
                online[username] = player
            end
        end
    end

    local username
    for username in pairs(state.registrations) do
        if not rawget(online, username) then
            state.registrations[username] = nil
            state.cooldowns[username] = nil
            state.langCooldownAt[username] = nil
            state.langSeq[username] = nil
            cancelJob(username)
            state.jobs[IMAGE_JOB_PREFIX .. username] = nil
        end
    end
    -- rejectLogAt 的 key 有多種形式（username、"reload|"..username、"enq|"..username），且被拒的
    -- register 玩家從未進 registrations——必須以 rejectLogAt 本身為基準清理，否則此表隨歷史 username
    -- 無界成長。清理以「本名或去掉任一已知前綴後的名字」任一在線即保留：PZ username 可含 `|`，
    -- 單純去前綴會把本名就叫 "reload|xxx" 的玩家與 reload-reject key 混為一談。
    local LOG_KEY_PREFIXES = { "reload|", "enq|" }
    local function ownerOffline(key)
        if rawget(online, key) then
            return false
        end
        local prefixIndex
        for prefixIndex = 1, #LOG_KEY_PREFIXES do
            local prefix = LOG_KEY_PREFIXES[prefixIndex]
            local prefixLength = string.len(prefix)
            if string.sub(key, 1, prefixLength) == prefix
                and rawget(online, string.sub(key, prefixLength + 1)) then
                return false
            end
        end
        return true
    end

    local logKey
    for logKey in pairs(state.rejectLogAt) do
        if ownerOffline(logKey) then
            state.rejectLogAt[logKey] = nil
        end
    end
    local reloadKey
    for reloadKey in pairs(state.reloadCooldownAt) do
        if ownerOffline(reloadKey) then
            state.reloadCooldownAt[reloadKey] = nil
        end
    end
    local imgKey
    for imgKey in pairs(state.imgCooldownAt) do
        if imgKey ~= LOCAL_JOB_KEY and not rawget(online, imgKey) then
            state.imgCooldownAt[imgKey] = nil
        end
    end
    state.online = online
end

local function deliver(job, player, command, payload)
    if job.localDelivery then
        triggerEvent(Reader.LOCAL_EVENT, NBServer.MODULE, command, payload)
    else
        sendServerCommand(player, NBServer.MODULE, command, payload)
    end
end

-- 三個上限（4 人／32 則／單人 8 則）都必須是「每 tick」而不是「每次取 job」。
-- 舊版把佇列當環形跑：未送完的 job 立刻排回同一個 while 的佇列尾端，而 sentForPlayer 在
-- 每次取 job 時歸零，於是佇列裡只有一位玩家時，同一個 job 一個 tick 內被取 4 次 ×8 則
-- ＝32 則全灌給同一個人；playersProcessed 數的也是 job 造訪次數而非不同玩家數。
--
-- 改成「一個 tick 只掃一次佇列快照」：每個 key 最多造訪一次，額度以 job.username 累計
-- （內容 job 的 username 就是 key，圖片 job 是 "img|"..username 但 username 欄位相同，
-- 兩者因此共吃同一份 8 則額度——這是刻意的，不可另開旁路）。
-- 回寫順序：本 tick 沒碰到的排前面（先來先服務），送過但沒送完的排到最後（長 job 不餓死他人）。
local function processQueue()
    local state = NBServer.state
    local pending = state.queue
    state.queue = {}

    local sentByPlayer = {}
    local playersProcessed = 0
    local messagesSent = 0
    local carried = {}
    local requeued = {}

    local index
    for index = 1, #pending do
        local key = pending[index]
        local job = rawget(state.jobs, key)
        if not job then
            state.queued[key] = nil
        else
            local player = nil
            local valid = false
            if job.localDelivery then
                valid = state.localLanguage ~= nil
                if job.kind == "content" then
                    valid = state.localLanguage == job.language
                end
            else
                player = rawget(state.online, job.username)
                valid = player ~= nil and rawget(state.registrations, job.username) ~= nil
                if job.kind == "content" then
                    valid = player ~= nil
                        and rawget(state.registrations, job.username) == job.language
                end
            end

            if not valid then
                state.jobs[key] = nil
                state.queued[key] = nil
            else
                local sentForPlayer = rawget(sentByPlayer, job.username)
                local blocked = messagesSent >= MAX_MESSAGES_PER_TICK
                    or (sentForPlayer == nil and playersProcessed >= MAX_PLAYERS_PER_TICK)
                    or (sentForPlayer ~= nil and sentForPlayer >= MAX_MESSAGES_PER_PLAYER_PER_TICK)

                if blocked then
                    -- 本 tick 額度用盡：原封不動留到下一 tick（queued 旗標維持 true）。
                    carried[#carried + 1] = key
                else
                    if sentForPlayer == nil then
                        sentForPlayer = 0
                        playersProcessed = playersProcessed + 1
                    end
                    local failed = false
                    local complete = false
                    while sentForPlayer < MAX_MESSAGES_PER_PLAYER_PER_TICK
                        and messagesSent < MAX_MESSAGES_PER_TICK
                        and not failed
                        and not complete do
                        local command, payload = nextJobMessage(job)
                        if not command then
                            complete = true
                        else
                            messagesSent = messagesSent + 1
                            sentForPlayer = sentForPlayer + 1
                            local ok, sendError = pcall(deliver, job, player, command, payload)
                            if not ok then
                                failed = true
                                local target = "SP"
                                if not job.localDelivery then
                                    target = safeLogValue(job.username, LOG_VALUE_LIMIT)
                                end
                                logLine("push failed target=" .. target
                                    .. " kind=" .. tostring(job.kind)
                                    .. " error=" .. safeLogValue(sendError))
                            end
                        end
                    end
                    sentByPlayer[job.username] = sentForPlayer

                    if failed or complete then
                        state.jobs[key] = nil
                        state.queued[key] = nil
                    else
                        requeued[#requeued + 1] = key
                    end
                end
            end
        end
    end

    for index = 1, #carried do
        state.queue[#state.queue + 1] = carried[index]
    end
    for index = 1, #requeued do
        state.queue[#state.queue + 1] = requeued[index]
    end
end

-- SP 專用的初始語系。玩家在面板選過的語系存在 client 端的 settings.ini，開場就得吃它，
-- 否則「記憶選擇」只在 MP 成立：SP 的 NBClient 第一個 OnTick 就把 registerOnTick 移除，
-- 全場沒有任何人會把偏好送過來，面板選單勾著 JP、內容卻是遊戲語系。
-- 只會在 SP 被呼叫：onServerStarted 的 isServer() 分支已把 localLanguage 設為 nil，
-- dedicated server 走不到這裡（先前的註解宣稱這裡在防「dedicated server 沒有 NBClient」，
-- 那是不可達路徑，說法錯誤）。pcall 真正要防的是 SP 下的兩件事：載入順序讓 NBClient
-- 全域尚未出現，以及 getLanguagePreference 首次呼叫要讀 settings.ini 而讀檔可能拋錯。
-- 偏好為 auto 時會回 "auto"（不在 LANGS 白名單內）而落到下面的 Translator 路徑。
local function currentLocalLanguage()
    local preferenceOk, preference = pcall(function()
        return NBClient.getLanguagePreference()
    end)
    if not preferenceOk then
        -- 失敗與「玩家選了 auto」是兩件事，混在一起會讓「記憶選擇在 SP 失效」查不出原因。
        logLine("local language preference unavailable: "
            .. safeLogValue(preference, LOG_VALUE_LIMIT))
    end
    if preferenceOk and type(preference) == "string"
        and rawget(Core.LANGS, preference) == true then
        return preference
    end

    local ok, language = pcall(function()
        return Translator.getLanguage():name()
    end)
    if ok and type(language) == "string" and rawget(Core.LANGS, language) == true then
        return language
    end
    return NBServer.state.defaultLanguage
end

local function usernameOf(player)
    if not player then
        return ""
    end
    local username = player:getUsername()
    if type(username) ~= "string" then
        return tostring(username or "")
    end
    return username
end

local function usePushCooldown(username, command)
    local state = NBServer.state
    local now = getTimestampMs()
    local cooldown = rawget(state.cooldowns, username)
    if cooldown and now - cooldown.lastAt < REQUEST_COOLDOWN_MS then
        if command == "register" then
            cooldown.registerRepeats = cooldown.registerRepeats + 1
            if cooldown.registerRepeats == 5 then
                writeReconcile(
                    true,
                    "repeat-register username=" .. safeLogValue(username)
                        .. " count=" .. tostring(cooldown.registerRepeats)
                )
            end
        end
        return false
    end

    state.cooldowns[username] = {
        lastAt = now,
        registerRepeats = 0,
    }
    return true
end

-- 語系切換的獨立桶。形狀比照 handleImgReq 的 imgCooldownAt：O(1)、只記時戳，
-- 也不累加 registerRepeats——那是「同一個桶內重複送 register」的灌送偵測，
-- 而每一次語系切換都是玩家的新請求，掛在它名下會被誣賴成灌送。
local function useLanguageCooldown(username)
    local state = NBServer.state
    local now = getTimestampMs()
    local lastAt = rawget(state.langCooldownAt, username) or 0
    if lastAt ~= 0 and now - lastAt < LANGUAGE_COOLDOWN_MS then
        return false
    end
    state.langCooldownAt[username] = now
    return true
end

local function isAdmin(player)
    if not player then
        return false
    end
    local accessLevel = player:getAccessLevel()
    return type(accessLevel) == "string" and string.lower(accessLevel) == "admin"
end

-- client 送來的語系切換序號。信任邊界：非整數／超出上界一律當作「舊版 client 沒送」。
local function normalizeLanguageSeq(args)
    local value = type(args) == "table" and rawget(args, "lseq") or nil
    if type(value) ~= "number"
        or value ~= math.floor(value)
        or value < 0
        or value > Core.MAX_LANGUAGE_SEQ then
        return nil
    end
    return value
end

local function handleRegister(player, args)
    local state = NBServer.state
    local username = usernameOf(player)
    if username == "" then
        return
    end
    local language = type(args) == "table" and rawget(args, "lang") or nil
    if type(language) ~= "string" or rawget(Core.LANGS, language) ~= true then
        local now = getTimestampMs()
        local lastLog = rawget(state.rejectLogAt, username) or 0
        if now - lastLog >= REQUEST_COOLDOWN_MS then
            state.rejectLogAt[username] = now
            -- lang 完全由 client 決定且長度不受限：不截長就能每 10 秒灌一次超長值把 writeLog
            -- 撐到 10MB（整檔截斷非輪替）沖掉服主的排查紀錄。
            logLine("rejected register username=" .. safeLogValue(username, LOG_VALUE_LIMIT)
                .. " lang=" .. safeLogValue(language, LOG_VALUE_LIMIT))
        end
        return
    end

    local oldLanguage = rawget(state.registrations, username)
    local languageChanged = oldLanguage ~= nil and oldLanguage ~= language
    local seq = normalizeLanguageSeq(args)
    -- 這一包是不是「玩家換語系」的請求（或它的重送）：client 每次切換都會推進序號，
    -- 首次註冊與從未切換過的重送一律送 0（見 NBClient registerOnTick）。
    -- **不可以拿語系值去猜**：切換的第一包到達後 registrations 就已經是新語系，之後 client
    -- 每 3 秒的補送都長得像「同語系重送」，落回 10 秒桶就會被吞掉——而且白燒 client 的
    -- 送出額度（LANGUAGE_SWITCH_SEND_LIMIT）、還會累加 registerRepeats 把正常切換的玩家
    -- 記成灌送。舊版 client 不送序號 -> nil -> 照舊走 register 桶（行為與過去相同）。
    local switchRequest = seq ~= nil and seq >= 1
    state.registrations[username] = language
    state.online[username] = player
    state.langSeq[username] = seq
    if languageChanged then
        cancelJob(username)
    end

    -- 同一份切換請求已經在推送中就不要再排一次（理由見 contentJobInFlight）。
    -- 放在冷卻判斷之前：這只是 O(1) 表查詢，而被冷卻擋下的路徑會記 langPending，
    -- pumpLanguagePending 補推時也會撞上同一個判斷。
    if switchRequest and contentJobInFlight(username, language, seq) then
        state.langPending[username] = nil
        writeReconcile(false, nil)
        return
    end

    -- 換語系（含它的重送）走獨立短桶（LANGUAGE_COOLDOWN_MS=3s，與 client 鏡像同值）；
    -- 首次註冊與 retryRegister 的重送仍吃 register/resync 那個 10 秒桶，灌送防護不放寬。
    local allowed
    if switchRequest then
        allowed = useLanguageCooldown(username)
    else
        allowed = usePushCooldown(username, "register")
    end

    if allowed then
        -- 成功排入才算這次待推處理完；enqueueJob 在語系快取全空時會回 false，
        -- 先清 langPending 會把這次切換整個弄丟（register 路徑有 retryRegister 兜底，
        -- 但 langPending 是唯一能讓 server 自己補推的機制）。
        if enqueueJob(username, language, false) then
            state.langPending[username] = nil
        else
            state.langPending[username] = true
        end
    elseif switchRequest or languageChanged then
        -- 冷卻擋下切換請求時**不可以**只改註冊表就算了：飛行中的 job 可能剛被 cancelJob 砍掉、
        -- 新 job 沒排進去，而 refreshSnapshot 只推「內容有變的語系」，server 永遠不會自己補推。
        -- client 端送出即視為成功（pending 已清、registerLanguage 已樂觀寫成新值），再選同一個
        -- 語系會被當成 unchanged 直接吞掉 -> 玩家永久停在舊語系。改成記一筆待推，
        -- 由 pumpLanguagePending 在冷卻到期後補上（推送頻率仍受語系桶限制）。
        -- languageChanged 也要收：舊版 client 不送序號，它換語系一樣得補推。
        state.langPending[username] = true
    end
    writeReconcile(false, nil)
end

-- 冷卻期間被延後的語系變更，冷卻一到就補推。每秒跑一次（維護輪）。
-- 用的是語系桶（LANGUAGE_COOLDOWN_MS）：這裡補推的就是被那個桶擋下的那一次變更，
-- 換成 register 桶只會把玩家的等待拉回 10 秒。順帶也避開了 registerRepeats 的累加——
-- 本函式每秒重試一次，掛在 "register" 名下 5 秒就會誣賴玩家在灌 register。
local function pumpLanguagePending()
    local state = NBServer.state
    local username
    for username in pairs(state.langPending) do
        local language = rawget(state.registrations, username)
        if not language or not rawget(state.online, username) then
            state.langPending[username] = nil
        elseif contentJobInFlight(username, language, rawget(state.langSeq, username)) then
            -- 已經在推送中（多半是 client 的重送先到）。再排一次會讓它從 manifest 重頭開始，
            -- 理由見 contentJobInFlight；這一筆待推的目的已經達成，直接清掉。
            state.langPending[username] = nil
        elseif useLanguageCooldown(username) then
            -- 同 handleRegister：成功才清。失敗時留著，下一輪冷卻到期再試（失敗原因由
            -- enqueueJob 內的節流 log 呈現），否則這次語系切換會靜默遺失且無法自癒。
            if enqueueJob(username, language, false) then
                state.langPending[username] = nil
            end
        end
    end
end

local function handleResync(player, args)
    local state = NBServer.state
    local username = usernameOf(player)
    if username == "" then
        return
    end
    local language = rawget(state.registrations, username)
    if not language then
        -- 註冊表可能已被 rebuildOnlinePlayers 於玩家瞬間缺席時剔除；resync 帶著 lang，
        -- 此時當作重新註冊處理，避免「server 掉了註冊 → client 整場凍結」的不可自癒狀態。
        local candidate = type(args) == "table" and rawget(args, "lang") or nil
        if type(candidate) ~= "string" or rawget(Core.LANGS, candidate) ~= true then
            return
        end
        language = candidate
        state.registrations[username] = language
        state.online[username] = player
    end
    -- resync 也帶著序號：它是「把目前狀態重送給我」，回帶的必須是 client 現在等待的那一次
    -- 切換序號，否則重送回來的快照會被 client 判為不相符而永遠等下去。
    state.langSeq[username] = normalizeLanguageSeq(args)
    if usePushCooldown(username, "resync") then
        -- 與 handleRegister／pumpLanguagePending 對齊：resync 推的就是註冊語系的整包內容，
        -- 也就是 langPending 想推的那一份。不清掉的話 pumpLanguagePending 會在下一個冷卻視窗
        -- 把同樣的內容再送一次（一個語系上限 512KB ≒ 90 則訊息），而 client 端 pending 是空的
        -- 會全部丟棄——純浪費，還會佔掉該玩家約 12 個 tick 的推送額度。
        if enqueueJob(username, language, false) then
            state.langPending[username] = nil
        end
    end
end

local function handleReload(player)
    local state = NBServer.state
    local username = usernameOf(player)
    if not isAdmin(player) then
        local now = getTimestampMs()
        local key = "reload|" .. username
        local lastLog = rawget(state.rejectLogAt, key) or 0
        if now - lastLog >= REQUEST_COOLDOWN_MS then
            state.rejectLogAt[key] = now
            logLine("rejected reload username=" .. safeLogValue(username))
        end
        return
    end
    -- reload 需自己的冷卻鍵：若和 register/resync 共用 username 桶，玩家進場的 register 會先消耗冷卻，
    -- 10 秒內的 admin reload 被靜默丟棄卻仍顯示「已送出」（假成功）。用 reload| 前綴獨立節流。
    local now = getTimestampMs()
    local cooldownKey = "reload|" .. username
    local lastReload = rawget(state.reloadCooldownAt, cooldownKey) or 0
    if lastReload ~= 0 and now - lastReload < REQUEST_COOLDOWN_MS then
        return
    end
    state.reloadCooldownAt[cooldownKey] = now
    logLine("reload requested username=" .. safeLogValue(username))
    refreshSnapshot("reload", true)
    writeReconcile(false, nil)
end

-- imgreq：client 只要求「本機快取缺少的 hash」，並可帶一個**續傳起點**（args.from，
-- 與 hashes 平行的陣列）只要缺的那幾塊。防 DoS 的形狀與 resync 一致——
-- 獨立 per-player 冷卻桶（不與 register/resync 共用，避免進場的 register 吃掉冷卻造成靜默丟棄）、
-- 數量上限、且**只吃預先分塊好的快取**，絕不觸發重新讀檔或重新編碼。
local function handleImgReq(player, args)
    local state = NBServer.state
    local localRequest = not isServer()
    local username
    if localRequest then
        username = LOCAL_JOB_KEY
    else
        username = usernameOf(player)
        if username == "" or rawget(state.registrations, username) == nil then
            return
        end
    end

    local hashes = type(args) == "table" and rawget(args, "hashes") or nil
    if type(hashes) ~= "table" then
        return
    end
    -- 續傳起點（與 hashes 平行的陣列，from[i] 對應 hashes[i]）。舊版 client 不送這個欄位，
    -- 缺值／不合法一律當 1＝從頭送，也就是續傳之前的行為。
    local froms = rawget(args, "from")
    if type(froms) ~= "table" then
        froms = nil
    end

    -- 冷卻與輸入上限都必須在掃描**之前**：舊版先掃完整份 hashes 才檢查冷卻，而且沒有比對到
    -- 任何一張時連冷卻時戳都不寫，於是「每 tick 送幾萬個假 hash」可以在 OnClientCommand
    -- 的同步路徑上無限跑 string.match。比照 handleResync：先做 O(1) 的冷卻判斷再做事。
    local now = getTimestampMs()
    local lastAt = rawget(state.imgCooldownAt, username) or 0
    if lastAt ~= 0 and now - lastAt < REQUEST_COOLDOWN_MS then
        return
    end
    state.imgCooldownAt[username] = now

    -- 掃描量的上界＝這台伺服器可能存在的圖片張數（服主政策）。client 正常一次只要 4 個 hash，
    -- 這個夾限是擋惡意 client 送幾萬個假 hash 在主執行緒上跑 string.match。
    local scanLimit = #hashes
    local maxCount = Image.maxImageCount()
    if scanLimit > maxCount then
        scanLimit = maxCount
    end

    local entries = {}
    local seen = {}
    local chunkCount = 0
    local index
    for index = 1, scanLimit do
        local hash = hashes[index]
        if Image.isHash(hash) and not rawget(seen, hash) then
            seen[hash] = true
            local entry = rawget(state.imageByHash, hash)
            if entry then
                -- 起點是信任邊界：整數、落在 [1, entry.n] 才採用。夾在上界之內就不可能
                -- 讓 nextJobMessage 去取一個不存在的 chunks[i]；不合法就當 1（送整張），
                -- 亦即壞掉的 from 只會多送、不會少送或炸掉。
                local from = 1
                if froms then
                    local requested = tonumber(rawget(froms, index))
                    if requested and requested == math.floor(requested)
                        and requested >= 1 and requested <= entry.n then
                        from = requested
                    end
                end
                entries[#entries + 1] = { entry = entry, from = from }
                chunkCount = chunkCount + (entry.n - from + 1)
            end
        end
    end
    if #entries == 0 then
        return
    end

    enqueueImageJob(username, entries, localRequest)
    logLine("imgreq user=" .. (localRequest and "SP" or safeLogValue(username))
        .. " images=" .. tostring(#entries)
        .. " chunks=" .. tostring(chunkCount))
end

-- SP 專用：面板換語系。MP 走 register（有 per-player 冷卻），SP 沒有網路層也沒有信任邊界
-- ——發動者就是伺服器本人，冷卻是用來擋遠端 client 的，這裡套上去只會讓自己的選單卡住。
local function handleLocalLanguage(args)
    local state = NBServer.state
    if isServer() then
        return
    end
    local language = type(args) == "table" and rawget(args, "lang") or nil
    if type(language) ~= "string" or rawget(Core.LANGS, language) ~= true then
        return
    end
    -- 語系相同也要重推一份：client 的 languageSwitchArmed 只有在收到快照時才會被
    -- consumeLanguageSwitch 吃掉（applySnapshot），這裡靜默 return 會讓 armed 一路留著，
    -- 把之後某一次「公告真的更新了」的提示無聲吃掉。SP 的 setlang 只由選單點擊觸發，
    -- 且 client 端 setLanguagePreference 對相同語系會早退，最多只多推一次。
    state.localLanguage = language
    -- SP 也要帶序號：client 端的完成判定（applySnapshot）兩種模式共用同一條路徑，
    -- 少了序號 SP 就會退回語系值比對，EN->JP->EN 的誤判在 SP 一樣會發生。
    state.langSeq[LOCAL_JOB_KEY] = normalizeLanguageSeq(args)
    enqueueJob(LOCAL_JOB_KEY, language, true, false)
end

function NBServer.onClientCommand(module, command, player, args)
    if module ~= NBServer.MODULE then
        return
    end
    if command == "register" then
        handleRegister(player, args)
    elseif command == "reload" then
        handleReload(player)
    elseif command == "resync" then
        handleResync(player, args)
    elseif command == "imgreq" then
        handleImgReq(player, args)
    end
end

function NBServer.refresh(reason, forceAll)
    return refreshSnapshot(reason or "manual", forceAll == true)
end

function NBServer.onServerStarted()
    local state = NBServer.state
    -- state.started 一律最後才設 true。曾經踩過：這行放在最前面時，中途任何例外都會讓
    -- 初始化中斷（bootstrap 與 startup 掃描沒跑、sid 是 nil），但輪詢因 started=true 照常運作，
    -- 於是持續推送 sid=nil 的 manifest，client 只看得到「同步逾時」，根因完全被掩蓋。
    state.started = false
    state.defaultLanguage = validateDefaultLanguage(true)

    -- sid 取得失敗不可致命：拿不到就用一次性 fallback，讓協定仍有合法 sid（只是已讀狀態不跨重啟）
    local sidOk, sid = pcall(loadOrCreateServerId)
    if not sidOk or not validServerId(sid) then
        if not sidOk then
            logLine("server id generation failed: " .. safeLogValue(sid))
        end
        sid = Core.djb2Hex("fallback:" .. tostring(getTimestampMs()))
        sid = sid .. sid .. sid .. sid
        logLine("using volatile fallback server id; read state will not persist across restarts")
    end
    state.sid = sid
    state.registrations = {}
    state.online = {}
    state.cooldowns = {}
    state.langPending = {}
    state.langSeq = {}
    state.jobs = {}
    state.queued = {}
    state.queue = {}
    state.rejectLogAt = {}
    state.reloadCooldownAt = {}
    state.imgCooldownAt = {}
    state.lastReconcileSignature = nil
    state.availableLanguages = {}
    state.languagesSignature = nil
    closeImageJob(state.imageJob)
    state.imageJob = nil
    state.imageQueue = {}
    state.imageEntries = {}
    state.imageByHash = {}
    state.imageManifest = {}
    state.imageSignature = nil
    state.imageTotalBytes = 0
    state.imageIssues = {}
    state.imageIssueSignature = nil
    state.imageIssuesDirty = false
    state.imageDirty = false
    state.imageProbeCursor = nil

    if isServer() then
        state.localLanguage = nil
    else
        state.localLanguage = currentLocalLanguage()
    end

    bootstrapIfEmpty()
    ensureImagesReadme()
    refreshSnapshot("startup", true)
    state.lastPollMs = getTimestampMs()
    rebuildOnlinePlayers()
    -- 全部初始化成功才開啟輪詢；中途拋錯則 started 維持 false，寧可完全不運作也不要
    -- 帶著半套狀態推送（見本函式開頭註解）。
    state.started = true
    writeReconcile(false, nil)
end

function NBServer.onGameStart()
    if not isServer() and not isClient() and not NBServer.state.started then
        NBServer.onServerStarted()
    end
end

function NBServer.onTickEvenPaused()
    local state = NBServer.state
    if not state.started then
        return
    end

    local now = getTimestampMs()
    -- getOnlinePlayers() 每次 new 一個 ArrayList＋掃全連線，writeReconcile 另組 table/sort/signature。
    -- 這些是 registration 清理與對帳，1s 一次已足夠；processQueue 才需要每 tick 跑（批次投遞泵）。
    if now - (state.lastMaintenanceMs or 0) >= MAINTENANCE_INTERVAL_MS then
        state.lastMaintenanceMs = now
        rebuildOnlinePlayers()
        pumpLanguagePending()
        writeReconcile(false, nil)
    end
    if now - state.lastPollMs >= pollIntervalMs() then
        state.lastPollMs = now
        refreshSnapshot("poll", false)
    end
    local pumpOk, pumpResult = pcall(pumpImageEncode)
    if not pumpOk then
        logLine("image pump failed: " .. safeLogValue(pumpResult))
    elseif pumpResult then
        publishImageManifest()
    end
    processQueue()
end

function NBServer.getState()
    return NBServer.state
end

-- 投遞泵的一個 tick。對外暴露只為了讓 scripts/test_mdparser.lua 能直接實跑限流契約
-- （4 人／32 則／單人 8 則都是每 tick，光讀碼保證不了）；正式路徑仍由 onTickEvenPaused 呼叫。
NBServer.processQueue = processQueue

-- 同上：讓測試能直接實跑「原地覆蓋偵測」的判定（大小比對、正在編碼中的檔名要跳過、
-- 開檔失敗不得丟 entry、移除後總量重算），這些光讀碼保證不了。
NBServer.scanImages = scanImages
NBServer.ensureImagesReadme = ensureImagesReadme
-- 同上：唯有實跑一次完整編碼才能釘住 entry.pb（原地覆蓋比對的基準）確實來自
-- 開檔時的 available()，而不是實際讀到的位元組數——兩者在 short-read 時會分岔。
NBServer.pumpImageEncode = pumpImageEncode

if not NBServer._eventsInstalled then
    Events.OnServerStarted.Add(function()
        NBServer.onServerStarted()
    end)
    Events.OnGameStart.Add(function()
        NBServer.onGameStart()
    end)
    Events.OnTickEvenPaused.Add(function()
        NBServer.onTickEvenPaused()
    end)
    Events.OnClientCommand.Add(function(module, command, player, args)
        NBServer.onClientCommand(module, command, player, args)
    end)
    -- SP 專用的本地請求管道。只收 imgreq 與 setlang：register/resync/reload 在 SP 沒有意義
    -- （沒有 player 物件、內容本來就由 server 端主動投遞），放行它們只會產生 username 為空的拒絕 log。
    Events[Reader.LOCAL_CMD_EVENT].Add(function(module, command, args)
        if module ~= NBServer.MODULE then
            return
        end
        if command == "imgreq" then
            handleImgReq(nil, args)
        elseif command == "setlang" then
            handleLocalLanguage(args)
        end
    end)
    NBServer._eventsInstalled = true
end

return NBServer
