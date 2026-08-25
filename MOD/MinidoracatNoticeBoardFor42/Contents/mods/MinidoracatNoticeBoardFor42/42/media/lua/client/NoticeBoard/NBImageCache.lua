-- NBImageCache：client 端的圖片快取。
--
-- 流程：manifest 帶來 images 清單 -> 逐個 hash 問磁碟（NoticeBoard/cache/）->
-- 只對缺少的 hash 送 imgreq -> 收齊分塊 -> 每 tick 一小批 base64 解碼並寫檔
-- -> 驗證位元組數與 hash -> 標記可用。
--
-- 「每 tick 一小批」是硬性要求：純 Lua 解碼一張 512KB 的圖是數十萬次迭代，
-- 任何一次跑完的路徑都會讓畫面卡住。本檔沒有任何同步跑完整張圖的分支。
--
-- 三個跨檔的設計點，各自的理由寫在對應的區塊註解裡：
--   * 快取檔名帶伺服器命名空間 <serverToken>_<hash>.png（見 sanitizeToken 上方）——
--     安全修正，代價是跨伺服器去重。
--   * LRU 淘汰（見「LRU 淘汰」區塊）——快取總量第一次成為有界量。
--   * 寫入額度是**時間窗**而不是一次性額度（見 NBImage.WRITE_WINDOW_BYTES）——
--     用完只是這個窗停手，下一個窗自動恢復。
--   * 傳輸中斷以**分塊**為單位續傳（見 firstMissingChunk 與 expirePending）——
--     逾時不再丟掉已收到的分塊，imgreq 帶一個起點索引只要缺的那幾塊。
--
-- 為什麼**沒有**跨場次的續傳（把已收到的分塊寫進磁碟）：這條管線是**寫檔綁死**的。
-- 客戶端寫圖檔約 92KB/s（WRITE_BYTES_PER_TICK 的註解有推導），而伺服器推分塊是
-- 每位玩家每 tick 8 則 x 6000 字元，兩者差一個數量級以上——所以中斷幾乎必然發生在
-- 寫檔階段，而寫檔階段**在引擎層面就不可能續傳**：getFileOutput 走
-- `new FileOutputStream(outFile)`（LuaManager.java:5818-5837，無 append 多載），
-- 一開檔就把檔案截成 0，沒有任何辦法接在既有位元組後面寫。唯一能持久化的是 base64
-- 文字（getFileWriter 有 append），但那是「多寫 1.33 倍的位元組到磁碟，去省下一段
-- 重新下載」——而磁碟寫入正是這裡最稀缺、WRITE_WINDOW_BYTES 專門在保護的資源，
-- 下載則不是。淨值為負，所以不做。
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

NBImageCache = NBImageCache or {}

-- 寫進 RichText 的替身 token。實際的絕對路徑在 NBPanel 的 processCommand 覆寫裡才換回去：
-- ISRichTextPanel:paginate 以空白切 token（:459），玩家家目錄含空白（"C:\Users\John Doe\..."）
-- 時，把絕對路徑直接寫進 <IMAGE:...> 會被切斷成兩段字面文字，圖變成亂碼。
NBImageCache.TOKEN_PREFIX = "NBCACHE_"

-- 圖片端要對玩家講的話。沿用既有事件機制（NBClient.LANGUAGE_STATUS_EVENT 的形狀），
-- 不新增全域輪詢：NBPanel Add 一個 handler 就能出 toast。payload 一律是 table，
-- 目前只有一種 kind（budget，見 startWriteJob）。
NBImageCache.STATUS_EVENT = "MinidoracatNB_ImageStatus"

local LOG_NAME = "MinidoracatNoticeBoardFor42"
local LOG_PREFIX = "[MinidoracatNoticeBoardFor42]"
local SEPARATOR = getFileSeparator()
local CACHE_DIR = Reader.NOTICE_ROOT .. SEPARATOR .. Image.CACHE_DIR
-- **必須大於 server 端的 per-player imgreq 冷卻**（NBServer 的 REQUEST_COOLDOWN_MS，
-- 目前 10 秒；scripts/test_mdparser.lua 有跨檔一致性測試釘住這個大小關係）。兩邊相等時
-- 「連續兩次請求」的間隔在 server 看來是 10 秒 ± 網路抖動，也就是一半機率被冷卻靜默丟棄。
-- 有了續傳之後這件事會咬人：送出續傳請求時 client 會樂觀地把 pending 收掉 stalled 並重新
-- 計時（它無從得知對方丟了），被丟掉的那次要白等一整個 PENDING_TIMEOUT_MS 才會再次
-- 變成 stalled，而且**吃掉 MAX_ATTEMPTS 三次之一**。續傳之前不會：那時沒有 pending 的
-- hash 被丟棄只是下一輪再要一次，不累積 attempts。
local REQUEST_INTERVAL_MS = 12000
local REQUEST_BATCH = 4
local PENDING_TIMEOUT_MS = 60000
local MAX_ATTEMPTS = 3

-- LRU 索引檔。只存**淘汰順序**，不存有效性——有效性永遠是「位元組數相符 + 標記完整」，
-- 由磁碟自己決定。索引壞掉／消失時所有 seq 退化成 0，淘汰順序變成任意，
-- 但每一張快取仍然照樣命中、面板照樣進得去。這是刻意的降級界線。
local LRU_INDEX_FILE = CACHE_DIR .. SEPARATOR .. "index.txt"
local LRU_INDEX_HEADER = "NBLRU1"
-- 索引行數上限：只是防呆（索引是我們自己寫的），避免壞檔讓載入變成無界迴圈。
local LRU_INDEX_MAX_LINES = 4096
-- 每 tick 只 stat 幾個檔：getFileInput 每次都是一次開檔＋available()＋close。
-- 幾百個檔案的目錄約 1 秒掃完，攤在背景不影響影格。
local LRU_SCAN_PER_TICK = 4
local LRU_EVICT_PER_TICK = 2
local LRU_SAVE_INTERVAL_MS = 10000

local function newLruState()
    return {
        -- load -> scan -> evict -> idle
        phase = "load",
        names = nil,
        cursor = 0,
        -- stem -> { bytes = <磁碟位元組數>, seq = <最後使用的場次序號> }
        entries = {},
        -- 載入索引時的 stem -> seq，掃描完就丟掉
        seqs = {},
        -- 這場遊戲用過的 stem（掃描還沒走到它時也要記住）
        touched = {},
        total = 0,
        session = 1,
        dirty = false,
        lastSaveMs = 0,
        fullLogged = false,
    }
end

local function newState()
    return {
        signature = nil,
        wanted = {},
        byName = {},
        order = {},
        ready = {},
        attempts = {},
        verifyQueue = {},
        pending = {},
        writeQueue = {},
        writeJob = nil,
        lastRequestMs = 0,
        basePath = nil,
        basePathChecked = false,
        -- 快取檔名的伺服器命名空間（見 serverToken 的註解）。
        serverAddress = nil,
        serverToken = nil,
        serverChanged = false,
        -- 目前時間窗內的寫入總量（含失敗的嘗試——耗掉的是同一份磁碟）。
        windowWritten = 0,
        windowStartMs = 0,
        -- 被時間窗額度擋下（而不是真的失敗）的 hash：換窗時要把 attempts 清掉重排。
        deferred = {},
        budgetLogged = false,
        lru = newLruState(),
        -- 每有一張圖變成可用就 +1。面板拿它當「該重畫了嗎」的判斷，
        -- 否則玩家會一直看到 [替代文字] 占位直到手動切頁籤。
        readyVersion = 0,
    }
end

NBImageCache.state = NBImageCache.state or newState()

local function logLine(message)
    local line = LOG_PREFIX .. " " .. tostring(message)
    print(line)
    pcall(function()
        writeLog(LOG_NAME, line)
    end)
end

local function safeLogValue(value)
    return Core.sanitizeName(value)
end

local function triggerStatus(payload)
    local ok, eventError = pcall(function()
        triggerEvent(NBImageCache.STATUS_EVENT, payload)
    end)
    if not ok then
        logLine("image status event failed: " .. safeLogValue(eventError))
    end
end

-- 快取檔名為什麼要帶伺服器命名空間（安全修正，代價是跨伺服器去重）
--
-- 檔名原本就是內容 hash：<hash>.png，而 hash 是 32 位元 DJB2。DJB2 對訊息是**線性**的
--   h = 33^n * 5381 + sum(33^(n-i) * b_i)  (mod 2^32)
-- ——碰撞不必暴力，直接解線性方程就有。Kahlua 沒有位元運算（沒有 bit32／& | ~ << >>），
-- 能寫出來的純算術 hash 全是這個形狀，把兩組 DJB2 併成 64 位元也還是線性、一樣可解，
-- 所以**加寬 hash 救不了這件事**，唯一的解法是不要讓不同來源共用同一個檔名。
--
-- 沒有命名空間時的具體攻擊：快取目錄是所有伺服器共用的。攻擊者去目標伺服器抄下 manifest
-- 公開的 (h, b)，做一張長度同為 b、base64 的 DJB2 同為 h 的 PNG，讓玩家連自己的伺服器一次；
-- 玩家之後連上正牌伺服器時，pumpVerify 看到「檔名 hash 命中 + 位元組數相符 + 標記完整」
-- 就直接採用，公告欄上出現的是攻擊者的圖。前綴改用**連線位址**（client 自己知道的東西，
-- 不是 server 宣告的欄位，偽造不了）之後，兩邊的檔名不同，這條路整條消失。
-- getServerIP()/getServerPort() 回的是 GameClient.ip／port（`LuaManager.java:4112,4124`），
-- 而 GameClient.ip 只在連線發起處被賦值成玩家輸入的位址（`GameClient.java:1794`、
-- coop `:1816`、本機 `:2318`），不經封包。vanilla 自己也拿同一組值當存檔目錄的命名空間
-- （`ip + "_" + port + "_" + user`，`GameClient.java:1801`）。
--
-- **取捨**：跨伺服器去重沒了——同一張圖在三台伺服器上就是三份。以單張 <=4MB、
-- 總量上限 128MB 來看是划算的交換，但這是產品取捨，不是唯一解。
--
-- 消毒必須是**單射**的，否則上面整段等於沒寫：兩個不同來源只要映射到同一個 token 就共用
-- 同一個檔名，隔離對那一對來源完全失效。舊版把每個非 [a-z0-9] 字元一律塌縮成 "_"，於是
-- pz.example.com 與 pz-example.com（兩個各自可註冊、可解析的名稱）拿到同一個前綴——
-- 攻擊者只要多註冊一個「消毒後同形」的域名，上面那條毒化路徑就整條復活，成本是一次網域註冊。
-- 也**不可以**用「截斷 + 補上整串的 DJB2」補救：DJB2 正是這段開頭說的線性 hash，攻擊者
-- 控制自己那台的位址字串就解得出碰撞，等於拿本檔判定為不安全的原語去守本檔要建立的性質。
-- （完整形 IPv6 是 39 字元、加上 _<port> 必然超過舊版的 40 字元門檻，所以每一台 IPv6
-- 伺服器都走在那條路上。）
--
-- 現在改成可逆的逐字元轉義：非 [a-z0-9] 的字元寫成 _<字碼>_，"_" 自己也照這條規則（_95_），
-- 所以輸出裡的 "_" 只會是轉義語法的一部分，解碼唯一 => 編碼單射。輸出仍只含 [a-z0-9_]
-- （scanCacheName 與 loadLruIndex 的樣式都依賴這件事）。先 lower 是刻意的：DNS 不分大小寫，
-- 大小寫不同的同一台伺服器該共用快取，而不是各存一份。
local MAX_TOKEN_CHARS = 120
local function sanitizeToken(text)
    local clean = string.gsub(string.lower(text), "[^a-z0-9]", function(character)
        return "_" .. tostring(string.byte(character)) .. "_"
    end)
    -- 轉義沒有長度上界（DNS 名稱最長 253 字元，最壞膨脹成四倍），檔名與完整路徑有。
    -- 過長時**不截斷**——截斷就不再單射，就得回頭補 hash，繞回上面剛拆掉的那個洞。
    -- 改成回 nil，走既有的「位址還沒就緒」那條路：這條連線一張圖都不快取，公告改用替代文字。
    -- 120 的來源：完整形 IPv6 + port 轉義後是 69 字元（最長的合法位址），而
    -- <家目錄>/Lua/NoticeBoard/cache/ 約 50 字元 + token + "_" + 8 + ".png"
    -- 要留在 Windows MAX_PATH 260 之內。
    if string.len(clean) > MAX_TOKEN_CHARS then
        return nil
    end
    return clean
end

-- **每次都重新問位址**，不可只算一次就存著：命名空間停在上一個來源就等於整個隔離失效。
-- 位址取得很便宜（兩個 static getter），真正貴的 sanitizeToken 只在位址變動時才跑。
--
-- 42.20.2 的引擎實際上不會讓同一個 Lua 環境看到兩個來源：離開 IngameState 必經
-- exit()（`IngameState.java:789`，789 到 1075 之間沒有任何 return），它會呼叫
-- LuaManager.init()（`:990`）把整個 Lua 環境 wipeRecurse 後重建（`LuaManager.java:1085-1091`），
-- 而兩條斷線路徑（Core.exiting `IngameState.java:1359`、serverDisconnected `:1380`）都在
-- OnTick 的觸發點（`:1528`／`:1532`）之前就 return Continue，也就是 GameStateMachine
-- 呼叫 exit()（`GameStateMachine.java:62-64`）。所以下面這道作廢是**縱深防禦**，不是熱路徑。
-- 正因為如此它更不能有洞：真正生效的那天，是引擎行為變了、或有人把 state 改成跨場次持久化的那天。
--
-- 作廢的比較點是 **token** 不是位址：SP 這條分支根本沒有位址，舊版讓它直接 return，
-- 於是 MP -> SP 換掉了命名空間卻不觸發 serverChanged（而且 serverAddress 停在上一台，
-- SP -> 原本那台 MP 時比較不成立，token 就永遠卡在 "sp"）。兩條分支收斂到同一個比較點之後
-- 這兩件事一起消失。
local function serverToken()
    local state = NBImageCache.state
    local address = nil
    if not isClient() then
        -- SP：server 在同一個 VM，沒有位址也不可能被別人冒充。MP 的位址一律是
        -- <ip>_<port>，轉義後必然含 "_"，不可能與這個字面值相撞。
        address = "sp"
    else
        pcall(function()
            address = tostring(getServerIP()) .. "_" .. tostring(getServerPort())
        end)
        -- 位址還沒就緒時**不要**先湊一個命名空間出來：那一輪寫下的檔案會落在錯的前綴底下，
        -- 之後永遠命不中（而且永遠佔著空間）。回 nil，呼叫端這一 tick 直接什麼都不做。
        if type(address) ~= "string" or string.match(address, "[a-zA-Z0-9]") == nil then
            return nil
        end
    end
    if address ~= state.serverAddress then
        state.serverAddress = address
        state.serverToken = sanitizeToken(address)
        state.serverChanged = true
        -- 位址長到無法安全命名空間化（sanitizeToken 回 nil）時圖片快取整條停用，而症狀是
        -- 「圖永遠不出現」——沒有這行 log，服主無從得知原因。位址變動時才算一次，不會洗版。
        if not state.serverToken then
            logLine("image cache disabled: server address too long to namespace safely")
        end
    end
    return state.serverToken
end

-- 快取檔名主幹 <serverToken>_<hash>。舊格式是沒有底線的 <hash>，兩者永遠分得開。
local function cacheStem(hash)
    local token = serverToken()
    if not token then
        return nil
    end
    return token .. "_" .. hash
end

local function stemPngPath(stem)
    return CACHE_DIR .. SEPARATOR .. stem .. ".png"
end

local function stemMarkerPath(stem)
    return CACHE_DIR .. SEPARATOR .. stem .. ".ok"
end

local function cacheRelativePath(hash)
    return stemPngPath(cacheStem(hash))
end

-- 完成標記 <stem>.ok，內容是該 hash 的 8 個字元。只有「寫完且 digest 驗過」才會產生。
-- 為什麼需要：manifest 的 digest 是對 base64 文字算的，沒辦法拿磁碟上的位元組直接重算，
-- 所以快取命中路徑只能比對位元組數——一個「大小正確但內容錯」的殘檔會被永久當成有效快取，
-- 而且完全不會重下載。PZ 沒有刪檔 API（只能用 getFileOutput 截成 0 bytes），
-- 所以標記的有效性看的是**內容長度**而不是檔案存不存在。
local function markerRelativePath(hash)
    return stemMarkerPath(cacheStem(hash))
end

local function fileSize(relativePath)
    local input = nil
    local ok, size = pcall(function()
        input = getFileInput(relativePath)
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
    if not ok or type(size) ~= "number" then
        return nil
    end
    return math.floor(size)
end

-- 截成 0 bytes：getFileOutput 走 new FileOutputStream（LuaManager.java:5818-5837）會截斷檔案，
-- 開了立刻關就等於清空。
--
-- **「拿到 writer」不等於截斷成功，所以結果一定要讀回來確認。** 開檔失敗時 getFileOutput
-- 不回 nil，它回的是 DataOutputStream(上一個成功開啟的 static outStream)
-- （LuaManager.java:5833-5840）——那個殼 close() 得掉，檔案卻原封不動。只看回傳值的話
-- 這個函式永遠回 true，失敗的 log 是死程式碼，而呼叫端（evictStem 的帳）會以為空間收回來了。
-- 觸發條件不罕見：%USERPROFILE%\Zomboid 落在 OneDrive 同步範圍、防毒即時掃描、
-- 或玩家拿看圖程式開著那個 png，都會讓 new FileOutputStream 吃到 sharing violation。
local function truncateFile(relativePath)
    local writer = nil
    local ok, openError = pcall(function()
        writer = getFileOutput(relativePath)
    end)
    if writer then
        pcall(function()
            writer:close()
        end)
    end
    if fileSize(relativePath) == 0 then
        return true
    end
    logLine("cache discard failed path=" .. relativePath
        .. " error=" .. safeLogValue(ok and "file not truncated" or openError))
    return false
end

local function cacheBasePath()
    local state = NBImageCache.state
    if state.basePathChecked then
        return state.basePath
    end
    state.basePathChecked = true

    local ok, root = pcall(getMyDocumentFolder)
    if not ok or type(root) ~= "string" or root == "" then
        logLine("image cache disabled: getMyDocumentFolder unavailable")
        return nil
    end

    -- 危險字樣清單在 NBCore。這裡查的是 COMMAND_HAZARDS——**護欄救不了**的那一份；
    -- 顏色類（RED／GREEN／...，見 NBCore.COLOR_HAZARDS）不必在這裡擋：絕對路徑是在
    -- NBPanel 的 processCommand 覆寫裡、過了 tokenizer 之後才換回去的，NBPanel 包在外面的
    -- 顏色護欄照樣抵銷得掉，圖可以正常顯示（否則 Windows 帳號叫 FRED／GREEN 的玩家
    -- 會永遠看不到任何同步圖）。
    -- 剩下這些字樣會讓引擎去拆寬高或解析不存在的參數，快取路徑又不可能在執行期修好，
    -- 所以偵測到就整組降級成 [替代文字] 占位並寫一次 log，讓服主看得懂為什麼沒有圖。
    local base = root .. SEPARATOR .. "Lua" .. SEPARATOR .. CACHE_DIR .. SEPARATOR
    local hazard = Core.findCommandHazard(base)
    if hazard then
        logLine("image cache disabled: cache path contains RichText-unsafe text '"
            .. hazard .. "'; notice images fall back to alt text")
        return nil
    end

    state.basePath = base
    return base
end

-- 整條管線裡**唯一無法分批**的呼叫，而且成本與目錄項數成正比：listFilesInDirectoryAux
-- 對每一個目錄項呼叫 getCanonicalFile()（LuaManager.java:6056-6068），那是 per-entry 的
-- 檔案系統呼叫。用 PZ 內附的 jre64（Zulu25.30）實測：500 項約 140ms、4000 項約 1160ms
-- （約 0.28ms/項，是同一迴圈只呼叫 getName() 的 15 倍）。一次呼叫就回整份 ArrayList，
-- 沒有分批的餘地——所以呼叫點必須壓到最少：**只有 LRU 掃描需要完整名單，每場一次**。
local function listCacheNames()
    local ok, files = pcall(function()
        return listFilesInZomboidLuaDirectory(CACHE_DIR)
    end)
    if not ok then
        logLine("image cache listing failed: " .. safeLogValue(files))
        return {}
    end
    if not files then
        return {}
    end

    local ordered = {}
    local index
    for index = 0, files:size() - 1 do
        local name = files:get(index)
        if type(name) == "string" then
            ordered[#ordered + 1] = string.lower(name)
        end
    end
    return ordered
end

-- 快取命中的條件：位元組數相符**且**本機留下的完成標記完整。少了標記這一半，
-- 一個大小剛好但內容錯的檔案會被永遠當成有效快取。
local function cacheEntryValid(hash, expectedBytes)
    return fileSize(cacheRelativePath(hash)) == expectedBytes
        and fileSize(markerRelativePath(hash)) == 8
end

-- 清掉半成品。先清標記再清圖檔——但**順序不是安全機制**：兩個 truncateFile 都是無條件
-- 呼叫，前一個失敗不會擋住後一個，所以四種失敗組合下兩種順序留下的殘局完全相同
-- （唯一會被當成好檔案的是「兩個都失敗」，與順序無關）。真正守住那個洞的是
-- truncateFile 的讀回檢查：兩個都失敗時會留下兩行 log，而不是靜默通過。
-- 之所以仍然先清標記：兩次呼叫之間玩家可以直接關掉遊戲，那一瞬間停在「標記已失效」
-- 比停在「圖檔沒了但標記還有效」安全——這是唯一還成立的理由。
local function discardPartial(hash)
    truncateFile(markerRelativePath(hash))
    truncateFile(cacheRelativePath(hash))
end

local function writeMarker(hash)
    local writer = nil
    local ok, openError = pcall(function()
        writer = getFileOutput(markerRelativePath(hash))
    end)
    if not ok or writer == nil then
        logLine("image marker open failed hash=" .. hash
            .. " error=" .. safeLogValue(ok and "getFileOutput returned nil" or openError))
        return false
    end
    -- 只有 8 個位元組，直接逐位元組寫，不必探測 writeBytes 是否可用。
    local wrote, writeError = pcall(function()
        local index
        for index = 1, 8 do
            writer:write(string.byte(hash, index))
        end
    end)
    pcall(function()
        writer:close()
    end)
    if not wrote then
        logLine("image marker write failed hash=" .. hash
            .. " error=" .. safeLogValue(writeError))
        return false
    end
    return true
end

local function closeWriteJob(job)
    if job and job.writer then
        pcall(function()
            job.writer:close()
        end)
        job.writer = nil
    end
end

-- ---------------------------------------------------------------------------
-- LRU 淘汰
--
-- PZ 沒有刪檔 API：唯一手段是 getFileOutput 開檔把內容截成 0 bytes（truncateFile），
-- 所以「刪掉」的檔案仍會留下一個 0 bytes 的目錄項。設計接受這件事——回收的是空間，
-- 不是目錄項；0 bytes 的檔在掃描時當成不存在直接跳過。
-- ponytail: 目錄項只增不減，天花板是「玩家在敵意伺服器上累積的場次數 x 每場的新 hash 數」。
-- 真要處理只能改成固定槽位檔名，但那會撞到引擎的貼圖快取（Texture.s_sharedTextureTable
-- 以路徑為鍵，Texture.java:483-485）——同一個檔名換內容會拿到舊貼圖，所以檔名必須
-- 跟著內容走。目前用寫入速率上限（Image.WRITE_WINDOW_BYTES）壓住產生速度。
--
-- 「最近使用」存在哪裡：PZ 沒有檔案時間戳 API，只能自己維護 index.txt。
-- 戳記用**場次序號**而不是牆鐘時間：序號是小整數（tostring 不會變成科學記號），
-- 也不受玩家改系統時間影響。載入時把上一場的序號 +1 當成這一場的戳記。
--
-- 全程分批：掃描每 tick 只 stat LRU_SCAN_PER_TICK 個檔、淘汰每 tick 最多
-- LRU_EVICT_PER_TICK 張。這個 codebase 所有重活都是這個形狀（純 Lua 迭代會卡影格）。
-- ---------------------------------------------------------------------------
local function lruTouch(stem)
    local lru = NBImageCache.state.lru
    lru.touched[stem] = true
    local entry = rawget(lru.entries, stem)
    if entry and entry.seq ~= lru.session then
        entry.seq = lru.session
        lru.dirty = true
    end
end

local function loadLruIndex()
    local lru = NBImageCache.state.lru
    local reader = nil
    local ok = pcall(function()
        reader = getFileReader(LRU_INDEX_FILE, false)
    end)
    if not ok or reader == nil then
        return
    end

    local lines = {}
    pcall(function()
        local count = 0
        local line = reader:readLine()
        while line ~= nil and count < LRU_INDEX_MAX_LINES do
            count = count + 1
            lines[count] = line
            line = reader:readLine()
        end
    end)
    pcall(function()
        reader:close()
    end)

    -- 表頭不合就整份當沒有。索引只影響淘汰順序：壞掉＝退回任意順序，
    -- **不會**讓任何一張已經在磁碟上的圖失效，也不會擋住面板。
    local session = nil
    if lines[1] then
        local header = string.match(lines[1], "^" .. LRU_INDEX_HEADER .. " (%d+)$")
        if header then
            session = tonumber(header)
        end
    end
    if not session then
        logLine("image cache index unreadable; eviction order degrades to arbitrary")
        return
    end
    lru.session = session + 1

    local index
    for index = 2, #lines do
        local stem, seq = string.match(lines[index], "^([a-z0-9_]+) (%d+)$")
        if stem then
            lru.seqs[stem] = tonumber(seq)
        end
    end
end

local function saveLruIndex(now)
    local lru = NBImageCache.state.lru
    -- 寫不出去就算了，也不重試：索引只是淘汰順序的提示，重試只會每 10 秒白打一次磁碟。
    lru.lastSaveMs = now
    lru.dirty = false

    local writer = nil
    local ok = pcall(function()
        writer = getFileWriter(LRU_INDEX_FILE, true, false)
    end)
    if not ok or writer == nil then
        return false
    end
    local wrote = pcall(function()
        writer:write(LRU_INDEX_HEADER .. " " .. tostring(lru.session) .. "\n")
        local stem, entry
        for stem, entry in pairs(lru.entries) do
            writer:write(stem .. " " .. tostring(entry.seq) .. "\n")
        end
    end)
    pcall(function()
        writer:close()
    end)
    return wrote
end

local function scanCacheName(name)
    local lru = NBImageCache.state.lru
    local stem = string.match(name, "^([a-z0-9_]+)%.png$")
    if not stem or rawget(lru.entries, stem) ~= nil then
        return
    end

    local path = stemPngPath(stem)
    local bytes = fileSize(path) or 0
    if string.find(stem, "_", 1, true) == nil then
        -- 舊格式 <hash>.png（沒有伺服器前綴）。來源伺服器不可考，安全修正後一律不採用；
        -- 順手截成 0 把空間還給玩家，之後每次掃描都會當成空檔跳過。
        if bytes > 0 then
            truncateFile(stemMarkerPath(stem))
            truncateFile(path)
            lru.reclaimed = (lru.reclaimed or 0) + 1
        end
        return
    end
    if bytes <= 0 then
        return
    end

    lru.entries[stem] = {
        bytes = bytes,
        seq = rawget(lru.touched, stem) and lru.session or (rawget(lru.seqs, stem) or 0),
    }
    lru.total = lru.total + bytes
    if rawget(lru.touched, stem) then
        lru.dirty = true
    end
end

-- 正在用的圖不可淘汰：目前 manifest 要的每個 hash（不論下載完了沒）都受保護。
local function protectedStems()
    local state = NBImageCache.state
    local guard = {}
    local hash
    for hash in pairs(state.wanted) do
        local stem = cacheStem(hash)
        if stem then
            guard[stem] = true
        end
    end
    return guard
end

local function evictStem(stem)
    local state = NBImageCache.state
    local lru = state.lru

    -- ready 是「這場遊戲裡這個 hash 可以直接用」的旗標，而 syncManifest 對已 ready 的
    -- hash **不會**重新驗證。淘汰了檔案卻留著 ready，同一個 hash 之後再出現在 manifest
    -- （伺服器輪替圖片時很常見）就會拿到一個 0 bytes 的檔。截斷失敗時一起撤也是對的：
    -- 標記已經被清掉，那個 hash 本來就得重驗。
    local hash = string.sub(stem, -8)
    if cacheStem(hash) == stem then
        state.ready[hash] = nil
        state.attempts[hash] = nil
    end

    -- 先清標記再清圖檔，理由同 discardPartial（順序只管「兩次呼叫之間被關掉」那一瞬間）。
    truncateFile(stemMarkerPath(stem))
    local entry = rawget(lru.entries, stem)
    if not truncateFile(stemPngPath(stem)) then
        -- 截斷失敗＝檔案還在磁碟上（防毒鎖檔／OneDrive／磁碟滿）。**不可以**把 bytes
        -- 從帳上扣掉：掃描名單是進場當下的快照，這個 stem 這一場不會再被看到，帳一旦
        -- 低估就整場低估——淘汰會自認做完並回到 idle，磁碟卻持續超出上限。
        -- 改成標記起來讓淘汰迴圈換下一個受害者；全部都動不了時由 evictStep 的
        -- victim == nil 那條路收尾（寫一次 log 後結束，不會空轉）。
        entry.stuck = true
        return
    end
    lru.evictedBytes = lru.evictedBytes + entry.bytes
    lru.evictedCount = lru.evictedCount + 1
    lru.total = lru.total - entry.bytes
    lru.entries[stem] = nil
    lru.dirty = true
end

local function evictStep()
    local lru = NBImageCache.state.lru
    local guard = protectedStems()
    local evicted = 0
    while evicted < LRU_EVICT_PER_TICK and lru.total > Image.CACHE_BUDGET_BYTES do
        local victim = nil
        local victimSeq = nil
        local stem, entry
        for stem, entry in pairs(lru.entries) do
            -- stuck＝這一場截斷失敗過的檔（見 evictStem），再挑一次也只是白開一次檔。
            if rawget(guard, stem) ~= true and entry.stuck ~= true then
                -- 同 seq 時用字典序決勝，讓行為可重現（pairs 的順序不保證）。
                if victim == nil
                    or entry.seq < victimSeq
                    or (entry.seq == victimSeq and stem < victim) then
                    victim = stem
                    victimSeq = entry.seq
                end
            end
        end
        if victim == nil then
            -- 剩下的全是這份 manifest 正在用的圖（或這一場截不掉的檔）。不動：把正在用的
            -- 圖截成 0 會讓面板拿到壞檔，比暫時超出上限嚴重得多。
            if not lru.fullLogged then
                lru.fullLogged = true
                logLine("image cache over budget bytes=" .. tostring(lru.total)
                    .. " but every entry is in use or locked; nothing evicted")
            end
            return true
        end
        evictStem(victim)
        evicted = evicted + 1
    end
    return lru.total <= Image.CACHE_BUDGET_BYTES
end

local function enterEvict()
    local lru = NBImageCache.state.lru
    lru.phase = "evict"
    lru.evictedCount = 0
    lru.evictedBytes = 0
end

-- 新寫進來的一張圖。掃描還沒走到它時也要記帳——掃描用的是進場當下的名單快照。
local function lruAccount(stem, bytes)
    local lru = NBImageCache.state.lru
    local existing = rawget(lru.entries, stem)
    if existing then
        lru.total = lru.total - existing.bytes
    end
    lru.entries[stem] = { bytes = bytes, seq = lru.session }
    lru.touched[stem] = true
    lru.total = lru.total + bytes
    lru.dirty = true
    if lru.phase == "idle" and lru.total > Image.CACHE_BUDGET_BYTES then
        enterEvict()
    end
end

-- 時間窗換窗：額度重新裝滿，並把「只是被額度擋下」的 hash 放回可重試狀態。
-- 真正失敗（開檔失敗／驗證失敗）的 attempts 不在 deferred 裡，不受影響。
local function pumpWindow(now)
    local state = NBImageCache.state
    if state.windowStartMs == 0 then
        state.windowStartMs = now
        return
    end
    if now - state.windowStartMs < Image.WRITE_WINDOW_MS then
        return
    end
    state.windowStartMs = now
    state.windowWritten = 0
    state.budgetLogged = false
    local hash
    for hash in pairs(state.deferred) do
        state.attempts[hash] = nil
    end
    state.deferred = {}
end

local function pumpLru(now)
    local state = NBImageCache.state
    local lru = state.lru
    -- 寫入中的 job 握著一個跨 tick 的 DataOutputStream，而 getFileOutput 開檔失敗時
    -- **不會**回 nil：它回的是 DataOutputStream(上一個成功開啟的 static outStream)
    -- （LuaManager.java:5833-5840）。那個殼的 close() 會關掉寫到一半的圖檔。
    -- 所以淘汰／舊格式回收一律等 job 結束再做——沒有 job 就沒有這個別名窗口。
    if state.writeJob then
        return
    end

    if lru.phase == "load" then
        loadLruIndex()
        lru.names = listCacheNames()
        lru.cursor = 0
        lru.reclaimed = 0
        lru.phase = "scan"
        return
    end

    if lru.phase == "scan" then
        local budget = LRU_SCAN_PER_TICK
        while budget > 0 and lru.cursor < #lru.names do
            lru.cursor = lru.cursor + 1
            budget = budget - 1
            scanCacheName(lru.names[lru.cursor])
        end
        if lru.cursor >= #lru.names then
            lru.names = nil
            lru.seqs = {}
            logLine("image cache scan done bytes=" .. tostring(lru.total)
                .. " budget=" .. tostring(Image.CACHE_BUDGET_BYTES)
                .. " legacyReclaimed=" .. tostring(lru.reclaimed))
            enterEvict()
        end
        return
    end

    if lru.phase == "evict" then
        if evictStep() then
            lru.phase = "idle"
            if lru.evictedCount > 0 then
                logLine("image cache evicted entries=" .. tostring(lru.evictedCount)
                    .. " bytes=" .. tostring(lru.evictedBytes)
                    .. " remaining=" .. tostring(lru.total))
            end
        end
        return
    end

    if lru.dirty and now - lru.lastSaveMs >= LRU_SAVE_INTERVAL_MS then
        saveLruIndex(now)
    end
end

-- 換連線來源時所有 per-server 的判斷一律作廢。42.20.2 的引擎會在離開 IngameState 時
-- 重建整個 Lua 環境（出處見 serverToken 上方），所以這條路實務上走不到——它是縱深防禦，
-- 保護的是「引擎行為變了」或「state 被改成跨場次持久化」的那天。
-- 尤其 ready——它是「這個 hash 的檔案已經驗過」的旗標，而檔案是連同命名空間
-- 一起認的；留著會讓面板以為圖已就緒，實際上那個檔在上一台的命名空間底下，
-- 整場遊戲該圖靜默消失。LRU 帳不動：它的鍵是完整檔名主幹，跨伺服器本來就是共用的。
-- 寫到一半的檔案只關串流、**不**呼叫 discardPartial：那個檔在上一台的命名空間底下，
-- 而 discardPartial 會用現在的命名空間去組路徑，砍到的是別的檔案。留著也安全——
-- 它的位元組數對不上，回到那台時驗證必然失敗而重下載，期間由 LRU 負責回收。
-- 寫入時間窗也不重置：它保護的是玩家的磁碟，不該因為換一台伺服器就重新裝滿。
local function forgetServerState()
    local state = NBImageCache.state
    closeWriteJob(state.writeJob)
    state.writeJob = nil
    state.signature = nil
    state.ready = {}
    state.attempts = {}
    state.deferred = {}
    state.pending = {}
    state.writeQueue = {}
    state.verifyQueue = {}
end

local function syncManifest()
    local state = NBImageCache.state
    local receiver = Reader.getReceiverState()
    local signature = rawget(receiver, "imagesSignature") or ""
    if signature == state.signature then
        return
    end
    state.signature = signature

    local images = rawget(receiver, "images") or {}
    -- 傳輸進度只認 hash，而 hash 就是內容——manifest 變了不代表已經收到的分塊作廢。
    -- 舊版無條件清空，於是服主「多加一張圖」（或原地覆蓋偵測產生一個新 hash）就會把
    -- 其餘每一張正在傳、甚至已經傳完在等寫檔的圖打回第 0 塊。輪替圖片的伺服器
    -- 每個輪詢週期都踩一次，玩家永遠同步不完。
    local carriedPending = state.pending
    local carriedWrites = state.writeQueue
    state.wanted = {}
    state.byName = {}
    state.order = {}
    state.pending = {}
    state.writeQueue = {}
    state.attempts = {}
    state.verifyQueue = {}
    state.lastRequestMs = 0

    local seen = {}
    local index
    for index = 1, #images do
        local entry = images[index]
        state.byName[string.lower(entry.name)] = entry
        if not rawget(seen, entry.h) then
            seen[entry.h] = true
            state.wanted[entry.h] = entry
            state.order[#state.order + 1] = entry.h
            if rawget(state.ready, entry.h) ~= true then
                state.verifyQueue[#state.verifyQueue + 1] = entry.h
            end
            -- 只有宣告值也一模一樣才續用：同一個 h 配上不同的 n／b 只可能來自惡意或
            -- 壞掉的 manifest，舊分塊對不上新宣告，整份丟掉重來比較便宜也比較安全。
            local carried = rawget(carriedPending, entry.h)
            if carried and carried.n == entry.n and carried.b == entry.b then
                state.pending[entry.h] = carried
            end
        end
    end

    -- 已經收齊、正在排隊等寫檔的 payload 同理（這批是最貴的：整張都下載完了）。
    for index = 1, #carriedWrites do
        local queued = carriedWrites[index]
        local entry = rawget(state.wanted, queued.hash)
        if entry and string.len(queued.text) == Image.encodedLength(entry.b) then
            state.writeQueue[#state.writeQueue + 1] = queued
        end
    end

    -- 已不在清單內的 hash：ready 標記留著也無害（檔名即內容 hash），但寫到一半的 job 要停掉。
    if state.writeJob and rawget(state.wanted, state.writeJob.hash) == nil then
        closeWriteJob(state.writeJob)
        discardPartial(state.writeJob.hash)
        state.writeJob = nil
    end

    if #state.order > 0 then
        logLine("image manifest images=" .. tostring(#state.order)
            .. " toVerify=" .. tostring(#state.verifyQueue))
    end
end

-- 命中與否只問磁碟，**不先列目錄**：cacheEntryValid 兩次 getFileInput，而檔案不存在時
-- 引擎自己就回 nil（LuaManager.java:6864-6881），所以「先列一份檔名 set 做存在性查詢」
-- 省不到任何一次開檔，卻要付 listCacheNames 的整份目錄成本（上面有實測數字）。
-- 更糟的是那份 set 由 syncManifest 設回 nil＝**圖片清單每變動一次就重列一次**，
-- 而伺服器原地覆蓋圖片會產生新 hash，輪替圖片的伺服器每個輪詢週期都踩一次。
local function pumpVerify()
    local state = NBImageCache.state
    if #state.verifyQueue == 0 then
        return
    end

    local hash = table.remove(state.verifyQueue, 1)
    local entry = rawget(state.wanted, hash)
    if not entry then
        return
    end
    if cacheEntryValid(hash, entry.b) then
        state.ready[hash] = true
        state.readyVersion = state.readyVersion + 1
        lruTouch(cacheStem(hash))
    end
end

-- from[i] = hashes[i] 這張圖要從第幾個分塊開始送（續傳起點）。舊版 server 忽略未知欄位，
-- 會從第 1 塊送到底——那正是續傳前的行為，所以協定兩個方向都能安全降級。
local function sendImageRequest(hashes, froms)
    local ok, commandError = pcall(function()
        local payload = { hashes = hashes, from = froms }
        if isClient() then
            sendClientCommand(Reader.MODULE, "imgreq", payload)
        else
            -- SP：沒有網路層，走同 VM 的本地命令事件送給 NBServer。
            triggerEvent(Reader.LOCAL_CMD_EVENT, Reader.MODULE, "imgreq", payload)
        end
    end)
    if not ok then
        logLine("imgreq send failed: " .. safeLogValue(commandError))
        return false
    end
    return true
end

-- stalled 的傳輸沒有在動，不佔併發額度——否則 REQUEST_BATCH 個 stalled 會讓 pumpRequest
-- 永遠早退，續傳請求一則都送不出去（死結）。
local function countPending()
    local state = NBImageCache.state
    local count = 0
    local _, pending
    for _, pending in pairs(state.pending) do
        if not pending.stalled then
            count = count + 1
        end
    end
    return count
end

-- 續傳起點：最小的、還沒收到的分塊索引。伺服器從這裡往後送到底。
-- 為什麼不送「缺塊清單」：分塊是照順序推的，洞極少見，而清單會讓 imgreq 的大小
-- 跟著圖片大小長（一張 4MB 的圖有近千塊），一個數字則永遠是一個數字。
-- 真的有洞時只是把洞前面那幾塊重送一次，receiveChunk 覆寫同索引不會重複計數。
local function firstMissingChunk(pending)
    if not pending then
        return 1
    end
    local index = 1
    while rawget(pending.parts, index) ~= nil do
        index = index + 1
    end
    return index
end

local function pumpRequest(now)
    local state = NBImageCache.state
    if #state.verifyQueue > 0 then
        return
    end
    local inFlight = countPending() + #state.writeQueue
    if state.writeJob then
        inFlight = inFlight + 1
    end
    if inFlight >= REQUEST_BATCH then
        return
    end
    if state.lastRequestMs ~= 0 and now - state.lastRequestMs < REQUEST_INTERVAL_MS then
        return
    end

    local hashes = {}
    local froms = {}
    local resumed = 0
    local index
    for index = 1, #state.order do
        local hash = state.order[index]
        local pending = rawget(state.pending, hash)
        -- stalled 的 hash 也是可要求的——這正是續傳的入口。它前面收到的分塊還在
        -- pending.parts 裡，froms 會把起點指到第一個缺的那塊。
        if rawget(state.ready, hash) ~= true
            and (pending == nil or pending.stalled == true)
            and (rawget(state.attempts, hash) or 0) < MAX_ATTEMPTS then
            hashes[#hashes + 1] = hash
            froms[#froms + 1] = firstMissingChunk(pending)
            if froms[#froms] > 1 then
                resumed = resumed + 1
            end
            -- 併發上限要把「已經在飛的」算進去：舊版固定收滿 REQUEST_BATCH 個，
            -- 續傳讓 stalled 也變成可要求之後，那會讓同時在傳的張數疊上去
            -- （每一張都握著一份 base64 字串）。
            if #hashes + inFlight >= REQUEST_BATCH then
                break
            end
        end
    end
    if #hashes == 0 then
        return
    end

    state.lastRequestMs = now
    if not sendImageRequest(hashes, froms) then
        return
    end
    -- 送出去了才把 stalled 收掉並重新計時：送失敗還清掉的話，那個 hash 會白等
    -- 一整個 PENDING_TIMEOUT_MS 才重新變成 stalled。
    for index = 1, #hashes do
        local pending = rawget(state.pending, hashes[index])
        if pending then
            pending.stalled = false
            pending.startedAt = now
        end
    end
    logLine("imgreq sent images=" .. tostring(#hashes)
        .. " resumed=" .. tostring(resumed))
end

-- 逾時的語意是「PENDING_TIMEOUT_MS 內沒有任何進度」（receiveChunk 每收到一個新分塊就
-- 重新計時），不是「沒在時限內傳完」：後者會把慢伺服器上的大圖判成失敗，而那張圖其實
-- 一直在前進。
local function expirePending(now)
    local state = NBImageCache.state
    local expired = {}
    local hash, pending
    for hash, pending in pairs(state.pending) do
        if not pending.stalled and now - pending.startedAt >= PENDING_TIMEOUT_MS then
            expired[#expired + 1] = hash
        end
    end

    local index
    for index = 1, #expired do
        hash = expired[index]
        pending = rawget(state.pending, hash)
        local attempts = (rawget(state.attempts, hash) or 0) + 1
        state.attempts[hash] = attempts
        -- **已收到的分塊留著**（舊版整份丟掉，於是每次重試都從第 0 塊重來——
        -- 掉包的連線因此永遠收不完一張圖，三次之後整場退回替代文字）。
        -- 但放棄重試的 hash 沒有留的理由，直接釋放。
        -- pending 的記憶體上界**不是** REQUEST_BATCH：stalled 的 hash 不佔併發額度
        -- （countPending 刻意不算它們），所以同時握著 parts 的張數可以是整份 manifest。
        -- 真正的界在接收端——NBReader.normalizeImages 把宣告總量夾在
        -- Image.MAX_TOTAL_KB（16MB）之內，base64 是 4/3 倍，於是最壞情況約 21MB 字串，
        -- 且只到 MAX_ATTEMPTS 用完為止。
        if attempts >= MAX_ATTEMPTS then
            state.pending[hash] = nil
        else
            pending.stalled = true
        end
        logLine("image transfer stalled hash=" .. hash
            .. " received=" .. tostring(pending.received)
            .. "/" .. tostring(pending.n)
            .. " attempt=" .. tostring(attempts))
    end
end

-- 寫入方法在開檔當下就探測完。用空字串探測是關鍵：Kahlua 在方法不存在時是「呼叫前就拋錯」，
-- 而寫到一半才拋錯無從得知已經有幾個位元組落地，此時再退回逐位元組重寫整批，
-- 檔案裡就會留下重複的位元組——長度計數與 digest 都是 Lua 端算的，兩者都看不出來。
local function detectWriteMethod(job)
    local ok = pcall(function()
        job.writer:writeBytes("")
    end)
    if ok then
        job.method = "writeBytes"
    else
        job.method = "write"
    end
end

local function startWriteJob()
    local state = NBImageCache.state
    while #state.writeQueue > 0 do
        local queued = table.remove(state.writeQueue, 1)
        local entry = rawget(state.wanted, queued.hash)
        if entry and rawget(state.ready, queued.hash) ~= true
            and state.windowWritten + entry.b > Image.WRITE_WINDOW_BYTES then
            -- 時間窗的寫入額度（玩家保護，**絕對常數、不隨伺服器宣告的總量縮放**，
            -- 取值理由見 NBImage.WRITE_WINDOW_BYTES）。惡意 server 可以無限輪替
            -- manifest（每輪一批新 hash）讓 client 一直寫新檔，淘汰只會讓它一直有空間可寫，
            -- 所以速率仍要有界。額度用盡就這個窗停手：attempts 拉到上限讓 pumpRequest
            -- 不再要這個 hash，同時記進 deferred——下一個窗會把它清掉重排，
            -- 不像舊版那樣整場遊戲不恢復。
            state.attempts[queued.hash] = MAX_ATTEMPTS
            state.deferred[queued.hash] = true
            if not state.budgetLogged then
                state.budgetLogged = true
                logLine("image cache write budget exhausted for this window bytes="
                    .. tostring(state.windowWritten)
                    .. "; deferred images retry after "
                    .. tostring(math.floor(Image.WRITE_WINDOW_MS / 60000)) .. " min")
                -- 遊戲內回饋。旗標與 log 共用，所以**一個時間窗最多一則**：誠實伺服器
                -- 永遠走不到這裡（合法上界 16MB 遠低於 64MB 的窗額度），惡意伺服器
                -- 也只能每 WRITE_WINDOW_MS 讓玩家看到一則。
                -- 沒有對應的「已恢復」提示：那是 30 分鐘後的事，玩家早忘了自己看過什麼，
                -- 而恢復本來就會自己表現成「圖出現了」。
                triggerStatus({
                    kind = "budget",
                    minutes = math.floor(Image.WRITE_WINDOW_MS / 60000),
                })
            end
        elseif entry and rawget(state.ready, queued.hash) ~= true then
            -- 先讓完成標記失效再開圖檔：開檔就會把舊圖截成 0，若標記還留著上一輪的有效內容，
            -- 這次寫失敗時磁碟上就是「半成品 + 有效標記」。順序也讓圖檔是最後開的串流
            -- （getFileOutput 會覆寫 LuaManager 的 static outStream，LuaManager.java:5835）。
            truncateFile(markerRelativePath(queued.hash))
            local writer = nil
            local ok, openError = pcall(function()
                writer = getFileOutput(cacheRelativePath(queued.hash))
            end)
            if not ok or writer == nil then
                state.attempts[queued.hash] = (rawget(state.attempts, queued.hash) or 0) + 1
                logLine("image write open failed hash=" .. queued.hash
                    .. " error=" .. safeLogValue(ok and "getFileOutput returned nil" or openError))
            else
                state.windowWritten = state.windowWritten + entry.b
                state.writeJob = {
                    hash = queued.hash,
                    text = queued.text,
                    length = string.len(queued.text),
                    position = 1,
                    writer = writer,
                    digest = Image.hashInit(),
                    written = 0,
                    expectedBytes = entry.b,
                    chunks = entry.n,
                    method = nil,
                    startMs = getTimestampMs(),
                    maxBatchMs = 0,
                    workMs = 0,
                }
                detectWriteMethod(state.writeJob)
                return true
            end
        end
    end
    return false
end

-- 一次呼叫寫完整批：DataOutputStream.writeBytes(String) 對每個 char 只取低 8 bits，
-- 正是我們解碼結果的形狀。退路才是逐位元組 write(int)（每 tick 上千次反射呼叫，會明顯拖慢）。
-- 這裡不做任何錯誤吞噬：方法早在 detectWriteMethod 決定好，寫入途中的錯誤一律往上拋給
-- pumpWrite 的 pcall，由它清掉半成品並重試。
local function writeByteString(job, byteString)
    local length = string.len(byteString)
    if length == 0 then
        return
    end

    if job.method == "writeBytes" then
        job.writer:writeBytes(byteString)
        return
    end

    local index
    for index = 1, length do
        job.writer:write(string.byte(byteString, index))
    end
end

local function finishWriteJob(job)
    local state = NBImageCache.state
    closeWriteJob(job)
    state.writeJob = nil

    local digestHex = Image.hashHex(job.digest)
    local elapsed = math.floor(getTimestampMs() - job.startMs)
    if job.written ~= job.expectedBytes or digestHex ~= job.hash then
        discardPartial(job.hash)
        state.attempts[job.hash] = (rawget(state.attempts, job.hash) or 0) + 1
        logLine("image verify failed hash=" .. job.hash
            .. " bytes=" .. tostring(job.written)
            .. " expected=" .. tostring(job.expectedBytes)
            .. " digest=" .. digestHex
            .. " attempt=" .. tostring(state.attempts[job.hash]))
        return
    end

    -- 標記寫不出去不算失敗：這次連線照樣用這張圖，只是下次進場會重新下載。
    writeMarker(job.hash)
    state.ready[job.hash] = true
    state.readyVersion = state.readyVersion + 1
    lruAccount(cacheStem(job.hash), job.written)
    -- writeMs 是每批耗時的累加（真正花掉的 client 時間）；startMs 到現在的牆鐘差含每個 tick
    -- 之間的閒置與等分塊的時間，會隨 FPS 浮動，拿來調 WRITE_BYTES_PER_TICK 只會誤導。
    logLine("image cached hash=" .. job.hash
        .. " bytes=" .. tostring(job.written)
        .. " chunks=" .. tostring(job.chunks)
        .. " writeMs=" .. tostring(math.floor(job.workMs))
        .. " spanMs=" .. tostring(elapsed)
        .. " maxBatchMs=" .. tostring(math.floor(job.maxBatchMs))
        .. " method=" .. tostring(job.method))
end

local function pumpWrite()
    local state = NBImageCache.state
    if not state.writeJob and not startWriteJob() then
        return
    end

    local job = state.writeJob
    local batchStartMs = getTimestampMs()
    local ok, batchError = pcall(function()
        local charBudget = math.floor(Image.WRITE_BYTES_PER_TICK / 3) * 4
        local remaining = job.length - job.position + 1
        local charCount = charBudget
        if charCount > remaining then
            charCount = remaining
        end

        local byteString = Image.decodeToByteString(job.text, job.position, charCount)
        job.digest = Image.hashUpdate(job.digest, job.text,
            job.position, job.position + charCount - 1)
        writeByteString(job, byteString)
        job.written = job.written + string.len(byteString)
        job.position = job.position + charCount
    end)

    local batchMs = getTimestampMs() - batchStartMs
    job.workMs = job.workMs + batchMs
    if batchMs > job.maxBatchMs then
        job.maxBatchMs = batchMs
    end

    if not ok then
        closeWriteJob(job)
        state.writeJob = nil
        discardPartial(job.hash)
        state.attempts[job.hash] = (rawget(state.attempts, job.hash) or 0) + 1
        logLine("image write failed hash=" .. job.hash
            .. " error=" .. safeLogValue(batchError))
        return
    end

    if job.position > job.length then
        finishWriteJob(job)
    end
end

function NBImageCache.receiveChunk(args)
    if type(args) ~= "table" then
        return
    end
    local state = NBImageCache.state
    local hash = rawget(args, "h")
    local index = rawget(args, "i")
    local part = rawget(args, "part")
    if not Image.isHash(hash) then
        return
    end

    local entry = rawget(state.wanted, hash)
    if not entry or rawget(state.ready, hash) == true then
        return
    end
    if type(index) ~= "number" or index ~= math.floor(index)
        or index < 1 or index > entry.n then
        return
    end
    if type(part) ~= "string" or Core.utf16Length(part) > Core.CHUNK_UTF16_LIMIT then
        return
    end

    local pending = rawget(state.pending, hash)
    if pending and (pending.n ~= entry.n or pending.b ~= entry.b) then
        -- 同一個 h 換了 n／b：只可能來自惡意或壞掉的 manifest。留著的分塊對不上新宣告，
        -- 整份丟掉重來（syncManifest 的續用條件同一份規則）。
        pending = nil
        state.pending[hash] = nil
    end
    if not pending then
        pending = {
            parts = {},
            received = 0,
            startedAt = getTimestampMs(),
            n = entry.n,
            b = entry.b,
            stalled = false,
        }
        state.pending[hash] = pending
    end
    if rawget(pending.parts, index) == nil then
        pending.received = pending.received + 1
        -- 有進度就重新計時、並收掉 stalled（伺服器已經在回應了）。
        pending.startedAt = getTimestampMs()
        pending.stalled = false
    end
    pending.parts[index] = part

    if pending.received < entry.n then
        return
    end

    state.pending[hash] = nil
    local text = table.concat(pending.parts)
    -- 便宜的形狀檢查，擋掉長度就不對的資料，省下整趟解碼＋寫檔。
    if string.len(text) ~= Image.encodedLength(entry.b) then
        state.attempts[hash] = (rawget(state.attempts, hash) or 0) + 1
        logLine("image payload length mismatch hash=" .. hash
            .. " chars=" .. tostring(string.len(text))
            .. " expected=" .. tostring(Image.encodedLength(entry.b)))
        return
    end
    state.writeQueue[#state.writeQueue + 1] = { hash = hash, text = text }
end

function NBImageCache.onTick()
    local ok, tickError = pcall(function()
        local now = getTimestampMs()
        -- 連線位址還沒就緒（MP 剛進場的幾個 tick）時整輪不做事：命名空間錯掉的檔案
        -- 之後永遠命不中，卻會一直佔著空間。
        if not serverToken() then
            return
        end
        local state = NBImageCache.state
        if state.serverChanged then
            state.serverChanged = false
            forgetServerState()
        end
        pumpWindow(now)
        syncManifest()
        pumpVerify()
        pumpWrite()
        pumpLru(now)
        expirePending(now)
        pumpRequest(now)
    end)
    if not ok then
        logLine("image cache tick failed: " .. safeLogValue(tickError))
    end
end

function NBImageCache.hashForPath(path)
    if type(path) ~= "string" then
        return nil
    end
    local name = string.match(path, "^" .. Image.IMAGE_DIR .. "/(.+)$")
    if not name then
        return nil
    end
    local entry = rawget(NBImageCache.state.byName, string.lower(name))
    if not entry then
        return nil
    end
    return entry.h
end

function NBImageCache.isReady(hash)
    return type(hash) == "string" and rawget(NBImageCache.state.ready, hash) == true
end

function NBImageCache.pathForHash(hash)
    if not NBImageCache.isReady(hash) then
        return nil
    end
    local base = cacheBasePath()
    if not base then
        return nil
    end
    -- 檔名主幹（伺服器命名空間 + hash）只含 [a-z0-9_]，不可能命中 COMMAND_HAZARDS
    -- （那些字樣不是標點就是全大寫），所以危險字樣只需要在 base 那一段檢查。
    local stem = cacheStem(hash)
    if not stem then
        return nil
    end
    return base .. stem .. ".png"
end

function NBImageCache.getReadyVersion()
    return NBImageCache.state.readyVersion
end

function NBImageCache.getState()
    return NBImageCache.state
end

if not NBImageCache._eventsInstalled then
    LuaEventManager.AddEvent(NBImageCache.STATUS_EVENT)
    Reader.onImageChunk = NBImageCache.receiveChunk
    -- 不加 isClient() 守衛：SP 也要跑（SP 的 server 端在同一個 VM，走本地事件投遞）。
    Events.OnTick.Add(NBImageCache.onTick)
    NBImageCache._eventsInstalled = true
end

return NBImageCache
