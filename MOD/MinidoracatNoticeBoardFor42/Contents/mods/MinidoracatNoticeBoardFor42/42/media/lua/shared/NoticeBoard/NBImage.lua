-- NBImage：圖片同步的純邏輯層（base64 編解碼、分批切割、串流 DJB2、名稱驗證）。
-- 本檔**不得**呼叫任何 PZ API：它同時被 server／client 載入，也被 scripts/test_mdparser.lua
-- 以標準 Lua 直接 require 做斷言測試。
--
-- 為什麼每個函式都吃 (startIndex, count)：純 Lua 逐位元組編解碼很慢，整張圖一次跑完會卡主執行緒。
-- 呼叫端（NBServer／NBImageCache）以每 tick 一小批的方式推進，這層只負責「一批」的正確性。
NBImage = NBImage or {}

NBImage.IMAGE_DIR = "images"
NBImage.CACHE_DIR = "cache"

-- ---------------------------------------------------------------------------
-- 容量上限：**服主政策** 與 **玩家保護** 是兩層，後者不可被前者放寬
--
-- (A) 服主政策（沙盒選項，預設值＝下面三個 MAX_* 常數）
--     單張大小 MaxImageKB／張數 MaxImageCount／總量 MaxImageTotalKB。
--     服主什麼都不設就是這三個預設值，行為與可調之前完全相同。
--     這些是「這台伺服器願意讓玩家下載多少」的政策，影響由服主自己承擔，故交給服主。
--
-- (B) 玩家保護（下面的 *_LIMIT／MAX_*_KB 硬天花板 ＋ CACHE_BUDGET_BYTES／WRITE_WINDOW_BYTES）
--     寫死在 .lua 裡、不讀任何 sandbox。MP 下 sandbox 是 **server 推給 client** 的
--     （ConnectionDetails.java:137-138），所以「宣告值」本身就是不可信輸入。
--     天花板取值 == 沙盒選項的合法上界，因此對誠實伺服器永遠是 no-op；它擋的是
--     宣告值落在選項合法範圍之外的惡意 server。接收端（NBReader）與寫檔端
--     （NBImageCache）一律 min(宣告值, 天花板)，**不可**因為 (A) 調高而跟著放寬。
-- ---------------------------------------------------------------------------

-- (A) 政策預設值。超限者剔除並寫 issue log（比照既有 oversize/trimmed）。
NBImage.MAX_IMAGE_BYTES = 524288
NBImage.MAX_IMAGE_COUNT = 20
NBImage.MAX_TOTAL_BYTES = 4194304

-- (B) 沙盒選項的合法範圍＝客戶端硬天花板。三組 min/max 必須與 sandbox-options.txt
-- 及 NoticeBoardImages/README.txt 的 [LIMITS] 逐項相同（scripts/test_mdparser.lua 有三方一致性測試）。
NBImage.MIN_IMAGE_KB = 64
NBImage.MAX_IMAGE_KB = 4096

-- 張數天花板 200 的推算（硬界來自「manifest 單包不可接近 1MB」）：
--   * 封包緩衝是 ByteBuffer.allocate(1000000)（UdpConnection.java:39-40）。
--   * manifest 的每個 image 條目是 {name, h, n, b}，序列化規則見
--     TableNetworkUtils.save（型別 byte + 值）與 GameWindow.StringUTF.save
--     （putShort 長度 + UTF-8 bytes）：
--       陣列鍵(Double)  1 + 8                       =   9
--       條目表頭        1 + putInt(4)               =   5
--       "name"          key 1+2+4 / val 1+2+64      =  74   (MAX_NAME_UTF16=64，ASCII)
--       "h"             key 1+2+1 / val 1+2+8       =  15   (8 hex)
--       "n"             key 1+2+1 / val 1+8         =  13   (Double)
--       "b"             key 1+2+1 / val 1+8         =  13   (Double)
--     合計 <= 129 bytes/條目（最壞情況，檔名吃滿 64 字元）。
--   * 同一包還要裝公告 manifest：MAX_MANIFEST_FILES=200 個 {id,title,n,h}，
--     id <= 128 UTF-16 單元、title <= 200 UTF-16 單元，CJK 各 3 bytes/單元
--     -> 每筆 <= 1045 bytes -> 209,000 bytes；langs(<=32) + v/sid/lang/lseq 約 1KB。
--   * 於是圖片條目可用 1,000,000 - 210,000 = 790,000 bytes -> 理論硬界約 6100 條。
--   取 200：200 * 129 = 25,800 bytes，佔封包 2.6%，與公告 manifest 合計約 236KB
--   （不到緩衝的四分之一），距硬界仍有 30 倍餘裕。200 也與 MAX_MANIFEST_FILES 同量級。
NBImage.MIN_IMAGE_COUNT = 1
NBImage.MAX_IMAGE_COUNT_LIMIT = 200

-- 總量天花板 16384KB=16MB 的取值：真正的瓶頸不是封包而是**客戶端寫檔吞吐**。
-- WRITE_BYTES_PER_TICK=1536、約 60 tick/s -> 約 92KB/s，16MB 約 3 分鐘背景同步
-- （一次性，之後靠 hash 快取命中不再重傳）；再往上就不是「等一下」而是「等很久」。
-- 下界刻意取 4096＝MAX_IMAGE_KB：這樣**任何合法組合下**單張上限都不可能超過總量上限，
-- 原本「保證單張永遠不可能超過總量」的不變式不需要任何執行期交叉檢查就繼續成立。
NBImage.MIN_TOTAL_KB = 4096
NBImage.MAX_TOTAL_KB = 16384

-- 讀 SandboxVars.MinidoracatNB.<key>：非整數／超出 [minValue,maxValue]／缺值一律回 fallback。
-- 只讀全域變數、不呼叫任何 PZ 函式——標準 Lua 測試環境下 SandboxVars 是 nil，直接回 fallback，
-- 本檔的「零 PZ API」契約不變。回傳值必然落在合法範圍內（fallback 本身也在範圍內），
-- 惡意 server 宣告 MaxImageCount=99999 只會拿到預設值。
local function sandboxInt(key, minValue, maxValue, fallback)
    if type(SandboxVars) == "table" then
        local options = rawget(SandboxVars, "MinidoracatNB")
        if type(options) == "table" then
            local value = tonumber(rawget(options, key))
            if value
                and value == math.floor(value)
                and value >= minValue
                and value <= maxValue then
                return value
            end
        end
    end
    return fallback
end

-- **產生端與接收端必須用同一個值**：只放寬 server 端的話，client 會把圖片清單判為無效而丟棄。
-- MP 下 server 連線時會把 sandbox 整包推給 client（ConnectionDetails），故兩端讀到的必然一致。
function NBImage.maxImageBytes()
    local kilobytes = sandboxInt("MaxImageKB",
        NBImage.MIN_IMAGE_KB, NBImage.MAX_IMAGE_KB, nil)
    if kilobytes then
        return kilobytes * 1024
    end
    return NBImage.MAX_IMAGE_BYTES
end

function NBImage.maxImageCount()
    return sandboxInt("MaxImageCount",
        NBImage.MIN_IMAGE_COUNT, NBImage.MAX_IMAGE_COUNT_LIMIT, NBImage.MAX_IMAGE_COUNT)
end

function NBImage.maxTotalBytes()
    local kilobytes = sandboxInt("MaxImageTotalKB",
        NBImage.MIN_TOTAL_KB, NBImage.MAX_TOTAL_KB, nil)
    if kilobytes then
        return kilobytes * 1024
    end
    return NBImage.MAX_TOTAL_BYTES
end
-- server 端每 tick 的位元組預算（讀檔＋編碼）。readInt() 一次吃 4 bytes，成本可控。
NBImage.BYTES_PER_TICK = 8192
-- client 端每 tick 的寫檔位元組預算，必須遠小於 server 端：getFileOutput 回的是**未緩衝**的
-- DataOutputStream(new FileOutputStream(...))（LuaManager.java:5818-5840），writeBytes(String)
-- 對每個 char 都會打到 OS 一次；實測 Java 25（PZ 內附 Zulu25.30）寫 8192 chars 約 13.5ms，
-- 加上純 Lua 解碼＋DJB2 會直接吃掉整個 16.7ms 影格。1536 bytes 讓每 tick 落在約 2-3ms。
-- 兩條路徑成本差約 5.6 倍，所以必須是兩個獨立常數，一個旋鈕調不動兩邊。
NBImage.WRITE_BYTES_PER_TICK = 1536
-- 快取目錄的總量上限（所有伺服器共用同一個目錄，所以這是**全域**的界）。
-- 有了 LRU 淘汰之後磁碟佔用才第一次成為有界量，這條就是那個界。
--
-- 取 128MB 的推導：
--   * 單台伺服器的合法總量上界是 MAX_TOTAL_KB=16MB -> 128MB 可以同時完整快取
--     8 台「設定拉滿」的伺服器，或 32 台跑預設 4MB 的伺服器。玩家常玩的伺服器
--     數量遠低於此，所以誠實情境下淘汰幾乎不會發生（＝不會有無謂的重下載）。
--   * 淘汰的代價是重新下載，而重新下載很貴：client 寫檔吞吐約 92KB/s
--     （WRITE_BYTES_PER_TICK * 60 tick/s），一台 16MB 的伺服器重同步約 3 分鐘。
--     上限太小會讓玩家在兩三台伺服器之間反覆付這 3 分鐘。
--   * 玩家硬碟成本：128MB 相對 PZ 本體（約 5GB）與一般存檔（數百 MB 起跳）不到 3%，
--     而且是**上限**不是常態值——只有真的快取了那麼多圖才會用到。
NBImage.CACHE_BUDGET_BYTES = 134217728

-- 寫入速率上限（取代原本「一場連線 64MB、用完整場不恢復」的絕對額度）。
--
-- 有了淘汰之後這條保護的東西變了：磁碟總量已經由 CACHE_BUDGET_BYTES 封死，
-- 這裡擋的是**持續寫入**本身（CPU／IO／SSD 壽命）——惡意 server 可以無限輪替
-- manifest，淘汰只會讓它「一直有空間可寫」，所以速率仍然必須有界。
--
-- 形狀從「一次性額度」改成「每個時間窗重新裝滿」：
--   * 額度 64MB 沿用原本的推導：服主把總量開到天花板 16MB、每張圖都重試到
--     MAX_ATTEMPTS=3 次 = 48MB < 64MB，最壞的**合法**用量仍不會誤觸。
--     額度同樣不可由 MAX_TOTAL_BYTES 倍率推導——它保護的是玩家自己的硬碟，
--     不該隨伺服器宣告的值縮放（服主把總量拉滿時玩家第一輪就撞上限）。
--   * 窗 30 分鐘 -> 持續寫入上限 64MB/30min = 36KB/s，約是 client 寫檔吞吐
--     （92KB/s）的四成；惡意 server 一小時最多讓玩家寫掉 128MB。
--   * 額度用盡不再等於「整場遊戲失去圖片」：被擋下的 hash 記在 deferred，
--     下一個窗開始時清掉 attempts 重新排隊。原本的行為是 attempts 拉到上限、
--     整場不恢復，而「原地覆蓋自動偵測」讓每次換圖都產生新 hash——一台每輪換圖的
--     伺服器在預設 60 秒輪詢下約 2.1 小時（64MB/512KB=128 張）就會讓誠實玩家
--     整場看不到圖，這正是要修掉的行為。
NBImage.WRITE_WINDOW_BYTES = 67108864
NBImage.WRITE_WINDOW_MS = 1800000
NBImage.MAX_NAME_UTF16 = 64

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local PAD = "="
local UINT32_MODULUS = 4294967296
local HEX_DIGITS = "0123456789abcdef"

local ENCODE = {}
local DECODE = {}
-- 0..255 -> 單一字元字串。解碼結果組成這種「每字元即一個位元組」的字串後，
-- 可直接交給 DataOutputStream:writeBytes（Java 只取每個 char 的低 8 bits），
-- 一次呼叫寫完整批，避免逐位元組 write() 造成每 tick 上千次反射呼叫。
local BYTE_CHAR = {}

local buildIndex
for buildIndex = 0, 63 do
    local character = string.sub(B64_CHARS, buildIndex + 1, buildIndex + 1)
    ENCODE[buildIndex] = character
    DECODE[character] = buildIndex
end
for buildIndex = 0, 255 do
    BYTE_CHAR[buildIndex] = string.char(buildIndex)
end

local function expectNumber(value, name)
    if type(value) ~= "number" or value ~= math.floor(value) then
        error((name or "value") .. " must be an integer")
    end
end

-- 名稱契約：ASCII 檔名 + .png。同時是 producer（掃描目錄）與 receiver（manifest）的邊界檢查，
-- 兩端用同一份規則，否則合法檔名會在對端被拒、圖永遠同步不過去。
function NBImage.isValidName(name)
    if type(name) ~= "string" then
        return false
    end
    if string.len(name) > NBImage.MAX_NAME_UTF16 then
        return false
    end
    if string.find(name, "..", 1, true) ~= nil then
        return false
    end
    return string.match(name, "^[A-Za-z0-9][A-Za-z0-9%-_]*%.[Pp][Nn][Gg]$") ~= nil
end

function NBImage.isHash(text)
    return type(text) == "string"
        and string.len(text) == 8
        and string.match(text, "^[0-9a-f]+$") ~= nil
end

-- base64 輸出長度：每 3 bytes 產生 4 chars，不足 3 的尾段補齊成一組 4。
function NBImage.encodedLength(byteCount)
    expectNumber(byteCount, "byteCount")
    if byteCount < 0 then
        error("byteCount must not be negative")
    end
    return math.floor((byteCount + 2) / 3) * 4
end

-- 編碼一批位元組。byteCount 必須是 3 的倍數，除非 isFinal（否則跨批會產生錯誤的 padding）。
function NBImage.encodeBytes(bytes, startIndex, byteCount, isFinal)
    if type(bytes) ~= "table" then
        error("bytes must be a table")
    end
    expectNumber(startIndex, "startIndex")
    expectNumber(byteCount, "byteCount")
    if byteCount < 0 then
        error("byteCount must not be negative")
    end
    if not isFinal and byteCount % 3 ~= 0 then
        error("byteCount must be a multiple of 3 unless isFinal")
    end
    if byteCount == 0 then
        return ""
    end

    local out = {}
    local outCount = 0
    local lastIndex = startIndex + byteCount - 1
    local index = startIndex
    while index <= lastIndex do
        local b1 = bytes[index]
        local b2 = nil
        local b3 = nil
        if index + 1 <= lastIndex then
            b2 = bytes[index + 1]
        end
        if index + 2 <= lastIndex then
            b3 = bytes[index + 2]
        end
        if type(b1) ~= "number" then
            error("missing byte at index " .. tostring(index))
        end

        local value
        local significant
        if b3 ~= nil then
            value = b1 * 65536 + b2 * 256 + b3
            significant = 4
        elseif b2 ~= nil then
            value = b1 * 65536 + b2 * 256
            significant = 3
        else
            value = b1 * 65536
            significant = 2
        end

        outCount = outCount + 1
        out[outCount] = ENCODE[math.floor(value / 262144) % 64]
        outCount = outCount + 1
        out[outCount] = ENCODE[math.floor(value / 4096) % 64]
        outCount = outCount + 1
        if significant >= 3 then
            out[outCount] = ENCODE[math.floor(value / 64) % 64]
        else
            out[outCount] = PAD
        end
        outCount = outCount + 1
        if significant >= 4 then
            out[outCount] = ENCODE[value % 64]
        else
            out[outCount] = PAD
        end

        index = index + 3
    end
    return table.concat(out)
end

-- 解碼一批 base64 字元，回傳「每字元即一個位元組」的字串（見 BYTE_CHAR 註解）。
-- charCount 必須是 4 的倍數；padding 只允許出現在整份輸入的最後一組。
function NBImage.decodeToByteString(text, startIndex, charCount)
    if type(text) ~= "string" then
        error("text must be a string")
    end
    expectNumber(startIndex, "startIndex")
    expectNumber(charCount, "charCount")
    if charCount < 0 or charCount % 4 ~= 0 then
        error("charCount must be a non-negative multiple of 4")
    end
    if charCount == 0 then
        return ""
    end

    local out = {}
    local outCount = 0
    local lastIndex = startIndex + charCount - 1
    if lastIndex > string.len(text) then
        error("decode range exceeds input length")
    end

    local index = startIndex
    while index <= lastIndex do
        local c1 = string.sub(text, index, index)
        local c2 = string.sub(text, index + 1, index + 1)
        local c3 = string.sub(text, index + 2, index + 2)
        local c4 = string.sub(text, index + 3, index + 3)
        local v1 = DECODE[c1]
        local v2 = DECODE[c2]
        if v1 == nil or v2 == nil then
            error("invalid base64 at index " .. tostring(index))
        end

        local value = v1 * 262144 + v2 * 4096
        outCount = outCount + 1
        out[outCount] = BYTE_CHAR[math.floor(value / 65536) % 256]

        if c3 == PAD then
            if c4 ~= PAD then
                error("invalid base64 padding at index " .. tostring(index))
            end
        else
            local v3 = DECODE[c3]
            if v3 == nil then
                error("invalid base64 at index " .. tostring(index + 2))
            end
            value = value + v3 * 64
            outCount = outCount + 1
            out[outCount] = BYTE_CHAR[math.floor(value / 256) % 256]

            if c4 ~= PAD then
                local v4 = DECODE[c4]
                if v4 == nil then
                    error("invalid base64 at index " .. tostring(index + 3))
                end
                value = value + v4
                outCount = outCount + 1
                out[outCount] = BYTE_CHAR[value % 256]
            end
        end

        index = index + 4
    end
    return table.concat(out)
end

-- 串流 DJB2：整份 base64 字串一次算 hash 會是一個同步全掃描（大圖 ~700K 次迭代），
-- 必然卡幀。改成每批推進，語意與 NBCore.djb2 對 ASCII 輸入完全相同。
function NBImage.hashInit()
    return 5381
end

function NBImage.hashUpdate(hash, text, fromIndex, toIndex)
    if type(hash) ~= "number" then
        error("hash must be a number")
    end
    if type(text) ~= "string" then
        error("text must be a string")
    end
    fromIndex = fromIndex or 1
    toIndex = toIndex or string.len(text)
    local index
    for index = fromIndex, toIndex do
        hash = (hash * 33 + string.byte(text, index)) % UINT32_MODULUS
    end
    return hash
end

function NBImage.hashHex(hash)
    local value = hash
    local result = {}
    local index
    for index = 8, 1, -1 do
        local digit = value % 16
        result[index] = string.sub(HEX_DIGITS, digit + 1, digit + 1)
        value = math.floor(value / 16)
    end
    return table.concat(result)
end

-- 分塊累積器：把新產生的 ASCII 片段接進 pending，滿 limit 就切出一塊放進 chunks，
-- 回傳剩下的 pending。切點規則與 NBCore.chunkText 一致（base64 純 ASCII，UTF-16 長度＝字元數，
-- 不存在 surrogate pair，故可直接切）。
function NBImage.pushChunks(pending, produced, chunks, limit)
    if type(pending) ~= "string" or type(produced) ~= "string" then
        error("pending and produced must be strings")
    end
    if type(chunks) ~= "table" then
        error("chunks must be a table")
    end
    expectNumber(limit, "limit")
    if limit < 1 then
        error("limit must be positive")
    end

    local buffer = pending .. produced
    while string.len(buffer) >= limit do
        chunks[#chunks + 1] = string.sub(buffer, 1, limit)
        buffer = string.sub(buffer, limit + 1)
    end
    return buffer
end

-- 收尾：把殘餘 pending 推成最後一塊。空輸入也必須留下一塊，否則 n=0 無法通過接收端驗證。
function NBImage.flushChunks(pending, chunks)
    if type(pending) ~= "string" or type(chunks) ~= "table" then
        error("pending must be a string and chunks a table")
    end
    if pending ~= "" or #chunks == 0 then
        chunks[#chunks + 1] = pending
    end
    return chunks
end

return NBImage
