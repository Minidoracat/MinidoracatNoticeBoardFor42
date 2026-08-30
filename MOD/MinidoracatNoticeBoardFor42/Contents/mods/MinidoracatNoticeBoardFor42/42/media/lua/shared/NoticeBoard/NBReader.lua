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

-- category="" 代表語系根層（升級前唯一存在的位置）：路徑一個字元都不變。
local function categoryDirectory(language, category)
    if category == nil or category == "" then
        return languageDirectory(language)
    end
    return languageDirectory(language) .. FILE_SEPARATOR .. category
end

local function noticePath(language, category, fileName)
    return categoryDirectory(language, category) .. FILE_SEPARATOR .. fileName
end

local function closeReader(reader)
    if reader then
        pcall(function()
            reader:close()
        end)
    end
end

-- 讀整個檔的每一行。三種結果必須分得開：(lines, nil) 讀到了、(nil, nil) 檔案不存在、
-- (nil, err) 讀檔失敗。maxUnits/maxLines 只給固定格式的小型控制檔使用，避免輪詢在主執行緒
-- 一次配置無界內容；公告本文仍由既有 MAX_FILE_BYTES 契約在掃描階段判定。
local function readAllLines(path, maxUnits, maxLines)
    local reader = nil
    local ok, result = pcall(function()
        reader = getFileReader(path, false)
        if not reader then
            return nil
        end

        local lines = {}
        local units = 0
        while true do
            local line = reader:readLine()
            if line == nil then
                break
            end
            if maxLines and #lines >= maxLines then
                error("too many lines")
            end
            units = units + string.len(line) + 1
            if maxUnits and units > maxUnits then
                error("file too large")
            end
            lines[#lines + 1] = line
        end

        reader:close()
        reader = nil
        return lines
    end)

    closeReader(reader)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

local function readNoticeFile(language, category, fileName)
    local lines, readError = readAllLines(noticePath(language, category, fileName))
    if readError then
        return nil, readError
    end
    if lines == nil then
        return nil, "file not found"
    end
    return table.concat(lines, "\n"), nil
end

local function listLanguageFileNames(language, category)
    local ok, files = pcall(function()
        return listFilesInZomboidLuaDirectory(categoryDirectory(language, category))
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

-- ---------------------------------------------------------------------------
-- 分類：NoticeBoard/categories.txt 宣告 -> NoticeBoard/<LANG>/<key>/ 放公告
--
-- 為什麼要一份宣告檔，而不是自動列舉子目錄：listFilesInZomboidLuaDirectory 只回**檔名**、
-- 從不列目錄，所以要發現子目錄唯一的辦法是「先知道名字再去問」——宣告檔就是那份名單。
-- 順帶得到三件本來沒地方放的東西：分類順序（key 的數字前綴，與檔名排序同一套規則）、
-- 多語標籤、以及一個結構性上界（MAX_CATEGORIES），擋掉服主亂放目錄把每輪掃描炸開。
--
-- 成本：每輪掃描的目錄數是 29 語系 x (1 + 已宣告分類數)，MAX_CATEGORIES=32 時最壞 957 次
-- listFilesInZomboidLuaDirectory。輪詢預設 60 秒一次，實務上服主只會宣告個位數分類。
-- 真要壓下來就得像 scanImages 那樣加輪替游標，但那會拉長分類變更的生效延遲；
-- 在實際量到卡頓之前不做。
-- ---------------------------------------------------------------------------

NBReader.CATEGORY_FILE = "categories.txt"
-- 這個上界同時是 producer 與 receiver 的契約（比照 MAX_MANIFEST_FILES）：沒有它，
-- 惡意 server 可用海量 cats 條目把 manifest 單包撐過 1MB 觸發 BufferOverflow。
NBReader.MAX_CATEGORIES = 32
NBReader.MAX_CATEGORY_KEY_UTF16 = 48
NBReader.MAX_CATEGORY_LABEL_UTF16 = 80
-- categories.txt 是 server 主執行緒週期性讀取的控制檔；成功分類數有上限仍不夠，
-- 無界註解／壞行一樣能放大配置與 issue signature。這三個上界只限制控制檔，不限制公告本文。
NBReader.MAX_CATEGORY_FILE_UTF16 = 256 * 1024
NBReader.MAX_CATEGORY_LINES = 2048
NBReader.MAX_CATEGORY_ISSUES = 128

-- 共用的不可變空清單。分類是「多數伺服器沒有」的功能，熱路徑（scanLanguage／compose／
-- languageCachesEqual）每次都新建一個空表純屬浪費。
local EMPTY_LIST = {}

-- key 直接當目錄名用，所以只放行 ASCII 的檔名安全字元：非 ASCII 目錄名在 Kahlua 的
-- 字面值路徑上會被截成單位元組（見本檔開頭 STRINGS_USE_UTF8_BYTES 的說明），而 `.`／`/`／`\`
-- 一旦放行就是路徑穿越（`..` 能爬出 NoticeBoard/）。要給人看的文字放 label，不放 key。
local function isValidCategoryKey(key)
    return type(key) == "string"
        and key ~= ""
        and string.len(key) <= NBReader.MAX_CATEGORY_KEY_UTF16
        and string.match(key, "^[A-Za-z0-9][A-Za-z0-9_%-]*$") ~= nil
end

-- label 會進 manifest 也會進 UI，所以要有長度上界（理由同 TITLE_UTF16_LIMIT）。
-- `|` 另外擋掉：宣告檔以 `|` 分欄，issue 簽章也用 `|` 串接。
local function isValidCategoryLabel(label)
    return type(label) == "string"
        and label ~= ""
        and string.len(label) <= NBReader.MAX_CATEGORY_LABEL_UTF16
        and string.find(label, "[%c|]") == nil
end

-- 條目的分類一律正規化成字串："" ＝未分類。舊版快取條目沒有這個欄位，
-- 而比較與分組都不該去區分 nil 與 ""。
local function categoryOf(entry)
    local value = entry.category
    if type(value) ~= "string" then
        return ""
    end
    return value
end

local function categoryKeysOf(categories)
    if categories and type(categories.keys) == "table" then
        return categories.keys
    end
    return EMPTY_LIST
end

-- 掃描用 key 可在宣告檔有語法錯誤時暫時包含上一輪 key；發布用 keys 則只含本輪合法宣告。
-- 兩者分開，才能在設定寫到一半時保住公告，又不把壞分類送進 cats。
local function categoryScanKeysOf(categories)
    if categories and type(categories.scanKeys) == "table" then
        return categories.scanKeys
    end
    return categoryKeysOf(categories)
end

-- 回傳 { keys, scanKeys, labels, defaults, issues, readError }：
--   keys      本輪合法宣告的分類 key（發布 cats 用）
--   scanKeys  本輪實際掃描的目錄 key；設定有錯時聯集上一輪，避免公告／已讀狀態被誤刪
--   labels    labels[key][lang] = 標籤
--   defaults  defaults[key] = 該 key 在檔案裡出現的第一個標籤（標籤 fallback 的最後一站）
--   readError 本輪讀檔失敗；若有 previous，完整沿用上一輪
function NBReader.scanCategories(previous)
    local result = {
        keys = {},
        scanKeys = {},
        labels = {},
        defaults = {},
        issues = {},
        readError = nil,
    }

    local lines, readError = readAllLines(
        NBReader.NOTICE_ROOT .. FILE_SEPARATOR .. NBReader.CATEGORY_FILE,
        NBReader.MAX_CATEGORY_FILE_UTF16, NBReader.MAX_CATEGORY_LINES)
    if readError then
        result.readError = readError
        if previous then
            result.keys = previous.keys or EMPTY_LIST
            result.labels = previous.labels or EMPTY_LIST
            result.defaults = previous.defaults or EMPTY_LIST
            result.scanKeys = previous.scanKeys or result.keys
        end
        result.issues[#result.issues + 1] = {
            kind = "category-read",
            detail = readError,
        }
        return result
    end
    -- lines 為 nil ＝檔案不存在。那不是錯誤（沒宣告分類就是沒分類），但必須與上面的
    -- 「讀檔失敗」分得開，否則一次磁碟問題會靜默把所有分類目錄從掃描名單上抹掉。
    if not lines then
        return result
    end

    local order = {}
    -- issue 一律只記「第幾行」＋問題種類，**不記原始內容**；而且最多保留 128 筆，
    -- 超過只加一筆 category-issue-limit。否則大量壞行雖不會灌原文，仍會在每輪為
    -- updateIssueLog 配置、排序並串接整份 signature。
    local issueLimitReported = false
    local function addIssue(kind, at, key, language)
        if #result.issues >= NBReader.MAX_CATEGORY_ISSUES then
            if not issueLimitReported then
                issueLimitReported = true
                result.issues[#result.issues + 1] = {
                    kind = "category-issue-limit",
                    detail = "line " .. tostring(at),
                }
            end
            return
        end
        result.issues[#result.issues + 1] = {
            kind = kind,
            language = language,
            id = key,
            detail = "line " .. tostring(at),
        }
    end

    local index
    for index = 1, #lines do
        local line = trim(lines[index])
        -- 空行與 `#` 註解一律略過 -> 一份純註解的檔案宣告零個分類。
        if line ~= "" and string.sub(line, 1, 1) ~= "#" then
            local key, language, label = string.match(line, "^([^|]*)|([^|]*)|([^|]*)$")
            if key == nil then
                addIssue("category-syntax", index)
            else
                key = trim(key)
                language = trim(language)
                label = trim(label)
                if not isValidCategoryKey(key) then
                    addIssue("category-key", index)
                elseif not isSupportedLanguage(language) then
                    addIssue("category-lang", index, key)
                elseif not isValidCategoryLabel(label) then
                    addIssue("category-label", index, key, language)
                else
                    local byLanguage = rawget(result.labels, key)
                    if byLanguage == nil and #order >= NBReader.MAX_CATEGORIES then
                        addIssue("category-limit", index, key)
                    else
                        if byLanguage == nil then
                            byLanguage = {}
                            result.labels[key] = byLanguage
                            result.defaults[key] = label
                            order[#order + 1] = key
                        end
                        if rawget(byLanguage, language) ~= nil then
                            addIssue("category-dup", index, key, language)
                        else
                            byLanguage[language] = label
                        end
                    end
                end
            end
        end
    end

    Core.sortSafe(order, fileNameLess)
    result.keys = order
    if #result.issues > 0 and previous then
        local scanKeys = {}
        local seen = {}
        local function addKeys(values)
            local keyIndex
            for keyIndex = 1, #(values or EMPTY_LIST) do
                if #scanKeys >= NBReader.MAX_CATEGORIES then
                    return
                end
                local key = values[keyIndex]
                if not rawget(seen, key) then
                    seen[key] = true
                    scanKeys[#scanKeys + 1] = key
                end
            end
        end
        -- 本輪合法 key 優先；上一輪只補滿剩餘名額，聯集永遠不超過 MAX_CATEGORIES。
        addKeys(order)
        addKeys(previous.scanKeys or previous.keys)
        Core.sortSafe(scanKeys, fileNameLess)
        result.scanKeys = scanKeys
    else
        result.scanKeys = order
    end
    return result
end

-- 標籤解析順序：玩家語系 -> DefaultLanguage -> 檔案裡第一個出現的標籤 -> key 本身。
-- 最後一站是 key 而不是空字串：側欄寧可顯示 `10_news`，也不要出現一個沒有名字的分組。
local function categoryLabel(categories, key, language, defaultLanguage)
    if categories then
        local byLanguage = rawget(categories.labels, key)
        if byLanguage then
            local label = rawget(byLanguage, language)
            if label ~= nil then
                return label
            end
            label = rawget(byLanguage, defaultLanguage)
            if label ~= nil then
                return label
            end
        end
        local fallback = rawget(categories.defaults, key)
        if fallback ~= nil then
            return fallback
        end
    end
    return key
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

-- 標題行的圖片標記不能原樣當側欄名稱：第一個 H1 同時是側欄公告名稱與新內容 toast 文案，
-- 路徑原樣留下會露出實體位置並把文件樹文字撐到幾乎全被截斷。markdown 的
-- `![替代文字](路徑)` 留下替代文字（那正是「這張圖在說什麼」）；原生
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

function NBReader.listLanguageFiles(language, category)
    if not isSupportedLanguage(language) then
        return nil, "unsupported language"
    end
    if category ~= nil and category ~= "" and not isValidCategoryKey(category) then
        return nil, "invalid category"
    end
    return listLanguageFileNames(language, category or "")
end

-- bootstrap 的唯一判斷依據，所以**必須**把已宣告的分類目錄一起算進來：只把公告放在
-- 分類目錄裡的伺服器若被判成「空的」，啟動時就會被塞進兩份 10_welcome.txt。
-- categories 省略時自己讀一次宣告檔（呼叫端只有啟動路徑，一輪一次不必共用）。
function NBReader.hasAnyNoticeFiles(categories)
    if categories == nil then
        categories = NBReader.scanCategories()
    end
    if categories.readError then
        return nil, categories.readError
    end
    local keys = categoryScanKeysOf(categories)
    local languages = languageCodes()
    local index
    for index = 1, #languages do
        local language = languages[index]
        local files, readError = listLanguageFileNames(language, "")
        if not files then
            return nil, readError
        end
        if #files > 0 then
            return true, nil
        end
        local keyIndex
        for keyIndex = 1, #keys do
            files, readError = listLanguageFileNames(language, keys[keyIndex])
            if not files then
                return nil, readError
            end
            if #files > 0 then
                return true, nil
            end
        end
    end
    return false, nil
end

-- 只換分類（內容 hash 一個位元組都沒動）時複製一份、改掉 category。
-- **不可原地改 previousEntry**：那張表仍被上一輪的 sourceCaches／languageCaches 持有，
-- 改了等於讓「上一輪的分類」憑空變成新值，languageCachesEqual 就再也看不出分類變更，
-- manifest 永遠不會重推 -> 玩家的側欄停在舊分組。chunks 是唯讀的，共用即可（不重切）。
local function reparentEntry(entry, category)
    if categoryOf(entry) == category then
        return entry
    end
    return {
        id = entry.id,
        language = entry.language,
        category = category,
        title = entry.title,
        content = entry.content,
        bytes = entry.bytes,
        h = entry.h,
        chunks = entry.chunks,
        n = entry.n,
    }
end

-- 掃一個目錄並把條目併進 result。category="" 代表語系根層。
-- id 是**裸檔名**，分類不進 id：已讀狀態的鍵、manifest 的鍵、client 端的內容快取全都用它，
-- 把分類塞進 id 會讓服主搬一次資料夾就把全服的已讀狀態與內容快取整批作廢。
-- 代價是同語系下裸檔名必須全域唯一。掃描順序固定為「根層先，其後依 key 排序的分類目錄」，
-- 先到先贏；撞名者記 dup-id 並跳過（服主看得到，才知道要改檔名）。
local function scanDirectory(result, language, category, previous, previousById)
    local fileNames, listError = listLanguageFileNames(language, category)
    if not fileNames then
        result.issues[#result.issues + 1] = {
            kind = "list",
            language = language,
            id = category ~= "" and category or nil,
            detail = listError,
        }
        -- 列舉失敗只代表這一輪問不到（磁碟／權限），不代表服主刪了公告：沿用上一輪
        -- **同一個目錄**的條目，別讓一次 IO 抖動把公告板清空。
        local previousFiles = previous.files or EMPTY_LIST
        local previousIndex
        for previousIndex = 1, #previousFiles do
            local previousEntry = previousFiles[previousIndex]
            if categoryOf(previousEntry) == category
                and rawget(result.byId, previousEntry.id) == nil then
                result.files[#result.files + 1] = previousEntry
                result.byId[previousEntry.id] = previousEntry
            end
        end
        return
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
        elseif rawget(result.byId, fileName) ~= nil then
            result.issues[#result.issues + 1] = {
                kind = "dup-id",
                language = language,
                id = fileName,
                detail = category ~= "" and category or "-",
            }
        else
        local previousEntry = rawget(previousById, fileName)
        local content, readError = readNoticeFile(language, category, fileName)
        if content == nil then
            result.issues[#result.issues + 1] = {
                kind = "read",
                language = language,
                id = fileName,
                detail = readError,
            }
            if previousEntry then
                local staleEntry = reparentEntry(previousEntry, category)
                result.files[#result.files + 1] = staleEntry
                result.byId[fileName] = staleEntry
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
                    entry = reparentEntry(previousEntry, category)
                else
                    local ok, chunks = pcall(Core.chunkText, content)
                    if ok then
                        entry = {
                            id = fileName,
                            language = language,
                            category = category,
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
                        if previousEntry then
                            entry = reparentEntry(previousEntry, category)
                        end
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
end

-- categories 省略 -> 只掃語系根層，行為與分類功能加入之前完全相同。
function NBReader.scanLanguage(language, previous, categories)
    if not isSupportedLanguage(language) then
        error("unsupported language: " .. tostring(language))
    end

    previous = previous or EMPTY_LIST
    local previousById = previous.byId or EMPTY_LIST
    local result = {
        language = language,
        files = {},
        byId = {},
        issues = {},
    }

    scanDirectory(result, language, "", previous, previousById)
    local keys = categoryScanKeysOf(categories)
    local index
    for index = 1, #keys do
        scanDirectory(result, language, keys[index], previous, previousById)
    end

    Core.sortSafe(result.files, entryLess)
    return result
end

function NBReader.scanAll(previous, previousCategories)
    previous = previous or EMPTY_LIST
    -- 宣告檔一輪只讀一次，29 個語系共用同一份名單（也共用同一批 issue）。
    -- 暫時讀不到時沿用上一輪名單，避免整批分類公告被誤判刪除。
    local categories = NBReader.scanCategories(previousCategories)
    local result = {
        languages = {},
        issues = {},
        categories = categories,
    }
    local index
    for index = 1, #categories.issues do
        result.issues[#result.issues + 1] = categories.issues[index]
    end
    local languages = languageCodes()
    for index = 1, #languages do
        local language = languages[index]
        local scanned = NBReader.scanLanguage(language, rawget(previous, language), categories)
        result.languages[language] = scanned
        local issueIndex
        for issueIndex = 1, #scanned.issues do
            result.issues[#result.issues + 1] = scanned.issues[issueIndex]
        end
    end
    return result
end

-- 檔名標記 `<名稱>.only.<副檔名>`＝**這份公告只給所屬語系目錄的玩家看**，不會被鋪成
-- 其他語系的底稿。為什麼需要它：DefaultLanguage 目錄同時扮演兩個角色（該語系的內容
-- ＋全體共用的底稿），所以在它裡面本來沒有辦法表達「只給這個語系看」——把 DefaultLanguage
-- 設成 EN 之後，EN/ 底下的每一份都會出現在所有語系玩家面板上。非 DefaultLanguage 的
-- 語系目錄本來就是限定的（compose 只從 DefaultLanguage 鋪底稿，不會反向補），
-- 這個標記等於把同樣的能力補回 DefaultLanguage 目錄。
--
-- 為什麼可見性仍用檔名，而不是分類目錄或檔案內標記：
--   * 分類目錄由 `categories.txt` 宣告，作用只有側欄分組；拿目錄同時表達可見性會把兩種
--     正交語意綁死，搬分類就意外改變能看到公告的人。
--   * 檔案內標記要先讀檔才知道要不要納入，而 fallback 納入判斷以裸檔名為穩定 ID。
--   * `.only.` 從檔名一眼看得出，服主列一次檔案就知道哪些是限定的。
-- 點號在檔名驗證裡完全合法（只擋控制字元與 | =，見 scanLanguage 的 invalid-id），
-- 副檔名取的是最後一段（isNoticeFile 的 `%.([^%.]+)$`），所以 `.only.txt` 仍是合法的 .txt。
local function isLanguageOnly(fileName)
    return type(fileName) == "string"
        and string.match(fileName, "%.only%.[^%.]+$") ~= nil
end

NBReader.isLanguageOnly = isLanguageOnly

-- skipLanguageOnly：這一批是「別人的底稿」，標記過的檔案不該跟著鋪過來。
-- 底稿這一輪同時決定「這個 id 住在哪一個分類」（authority）。DefaultLanguage 是全體共用的
-- 骨架，分類位置必須由它定：否則服主把某個語系的翻譯版放進別的資料夾時，同一份公告
-- 會在不同語系玩家的側欄跳到不同分組。
local function addBaseEntries(target, authority, source, skipLanguageOnly)
    if not source then
        return
    end
    local index
    for index = 1, #source.files do
        local entry = source.files[index]
        if not (skipLanguageOnly and isLanguageOnly(entry.id)) then
            target[entry.id] = entry
            authority[entry.id] = categoryOf(entry)
        end
    end
end

-- 玩家語系這一輪覆蓋**內容**，但不改分類位置：位置以底稿為準，並回報衝突
-- （否則服主完全看不出自己把某個語系的版本放錯了資料夾）。底稿沒有的 id 由它自己定分類。
local function addOverrideEntries(target, authority, source, conflicts)
    if not source then
        return
    end
    local index
    for index = 1, #source.files do
        local entry = source.files[index]
        local expected = rawget(authority, entry.id)
        local actual = categoryOf(entry)
        if expected == nil then
            target[entry.id] = entry
            authority[entry.id] = actual
        elseif expected == actual then
            target[entry.id] = entry
        else
            target[entry.id] = reparentEntry(entry, expected)
            conflicts[#conflicts + 1] = { id = entry.id, from = actual, to = expected }
        end
    end
end

function NBReader.composeLanguage(scannedLanguages, language, defaultLanguage, categories)
    if not isSupportedLanguage(language) then
        error("unsupported language: " .. tostring(language))
    end
    if not isSupportedLanguage(defaultLanguage) then
        error("unsupported default language: " .. tostring(defaultLanguage))
    end

    local selected = {}
    local authority = {}
    local conflicts = {}
    -- DefaultLanguage 是全體共用的底稿；玩家語系不是它時，跳過它裡面標記 .only 的檔案。
    -- 玩家語系自己的目錄一律全收（含 .only —— 那本來就是給這個語系看的）。
    addBaseEntries(selected, authority, rawget(scannedLanguages, defaultLanguage),
        language ~= defaultLanguage)
    if language ~= defaultLanguage then
        addOverrideEntries(selected, authority, rawget(scannedLanguages, language), conflicts)
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
    local used = {}
    local declared = {}
    local declaredKeys = categoryKeysOf(categories)
    for index = 1, #declaredKeys do
        declared[declaredKeys[index]] = true
    end
    for index = 1, #files do
        entry = files[index]
        byId[entry.id] = entry
        local category = categoryOf(entry)
        local publishedCategory = rawget(declared, category) and category or ""
        manifestFiles[index] = {
            id = entry.id,
            title = entry.title,
            n = entry.n,
            h = entry.h,
            -- 未分類或本輪宣告無效就不送 c：公告仍發布，但 receiver 把它放進根層。
            c = publishedCategory ~= "" and publishedCategory or nil,
        }
        if publishedCategory ~= "" then
            used[publishedCategory] = true
        end
    end

    -- 只送**這個語系實際有檔案**的分類。空分類不進 manifest：側欄不該出現點開是空的分組
    -- （某個語系還沒翻譯完時正是這個狀態），也省下每份 manifest 的固定開銷。
    local activeCategories = {}
    local manifestCategories = {}
    local keys = categoryKeysOf(categories)
    for index = 1, #keys do
        local key = keys[index]
        if rawget(used, key) then
            local label = categoryLabel(categories, key, language, defaultLanguage)
            activeCategories[#activeCategories + 1] = { key = key, label = label }
            manifestCategories[#manifestCategories + 1] = { k = key, t = label }
        end
    end

    return {
        language = language,
        files = files,
        byId = byId,
        manifestFiles = manifestFiles,
        -- {{key=..., label=...}}：標籤在這裡就解析完 fallback，UI 直接顯示。
        categories = activeCategories,
        -- 上面那份的線材形狀（{{k=..., t=...}}）。預先算好，讓每次送 manifest 不必重建。
        manifestCategories = manifestCategories,
        -- 玩家語系把某份公告放進了與底稿不同的分類（位置以底稿為準）。呼叫端負責寫進 issue log。
        categoryConflicts = conflicts,
        totalBytes = totalBytes,
        trimmed = trimmed,
    }
end

-- 「這個語系的內容有沒有變」的唯一判斷。分類與分類標籤也算在內：只把公告搬進另一個
-- 資料夾（每份 hash 都沒動）或只改一行標籤時，manifest 一樣必須重推，
-- 否則玩家的側欄會停在舊分組／舊名字，而且完全沒有自癒路徑。
function NBReader.languageCachesEqual(left, right)
    if left == right then
        return true
    end
    if not left or not right or #left.files ~= #right.files then
        return false
    end

    local leftCategories = left.categories or EMPTY_LIST
    local rightCategories = right.categories or EMPTY_LIST
    if #leftCategories ~= #rightCategories then
        return false
    end
    local index
    for index = 1, #leftCategories do
        if leftCategories[index].key ~= rightCategories[index].key
            or leftCategories[index].label ~= rightCategories[index].label then
            return false
        end
    end

    for index = 1, #left.files do
        local leftEntry = left.files[index]
        local rightEntry = right.files[index]
        if leftEntry.id ~= rightEntry.id
            or leftEntry.h ~= rightEntry.h
            or leftEntry.n ~= rightEntry.n
            or categoryOf(leftEntry) ~= categoryOf(rightEntry) then
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
        -- 已完成內容與所有 pending parts 的實收 UTF-8 bytes；每次收 chunk 都先試算再落地。
        receivedBytes = 0,
        snapshot = nil,
        needsResync = false,
        lastError = nil,
        -- 伺服器實際有內容的語系（面板語系選單用）。舊版 server 不送這個欄位 -> 空清單，
        -- 選單只剩「自動」，公告文字與圖片完全不受影響。
        languages = {},
        -- 伺服器宣告的分類（側欄分組用），{{key=..., label=...}}。舊版 server 不送 cats
        -- -> 空清單，所有公告落在「未分類」，公告文字與圖片完全不受影響。
        categories = {},
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

-- 分類是分組用的裝飾欄位，不是內容完整性的一部分。形狀不合或不在 cats 權威清單內時，
-- 該檔只降級成未分類並寫一行 log，**不得**像 id/h/n/title 那樣拒收整份 manifest。
local function normalizeDescriptorCategory(descriptor, allowed)
    local value = rawget(descriptor, "c")
    if value == nil then
        -- 舊版 server 不送 c -> 未分類。
        return "", false
    end
    if isValidCategoryKey(value) and rawget(allowed, value) == true then
        return value, false
    end
    return "", true
end

-- cats 的上界與字元集與 producer 端共用同一組判定（isValidCategoryKey／isValidCategoryLabel）：
-- 惡意 server 不得靠海量條目或超長標籤把單包撐過 1MB，也不得把控制字元送進 UI。
-- 任一條目不合法就整份拒絕（比照 normalizeLanguageList）：清單很小，部分接受只會讓
-- 服主看不出自己哪裡設錯。
local function normalizeCategories(rawCategories)
    if rawCategories == nil then
        return {}, nil, {}
    end
    if type(rawCategories) ~= "table" then
        return nil, "categories is not a table", nil
    end
    if #rawCategories > NBReader.MAX_CATEGORIES then
        return nil, "too many categories: " .. tostring(#rawCategories), nil
    end

    local normalized = {}
    local seen = {}
    local index
    for index = 1, #rawCategories do
        local descriptor = rawCategories[index]
        if type(descriptor) ~= "table" then
            return nil, "invalid category at index " .. tostring(index), nil
        end
        local key = rawget(descriptor, "k")
        local label = rawget(descriptor, "t")
        if not isValidCategoryKey(key) then
            return nil, "invalid category key at index " .. tostring(index), nil
        end
        if not isValidCategoryLabel(label) then
            return nil, "invalid category label at index " .. tostring(index), nil
        end
        if rawget(seen, key) then
            return nil, "duplicate category key: " .. key, nil
        end
        seen[key] = true
        normalized[index] = { key = key, label = label }
    end
    return normalized, nil, seen
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
            -- 側欄分組用。舊版 server 沒送 -> ""（未分類），UI 因此可以無條件取用。
            category = descriptor.category or "",
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
        -- {{key=..., label=...}}，順序即側欄顯示順序。舊版 server 為空清單。
        categories = receiver.categories,
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

local function newPendingFile(descriptor)
    return {
        descriptor = descriptor,
        parts = {},
        partBytes = {},
        bytes = 0,
        received = 0,
    }
end

local function resetPendingFile(receiver, id, pending)
    receiver.receivedBytes = math.max(0, receiver.receivedBytes - pending.bytes)
    receiver.pending[id] = newPendingFile(pending.descriptor)
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

    -- 分類清單同一政策（只影響側欄分組，壞掉不得拖垮公告文字）。
    local categories, categoriesError, categoryKeys = normalizeCategories(rawget(args, "cats"))
    if not categories then
        print("[MinidoracatNoticeBoardFor42] manifest categories ignored: "
            .. Core.sanitizeName(tostring(categoriesError)))
        categories = {}
        categoryKeys = {}
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
    local totalChunks = 0
    local maximumChunks = math.floor(
        NBReader.MAX_LANGUAGE_BYTES / Core.CHUNK_UTF16_LIMIT) + #descriptors
    -- 分類形狀不合的檔案數。降級成未分類而不是拒收整份 manifest（見 normalizeDescriptorCategory），
    -- 但要留一行 log，否則 producer 端的錯誤在 client 這邊完全無聲。
    local categoryRejects = 0
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
        totalChunks = totalChunks + rawget(descriptor, "n")
        if totalChunks > maximumChunks then
            receiverError("manifest chunk budget exceeded")
            return
        end
        local category, categoryRejected = normalizeDescriptorCategory(descriptor, categoryKeys)
        if categoryRejected then
            categoryRejects = categoryRejects + 1
        end
        normalized[index] = {
            id = id,
            title = rawget(descriptor, "title"),
            n = rawget(descriptor, "n"),
            h = rawget(descriptor, "h"),
            category = category,
        }
    end
    if categoryRejects > 0 then
        print("[MinidoracatNoticeBoardFor42] manifest file categories ignored: "
            .. tostring(categoryRejects))
    end

    local sameServer = receiver.sid == sid
    local previousFiles = receiver.files
    receiver.v = version
    receiver.sid = sid
    receiver.manifest = { files = normalized }
    receiver.files = {}
    receiver.pending = {}
    receiver.receivedBytes = 0
    receiver.snapshot = nil
    receiver.needsResync = false
    receiver.lastError = nil
    receiver.images = images
    receiver.imagesSignature = imagesSignature
    receiver.languages = languages
    receiver.categories = categories
    receiver.language = contentLanguage
    receiver.lseq = contentSeq

    for index = 1, #normalized do
        local descriptor = normalized[index]
        local previous = nil
        if sameServer then
            previous = rawget(previousFiles, descriptor.id)
        end
        if previous and previous.h == descriptor.h then
            local bytes = previous.bytes
            if not isInteger(bytes) then
                bytes = NBReader.utf8ByteLength(previous.content)
            end
            if bytes > NBReader.MAX_FILE_BYTES
                or receiver.receivedBytes + bytes > NBReader.MAX_LANGUAGE_BYTES then
                receiverError("cached content budget exceeded")
                return
            end
            receiver.files[descriptor.id] = {
                h = descriptor.h,
                content = previous.content,
                bytes = bytes,
            }
            receiver.receivedBytes = receiver.receivedBytes + bytes
        else
            receiver.pending[descriptor.id] = newPendingFile(descriptor)
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

    local partBytes = NBReader.utf8ByteLength(part)
    local previousBytes = rawget(pending.partBytes, index) or 0
    local pendingBytes = pending.bytes - previousBytes + partBytes
    local receivedBytes = receiver.receivedBytes - previousBytes + partBytes
    if pendingBytes > NBReader.MAX_FILE_BYTES
        or receivedBytes > NBReader.MAX_LANGUAGE_BYTES then
        receiverError("chunk byte budget exceeded for " .. id)
        return
    end

    if rawget(pending.parts, index) == nil then
        pending.received = pending.received + 1
    end
    pending.parts[index] = part
    pending.partBytes[index] = partBytes
    pending.bytes = pendingBytes
    receiver.receivedBytes = receivedBytes

    if pending.received ~= pending.descriptor.n then
        return
    end

    local ok, content = pcall(Core.reassembleChunks, pending.parts, pending.descriptor.n)
    if not ok then
        resetPendingFile(receiver, id, pending)
        receiverError(content)
        return
    end
    local contentBytes = NBReader.utf8ByteLength(content)
    if contentBytes ~= pending.bytes then
        resetPendingFile(receiver, id, pending)
        receiverError("byte count mismatch for " .. id)
        return
    end
    if Core.djb2Hex(content) ~= pending.descriptor.h then
        resetPendingFile(receiver, id, pending)
        receiverError("hash mismatch for " .. id)
        return
    end

    receiver.files[id] = {
        h = pending.descriptor.h,
        content = content,
        bytes = contentBytes,
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
