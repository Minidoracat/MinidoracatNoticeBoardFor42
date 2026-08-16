if not NBCore then
    require "NoticeBoard/NBCore"
end
if not NBImage then
    require "NoticeBoard/NBImage"
end

local Core = NBCore
local Image = NBImage
if not Core or not Image then
    error("NoticeBoard/NBCore failed to load")
end

NBReader = NBReader or {}

NBReader.MODULE = "MinidoracatNB"
NBReader.LOCAL_EVENT = "MinidoracatNB_Local"
-- SP 沒有網路層，client 端的請求（imgreq）靠這個本地事件投遞到同一 VM 的 NBServer。
NBReader.LOCAL_CMD_EVENT = "MinidoracatNB_LocalCmd"
NBReader.NOTICE_ROOT = "NoticeBoard"
NBReader.MAX_FILE_BYTES = 200 * 1024
NBReader.MAX_LANGUAGE_BYTES = 512 * 1024
-- 接收端把 producer 上限當成契約強制：惡意 server 不得靠海量檔案/巨大欄位耗盡 client 記憶體，
-- 也不得靠海量 manifest 條目把單包撐過 1MB（UdpConnection buffer）觸發 BufferOverflow。
NBReader.MAX_MANIFEST_FILES = 200
NBReader.MAX_ID_UTF16 = 128

local FILE_SEPARATOR = getFileSeparator()
-- 環境偵測必須用純 ASCII：非 ASCII 字面值在 Kahlua 會被截成單位元組（先前靠 "é" 恰好
-- 得到正確答案純屬僥倖）。改用 PZ 全域函式是否存在來判斷：PZ/Kahlua 的字串索引是
-- UTF-16 code unit，標準 Lua（測試環境）則是 UTF-8 byte。
local STRINGS_USE_UTF8_BYTES = type(getTimestampMs) ~= "function"

local function isInteger(value)
    return type(value) == "number" and value == math.floor(value)
end

local function trim(text)
    text = string.gsub(text, "^%s+", "")
    return string.gsub(text, "%s+$", "")
end

local function languageCodes()
    local result = {}
    local language
    for language, enabled in pairs(Core.LANGS) do
        if enabled then
            result[#result + 1] = language
        end
    end
    Core.sortSafe(result)
    return result
end

local function isSupportedLanguage(language)
    return type(language) == "string" and rawget(Core.LANGS, language) == true
end

local function isNoticeFile(fileName)
    if type(fileName) ~= "string" then
        return false
    end
    local extension = string.match(fileName, "%.([^%.]+)$")
    if not extension then
        return false
    end
    extension = string.lower(extension)
    return extension == "md" or extension == "txt"
end

local function numericPrefix(fileName)
    local prefix = string.match(fileName, "^(%d+)")
    if prefix then
        return tonumber(prefix)
    end
    return 2147483647
end

local function fileNameLess(left, right)
    local leftPrefix = numericPrefix(left)
    local rightPrefix = numericPrefix(right)
    if leftPrefix ~= rightPrefix then
        return leftPrefix < rightPrefix
    end

    local leftLower = string.lower(left)
    local rightLower = string.lower(right)
    if leftLower ~= rightLower then
        return leftLower < rightLower
    end
    return left < right
end

local function entryLess(left, right)
    return fileNameLess(left.id, right.id)
end

local function languageDirectory(language)
    return NBReader.NOTICE_ROOT .. FILE_SEPARATOR .. language
end

local function noticePath(language, fileName)
    return languageDirectory(language) .. FILE_SEPARATOR .. fileName
end

local function closeReader(reader)
    if reader then
        pcall(function()
            reader:close()
        end)
    end
end

local function readNoticeFile(language, fileName)
    local reader = nil
    local ok, result = pcall(function()
        reader = getFileReader(noticePath(language, fileName), false)
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
        return table.concat(lines, "\n")
    end)

    closeReader(reader)
    if not ok then
        return nil, tostring(result)
    end
    if result == nil then
        return nil, "file not found"
    end
    return result, nil
end

local function listLanguageFileNames(language)
    local ok, files = pcall(function()
        return listFilesInZomboidLuaDirectory(languageDirectory(language))
    end)
    if not ok then
        return nil, tostring(files)
    end
    if not files then
        return {}, nil
    end

    local result = {}
    local index
    for index = 0, files:size() - 1 do
        local fileName = files:get(index)
        if isNoticeFile(fileName) then
            result[#result + 1] = fileName
        end
    end
    Core.sortSafe(result, fileNameLess)
    return result, nil
end

-- title 進 manifest 單一字串欄位；不設上限則超長單行標題可讓 putUTF 32767 bytes
-- 溢位路徑經 title 重新可達（GameWindow.java:1263-1277）。200 UTF-16 units 上限封死。
local TITLE_UTF16_LIMIT = 200

local function truncateTitle(title)
    if string.len(title) <= TITLE_UTF16_LIMIT then
        return title
    end
    local endIndex = TITLE_UTF16_LIMIT
    local lastUnit = string.byte(title, endIndex)
    local nextUnit = string.byte(title, endIndex + 1)
    if lastUnit and nextUnit
        and lastUnit >= 55296 and lastUnit <= 56319
        and nextUnit >= 56320 and nextUnit <= 57343 then
        endIndex = endIndex - 1
    end
    return string.sub(title, 1, endIndex)
end

-- 標題行的圖片標記不能原樣當頁籤名稱：`#` 標題現在明確支援放圖片（見 ADMIN_GUIDE
-- 「顯示與排錯」），而第一個 H1 同時是頁籤名稱與新內容 toast 的內容，路徑會整串露出來，
-- 頁籤寬度又是 MeasureStringX(title)+28 算的（NBPanel.lua:1216），一條路徑就把頁籤撐爆。
-- markdown 的 `![替代文字](路徑)` 留下替代文字（那正是「這張圖在說什麼」）；原生
-- `<IMAGE:>` / `<IMAGECENTRE:>` 沒有替代文字可留，整段拿掉。
-- 只處理圖片：`**粗體**`／`` `程式碼` ``／`[連結](url)` 的記號留著仍讀得出標題文字，
-- 而且要剝乾淨就得把 MDParser 的行內解析整套搬進 NBReader（server 端也跑），不划算。
local function stripImageMarkup(title)
    title = string.gsub(title, "!%[([^%]]-)%]%(([^%)]-)%)", "%1")
    title = string.gsub(title, "<IMAGECENTRE:[^>]->", "")
    return (string.gsub(title, "<IMAGE:[^>]->", ""))
end

local function extractTitle(content, fileName)
    local position = 1
    while position <= string.len(content) do
        local lineEnd = string.find(content, "\n", position, true)
        local line
        if lineEnd then
            line = string.sub(content, position, lineEnd - 1)
            position = lineEnd + 1
        else
            line = string.sub(content, position)
            position = string.len(content) + 1
        end

        local title = string.match(line, "^%s*#%s+(.+)$")
        if title then
            title = trim(stripImageMarkup(title))
            if title ~= "" then
                return truncateTitle(title)
            end
        end
    end
    return fileName
end

-- Kahlua 的 string index 是 UTF-16 code unit；一般 Lua 則是 UTF-8 byte。
-- 限制以實際 UTF-8 編碼大小計算，避免 CJK 內容低估網路負載。
function NBReader.utf8ByteLength(text)
    if type(text) ~= "string" then
        error("text must be a string")
    end
    if STRINGS_USE_UTF8_BYTES then
        return string.len(text)
    end

    local bytes = 0
    local index = 1
    local length = string.len(text)
    while index <= length do
        local unit = string.byte(text, index)
        if unit <= 127 then
            bytes = bytes + 1
        elseif unit <= 2047 then
            bytes = bytes + 2
        elseif unit >= 55296 and unit <= 56319 and index < length then
            local nextUnit = string.byte(text, index + 1)
            if nextUnit >= 56320 and nextUnit <= 57343 then
                bytes = bytes + 4
                index = index + 1
            else
                bytes = bytes + 3
            end
        else
            bytes = bytes + 3
        end
        index = index + 1
    end
    return bytes
end

function NBReader.getLanguageCodes()
    return languageCodes()
end

function NBReader.isNoticeFile(fileName)
    return isNoticeFile(fileName)
end

function NBReader.listLanguageFiles(language)
    if not isSupportedLanguage(language) then
        return nil, "unsupported language"
    end
    return listLanguageFileNames(language)
end

function NBReader.hasAnyNoticeFiles()
    local languages = languageCodes()
    local index
    for index = 1, #languages do
        local files, readError = listLanguageFileNames(languages[index])
        if not files then
            return nil, readError
        end
        if #files > 0 then
            return true, nil
        end
    end
    return false, nil
end

function NBReader.scanLanguage(language, previous)
    if not isSupportedLanguage(language) then
        error("unsupported language: " .. tostring(language))
    end

    previous = previous or { byId = {} }
    local previousById = previous.byId or {}
    local result = {
        language = language,
        files = {},
        byId = {},
        issues = {},
    }

    local fileNames, listError = listLanguageFileNames(language)
    if not fileNames then
        result.issues[#result.issues + 1] = {
            kind = "list",
            language = language,
            detail = listError,
        }
        local previousIndex
        for previousIndex = 1, #(previous.files or {}) do
            local previousEntry = previous.files[previousIndex]
            result.files[#result.files + 1] = previousEntry
            result.byId[previousEntry.id] = previousEntry
        end
        return result
    end

    local index
    for index = 1, #fileNames do
        local fileName = fileNames[index]
        -- producer 必須套用與 receiver validateDescriptor 相同的 id 契約：否則超長或含 | = 控制字元
        -- 的合法檔名進了 manifest，接收端會拒絕整份 manifest → 公告永遠無法發布。跳過並記錄給服主。
        if string.len(fileName) > NBReader.MAX_ID_UTF16
            or string.find(fileName, "[%c|=]") ~= nil then
            result.issues[#result.issues + 1] = {
                kind = "invalid-id",
                language = language,
                id = fileName,
            }
        else
        local previousEntry = rawget(previousById, fileName)
        local content, readError = readNoticeFile(language, fileName)
        if content == nil then
            result.issues[#result.issues + 1] = {
                kind = "read",
                language = language,
                id = fileName,
                detail = readError,
            }
            if previousEntry then
                result.files[#result.files + 1] = previousEntry
                result.byId[fileName] = previousEntry
            end
        else
            local byteLength = NBReader.utf8ByteLength(content)
            if byteLength > NBReader.MAX_FILE_BYTES then
                result.issues[#result.issues + 1] = {
                    kind = "oversize",
                    language = language,
                    id = fileName,
                    bytes = byteLength,
                }
            else
                local hash = Core.djb2Hex(content)
                local entry
                if previousEntry and previousEntry.h == hash then
                    entry = previousEntry
                else
                    local ok, chunks = pcall(Core.chunkText, content)
                    if ok then
                        entry = {
                            id = fileName,
                            language = language,
                            title = extractTitle(content, fileName),
                            content = content,
                            bytes = byteLength,
                            h = hash,
                            chunks = chunks,
                            n = #chunks,
                        }
                    else
                        result.issues[#result.issues + 1] = {
                            kind = "process",
                            language = language,
                            id = fileName,
                            detail = tostring(chunks),
                        }
                        entry = previousEntry
                    end
                end

                if entry then
                    result.files[#result.files + 1] = entry
                    result.byId[fileName] = entry
                end
            end
        end
        end
    end

    Core.sortSafe(result.files, entryLess)
    return result
end

function NBReader.scanAll(previous)
    previous = previous or {}
    local result = {
        languages = {},
        issues = {},
    }
    local languages = languageCodes()
    local index
    for index = 1, #languages do
        local language = languages[index]
        local scanned = NBReader.scanLanguage(language, rawget(previous, language))
        result.languages[language] = scanned
        local issueIndex
        for issueIndex = 1, #scanned.issues do
            result.issues[#result.issues + 1] = scanned.issues[issueIndex]
        end
    end
    return result
end

local function addEntries(target, source)
    if not source then
        return
    end
    local index
    for index = 1, #source.files do
        local entry = source.files[index]
        target[entry.id] = entry
    end
end

function NBReader.composeLanguage(scannedLanguages, language, defaultLanguage)
    if not isSupportedLanguage(language) then
        error("unsupported language: " .. tostring(language))
    end
    if not isSupportedLanguage(defaultLanguage) then
        error("unsupported default language: " .. tostring(defaultLanguage))
    end

    local selected = {}
    addEntries(selected, rawget(scannedLanguages, defaultLanguage))
    if language ~= defaultLanguage then
        addEntries(selected, rawget(scannedLanguages, language))
    end

    local files = {}
    local _, entry
    for _, entry in pairs(selected) do
        files[#files + 1] = entry
    end
    Core.sortSafe(files, entryLess)

    local totalBytes = 0
    local index
    for index = 1, #files do
        totalBytes = totalBytes + files[index].bytes
    end

    -- 兩道閘：總 byte 上限，加上檔案數上限。後者結構性封死「大量小檔」把 manifest 單包
    -- 撐過 1MB（每條 ~900 bytes × MAX_MANIFEST_FILES）觸發 BufferOverflow → bufferLock 洩漏。
    local trimmed = {}
    while (totalBytes > NBReader.MAX_LANGUAGE_BYTES or #files > NBReader.MAX_MANIFEST_FILES)
        and #files > 0 do
        local removed = table.remove(files)
        totalBytes = totalBytes - removed.bytes
        trimmed[#trimmed + 1] = removed.id
    end

    local byId = {}
    local manifestFiles = {}
    for index = 1, #files do
        entry = files[index]
        byId[entry.id] = entry
        manifestFiles[index] = {
            id = entry.id,
            title = entry.title,
            n = entry.n,
            h = entry.h,
        }
    end

    return {
        language = language,
        files = files,
        byId = byId,
        manifestFiles = manifestFiles,
        totalBytes = totalBytes,
        trimmed = trimmed,
    }
end

function NBReader.languageCachesEqual(left, right)
    if left == right then
        return true
    end
    if not left or not right or #left.files ~= #right.files then
        return false
    end

    local index
    for index = 1, #left.files do
        local leftEntry = left.files[index]
        local rightEntry = right.files[index]
        if leftEntry.id ~= rightEntry.id
            or leftEntry.h ~= rightEntry.h
            or leftEntry.n ~= rightEntry.n then
            return false
        end
    end
    return true
end

local function newReceiverState()
    return {
        v = -1,
        sid = nil,
        manifest = nil,
        files = {},
        pending = {},
        snapshot = nil,
        needsResync = false,
        lastError = nil,
        -- 伺服器實際有內容的語系（面板語系選單用）。舊版 server 不送這個欄位 -> 空清單，
        -- 選單只剩「自動」，公告文字與圖片完全不受影響。
        languages = {},
        -- 這份內容本身是哪個語系。舊版 server 送 nil；只在沒有 lseq 時當作退化判定依據。
        language = nil,
        -- 這份內容對應到 client 的哪一次語系切換請求（client 送出、server 原樣回帶）。
        -- NBClient 用它判定「換語系真的完成了」——語系值比對在 EN->JP->EN 來回時會誤判。
        lseq = nil,
        images = {},
        -- 圖片清單的變更偵測用簽章。用字串而非 table identity：同一份 manifest 重送
        -- （register 冷卻期後的重推）會產生新 table，identity 比對會誤判成「圖片變了」
        -- 而觸發整輪快取重驗。
        imagesSignature = "",
    }
end

NBReader.receiver = NBReader.receiver or newReceiverState()

local function receiverError(message)
    local receiver = NBReader.receiver
    receiver.needsResync = true
    -- message 可能含 server 可控字串（id 等）→ 消毒後才寫 log，防 log injection。
    receiver.lastError = Core.sanitizeName(message)
    print("[MinidoracatNoticeBoardFor42] receiver error: " .. receiver.lastError)
end

local function validateDescriptor(descriptor)
    if type(descriptor) ~= "table" then
        return false
    end
    local id = rawget(descriptor, "id")
    local title = rawget(descriptor, "title")
    local count = rawget(descriptor, "n")
    local hash = rawget(descriptor, "h")
    -- 單檔最多這麼多分塊；上界封死惡意 server 用 n=2^31 誘導巨大 parts 表。
    local maxChunks = math.floor(NBReader.MAX_FILE_BYTES / Core.CHUNK_UTF16_LIMIT) + 2
    return type(id) == "string"
        and id ~= ""
        and string.len(id) <= NBReader.MAX_ID_UTF16
        -- id 會成為 ReadState ini 的鍵（sidHash|id=hash 行格式）；含控制字元或 | = 的 id
        -- 可偽造成別的 sidHash 條目汙染跨伺服器已讀狀態，故在信任邊界一次擋掉。
        and string.find(id, "[%c|=]") == nil
        -- title 同樣要有上限：它是唯一會進 UI 渲染與 toast 的可變長字串，
        -- 沒有上限則惡意 server 可送 ~32K 字元 title 拖垮 client（與 producer 端 TITLE_UTF16_LIMIT 對齊）。
        and type(title) == "string"
        and string.len(title) <= TITLE_UTF16_LIMIT
        and isInteger(count)
        and count >= 1
        and count <= maxChunks
        and type(hash) == "string"
        and string.match(hash, "^%x%x%x%x%x%x%x%x$") ~= nil
end

-- 圖片描述子同樣是信任邊界：惡意／損壞的 server 不得靠超大 n 或 b 誘導 client 配置
-- 巨大表格或永遠等不到的重組狀態。上界一律取 producer 端的同一組常數。
local function validateImageDescriptor(descriptor)
    if type(descriptor) ~= "table" then
        return false
    end
    local name = rawget(descriptor, "name")
    local hash = rawget(descriptor, "h")
    local count = rawget(descriptor, "n")
    local bytes = rawget(descriptor, "b")
    -- 用 Sandbox 解析後的上限，不能用預設常數：服主調高後 server 會送出更大的圖，
    -- 這裡若仍拿 512KB 比對就會把整份圖片清單判為無效。
    -- 但**宣告值不可全信**：MP 下 sandbox 是 server 推給 client 的，所以再夾一次客戶端
    -- 硬天花板（寫死常數，不讀 sandbox）。天花板 == 沙盒選項的合法上界，對誠實伺服器
    -- 是 no-op；它把「接收端不信任任何宣告值」寫成結構，而不是仰賴 accessor 順手驗證。
    local maxImageBytes = Image.maxImageBytes()
    local byteCeiling = Image.MAX_IMAGE_KB * 1024
    if maxImageBytes > byteCeiling then
        maxImageBytes = byteCeiling
    end
    if not (Image.isValidName(name)
        and Image.isHash(hash)
        and isInteger(bytes)
        and bytes >= 0
        and bytes <= maxImageBytes) then
        return false
    end
    -- n 的上界必須由**這一筆自己的 b** 推，不能拿全域的單張上限推：客戶端是先把分塊
    -- 全部收齊才比對長度（NBImageCache.receiveChunk），所以「b=1 但 n=934」這種宣告
    -- 會在長度檢查之前就先讓 client 緩衝 n * CHUNK_UTF16_LIMIT 個字元。
    -- producer 端 n 恆等於 max(1, ceil(encodedLength(b) / CHUNK_UTF16_LIMIT))
    -- （NBImage.pushChunks 每滿 limit 切一塊、flushChunks 收尾，空輸入也留一塊），
    -- 這裡取上界比對而非等號：誠實伺服器一律通過，宣告值再也撐不出額外的緩衝區。
    local maxChunks = math.ceil(Image.encodedLength(bytes) / Core.CHUNK_UTF16_LIMIT)
    if maxChunks < 1 then
        maxChunks = 1
    end
    return isInteger(count)
        and count >= 1
        and count <= maxChunks
end

local function normalizeImages(rawImages)
    if rawImages == nil then
        return {}, nil, ""
    end
    if type(rawImages) ~= "table" then
        return nil, "images is not a table", nil
    end
    -- 同 validateImageDescriptor：吃服主宣告的張數，但一律再夾客戶端硬天花板。
    local maxCount = Image.maxImageCount()
    if maxCount > Image.MAX_IMAGE_COUNT_LIMIT then
        maxCount = Image.MAX_IMAGE_COUNT_LIMIT
    end
    if #rawImages > maxCount then
        return nil, "too many images: " .. tostring(#rawImages), nil
    end
    -- 總量同樣要夾：張數與單張大小各自合法，乘起來仍可以是 200 * 4MB = 800MB。
    -- 那正是 client 要在記憶體裡緩衝的量（NBImageCache 的 pending／writeQueue 都沒有
    -- 併發張數上限，而 WRITE_WINDOW_BYTES 是在 payload 組完之後才擋，保護的是硬碟
    -- 不是 RAM）。producer 端本來就有同一道總量閘（NBServer.startNextImageJob 的
    -- img-total），所以這條對誠實伺服器是 no-op。
    local maxTotal = Image.maxTotalBytes()
    local totalCeiling = Image.MAX_TOTAL_KB * 1024
    if maxTotal > totalCeiling then
        maxTotal = totalCeiling
    end

    local normalized = {}
    local signatureParts = {}
    local seen = {}
    local totalBytes = 0
    local index
    for index = 1, #rawImages do
        local descriptor = rawImages[index]
        if not validateImageDescriptor(descriptor) then
            return nil, "invalid image descriptor at index " .. tostring(index), nil
        end
        totalBytes = totalBytes + rawget(descriptor, "b")
        if totalBytes > maxTotal then
            return nil, "images exceed total bytes: " .. tostring(totalBytes), nil
        end
        local name = rawget(descriptor, "name")
        local lowered = string.lower(name)
        if rawget(seen, lowered) then
            return nil, "duplicate image name: " .. name, nil
        end
        seen[lowered] = true
        normalized[index] = {
            name = name,
            h = rawget(descriptor, "h"),
            n = rawget(descriptor, "n"),
            b = rawget(descriptor, "b"),
        }
        signatureParts[index] = lowered .. ":" .. normalized[index].h
    end
    return normalized, nil, table.concat(signatureParts, "|")
end

local function publishSnapshotIfComplete()
    local receiver = NBReader.receiver
    if not receiver.manifest then
        return false
    end

    local descriptors = receiver.manifest.files
    local snapshotFiles = {}
    local index
    for index = 1, #descriptors do
        local descriptor = descriptors[index]
        local complete = rawget(receiver.files, descriptor.id)
        if not complete or complete.h ~= descriptor.h then
            return false
        end
        snapshotFiles[index] = {
            id = descriptor.id,
            title = descriptor.title,
            h = descriptor.h,
            content = complete.content,
        }
    end

    receiver.snapshot = {
        v = receiver.v,
        sid = receiver.sid,
        -- 這份快照的語系。舊版 server 為 nil（此時 NBClient 退回語系值比對）。
        lang = receiver.language,
        -- 對應的語系切換請求序號。這是 NBClient 判定切換完成的權威依據，舊版 server 為 nil。
        lseq = receiver.lseq,
        files = snapshotFiles,
    }
    receiver.needsResync = false
    receiver.lastError = nil

    if type(NBReader.onSnapshot) == "function" then
        local ok, callbackError = pcall(NBReader.onSnapshot, receiver.snapshot)
        if not ok then
            receiverError(callbackError)
        end
    end
    return true
end

local function receiveManifest(args)
    if type(args) ~= "table" then
        receiverError("manifest payload is not a table")
        return
    end

    local version = rawget(args, "v")
    local sid = rawget(args, "sid")
    local descriptors = rawget(args, "files")
    -- 逐欄回報：只說「invalid manifest header」會讓服主完全無從判斷是版本、sid 還是檔案清單壞掉。
    if not isInteger(version) or version < 0 then
        receiverError("invalid manifest header: v=" .. tostring(version))
        return
    end
    if type(sid) ~= "string" or sid == "" then
        receiverError("invalid manifest header: sid=" .. tostring(sid)
            .. " (server-side server id init failed)")
        return
    end
    if type(descriptors) ~= "table" then
        receiverError("invalid manifest header: files=" .. tostring(descriptors))
        return
    end
    if #descriptors > NBReader.MAX_MANIFEST_FILES then
        receiverError("manifest too large: " .. tostring(#descriptors) .. " files")
        return
    end

    local images, imageError, imagesSignature = normalizeImages(rawget(args, "images"))
    if not images then
        -- 圖片清單有問題不得拖垮公告文字：降級成「這份 manifest 沒有圖片」後照常發佈快照。
        -- 走 receiverError 會 return 在快照發佈之前並設 needsResync，於是一個純圖片問題
        -- （例如 case-insensitive 撞名）會讓 client 永遠停在「同步逾時」，連文字都看不到。
        -- 與 imgchunk handler 的錯誤處理同一政策：圖片端錯誤只寫 log。
        print("[MinidoracatNoticeBoardFor42] manifest images ignored: "
            .. Core.sanitizeName(tostring(imageError)))
        images = {}
        imagesSignature = ""
    end

    -- 語系清單與 images 同一政策：它只影響選單，壞掉不得拖垮公告文字。
    local languages, languagesError = Core.normalizeLanguageList(rawget(args, "langs") or {})
    if not languages then
        print("[MinidoracatNoticeBoardFor42] manifest languages ignored: "
            .. Core.sanitizeName(tostring(languagesError)))
        languages = {}
    end

    -- 這份內容的語系（白名單外一律當作沒送）。同樣只影響 client 的切換確認，不擋公告文字。
    local contentLanguage = rawget(args, "lang")
    if type(contentLanguage) ~= "string" or rawget(Core.LANGS, contentLanguage) ~= true then
        contentLanguage = nil
    end

    -- 語系切換序號。它是 client 自己送出去、由 server 原樣回帶的值，仍是信任邊界：
    -- 範圍外／非整數一律當作「舊版 server 沒送」（nil），讓 NBClient 退回語系值比對。
    local contentSeq = rawget(args, "lseq")
    if not isInteger(contentSeq) or contentSeq < 0 or contentSeq > Core.MAX_LANGUAGE_SEQ then
        contentSeq = nil
    end

    local receiver = NBReader.receiver
    if receiver.sid == sid and version < receiver.v then
        return
    end

    local seen = {}
    local normalized = {}
    local index
    for index = 1, #descriptors do
        local descriptor = descriptors[index]
        if not validateDescriptor(descriptor) then
            receiverError("invalid manifest descriptor at index " .. tostring(index))
            return
        end
        local id = rawget(descriptor, "id")
        if rawget(seen, id) then
            receiverError("duplicate manifest id: " .. id)
            return
        end
        seen[id] = true
        normalized[index] = {
            id = id,
            title = rawget(descriptor, "title"),
            n = rawget(descriptor, "n"),
            h = rawget(descriptor, "h"),
        }
    end

    local sameServer = receiver.sid == sid
    local previousFiles = receiver.files
    receiver.v = version
    receiver.sid = sid
    receiver.manifest = { files = normalized }
    receiver.files = {}
    receiver.pending = {}
    receiver.snapshot = nil
    receiver.needsResync = false
    receiver.lastError = nil
    receiver.images = images
    receiver.imagesSignature = imagesSignature
    receiver.languages = languages
    receiver.language = contentLanguage
    receiver.lseq = contentSeq

    for index = 1, #normalized do
        local descriptor = normalized[index]
        local previous = nil
        if sameServer then
            previous = rawget(previousFiles, descriptor.id)
        end
        if previous and previous.h == descriptor.h then
            receiver.files[descriptor.id] = {
                h = descriptor.h,
                content = previous.content,
            }
        else
            receiver.pending[descriptor.id] = {
                descriptor = descriptor,
                parts = {},
                received = 0,
            }
        end
    end

    publishSnapshotIfComplete()
end

local function receiveChunk(args)
    if type(args) ~= "table" then
        receiverError("chunk payload is not a table")
        return
    end

    local version = rawget(args, "v")
    local id = rawget(args, "id")
    local index = rawget(args, "i")
    local part = rawget(args, "part")
    local receiver = NBReader.receiver
    if version ~= receiver.v or type(id) ~= "string" then
        return
    end

    local pending = rawget(receiver.pending, id)
    if not pending then
        return
    end
    if not isInteger(index) or index < 1 or index > pending.descriptor.n
        or type(part) ~= "string"
        or Core.utf16Length(part) > Core.CHUNK_UTF16_LIMIT then
        receiverError("invalid chunk for " .. id)
        return
    end

    if rawget(pending.parts, index) == nil then
        pending.received = pending.received + 1
    end
    pending.parts[index] = part

    if pending.received ~= pending.descriptor.n then
        return
    end

    local ok, content = pcall(Core.reassembleChunks, pending.parts, pending.descriptor.n)
    if not ok then
        receiver.pending[id] = {
            descriptor = pending.descriptor,
            parts = {},
            received = 0,
        }
        receiverError(content)
        return
    end
    if Core.djb2Hex(content) ~= pending.descriptor.h then
        receiver.pending[id] = {
            descriptor = pending.descriptor,
            parts = {},
            received = 0,
        }
        receiverError("hash mismatch for " .. id)
        return
    end

    receiver.files[id] = {
        h = pending.descriptor.h,
        content = content,
    }
    receiver.pending[id] = nil
    publishSnapshotIfComplete()
end

function NBReader.receive(module, command, args)
    if module ~= NBReader.MODULE then
        return
    end
    if command == "manifest" then
        receiveManifest(args)
    elseif command == "chunk" then
        receiveChunk(args)
    elseif command == "imgchunk" then
        -- 圖片分塊的重組／解碼／落地全在 client 的 NBImageCache（需要 PZ 檔案 API 且必須分批），
        -- 這裡只做轉發；dedicated server 沒有這個 handler，訊息自然被忽略。
        if type(NBReader.onImageChunk) == "function" then
            local ok, callbackError = pcall(NBReader.onImageChunk, args)
            if not ok then
                -- 刻意不走 receiverError：那會設 needsResync，讓圖片端的錯誤去觸發整份公告重送。
                print("[MinidoracatNoticeBoardFor42] image chunk handler failed: "
                    .. Core.sanitizeName(callbackError))
            end
        end
    end
end

function NBReader.getImages()
    return NBReader.receiver.images
end

function NBReader.getLanguages()
    return NBReader.receiver.languages
end

function NBReader.getSnapshot()
    return NBReader.receiver.snapshot
end

function NBReader.getReceiverState()
    return NBReader.receiver
end

-- **測試專用的重置閘，不是執行期的防線**（比照 NBServer 對外暴露 scanImages／pumpImageEncode
-- 的理由）：出貨路徑一個呼叫點都沒有，也不該有——換伺服器由 receiveManifest 的
-- `receiver.sid == sid` 版本守衛就地處理（見該函式），整份重建反而會把已收到的檔案丟掉。
-- 唯一的呼叫端是 scripts/test_mdparser.lua，用它在各段測試之間拿到乾淨的接收端狀態。
-- 留著是因為替代方案更差：測試自己手刻一份 receiver 表就等於複製 newReceiverState 的
-- 12 個欄位，日後加欄位時無聲分岔。**不要把它當成「有東西在保護這條路徑」。**
function NBReader.resetReceiver()
    NBReader.receiver = newReceiverState()
end

if not NBReader._eventsInstalled then
    LuaEventManager.AddEvent(NBReader.LOCAL_EVENT)
    -- 兩個方向都要在 shared 註冊：SP 下 client 與 server lua 同 VM，誰先載入都要拿得到事件。
    LuaEventManager.AddEvent(NBReader.LOCAL_CMD_EVENT)
    Events[NBReader.LOCAL_EVENT].Add(function(module, command, args)
        NBReader.receive(module, command, args)
    end)
    Events.OnServerCommand.Add(function(module, command, args)
        NBReader.receive(module, command, args)
    end)
    NBReader._eventsInstalled = true
end

return NBReader
