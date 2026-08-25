if not NBCore then
    require "NoticeBoard/NBCore"
end

local Core = NBCore
if not Core then
    error("NoticeBoard/NBCore failed to load")
end

MDParser = MDParser or {}

-- 【每個 tag 前後都必須有空白——這是硬性要求，不是排版偏好】
-- ISRichTextPanel:paginate 以空白切 token（:459）；只要一個 token 同時含 < 與 >，整個 token
-- 就被當成 command，只有 <> 之間的內容送 processCommand，**< 前面的文字直接被丟棄**（:468-486）。
-- 因此 `文字<TAG>` 會讓「文字」消失。而尾段若沒有後續空白，會走 :533-557 直接當字面文字印出。
-- vanilla 自己也是這樣處理：`leftText:gsub("\n", " <LINE> ")`（:445），前後都補空白。
MDParser.BOLD_PREFIX = " <PUSHRGB:1,0.85,0.4> "
MDParser.BOLD_SUFFIX = " <POPRGB> "
-- 斜體只能用顏色表示：ISRichTextPanel 的 <SIZE:> 只切換 UIFont 列舉（:122-144），
-- 沒有任何斜體或字重變體，drawText 也沒有樣式參數（:672）。
MDParser.ITALIC_PREFIX = " <PUSHRGB:0.6,0.9,0.6> "
MDParser.ITALIC_SUFFIX = " <POPRGB> "
-- 行內程式碼同理：引擎沒有等寬字型也沒有行內底色原語，只能換色。
MDParser.CODE_PREFIX = " <PUSHRGB:1,0.7,0.85> "
MDParser.CODE_SUFFIX = " <POPRGB> "
MDParser.LINK_PREFIX = " <PUSHRGB:0.35,0.65,1> "
MDParser.LINK_SUFFIX = " <POPRGB> "
MDParser.LINE_SEPARATOR = " <LINE> "
MDParser.ERROR_PLACEHOLDER = "[Markdown parse error]"

-- 【顏色標記邊界的視覺間距】ISRichTextPanel 在遇到 command token 時 `lines = lines + 1`
-- 開新 chunk（:462-470），而新 chunk 的起點直接接前一個 chunk 的右邊緣
-- （:529 `x = self.lineX[lines] + pixLen`）；只有**同一** chunk 內的 token 之間才會補
-- 單一空白（:498-500）。所以 `文字：<PUSHRGB>=600x200<POPRGB>` 渲染出來是緊貼的，
-- CJK 接技術符號時特別難讀（`顯示尺寸：=600x200`）。
-- 服主自己在 markdown 裡打空格也救不了：token 進 chunk 前一律 `string.trim`（:497）。
-- 唯一能存活的是不匹配 Lua `%s` 的空白——U+00A0（NBSP）。原版法文 UI 翻譯用了 30 處
-- （media/lua/shared/Translate/FR/UI.json，法式排版標點前要 NBSP），證明字型有 glyph。
-- 用 string.char 組出：.lua 原始碼裡的非 ASCII 字面會被 Kahlua 逐字元截成單一位元組。
MDParser.NBSP = string.char(0xC2, 0xA0)

-- <LINE> 只換行；font/orient/rgb/indent 都跨行持續（processCommand:29-63、311、render:619-624），
-- 故每個邏輯行的第一段必須自報樣式，否則標題後正文繼承大字置中、清單後正文持續縮排（AC5 會失敗）。
MDParser.LINE_RESET = " <TEXT> <INDENT:0> "
-- <H1>／<H2> 只寫 self.rgb[currentLine]，**不更新 self.rgbCurrent**（:29-46；<TEXT>:53、
-- <RGB:>:87 才會更新）。而 PUSHRGB 存進堆疊的是 rgbCurrent（:69）、POPRGB 把它寫回該行（:76-80），
-- 所以標題行內只要出現任何 PUSHRGB/POPRGB 配對（粗體、斜體、行內程式碼、連結，以及路徑含
-- 顏色字樣的圖片護欄），POP 回來的都是**上一段本文的顏色**，標題後半段整段掉色。
-- 補一個同色的 <RGB:> 把 rgbCurrent 同步到標題色即可（顏色值取自引擎 :32-34／:41-43，
-- 畫面完全不變），H3-H6 本來就是這個形狀。
MDParser.H1_PREFIX = " <H1> <RGB:1,1,1> <INDENT:0> "
-- 含圖片的 `#` 標題改走這一條：<H1> 寫死的置中（:30）與圖片排版是**兩套座標系**。
-- render 的置中分支算 lineLength 時只累加 MeasureStringX（:644-648）——圖片寬度恆為 0；
-- 文字畫在 lineX + self.lineX[c]（:665），圖片卻在**另一個迴圈**用 imageX[c] + marginLeft
-- 畫（:595），兩者差一個置中位移，於是文字整段右移、圖片留在最左，圖不是壓在標題文字上
-- 就是跑到文字左邊。<H2>（:39 orient=left）、H3-H6、一般本文行都沒有這個問題。
-- 靠左之後兩者共用同一套座標，圖文回到同一行的正確相對位置。逐段理由（全部對照
-- ISRichTextPanel.lua）：
--   <LEFT>（:61-63）**不可省略**：render 的 orient 是**跨行沿用**的——迴圈外 :604
--     `local orient = "left"`，迴圈內 :619 只有 self.orient[c] 非 nil 時才更新。省掉它，
--     這一行的 orient 為 nil，會沿用前一行；前一行剛好是個 `#` 標題時仍然置中，等於沒修。
--   <SIZE:large>（:122-144；:131 設 UIFont.Large、:143 寫 fonts[currentLine]）與 <H1>
--     的 :35-36 是同一個字型。
--   <RGB:1,1,1>（:81-87）與 <H1> 的 :32-34 同色，且會同步 rgbCurrent（:87）——與上面
--     H1_PREFIX／H2_PREFIX 補 <RGB:> 的既有修正同一套理由，不可退回。
--   <INDENT:0> 維持與 H1_PREFIX 一致。
MDParser.H1_IMAGE_PREFIX = " <LEFT> <SIZE:large> <RGB:1,1,1> <INDENT:0> "
MDParser.H2_PREFIX = " <H2> <RGB:0.8,0.8,0.8> <INDENT:0> "
-- H3 之後沒有字級可用：<SIZE:> 只認 small/medium/large/intro/credits1/credits2（:122-144），
-- 而 small 就是本文預設的 UIFont.NewSmall（:765），intro/credits 是裝飾字型。
-- 所以 H3 與 H2 同字級只換色，H4-H6 一律本文字級、只能靠亮度階梯區分。
MDParser.H3_PREFIX = " <TEXT> <SIZE:medium> <RGB:0.55,0.85,0.85> <INDENT:0> "
MDParser.H4_PREFIX = " <TEXT> <RGB:1,0.97,0.88> <INDENT:0> "
MDParser.H5_PREFIX = " <TEXT> <RGB:0.88,0.85,0.78> <INDENT:0> "
MDParser.H6_PREFIX = " <TEXT> <RGB:0.78,0.75,0.68> <INDENT:0> "
MDParser.HORIZONTAL_RULE = MDParser.LINE_RESET
    .. " <RGB:0.4,0.4,0.4> " .. string.rep("-", 48) .. " <RGB:1,1,1> "

local HEADING_PREFIX = {
    MDParser.H1_PREFIX,
    MDParser.H2_PREFIX,
    MDParser.H3_PREFIX,
    MDParser.H4_PREFIX,
    MDParser.H5_PREFIX,
    MDParser.H6_PREFIX,
}

-- 巢狀縮排上限 4 層：再深下去內容區會被縮排吃光（面板內容寬約 950px）。
local MAX_LIST_DEPTH = 4
local INDENT_TAG = {
    "<INDENT:0> ", "<INDENT:20> ", "<INDENT:40> ", "<INDENT:60> ", "<INDENT:80> ",
}
-- 程式碼區塊：把行首空白數換算成 <INDENT:>（processCommand:310-312），
-- 這是唯一能救回行首縮排的辦法——引擎會 trim 每個 token 再以單一空白重組（:497-499、513、542）。
local CODE_INDENT_TAG = {
    "<INDENT:20> ", "<INDENT:28> ", "<INDENT:36> ", "<INDENT:44> ",
    "<INDENT:52> ", "<INDENT:60> ", "<INDENT:68> ", "<INDENT:76> ",
    "<INDENT:84> ", "<INDENT:92> ", "<INDENT:100> ", "<INDENT:108> ",
    "<INDENT:116> ",
}
local CODE_COLOR = "<RGB:0.72,0.86,0.95> "
local QUOTE_COLOR = "<RGB:0.6,0.6,0.6> "
-- 引言記號刻意用 ASCII 直線而非 '>'：'>' 會被 escapeRichText 轉成 &gt;（NBCore.escapeRichText），
-- 雖然引擎會在 :492 還原，但多一層轉義就多一個出錯面。
local QUOTE_MARK = "| "

-- `%s+$` 的 gsub 在長空白 run 上退化成 O(n^2)：每個起點都會把整段空白吃完再逐格回溯。
-- trim 與 splitHardBreak 是每一行都會走的路徑，故自己往回掃。（`^%s+` 有錨點，只試位置 1，安全。）
local function trimTrailing(text)
    local length = string.len(text)
    local stop = length
    while stop > 0 do
        local value = string.byte(text, stop)
        if value ~= 32 and (value < 9 or value > 13) then
            break
        end
        stop = stop - 1
    end
    if stop == length then
        return text
    end
    return string.sub(text, 1, stop)
end

local function trim(text)
    text = string.gsub(text, "^%s+", "")
    return trimTrailing(text)
end

local function runLength(text, position, character)
    local count = 0
    while string.sub(text, position + count, position + count) == character do
        count = count + 1
    end
    return count
end

local function isBlankChar(character)
    return character == "" or character == " " or character == "\t"
end

-- UTF-8 續位元組（>=128）一律當成文字字元，否則 CJK 會被誤判成 emphasis 邊界。
local function isWordChar(character)
    if character == "" then
        return false
    end
    local value = string.byte(character)
    if value >= 48 and value <= 57 then
        return true
    end
    if value >= 65 and value <= 90 then
        return true
    end
    if value >= 97 and value <= 122 then
        return true
    end
    return value >= 128
end

local function isAsciiPunctuation(value)
    if value >= 33 and value <= 47 then
        return true
    end
    if value >= 58 and value <= 64 then
        return true
    end
    if value >= 91 and value <= 96 then
        return true
    end
    return value >= 123 and value <= 126
end

-- Kahlua 的數字是 double，直接 `.. number` 有機會印成 "20.0"，故自己轉字串。
local function integerToString(value)
    value = math.floor(value)
    if value <= 0 then
        return "0"
    end
    local digits = ""
    while value > 0 do
        local remainder = value - math.floor(value / 10) * 10
        digits = string.sub("0123456789", remainder + 1, remainder + 1) .. digits
        value = math.floor(value / 10)
    end
    return digits
end

-- ---------------------------------------------------------------------------
-- 反斜線逸出：先把 `\<punct>` 換成不可能出現在公告裡的哨兵（\1 <byte> \2），
-- 讓後續所有區塊／行內比對都看不到那個字元，最後輸出時才還原。
-- 還原分三種模式，因為同一個字元在三個位置要長成不同樣子：
--   plain -> 原字元（link.text / image path 這種要與畫面可見文字比對的欄位）
--   text  -> 已轉義字元（`\<` 必須還原成 &lt; 而不是 <，否則會在輸出裡塞回一個活的 <，
--            與後面的 > 在同一 token 內配對成 command，前面的文字被引擎丟棄 :462,468）
--   code  -> 反斜線保留（CommonMark 規定程式碼內不做反斜線逸出）
-- ---------------------------------------------------------------------------
local SENTINEL_OPEN = string.char(1)
local SENTINEL_CLOSE = string.char(2)
local SENTINEL_PATTERN = SENTINEL_OPEN .. "(%d+)" .. SENTINEL_CLOSE

local function encodeBackslashEscapes(text)
    if string.find(text, "\\", 1, true) == nil then
        return text
    end

    local result = {}
    local position = 1
    while true do
        local slash = string.find(text, "\\", position, true)
        if not slash then
            result[#result + 1] = string.sub(text, position)
            break
        end
        result[#result + 1] = string.sub(text, position, slash - 1)
        local following = string.sub(text, slash + 1, slash + 1)
        if following ~= "" and isAsciiPunctuation(string.byte(following)) then
            result[#result + 1] = SENTINEL_OPEN
                .. integerToString(string.byte(following)) .. SENTINEL_CLOSE
            position = slash + 2
        else
            result[#result + 1] = "\\"
            position = slash + 1
        end
    end
    return table.concat(result)
end

local function decodeEscapes(text, mode)
    if string.find(text, SENTINEL_OPEN, 1, true) == nil then
        return text
    end
    return (string.gsub(text, SENTINEL_PATTERN, function(digits)
        local character = string.char(tonumber(digits))
        if mode == "plain" then
            return character
        end
        if mode == "code" then
            character = "\\" .. character
        end
        return Core.escapeRichText(character)
    end))
end

-- 顯式允許清單，取代「任意大寫 tag」。ISRichTextPanel.processCommand 用子字串比對
-- （"IMAGE:" 可被 <XIMAGE:> 命中），放行任意大寫 tag 會讓 <VIDEOCENTRE:../> 這類
-- 未預期標記逃過 NBPanel 的 getTexture 預檢並觸發 nil 索引/路徑穿越。
local ALLOWED_BARE_TAG = {
    LINE = true, BR = true, H1 = true, H2 = true, TEXT = true,
    CENTRE = true, LEFT = true, RIGHT = true, SPACE = true, POPRGB = true,
}
local ALLOWED_PARAM_TAG = {
    RGB = true, PUSHRGB = true, SIZE = true, INDENT = true,
    IMAGE = true, IMAGECENTRE = true,
}

-- <SIZE:> 認得的字型名（ISRichTextPanel.lua:125-142）。清單外的值在引擎裡本來就沒有任何
-- 效果，擋掉不會少任何功能。
local SIZE_VALUE = {
    small = true, medium = true, large = true,
    intro = true, credits1 = true, credits2 = true,
}

-- 帶參數 tag 的參數形狀。放行形狀不合的 tag 會讓引擎在 processCommand 內對 nil
-- 做算術／字串操作而拋錯，pcall 在 paginate 那層接住 -> **整份公告**變成錯誤占位：
--   <RGB:...> / <PUSHRGB:...>：引擎逐一 tonumber(rgb[1..3])（ISRichTextPanel.lua:70-74、82-86），
--     少一段就把 self.rgb[currentLine] 的分量設成 nil，render 再把它當顏色送進 drawText（:665、:672）。
--   <INDENT:n>：self.indent = tonumber(string.sub(command, 8))（:311），非數字時 render 端
--     `x = self.indent`（:515）之後的加法（:519）直接對 nil 運算。
--   <SIZE:v>：v 完全不受限，而引擎對每條指令做的是**子字串**比對而非完整比對
--     （:68-347 全是 string.find）。於是 <SIZE:INDENT:zz> 這種 tag 名合法、參數段藏著另一條
--     指令觸發字樣的寫法會同時命中 SIZE 與 INDENT 兩個分支——與被擋下的 <INDENT:abc> 是
--     同一個崩潰，只是繞過了檢查。<SIZE:IMAGE:x> 同理（getTexture("MAGE:x") -> nil:getWidth()），
--     而且 NBPanel 的預檢找的是字面 "<IMAGE:"，接不到它。改成只放行引擎認得的六個字型名。
-- RGB／PUSHRGB／INDENT 不必另外查危險字樣：它們的每一段都要 tonumber 得出數字，
-- 而危險字樣全是大寫字母，數字裡不可能出現。
-- <IMAGE:> / <IMAGECENTRE:> 刻意不在這裡擋：它們的形狀由 NBPanel 的預檢負責（那裡才驗得了
-- 貼圖是否存在），壞掉的換成占位，服主看得出是哪一張圖壞掉。
local function paramTagShapeOk(name, parameters)
    if name == "RGB" or name == "PUSHRGB" then
        local red, green, blue = string.match(parameters, "^([^,]*),([^,]*),([^,]*)$")
        return red ~= nil and tonumber(red) ~= nil
            and tonumber(green) ~= nil and tonumber(blue) ~= nil
    end
    if name == "INDENT" then
        return tonumber(parameters) ~= nil
    end
    if name == "SIZE" then
        return rawget(SIZE_VALUE, parameters) == true
    end
    return true
end

-- 參數內不得含空白：tokenizer 以空白切 token，`<RGB:1, 0, 0>` 會被切成
-- `<RGB:1,`（有 < 沒 >，當字面文字印出）＋ `0,` ＋ `0>`，整段版面壞掉。
-- 含空白時不放行，改走轉義變成可見文字，服主看得到自己打錯了。
local function isNativeRichTextTag(candidate)
    local bare = string.match(candidate, "^<([A-Z][A-Z0-9_]*)>$")
    if bare then
        return rawget(ALLOWED_BARE_TAG, bare) == true
    end
    local name, parameters = string.match(candidate, "^<([A-Z][A-Z0-9_]*):([^<>%s]*)>$")
    return name ~= nil and rawget(ALLOWED_PARAM_TAG, name) == true
        and paramTagShapeOk(name, parameters)
end

-- 原生大寫 RichText tag 原樣保留；其他 angle bracket 一律轉義。
local function escapePreservingNativeTags(text)
    local result = {}
    local position = 1

    while position <= string.len(text) do
        local tagStart = string.find(text, "<", position, true)
        if not tagStart then
            result[#result + 1] = Core.escapeRichText(string.sub(text, position))
            break
        end

        if tagStart > position then
            result[#result + 1] = Core.escapeRichText(string.sub(text, position, tagStart - 1))
        end

        local tagEnd = string.find(text, ">", tagStart + 1, true)
        if tagEnd then
            local candidate = string.sub(text, tagStart, tagEnd)
            if isNativeRichTextTag(candidate) then
                -- 放行的原生 tag 同樣要前後補空白，否則會吃掉它前面的文字
                result[#result + 1] = " " .. candidate .. " "
                position = tagEnd + 1
            else
                result[#result + 1] = "&lt;"
                position = tagStart + 1
            end
        else
            result[#result + 1] = Core.escapeRichText(string.sub(text, tagStart))
            break
        end
    end

    if text == "" then
        return ""
    end
    return table.concat(result)
end

local function escapeText(text)
    return decodeEscapes(escapePreservingNativeTags(text), "text")
end

local function escapeCode(text)
    return decodeEscapes(Core.escapeRichText(text), "code")
end

local function plainText(text)
    return decodeEscapes(text, "plain")
end

-- ---------------------------------------------------------------------------
-- 行內 token 搜尋器。每個搜尋器都必須是「從 from 位置起找下一個」的形式，
-- renderInline 才能沿用同一套快取策略（見該函式註解）。
-- ---------------------------------------------------------------------------

local function findImage(text, from)
    return string.find(text, "!%[([^%]]-)%]%(([^%)]-)%)", from)
end

-- 尺寸擴充語法（業界通用，不在 CommonMark 核心）：`path =600x200` / `=600x` / `=x200`。
-- 尺寸與路徑之間至少一個空白，沒有 `=WxH` 尾段時原樣回傳 -> 既有行為完全不變。
-- 上界只是擋掉荒謬輸入；真正的夾限在 NBPanel（要知道面板寬高才算得出來）。
local MAX_IMAGE_DIMENSION = 100000

-- `=600x200` / `=600x` / `=x200` 的形狀（至少要有一邊給了數字）。
-- 兩端都錨定、只套在「最後一個 = 之後」的短尾段上，沒有回溯空間。
local function isSizeSuffix(suffix)
    local widthDigits, heightDigits = string.match(suffix, "^=(%d*)x(%d*)$")
    return widthDigits ~= nil and (widthDigits ~= "" or heightDigits ~= "")
end

-- 回傳 path, width, height。path 為 nil = 這串根本不是合法路徑，呼叫端退回顯示原始 markdown。
local function splitImageSize(target)
    -- 尺寸候選＝最後一段空白分隔的 token，往回掃找分隔點。刻意**不用**
    -- `^(.-)%s+=(%d*)x(%d*)$`：非貪婪前綴配上貪婪 `%s+`，在「路徑含長空白 run」的輸入上
    -- 每個起點都會把空白吃完再逐格回溯，退化成 O(n^2)，而這條路徑每個 image token 都會走。
    -- 同一圈順便記下最後一個 '='（同樣是往回掃，維持單趟線性）。
    local separator = nil
    local equals = nil
    local index
    for index = string.len(target), 1, -1 do
        local value = string.byte(target, index)
        if value == 32 or (value >= 9 and value <= 13) then
            separator = index
            break
        end
        if equals == nil and value == 61 then
            equals = index
        end
    end
    if separator == nil then
        -- 沒有空白 -> 不是合法尺寸語法。但 `x.png=600x200`（漏打空白）是最常見的錯字，
        -- 當成路徑會靜默變成「貼圖找不到」的 [替代文字] 占位——與「還沒同步完」「圖檔不存在」
        -- 的畫面完全一樣，而那兩種都有 log，只有這種一行都沒有。
        -- 其他寫錯形式（`=0x200`、`=600X200`、`= 600x200`）因為路徑殘留空白而退回顯示
        -- 原始 markdown，服主看得見；漏空白也走同一條政策。
        -- 只看**最後一個** '=' 之後的尾段，所以 `a=1x2.png` 這種真的含 '=' 的檔名不會誤判
        -- （尾段是 `=1x2.png`，形狀不符）。
        if equals ~= nil and isSizeSuffix(string.sub(target, equals)) then
            return nil, nil, nil
        end
        return target, nil, nil
    end

    local widthDigits, heightDigits = string.match(
        string.sub(target, separator + 1), "^=(%d*)x(%d*)$")
    if widthDigits == nil or (widthDigits == "" and heightDigits == "") then
        return target, nil, nil
    end

    local path = string.sub(target, 1, separator - 1)
    local width = tonumber(widthDigits)
    local height = tonumber(heightDigits)
    if (width ~= nil and (width < 1 or width > MAX_IMAGE_DIMENSION))
        or (height ~= nil and (height < 1 or height > MAX_IMAGE_DIMENSION)) then
        return target, nil, nil
    end
    return trimTrailing(path), width, height
end

local function findStrike(text, from)
    return string.find(text, "~~(.-)~~", from)
end

-- 行內程式碼：開頭 n 個反引號，收尾必須「剛好」也是 n 個。
-- 某個長度找不到收尾就記進 failed，避免同長度的每個開頭都再全掃一次（退化成 O(n^2)）。
local function findCode(text, from)
    local length = string.len(text)
    local failed = {}
    local position = from
    while position <= length do
        local start = string.find(text, "`", position, true)
        if start == nil then
            return nil
        end
        local count = runLength(text, start, "`")
        if not failed[count] then
            local searchPosition = start + count
            local closeAt = nil
            while true do
                local candidate = string.find(text, "`", searchPosition, true)
                if candidate == nil then
                    break
                end
                local candidateCount = runLength(text, candidate, "`")
                if candidateCount == count then
                    closeAt = candidate
                    break
                end
                searchPosition = candidate + candidateCount
            end
            if closeAt then
                return start, closeAt + count - 1, string.sub(text, start + count, closeAt - 1)
            end
            failed[count] = true
        end
        position = start + count
    end
    return nil
end

-- Emphasis（* 與 _）。回傳 start, stop, inner, level（1=斜體 2=粗體 3=粗斜體）。
-- 簡化版 CommonMark 規則：開頭 delimiter 後不得接空白、收尾 delimiter 前不得是空白；
-- `_` 另外要求兩側非文字字元，否則 snake_case_name 會被吃掉。
-- failedLevel：某個 level 找不到收尾時，之後的開頭只會更靠右，收尾集合是子集，
-- 所以 level 更大的開頭一定也失敗——直接跳過，把最壞情況壓在 O(3n)。
local function makeEmphasisFinder(character, guardWord)
    return function(text, from)
        local length = string.len(text)
        local failedLevel = 4
        local position = from
        while position <= length do
            local start = string.find(text, character, position, true)
            if start == nil then
                return nil
            end
            local count = runLength(text, start, character)
            local canOpen = count <= 3 and count < failedLevel
            if canOpen then
                canOpen = not isBlankChar(string.sub(text, start + count, start + count))
            end
            if canOpen and guardWord then
                local before = ""
                if start > 1 then
                    before = string.sub(text, start - 1, start - 1)
                end
                canOpen = not isWordChar(before)
            end

            if canOpen then
                local searchPosition = start + count
                local closeAt = nil
                while true do
                    local candidate = string.find(text, character, searchPosition, true)
                    if candidate == nil then
                        break
                    end
                    local candidateCount = runLength(text, candidate, character)
                    if candidateCount >= count then
                        local ok = not isBlankChar(string.sub(text, candidate - 1, candidate - 1))
                        if ok and guardWord then
                            ok = not isWordChar(
                                string.sub(text, candidate + candidateCount,
                                    candidate + candidateCount))
                        end
                        if ok then
                            closeAt = candidate
                            break
                        end
                    end
                    searchPosition = candidate + candidateCount
                end
                if closeAt then
                    return start, closeAt + count - 1,
                        string.sub(text, start + count, closeAt - 1), count
                end
                if count < failedLevel then
                    failedLevel = count
                end
                if failedLevel <= 1 then
                    return nil
                end
            end
            position = start + count
        end
        return nil
    end
end

local findEmphasisStar = makeEmphasisFinder("*", false)
local findEmphasisUnderscore = makeEmphasisFinder("_", true)

-- 索引必須與 INLINE_FINDER 一致；3 與 4（* 與 _）共用 emphasis 分支，故沒有具名常數。
local KIND_IMAGE = 1
local KIND_CODE = 2
local KIND_STRIKE = 5
local INLINE_FINDER = {
    findImage, findCode, findEmphasisStar, findEmphasisUnderscore, findStrike,
}
local INLINE_KIND_COUNT = #INLINE_FINDER

local renderInline

renderInline = function(text, state, lineNumber)
    local result = {}
    local position = 1
    local textLength = string.len(text)
    -- 快取每一種 token 的搜尋結果：只在快取落後於 position（被消耗或跳過）時重搜。
    -- 否則單行大量 image token 而無其他 token 時，其餘搜尋器每輪重掃整條剩餘字串 -> O(n^2)。
    -- 新增行內語法一律加進 INLINE_FINDER，不要在迴圈裡直接 string.find。
    local cacheStart = {}
    local cacheStop = {}
    local cacheFirst = {}
    local cacheSecond = {}
    local exhausted = {}

    while position <= textLength do
        local kind
        local best = nil
        for kind = 1, INLINE_KIND_COUNT do
            if not exhausted[kind] then
                local start = cacheStart[kind]
                if start == nil or start < position then
                    local newStart, newStop, first, second =
                        INLINE_FINDER[kind](text, position)
                    if newStart == nil then
                        exhausted[kind] = true
                        cacheStart[kind] = nil
                    else
                        cacheStart[kind] = newStart
                        cacheStop[kind] = newStop
                        cacheFirst[kind] = first
                        cacheSecond[kind] = second
                    end
                end
                local current = cacheStart[kind]
                if current ~= nil and (best == nil or current < cacheStart[best]) then
                    best = kind
                end
            end
        end

        if not best then
            result[#result + 1] = escapeText(string.sub(text, position))
            break
        end

        local tokenStart = cacheStart[best]
        local tokenStop = cacheStop[best]
        if tokenStart > position then
            result[#result + 1] = escapeText(string.sub(text, position, tokenStart - 1))
        end

        if best == KIND_IMAGE then
            local path, imageWidth, imageHeight =
                splitImageSize(trim(plainText(cacheSecond[KIND_IMAGE])))
            -- 路徑內含空白同樣不行：`<IMAGE:a b.png>` 會被 tokenizer 切成兩個 token，
            -- 前半有 < 沒 > 直接當字面文字印出。退回顯示原始 markdown，讓服主看得出打錯。
            -- path 為 nil 是 splitImageSize 判定的「寫壞的尺寸語法」，同一條政策。
            if path == nil or path == "" or string.find(path, "[<>%s]") then
                result[#result + 1] = escapeText(string.sub(text, tokenStart, tokenStop))
            else
                -- 這裡放的是**唯一佔位 token**，不是最終的 <IMAGE:路徑>：
                -- 服主可以在同一份公告裡手寫一個與 markdown 圖片完全相同的 <IMAGE:路徑>，
                -- NBPanel 若靠 tag 文字找 occurrence 就會把尺寸套到錯的那張身上
                -- （`<IMAGE:a> ![x](a =100x50)` 會讓尺寸落到手寫的那張）。
                -- token 的形狀要求：前後補空白、內部無空白（tokenizer :459-486）；
                -- NBIMG 不命中 processCommand 的任何比對分支（ISRichTextPanel.lua:17-352），
                -- 萬一預檢沒接到也只是不畫東西，不會拋錯。服主自己寫的 <NBIMG:1> 不在
                -- ALLOWED_PARAM_TAG 內，會被轉義成可見文字，不可能與這裡相撞。
                -- 真正的 <IMAGE:> tag 由 NBPanel:preflightImages 換上去：markdown 的 ![]()
                -- 是靠左的行內元素，故用 IMAGE 而非會強制置中的 IMAGECENTRE；
                -- <IMAGE:> 的垂直位置（imageY = y + (lineHeight - lineImageHeight)/2，
                -- ISRichTextPanel.lua:172）會算出大負數，由 NBLinkRichTextPanel:processCommand
                -- 在呼叫原生實作後修正，見 NBPanel.lua。
                local imageIndex = #state.images + 1
                local tag = "<NBIMG:" .. integerToString(imageIndex) .. ">"
                result[#result + 1] = " " .. tag .. " "
                state.images[imageIndex] = {
                    alt = plainText(cacheFirst[KIND_IMAGE]),
                    path = path,
                    tag = tag,
                    line = lineNumber,
                    -- 沒寫尺寸時是 nil，NBPanel 據此維持既有的自動縮放行為
                    width = imageWidth,
                    height = imageHeight,
                }
            end
        elseif best == KIND_CODE then
            -- 程式碼內不再解析任何行內語法，且 < > 一律轉義。
            -- NBSP 墊在**上色區內側**（見 MDParser.NBSP）：跟著程式碼一起變色所以看不出來，
            -- 但撐出與相鄰 CJK 的間距，也一起進 MeasureStringX、換行寬度照樣算對。
            result[#result + 1] = MDParser.CODE_PREFIX
                .. MDParser.NBSP
                .. escapeCode(cacheFirst[KIND_CODE])
                .. MDParser.NBSP
                .. MDParser.CODE_SUFFIX
        elseif best == KIND_STRIKE then
            -- PZ RichText 沒有刪除線效果（drawText 無此參數，:672），只能吃掉標記顯示純文字
            result[#result + 1] = renderInline(cacheFirst[KIND_STRIKE], state, lineNumber)
        else
            local level = cacheSecond[best]
            local inner = renderInline(cacheFirst[best], state, lineNumber)
            if level == 1 then
                result[#result + 1] = MDParser.ITALIC_PREFIX .. inner .. MDParser.ITALIC_SUFFIX
            elseif level == 2 then
                result[#result + 1] = MDParser.BOLD_PREFIX .. inner .. MDParser.BOLD_SUFFIX
            else
                -- PUSHRGB 是堆疊（:68-80），巢狀後內層顏色勝出，粗斜體視覺上只看得到斜體色
                result[#result + 1] = MDParser.BOLD_PREFIX .. MDParser.ITALIC_PREFIX
                    .. inner .. MDParser.ITALIC_SUFFIX .. MDParser.BOLD_SUFFIX
            end
        end
        position = tokenStop + 1
    end

    if text == "" then
        return ""
    end
    return table.concat(result)
end

-- autolink `<https://...>`。注意**不是**靠 pattern 與「原生大寫 tag 白名單」互斥擋下來的：
-- 兩者其實會重疊——`<HTTPS://A.EXAMPLE/X>` 完全符合白名單的
-- `^<([A-Z][A-Z0-9_]*):[^<>%s]*>$`（name = HTTPS）。真正把它擋住的是 ALLOWED_PARAM_TAG
-- 這張查表。往那張表加名字前先確認新名字不會意外收下畸形參數。
-- scheme 限 http/https，與 NBPanel 的連結安全政策一致。
local function findAutolink(text, from)
    local position = from
    while true do
        local start, stop, uri = string.find(text, "<(%a[%w%+%.%-]*://[^%s<>]*)>", position)
        if not start then
            return nil
        end
        local scheme = string.match(uri, "^(%a[%w%+%.%-]*)://")
        if scheme and (string.lower(scheme) == "http" or string.lower(scheme) == "https") then
            return start, stop, uri, uri
        end
        position = start + 1
    end
end

local function findBracketLink(text, from)
    local searchPosition = from
    while searchPosition <= string.len(text) do
        local linkStart, linkEnd, label, url = string.find(
            text,
            "%[([^%]]-)%]%(([^%)]-)%)",
            searchPosition
        )
        if not linkStart then
            return nil
        end

        local previous = ""
        if linkStart > 1 then
            previous = string.sub(text, linkStart - 1, linkStart - 1)
        end
        if previous ~= "!" and trim(url) ~= "" then
            return linkStart, linkEnd, label, trim(url)
        end
        searchPosition = linkEnd + 1
    end
    return nil
end

local LINK_FINDER = { findBracketLink, findAutolink }

-- 與 renderInline 同一套快取策略：每種搜尋器只在快取落後於 from 時重掃，掃不到就標 done。
-- 文件裡缺哪一種，那一種若每輪都重掃剩餘字串就是 O(n^2)——段落合併之後，
-- 「連續 N 行、每行一個連結」會被併成單一超長邏輯行，正好餵中這條路徑。
local function newLinkCache()
    return { start = {}, stop = {}, label = {}, url = {}, done = {} }
end

local function findNextLink(text, from, cache)
    local kind
    for kind = 1, #LINK_FINDER do
        if not cache.done[kind] and (cache.start[kind] == nil or cache.start[kind] < from) then
            local start, stop, label, url = LINK_FINDER[kind](text, from)
            if start == nil then
                cache.done[kind] = true
                cache.start[kind] = nil
            else
                cache.start[kind] = start
                cache.stop[kind] = stop
                cache.label[kind] = label
                cache.url[kind] = url
            end
        end
    end

    local best = nil
    for kind = 1, #LINK_FINDER do
        if cache.start[kind] ~= nil
            and (best == nil or cache.start[kind] < cache.start[best]) then
            best = kind
        end
    end
    if best == nil then
        return nil
    end
    return cache.start[best], cache.stop[best], cache.label[best], cache.url[best]
end

-- 行內程式碼區間表（start1, stop1, start2, stop2, ...）。
-- renderContentLine 必須在 renderInline **之前**就掃連結（連結要獨占邏輯行），
-- 所以 findCode 沒機會先手，連結搜尋得自己跳過落在 code span 內的位置；
-- 否則 `` `[a](b)` `` 會被拆成一個可點擊連結、兩個反引號漏成可見文字，
-- 而且多個 code span 的分隔符會互相錯配（CommonMark：code span 內不解析任何行內語法）。
local function codeSpanBounds(text)
    if string.find(text, "`", 1, true) == nil then
        return nil
    end
    local bounds = nil
    local from = 1
    while true do
        local start, stop = findCode(text, from)
        if start == nil then
            return bounds
        end
        bounds = bounds or {}
        bounds[#bounds + 1] = start
        bounds[#bounds + 1] = stop
        from = stop + 1
    end
end

local function appendLogicalLine(state, text)
    state.lines[#state.lines + 1] = text
end

local function renderContentLine(content, prefix, state)
    local position = 1
    local prefixPending = prefix
    local emitted = false

    local function emitInline(fragment)
        local lineNumber = #state.lines + 1
        appendLogicalLine(state, prefixPending .. renderInline(fragment, state, lineNumber))
        prefixPending = ""
        emitted = true
    end

    local function emitLink(label, url)
        local display = trim(label)
        if display == "" then
            display = url
        end

        local lineNumber = #state.lines + 1
        local rendered = MDParser.LINK_PREFIX
            .. escapeText(display)
            .. MDParser.LINK_SUFFIX
        appendLogicalLine(state, prefixPending .. rendered)
        prefixPending = ""
        state.links[#state.links + 1] = {
            text = plainText(display),
            url = plainText(url),
            line = lineNumber,
        }
        emitted = true
    end

    local bounds = codeSpanBounds(content)
    local boundIndex = 1
    local cache = newLinkCache()
    local searchFrom = 1
    while searchFrom <= string.len(content) do
        local linkStart, linkEnd, label, url = findNextLink(content, searchFrom, cache)
        if not linkStart then
            break
        end

        -- bounds 與 searchFrom 都只往前走，所以這個推進是攤還線性的
        while bounds ~= nil and bounds[boundIndex] ~= nil
            and bounds[boundIndex + 1] < linkStart do
            boundIndex = boundIndex + 2
        end
        if bounds ~= nil and bounds[boundIndex] ~= nil and bounds[boundIndex] <= linkStart then
            -- 連結落在行內程式碼內：整個 code span 跳過，內容留給 renderInline 當程式碼渲染
            searchFrom = bounds[boundIndex + 1] + 1
        else
            local before = trim(string.sub(content, position, linkStart - 1))
            if before ~= "" then
                emitInline(before)
            end
            emitLink(label, url)
            position = linkEnd + 1
            searchFrom = position
        end
    end

    local remainder = string.sub(content, position)
    if emitted then
        remainder = trim(remainder)
    end
    if remainder ~= "" or not emitted then
        emitInline(remainder)
    end
end

-- ---------------------------------------------------------------------------
-- 區塊級解析
-- ---------------------------------------------------------------------------

local function indentWidth(spaces)
    local width = 0
    local index
    for index = 1, string.len(spaces) do
        if string.sub(spaces, index, index) == "\t" then
            width = width + 4
        else
            width = width + 1
        end
    end
    return width
end

-- 行尾兩個以上空白或單一反斜線 = 強制換行。
-- 注意：這條語法只有在段落內的 soft break 被合併成同一邏輯行時才有意義，見 MDParser.parse。
local function splitHardBreak(line)
    local body = trimTrailing(line)
    if body == "" then
        return "", false
    end

    local hard = false
    local bodyLength = string.len(body)
    if string.sub(line, bodyLength + 1, bodyLength + 2) == "  " then
        hard = true
    end
    if string.sub(body, bodyLength, bodyLength) == "\\" then
        hard = true
        body = trimTrailing(string.sub(body, 1, bodyLength - 1))
    end
    return body, hard
end

-- 主題分隔線：---、***、___，允許內部空白（- - -）。
-- 表格分隔列 |---|---| 含 '|' 會在「全部同字元」檢查落空，不會誤中。
local function isThematicBreak(line)
    local compact = string.gsub(line, "%s", "")
    local length = string.len(compact)
    if length < 3 then
        return false
    end
    local first = string.sub(compact, 1, 1)
    if first ~= "-" and first ~= "*" and first ~= "_" then
        return false
    end
    local index
    for index = 2, length do
        if string.sub(compact, index, index) ~= first then
            return false
        end
    end
    return true
end

local function headingInfo(line)
    local hashes, rest = string.match(line, "^%s*(#+)%s+(.*)$")
    if hashes == nil then
        hashes = string.match(line, "^%s*(#+)%s*$")
        rest = ""
    end
    -- CommonMark 上限 6 個 #，超過退回段落
    if hashes == nil or string.len(hashes) > 6 then
        return nil
    end
    local stripped = string.match(rest, "^(.-)%s+#+%s*$")
    if stripped then
        rest = stripped
    end
    return string.len(hashes), rest
end

local function fenceInfo(line)
    local spaces, rest = string.match(line, "^([ \t]*)(.*)$")
    local character = string.sub(rest, 1, 1)
    if character ~= "`" and character ~= "~" then
        return nil
    end
    local count = runLength(rest, 1, character)
    if count < 3 then
        return nil
    end
    local info = string.sub(rest, count + 1)
    if character == "`" and string.find(info, "`", 1, true) then
        return nil
    end
    return character, count, indentWidth(spaces), info
end

local function blockquoteInfo(line)
    local rest = string.match(line, "^%s*(>.*)$")
    if not rest then
        return nil
    end
    local depth = 0
    while true do
        local stripped = string.match(rest, "^>%s?(.*)$")
        if not stripped then
            break
        end
        depth = depth + 1
        rest = stripped
        local nested = string.match(rest, "^%s*(>.*)$")
        if nested then
            rest = nested
        end
    end
    return depth, rest
end

local function listInfo(line)
    local spaces, _, rest = string.match(line, "^([ \t]*)([%-%*%+])[ \t]+(.*)$")
    if spaces then
        return indentWidth(spaces), false, 0, rest
    end
    local numberSpaces, digits, _, body = string.match(
        line, "^([ \t]*)(%d+)([%.%)])[ \t]+(.*)$")
    if numberSpaces then
        return indentWidth(numberSpaces), true, tonumber(digits), body
    end
    return nil
end

-- 用「開啟中的清單堆疊」判層級，不用「前導空白數 / N」：
-- 沒有父項時 4 個空白不算巢狀，跟 CommonMark 一致。
local function updateListStack(stack, width, ordered, startNumber)
    while #stack > 0 and width < stack[#stack].width do
        stack[#stack] = nil
    end

    if #stack == 0 or width > stack[#stack].width then
        local entry = { width = width, ordered = ordered, counter = startNumber }
        if #stack >= MAX_LIST_DEPTH then
            stack[#stack] = entry
        else
            stack[#stack + 1] = entry
        end
    elseif stack[#stack].ordered ~= ordered then
        stack[#stack].ordered = ordered
        stack[#stack].counter = startNumber
    end

    local top = stack[#stack]
    -- -、*、+ 三種 marker 一律渲染成同一個 ASCII '-'：
    -- (a) HTML 的 <ul> 本來就不因 marker 字元改變 bullet；
    -- (b) NBPanel:matchLinkGroups 只剝除 "- " 與 "n. "，引入其他 bullet 會讓清單項內的連結點不到；
    -- (c) 非 ASCII 字元（例如中點 U+00B7）會被 Kahlua 截成單一位元組變亂碼。
    local marker = "- "
    if top.ordered then
        -- CommonMark 的 <ol> 只吃第一項的起始號，之後自動遞增
        marker = integerToString(top.counter) .. ". "
        top.counter = top.counter + 1
    end
    return #stack, marker
end

local function listPrefix(level, marker)
    return " <TEXT> " .. INDENT_TAG[level + 1] .. marker
end

local function listContinuation(level)
    return " <TEXT> " .. INDENT_TAG[level + 1]
end

local function quotePrefix(depth)
    return " <TEXT> " .. INDENT_TAG[depth + 1] .. QUOTE_COLOR .. QUOTE_MARK
end

local function codePrefix(leading)
    local index = leading + 1
    if index > #CODE_INDENT_TAG then
        index = #CODE_INDENT_TAG
    end
    return " <TEXT> " .. CODE_INDENT_TAG[index] .. CODE_COLOR
end

local function stripIndent(line, amount)
    local removed = 0
    local position = 1
    while removed < amount do
        local character = string.sub(line, position, position)
        if character == " " then
            removed = removed + 1
        elseif character == "\t" then
            removed = removed + 4
        else
            break
        end
        position = position + 1
    end
    return string.sub(line, position)
end

local function renderCodeLine(text)
    local leading = 0
    local position = 1
    while true do
        local character = string.sub(text, position, position)
        if character == " " then
            leading = leading + 1
        elseif character == "\t" then
            leading = leading + 4
        else
            break
        end
        position = position + 1
    end
    return codePrefix(leading) .. escapeCode(string.sub(text, position))
end

local function splitLines(text)
    local lines = {}
    local position = 1

    while true do
        local lineEnd = string.find(text, "\n", position, true)
        if not lineEnd then
            lines[#lines + 1] = string.sub(text, position)
            break
        end
        lines[#lines + 1] = string.sub(text, position, lineEnd - 1)
        position = lineEnd + 1
    end

    return lines
end

function MDParser.parse(markdown)
    if type(markdown) ~= "string" then
        error("markdown must be a string")
    end

    -- 逸出哨兵是裸位元組，而 getFileReader 讀的是服主手寫的任意位元組檔：
    -- 來源裡若剛好出現 \1<digits>\2，decodeEscapes 會把它當成逸出佔位還原成別的字元
    -- （超出 char 範圍時更是整份公告變成錯誤占位）。在入口一律剝掉。
    markdown = string.gsub(markdown, SENTINEL_OPEN, "")
    markdown = string.gsub(markdown, SENTINEL_CLOSE, "")
    markdown = string.gsub(markdown, "\r\n", "\n")
    markdown = string.gsub(markdown, "\r", "\n")

    local state = {
        lines = {},
        links = {},
        images = {},
    }

    -- 段落累積器。CommonMark 的 soft break（段落內單一換行）要併回同一個邏輯行，
    -- 否則「行尾兩空格 = 強制換行」不會有任何可觀察差異（每個 \n 本來就變成 <LINE>），
    -- 而且服主把段落斷在 80 欄時畫面會長成參差短行——引擎本來就會自動重排（:502）。
    local pending = nil
    local listStack = {}
    local blockSerial = 0
    local fenceCharacter = nil
    local fenceCount = 0
    local fenceIndent = 0

    local function flushPending()
        if pending == nil then
            return
        end
        if #pending.parts > 0 then
            renderContentLine(table.concat(pending.parts, " "), pending.prefix, state)
        end
        pending = nil
    end

    local function pushText(kind, key, prefix, continuation, text, hard)
        if pending ~= nil and (pending.kind ~= kind or pending.key ~= key) then
            flushPending()
        end
        if pending == nil then
            pending = {
                kind = kind,
                key = key,
                prefix = prefix,
                continuation = continuation,
                parts = {},
            }
        end
        pending.parts[#pending.parts + 1] = text
        if hard then
            renderContentLine(table.concat(pending.parts, " "), pending.prefix, state)
            pending.parts = {}
            -- 續行保留當層 <INDENT:>，但不重印 bullet / 編號
            pending.prefix = pending.continuation
        end
    end

    local lines = splitLines(markdown)
    local index
    for index = 1, #lines do
        local raw = lines[index]

        if fenceCharacter ~= nil then
            local closeCharacter, closeCount, _, closeInfo = fenceInfo(raw)
            if closeCharacter == fenceCharacter and closeCount >= fenceCount
                and trim(closeInfo) == "" then
                fenceCharacter = nil
            else
                appendLogicalLine(state, renderCodeLine(stripIndent(raw, fenceIndent)))
            end
        else
            -- 先做反斜線逸出，區塊級比對才看不到 \# / \- / \``` 這些被逸出的記號
            local body, hard = splitHardBreak(encodeBackslashEscapes(raw))
            if body == "" then
                -- 空行不清掉清單堆疊：CommonMark 的鬆散清單（項目間有空行）仍是同一份清單，
                -- 編號要接著數。只有出現「非清單的區塊」才重設。
                flushPending()
                appendLogicalLine(state, "")
            else
                local openCharacter, openCount, openIndent = fenceInfo(body)
                local headingLevel, headingText = headingInfo(body)
                if openCharacter then
                    flushPending()
                    listStack = {}
                    fenceCharacter = openCharacter
                    fenceCount = openCount
                    fenceIndent = openIndent
                elseif headingLevel then
                    listStack = {}
                    blockSerial = blockSerial + 1
                    -- 只有 H1 需要換前綴（H2-H6 本來就靠左），見 H1_IMAGE_PREFIX 的註解。
                    -- 判定刻意走既有的 findImage 而不是 string.find(text, "![", 1, true)：
                    -- headingText 來自 encodeBackslashEscapes 之後的 body（見上方 :1124），
                    -- 逸出的 `\![` 這時已經是 sentinel、比不中，字面上的 `![`（沒有跟著
                    -- `](...)`）也不成立——兩者都不該讓一個沒有圖片的 `#` 標題莫名靠左。
                    -- 服主手寫的原生 `<IMAGE:路徑>` 是白名單放行的一等語法（見 ADMIN_GUIDE
                    -- 的原生標記白名單），走的是引擎同一個 IMAGE 分支（ISRichTextPanel.lua
                    -- :146-177，imageX = x + IMAGE_PAD，同樣不吃置中位移），所以錯位一模一樣、
                    -- 必須一起判。用純字面比對即可：`\<` 逸出後已是 sentinel、比不中。
                    -- `<IMAGECENTRE:>` 刻意不列入——它強制水平置中（:205-206），與 orient
                    -- 無關，改成靠左只會讓文字也跟著往左而圖片留在正中，不會更好。
                    local headingPrefix = HEADING_PREFIX[headingLevel]
                    if headingLevel == 1
                        and (findImage(headingText, 1) ~= nil
                            or string.find(headingText, "<IMAGE:", 1, true) ~= nil) then
                        headingPrefix = MDParser.H1_IMAGE_PREFIX
                    end
                    pushText("heading", blockSerial, headingPrefix,
                        MDParser.LINE_RESET, headingText, hard)
                elseif isThematicBreak(body) then
                    flushPending()
                    listStack = {}
                    appendLogicalLine(state, MDParser.HORIZONTAL_RULE)
                else
                    local quoteDepth, quoteText = blockquoteInfo(body)
                    if quoteDepth then
                        listStack = {}
                        if quoteDepth > MAX_LIST_DEPTH then
                            quoteDepth = MAX_LIST_DEPTH
                        end
                        pushText("quote", quoteDepth, quotePrefix(quoteDepth),
                            quotePrefix(quoteDepth), quoteText, hard)
                    else
                        local width, ordered, startNumber, itemText = listInfo(body)
                        if width then
                            local level, marker =
                                updateListStack(listStack, width, ordered, startNumber)
                            blockSerial = blockSerial + 1
                            pushText("list", blockSerial, listPrefix(level, marker),
                                listContinuation(level), itemText, hard)
                        elseif pending ~= nil and pending.kind == "list"
                            and string.match(body, "^[ \t]") ~= nil then
                            -- 縮排續行併回上一個清單項（CommonMark 的 lazy continuation）。
                            -- 只接受「有縮排」的形式，沒縮排的一律當新段落，行為才可預測。
                            pushText("list", pending.key, pending.prefix,
                                pending.continuation, trim(body), hard)
                        else
                            listStack = {}
                            pushText("paragraph", 0, MDParser.LINE_RESET,
                                MDParser.LINE_RESET, body, hard)
                        end
                    end
                end
            end
        end
    end
    flushPending()

    return {
        ok = true,
        richText = table.concat(state.lines, MDParser.LINE_SEPARATOR),
        links = state.links,
        images = state.images,
    }
end

-- 對外安全入口：任何 parser 例外都轉為可顯示的占位結果，不向 UI 傳播。
function MDParser.safeParse(markdown)
    local ok, parsed = pcall(MDParser.parse, markdown)
    if ok then
        return parsed
    end

    return {
        ok = false,
        richText = MDParser.ERROR_PLACEHOLDER,
        links = {},
        images = {},
        error = tostring(parsed),
    }
end

return MDParser
