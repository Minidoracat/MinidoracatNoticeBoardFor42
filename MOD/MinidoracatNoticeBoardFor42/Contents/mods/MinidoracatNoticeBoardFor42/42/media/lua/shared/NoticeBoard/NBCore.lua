NBCore = NBCore or {}

NBCore.CHUNK_UTF16_LIMIT = 6000

-- 此白名單實列自 B42.20.2 原版 Translate 目錄；STREW 是實際存在的語系目錄，故一併納入。
NBCore.LANGS = {
    AR = true,
    CA = true,
    CH = true,
    CN = true,
    CS = true,
    DA = true,
    DE = true,
    EN = true,
    ES = true,
    ES_CL = true,
    ES_MX = true,
    FI = true,
    FR = true,
    HU = true,
    ID = true,
    IT = true,
    JP = true,
    KO = true,
    NL = true,
    NO = true,
    PL = true,
    PT = true,
    PTBR = true,
    RO = true,
    RU = true,
    STREW = true,
    TH = true,
    TR = true,
    UA = true,
}

-- 面板語系選單的「跟隨遊戲語系」哨兵值。刻意小寫，永遠不可能與 LANGS 的代碼相撞。
NBCore.AUTO_LANGUAGE = "auto"
-- 語系清單的上界（信任邊界，比照 NBReader.MAX_MANIFEST_FILES）：白名單本身只有 29 個，
-- 留一點餘裕即可。沒有上界則惡意 server 可用海量條目把 manifest 單包撐過 1MB。
NBCore.MAX_LANGUAGE_LIST = 32
-- 語系切換請求的序號上界。client 每送一次切換請求就 +1，超過此值回繞到 1
-- （0 保留給「本場還沒切換過」）。Kahlua 沒有整數型別，序號是 double；1e6 遠低於
-- double 的整數精確上界 2^53，回繞後的值仍可被精確表示，而比對是純等值判斷
-- （不做大小比較），因此回繞不影響正確性——要誤判必須在單一次切換飛行期間
-- 正好累積 1e6 次切換，不可能發生。同時它也是接收端的信任邊界上界。
NBCore.MAX_LANGUAGE_SEQ = 1000000

-- Kahlua 的 table.sort 是遞迴 quicksort，跑在 coroutine 堆疊上（MAX_STACK_SIZE=3000，
-- Coroutine.java:16）；輸入已接近排序時退化成 O(n) 遞迴深度，數百筆即堆疊溢位
-- （Cleaner 0.1.1 正式服實際炸過）。本 MOD 的排序輸入多為檔案清單（目錄列舉常已排序）
-- 與 pairs() 走訪結果（KahluaTableImpl 底層是 LinkedHashMap＝插入順序，若插入源有序則
-- 輸出有序）——正是危險輸入。全庫一律用本函式：迭代式 bottom-up merge sort，
-- 無遞迴、穩定、O(n log n)。comp 省略時預設升冪。
function NBCore.sortSafe(list, comp)
    comp = comp or function(a, b) return a < b end
    local n = #list
    if n < 2 then
        return list
    end
    local buf = {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local midEnd = i + width - 1
            if midEnd > n then midEnd = n end
            local hiEnd = i + width * 2 - 1
            if hiEnd > n then hiEnd = n end
            local a, b, k = i, midEnd + 1, i
            while a <= midEnd and b <= hiEnd do
                if comp(list[b], list[a]) then
                    buf[k] = list[b]; b = b + 1
                else
                    buf[k] = list[a]; a = a + 1
                end
                k = k + 1
            end
            while a <= midEnd do buf[k] = list[a]; a = a + 1; k = k + 1 end
            while b <= hiEnd do buf[k] = list[b]; b = b + 1; k = k + 1 end
            i = i + width * 2
        end
        for j = 1, n do
            list[j] = buf[j]
        end
        width = width * 2
    end
    return list
end

local UINT32_MODULUS = 4294967296
local HEX_DIGITS = "0123456789abcdef"

-- 標準 Lua 的 string index 是 UTF-8 byte；Kahlua 的 string index 是 Java UTF-16 char。
-- 環境偵測必須用純 ASCII：非 ASCII 字面值在 Kahlua 會被截成單位元組（先前靠 "é" 恰好
-- 得到正確答案純屬僥倖）。改用 PZ 全域函式是否存在來判斷：PZ/Kahlua 的字串索引是
-- UTF-16 code unit，標準 Lua（測試環境）則是 UTF-8 byte。
local STRINGS_USE_UTF8_BYTES = type(getTimestampMs) ~= "function"

local function expectString(value, name)
    if type(value) ~= "string" then
        error((name or "value") .. " must be a string")
    end
end

local function isContinuationByte(value)
    return value ~= nil and value >= 128 and value <= 191
end

-- 回傳 UTF-8 byte 寬度、Unicode code point、UTF-16 code unit 數。
-- 無效 UTF-8 byte 以單一 code unit 保留，避免純邏輯層遺失原始資料。
local function nextUtf8CodePoint(text, index)
    local b1 = string.byte(text, index)
    if b1 == nil then
        return 0, 0, 0
    end

    if b1 <= 127 then
        return 1, b1, 1
    end

    local b2 = string.byte(text, index + 1)
    if b1 >= 194 and b1 <= 223 and isContinuationByte(b2) then
        return 2, (b1 - 192) * 64 + (b2 - 128), 1
    end

    local b3 = string.byte(text, index + 2)
    if b1 >= 224 and b1 <= 239 and isContinuationByte(b2) and isContinuationByte(b3) then
        local validSecond = true
        if b1 == 224 and b2 < 160 then
            validSecond = false
        elseif b1 == 237 and b2 > 159 then
            validSecond = false
        end

        if validSecond then
            local codePoint = (b1 - 224) * 4096 + (b2 - 128) * 64 + (b3 - 128)
            return 3, codePoint, 1
        end
    end

    local b4 = string.byte(text, index + 3)
    if b1 >= 240 and b1 <= 244 and isContinuationByte(b2)
        and isContinuationByte(b3) and isContinuationByte(b4) then
        local validSecond = true
        if b1 == 240 and b2 < 144 then
            validSecond = false
        elseif b1 == 244 and b2 > 143 then
            validSecond = false
        end

        if validSecond then
            local codePoint = (b1 - 240) * 262144
                + (b2 - 128) * 4096
                + (b3 - 128) * 64
                + (b4 - 128)
            return 4, codePoint, 2
        end
    end

    return 1, b1, 1
end

local function addDjb2Unit(hash, unit)
    return (hash * 33 + unit) % UINT32_MODULUS
end

-- DJB2 以 UTF-16 code unit 計算，讓純 Lua 測試環境與 Kahlua 得到相同結果。
function NBCore.djb2(text)
    expectString(text, "text")

    local hash = 5381
    if not STRINGS_USE_UTF8_BYTES then
        local index
        for index = 1, string.len(text) do
            hash = addDjb2Unit(hash, string.byte(text, index))
        end
        return hash
    end

    local index = 1
    local byteLength = string.len(text)
    while index <= byteLength do
        local width, codePoint = nextUtf8CodePoint(text, index)
        if codePoint > 65535 then
            local offset = codePoint - 65536
            local highSurrogate = 55296 + math.floor(offset / 1024)
            local lowSurrogate = 56320 + (offset % 1024)
            hash = addDjb2Unit(hash, highSurrogate)
            hash = addDjb2Unit(hash, lowSurrogate)
        else
            hash = addDjb2Unit(hash, codePoint)
        end
        index = index + width
    end

    return hash
end

function NBCore.djb2Hex(text)
    local value = NBCore.djb2(text)
    local result = {}
    local index
    for index = 8, 1, -1 do
        local digit = value % 16
        result[index] = string.sub(HEX_DIGITS, digit + 1, digit + 1)
        value = math.floor(value / 16)
    end
    return table.concat(result)
end

function NBCore.utf16Length(text)
    expectString(text, "text")

    if not STRINGS_USE_UTF8_BYTES then
        return string.len(text)
    end

    local units = 0
    local index = 1
    local byteLength = string.len(text)
    while index <= byteLength do
        local width, _, codeUnits = nextUtf8CodePoint(text, index)
        units = units + codeUnits
        index = index + width
    end
    return units
end

local function validateChunkLimit(maxUnits)
    if type(maxUnits) ~= "number" or maxUnits < 1 or maxUnits ~= math.floor(maxUnits) then
        error("maxUnits must be a positive integer")
    end
    if maxUnits > NBCore.CHUNK_UTF16_LIMIT then
        error("maxUnits exceeds CHUNK_UTF16_LIMIT")
    end
end

local function chunkUtf16String(text, maxUnits)
    local chunks = {}
    local textLength = string.len(text)
    local startIndex = 1

    while startIndex <= textLength do
        local endIndex = startIndex + maxUnits - 1
        if endIndex > textLength then
            endIndex = textLength
        end

        if endIndex < textLength then
            local lastUnit = string.byte(text, endIndex)
            local nextUnit = string.byte(text, endIndex + 1)
            local endsWithHighSurrogate = lastUnit >= 55296 and lastUnit <= 56319
            local followedByLowSurrogate = nextUnit >= 56320 and nextUnit <= 57343
            if endsWithHighSurrogate and followedByLowSurrogate then
                endIndex = endIndex - 1
            end
        end

        if endIndex < startIndex then
            error("maxUnits cannot contain a surrogate pair")
        end

        chunks[#chunks + 1] = string.sub(text, startIndex, endIndex)
        startIndex = endIndex + 1
    end

    return chunks
end

local function chunkUtf8String(text, maxUnits)
    local chunks = {}
    local byteLength = string.len(text)
    local chunkStart = 1
    local index = 1
    local chunkUnits = 0

    while index <= byteLength do
        local width, _, codeUnits = nextUtf8CodePoint(text, index)
        if chunkUnits + codeUnits > maxUnits then
            if chunkUnits == 0 then
                error("maxUnits cannot contain a surrogate pair")
            end
            chunks[#chunks + 1] = string.sub(text, chunkStart, index - 1)
            chunkStart = index
            chunkUnits = 0
        else
            chunkUnits = chunkUnits + codeUnits
            index = index + width
        end
    end

    chunks[#chunks + 1] = string.sub(text, chunkStart)
    return chunks
end

function NBCore.chunkText(text, maxUnits)
    expectString(text, "text")
    maxUnits = maxUnits or NBCore.CHUNK_UTF16_LIMIT
    validateChunkLimit(maxUnits)

    if text == "" then
        return { "" }
    end

    if STRINGS_USE_UTF8_BYTES then
        return chunkUtf8String(text, maxUnits)
    end
    return chunkUtf16String(text, maxUnits)
end

function NBCore.reassembleChunks(chunks, expectedCount)
    if type(chunks) ~= "table" then
        error("chunks must be a table")
    end

    local count = expectedCount
    if count == nil then
        count = #chunks
    end
    if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then
        error("expectedCount must be a non-negative integer")
    end

    local ordered = {}
    local index
    for index = 1, count do
        local part = chunks[index]
        if type(part) ~= "string" then
            error("missing or invalid chunk at index " .. tostring(index))
        end
        if NBCore.utf16Length(part) > NBCore.CHUNK_UTF16_LIMIT then
            error("chunk exceeds CHUNK_UTF16_LIMIT at index " .. tostring(index))
        end
        ordered[index] = part
    end

    return table.concat(ordered)
end

function NBCore.escapeRichText(text)
    expectString(text, "text")
    text = string.gsub(text, "<", "&lt;")
    return string.gsub(text, ">", "&gt;")
end

function NBCore.unescapeRichText(text)
    expectString(text, "text")
    text = string.gsub(text, "&lt;", "<")
    return string.gsub(text, "&gt;", ">")
end

-- 「伺服器實際有內容的語系」清單的共用正規化：producer（NBServer 掃描結果）與
-- receiver（NBReader 收 manifest）都走這一份，上界與白名單只有一處可改。
-- 任一條目不合法就整份拒絕：清單很小，部分接受只會讓服主看不出自己哪裡設錯。
function NBCore.normalizeLanguageList(values)
    if type(values) ~= "table" then
        return nil, "languages is not a table"
    end
    local count = #values
    if count > NBCore.MAX_LANGUAGE_LIST then
        return nil, "too many languages: " .. tostring(count)
    end

    local result = {}
    local seen = {}
    local index
    for index = 1, count do
        local code = values[index]
        if type(code) ~= "string" or rawget(NBCore.LANGS, code) ~= true then
            return nil, "invalid language at index " .. tostring(index)
        end
        if not rawget(seen, code) then
            seen[code] = true
            result[#result + 1] = code
        end
    end
    return result, nil
end

-- 面板語系偏好的正規化。settings.ini 的內容是玩家可編輯的純文字，
-- 白名單外的一切（含 nil、非字串、大小寫不符）一律視為 auto。
function NBCore.normalizeLanguagePreference(value)
    if type(value) == "string" and rawget(NBCore.LANGS, value) == true then
        return value
    end
    return NBCore.AUTO_LANGUAGE
end

-- 依序（帶游標）取代字面子字串。NBPanel 的圖片預檢用它逐一消耗 richText 內的
-- <NBIMG:n> 佔位（MDParser 為每張 markdown 圖片產生一個唯一 token），游標讓整輪替換
-- 維持線性，不必每張都從頭掃。
-- 回傳新字串與「下一次搜尋起點」（替換後的尾端，不會再掃進剛放進去的內容）。
function NBCore.replaceNextLiteral(text, position, needle, replacement)
    local first, last = string.find(text, needle, position, true)
    if not first then
        return text, position
    end
    return string.sub(text, 1, first - 1)
        .. replacement
        .. string.sub(text, last + 1),
        first + string.len(replacement)
end

-- 原生圖片 tag 的參數解析（`<IMAGE:路徑>` 或 `<IMAGE:路徑,寬,高>`）。
-- 引擎只要在 command 內看到逗號就做 vs = string.split(command, ",")、
-- w = tonumber(string.trim(vs[2]))、h = tonumber(string.trim(vs[3]))
-- （ISRichTextPanel.lua:149-154，IMAGECENTRE 同形於 :183-190）。服主手寫
-- `<IMAGE:path,600>` 時 vs[3] 是 nil，而 string.trim 是 Java 端 StringLib（原版 lua
-- 全樹沒有定義），對 nil 直接拋錯 -> paginate 外層的 pcall 接住 -> **整份公告**變成錯誤占位。
-- 因此逗號參數個數只允許 0 或 2，且兩段都要 tonumber 得出正數。
-- 第三個以上的逗號不必另外檢查：多出來的逗號一定落在高度那一段裡，tonumber 認不得。
-- 回傳 path, width, height, ok；ok=false 代表形狀不合法，呼叫端應換成占位（讓服主看得出
-- 是哪一張圖壞掉，而不是整份公告死掉）。
-- 不做 trim：MDParser 的原生 tag 白名單不放行含空白的參數，預檢自己產生的 tag 也不含空白。
function NBCore.parseImageTagArguments(arguments)
    if type(arguments) ~= "string" then
        return nil, nil, nil, false
    end
    local firstComma = string.find(arguments, ",", 1, true)
    if firstComma == nil then
        return arguments, nil, nil, true
    end
    local secondComma = string.find(arguments, ",", firstComma + 1, true)
    if secondComma == nil then
        return nil, nil, nil, false
    end
    local width = tonumber(string.sub(arguments, firstComma + 1, secondComma - 1))
    local height = tonumber(string.sub(arguments, secondComma + 1))
    if width == nil or height == nil or width < 1 or height < 1 then
        return nil, nil, nil, false
    end
    return string.sub(arguments, 1, firstComma - 1), width, height, true
end

-- 圖片尺寸夾限（純數學；面板寬高由呼叫端算好傳進來，測試才跑得動）。
-- requested 為 nil 代表公告沒指定尺寸：此時只有「原圖超出上限」才需要縮放。
-- 回傳 nil 代表不需要尺寸參數 -> 產出不帶逗號的 `<IMAGE:路徑>`（既有行為）。
-- 這份夾限是**唯一**的縮放來源：markdown 圖片與服主手寫的原生 tag 都得走它，
-- 否則手寫 `<IMAGE:path,100000,100000>` 的尺寸會被引擎原樣採用（:173-174）。
function NBCore.fitImageSize(naturalWidth, naturalHeight,
        requestedWidth, requestedHeight, maxWidth, maxHeight)
    if type(naturalWidth) ~= "number" or type(naturalHeight) ~= "number"
        or naturalWidth <= 0 or naturalHeight <= 0 then
        return nil
    end
    if type(maxWidth) ~= "number" or type(maxHeight) ~= "number"
        or maxWidth < 32 or maxHeight < 32 then
        return nil
    end

    local targetWidth, targetHeight
    if requestedWidth and requestedHeight then
        targetWidth = requestedWidth
        targetHeight = requestedHeight
    elseif requestedWidth then
        targetWidth = requestedWidth
        targetHeight = math.max(1, math.floor(naturalHeight * requestedWidth / naturalWidth))
    elseif requestedHeight then
        targetHeight = requestedHeight
        targetWidth = math.max(1, math.floor(naturalWidth * requestedHeight / naturalHeight))
    elseif naturalWidth > maxWidth or naturalHeight > maxHeight then
        -- 高度也要看：只比寬度的話，100x5000 這種窄而極高的圖會整份按原始高度畫出來，
        -- 一張圖吃掉整個捲動區。
        targetWidth = naturalWidth
        targetHeight = naturalHeight
    else
        return nil
    end

    if targetWidth > maxWidth then
        targetHeight = math.max(1, math.floor(targetHeight * maxWidth / targetWidth))
        targetWidth = maxWidth
    end
    if targetHeight > maxHeight then
        targetWidth = math.max(1, math.floor(targetWidth * maxHeight / targetHeight))
        targetHeight = maxHeight
    end
    return math.floor(targetWidth), math.floor(targetHeight)
end

-- 組回原生圖片 tag。width/height 任一為 nil 就不寫逗號參數——沒指定尺寸的既有公告
-- 必須產出與以往完全相同的 `<IMAGE:路徑>`。
function NBCore.imageTag(prefix, path, width, height)
    if width == nil or height == nil then
        return prefix .. path .. ">"
    end
    return prefix .. path .. "," .. tostring(width) .. "," .. tostring(height) .. ">"
end

-- ISRichTextPanel.processCommand 對這些字樣做的是「裸子字串比對」而非完整比對，
-- 而各分支之間**互不排他**（都是獨立的 if），所以只要字樣出現在 command 的任何位置
-- ——包含圖片路徑——就會連帶命中那條分支。逐一核對自 42.20.2 的
-- media/lua/client/ISUI/ISRichTextPanel.lua，每一個 string.find(command, "...") 的字面值：
--   :68  PUSHRGB:      :76  POPRGB        :81  RGB:          :88  GHC
--   :94  BHC           :101 RED           :108 ORANGE        :115 GREEN
--   :122 SIZE:         :146 IMAGE:        :180 IMAGECENTRE:  :222 VIDEOCENTRE:
--   :310 INDENT:       :314 JOYPAD:       :343 SETX:         :347 SPACE
-- LINE / BR / H1 / H2 / TEXT / CENTRE / LEFT / RIGHT 走的是 `command == "..."` 完整比對
-- （:17、:23、:29、:38、:47、:57、:61、:65），帶路徑的 command 一定以 "IMAGE:" 開頭、
-- 不可能整串相等，故**不是**危險字樣，不列入。
-- 另外三個不是指令字樣、但同樣會讓帶路徑的 tag 走樣的字元也一併列入：
--   ","：IMAGE 分支看到逗號就 string.split 去拆寬高（:149-154），vs[3] 為 nil 直接拋錯。
--   "<" ">"：paginate 的 tokenizer 以此判定 command 邊界（:462、:468）。
--
-- 依「顏色護欄救不救得回來」分成兩份，因為兩個使用端要的答案不同：
--   COLOR_HAZARDS：只改 self.rgb[currentLine] 與 rgbCurrent（:68-121），
--     PUSHRGB/POPRGB 護欄抵銷得掉 -> **圖照畫、路徑不必改**。
--   COMMAND_HAZARDS：會拆寬高、解析不存在的參數、或改動 x／字型（:122-351），
--     護欄救不了；出現在執行期改不動的路徑（玩家家目錄）時只能整組退回 alt 占位。
-- NBImageCache 用 COMMAND_HAZARDS 判定「快取絕對路徑不可用」，NBPanel 用 COLOR_HAZARDS
-- 判定「這個 tag 要包上顏色護欄」。把顏色類也拿去拒絕快取，等於讓 Windows 帳號叫
-- FRED／GREEN（全大寫才命中）的玩家永遠看不到任何同步圖，而那正是護欄處理得了的情形。
NBCore.COLOR_HAZARDS = {
    "PUSHRGB:", "POPRGB", "RGB:", "GHC", "BHC",
    "RED", "ORANGE", "GREEN",
}

-- SPACE（:347-351）其實只把 x 多推幾個像素、不影響正確性，但為了讓清單維持
-- 「救得回來 / 救不回來」兩類而不必為它開第三類，一併留在拒絕側。
NBCore.COMMAND_HAZARDS = {
    ",", "<", ">",
    "SIZE:", "IMAGE:", "IMAGECENTRE:", "VIDEOCENTRE:",
    "INDENT:", "JOYPAD:", "SETX:", "SPACE",
}

-- 回傳第一個命中的危險字樣（供 log 指出是哪一個），乾淨字串回 nil。
-- hazards 省略時查 COMMAND_HAZARDS（護欄救不了的那一份）。
function NBCore.findCommandHazard(text, hazards)
    if type(text) ~= "string" then
        return nil
    end
    hazards = hazards or NBCore.COMMAND_HAZARDS
    local index
    for index = 1, #hazards do
        local hazard = hazards[index]
        if string.find(text, hazard, 1, true) ~= nil then
            return hazard
        end
    end
    return nil
end

-- 顏色護欄。路徑含危險字樣的圖片 tag 仍然照畫（引擎的 IMAGE 分支不受影響），
-- 但同一個 command 會連帶命中染色分支，把 self.rgb[self.currentLine] 換掉；顏色是存在
-- **每一邏輯行**上、render 時整行套用（ISRichTextPanel.lua:613-617），且未被覆寫的行會
-- 沿用前一行的值，所以圖片之後的文字會整段變色。
-- 抵銷方式（ISRichTextPanel.lua:68-80）：
--   PUSHRGB: 先 table.insert(self.rgbStack, self.rgbCurrent)（:69）把**圖片之前的顏色**存起來；
--   圖片 tag 的危險字樣接著覆寫該行顏色（例如 :101 的 RED）；
--   POPRGB 在堆疊非空時 pop 回來並寫回 self.rgb[self.currentLine]（:76-80）。
-- PUSH 與 POP 之間沒有任何文字，中間那一瞬的顏色畫不出來，因此**這裡填什麼 rgb 值都不影響
-- 最終畫面**（一律被 POP 蓋掉）；填的是 <TEXT> 的預設本文色（:50-52），純粹讓除錯時讀到的值合理。
-- 用堆疊而不是「把顏色寫死回去」正是為了圖片剛好被包在粗體／斜體區段裡的情形：
-- 存的是當下的 rgbCurrent，該區段的顏色也會被原樣保住。
-- **前提是 rgbCurrent 與畫面上看到的顏色一致**：H1／H2 只寫 self.rgb[currentLine]、
-- 從不更新 rgbCurrent（:29-46），所以 MDParser.H1_PREFIX／H2_PREFIX 額外補了一個 <RGB:>
-- 把 rgbCurrent 同步過去；少了那一步，標題行內的圖片 POP 回來的會是上一段本文的顏色，
-- 標題後半段直接掉色（粗體／連結／行內程式碼在標題內也會踩到同一件事）。
-- tag 前後的空白是硬性要求（tokenizer :459-486）。
NBCore.IMAGE_GUARD_PREFIX = " <PUSHRGB:0.7,0.7,0.7> "
NBCore.IMAGE_GUARD_SUFFIX = " <POPRGB> "

-- 組圖片 tag，路徑含顏色類危險字樣時額外包上顏色護欄。
-- 乾淨路徑回傳與 imageTag **完全相同**的字串（既有公告零行為改變）。
-- resolvedPath（選用）：引擎最後真正看到的路徑。伺服器同步圖寫進 richText 的是
-- NBCACHE_<hash> 替身 token（十六進位，永遠乾淨），絕對路徑要到 NBPanel 的 processCommand
-- 覆寫才換回去（NBPanel.lua:250-267），所以危險字樣必須對「換回去之後的字串」判定，
-- 否則玩家家目錄含 RED 時一個護欄都不會包。省略時退回用 path 判定。
function NBCore.imageTagGuarded(prefix, path, width, height, resolvedPath)
    local tag = NBCore.imageTag(prefix, path, width, height)
    if NBCore.findCommandHazard(resolvedPath or path, NBCore.COLOR_HAZARDS) == nil then
        return tag
    end
    return NBCore.IMAGE_GUARD_PREFIX .. tag .. NBCore.IMAGE_GUARD_SUFFIX
end

-- maxUnits（選用）：截長上界。**只消毒不截長是不夠的**——對端可控的欄位（register 的 lang、
-- settings.ini 的 lang=）長度不受限，每 10 秒灌一次超長值就能把 writeLog 撐到 10MB；
-- ZLogger 到 10MB 是整檔截斷而非輪替（ZLogger.java:95-101），會沖掉服主的排查紀錄。
-- 既有呼叫點不傳這個參數 -> 行為完全不變。
function NBCore.sanitizeName(name, maxUnits)
    local sanitized = tostring(name or "")
    -- 控制字元（含 \r\n\t）整個移除，防跨行 log 注入。
    sanitized = string.gsub(sanitized, "%c", "")
    -- log 行是空白分隔的 key=value；PZ username 允許空白與 = |（ServerWorldDatabase.java:763-777），
    -- 換成 _ 防欄位偽造（本 MOD 換了 log 格式，威脅模型不同於原版方括號分欄）。
    sanitized = string.gsub(sanitized, "[ =|]", "_")
    sanitized = string.gsub(sanitized, "%[", "(")
    sanitized = string.gsub(sanitized, "%]", ")")

    if type(maxUnits) ~= "number" or maxUnits < 1 or string.len(sanitized) <= maxUnits then
        return sanitized
    end
    -- 切點若落在代理對中間會產生孤兒 surrogate（Kahlua 的 string index 是 UTF-16 unit），
    -- 比照 NBReader.truncateTitle 退一格。標準 Lua 測試環境是 UTF-8 byte，此分支不會成立。
    local endIndex = maxUnits
    local lastUnit = string.byte(sanitized, endIndex)
    local nextUnit = string.byte(sanitized, endIndex + 1)
    if lastUnit and nextUnit
        and lastUnit >= 55296 and lastUnit <= 56319
        and nextUnit >= 56320 and nextUnit <= 57343 then
        endIndex = endIndex - 1
    end
    -- 尾端加標記，讓服主看得出這行被截過（純 ASCII，Kahlua 安全）。
    return string.sub(sanitized, 1, endIndex) .. "~"
end

return NBCore
