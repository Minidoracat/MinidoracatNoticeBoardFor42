local SHARED_LUA = "MOD/MinidoracatNoticeBoardFor42/Contents/mods/"
    .. "MinidoracatNoticeBoardFor42/42/media/lua/shared/"
package.path = SHARED_LUA .. "?.lua;" .. package.path

local NBCore = require "NoticeBoard/NBCore"
local NBImage = require "NoticeBoard/NBImage"
local MDParser = require "NoticeBoard/MDParser"

local assertionCount = 0

local function check(condition, message)
    assertionCount = assertionCount + 1
    assert(condition, message)
end

local function checkEqual(actual, expected, message)
    assertionCount = assertionCount + 1
    assert(
        actual == expected,
        (message or "values differ")
            .. "\nexpected: " .. tostring(expected)
            .. "\nactual:   " .. tostring(actual)
    )
end

local function contains(text, fragment)
    return string.find(text, fragment, 1, true) ~= nil
end

local expectedLanguages = {
    "AR", "CA", "CH", "CN", "CS", "DA", "DE", "EN", "ES", "ES_CL",
    "ES_MX", "FI", "FR", "HU", "ID", "IT", "JP", "KO", "NL", "NO",
    "PL", "PT", "PTBR", "RO", "RU", "STREW", "TH", "TR", "UA",
}

local languageCount = 0
for _ in pairs(NBCore.LANGS) do
    languageCount = languageCount + 1
end
checkEqual(languageCount, #expectedLanguages, "LANGS 必須等於實列的原版目錄集")
local languageIndex
for languageIndex = 1, #expectedLanguages do
    local language = expectedLanguages[languageIndex]
    check(NBCore.LANGS[language] == true, "LANGS 缺少 " .. language)
end
check(NBCore.LANGS.EN and NBCore.LANGS.CH, "LANGS 至少必須包含 EN 與 CH")
check(NBCore.LANGS.STREW == true, "實際存在的 STREW 必須納入白名單")

-- 語系清單／偏好的正規化：NBServer 產生 manifest、NBReader 驗收、NBClient 讀 settings.ini
-- 三處共用同一份規則。期望值一律寫字面字串，不引用被測模組自己的常數。
local langList, langListError = NBCore.normalizeLanguageList({ "EN", "CH", "EN" })
checkEqual(langListError, nil, "合法語系清單不應回報錯誤")
checkEqual(#langList, 2, "重複語系必須去重")
checkEqual(langList[1], "EN", "去重後第一個語系錯誤")
checkEqual(langList[2], "CH", "去重後第二個語系錯誤")
check(NBCore.normalizeLanguageList({}) ~= nil, "空清單是合法的（伺服器還沒有任何內容）")
check(NBCore.normalizeLanguageList({ "EN", "XX" }) == nil, "白名單外的語系必須整份拒絕")
check(NBCore.normalizeLanguageList({ "EN", 42 }) == nil, "非字串條目必須拒絕")
check(NBCore.normalizeLanguageList("EN") == nil, "非 table 的語系清單必須拒絕")
local oversizeLangs = {}
local oversizeIndex
for oversizeIndex = 1, 33 do
    oversizeLangs[oversizeIndex] = "EN"
end
check(NBCore.normalizeLanguageList(oversizeLangs) == nil, "超過上界的語系清單必須拒絕")

checkEqual(NBCore.normalizeLanguagePreference("CH"), "CH", "合法語系偏好應原樣保留")
checkEqual(NBCore.normalizeLanguagePreference("auto"), "auto", "auto 必須保留")
checkEqual(NBCore.normalizeLanguagePreference("ch"), "auto", "大小寫不符必須視為 auto")
checkEqual(NBCore.normalizeLanguagePreference("zz"), "auto", "白名單外的值必須視為 auto")
checkEqual(NBCore.normalizeLanguagePreference(nil), "auto", "缺值必須視為 auto")
checkEqual(NBCore.normalizeLanguagePreference(42), "auto", "非字串必須視為 auto")

checkEqual(NBCore.djb2Hex("hello"), "0f923099", "DJB2 ASCII 固定向量錯誤")
-- 固定向量（非函式對自身比較）：鎖住 CJK＋surrogate 內容的實際 hash，且證明對內容敏感
checkEqual(NBCore.djb2Hex("公告😀"), "aa864618", "DJB2 CJK+emoji 固定向量錯誤")
check(NBCore.djb2Hex("公告😀") ~= NBCore.djb2Hex("公告"), "DJB2 必須對內容敏感")

local escaped = NBCore.escapeRichText("甲 < 乙 > 丙")
checkEqual(escaped, "甲 &lt; 乙 &gt; 丙", "RichText angle bracket 轉義錯誤")
checkEqual(NBCore.unescapeRichText(escaped), "甲 < 乙 > 丙", "RichText 反轉義錯誤")
checkEqual(
    NBCore.sanitizeName("Bad[Name]\r\n\tTail]"),
    "Bad(Name)Tail)",
    "sanitizeName 必須移除控制字元並替換中括號"
)
-- log 行是空白分隔的 key=value；PZ username 允許空白／=／|，不換掉就能偽造欄位
checkEqual(
    NBCore.sanitizeName("bob v=999 x"),
    "bob_v_999_x",
    "sanitizeName 必須把空白與 = 換成底線，否則 log 欄位可被 username 偽造"
)
checkEqual(
    NBCore.sanitizeName("a|b"),
    "a_b",
    "sanitizeName 必須把 | 換成底線（ReadState 與 log 都以 | 分欄）"
)

-- 期望值一律寫「字面字串」，不得引用 MDParser 自己的常數——否則常數被改壞時測試仍恆真。
-- norm 只把連續空白收斂成單一空白，讓期望值可讀；tag 前後的必要空白仍受 tokenizer 測試把關。
local function norm(text)
    text = string.gsub(tostring(text), "%s+", " ")
    text = string.gsub(text, "^%s+", "")
    return string.gsub(text, "%s+$", "")
end

--[[
  引擎 tokenizer 移植（ISRichTextPanel.lua:458-558 的文字/命令切分部分）。
  這是本檔最重要的測試工具：richText 字串長得「對」不代表引擎會照著畫。
  引擎規則：以空白切 token；只要一個 token 同時含 < 與 >，整個 token 被當成 command，
  <> 之外的字元（包含 < 前面的文字）全部丟棄；最後沒有空白收尾的殘段則整段當字面文字。
]]
local function tokenizeLikeEngine(richText)
    local leftText = richText
    local cur = 0
    local commands, visible = {}, {}
    local done = false
    local guard = 0

    local function pushVisible(fragment)
        fragment = string.gsub(fragment, "&lt;", "<")
        fragment = string.gsub(fragment, "&gt;", ">")
        fragment = norm(fragment)
        if fragment ~= "" then
            visible[#visible + 1] = fragment
        end
    end

    while not done do
        guard = guard + 1
        if guard > 200000 then
            error("tokenizer guard tripped")
        end
        cur = string.find(leftText, " ", cur + 1)
        if cur ~= nil then
            local token = string.sub(leftText, 0, cur)
            if string.find(token, "<", 1, true) and string.find(token, ">", 1, true) then
                cur = string.find(token, ">", 1, true) + 1
                token = string.sub(leftText, 0, cur - 1)
            end
            leftText = string.sub(leftText, cur)
            cur = 1
            local open = string.find(token, "<", 1, true)
            local close = string.find(token, ">", 1, true)
            if open and close then
                commands[#commands + 1] = string.sub(token, open + 1, close - 1)
            else
                pushVisible(token)
            end
        else
            pushVisible(leftText)
            done = true
        end
    end
    return commands, table.concat(visible, " ")
end

-- 自我驗證：tokenizer 移植本身要能重現引擎的丟字行為，否則下面的斷言毫無意義
local _, droppedDemo = tokenizeLikeEngine("<H1>標題<LINE>正文 尾字")
check(
    not contains(droppedDemo, "標題"),
    "tokenizer 移植錯誤：`文字<TAG>` 必須重現引擎的丟字行為，實際可見：" .. droppedDemo
)
check(contains(droppedDemo, "尾字"), "tokenizer 移植錯誤：正常文字不該被丟棄")

-- 沒有任何來源文字可以在送進引擎後消失，也不得有 tag 洩漏成字面文字
local function checkNoTextLost(markdown, expectedTexts, label)
    local parsed = MDParser.safeParse(markdown)
    check(parsed.ok, label .. "：parser 不應失敗")
    local _, visibleText = tokenizeLikeEngine(parsed.richText)
    local index
    for index = 1, #expectedTexts do
        check(
            contains(visibleText, expectedTexts[index]),
            label .. "：來源文字「" .. expectedTexts[index] .. "」被引擎 tokenizer 丟棄\n實際可見："
                .. visibleText
        )
    end
    check(
        not contains(visibleText, "<"),
        label .. "：tag 洩漏成字面文字\n實際可見：" .. visibleText
    )
end

checkNoTextLost(
    "# 歡迎來到伺服器\n\n## 本週提醒\n\n請先閱讀 **重要規則**。\n\n- 尊重其他玩家。\n- 不要破壞安全屋。\n\n---\n\n[官方網站](https://projectzomboid.com)\n",
    {
        "歡迎來到伺服器", "本週提醒", "請先閱讀", "重要規則", "。",
        "尊重其他玩家", "不要破壞安全屋", "官方網站",
    },
    "服主指南完整範例"
)
checkNoTextLost("**整行粗體**", { "整行粗體" }, "粗體結尾（尾段無空白）")
checkNoTextLost("# 標題", { "標題" }, "單一標題（尾段無空白）")
checkNoTextLost("# ![替代](images/x.png) 大標", { "大標" }, "含圖片的 H1 標題（另一組前綴）")
checkNoTextLost("結尾是圖 ![替代](media/textures/a.png)", { "結尾是圖" }, "圖片結尾")
checkNoTextLost("English **bold** tail", { "English", "bold", "tail" }, "拉丁文粗體")
checkNoTextLost(
    "前綴 ![替代](images/a.png =600x200) 後綴",
    { "前綴", "後綴" },
    "帶尺寸的圖片"
)

local headings = MDParser.safeParse("# 主標題\n## 副標題")
check(headings.ok, "標題 parser 不應失敗")
checkEqual(
    norm(headings.richText),
    "<H1> <RGB:1,1,1> <INDENT:0> 主標題 <LINE> <H2> <RGB:0.8,0.8,0.8> <INDENT:0> 副標題",
    "#、## 標題映射錯誤"
)
check(contains(headings.richText, "主標題"), "CJK 內容必須原樣保留")
-- 樣式跨行洩漏回歸：標題後的正文必須自帶重置，否則 ISRichTextPanel 會讓正文繼承大字置中
local styled = MDParser.safeParse("# 標題\n正文")
checkEqual(
    norm(styled.richText),
    "<H1> <RGB:1,1,1> <INDENT:0> 標題 <LINE> <TEXT> <INDENT:0> 正文",
    "標題後的正文行必須自帶 <TEXT> 與 <INDENT:0> 重置"
)

-- 含圖片的 `#` 標題改靠左：<H1> 寫死置中（ISRichTextPanel.lua:30），而 render 的置中分支
-- 算行寬時只累加文字（:644-648），圖片是在另一個迴圈用未位移的 imageX 畫的（:595 對 :665）
-- -> 圖文分屬兩套座標系。字型與顏色必須與 <H1> 完全一致（:35-36 對 <SIZE:large> :131；
-- :32-34 對 <RGB:1,1,1> :81-87），只有 orient 改變。落點本身驗在 test_nbpanel.lua。
checkEqual(
    norm(MDParser.safeParse("# ![替代](images/x.png) 標題").richText),
    "<LEFT> <SIZE:large> <RGB:1,1,1> <INDENT:0> <NBIMG:1> 標題",
    "含圖片的 H1 必須改用靠左前綴（字型／顏色不變）"
)
checkEqual(
    norm(MDParser.safeParse("# 標題 ![替代](images/x.png)").richText),
    "<LEFT> <SIZE:large> <RGB:1,1,1> <INDENT:0> 標題 <NBIMG:1>",
    "圖片寫在標題文字之後同樣要靠左"
)
-- 回歸：沒有圖片的 H1 一個位元組都不能變（仍是置中的 <H1>）
checkEqual(
    norm(MDParser.safeParse("# 標題").richText),
    "<H1> <RGB:1,1,1> <INDENT:0> 標題",
    "不含圖片的 H1 產出必須完全不變"
)
-- 回歸：H2-H6 本來就靠左，一律不得改動
checkEqual(
    norm(MDParser.safeParse("## ![替代](images/x.png) 副標題").richText),
    "<H2> <RGB:0.8,0.8,0.8> <INDENT:0> <NBIMG:1> 副標題",
    "含圖片的 H2 產出必須完全不變"
)
checkEqual(
    norm(MDParser.safeParse("### ![替代](images/x.png) 小節").richText),
    "<TEXT> <SIZE:medium> <RGB:0.55,0.85,0.85> <INDENT:0> <NBIMG:1> 小節",
    "含圖片的 H3 產出必須完全不變"
)
checkEqual(
    norm(MDParser.safeParse("###### ![替代](images/x.png) 六級").richText),
    "<TEXT> <RGB:0.78,0.75,0.68> <INDENT:0> <NBIMG:1> 六級",
    "含圖片的 H6 產出必須完全不變"
)
-- 反例：判定必須走 findImage，不能是「字串裡有 ![ 就算」。
-- 逸出的 \![ 在區塊解析前就被換成 sentinel（encodeBackslashEscapes），比不中；
-- 沒有跟著 `](...)` 的字面 ![ 也不成立。兩者都得留在置中的 <H1>。
checkEqual(
    norm(MDParser.safeParse("# \\![替代](images/x.png)").richText),
    "<H1> <RGB:1,1,1> <INDENT:0> ! <LINE> <PUSHRGB:0.35,0.65,1> 替代 <POPRGB>",
    "逸出的 \\![ 不是圖片，H1 必須維持置中"
)
checkEqual(
    norm(MDParser.safeParse("# 有 ![ 但不是圖片").richText),
    "<H1> <RGB:1,1,1> <INDENT:0> 有 ![ 但不是圖片",
    "字面上的 ![ 不是圖片，H1 必須維持置中"
)
-- 服主手寫的原生 <IMAGE:> 是白名單放行的一等語法，走引擎同一個 IMAGE 分支
-- （ISRichTextPanel.lua:146-177），錯位與 markdown 的 ![]() 一模一樣，必須一起改靠左。
checkEqual(
    norm(MDParser.safeParse("# <IMAGE:images/x.png> 標題").richText),
    "<LEFT> <SIZE:large> <RGB:1,1,1> <INDENT:0> <IMAGE:images/x.png> 標題",
    "含手寫 <IMAGE:> 的 H1 必須改用靠左前綴"
)
checkEqual(
    norm(MDParser.safeParse("# 標題 <IMAGE:images/x.png>").richText),
    "<LEFT> <SIZE:large> <RGB:1,1,1> <INDENT:0> 標題 <IMAGE:images/x.png>",
    "手寫 <IMAGE:> 寫在標題文字之後同樣要靠左"
)
-- <IMAGECENTRE:> 刻意不列入：它強制水平置中（:205-206），與 orient 無關，
-- 改成靠左只會讓文字往左而圖片留在正中。維持置中的 <H1>。
checkEqual(
    norm(MDParser.safeParse("# <IMAGECENTRE:images/x.png> 標題").richText),
    "<H1> <RGB:1,1,1> <INDENT:0> <IMAGECENTRE:images/x.png> 標題",
    "含手寫 <IMAGECENTRE:> 的 H1 必須維持置中（引擎強制水平置中，與 orient 無關）"
)
-- 反例：逸出的 \< 在區塊解析前就被換成 sentinel，字面比對必須落空
checkEqual(
    norm(MDParser.safeParse("# \\<IMAGE:images/x.png> 標題").richText),
    "<H1> <RGB:1,1,1> <INDENT:0> &lt;IMAGE:images/x.png&gt; 標題",
    "逸出的 \\<IMAGE: 不是圖片，H1 必須維持置中"
)
-- 回歸：H2 含手寫 <IMAGE:> 一樣不得改動（判定有 headingLevel == 1 短路）
checkEqual(
    norm(MDParser.safeParse("## <IMAGE:images/x.png> 副標題").richText),
    "<H2> <RGB:0.8,0.8,0.8> <INDENT:0> <IMAGE:images/x.png> 副標題",
    "含手寫 <IMAGE:> 的 H2 產出必須完全不變"
)

local bold = MDParser.safeParse("一般 **重點** 結尾")
checkEqual(
    norm(bold.richText),
    "<TEXT> <INDENT:0> 一般 <PUSHRGB:1,0.85,0.4> 重點 <POPRGB> 結尾",
    "粗體映射錯誤"
)

local list = MDParser.safeParse("    - 巢狀項目")
-- 項目符號必須是純 ASCII（Kahlua 會把 .lua 內的非 ASCII 字面值截成單位元組）
-- 層級用「開啟中的清單堆疊」判定，沒有父項時 4 個空白不算巢狀（與 CommonMark 一致）
checkEqual(norm(list.richText), "<TEXT> <INDENT:20> - 巢狀項目", "無父項的縮排不得算成巢狀層級")

local rule = MDParser.safeParse("---")
checkEqual(
    norm(rule.richText),
    "<TEXT> <INDENT:0> <RGB:0.4,0.4,0.4> " .. string.rep("-", 48) .. " <RGB:1,1,1>",
    "分隔線映射錯誤"
)
check(contains(rule.richText, string.rep("-", 48)), "分隔線必須使用 ASCII hyphen")

local paragraph = MDParser.safeParse("第一段\n\n第二段")
checkEqual(
    norm(paragraph.richText),
    "<TEXT> <INDENT:0> 第一段 <LINE> <LINE> <TEXT> <INDENT:0> 第二段",
    "空行必須映射為額外 <LINE>"
)

local escapedTags = MDParser.safeParse("2 < 3 > 1 <RGB:1,0,0>紅色")
checkEqual(
    norm(escapedTags.richText),
    "<TEXT> <INDENT:0> 2 &lt; 3 &gt; 1 <RGB:1,0,0> 紅色",
    "大寫原生 tag 應放行，其餘 angle bracket 應轉義"
)
local lowercaseTag = MDParser.safeParse("<small>文字</small>")
checkEqual(
    norm(lowercaseTag.richText),
    "<TEXT> <INDENT:0> &lt;small&gt;文字&lt;/small&gt;",
    "非大寫原生 tag 不得注入 RichText"
)

local link = MDParser.safeParse("前文 [網站](https://example.com/path) 後文")
check(link.ok, "連結 parser 不應失敗")
checkEqual(#link.links, 1, "連結表筆數錯誤")
checkEqual(link.links[1].text, "網站", "連結顯示文字錯誤")
checkEqual(link.links[1].url, "https://example.com/path", "連結 URL 錯誤")
checkEqual(link.links[1].line, 2, "獨行化後 link 行號錯誤")
checkEqual(
    norm(link.richText),
    "<TEXT> <INDENT:0> 前文 <LINE> <PUSHRGB:0.35,0.65,1> 網站 <POPRGB> <LINE> 後文",
    "連結必須與前後文字分成獨立 RichText 行"
)

local twoLinks = MDParser.safeParse("[甲](https://a.example) 和 [乙](https://b.example)")
checkEqual(#twoLinks.links, 2, "同一來源行的多個 link 都必須收集")
checkEqual(twoLinks.links[1].line, 1, "第一個 link 行號錯誤")
checkEqual(twoLinks.links[2].line, 3, "第二個 link 應在獨立行")
checkEqual(
    norm(twoLinks.richText),
    "<TEXT> <INDENT:0> <PUSHRGB:0.35,0.65,1> 甲 <POPRGB> <LINE> 和 <LINE>"
        .. " <PUSHRGB:0.35,0.65,1> 乙 <POPRGB>",
    "多 link 獨行化錯誤"
)

local image = MDParser.safeParse("前綴 ![公告圖](media/textures/notice.png) 後綴")
check(image.ok, "圖片 parser 不應失敗")
-- richText 內放的是**唯一佔位 token**，不是最終的 <IMAGE:路徑>：服主可能手寫一個
-- 完全相同的 <IMAGE:路徑>，靠 tag 文字找 occurrence 會把尺寸套到錯的那張身上。
checkEqual(
    norm(image.richText),
    "<TEXT> <INDENT:0> 前綴 <NBIMG:1> 後綴",
    "圖片佔位 token 映射錯誤"
)
checkEqual(#image.images, 1, "image 表筆數錯誤")
checkEqual(image.images[1].alt, "公告圖", "image alt 錯誤")
checkEqual(image.images[1].path, "media/textures/notice.png", "image path 錯誤")
checkEqual(image.images[1].tag, "<NBIMG:1>", "image tag metadata 錯誤")
-- 佔位 token 不得命中 ISRichTextPanel:processCommand 的任何比對分支（:17-352）：
-- 萬一預檢沒接到，最壞情況只是不畫東西，不會拋錯也不會被當成圖片路徑。
check(not contains(image.richText, "<IMAGE:"), "MDParser 不得直接產生 <IMAGE:> 標記")
check(not contains(image.richText, "<IMAGECENTRE:"), "不得產生會強制置中的 <IMAGECENTRE:> 標記")
checkEqual(image.images[1].line, 1, "image 行號錯誤")
-- 回歸：沒有 `=WxH` 尾段時完全維持既有行為（NBPanel 據此走原本的自動縮放）
checkEqual(image.images[1].width, nil, "未指定尺寸時 width 必須是 nil")
checkEqual(image.images[1].height, nil, "未指定尺寸時 height 必須是 nil")

-- 尺寸擴充語法：![alt](path =600x200) / =600x / =x200（業界通用，不在 CommonMark 核心）
local sizedImage = MDParser.safeParse("![公告圖](images/a.png =600x200)")
checkEqual(#sizedImage.images, 1, "帶尺寸的圖片必須解析成 image")
checkEqual(sizedImage.images[1].path, "images/a.png", "帶尺寸時 path 不得含尺寸片段")
checkEqual(sizedImage.images[1].alt, "公告圖", "帶尺寸時 alt 錯誤")
checkEqual(sizedImage.images[1].width, 600, "圖片寬度解析錯誤")
checkEqual(sizedImage.images[1].height, 200, "圖片高度解析錯誤")
-- tag 是佔位 token：尺寸由 NBPanel 夾限後才寫進 <IMAGE:...,寬,高>
checkEqual(sizedImage.images[1].tag, "<NBIMG:1>", "帶尺寸時 tag metadata 錯誤")
checkEqual(
    norm(sizedImage.richText),
    "<TEXT> <INDENT:0> <NBIMG:1>",
    "帶尺寸的圖片 richText 錯誤"
)

local widthOnlyImage = MDParser.safeParse("![圖](images/a.png =600x)")
checkEqual(widthOnlyImage.images[1].path, "images/a.png", "只給寬時 path 錯誤")
checkEqual(widthOnlyImage.images[1].width, 600, "只給寬時寬度錯誤")
checkEqual(widthOnlyImage.images[1].height, nil, "只給寬時高度必須是 nil（由 NBPanel 等比推算）")

local heightOnlyImage = MDParser.safeParse("![圖](images/a.png =x200)")
checkEqual(heightOnlyImage.images[1].path, "images/a.png", "只給高時 path 錯誤")
checkEqual(heightOnlyImage.images[1].width, nil, "只給高時寬度必須是 nil（由 NBPanel 等比推算）")
checkEqual(heightOnlyImage.images[1].height, 200, "只給高時高度錯誤")

-- 路徑與尺寸之間漏了空白：這是最常見的錯字，靜默當成路徑會變成「貼圖找不到」的
-- [替代文字] 占位，與「還沒同步完」「圖檔不存在」的畫面完全一樣，而那兩種都有 log。
-- 走與其他寫錯形式同一條政策：退回顯示原始 markdown，服主看得見。
local gluedSize = MDParser.safeParse("![圖](images/a.png=600x200)")
checkEqual(#gluedSize.images, 0, "漏空白的尺寸語法不得產生 IMAGE tag")
checkEqual(
    norm(gluedSize.richText),
    "<TEXT> <INDENT:0> ![圖](images/a.png=600x200)",
    "漏空白的尺寸語法必須退回顯示原始 markdown"
)
checkEqual(#MDParser.safeParse("![圖](images/a.png=600x)").images, 0,
    "漏空白的 =600x 同樣必須退回")
checkEqual(#MDParser.safeParse("![圖](images/a.png=x200)").images, 0,
    "漏空白的 =x200 同樣必須退回")
-- 誤判防線：真的含 '=' 的合法檔名不得被當成寫壞的尺寸語法。
-- 只看**最後一個** '=' 之後的尾段，且尾段必須整段就是 =W x H。
local equalsInName = MDParser.safeParse("![圖](images/a=1x2.png)")
checkEqual(equalsInName.images[1].path, "images/a=1x2.png",
    "含 '=' 但尾段不是尺寸形狀的檔名必須原樣當成路徑")
checkEqual(MDParser.safeParse("![圖](images/v1=2.png)").images[1].path, "images/v1=2.png",
    "含 '=' 的一般檔名不得誤判")
checkEqual(MDParser.safeParse("![圖](images/a=600x200.png)").images[1].path,
    "images/a=600x200.png", "尺寸形狀後面還有副檔名時不得誤判")
-- 兩邊都沒有數字不是尺寸形狀（與空白版的規則一致），仍然當成路徑
checkEqual(MDParser.safeParse("![圖](images/a.png=x)").images[1].path, "images/a.png=x",
    "=x 兩邊都沒有數字，不算尺寸形狀")

-- 兩邊都沒有數字不是合法尺寸；路徑因此含空白 -> 退回顯示原始 markdown
local emptySize = MDParser.safeParse("![圖](images/a.png =x)")
checkEqual(#emptySize.images, 0, "=x 不是合法尺寸，不得產生 IMAGE tag")
checkEqual(
    norm(emptySize.richText),
    "<TEXT> <INDENT:0> ![圖](images/a.png =x)",
    "非法尺寸必須退回顯示原始 markdown"
)
local zeroSize = MDParser.safeParse("![圖](images/a.png =0x200)")
checkEqual(#zeroSize.images, 0, "寬度 0 不是合法尺寸，不得產生 IMAGE tag")

-- 同一路徑出現兩次時，佔位 token 必須不同——NBPanel 才不必靠「出現順序 vs 字串內容」
-- 這種脆弱的對應，服主手寫的同路徑裸 tag 也搶不走尺寸（見下方 R3 情境）。
local duplicateImages = MDParser.safeParse(
    "![first](media/textures/logo.png)\n\n![second](media/textures/logo.png =120x60)"
)
checkEqual(#duplicateImages.images, 2, "同路徑的兩張圖必須各自成為一筆 image")
checkEqual(duplicateImages.images[1].path, duplicateImages.images[2].path, "兩張圖的路徑本來就相同")
check(duplicateImages.images[1].tag ~= duplicateImages.images[2].tag,
    "同路徑的兩張圖必須拿到不同的佔位 token")
checkEqual(duplicateImages.images[1].tag, "<NBIMG:1>", "第一張的 token 錯誤")
checkEqual(duplicateImages.images[2].tag, "<NBIMG:2>", "第二張的 token 錯誤")
checkEqual(duplicateImages.images[1].width, nil, "第一張沒寫尺寸，width 必須是 nil")
checkEqual(duplicateImages.images[2].width, 120, "第二張的寬度錯誤")
checkEqual(duplicateImages.images[2].height, 60, "第二張的高度錯誤")

-- NBCore.replaceNextLiteral：NBPanel:preflightImages 依序消耗佔位 token 的游標。
local cursorText = "A <NBIMG:1> B <NBIMG:2> C"
local cursorOut, cursorAt = NBCore.replaceNextLiteral(cursorText, 1, "<NBIMG:1>", "<Y>")
checkEqual(cursorOut, "A <Y> B <NBIMG:2> C", "第一個 token 取代錯誤")
checkEqual(cursorAt, 6, "取代後游標必須落在替換內容之後")
cursorOut, cursorAt = NBCore.replaceNextLiteral(cursorOut, cursorAt, "<NBIMG:2>", "<Z>")
checkEqual(cursorOut, "A <Y> B <Z> C", "第二個 token 取代錯誤")
checkEqual(cursorAt, 12, "第二次取代後的游標錯誤")
-- 找不到時字串與游標都不動（image 表與 richText 不同步時不得無限迴圈或亂改）
local missingOut, missingAt = NBCore.replaceNextLiteral("A B", 2, "<NBIMG:1>", "<Z>")
checkEqual(missingOut, "A B", "找不到 needle 時不得改動字串")
checkEqual(missingAt, 2, "找不到 needle 時游標不得移動")
-- 替換內容本身含 needle 也不得被重新掃到（游標落在替換後方）
local nestedOut, nestedAt = NBCore.replaceNextLiteral(
    "<NBIMG:1>", 1, "<NBIMG:1>", "<IMAGE:x.png,120,60>")
checkEqual(nestedOut, "<IMAGE:x.png,120,60>", "替換結果錯誤")
checkEqual(nestedAt, 21, "游標必須跳過剛放進去的內容")

-- R3 情境：服主手寫的裸 <IMAGE:a> 與兩張同路徑的 markdown 圖片同在一行。
-- 舊實作靠 tag 文字（<IMAGE:a>）找 occurrence，第一次就命中手寫的那個，
-- 兩張圖的尺寸整組錯位。唯一 token 讓它們互不相干。
local mixedImages = MDParser.safeParse("<IMAGE:a> ![x](a =100x50) ![y](a =300x150)")
checkEqual(#mixedImages.images, 2, "手寫裸 tag 不進 images 表，只有兩張 markdown 圖片")
checkEqual(
    norm(mixedImages.richText),
    "<TEXT> <INDENT:0> <IMAGE:a> <NBIMG:1> <NBIMG:2>",
    "手寫裸 tag 必須原樣保留，markdown 圖片各自拿到唯一 token"
)
local mixedRendered = mixedImages.richText
local mixedAt = 1
local mixedIndex
for mixedIndex = 1, #mixedImages.images do
    local entry = mixedImages.images[mixedIndex]
    mixedRendered, mixedAt = NBCore.replaceNextLiteral(mixedRendered, mixedAt, entry.tag,
        NBCore.imageTag("<IMAGE:", entry.path, entry.width, entry.height))
end
checkEqual(
    norm(mixedRendered),
    "<TEXT> <INDENT:0> <IMAGE:a> <IMAGE:a,100,50> <IMAGE:a,300,150>",
    "尺寸必須落在正確那張圖上（手寫的裸 tag 不得被改寫）"
)

-- ---------------------------------------------------------------------------
-- 原生圖片 tag 的參數（NBPanel 預檢第二圈的信任邊界）。
-- 引擎在 command 內看到逗號就 vs = string.split(command, ",")、
-- h = tonumber(string.trim(vs[3]))（ISRichTextPanel.lua:149-154）。
-- string.trim 是 Java 端 StringLib（原版 lua 全樹沒有定義），對 nil 直接拋錯，
-- 由 paginate 的 pcall 接住 -> 整份公告變成錯誤占位。
-- 期望值一律寫字面值，不引用被測模組自己的常數。
-- ---------------------------------------------------------------------------
local tagPath, tagWidth, tagHeight, tagOk = NBCore.parseImageTagArguments("media/x.png")
checkEqual(tagOk, true, "沒有逗號是合法形狀")
checkEqual(tagPath, "media/x.png", "沒有逗號時整段就是路徑")
checkEqual(tagWidth, nil, "沒有逗號時不得解析出寬度")
checkEqual(tagHeight, nil, "沒有逗號時不得解析出高度")

tagPath, tagWidth, tagHeight, tagOk = NBCore.parseImageTagArguments("media/x.png,600,200")
checkEqual(tagOk, true, "兩個逗號參數是合法形狀")
checkEqual(tagPath, "media/x.png", "帶尺寸時路徑錯誤")
checkEqual(tagWidth, 600, "帶尺寸時寬度錯誤")
checkEqual(tagHeight, 200, "帶尺寸時高度錯誤")

local badTags = {
    "media/x.png,600",        -- 只有一個逗號參數：vs[3] 是 nil -> string.trim(nil) 拋錯
    "media/x.png,",           -- 同上，且寬度也是空的
    "media/x.png,600,200,50", -- 多餘參數
    "media/x.png,abc,200",    -- 寬度不是數字 -> tonumber 回 nil
    "media/x.png,600,abc",    -- 高度不是數字
    "media/x.png,0,200",      -- 0 不是正數
    "media/x.png,-5,200",     -- 負數
    "media/x.png,600,0",
}
local badTagIndex
for badTagIndex = 1, #badTags do
    local _, _, _, okFlag = NBCore.parseImageTagArguments(badTags[badTagIndex])
    checkEqual(okFlag, false,
        "不合法的圖片 tag 參數必須被擋下：" .. badTags[badTagIndex])
end
checkEqual(select(4, NBCore.parseImageTagArguments(nil)), false, "非字串參數必須擋下")

-- ---------------------------------------------------------------------------
-- 尺寸夾限：markdown 圖片與服主手寫的原生 tag 共用同一份。
-- ---------------------------------------------------------------------------
-- 回歸：沒指定尺寸且原圖塞得下 -> 不需要尺寸參數（產出不帶逗號的 <IMAGE:路徑>）
checkEqual(NBCore.fitImageSize(400, 300, nil, nil, 930, 1500), nil,
    "塞得下的圖不得產生尺寸參數（既有公告行為必須完全不變）")
-- 過寬：等比縮到可用寬度
local fitWidth, fitHeight = NBCore.fitImageSize(4000, 100, nil, nil, 930, 1500)
checkEqual(fitWidth, 930, "過寬的圖必須縮到可用寬度")
checkEqual(fitHeight, 23, "過寬的圖必須等比縮高")
-- 窄而極高：高度上限也要看，否則 100x5000 會按原始高度吃掉整個捲動區
fitWidth, fitHeight = NBCore.fitImageSize(100, 5000, nil, nil, 930, 1500)
checkEqual(fitHeight, 1500, "未指定尺寸的圖也必須受高度上限夾限")
checkEqual(fitWidth, 30, "受高度夾限時寬度必須等比縮小")
-- 服主指定的尺寸一樣要夾（手寫 <IMAGE:path,100000,100000> 不可以撐爆版面）
fitWidth, fitHeight = NBCore.fitImageSize(400, 300, 100000, 100000, 930, 1500)
checkEqual(fitWidth, 930, "指定寬度必須夾在可用寬度內")
checkEqual(fitHeight, 930, "指定尺寸夾限後高度必須等比縮小")
fitWidth, fitHeight = NBCore.fitImageSize(400, 300, 100, 9000, 930, 1500)
checkEqual(fitHeight, 1500, "指定高度必須夾在高度上限內")
checkEqual(fitWidth, 16, "受高度夾限時指定寬度也要等比縮小")
-- 只給一邊時用原圖比例補另一邊
fitWidth, fitHeight = NBCore.fitImageSize(400, 200, 600, nil, 930, 1500)
checkEqual(fitWidth, 600, "只給寬時寬度錯誤")
checkEqual(fitHeight, 300, "只給寬時高度必須依原圖比例推算")
fitWidth, fitHeight = NBCore.fitImageSize(400, 200, nil, 300, 930, 1500)
checkEqual(fitWidth, 600, "只給高時寬度必須依原圖比例推算")
checkEqual(fitHeight, 300, "只給高時高度錯誤")
-- 冪等：預檢第二圈會對第一圈剛寫好的 tag 再夾一次，結果不得再變
local idempotentWidth, idempotentHeight = NBCore.fitImageSize(4000, 100, nil, nil, 930, 1500)
checkEqual(
    NBCore.fitImageSize(4000, 100, idempotentWidth, idempotentHeight, 930, 1500),
    idempotentWidth,
    "夾限必須是冪等的（第二圈會重跑一次）"
)
-- 壞輸入不得讓預檢崩掉
checkEqual(NBCore.fitImageSize(0, 100, nil, nil, 930, 1500), nil, "寬度 0 的貼圖必須放棄縮放")
checkEqual(NBCore.fitImageSize(nil, 100, nil, nil, 930, 1500), nil, "非數字的貼圖尺寸必須放棄縮放")
checkEqual(NBCore.fitImageSize(400, 300, nil, nil, 20, 1500), nil, "面板太窄時必須放棄縮放")

-- tag 組回去：沒有尺寸就不能寫逗號（引擎看到逗號就走 string.split 那條路）
checkEqual(NBCore.imageTag("<IMAGE:", "media/x.png", nil, nil), "<IMAGE:media/x.png>",
    "沒有尺寸時不得產生逗號參數")
checkEqual(NBCore.imageTag("<IMAGE:", "media/x.png", 600, nil), "<IMAGE:media/x.png>",
    "只有一邊有值時不得產生半套參數")
checkEqual(NBCore.imageTag("<IMAGE:", "media/x.png", 600, 200), "<IMAGE:media/x.png,600,200>",
    "帶尺寸的 tag 組裝錯誤")
checkEqual(NBCore.imageTag("<IMAGECENTRE:", "media/x.png", 600, 200),
    "<IMAGECENTRE:media/x.png,600,200>", "IMAGECENTRE 的 tag 組裝錯誤")

-- 預檢第一圈的完整組合（NBPanel 需要引擎才跑得動，這裡驗它用到的三個純函式接起來的結果）
local noSizeImage = MDParser.safeParse("![圖](media/textures/logo.png)")
checkEqual(
    NBCore.imageTag("<IMAGE:", noSizeImage.images[1].path,
        NBCore.fitImageSize(400, 300, noSizeImage.images[1].width,
            noSizeImage.images[1].height, 930, 1500)),
    "<IMAGE:media/textures/logo.png>",
    "沒寫尺寸的既有公告必須產出不帶逗號的 <IMAGE:路徑>"
)
local withSizeImage = MDParser.safeParse("![圖](media/textures/logo.png =600x200)")
checkEqual(
    NBCore.imageTag("<IMAGE:", withSizeImage.images[1].path,
        NBCore.fitImageSize(400, 300, withSizeImage.images[1].width,
            withSizeImage.images[1].height, 930, 1500)),
    "<IMAGE:media/textures/logo.png,600,200>",
    "寫了尺寸的公告必須產出正確的寬高"
)

-- 本節整段包在 do ... end 內：主 chunk 的同時存活區域變數上限是 200（Lua 編譯期硬限制），
-- 這裡的區域變數不外流，才不會擠掉後面的測試。
do

-- ---------------------------------------------------------------------------
-- D1：圖包 MOD 的貼圖（media/... 路徑）也要走尺寸夾限。
-- 以前只有伺服器同步圖有夾限，MOD 貼圖是原樣交給引擎按原始像素畫的
-- （4000x3000 會橫向被裁掉、縱向把捲動區撐到 3000+）。
-- 回歸鐵則：塞得下的圖產出必須「完全不變」＝不帶逗號的 <IMAGE:路徑>。
-- ---------------------------------------------------------------------------
local modTextureFits = MDParser.safeParse("![圖](media/textures/pack/logo.png)")
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", modTextureFits.images[1].path,
        NBCore.fitImageSize(400, 300, modTextureFits.images[1].width,
            modTextureFits.images[1].height, 930, 1500)),
    "<IMAGE:media/textures/pack/logo.png>",
    "沒寫尺寸且塞得下的 MOD 貼圖產出必須完全不變（不帶逗號）"
)
-- 塞不下的 MOD 貼圖：這是 D1 唯一會改變的情形
local modTextureHuge = MDParser.safeParse("![圖](media/textures/pack/huge.png)")
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", modTextureHuge.images[1].path,
        NBCore.fitImageSize(4000, 3000, modTextureHuge.images[1].width,
            modTextureHuge.images[1].height, 930, 1500)),
    "<IMAGE:media/textures/pack/huge.png,930,697>",
    "畫爆版面的 MOD 貼圖必須被夾限"
)
-- 第二圈會對第一圈的產出再跑一次：夾限與護欄都必須冪等，否則每重畫一次就多包一層
local roundTripPath, roundTripWidth, roundTripHeight, roundTripOk =
    NBCore.parseImageTagArguments("media/textures/pack/huge.png,930,697")
checkEqual(roundTripOk, true, "第一圈產出的 tag 必須是合法形狀")
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", roundTripPath,
        NBCore.fitImageSize(4000, 3000, roundTripWidth, roundTripHeight, 930, 1500)),
    "<IMAGE:media/textures/pack/huge.png,930,697>",
    "第二圈重建必須是冪等的"
)
-- 服主手寫、不帶尺寸的原生 tag 也得夾（以前這條路徑完全繞過夾限）
local bareTagPath, bareTagWidth, bareTagHeight =
    NBCore.parseImageTagArguments("media/textures/pack/huge.png")
checkEqual(bareTagWidth, nil, "不帶逗號的手寫 tag 沒有尺寸參數")
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", bareTagPath,
        NBCore.fitImageSize(4000, 3000, bareTagWidth, bareTagHeight, 930, 1500)),
    "<IMAGE:media/textures/pack/huge.png,930,697>",
    "手寫且不帶尺寸的原生 tag 也必須被夾限"
)
-- 回歸：`![a](path =600x200)` 仍然正確（D1 不得動到明確指定尺寸的路徑）
local explicitSize = MDParser.safeParse("![圖](media/textures/pack/a.png =600x200)")
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", explicitSize.images[1].path,
        NBCore.fitImageSize(4000, 3000, explicitSize.images[1].width,
            explicitSize.images[1].height, 930, 1500)),
    "<IMAGE:media/textures/pack/a.png,600,200>",
    "明確指定的尺寸必須原樣採用（塞得下就不夾）"
)
-- 回歸：同一份公告出現兩次相同路徑時，尺寸仍落在正確那一張
local twoSamePath = MDParser.safeParse(
    "![a](media/textures/pack/logo.png)\n\n![b](media/textures/pack/logo.png =120x60)")
local twoSameRendered = twoSamePath.richText
local twoSameAt = 1
local twoSameIndex
for twoSameIndex = 1, #twoSamePath.images do
    local entry = twoSamePath.images[twoSameIndex]
    twoSameRendered, twoSameAt = NBCore.replaceNextLiteral(twoSameRendered, twoSameAt, entry.tag,
        NBCore.imageTagGuarded("<IMAGE:", entry.path,
            NBCore.fitImageSize(400, 300, entry.width, entry.height, 930, 1500)))
end
check(
    contains(twoSameRendered, "<IMAGE:media/textures/pack/logo.png>")
        and contains(twoSameRendered, "<IMAGE:media/textures/pack/logo.png,120,60>"),
    "同路徑兩張圖：沒寫尺寸的那張不得被加上尺寸，寫了的那張不得漏掉\n實際：" .. twoSameRendered
)

-- ---------------------------------------------------------------------------
-- D2：路徑含指令觸發字樣的貼圖 —— 圖照畫，但把染色抵銷掉。
-- 危險字樣清單逐字核對自 ISRichTextPanel.lua（42.20.2）processCommand 的每個
-- string.find(command, "..."):
--   :68 PUSHRGB:  :76 POPRGB  :81 RGB:  :88 GHC  :94 BHC  :101 RED  :108 ORANGE
--   :115 GREEN  :122 SIZE:  :146 IMAGE:  :180 IMAGECENTRE:  :222 VIDEOCENTRE:
--   :310 INDENT:  :314 JOYPAD:  :343 SETX:  :347 SPACE
-- 期望值一律寫字面值，不引用被測模組自己的清單。
-- ---------------------------------------------------------------------------
local engineSubstringLiterals = {
    "PUSHRGB:", "POPRGB", "RGB:", "GHC", "BHC", "RED", "ORANGE", "GREEN",
    "SIZE:", "IMAGE:", "IMAGECENTRE:", "VIDEOCENTRE:",
    "INDENT:", "JOYPAD:", "SETX:", "SPACE",
}
-- 兩份清單各司其職：COLOR_HAZARDS 是護欄抵銷得掉的（圖照畫），COMMAND_HAZARDS 是
-- 護欄救不了、只能整組退回占位的。每個引擎字面值都必須落在其中一份，少一個就是漏了分支。
local engineLiteralIndex
for engineLiteralIndex = 1, #engineSubstringLiterals do
    local literal = engineSubstringLiterals[engineLiteralIndex]
    local literalPath = "media/textures/pack/" .. literal .. "x.png"
    checkEqual(
        NBCore.findCommandHazard(literalPath)
            or NBCore.findCommandHazard(literalPath, NBCore.COLOR_HAZARDS),
        literal,
        "危險字樣清單漏了引擎的裸子字串比對字面值：" .. literal
    )
end
-- 顏色類**不得**留在 COMMAND_HAZARDS：NBImageCache 拿它當「整個圖片快取停用」的判準，
-- 把護欄處理得了的情形也擋掉，等於讓 Windows 帳號全大寫含 RED/GREEN 的玩家（FRED、
-- ALFRED、GREEN…）永遠只看得到 [替代文字]，而那正是護欄抵銷得掉的染色。
local colorLiteralIndex
for colorLiteralIndex = 1, #NBCore.COLOR_HAZARDS do
    local colorLiteral = NBCore.COLOR_HAZARDS[colorLiteralIndex]
    checkEqual(
        NBCore.findCommandHazard("C:/Users/" .. colorLiteral .. "/Zomboid/Lua/NoticeBoard/cache/"),
        nil,
        "顏色類字樣不得讓整個圖片快取停用（護欄抵銷得掉）：" .. colorLiteral
    )
end
-- PUSHRGB: / POPRGB **不是**顏色類：它們動的是 rgbStack 本身（ISRichTextPanel.lua:69
-- table.insert、:78 table.remove）。護欄自己就是一組 PUSH/POP，路徑裡的 POPRGB 會先把
-- 護欄推進去的那層 pop 掉，護欄的 POPRGB 再打在空堆疊上變 no-op -> 該區段照樣掉色。
-- 護欄抵銷不掉 -> 必須留在 COMMAND_HAZARDS 這一份。
checkEqual(NBCore.findCommandHazard("media/textures/pack/POPRGB_logo.png"), "POPRGB",
    "POPRGB 必須留在 COMMAND_HAZARDS（動的是堆疊，護欄抵銷不掉）")
checkEqual(NBCore.findCommandHazard("media/textures/pack/POPRGB_logo.png",
        NBCore.COLOR_HAZARDS), nil,
    "POPRGB 不得被當成護欄救得回來的顏色類")
-- PUSHRGB 帶冒號（引擎比對的是 "PUSHRGB:"），Windows 目錄不可能出現，列在這裡是為了
-- 讓兩份清單的分類本身有守門員。
checkEqual(NBCore.findCommandHazard("media/textures/pack/PUSHRGB:_logo.png"), "PUSHRGB:",
    "PUSHRGB: 必須留在 COMMAND_HAZARDS（動的是堆疊，護欄抵銷不掉）")
-- 註：含 "PUSHRGB:" 的路徑在 COLOR_HAZARDS 那份也會命中（它含子字串 "RGB:"），
-- 這是裸子字串比對無法避免的重疊，且無害：引擎的 if/elseif 鏈先進 PUSHRGB 分支
-- （:68），根本走不到 RGB:（:81），而 NBImageCache 那端已由 COMMAND_HAZARDS 擋下。

-- tokenizer 與 IMAGE 分支拆參數會用到的三個字元同樣不安全（且護欄救不了）
checkEqual(NBCore.findCommandHazard("a,b.png"), ",", "逗號必須視為不安全（IMAGE 分支拆寬高）")
checkEqual(NBCore.findCommandHazard("a<b.png"), "<", "< 必須視為不安全（tokenizer 邊界）")
checkEqual(NBCore.findCommandHazard("a>b.png"), ">", "> 必須視為不安全（tokenizer 邊界）")
checkEqual(NBCore.findCommandHazard("C:/Users/A,B/Zomboid/Lua/NoticeBoard/cache/"), ",",
    "含逗號的快取路徑仍然必須整組停用（護欄救不了拆寬高）")
-- LINE / BR / H1 / H2 / TEXT / CENTRE / LEFT / RIGHT 是 `command == "..."` 完整比對
-- （ISRichTextPanel.lua:17,23,29,38,47,57,61,65），帶路徑的 command 一定以 "IMAGE:" 開頭，
-- 不可能整串相等 -> 不是危險字樣。把它們加進清單只會讓乾淨路徑被無謂地包一層。
local equalityOnlyWords = { "LINE", "BR", "H1", "H2", "TEXT", "CENTRE", "LEFT", "RIGHT" }
local equalityIndex
for equalityIndex = 1, #equalityOnlyWords do
    local word = equalityOnlyWords[equalityIndex]
    local wordPath = "media/textures/pack/" .. word .. ".png"
    checkEqual(
        NBCore.findCommandHazard(wordPath)
            or NBCore.findCommandHazard(wordPath, NBCore.COLOR_HAZARDS),
        nil,
        "完整比對的指令字樣不得被當成危險字樣：" .. word
    )
end
checkEqual(NBCore.findCommandHazard("media/textures/pack/logo.png"), nil,
    "乾淨路徑不得被判為危險")
checkEqual(NBCore.findCommandHazard(nil), nil, "非字串輸入不得拋錯")
checkEqual(NBCore.findCommandHazard(nil, NBCore.COLOR_HAZARDS), nil,
    "指定清單時非字串輸入同樣不得拋錯")

-- 乾淨路徑：imageTagGuarded 必須與 imageTag 產出**完全相同**的字串（零行為改變）
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", "media/textures/pack/logo.png", nil, nil),
    "<IMAGE:media/textures/pack/logo.png>",
    "乾淨路徑不得被加上 PUSHRGB/POPRGB"
)
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", "media/textures/pack/logo.png", 600, 200),
    "<IMAGE:media/textures/pack/logo.png,600,200>",
    "乾淨路徑（帶尺寸）不得被加上 PUSHRGB/POPRGB"
)
-- 含危險字樣：包上護欄，tag 前後空白一個都不能少
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", "media/textures/RED_BANNER.png", nil, nil),
    " <PUSHRGB:0.7,0.7,0.7> <IMAGE:media/textures/RED_BANNER.png> <POPRGB> ",
    "含危險字樣的路徑必須被包上顏色護欄"
)
checkEqual(
    NBCore.imageTagGuarded("<IMAGECENTRE:", "media/textures/GREEN.png", 120, 60),
    " <PUSHRGB:0.7,0.7,0.7> <IMAGECENTRE:media/textures/GREEN.png,120,60> <POPRGB> ",
    "IMAGECENTRE 與帶尺寸的情形同樣要包護欄"
)
-- 伺服器同步圖：richText 裡的 path 是 NBCACHE_<hash> 替身（恆為乾淨十六進位），
-- 危險字樣在「換回去之後的絕對路徑」上。判定依據拿錯就等於整條同步圖路徑沒有護欄。
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", "NBCACHE_abcd1234", nil, nil,
        "C:/Users/FRED/Zomboid/Lua/NoticeBoard/cache/abcd1234.png"),
    " <PUSHRGB:0.7,0.7,0.7> <IMAGE:NBCACHE_abcd1234> <POPRGB> ",
    "同步圖的護欄必須依實際會交給引擎的絕對路徑判定"
)
checkEqual(
    NBCore.imageTagGuarded("<IMAGE:", "NBCACHE_abcd1234", nil, nil,
        "C:/Users/Ann/Zomboid/Lua/NoticeBoard/cache/abcd1234.png"),
    "<IMAGE:NBCACHE_abcd1234>",
    "乾淨的絕對路徑不得被包護欄"
)

--[[
  引擎顏色模型移植（ISRichTextPanel.lua）。這是 D2 唯一有意義的驗證方式：
  顏色不是掛在 token 上，而是掛在**每一邏輯行**上（self.rgb[self.currentLine]），
  render 時整行套用、未被覆寫的行沿用前一行的值（:613-617），所以光比對 richText
  字串看不出「圖片之後的文字整段變色」。
  移植的三段：
    paginate 的邏輯行記帳（:469-486）：遇到 command token 時，先把當前行落定，
      lines = lines + 1，再 self.currentLine = lines —— 所以 command 寫的是**下一行**的顏色。
    processCommand 的染色分支（:29-121）。
    render 的整行套色與顏色延續（:573-575、:613-617）。
  刻意不移植的：以像素寬度決定的自動換行（測試環境沒有字型量測）。換行只會多出幾個
  繼承同一顏色的行，不影響本節的斷言。
]]
local function parseRgbTriplet(text)
    local red, green, blue = string.match(text, "^([^,]*),([^,]*),([^,]*)$")
    if red == nil then
        return nil
    end
    return { r = tonumber(red), g = tonumber(green), b = tonumber(blue) }
end

local function rgbKey(color)
    return string.format("%.4f,%.4f,%.4f", color.r, color.g, color.b)
end

local function simulateLineColors(richText)
    local lineText = {}
    local lineRgb = {}
    local lineCount = 1
    local rgbCurrent = { r = 1, g = 1, b = 1 }
    local rgbStack = {}

    local function setLineColor(line, color)
        lineRgb[line] = color
        return color
    end

    local function applyCommand(command, line)
        -- 完整比對的分支（:29-56）
        if command == "H1" then
            setLineColor(line, { r = 1, g = 1, b = 1 })
        elseif command == "H2" then
            setLineColor(line, { r = 0.8, g = 0.8, b = 0.8 })
        elseif command == "TEXT" then
            rgbCurrent = setLineColor(line, { r = 0.7, g = 0.7, b = 0.7 })
        end
        -- 互斥的 if/elseif 鏈（:68-100）
        if string.find(command, "PUSHRGB:", 1, true) then
            rgbStack[#rgbStack + 1] = rgbCurrent
            local parsed = parseRgbTriplet(string.sub(command, 9))
            if parsed then
                rgbCurrent = setLineColor(line, parsed)
            end
        elseif string.find(command, "POPRGB", 1, true) then
            if #rgbStack > 0 then
                rgbCurrent = rgbStack[#rgbStack]
                rgbStack[#rgbStack] = nil
                setLineColor(line, rgbCurrent)
            end
        elseif string.find(command, "RGB:", 1, true) then
            local parsed = parseRgbTriplet(string.sub(command, 5))
            if parsed then
                rgbCurrent = setLineColor(line, parsed)
            end
        elseif string.find(command, "GHC", 1, true) then
            rgbCurrent = setLineColor(line, { r = 0.1, g = 0.9, b = 0.1 })
        elseif string.find(command, "BHC", 1, true) then
            rgbCurrent = setLineColor(line, { r = 0.9, g = 0.1, b = 0.1 })
        end
        -- 與上面那條鏈**互不排他**的獨立 if（:101-121）——D2 的成因就在這裡
        if string.find(command, "RED", 1, true) then
            rgbCurrent = setLineColor(line, { r = 1, g = 0, b = 0 })
        end
        if string.find(command, "ORANGE", 1, true) then
            rgbCurrent = setLineColor(line, { r = 0.9, g = 0.3, b = 0 })
        end
        if string.find(command, "GREEN", 1, true) then
            rgbCurrent = setLineColor(line, { r = 0, g = 1, b = 0 })
        end
    end

    local leftText = richText
    local cur = 0
    local done = false
    local guard = 0
    while not done do
        guard = guard + 1
        if guard > 200000 then
            error("color simulator guard tripped")
        end
        local token
        cur = string.find(leftText, " ", cur + 1)
        if cur ~= nil then
            token = string.sub(leftText, 0, cur)
            if string.find(token, "<", 1, true) and string.find(token, ">", 1, true) then
                cur = string.find(token, ">", 1, true) + 1
                token = string.sub(leftText, 0, cur - 1)
            end
            leftText = string.sub(leftText, cur)
            cur = 1
        else
            token = leftText
            done = true
        end

        local open = string.find(token, "<", 1, true)
        local close = string.find(token, ">", 1, true)
        if open and close and not done then
            if lineText[lineCount] == nil then
                lineText[lineCount] = ""
            end
            lineCount = lineCount + 1
            applyCommand(string.sub(token, open + 1, close - 1), lineCount)
        else
            local visible = norm(token)
            if visible ~= "" then
                if lineText[lineCount] == nil or lineText[lineCount] == "" then
                    lineText[lineCount] = visible
                else
                    lineText[lineCount] = lineText[lineCount] .. " " .. visible
                end
            end
        end
    end

    local result = {}
    local carried = { r = 1, g = 1, b = 1 }
    local line
    for line = 1, lineCount do
        if lineRgb[line] then
            carried = lineRgb[line]
        end
        result[#result + 1] = { text = lineText[line] or "", rgb = carried }
    end
    return result
end

-- 傳回「第一個含 fragment 的邏輯行」的顏色鍵；找不到就讓斷言看得到原因
local function colorOfText(richText, fragment)
    local simulated = simulateLineColors(richText)
    local index
    for index = 1, #simulated do
        if contains(simulated[index].text, fragment) then
            return rgbKey(simulated[index].rgb)
        end
    end
    return "MISSING:" .. fragment
end

-- 模擬器自我驗證：沒有護欄時必須重現「圖片之後的文字被染紅」，否則下面的斷言毫無意義
local hazardBare = " <TEXT> 前文 <IMAGE:media/textures/RED_BANNER.png> 後文 "
checkEqual(colorOfText(hazardBare, "後文"), string.format("%.4f,%.4f,%.4f", 1, 0, 0),
    "模擬器錯誤：沒有護欄時圖片之後的文字必須被染成紅色")
checkEqual(colorOfText(hazardBare, "前文"), string.format("%.4f,%.4f,%.4f", 0.7, 0.7, 0.7),
    "圖片**之前**的文字不受影響（顏色寫在 currentLine，而 currentLine 已經前進到下一行）")

-- 護欄生效：圖片之後的文字顏色必須與圖片之前完全相同
local hazardGuarded = " <TEXT> 前文 "
    .. NBCore.imageTagGuarded("<IMAGE:", "media/textures/RED_BANNER.png", nil, nil)
    .. " 後文 "
checkEqual(
    colorOfText(hazardGuarded, "後文"),
    colorOfText(hazardGuarded, "前文"),
    "護欄必須把圖片造成的染色抵銷掉"
)
checkEqual(colorOfText(hazardGuarded, "後文"), string.format("%.4f,%.4f,%.4f", 0.7, 0.7, 0.7),
    "抵銷後必須回到 <TEXT> 的本文色")

-- 圖片剛好被包在粗體區段裡：該區段的顏色也要保住（護欄存的是當下的 rgbCurrent）
local boldHazard = " <TEXT> a <PUSHRGB:1,0.85,0.4> 粗前 "
    .. NBCore.imageTagGuarded("<IMAGE:", "media/textures/GREEN_ICON.png", nil, nil)
    .. " 粗後 <POPRGB> 尾段 "
checkEqual(
    colorOfText(boldHazard, "粗後"),
    colorOfText(boldHazard, "粗前"),
    "圖片在粗體區段內時，該區段的顏色必須被保住"
)
checkEqual(colorOfText(boldHazard, "尾段"), string.format("%.4f,%.4f,%.4f", 0.7, 0.7, 0.7),
    "護欄不得破壞外層 PUSHRGB/POPRGB 的配對")
-- 對照組：同一份內容不加護欄時「粗後」會變綠，證明上面兩條不是恆真
local boldBare = " <TEXT> a <PUSHRGB:1,0.85,0.4> 粗前 "
    .. "<IMAGE:media/textures/GREEN_ICON.png>"
    .. " 粗後 <POPRGB> 尾段 "
checkEqual(colorOfText(boldBare, "粗後"), string.format("%.4f,%.4f,%.4f", 0, 1, 0),
    "對照組：沒有護欄時粗體區段內的文字會被圖片路徑染綠")

-- 標題行內的 PUSHRGB/POPRGB 配對必須還原成**標題色**，不是上一段本文色。
-- <H1>/<H2> 只寫 self.rgb[currentLine]、不更新 rgbCurrent（ISRichTextPanel.lua:29-46），
-- 而 POPRGB 寫回的是堆疊裡那份 rgbCurrent（:69、:76-80）；MDParser.H1_PREFIX/H2_PREFIX
-- 因此各補了一個同色 <RGB:>。把那個 <RGB:> 拿掉，下面四條會全部變成 0.7,0.7,0.7。
local headingImage = " <TEXT> 本文 " .. MDParser.H1_PREFIX .. "標前 "
    .. NBCore.imageTagGuarded("<IMAGE:", "media/textures/RED_BANNER.png", nil, nil)
    .. " 標後 "
checkEqual(colorOfText(headingImage, "標後"), rgbKey({ r = 1, g = 1, b = 1 }),
    "H1 標題行內的圖片護欄必須還原成標題色")
checkEqual(colorOfText(headingImage, "標後"), colorOfText(headingImage, "標前"),
    "H1 標題行內圖片的前後文字顏色必須一致")
-- 同一個成因也打到粗體／斜體／行內程式碼／連結（與圖片無關的既有路徑）
local headingBold = " <TEXT> 本文 " .. MDParser.H2_PREFIX .. "標前 "
    .. MDParser.BOLD_PREFIX .. "粗體 " .. MDParser.BOLD_SUFFIX .. " 標後 "
checkEqual(colorOfText(headingBold, "標後"), rgbKey({ r = 0.8, g = 0.8, b = 0.8 }),
    "H2 標題行內的粗體結束後必須回到標題色")
local headingLink = " <TEXT> 本文 " .. MDParser.H1_PREFIX .. "標前 "
    .. MDParser.LINK_PREFIX .. "連結 " .. MDParser.LINK_SUFFIX .. " 標後 "
checkEqual(colorOfText(headingLink, "標後"), rgbKey({ r = 1, g = 1, b = 1 }),
    "H1 標題行內的連結結束後必須回到標題色")

-- 乾淨路徑不得有任何顏色變化（零行為改變）
local cleanImage = " <TEXT> 前文 "
    .. NBCore.imageTagGuarded("<IMAGE:", "media/textures/pack/logo.png", nil, nil)
    .. " 後文 "
checkEqual(
    colorOfText(cleanImage, "後文"),
    colorOfText(cleanImage, "前文"),
    "乾淨路徑本來就不會染色"
)
check(not contains(cleanImage, "PUSHRGB"), "乾淨路徑的產出不得出現 PUSHRGB")

-- RichText tag 前後空白規則：光比對字串抓不到，必須用引擎 tokenizer 驗
local guardedCommands, guardedVisible = tokenizeLikeEngine(hazardGuarded)
checkEqual(#guardedCommands, 4, "護欄後的 command 數量錯誤（TEXT + PUSHRGB + IMAGE + POPRGB）")
checkEqual(guardedCommands[1], "TEXT", "第一個 command 錯誤")
checkEqual(guardedCommands[2], "PUSHRGB:0.7,0.7,0.7", "護欄的 PUSHRGB 必須自成一個 command")
checkEqual(guardedCommands[3], "IMAGE:media/textures/RED_BANNER.png",
    "圖片 tag 必須完整、不得被護欄吃掉")
checkEqual(guardedCommands[4], "POPRGB", "護欄的 POPRGB 必須自成一個 command")
check(contains(guardedVisible, "前文"), "護欄不得吃掉它前面的文字\n實際可見：" .. guardedVisible)
-- 護欄必須**自帶**前後空白（合約的一部分，呼叫端不補）：預檢是把它直接貼在
-- <NBIMG:n> / <IMAGE:...> 原本的位置上，緊貼前一段文字時若少了開頭空白，
-- tokenizer 會把「文字<PUSHRGB:...>」整段當成 command，前面的文字直接消失（:462-468）。
-- 收尾空白則不是必要的（引擎在 :462-465 會於 '>' 之後重新切開），但一併保留較不易誤用。
local tightGuarded = " <TEXT> 前文"
    .. NBCore.imageTagGuarded("<IMAGE:", "media/textures/RED_BANNER.png", nil, nil)
    .. "後文 "
local _, tightVisible = tokenizeLikeEngine(tightGuarded)
check(contains(tightVisible, "前文"),
    "護欄少了開頭空白就會吃掉緊貼在前面的文字\n實際可見：" .. tightVisible)
check(contains(tightVisible, "後文"),
    "護欄不得吃掉緊貼在後面的文字\n實際可見：" .. tightVisible)
checkEqual(
    colorOfText(tightGuarded, "後文"),
    colorOfText(tightGuarded, "前文"),
    "緊貼拼接時護欄同樣必須抵銷染色"
)
check(contains(guardedVisible, "後文"), "護欄不得吃掉它後面的文字\n實際可見：" .. guardedVisible)
check(not contains(guardedVisible, "<"), "護欄不得讓 tag 洩漏成字面文字\n實際可見：" .. guardedVisible)

-- 護欄接在 markdown 圖片的佔位 token 上（預檢第一圈 + 第二圈的完整組合）也不得吃字
local hazardDoc = MDParser.safeParse("前綴 ![替代](media/textures/RED_BANNER.png) 後綴")
local hazardRendered = select(1, NBCore.replaceNextLiteral(
    hazardDoc.richText, 1, hazardDoc.images[1].tag,
    NBCore.imageTagGuarded("<IMAGE:", hazardDoc.images[1].path,
        NBCore.fitImageSize(400, 300, nil, nil, 930, 1500))))
local _, hazardVisible = tokenizeLikeEngine(hazardRendered)
check(contains(hazardVisible, "前綴") and contains(hazardVisible, "後綴"),
    "護欄套進實際公告後不得丟字\n實際可見：" .. hazardVisible)
check(not contains(hazardVisible, "<"),
    "護欄套進實際公告後不得洩漏 tag\n實際可見：" .. hazardVisible)
checkEqual(
    colorOfText(hazardRendered, "後綴"),
    colorOfText(hazardRendered, "前綴"),
    "實際公告裡的危險路徑圖片同樣不得改變後續文字的顏色"
)

end

-- ---------------------------------------------------------------------------
-- 帶參數的原生 tag：參數形狀不合的一律不放行。
-- 引擎對 <RGB:1,0> 會把顏色分量設成 nil（:82-86）再送進 drawText（:665,672）；
-- <INDENT:abc> 會讓 self.indent 變成 nil（:311），render 端 `x = self.indent`（:515）
-- 之後的加法（:519）直接對 nil 運算。兩者都是「整份公告變成錯誤占位」。
-- ---------------------------------------------------------------------------
checkEqual(
    norm(MDParser.safeParse("<RGB:1,0> 文字").richText),
    "<TEXT> <INDENT:0> &lt;RGB:1,0&gt; 文字",
    "參數段數不足的 RGB 不得放行"
)
checkEqual(
    norm(MDParser.safeParse("<PUSHRGB:1,0,x> 文字").richText),
    "<TEXT> <INDENT:0> &lt;PUSHRGB:1,0,x&gt; 文字",
    "參數不是數字的 PUSHRGB 不得放行"
)
checkEqual(
    norm(MDParser.safeParse("<INDENT:abc> 文字").richText),
    "<TEXT> <INDENT:0> &lt;INDENT:abc&gt; 文字",
    "參數不是數字的 INDENT 不得放行"
)
checkEqual(
    norm(MDParser.safeParse("<INDENT:> 文字").richText),
    "<TEXT> <INDENT:0> &lt;INDENT:&gt; 文字",
    "參數空白的 INDENT 不得放行"
)
-- <SIZE:> 的參數段以前完全不驗，而引擎對每條指令做的是**子字串**比對（:68-347 全是
-- string.find）。於是把另一條指令的觸發字樣藏進 SIZE 的參數段就能同時命中兩個分支，
-- 繞過上面那三條檢查拿到一模一樣的崩潰——而且 NBPanel 的預檢找的是字面 "<IMAGE:"，接不到。
local sizeInjections = {
    "<SIZE:INDENT:zz>", "<SIZE:IMAGE:x>", "<SIZE:IMAGE:x,1>",
    "<SIZE:SETX:zz>", "<SIZE:JOYPAD:x>", "<SIZE:VIDEOCENTRE:x,1>", "<SIZE:RED>",
}
local sizeIndex
for sizeIndex = 1, #sizeInjections do
    local injection = sizeInjections[sizeIndex]
    check(
        contains(MDParser.safeParse(injection .. " 文字").richText, "&lt;SIZE:"),
        "參數段藏著其他指令觸發字樣的 SIZE 不得放行：" .. injection
    )
end
checkEqual(
    norm(MDParser.safeParse("<SIZE:zz> 文字").richText),
    "<TEXT> <INDENT:0> &lt;SIZE:zz&gt; 文字",
    "引擎不認得的字型名不得放行"
)
-- 合法的仍然要放行（不可以把整個白名單關掉）
checkEqual(
    norm(MDParser.safeParse("<SIZE:small> 小 <SIZE:large> 大").richText),
    "<TEXT> <INDENT:0> <SIZE:small> 小 <SIZE:large> 大",
    "引擎認得的字型名必須照常放行"
)
checkEqual(
    norm(MDParser.safeParse("<RGB:1,0.5,0> 紅 <PUSHRGB:0,0,1> 藍 <POPRGB> <INDENT:40> 縮").richText),
    "<TEXT> <INDENT:0> <RGB:1,0.5,0> 紅 <PUSHRGB:0,0,1> 藍 <POPRGB> <INDENT:40> 縮",
    "合法的帶參數 tag 必須照常放行"
)

local malformed = MDParser.safeParse("**未關閉 [不完整](")
check(malformed.ok, "不完整 Markdown 語法應退回純文字，不得拋錯")
check(contains(malformed.richText, "**未關閉"), "不完整 Markdown 不得遺失內容")

local badInput = MDParser.safeParse({ value = "not a string" })
check(badInput.ok == false, "非字串壞輸入必須由 safeParse 捕捉")
checkEqual(badInput.richText, MDParser.ERROR_PLACEHOLDER, "壞輸入占位文字錯誤")
checkEqual(#badInput.links, 0, "壞輸入不得留下 link")
checkEqual(#badInput.images, 0, "壞輸入不得留下 image")
check(type(badInput.error) == "string", "壞輸入應保留可記錄的錯誤字串")

-- ---------------------------------------------------------------------------
-- CommonMark 補齊：期望值一律字面字串，且每個語法都再用 tokenizeLikeEngine 驗
-- 「來源文字不會被引擎丟棄、且沒有 tag 洩漏成字面文字」。
-- ---------------------------------------------------------------------------

-- H3-H6：引擎只有三階字級（<SIZE:> 的 small 就是本文字型 UIFont.NewSmall），
-- 所以 H3 與 H2 同字級只換色，H4-H6 一律本文字級只換亮度。
local deepHeadings = MDParser.safeParse("### 三級\n#### 四級\n##### 五級\n###### 六級")
checkEqual(
    norm(deepHeadings.richText),
    "<TEXT> <SIZE:medium> <RGB:0.55,0.85,0.85> <INDENT:0> 三級 <LINE>"
        .. " <TEXT> <RGB:1,0.97,0.88> <INDENT:0> 四級 <LINE>"
        .. " <TEXT> <RGB:0.88,0.85,0.78> <INDENT:0> 五級 <LINE>"
        .. " <TEXT> <RGB:0.78,0.75,0.68> <INDENT:0> 六級",
    "H3-H6 必須各自有獨立層級樣式"
)
checkNoTextLost(
    "### 三級\n#### 四級\n##### 五級\n###### 六級",
    { "三級", "四級", "五級", "六級" },
    "H3-H6"
)
checkEqual(
    norm(MDParser.safeParse("####### 不是標題").richText),
    "<TEXT> <INDENT:0> ####### 不是標題",
    "7 個以上的 # 必須退回段落"
)
checkEqual(
    norm(MDParser.safeParse("## 收尾井號 ##").richText),
    "<H2> <RGB:0.8,0.8,0.8> <INDENT:0> 收尾井號",
    "ATX 收尾井號必須剝除"
)

-- 分隔線：***、___、- - - 都算；表格分隔列 |---|---| 不得誤中
local ruleText = "<TEXT> <INDENT:0> <RGB:0.4,0.4,0.4> " .. string.rep("-", 48) .. " <RGB:1,1,1>"
checkEqual(
    norm(MDParser.safeParse("***\n___\n- - -").richText),
    ruleText .. " <LINE> " .. ruleText .. " <LINE> " .. ruleText,
    "***、___、- - - 都必須是分隔線"
)
checkEqual(
    norm(MDParser.safeParse("|---|---|").richText),
    "<TEXT> <INDENT:0> |---|---|",
    "表格分隔列不得被當成分隔線"
)

-- 項目符號 -、*、+ 一律渲染成同一個 ASCII '-'：
-- HTML 的 <ul> 本來就不因 marker 字元改變 bullet，而且 NBPanel:matchLinkGroups
-- 只剝除 "- " 與 "n. "，引入其他 bullet 會讓清單項內的連結點不到。
checkEqual(
    norm(MDParser.safeParse("* 星號\n+ 加號\n- 減號").richText),
    "<TEXT> <INDENT:20> - 星號 <LINE> <TEXT> <INDENT:20> - 加號 <LINE> <TEXT> <INDENT:20> - 減號",
    "*、+、- 三種項目符號必須統一渲染"
)
checkNoTextLost("* 星號\n+ 加號\n- 減號", { "星號", "加號", "減號" }, "三種項目符號")

-- 有序清單必須自動編號（CommonMark 的 <ol> 只吃第一項的起始號）
checkEqual(
    norm(MDParser.safeParse("1. 甲\n1. 乙\n1. 丙").richText),
    "<TEXT> <INDENT:20> 1. 甲 <LINE> <TEXT> <INDENT:20> 2. 乙 <LINE> <TEXT> <INDENT:20> 3. 丙",
    "有序清單必須自動遞增編號"
)
checkEqual(
    norm(MDParser.safeParse("3) 甲\n9) 乙").richText),
    "<TEXT> <INDENT:20> 3. 甲 <LINE> <TEXT> <INDENT:20> 4. 乙",
    "有序清單必須沿用第一項的起始號並改用 '.' 收尾"
)
checkEqual(
    norm(MDParser.safeParse("1. 甲\n\n1. 乙").richText),
    "<TEXT> <INDENT:20> 1. 甲 <LINE> <LINE> <TEXT> <INDENT:20> 2. 乙",
    "鬆散清單（項目間空行）仍是同一份清單，編號要接著數"
)
checkNoTextLost("1. 甲\n2. 乙", { "甲", "乙" }, "有序清單")

-- 巢狀層級：20/40/60/80，第 5 層以上壓在第 4 層
checkEqual(
    norm(MDParser.safeParse("- 甲\n  - 乙\n    - 丙\n      - 丁\n        - 戊\n- 己").richText),
    "<TEXT> <INDENT:20> - 甲 <LINE> <TEXT> <INDENT:40> - 乙 <LINE> <TEXT> <INDENT:60> - 丙"
        .. " <LINE> <TEXT> <INDENT:80> - 丁 <LINE> <TEXT> <INDENT:80> - 戊"
        .. " <LINE> <TEXT> <INDENT:20> - 己",
    "巢狀清單層級與第 4 層上限錯誤"
)
checkNoTextLost(
    "- 甲\n  - 乙\n    - 丙\n      - 丁\n        - 戊",
    { "甲", "乙", "丙", "丁", "戊" },
    "巢狀清單"
)
-- 縮排續行併回上一個清單項（CommonMark 的 lazy continuation）
checkEqual(
    norm(MDParser.safeParse("- 甲\n  續行").richText),
    "<TEXT> <INDENT:20> - 甲 續行",
    "清單項的縮排續行必須併回同一項"
)

-- 引言：記號用 ASCII '|'，'>' 會被 escapeRichText 轉義多一層出錯面
checkEqual(
    norm(MDParser.safeParse("> 引言甲\n> 引言乙\n\n>> 巢狀引言").richText),
    "<TEXT> <INDENT:20> <RGB:0.6,0.6,0.6> | 引言甲 引言乙 <LINE> <LINE>"
        .. " <TEXT> <INDENT:40> <RGB:0.6,0.6,0.6> | 巢狀引言",
    "引言映射錯誤"
)
checkNoTextLost("> 引言甲\n> 引言乙\n\n>> 巢狀引言", { "引言甲", "引言乙", "巢狀引言" }, "引言")

-- 行內程式碼：無等寬字型也無底色框，只能換色；內容的 < > 必須轉義
checkEqual(
    norm(MDParser.safeParse("執行 `a<b>c` 完成").richText),
    "<TEXT> <INDENT:0> 執行 <PUSHRGB:1,0.7,0.85> a&lt;b&gt;c <POPRGB> 完成",
    "行內程式碼映射錯誤"
)
checkEqual(
    norm(MDParser.safeParse("`` a`b ``").richText),
    "<TEXT> <INDENT:0> <PUSHRGB:1,0.7,0.85> a`b <POPRGB>",
    "多重反引號 delimiter 必須支援"
)
checkNoTextLost("執行 `abc` 完成", { "執行", "abc", "完成" }, "行內程式碼")

-- 圍欄程式碼區塊：行內語法一律不解析、< > 轉義、行首縮排換算成 <INDENT:>
checkEqual(
    norm(MDParser.safeParse("```lua\nlocal x = 1\n  print('<hi>')\n```\n之後").richText),
    "<TEXT> <INDENT:20> <RGB:0.72,0.86,0.95> local x = 1 <LINE>"
        .. " <TEXT> <INDENT:36> <RGB:0.72,0.86,0.95> print('&lt;hi&gt;') <LINE>"
        .. " <TEXT> <INDENT:0> 之後",
    "圍欄程式碼區塊映射錯誤"
)
checkEqual(
    norm(MDParser.safeParse("~~~\n**不是粗體** <RGB:1,0,0>\n~~~").richText),
    "<TEXT> <INDENT:20> <RGB:0.72,0.86,0.95> **不是粗體** &lt;RGB:1,0,0&gt;",
    "程式碼區塊內不得解析行內語法，且原生 tag 必須被轉義"
)
checkNoTextLost("```\nplain code\n```", { "plain code" }, "圍欄程式碼區塊")

-- 斜體只能用顏色；'_' 必須有 intra-word 守衛，否則 snake_case_name 會被吃掉
checkEqual(
    norm(MDParser.safeParse("甲 *斜體* 乙 _斜體二_ 丙 snake_case_name").richText),
    "<TEXT> <INDENT:0> 甲 <PUSHRGB:0.6,0.9,0.6> 斜體 <POPRGB> 乙"
        .. " <PUSHRGB:0.6,0.9,0.6> 斜體二 <POPRGB> 丙 snake_case_name",
    "斜體映射或 intra-word 守衛錯誤"
)
checkEqual(
    norm(MDParser.safeParse("__粗體__").richText),
    "<TEXT> <INDENT:0> <PUSHRGB:1,0.85,0.4> 粗體 <POPRGB>",
    "__ 粗體映射錯誤"
)
-- PUSHRGB 是堆疊，巢狀後內層顏色勝出：粗斜體視覺上只看得到斜體色
checkEqual(
    norm(MDParser.safeParse("***粗斜體***").richText),
    "<TEXT> <INDENT:0> <PUSHRGB:1,0.85,0.4> <PUSHRGB:0.6,0.9,0.6> 粗斜體 <POPRGB> <POPRGB>",
    "粗斜體映射錯誤"
)
checkNoTextLost("甲 *斜體* 乙 _斜體二_ 丙", { "斜體", "斜體二" }, "斜體")

-- 反斜線逸出。'\<' 必須還原成 &lt; 而不是 <，否則會在輸出裡塞回一個活的 <，
-- 與後面的 > 在同一 token 內配對成 command，前面的文字被引擎丟棄（:462,468）。
checkEqual(
    norm(MDParser.safeParse("\\*不是斜體\\* 與 \\# 不是標題 與 \\<TEXT\\>").richText),
    "<TEXT> <INDENT:0> *不是斜體* 與 # 不是標題 與 &lt;TEXT&gt;",
    "反斜線逸出錯誤"
)
checkEqual(
    norm(MDParser.safeParse("\\- 不是清單").richText),
    "<TEXT> <INDENT:0> - 不是清單",
    "逸出後的 - 不得被當成清單"
)
-- CommonMark：程式碼內不做反斜線逸出，反斜線要原樣留著
checkEqual(
    norm(MDParser.safeParse("`a\\*b`").richText),
    "<TEXT> <INDENT:0> <PUSHRGB:1,0.7,0.85> a\\*b <POPRGB>",
    "程式碼內的反斜線必須原樣保留"
)
checkNoTextLost("\\*不是斜體\\* 與 \\# 不是標題", { "*不是斜體*", "# 不是標題" }, "反斜線逸出")

-- soft break（段落內單一換行）必須併回同一邏輯行，否則「行尾兩空格＝強制換行」
-- 不會有任何可觀察差異——每個 \n 本來就已經變成一個 <LINE>。
checkEqual(
    norm(MDParser.safeParse("第一行\n第二行\n\n第三行").richText),
    "<TEXT> <INDENT:0> 第一行 第二行 <LINE> <LINE> <TEXT> <INDENT:0> 第三行",
    "段落內的 soft break 必須合併成同一邏輯行"
)
checkEqual(
    norm(MDParser.safeParse("甲  \n乙\n丙\\\n丁").richText),
    "<TEXT> <INDENT:0> 甲 <LINE> <TEXT> <INDENT:0> 乙 丙 <LINE> <TEXT> <INDENT:0> 丁",
    "行尾兩空格與行尾反斜線都必須強制換行"
)
-- 強制換行的續行要保留當層 <INDENT:>，不重印 bullet／引言記號以外的東西
checkEqual(
    norm(MDParser.safeParse("- 甲  \n  乙").richText),
    "<TEXT> <INDENT:20> - 甲 <LINE> <TEXT> <INDENT:20> 乙",
    "清單項內的強制換行必須保留縮排且不重印項目符號"
)
checkNoTextLost("甲  \n乙\n丙", { "甲", "乙", "丙" }, "強制換行")

-- autolink：與原生 tag 白名單的匹配集合互斥（白名單的冒號前不允許 '/'），
-- scheme 限 http/https，與 NBPanel 的連結安全政策一致。
local autolink = MDParser.safeParse("見 <https://example.com/a> 完")
checkEqual(#autolink.links, 1, "autolink 必須收進 link 表")
checkEqual(autolink.links[1].text, "https://example.com/a", "autolink 顯示文字錯誤")
checkEqual(autolink.links[1].url, "https://example.com/a", "autolink URL 錯誤")
checkEqual(
    norm(autolink.richText),
    "<TEXT> <INDENT:0> 見 <LINE> <PUSHRGB:0.35,0.65,1> https://example.com/a <POPRGB> <LINE> 完",
    "autolink 必須與一般連結同樣獨行化"
)
local badScheme = MDParser.safeParse("<ftp://example.com/a>")
checkEqual(#badScheme.links, 0, "非 http/https 的 autolink 不得成為連結")
checkEqual(
    norm(badScheme.richText),
    "<TEXT> <INDENT:0> &lt;ftp://example.com/a&gt;",
    "非 http/https 的 autolink 必須被轉義成可見文字"
)
checkEqual(
    norm(MDParser.safeParse("<INDENT:40> 文字").richText),
    "<TEXT> <INDENT:0> <INDENT:40> 文字",
    "autolink 不得搶走原生 tag 白名單"
)
checkNoTextLost("見 <https://example.com/a> 完", { "見", "https://example.com/a", "完" }, "autolink")

-- 刪除線：PZ RichText 沒有刪除線效果（drawText 無此參數），只能吃掉標記顯示純文字
checkEqual(
    norm(MDParser.safeParse("甲 ~~刪除~~ 乙").richText),
    "<TEXT> <INDENT:0> 甲 刪除 乙",
    "刪除線必須移除標記並顯示純文字"
)
checkNoTextLost("甲 ~~刪除~~ 乙", { "甲", "刪除", "乙" }, "刪除線")

-- 行內程式碼必須擋住連結與 autolink：renderContentLine 在 renderInline 之前就掃連結
-- （連結要獨占邏輯行），findCode 沒機會先手，所以連結搜尋要自己跳過 code span。
local codeLink = MDParser.safeParse("`[a](b)`")
checkEqual(#codeLink.links, 0, "行內程式碼內的連結不得成為可點擊連結")
checkEqual(
    norm(codeLink.richText),
    "<TEXT> <INDENT:0> <PUSHRGB:1,0.7,0.85> [a](b) <POPRGB>",
    "行內程式碼內的連結必須原樣顯示"
)
local codeAutolink = MDParser.safeParse("`<https://evil.example/x>`")
checkEqual(#codeAutolink.links, 0, "行內程式碼內的 autolink 不得成為可點擊連結")
checkEqual(
    norm(codeAutolink.richText),
    "<TEXT> <INDENT:0> <PUSHRGB:1,0.7,0.85> &lt;https://evil.example/x&gt; <POPRGB>",
    "行內程式碼內的 autolink 必須轉義成可見文字"
)
-- 同一行有兩個 code span 時，連結被抽走會讓剩下的分隔符互相錯配、把中間的字塗成程式碼色。
-- 這句就是 ADMIN_GUIDE「裸網址」那列的原句。
local docSentence = MDParser.safeParse("please use `<https://...>` or `[text](https://...)`.")
checkEqual(#docSentence.links, 0, "文件原句不得產生任何連結")
checkEqual(
    norm(docSentence.richText),
    "<TEXT> <INDENT:0> please use <PUSHRGB:1,0.7,0.85> &lt;https://...&gt; <POPRGB>"
        .. " or <PUSHRGB:1,0.7,0.85> [text](https://...) <POPRGB> .",
    "兩個 code span 之間的文字不得被錯配成程式碼"
)
-- code span 之外的連結照樣要成立（不能因為擋 code span 就把整行的連結都關掉）
local codeThenLink = MDParser.safeParse("`x` [y](https://a.example) `z`")
checkEqual(#codeThenLink.links, 1, "code span 以外的連結必須照常收集")
checkEqual(codeThenLink.links[1].url, "https://a.example", "code span 以外的連結 URL 錯誤")
-- 註：autolink 版不能用 checkNoTextLost 驗——它的可見內容本來就含 '<'（&lt; 還原後），
-- 那條的把關由上面的字面期望值與下面的 checkTagSpacing 負責。
checkNoTextLost("`[a](b)` 尾字", { "[a](b)", "尾字" }, "行內程式碼擋連結")

-- 逸出哨兵（\1 <digits> \2）是裸位元組，而來源檔是服主手寫的任意位元組：
-- 入口不剝除的話，整份公告會變成錯誤占位，或內容被靜默竄改成別的字元。
local sentinelOverflow = MDParser.safeParse(string.char(1) .. "999999" .. string.char(2))
check(sentinelOverflow.ok, "輸入含哨兵位元組時不得整份解析失敗")
checkEqual(
    norm(sentinelOverflow.richText),
    "<TEXT> <INDENT:0> 999999",
    "哨兵位元組必須在入口剝除"
)
checkEqual(
    norm(MDParser.safeParse(string.char(1) .. "65" .. string.char(2)).richText),
    "<TEXT> <INDENT:0> 65",
    "哨兵位元組不得把數字竄改成別的字元"
)
check(
    not contains(
        MDParser.safeParse(string.char(1) .. "0" .. string.char(2)).richText,
        string.char(0)
    ),
    "輸出不得被塞進 NUL 位元組"
)
-- 剝除哨兵不得影響正常的反斜線逸出
checkEqual(
    norm(MDParser.safeParse("\\*不是斜體\\*" .. string.char(1)).richText),
    "<TEXT> <INDENT:0> *不是斜體*",
    "剝除哨兵後反斜線逸出仍須正常"
)

-- CommonMark：thematic break 優先於清單項，而 `- ---` 本身就符合 thematic break 的產生式
-- （3 個以上同字元、每個後面可跟任意空白）。以 markdown-it commonmark 模式核對過輸出為 <hr />。
checkEqual(
    norm(MDParser.safeParse("- ---").richText),
    ruleText,
    "`- ---` 必須是分隔線（CommonMark 規定 thematic break 優先於清單項）"
)

-- 清單項內的連結：NBPanel:matchLinkGroups 會剝除 "- " 與 "n. " 才比對得到
local listLink = MDParser.safeParse("1. [站台](https://a.example)")
checkEqual(#listLink.links, 1, "有序清單項內的連結必須收集")
checkEqual(listLink.links[1].text, "站台", "有序清單項內的連結顯示文字錯誤")
checkEqual(
    norm(listLink.richText),
    "<TEXT> <INDENT:20> 1. <PUSHRGB:0.35,0.65,1> 站台 <POPRGB>",
    "有序清單項內的連結映射錯誤"
)

-- 任務清單只當純文字顯示（'[ ]' 沒有跟著 '(' 就不是連結），零引擎風險
checkEqual(
    norm(MDParser.safeParse("- [ ] 待辦\n- [x] 完成").richText),
    "<TEXT> <INDENT:20> - [ ] 待辦 <LINE> <TEXT> <INDENT:20> - [x] 完成",
    "任務清單必須以純文字顯示"
)

-- tag 內含空白同樣會被 tokenizer 切開：`<IMAGE:a b.png>` 的前半有 < 沒 >，
-- 會走 :533-557 整段當字面文字印出。這種輸入一律不放行，退回顯示可見文字。
local spacedImage = MDParser.safeParse("![圖](me dia/x.png)")
checkEqual(#spacedImage.images, 0, "含空白的圖片路徑不得產生 IMAGE tag")
checkEqual(
    norm(spacedImage.richText),
    "<TEXT> <INDENT:0> ![圖](me dia/x.png)",
    "含空白的圖片路徑必須退回顯示原始 markdown"
)
checkEqual(
    norm(MDParser.safeParse("<RGB:1, 0, 0>紅").richText),
    "<TEXT> <INDENT:0> &lt;RGB:1, 0, 0&gt;紅",
    "參數含空白的原生 tag 不得放行"
)

-- 引擎不變式（比逐條期望值更難繞過）：輸出裡每個 '<' 前面必須是空白或字串開頭、
-- 對應的 '>' 後面必須是空白或字串結尾、且 <> 之間不得有空白。
-- 任何一條不成立，ISRichTextPanel 就會吃掉文字或把 tag 印出來（:462-486、:533-557）。
local function checkTagSpacing(markdown, label)
    local parsed = MDParser.safeParse(markdown)
    check(parsed.ok, label .. "：parser 不應失敗")
    local richText = parsed.richText
    check(
        not contains(richText, string.char(1)) and not contains(richText, string.char(2)),
        label .. "：逸出哨兵位元組洩漏到輸出"
    )
    local position = 1
    while true do
        local open = string.find(richText, "<", position, true)
        if not open then
            return
        end
        assertionCount = assertionCount + 1
        assert(
            open == 1 or string.sub(richText, open - 1, open - 1) == " ",
            label .. "：tag 的 '<' 前面沒有空白\n" .. richText
        )
        local close = string.find(richText, ">", open + 1, true)
        assertionCount = assertionCount + 1
        assert(close ~= nil, label .. "：有 '<' 卻沒有 '>'\n" .. richText)
        local inner = string.sub(richText, open + 1, close - 1)
        assertionCount = assertionCount + 1
        assert(
            string.find(inner, "%s") == nil and string.find(inner, "<", 1, true) == nil,
            label .. "：tag 內含空白或巢狀 '<'\n" .. richText
        )
        local after = string.sub(richText, close + 1, close + 1)
        assertionCount = assertionCount + 1
        assert(
            after == "" or after == " ",
            label .. "：tag 的 '>' 後面沒有空白\n" .. richText
        )
        position = close + 1
    end
end

checkTagSpacing("# 標\n## 副\n### 三\n#### 四\n##### 五\n###### 六", "全部標題層級")
-- 含圖片的 H1 走的是另一組前綴（H1_IMAGE_PREFIX），tag 間距要另外驗一次
checkTagSpacing("# ![a](images/x.png) 大標\n# 純標\n## ![b](images/y.png) 副", "含圖片的標題")
checkTagSpacing("- a\n  - b\n    - c\n      - d\n        - e", "巢狀清單")
checkTagSpacing("1. a\n2. b\n> q\n>> qq", "有序清單與引言")
checkTagSpacing("```\n<RGB:1,0,0> a b\n```", "程式碼區塊內的原生 tag")
checkTagSpacing("\\<TEXT\\> \\* \\` \\\\ \\<", "反斜線逸出")
checkTagSpacing("<https://a.example/x> <ftp://a.example> <TEXT> <RGB:1, 0, 0>", "autolink 與原生 tag")
checkTagSpacing("![a](me dia/x.png) ![b](<x>) ![c]() ![d](ok/x.png)", "各種壞圖片路徑")
checkTagSpacing(
    "![a](images/a.png =600x200) ![b](images/b.png =x99) ![c](images/c.png =12x)"
        .. " ![d](images/d.png =x) ![e](images/e.png =0x1)",
    "帶尺寸的圖片"
)
checkTagSpacing("![a](images/a.png=600x200) ![b](images/b.png=x9) ![c](images/a=1x2.png)",
    "漏空白的尺寸語法")
checkTagSpacing("<RGB:1,0> <PUSHRGB:1,0,x> <INDENT:abc> <INDENT:> <RGB:1,0,0>",
    "參數形狀不合的原生 tag")
checkTagSpacing("<SIZE:INDENT:zz> <SIZE:IMAGE:x> <SIZE:zz> <SIZE:small>",
    "參數段藏著其他指令的 SIZE")
checkTagSpacing("*a **b `c` d** e* ~~f~~ _g_ __h__ ***i***", "行內語法混合巢狀")
checkTagSpacing("a<b>c 2 < 3 > 1 &lt; &gt;", "裸角括號")
checkTagSpacing("`[a](b)` `<https://a.example/x>` `x` [y](https://b.example) `z`", "行內程式碼擋連結")
checkTagSpacing(string.char(1) .. "999999" .. string.char(2) .. " \\* " .. string.char(2), "哨兵位元組")

-- 行內解析效能：新增語法不得退化成每輪重掃剩餘字串。
-- 壓力來源必須是「單一超長邏輯行」——跨行的成本本來就是線性的，
-- O(n^2) 只會出現在同一行內的 token 搜尋。
local function buildLongLine(repeatCount)
    local parts = {}
    local partIndex
    for partIndex = 1, repeatCount do
        parts[partIndex] = "![圖](media/a.png) 文字 **粗體** *斜體* `碼` 尾"
    end
    return table.concat(parts, " ")
end

local function measureParse(text)
    local started = os.clock()
    local parsed = MDParser.safeParse(text)
    local elapsed = os.clock() - started
    check(parsed.ok, "效能測試的 parser 不應失敗")
    return elapsed
end

measureParse(buildLongLine(200))
local smallElapsed = measureParse(buildLongLine(800))
local largeElapsed = measureParse(buildLongLine(1600))
check(
    largeElapsed <= smallElapsed * 3.2 + 0.05,
    "行內解析必須維持近線性（2 倍輸入耗時上限 3.2 倍）：small="
        .. tostring(smallElapsed) .. " large=" .. tostring(largeElapsed)
)

-- 連結路徑另有一個獨立的搜尋器組（bracket / autolink），buildLongLine 一個都沒有。
-- 段落合併會把「連續 N 行、每行一個連結」併成單一超長邏輯行：文件裡缺哪一種連結，
-- 那一種若每輪重掃剩餘字串就是 O(n^2)。4 倍輸入用 8 倍上限（線性應在 4 倍上下）。
local function buildLinkLines(count, template)
    local parts = {}
    local lineIndex
    for lineIndex = 1, count do
        parts[lineIndex] = template
    end
    return table.concat(parts, "\n")
end

local bracketSmall = measureParse(buildLinkLines(1000, "See [site](https://example.com/page)"))
local bracketLarge = measureParse(buildLinkLines(4000, "See [site](https://example.com/page)"))
check(
    bracketLarge <= bracketSmall * 8 + 0.05,
    "bracket link 解析必須維持近線性：small=" .. tostring(bracketSmall)
        .. " large=" .. tostring(bracketLarge)
)
local autoSmall = measureParse(buildLinkLines(1000, "See <https://example.com/page>"))
local autoLarge = measureParse(buildLinkLines(4000, "See <https://example.com/page>"))
check(
    autoLarge <= autoSmall * 8 + 0.05,
    "autolink 解析必須維持近線性：small=" .. tostring(autoSmall)
        .. " large=" .. tostring(autoLarge)
)

-- 圖片尺寸的拆解是每個 image token 都會走的路徑：長路徑不得退化成 O(n^2)
-- （`^(.-)%s+=(%d*)x(%d*)$` 這種寫法就會，故實作改成往回掃分隔點）
local imagePathSmall = measureParse("![a](" .. string.rep("a", 4000) .. ".png)")
local imagePathLarge = measureParse("![a](" .. string.rep("a", 16000) .. ".png)")
check(
    imagePathLarge <= imagePathSmall * 8 + 0.05,
    "圖片尺寸拆解必須維持近線性：small=" .. tostring(imagePathSmall)
        .. " large=" .. tostring(imagePathLarge)
)
local imageSpaceSmall = measureParse("![a](x" .. string.rep(" ", 4000) .. "b.png)")
local imageSpaceLarge = measureParse("![a](x" .. string.rep(" ", 16000) .. "b.png)")
check(
    imageSpaceLarge <= imageSpaceSmall * 8 + 0.05,
    "含長空白 run 的圖片路徑必須維持近線性：small=" .. tostring(imageSpaceSmall)
        .. " large=" .. tostring(imageSpaceLarge)
)

-- 長空白 run：`%s+$` 的 gsub 會退化成 O(n^2)，而 splitHardBreak 每一行都會走一次
local spaceSmall = measureParse(string.rep(" ", 10000) .. "x")
local spaceLarge = measureParse(string.rep(" ", 40000) .. "x")
check(
    spaceLarge <= spaceSmall * 8 + 0.05,
    "行尾空白修剪必須維持近線性：small=" .. tostring(spaceSmall)
        .. " large=" .. tostring(spaceLarge)
)

-- 大量無法配對的 delimiter 是最容易退化的病態輸入（每個開頭都想重掃到行尾）
local unclosedElapsed = measureParse(string.rep("*x ", 4000) .. string.rep("`y ", 4000))
check(
    unclosedElapsed < 2.0,
    "大量未配對 delimiter 不得退化成 O(n^2)：耗時 " .. tostring(unclosedElapsed)
)

local emoji = "😀"
local boundaryText = string.rep("甲", 5999) .. emoji .. "尾"
checkEqual(NBCore.utf16Length(boundaryText), 6002, "UTF-16 長度計算錯誤")
local boundaryChunks = NBCore.chunkText(boundaryText)
checkEqual(#boundaryChunks, 2, "surrogate 邊界應切成兩塊")
checkEqual(NBCore.utf16Length(boundaryChunks[1]), 5999, "不得把 high surrogate 留在第一塊")
checkEqual(NBCore.utf16Length(boundaryChunks[2]), 3, "第二塊應含完整 surrogate pair 與尾字")
check(
    string.sub(boundaryChunks[2], 1, string.len(emoji)) == emoji,
    "第二塊必須以完整 surrogate pair 開始"
)

local exactBoundaryText = string.rep("甲", 5998) .. emoji .. "尾"
local exactBoundaryChunks = NBCore.chunkText(exactBoundaryText)
checkEqual(NBCore.utf16Length(exactBoundaryChunks[1]), 6000, "完整 surrogate pair 應可落在邊界內")
check(
    string.sub(exactBoundaryChunks[1], -string.len(emoji)) == emoji,
    "邊界內的 surrogate pair 不得被拆開"
)

local chunkIndex
for chunkIndex = 1, #boundaryChunks do
    check(
        NBCore.utf16Length(boundaryChunks[chunkIndex]) <= NBCore.CHUNK_UTF16_LIMIT,
        "任何 chunk 都不得超過 6000 UTF-16 char"
    )
end

local reassembled = NBCore.reassembleChunks(boundaryChunks, #boundaryChunks)
checkEqual(reassembled, boundaryText, "chunk 重組內容不一致")
checkEqual(NBCore.djb2Hex(reassembled), NBCore.djb2Hex(boundaryText), "重組後 hash 必須一致")

local emptyChunks = NBCore.chunkText("")
checkEqual(#emptyChunks, 1, "空檔仍須產生一個可傳輸 chunk")
checkEqual(emptyChunks[1], "", "空檔 chunk 內容錯誤")
checkEqual(NBCore.reassembleChunks(emptyChunks), "", "空檔重組錯誤")

-- ---------------------------------------------------------------------------
-- NBImage：base64 編解碼、分批切割、串流 hash
-- 期望值一律寫字面值（RFC 4648 的標準測試向量、實際跑出來的 hash），
-- 不引用 NBImage 自己的常數，否則常數被改壞時測試仍恆真。
-- ---------------------------------------------------------------------------

local function bytesOf(text)
    local values = {}
    local index
    for index = 1, string.len(text) do
        values[index] = string.byte(text, index)
    end
    return values
end

checkEqual(NBImage.encodeBytes(bytesOf("Man"), 1, 3, true), "TWFu", "base64 三位元組向量錯誤")
checkEqual(NBImage.encodeBytes(bytesOf("Ma"), 1, 2, true), "TWE=", "base64 兩位元組 padding 錯誤")
checkEqual(NBImage.encodeBytes(bytesOf("M"), 1, 1, true), "TQ==", "base64 單位元組 padding 錯誤")
checkEqual(NBImage.encodeBytes({}, 1, 0, true), "", "空輸入應編碼成空字串")
checkEqual(
    NBImage.encodeBytes(bytesOf("any carnal pleasure."), 1, 20, true),
    "YW55IGNhcm5hbCBwbGVhc3VyZS4=",
    "base64 RFC 4648 向量錯誤"
)
-- 二進位（非 ASCII）位元組也必須正確：PNG 內容大量是 0x00 / 0xFF
checkEqual(NBImage.encodeBytes({ 0, 0, 0 }, 1, 3, true), "AAAA", "全 0 位元組編碼錯誤")
checkEqual(NBImage.encodeBytes({ 255, 255, 255 }, 1, 3, true), "////", "全 0xFF 位元組編碼錯誤")
checkEqual(NBImage.encodeBytes({ 251, 255, 190 }, 1, 3, true), "+/++", "62/63 號字元對應錯誤")

checkEqual(NBImage.encodedLength(0), 0, "空輸入編碼長度錯誤")
checkEqual(NBImage.encodedLength(1), 4, "1 byte 編碼長度錯誤")
checkEqual(NBImage.encodedLength(3), 4, "3 bytes 編碼長度錯誤")
checkEqual(NBImage.encodedLength(4), 8, "4 bytes 編碼長度錯誤")
checkEqual(NBImage.encodedLength(204800), 273068, "200KB 編碼長度錯誤")

-- 分批編碼：每批必須是 3 的倍數，串起來要與一次跑完完全相同（伺服器端就是這樣跨 tick 推進的）
local sequential = {}
local seqIndex
for seqIndex = 1, 256 do
    sequential[seqIndex] = (seqIndex - 1) % 256
end
local oneShot = NBImage.encodeBytes(sequential, 1, 256, true)
checkEqual(string.len(oneShot), 344, "256 bytes 編碼長度錯誤")
checkEqual(string.sub(oneShot, 1, 24), "AAECAwQFBgcICQoLDA0ODxAR", "遞增位元組編碼前段錯誤")
checkEqual(string.sub(oneShot, -8), "/P3+/w==", "遞增位元組編碼尾段錯誤")

local batched = {}
local cursor = 1
while cursor <= 256 do
    local count = 33
    local isFinal = false
    if cursor + count - 1 >= 256 then
        count = 256 - cursor + 1
        isFinal = true
    end
    batched[#batched + 1] = NBImage.encodeBytes(sequential, cursor, count, isFinal)
    cursor = cursor + count
end
checkEqual(table.concat(batched), oneShot, "分批編碼結果必須與一次編碼完全相同")

check(
    pcall(NBImage.encodeBytes, sequential, 1, 4, false) == false,
    "非收尾批次的 byteCount 不是 3 的倍數時必須拋錯（否則跨批 padding 會壞掉）"
)

-- 解碼：回傳「每字元即一個位元組」的字串，可直接餵 DataOutputStream:writeBytes
checkEqual(NBImage.decodeToByteString("TWFu", 1, 4), "Man", "base64 解碼錯誤")
checkEqual(NBImage.decodeToByteString("TWE=", 1, 4), "Ma", "base64 單一 padding 解碼錯誤")
checkEqual(NBImage.decodeToByteString("TQ==", 1, 4), "M", "base64 雙 padding 解碼錯誤")
checkEqual(NBImage.decodeToByteString("AAAA", 1, 4), string.char(0, 0, 0), "全 0 解碼錯誤")
checkEqual(NBImage.decodeToByteString("////", 1, 4), string.char(255, 255, 255), "全 0xFF 解碼錯誤")
checkEqual(NBImage.decodeToByteString("", 1, 0), "", "空解碼錯誤")
check(
    pcall(NBImage.decodeToByteString, "TWFu", 1, 3) == false,
    "charCount 不是 4 的倍數時必須拋錯"
)
check(
    pcall(NBImage.decodeToByteString, "TW*u", 1, 4) == false,
    "非法 base64 字元必須拋錯"
)
check(
    pcall(NBImage.decodeToByteString, "TWFu", 1, 8) == false,
    "解碼範圍超過輸入長度必須拋錯"
)

-- 分批解碼（client 端每 tick 一小批）串起來必須等於原始位元組
local decodeParts = {}
local decodeCursor = 1
while decodeCursor <= 344 do
    local count = 40
    if decodeCursor + count - 1 > 344 then
        count = 344 - decodeCursor + 1
    end
    decodeParts[#decodeParts + 1] = NBImage.decodeToByteString(oneShot, decodeCursor, count)
    decodeCursor = decodeCursor + count
end
local roundTripped = table.concat(decodeParts)
checkEqual(string.len(roundTripped), 256, "round-trip 位元組數錯誤")
local byteIndex
local roundTripMatches = true
for byteIndex = 1, 256 do
    if string.byte(roundTripped, byteIndex) ~= sequential[byteIndex] then
        roundTripMatches = false
        break
    end
end
check(roundTripMatches, "分批解碼後每個位元組都必須與來源相同")

-- 串流 DJB2：語意必須與 NBCore.djb2Hex 對 ASCII 完全一致，且分批推進結果相同
checkEqual(
    NBImage.hashHex(NBImage.hashUpdate(NBImage.hashInit(), "TWFu")),
    "7c8c9aeb",
    "串流 DJB2 固定向量錯誤"
)
checkEqual(
    NBImage.hashHex(NBImage.hashUpdate(NBImage.hashInit(), oneShot)),
    "efbf420d",
    "256 bytes base64 的串流 DJB2 固定向量錯誤"
)
checkEqual(
    NBImage.hashHex(NBImage.hashUpdate(NBImage.hashInit(), oneShot)),
    NBCore.djb2Hex(oneShot),
    "串流 DJB2 必須與 NBCore.djb2Hex 對 ASCII 輸入一致"
)
local streamed = NBImage.hashInit()
local streamCursor = 1
while streamCursor <= 344 do
    local stop = streamCursor + 49
    if stop > 344 then
        stop = 344
    end
    streamed = NBImage.hashUpdate(streamed, oneShot, streamCursor, stop)
    streamCursor = stop + 1
end
checkEqual(NBImage.hashHex(streamed), "efbf420d", "分批 hash 必須與一次算完相同")

-- 分塊：每塊上限一致、切點正確、殘段收尾
local chunks = {}
local pending = NBImage.pushChunks("", "abcdefghij", chunks, 4)
checkEqual(#chunks, 2, "10 字元以 4 為上限應切出 2 塊")
checkEqual(chunks[1], "abcd", "第一塊內容錯誤")
checkEqual(chunks[2], "efgh", "第二塊內容錯誤")
checkEqual(pending, "ij", "殘段必須留在 pending")
pending = NBImage.pushChunks(pending, "kl", chunks, 4)
checkEqual(#chunks, 3, "補滿一塊後應切出第三塊")
checkEqual(chunks[3], "ijkl", "跨批切塊內容錯誤")
checkEqual(pending, "", "剛好切齊時 pending 應為空字串")
NBImage.flushChunks("mn", chunks)
checkEqual(#chunks, 4, "收尾必須推出殘段")
checkEqual(chunks[4], "mn", "收尾殘段內容錯誤")
checkEqual(table.concat(chunks), "abcdefghijklmn", "分塊重組必須還原原始字串")

local emptyImageChunks = {}
NBImage.flushChunks("", emptyImageChunks)
checkEqual(#emptyImageChunks, 1, "空內容仍須留下一塊（n=0 無法通過接收端驗證）")
checkEqual(emptyImageChunks[1], "", "空內容分塊應為空字串")

-- 真實分塊上限：6000 UTF-16 chars（與公告分塊同一規則）
local wideChunks = {}
local widePending = NBImage.pushChunks("", string.rep("A", 13000), wideChunks, 6000)
checkEqual(#wideChunks, 2, "13000 字元以 6000 為上限應切出 2 塊")
checkEqual(string.len(wideChunks[1]), 6000, "第一塊必須剛好 6000 字元")
checkEqual(string.len(widePending), 1000, "殘段長度錯誤")

-- 名稱與 hash 契約（producer 掃描目錄與 receiver 驗 manifest 共用同一份規則）
check(NBImage.isValidName("poc_tiny.png"), "合法檔名被拒")
check(NBImage.isValidName("Rules-01.PNG"), "大寫副檔名必須接受")
check(not NBImage.isValidName("../evil.png"), "路徑穿越必須拒絕")
check(not NBImage.isValidName("a/b.png"), "含目錄分隔的名稱必須拒絕")
check(not NBImage.isValidName("notice.jpg"), "非 png 必須拒絕")
check(not NBImage.isValidName("_lead.png"), "首字元必須是英數")
check(not NBImage.isValidName(string.rep("a", 62) .. ".png"), "超長檔名必須拒絕")
check(not NBImage.isValidName("公告.png"), "非 ASCII 檔名必須拒絕")
check(NBImage.isHash("0f923099"), "合法 hash 被拒")
check(not NBImage.isHash("0F923099"), "大寫 hash 必須拒絕（檔名一律小寫）")
check(not NBImage.isHash("0f92309"), "長度不足的 hash 必須拒絕")
check(not NBImage.isHash("0f92309g"), "非 hex 字元必須拒絕")

-- 每 tick 預算：server（讀檔＋編碼）與 client（解碼＋寫檔）成本差約 5.6 倍，必須是兩個常數。
-- client 端 getFileOutput 回的是未緩衝的串流，writeBytes 每個 char 都會打到 OS 一次，
-- 8192 會直接吃掉整個影格；預算必須是 3 的倍數，否則每批換算出來的 char 數會不對齊。
checkEqual(NBImage.BYTES_PER_TICK, 8192, "server 每 tick 位元組預算被改動")
checkEqual(NBImage.WRITE_BYTES_PER_TICK, 1536, "client 每 tick 寫檔預算被改動")
check(NBImage.WRITE_BYTES_PER_TICK < NBImage.BYTES_PER_TICK,
    "client 寫檔預算必須小於 server 讀檔預算")
checkEqual(NBImage.WRITE_BYTES_PER_TICK % 3, 0, "寫檔預算必須是 3 的倍數")
-- 預算換算出來的 char 數，必須剛好解碼回同樣多的位元組（pumpWrite 就是這樣算的）
local budgetChars = math.floor(NBImage.WRITE_BYTES_PER_TICK / 3) * 4
checkEqual(budgetChars, 2048, "1536 bytes 應換算成 2048 個 base64 字元")
checkEqual(
    string.len(NBImage.decodeToByteString(string.rep("TWFu", 512), 1, budgetChars)),
    1536,
    "一批預算解碼出來的位元組數必須等於預算本身"
)

-- 時間窗的寫入額度：擋惡意 server 無限輪替 manifest 一直讓 client 寫檔。
-- 這是**玩家保護**，必須是與伺服器宣告值無關的絕對常數：若由 MAX_TOTAL_BYTES 倍率推導，
-- 服主把總量調到天花板時玩家第一輪就撞上限，圖永遠同步不完。
checkEqual(NBImage.WRITE_WINDOW_BYTES, 67108864, "時間窗寫入額度被改動")
checkEqual(NBImage.WRITE_WINDOW_MS, 1800000, "寫入時間窗長度被改動")
-- 「服主用滿天花板 + 每張圖都重試到 MAX_ATTEMPTS=3 次」是最壞的**合法**用量，不得誤觸。
check(NBImage.WRITE_WINDOW_BYTES >= NBImage.MAX_TOTAL_KB * 1024 * 3,
    "服主把總量調到天花板時，正常重試也不得撞上單一時間窗的寫入額度")
-- 快取總量上限：淘汰機制的界。必須大於單台伺服器的合法總量上界，否則玩家在**一台**
-- 誠實伺服器上就會被迫反覆淘汰＋重下載（一輪約 3 分鐘）。
checkEqual(NBImage.CACHE_BUDGET_BYTES, 134217728, "快取總量上限被改動")
check(NBImage.CACHE_BUDGET_BYTES >= NBImage.MAX_TOTAL_KB * 1024 * 8,
    "快取總量上限至少要放得下 8 台設定拉滿的伺服器")

-- ---------------------------------------------------------------------------
-- 三個圖片上限的沙盒存取函式。期望值全部寫字面數字，不引用 NBImage 自己的常數。
-- 產生端與接收端共用這些解析結果，讀錯值會讓 client 把整份圖片清單判為無效。
-- ---------------------------------------------------------------------------
-- 不變式：單張上限的沙盒上界 == 總量上限的沙盒下界 -> 任何合法組合下單張都不可能超過總量，
-- 不需要任何執行期交叉檢查。改動任一邊而不改另一邊就會紅。
checkEqual(NBImage.MAX_IMAGE_KB, NBImage.MIN_TOTAL_KB,
    "單張上限的沙盒上界必須等於總量上限的沙盒下界，否則單張可能超過總量")

checkEqual(NBImage.maxImageBytes(), 524288, "未設定 Sandbox 時應回預設 512KB")
SandboxVars = { MinidoracatNB = { MaxImageKB = 1024 } }
checkEqual(NBImage.maxImageBytes(), 1048576, "應讀取 Sandbox 的 MaxImageKB")
SandboxVars = { MinidoracatNB = { MaxImageKB = 63 } }
checkEqual(NBImage.maxImageBytes(), 524288, "低於下限 64KB 應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageKB = 4097 } }
checkEqual(NBImage.maxImageBytes(), 524288, "高於上限 4096KB 應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageKB = 1024.5 } }
checkEqual(NBImage.maxImageBytes(), 524288, "非整數應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageKB = "abc" } }
checkEqual(NBImage.maxImageBytes(), 524288, "非數字應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageKB = "1024" } }
checkEqual(NBImage.maxImageBytes(), 1048576, "字串型別的 Sandbox 值也要能解析")
SandboxVars = {}
checkEqual(NBImage.maxImageBytes(), 524288, "SandboxVars 缺 MinidoracatNB 分頁時回預設")
SandboxVars = nil
checkEqual(NBImage.maxImageBytes(), 524288, "缺 SandboxVars（標準 Lua 環境）時回預設")

checkEqual(NBImage.maxImageCount(), 20, "未設定 Sandbox 時張數應回預設 20")
SandboxVars = { MinidoracatNB = { MaxImageCount = 50 } }
checkEqual(NBImage.maxImageCount(), 50, "應讀取 Sandbox 的 MaxImageCount")
SandboxVars = { MinidoracatNB = { MaxImageCount = 0 } }
checkEqual(NBImage.maxImageCount(), 20, "低於下限 1 應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageCount = 201 } }
checkEqual(NBImage.maxImageCount(), 20, "高於上限 200 應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageCount = 50.5 } }
checkEqual(NBImage.maxImageCount(), 20, "非整數應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageCount = {} } }
checkEqual(NBImage.maxImageCount(), 20, "非數字應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageCount = "50" } }
checkEqual(NBImage.maxImageCount(), 50, "字串型別的 Sandbox 值也要能解析")
SandboxVars = {}
checkEqual(NBImage.maxImageCount(), 20, "SandboxVars 缺 MinidoracatNB 分頁時回預設")
SandboxVars = nil
checkEqual(NBImage.maxImageCount(), 20, "缺 SandboxVars（標準 Lua 環境）時回預設")

checkEqual(NBImage.maxTotalBytes(), 4194304, "未設定 Sandbox 時總量應回預設 4MB")
SandboxVars = { MinidoracatNB = { MaxImageTotalKB = 8192 } }
checkEqual(NBImage.maxTotalBytes(), 8388608, "應讀取 Sandbox 的 MaxImageTotalKB")
SandboxVars = { MinidoracatNB = { MaxImageTotalKB = 4095 } }
checkEqual(NBImage.maxTotalBytes(), 4194304, "低於下限 4096KB 應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageTotalKB = 16385 } }
checkEqual(NBImage.maxTotalBytes(), 4194304, "高於上限 16384KB 應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageTotalKB = 8192.5 } }
checkEqual(NBImage.maxTotalBytes(), 4194304, "非整數應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageTotalKB = true } }
checkEqual(NBImage.maxTotalBytes(), 4194304, "非數字應回退預設")
SandboxVars = { MinidoracatNB = { MaxImageTotalKB = "8192" } }
checkEqual(NBImage.maxTotalBytes(), 8388608, "字串型別的 Sandbox 值也要能解析")
SandboxVars = {}
checkEqual(NBImage.maxTotalBytes(), 4194304, "SandboxVars 缺 MinidoracatNB 分頁時回預設")
SandboxVars = nil
checkEqual(NBImage.maxTotalBytes(), 4194304, "缺 SandboxVars（標準 Lua 環境）時回預設")

-- 惡意 server 宣告超大值：accessor 本身就必須把結果留在硬天花板內（第一道）。
SandboxVars = {
    MinidoracatNB = {
        MaxImageKB = 999999,
        MaxImageCount = 999999,
        MaxImageTotalKB = 999999,
    },
}
check(NBImage.maxImageBytes() <= 4096 * 1024, "宣告值不得讓單張上限超過硬天花板")
check(NBImage.maxImageCount() <= 200, "宣告值不得讓張數上限超過硬天花板")
check(NBImage.maxTotalBytes() <= 16384 * 1024, "宣告值不得讓總量上限超過硬天花板")
SandboxVars = nil

-- ---------------------------------------------------------------------------
-- sanitizeName 的截長（選用參數）。log 值若來自對端（register 的 lang、settings.ini 的
-- lang=）長度不受限，writeLog 到 10MB 是整檔截斷非輪替，會沖掉服主的排查紀錄。
-- ---------------------------------------------------------------------------
checkEqual(NBCore.sanitizeName("abc"), "abc", "不傳上限時行為必須完全不變")
checkEqual(NBCore.sanitizeName(string.rep("a", 200)), string.rep("a", 200),
    "不傳上限時不得截長（既有呼叫點依賴這個行為）")
checkEqual(NBCore.sanitizeName(string.rep("a", 200), 64), string.rep("a", 64) .. "~",
    "超過上限必須截到上限並補上截斷標記")
checkEqual(NBCore.sanitizeName("abc", 64), "abc", "未超過上限不得加標記")
checkEqual(NBCore.sanitizeName("ab cd", 64), "ab_cd", "截長不得影響既有的消毒規則")
checkEqual(NBCore.sanitizeName(string.rep("a", 200), 0), string.rep("a", 200),
    "上限小於 1 視為未指定")

-- 語系切換序號的上界是產生端與接收端共用的常數，寫死期望值不引用被測模組。
checkEqual(NBCore.MAX_LANGUAGE_SEQ, 1000000, "語系切換序號上界被改動")

-- ---------------------------------------------------------------------------
-- PZ 執行環境樁。NBServer／NBClient 的協定不變式（每 tick 限流、語系切換完成判定、
-- settings.ini 落地驗證）光靠讀碼保證不了，必須實跑真正出貨的那份程式碼。
-- 樁只補「實際被呼叫到的」PZ 全域，不模擬引擎其餘行為。
--
-- **順序關鍵**：getTimestampMs 必須等 NBCore／NBReader 載入完才定義——那兩個檔用
-- `type(getTimestampMs) ~= "function"` 判斷字串索引是 UTF-8 byte 還是 UTF-16 unit，
-- 提前定義會讓它們切到 Kahlua 模式，上面所有既有斷言全數失真。
-- ---------------------------------------------------------------------------
local MOD_LUA = "MOD/MinidoracatNoticeBoardFor42/Contents/mods/"
    .. "MinidoracatNoticeBoardFor42/42/media/lua/"
package.path = MOD_LUA .. "server/?.lua;" .. MOD_LUA .. "client/?.lua;" .. package.path

local env = { isServer = true, isClient = true, nowMs = 1000000, gameLanguage = "EN" }

function isServer()
    return env.isServer
end

function isClient()
    return env.isClient
end

function getFileSeparator()
    return "/"
end

Translator = {
    getLanguage = function()
        return { name = function() return env.gameLanguage end }
    end,
}

local eventSlots = {}
local function eventSlot(name)
    local slot = eventSlots[name]
    if not slot then
        slot = { handlers = {} }
        slot.Add = function(handler)
            slot.handlers[#slot.handlers + 1] = handler
        end
        slot.Remove = function(handler)
            local index
            for index = 1, #slot.handlers do
                if slot.handlers[index] == handler then
                    table.remove(slot.handlers, index)
                    return
                end
            end
        end
        eventSlots[name] = slot
    end
    return slot
end

Events = setmetatable({}, {
    __index = function(_, name)
        return eventSlot(name)
    end,
})
LuaEventManager = {
    AddEvent = function(name)
        eventSlot(name)
    end,
}

-- handler 清單先複製再走訪：registerOnTick 會在自己的 handler 裡把自己 Remove 掉。
local function fireEvent(name, ...)
    local slot = eventSlot(name)
    local snapshot = {}
    local index
    for index = 1, #slot.handlers do
        snapshot[index] = slot.handlers[index]
    end
    for index = 1, #snapshot do
        snapshot[index](...)
    end
end

function triggerEvent(name, ...)
    fireEvent(name, ...)
end

-- 記憶體檔案系統。fsWorking=false 模擬引擎的靜默寫入失敗：PrintWriter 把 IOException
-- 記在內部旗標從不外拋，LuaFileWriter 也沒暴露 checkError()，pcall 會回報成功。
local diskFiles = {}
local fsWorking = true

function getFileWriter(path, createIfNull, append)
    local buffer = {}
    if append and diskFiles[path] then
        buffer[1] = diskFiles[path]
    end
    return {
        write = function(_, text)
            buffer[#buffer + 1] = text
        end,
        close = function()
            if fsWorking then
                diskFiles[path] = table.concat(buffer)
            end
        end,
    }
end

local function makeLineReader(content)
    local position = 1
    return {
        readLine = function()
            local length = string.len(content)
            if position > length then
                return nil
            end
            local newlineAt = string.find(content, "\n", position, true)
            local line
            if newlineAt then
                line = string.sub(content, position, newlineAt - 1)
                position = newlineAt + 1
            else
                line = string.sub(content, position)
                position = length + 1
            end
            return line
        end,
        close = function() end,
    }
end

-- 讀檔可能拋錯（磁碟／權限問題），不是只有「回 nil＝不存在」一種結果。
local readerFails = {}

function getFileReader(path)
    if readerFails[path] then
        error("io error on " .. path)
    end
    local content = diskFiles[path]
    if not content then
        return nil
    end
    return makeLineReader(content)
end

-- MOD 資源檔一律讀 repo 裡真正要出貨的那一份（EXAMPLE_DIR／NoticeBoardImages），
-- 不另寫一份副本——否則資源檔改了測試也不會紅。
local MOD_VERSION_DIR = "MOD/MinidoracatNoticeBoardFor42/Contents/mods/"
    .. "MinidoracatNoticeBoardFor42/42/"

local function readRepoFile(relativePath)
    local handle = io.open(MOD_VERSION_DIR .. relativePath, "rb")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

function getModFileReader(modId, path, createIfNull)
    if modId ~= "MinidoracatNoticeBoardFor42" then
        return nil
    end
    local content = readRepoFile(path)
    if not content then
        return nil
    end
    return makeLineReader(content)
end

-- getFileInput 的樁：只回大小（DataInputStream(FileInputStream) 的 available()，
-- LuaManager.java:6863-6881），並記錄每個檔名這一輪被開了幾次，好驗開檔次數的上界。
local imageSizes = {}
local imageProbeFails = {}
local imageOpens = {}
local imageCloses = 0
-- imageShortReads[name] = k 代表串流讀到第 k 個位元組就回 -1（EOF），也就是實際可讀量
-- 比 available() 宣告的少。只有「實跑一次完整編碼」的測試會用到 read()。
local imageShortReads = {}

function getFileInput(path)
    local name = string.match(path, "^NoticeBoard/images/(.+)$")
    if name == nil then
        return nil
    end
    imageOpens[name] = (imageOpens[name] or 0) + 1
    local size = imageSizes[name]
    if size == nil then
        -- 檔案不存在時引擎回 null（同上出處），不是拋錯
        return nil
    end
    local position = 0
    local eofAt = imageShortReads[name] or size
    return {
        -- IO 錯誤在 available()／read() 才浮現：getFileInput 自己把 FileNotFoundException
        -- 吞掉只寫 log（LuaManager.java:6875-6877），從不外拋。錯在這裡才逼呼叫端走
        -- 「已經拿到 handle」的那條路 —— 也就是必須 close 的那條。
        available = function()
            if imageProbeFails[name] then
                error("io error on " .. name)
            end
            return size
        end,
        -- 沒有 readInt：readImageBatch 會 pcall 探測失敗後降級成逐位元組 read()。
        read = function()
            if position >= eofAt then
                return -1
            end
            position = position + 1
            return position % 256
        end,
        close = function() imageCloses = imageCloses + 1 end,
    }
end

local sentCommands = {}
function sendServerCommand(player, module, command, payload)
    sentCommands[#sentCommands + 1] = {
        player = player,
        module = module,
        command = command,
        payload = payload,
    }
end

local clientCommands = {}
function sendClientCommand(module, command, args)
    clientCommands[#clientCommands + 1] = {
        module = module,
        command = command,
        args = args,
    }
end

local stubPlayer = { getOnlineID = function() return 1 end }
function getPlayer()
    return stubPlayer
end

function writeLog() end

-- logLine 先 print 再 writeLog；攔 print 就能斷言 log 內容，順便讓測試輸出保持乾淨。
local realPrint = print
local logLines = {}
print = function(text)
    logLines[#logLines + 1] = tostring(text)
end

local function logContains(fragment)
    local index
    for index = 1, #logLines do
        if string.find(logLines[index], fragment, 1, true) then
            return true
        end
    end
    return false
end

local NBServer = require "NoticeBoard/NBServer"
local NBReader = require "NoticeBoard/NBReader"
local NBClient = require "NoticeBoard/NBClient"

-- 這行必須在上面三個 require 之後（見本區塊開頭的順序說明）。
function getTimestampMs()
    return env.nowMs
end

local MODULE = "MinidoracatNB"
local serverState = NBServer.getState()
local clientState = NBClient.state

local function makePlayer(username)
    return { getUsername = function() return username end }
end

local function makeCache(chunkCount)
    local chunks = {}
    local index
    for index = 1, chunkCount do
        chunks[index] = "part" .. tostring(index)
    end
    return {
        language = "EN",
        files = { { id = "10_a.md", n = chunkCount, chunks = chunks } },
        manifestFiles = { { id = "10_a.md", title = "A", n = chunkCount, h = "0f923099" } },
    }
end

local function resetServer(chunkCount)
    serverState.defaultLanguage = "EN"
    serverState.sid = "0f9230990f9230990f9230990f923099"
    serverState.version = 1
    serverState.languageCaches = { EN = makeCache(chunkCount or 40) }
    serverState.availableLanguages = { "EN" }
    serverState.imageManifest = {}
    serverState.imageByHash = {}
    serverState.registrations = {}
    serverState.online = {}
    serverState.cooldowns = {}
    serverState.langPending = {}
    serverState.langSeq = {}
    serverState.jobs = {}
    serverState.queued = {}
    serverState.queue = {}
    serverState.rejectLogAt = {}
    serverState.imgCooldownAt = {}
    serverState.langCooldownAt = {}
    serverState.localLanguage = nil
    sentCommands = {}
end

local function countTargets()
    local perPlayer = {}
    local index
    for index = 1, #sentCommands do
        local username = sentCommands[index].player.getUsername()
        perPlayer[username] = (perPlayer[username] or 0) + 1
    end
    local distinct = 0
    local _
    for _ in pairs(perPlayer) do
        distinct = distinct + 1
    end
    return perPlayer, distinct
end

-- ---------------------------------------------------------------------------
-- 頁籤名稱／toast 用的標題（NBReader 的 extractTitle）。`#` 標題現在支援放圖片，
-- 而第一個 H1 同時是頁籤名稱，圖片標記若原樣留著，頁籤上會出現一整條路徑，
-- 頁籤寬度又是 MeasureStringX(title)+28 算的（NBPanel.lua:1216）。
-- 走公開的 scanLanguage 而不是直接測 local，順便釘住整條 producer 路徑。
-- ---------------------------------------------------------------------------
local scannedNames = {}
function listFilesInZomboidLuaDirectory(directory)
    local names = scannedNames[directory] or {}
    return {
        size = function() return #names end,
        get = function(_, index) return names[index + 1] end,
    }
end

local function titleOf(markdown)
    scannedNames["NoticeBoard/EN"] = { "10_a.md" }
    diskFiles["NoticeBoard/EN/10_a.md"] = markdown
    local scan = NBReader.scanLanguage("EN")
    return scan.files[1] and scan.files[1].title
end

checkEqual(titleOf("# 伺服器公告"), "伺服器公告", "純文字標題必須原樣當頁籤名稱")
checkEqual(
    titleOf("# ![公告圖](images/logo.png) 伺服器公告"),
    "公告圖 伺服器公告",
    "markdown 圖片標記必須只留下替代文字，路徑不得出現在頁籤上"
)
checkEqual(
    titleOf("# <IMAGE:media/textures/pack/head.png> 伺服器公告"),
    "伺服器公告",
    "手寫原生 <IMAGE:> 沒有替代文字可留，整段拿掉"
)
checkEqual(
    titleOf("# <IMAGECENTRE:media/textures/pack/head.png> 伺服器公告"),
    "伺服器公告",
    "手寫原生 <IMAGECENTRE:> 同樣不得留在頁籤名稱上"
)
-- 只有圖片的標題剝完是空字串 -> 往下找下一個 `#`，都沒有才退回檔名
checkEqual(
    titleOf("# ![公告圖](images/logo.png)\n\n# 真正的標題"),
    "公告圖",
    "只有圖片的標題仍保留替代文字（不得意外落到下一個標題）"
)
checkEqual(
    titleOf("# <IMAGE:images/logo.png>\n\n# 真正的標題"),
    "真正的標題",
    "剝完變空字串的標題必須跳過，改用下一個 `#`"
)
checkEqual(
    titleOf("# <IMAGE:images/logo.png>\n\n沒有其他標題"),
    "10_a.md",
    "整份都沒有可用標題時退回檔名"
)

-- ---------------------------------------------------------------------------
-- P2：每 tick 的限流是「每玩家」而不是「每次取 job」。
-- 舊版把未送完的 job 立刻排回同一個 while 的佇列尾端，而單人計數在每次取 job 時歸零，
-- 於是佇列裡只有一位玩家時，同一 tick 內同一個 job 被取 4 次 ×8 則＝32 則全灌給一個人。
-- ---------------------------------------------------------------------------
resetServer(40)
env.nowMs = 2000000
NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 0 })
checkEqual(#serverState.queue, 1, "register 之後應有一個排隊中的推送 job")

NBServer.processQueue()
checkEqual(#sentCommands, 8, "單一玩家的長 job 在一個 tick 內最多只能收到 8 則")
checkEqual(sentCommands[1].command, "manifest", "第一則必須是 manifest")
checkEqual(#serverState.queue, 1, "沒送完的 job 必須留在佇列裡")

NBServer.processQueue()
checkEqual(#sentCommands, 16, "第二個 tick 再送 8 則（累計 16）")

-- 4 人上限：六位玩家排隊時，一個 tick 只能服務 4 位、總量不超過 32 則。
resetServer(40)
env.nowMs = env.nowMs + 60000
local playerIndex
for playerIndex = 1, 6 do
    NBServer.onClientCommand(MODULE, "register",
        makePlayer("p" .. tostring(playerIndex)), { lang = "EN", lseq = 0 })
end
checkEqual(#serverState.queue, 6, "六位玩家應各有一個 job")
NBServer.processQueue()
local perPlayer, distinctPlayers = countTargets()
checkEqual(distinctPlayers, 4, "一個 tick 最多服務 4 位玩家")
checkEqual(#sentCommands, 32, "一個 tick 最多送出 32 則")
local playerName, playerCount
for playerName, playerCount in pairs(perPlayer) do
    checkEqual(playerCount, 8, "每位玩家一個 tick 最多 8 則（" .. playerName .. "）")
end
checkEqual(#serverState.queue, 6, "所有 job 都還沒送完，應全部留在佇列")

-- 圖片 job 與內容 job 共吃同一份單人 8 則額度（刻意設計，不可另開旁路）。
resetServer(40)
env.nowMs = env.nowMs + 60000
NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 0 })
local imageChunks = {}
local chunkIndex
for chunkIndex = 1, 30 do
    imageChunks[chunkIndex] = "img" .. tostring(chunkIndex)
end
serverState.imageByHash = {
    aabbccdd = { name = "a.png", h = "aabbccdd", n = 30, b = 100, chunks = imageChunks },
}
NBServer.onClientCommand(MODULE, "imgreq", makePlayer("alice"), { hashes = { "aabbccdd" } })
checkEqual(#serverState.queue, 2, "同一位玩家的內容 job 與圖片 job 是兩個 key")
NBServer.processQueue()
checkEqual(#sentCommands, 8, "內容與圖片必須共吃同一份 8 則額度")

-- ---------------------------------------------------------------------------
-- P1（server 端）：manifest 必須原樣回帶 client 送來的語系切換序號，且序號是信任邊界。
-- ---------------------------------------------------------------------------
resetServer(1)
env.nowMs = env.nowMs + 60000
NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 42 })
NBServer.processQueue()
checkEqual(sentCommands[1].command, "manifest", "第一則必須是 manifest")
checkEqual(sentCommands[1].payload.lseq, 42, "manifest 必須回帶送來的序號")
checkEqual(sentCommands[1].payload.lang, "EN", "manifest 仍須帶語系值（舊版 client 用）")

local badSeqs = { "42", -1, 1.5, 1000001, nil }
local badIndex
for badIndex = 1, 5 do
    resetServer(1)
    env.nowMs = env.nowMs + 60000
    NBServer.onClientCommand(MODULE, "register", makePlayer("alice"),
        { lang = "EN", lseq = badSeqs[badIndex] })
    NBServer.processQueue()
    checkEqual(sentCommands[1].payload.lseq, nil,
        "不合法的序號必須當成舊版 client 沒送（index " .. tostring(badIndex) .. "）")
end

-- ---------------------------------------------------------------------------
-- P6／P7：enqueueJob 失敗（語系快取全空）必須寫 log，且不得把 langPending 清掉——
-- 清掉那次語系切換就永久遺失，server 端沒有任何機制會自己補推。
-- ---------------------------------------------------------------------------
resetServer(1)
serverState.languageCaches = {}
env.nowMs = env.nowMs + 60000
logLines = {}
NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 1 })
checkEqual(#serverState.queue, 0, "語系快取全空時排不進任何 job")
checkEqual(serverState.langPending.alice, true, "排入失敗時必須留著待推，供冷卻到期後補推")
check(logContains("enqueue failed"), "排入失敗必須留下 log")
check(logContains("username=alice"), "log 必須帶 username")

-- 節流是 per-player：一位玩家的失敗不得蓋掉其他人的紀錄（節流窗與 request 冷卻同寬，
-- 因此同一位玩家的重複失敗本來就被冷卻擋在前面，這裡驗的是「不同玩家各自記一筆」）。
logLines = {}
NBServer.onClientCommand(MODULE, "register", makePlayer("carol"), { lang = "EN", lseq = 1 })
check(logContains("username=carol"), "不同玩家的排入失敗必須各自留下紀錄")
checkEqual(serverState.langPending.carol, true, "第二位玩家的待推也要留著")

-- ---------------------------------------------------------------------------
-- P10：拒絕 register 的 log 對 client 可控的 lang 必須截長。
-- ---------------------------------------------------------------------------
resetServer(1)
env.nowMs = env.nowMs + 60000
logLines = {}
NBServer.onClientCommand(MODULE, "register", makePlayer("bob"),
    { lang = string.rep("Z", 5000) })
check(logContains("rejected register"), "非法語系必須寫拒絕 log")
local rejectLine = nil
local lineIndex
for lineIndex = 1, #logLines do
    if string.find(logLines[lineIndex], "rejected register", 1, true) then
        rejectLine = logLines[lineIndex]
    end
end
check(rejectLine ~= nil, "應找得到拒絕 log 那一行")
check(string.len(rejectLine) < 200, "拒絕 log 的長度必須有界（實際 "
    .. tostring(string.len(rejectLine or "")) .. "）")

-- ---------------------------------------------------------------------------
-- P1（receiver 端）：manifest 的 lseq 是信任邊界，範圍外一律當作舊版 server 沒送。
-- ---------------------------------------------------------------------------
-- NBClient 載入時已把自己的 applySnapshot 掛在 onSnapshot 上；先拆下來單獨驗收接收端，
-- 稍後測 client 完成判定時再接回去（不可自己另寫一份，那就不是在測出貨的那條路徑）。
local clientOnSnapshot = NBReader.onSnapshot
check(type(clientOnSnapshot) == "function", "NBClient 應已掛上 onSnapshot")
NBReader.onSnapshot = nil
NBReader.resetReceiver()
NBReader.receive(MODULE, "manifest", { v = 1, sid = "s1", files = {}, lang = "EN", lseq = 7 })
checkEqual(NBReader.getSnapshot().lseq, 7, "合法序號必須進快照")
NBReader.receive(MODULE, "manifest", { v = 2, sid = "s1", files = {}, lang = "EN", lseq = -1 })
checkEqual(NBReader.getSnapshot().lseq, nil, "負數序號必須丟棄")
NBReader.receive(MODULE, "manifest",
    { v = 3, sid = "s1", files = {}, lang = "EN", lseq = 1000001 })
checkEqual(NBReader.getSnapshot().lseq, nil, "超過上界的序號必須丟棄")
NBReader.receive(MODULE, "manifest", { v = 4, sid = "s1", files = {}, lang = "EN" })
checkEqual(NBReader.getSnapshot().lseq, nil, "舊版 server 沒送 lseq 時必須是 nil")

-- ---------------------------------------------------------------------------
-- 信任邊界：接收端的圖片上限 = min(伺服器宣告值, 客戶端硬天花板)。
-- MP 下 sandbox 是 server 推給 client 的，宣告值本身就是不可信輸入。這裡直接把
-- 出貨用的 accessor 換成「說謊的伺服器」再跑真正的 receive 路徑——只驗 accessor 的
-- 夾限不算數，那證明不了接收端沒有無條件相信它。
-- ---------------------------------------------------------------------------
do
    local realMaxImageCount = NBImage.maxImageCount
    local realMaxImageBytes = NBImage.maxImageBytes
    local manifestVersion = 100

    local function receiveImages(images)
        manifestVersion = manifestVersion + 1
        NBReader.resetReceiver()
        NBReader.receive(MODULE, "manifest",
            { v = manifestVersion, sid = "sImg", files = {}, lang = "EN", images = images })
        return NBReader.getImages()
    end

    local function imageList(count, bytes)
        local list = {}
        local imageIndex
        for imageIndex = 1, count do
            list[imageIndex] = {
                name = "i" .. tostring(imageIndex) .. ".png",
                h = "0f923099",
                n = 1,
                b = bytes,
            }
        end
        return list
    end

    -- 先確認誠實伺服器不受影響：天花板 == 沙盒上界，所以合法宣告值一律 no-op。
    NBImage.maxImageCount = function() return 200 end
    checkEqual(#receiveImages(imageList(200, 1024)), 200,
        "服主把張數調到沙盒上界時，接收端必須全收（天花板不得比沙盒上界低）")

    -- 說謊的伺服器：宣告 500 張。接收端必須用天花板 200，第 201 張就要整份拒絕。
    NBImage.maxImageCount = function() return 500 end
    checkEqual(#receiveImages(imageList(201, 1024)), 0,
        "宣告值超過客戶端天花板時，接收端必須用天花板（拿掉 min() 這條會紅）")
    checkEqual(#receiveImages(imageList(200, 1024)), 200,
        "天花板以內的張數仍必須收下")

    NBImage.maxImageCount = realMaxImageCount

    -- 單張大小同理：宣告 64MB，接收端仍只認 4096KB 天花板。
    NBImage.maxImageBytes = function() return 64 * 1024 * 1024 end
    checkEqual(#receiveImages(imageList(1, 4096 * 1024 + 1)), 0,
        "宣告值超過客戶端天花板時，超大單張必須被拒（拿掉 min() 這條會紅）")
    checkEqual(#receiveImages(imageList(1, 4096 * 1024)), 1,
        "剛好等於天花板的單張必須收下")

    NBImage.maxImageBytes = realMaxImageBytes

    -- 分塊數必須由**這一筆自己的 b** 推。client 是收齊 n 塊才比對長度，所以
    -- 「b 很小、n 很大」的宣告會在長度檢查之前先撐出 n * 6000 個字元的緩衝。
    -- 6000 = NBCore.CHUNK_UTF16_LIMIT；b=1024 -> encodedLength=1368 -> 恰好 1 塊。
    checkEqual(#receiveImages({ { name = "a.png", h = "0f923099", n = 2, b = 1024 } }), 0,
        "n 超過該筆 b 所需的分塊數必須整份拒絕（拿掉 n<=ceil(b) 這條會紅）")
    checkEqual(#receiveImages({ { name = "a.png", h = "0f923099", n = 1, b = 1024 } }), 1,
        "n 剛好等於所需分塊數必須收下")
    -- 0 bytes 的圖 producer 端仍會留一塊空的（flushChunks），n=1 必須合法。
    checkEqual(#receiveImages({ { name = "a.png", h = "0f923099", n = 1, b = 0 } }), 1,
        "0 位元組的圖 n=1 必須合法")
    -- 6000 * 3 = 18000 chars -> 需 13500 bytes（encodedLength(13500)=18000），恰好 3 塊。
    checkEqual(#receiveImages({ { name = "a.png", h = "0f923099", n = 3, b = 13500 } }), 1,
        "分塊數剛好整除時不得多算一塊")
    checkEqual(#receiveImages({ { name = "a.png", h = "0f923099", n = 4, b = 13500 } }), 0,
        "分塊數整除時多宣告一塊必須拒絕")

    -- 總量夾限：張數與單張大小各自合法，乘起來仍可以遠超總量天花板（200 * 4MB = 800MB），
    -- 那正是 client 要緩衝的量。producer 端本來就有 img-total 閘，所以誠實伺服器不受影響。
    local realMaxTotalBytes = NBImage.maxTotalBytes
    -- 單張上限一併放到沙盒合法上界，否則這幾筆會先被單張檢查擋掉、總量夾限根本沒跑到。
    NBImage.maxImageBytes = function() return 4096 * 1024 end
    NBImage.maxTotalBytes = function() return 4 * 1024 * 1024 end
    checkEqual(#receiveImages(imageList(4, 1024 * 1024)), 4,
        "總量剛好等於上限必須全收")
    checkEqual(#receiveImages(imageList(5, 1024 * 1024)), 0,
        "總量超過上限必須整份拒絕（拿掉總量夾限這條會紅）")
    -- 說謊的伺服器：宣告總量 512MB，接收端仍只認 MAX_TOTAL_KB 天花板（16MB）。
    NBImage.maxTotalBytes = function() return 512 * 1024 * 1024 end
    checkEqual(#receiveImages(imageList(5, 4 * 1024 * 1024)), 0,
        "宣告總量超過客戶端天花板時必須用天花板（16MB < 5 * 4MB）")
    checkEqual(#receiveImages(imageList(4, 4 * 1024 * 1024)), 4,
        "天花板以內的總量仍必須收下")
    NBImage.maxTotalBytes = realMaxTotalBytes
    NBImage.maxImageBytes = realMaxImageBytes

    NBReader.resetReceiver()
end

-- ---------------------------------------------------------------------------
-- P1（client 端，本輪最重要的一條）：EN -> JP -> EN 來回切換。
-- 語系值比對會被一份「剛好也是 EN」的舊快照誤判成切換完成，序號比對不會。
-- ---------------------------------------------------------------------------
local statusEvents = {}
Events[NBClient.LANGUAGE_STATUS_EVENT].Add(function(payload)
    statusEvents[#statusEvents + 1] = payload
end)
NBReader.onSnapshot = clientOnSnapshot

diskFiles = {}
fsWorking = true
env.nowMs = 3000000
clientState.languagePreference = "EN"
clientState.registerLanguage = "EN"
clientState.langSeq = 0
clientState.languageSwitchPending = false
clientState.languageSwitchSends = 0
clientState.languageSwitchExhausted = false
clientState.settingsPending = nil
clientState.lastRegisterAttemptMs = 0

local switchStatus = NBClient.setLanguagePreference("JP")
checkEqual(switchStatus, "sent", "第一次切換應送得出去")
checkEqual(clientState.langSeq, 1, "切換必須推進序號")

env.nowMs = env.nowMs + 1000
local backStatus, backWait = NBClient.setLanguagePreference("EN")
checkEqual(backStatus, "cooldown", "語系冷卻（3 秒）內切回去應被鏡像冷卻擋下")
check(backWait > 0, "冷卻應回報剩餘秒數")
checkEqual(clientState.langSeq, 2, "被冷卻擋下的切換一樣要推進序號")
checkEqual(clientState.registerLanguage, "EN", "registerLanguage 已樂觀寫成新值")

NBReader.resetReceiver()
NBReader.receive(MODULE, "manifest", { v = 1, sid = "s1", files = {}, lang = "EN", lseq = 0 })
checkEqual(clientState.languageSwitchMatched, false,
    "序號不符的舊快照不得被判為切換完成（語系值剛好相同是陷阱）")
checkEqual(clientState.languageSwitchPending, true, "誤判會讓 pending 被清掉、之後不再重試")

NBReader.receive(MODULE, "manifest", { v = 2, sid = "s1", files = {}, lang = "EN", lseq = 2 })
checkEqual(clientState.languageSwitchMatched, true, "序號相符才算切換完成")
checkEqual(clientState.languageSwitchPending, false, "切換完成後 pending 必須清掉")
checkEqual(clientState.languageSwitchSends, 0, "切換完成後送出計數必須歸零")

-- 舊版 server（manifest 沒有 lseq）必須沿用語系值比對，不可讓玩家卡住。
clientState.languageSwitchPending = true
clientState.registerLanguage = "EN"
NBReader.receive(MODULE, "manifest", { v = 3, sid = "s1", files = {}, lang = "EN" })
checkEqual(clientState.languageSwitchMatched, true, "舊版 server 應沿用語系值比對")
checkEqual(clientState.languageSwitchPending, false, "舊版 server 下切換仍要能完成")

clientState.languageSwitchPending = true
clientState.registerLanguage = "JP"
NBReader.receive(MODULE, "manifest", { v = 4, sid = "s1", files = {}, lang = "EN" })
checkEqual(clientState.languageSwitchMatched, false, "舊版 server 下語系不符仍不算完成")

-- 序號回繞後比對仍要正確
clientState.langSeq = 1000000
clientState.languagePreference = "EN"
clientState.registerLanguage = "EN"
clientState.languageSwitchPending = false
env.nowMs = env.nowMs + 60000
NBClient.setLanguagePreference("CH")
checkEqual(clientState.langSeq, 1, "序號到上界後必須回繞到 1")
NBReader.receive(MODULE, "manifest", { v = 5, sid = "s1", files = {}, lang = "CH", lseq = 1 })
checkEqual(clientState.languageSwitchMatched, true, "回繞後的序號比對仍須成立")

-- ---------------------------------------------------------------------------
-- R6：連續換語系不得洗版。「這份快照要不要靜音」與「pending 何時可以清掉」是兩件事：
-- 中途抵達的那份快照序號不符（不算切換完成），但它一樣把每份公告換成另一種語言、
-- hash 全變，照一般內容更新走就是每份公告一則 toast。
-- ---------------------------------------------------------------------------
diskFiles = {}
fsWorking = true
env.nowMs = env.nowMs + 60000
clientState.languagePreference = "EN"
clientState.registerLanguage = "EN"
clientState.langSeq = 0
clientState.languageSwitchPending = false
clientState.languageSwitchArmed = false
clientState.languageSwitchSilence = false
clientState.lastSnapshotLanguage = nil
clientState.settingsPending = nil
clientState.lastRegisterAttemptMs = 0

NBReader.resetReceiver()
NBReader.receive(MODULE, "manifest", { v = 1, sid = "s2", files = {}, lang = "EN", lseq = 0 })
checkEqual(NBClient.consumeLanguageSwitch(), false, "第一份快照沒有語系變化，不得靜音")

NBClient.setLanguagePreference("JP")
env.nowMs = env.nowMs + 2000
local secondStatus = NBClient.setLanguagePreference("CH")
checkEqual(secondStatus, "cooldown", "2 秒內的第二次切換應被鏡像冷卻擋下")
checkEqual(clientState.langSeq, 2, "兩次切換必須各推進一次序號")

NBReader.receive(MODULE, "manifest", { v = 2, sid = "s2", files = {}, lang = "JP", lseq = 1 })
checkEqual(clientState.languageSwitchMatched, false, "中途快照的序號不符，不得判為切換完成")
checkEqual(clientState.languageSwitchPending, true, "切換尚未完成，pending 必須留著")
checkEqual(NBClient.consumeLanguageSwitch(), true,
    "語系變了就必須靜音，不論它是不是玩家最後要求的那一個")

NBReader.receive(MODULE, "manifest", { v = 3, sid = "s2", files = {}, lang = "CH", lseq = 2 })
checkEqual(clientState.languageSwitchPending, false, "序號相符後 pending 必須清掉")
checkEqual(NBClient.consumeLanguageSwitch(), true, "切換完成的那份快照一樣要靜音")

NBReader.receive(MODULE, "manifest", { v = 4, sid = "s2", files = {}, lang = "CH", lseq = 2 })
checkEqual(NBClient.consumeLanguageSwitch(), false, "語系沒變的一般內容更新不得被靜音")

-- 舊版 server 不送 lang：沿用既有的 armed + matched 判斷，不可讓切換變成永遠有 toast
clientState.lastSnapshotLanguage = nil
clientState.languageSwitchArmed = true
clientState.languageSwitchPending = true
clientState.registerLanguage = "CH"
NBReader.receive(MODULE, "manifest", { v = 5, sid = "s2", files = {} })
checkEqual(NBClient.consumeLanguageSwitch(), true, "舊版 server 下切換完成的快照仍須靜音")

-- ---------------------------------------------------------------------------
-- P3／P4：settings.ini 落地失敗必須回報，而且「值沒變」的早退不可以吃掉重試路徑。
-- ---------------------------------------------------------------------------
diskFiles = {}
clientState.languagePreference = "EN"
clientState.settingsPending = nil
clientState.registerLanguage = "EN"
clientState.languageSwitchPending = false
env.nowMs = env.nowMs + 60000
statusEvents = {}
fsWorking = false
local saveStatus, saveWait, saved = NBClient.setLanguagePreference("CH")
checkEqual(saved, false, "引擎吞掉寫入錯誤時必須回報未保存（pcall 成功不等於落地）")
checkEqual(clientState.settingsPending, "CH", "失敗的偏好必須留著重試")
checkEqual(#statusEvents, 1, "落地失敗必須發出狀態事件")
checkEqual(statusEvents[1].kind, "save-failed", "事件種類錯誤")
checkEqual(statusEvents[1].preference, "CH", "事件必須帶偏好值")

-- 重試輪每 30 秒跑一次：同一個待寫入值不得每輪都重發事件與 log，
-- 否則面板端會每 30 秒彈一則 toast、log 也被灌爆（writeLog 到 10MB 是整檔截斷）。
statusEvents = {}
env.nowMs = env.nowMs + 60000
NBClient.setLanguagePreference("CH")
checkEqual(#statusEvents, 0, "同一個待寫入值重試失敗時不得重複發事件")
checkEqual(clientState.settingsPending, "CH", "重試失敗後待寫入值仍要留著")

fsWorking = true
statusEvents = {}
env.nowMs = env.nowMs + 60000
local retryStatus, retryWait, retrySaved = NBClient.setLanguagePreference("CH")
checkEqual(retrySaved, true, "值沒變也要能重試落地（早退不可以吃掉重試路徑）")
checkEqual(clientState.settingsPending, nil, "重試成功後不得留下待寫入")
checkEqual(#statusEvents, 1, "重試成功必須發出恢復事件")
checkEqual(statusEvents[1].kind, "save-recovered", "恢復事件種類錯誤")
checkEqual(diskFiles["NoticeBoard/settings.ini"], "lang=CH\n", "落地內容錯誤")

-- ---------------------------------------------------------------------------
-- P8：「沒檔案」「值壞掉」必須分得出來（壞值要留一行 log，不可靜默丟棄）。
-- ---------------------------------------------------------------------------
diskFiles["NoticeBoard/settings.ini"] = "lang=jp\n"
clientState.languagePreference = nil
logLines = {}
checkEqual(NBClient.getLanguagePreference(), "auto", "小寫 jp 不在白名單內，應視為 auto")
check(logContains("settings lang not recognized"), "無法辨識的值必須留下 log")
check(logContains("value=jp"), "log 必須帶原始值")

diskFiles = {}
clientState.languagePreference = nil
logLines = {}
checkEqual(NBClient.getLanguagePreference(), "auto", "沒有檔案時應是 auto")
check(not logContains("settings lang not recognized"), "沒有檔案不是錯誤，不得寫 log")

-- 超長的手改值進 log 前必須截長
diskFiles["NoticeBoard/settings.ini"] = "lang=" .. string.rep("Q", 5000) .. "\n"
clientState.languagePreference = nil
logLines = {}
NBClient.getLanguagePreference()
local settingsLine = nil
for lineIndex = 1, #logLines do
    if string.find(logLines[lineIndex], "settings lang not recognized", 1, true) then
        settingsLine = logLines[lineIndex]
    end
end
check(settingsLine ~= nil, "應找得到無法辨識值的 log")
check(string.len(settingsLine) < 200, "settings log 的長度必須有界（實際 "
    .. tostring(string.len(settingsLine or "")) .. "）")

-- ---------------------------------------------------------------------------
-- P5：換語系送出額度用盡時必須留下訊號（本檔唯一沒有退出提示的重試迴圈）。
-- ---------------------------------------------------------------------------
diskFiles = {}
clientState.languagePreference = "EN"
clientState.lastRegisterAttemptMs = 0
clientState.settingsPending = nil
-- registerOnTick 送出首次 register 後才會裝上 maintenanceOnTick（維護輪）。
fireEvent("OnTick")
check(NBClient._maintenanceInstalled == true, "首次 register 之後應裝上維護輪")

clientState.registerLanguage = "JP"
clientState.languageSwitchPending = true
clientState.languageSwitchSends = 0
clientState.languageSwitchExhausted = false
local tickIndex
for tickIndex = 1, 5 do
    env.nowMs = env.nowMs + 4000
    fireEvent("OnTick")
end
checkEqual(clientState.languageSwitchSends, 5, "額度是 5 次")
checkEqual(clientState.languageSwitchExhausted, false, "剛好用完的當下還不算已回報")

logLines = {}
statusEvents = {}
env.nowMs = env.nowMs + 11000
fireEvent("OnTick")
checkEqual(clientState.languageSwitchExhausted, true, "額度用盡必須標記")
check(logContains("language switch send limit reached"), "額度用盡必須留下 log")
checkEqual(#statusEvents, 1, "額度用盡必須發出狀態事件")
checkEqual(statusEvents[1].kind, "switch-exhausted", "事件種類錯誤")
checkEqual(statusEvents[1].language, "JP", "事件必須帶要求的語系")

logLines = {}
statusEvents = {}
env.nowMs = env.nowMs + 11000
fireEvent("OnTick")
checkEqual(#statusEvents, 0, "額度用盡只回報一次，不得每輪重複")

-- 玩家再選一次同一個語系＝重新開始計次（上限用盡後唯一的自救路徑）
env.nowMs = env.nowMs + 11000
clientState.languagePreference = "JP"
NBClient.setLanguagePreference("JP")
checkEqual(clientState.languageSwitchExhausted, false, "再選一次必須解除已回報旗標")
checkEqual(clientState.languageSwitchSends, 1, "再選一次必須重新開始計次")

-- 面板要接的狀態介面
local languageStatus = NBClient.getLanguageStatus()
checkEqual(languageStatus.requested, "JP", "getLanguageStatus.requested 錯誤")
checkEqual(languageStatus.switchPending, true, "getLanguageStatus.switchPending 錯誤")
checkEqual(languageStatus.switchExhausted, false, "getLanguageStatus.switchExhausted 錯誤")
checkEqual(languageStatus.saveFailed, false, "getLanguageStatus.saveFailed 錯誤")

-- ---------------------------------------------------------------------------
-- 對抗式審查：序號不符**且**畫面上的語系不是玩家要求的那一個 -> 這次切換確實沒生效，
-- 必須重新掛上 pending。少了這條，一旦封包亂序讓 pending 先被清掉就再也沒有自癒路徑：
-- pumpLanguageSwitch 只看 pending，選單重選同一語系又會被 unchanged 早退吞掉。
-- （server->client 的 Lua 命令走 RELIABLE 而非 RELIABLE_ORDERED，不保證順序。）
-- ---------------------------------------------------------------------------
diskFiles = {}
fsWorking = true
env.nowMs = env.nowMs + 60000
clientState.languagePreference = "EN"
clientState.registerLanguage = "EN"
clientState.langSeq = 0
clientState.languageSwitchPending = false
clientState.languageSwitchExhausted = false
clientState.settingsPending = nil
clientState.lastRegisterAttemptMs = 0
clientState.lastSnapshotLanguage = nil

NBReader.resetReceiver()
NBClient.setLanguagePreference("CH")
NBReader.receive(MODULE, "manifest", { v = 1, sid = "s3", files = {}, lang = "CH", lseq = 1 })
checkEqual(clientState.languageSwitchPending, false, "序號相符時切換完成、pending 清掉")

NBReader.receive(MODULE, "manifest", { v = 2, sid = "s3", files = {}, lang = "JP", lseq = 0 })
checkEqual(clientState.languageSwitchPending, true,
    "序號不符且畫面語系不是玩家要的 -> 必須重新掛上 pending，否則沒有任何自癒路徑")

clientState.languageSwitchPending = false
NBReader.receive(MODULE, "manifest", { v = 3, sid = "s3", files = {}, lang = "CH", lseq = 0 })
checkEqual(clientState.languageSwitchPending, false,
    "序號不符但語系已經對了（同語系的舊快照）不算分岔，不得重送")

-- ---------------------------------------------------------------------------
-- 對抗式審查：resync 推的就是註冊語系的整包內容＝langPending 想推的那一份。
-- 不清掉的話 pumpLanguagePending 會在下一個冷卻視窗把同一份內容整包再送一次
-- （一個語系上限 512KB ≒ 90 則訊息），client 端 pending 是空的會全部丟棄——純浪費，
-- 而且會佔掉該玩家約 12 個 tick 的推送額度，正好打在每 tick 限流想保護的公平性上。
-- ---------------------------------------------------------------------------
resetServer(1)
env.nowMs = env.nowMs + 60000
serverState.registrations.alice = "EN"
serverState.online.alice = makePlayer("alice")
serverState.langPending.alice = true
NBServer.onClientCommand(MODULE, "resync", makePlayer("alice"), { lang = "EN", lseq = 3 })
checkEqual(#serverState.queue, 1, "resync 應排入一個推送 job")
checkEqual(serverState.langPending.alice, nil, "resync 排入成功後必須把待推清掉")

resetServer(1)
serverState.languageCaches = {}
env.nowMs = env.nowMs + 60000
serverState.registrations.alice = "EN"
serverState.online.alice = makePlayer("alice")
serverState.langPending.alice = true
NBServer.onClientCommand(MODULE, "resync", makePlayer("alice"), { lang = "EN", lseq = 3 })
checkEqual(serverState.langPending.alice, true,
    "resync 排入失敗時待推必須留著（清掉這次語系切換就靜默遺失）")

-- ---------------------------------------------------------------------------
-- 語系切換的獨立冷卻桶（LANGUAGE_COOLDOWN_MS=3s）與「同一份請求不重排」。
-- 這一段釘住的是 client/server 兩端的**對稱性**：
--   * 換語系不吃 register/resync 那個 10 秒桶（進場註冊後馬上換語系不該被擋）；
--   * 帶 lseq>=1 的重送同樣走語系桶——落回 10 秒桶會被靜默吞掉，還會白燒 client 的
--     送出額度並讓 registerRepeats 把正常切換的玩家記成灌送；
--   * 首次註冊（lseq=0，或舊版 client 不送）仍吃 10 秒桶，灌送防護不放寬；
--   * 同語系、同序號的 job 還在推送中時不得重排（enqueueJob 是覆寫，會從 manifest 重頭，
--     多人佇列下大份內容永遠推不完）。
-- ---------------------------------------------------------------------------
;(function()
    resetServer(1)
    env.nowMs = env.nowMs + 60000
    serverState.languageCaches.JP = makeCache(1)
    serverState.languageCaches.JP.language = "JP"
    serverState.availableLanguages = { "EN", "JP" }
    NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 0 })
    checkEqual(#serverState.queue, 1, "首次註冊要排入推送")
    NBServer.processQueue()
    checkEqual(serverState.jobs.alice, nil, "小份內容一個 tick 就推完，job 必須移除")

    -- 1 秒後換語系：register 桶還在冷卻（10 秒），語系桶是另一個 -> 必須立刻排得進去
    env.nowMs = env.nowMs + 1000
    NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "JP", lseq = 1 })
    check(serverState.jobs.alice ~= nil, "換語系不吃 register 的 10 秒桶")
    checkEqual(serverState.jobs.alice.language, "JP", "排入的必須是新語系")
    checkEqual(serverState.langPending.alice, nil, "排入成功就沒有待推")

    -- 首次註冊仍受 10 秒桶限制：另一位玩家在 1 秒內重送同語系（lseq=0）必須被擋下
    resetServer(1)
    env.nowMs = env.nowMs + 60000
    NBServer.onClientCommand(MODULE, "register", makePlayer("bob"), { lang = "EN", lseq = 0 })
    NBServer.processQueue()
    env.nowMs = env.nowMs + 1000
    NBServer.onClientCommand(MODULE, "register", makePlayer("bob"), { lang = "EN", lseq = 0 })
    checkEqual(serverState.jobs.bob, nil,
        "lseq=0 的重送仍吃 register 的 10 秒桶（灌送防護不得因為語系桶而放寬）")

    -- 推到一半的 job 不得被同一份請求的重送重設
    resetServer(8)
    env.nowMs = env.nowMs + 60000
    NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 3 })
    NBServer.processQueue()
    check(serverState.jobs.alice ~= nil, "8 個分塊一個 tick（8 則額度）推不完")
    local progressChunk = serverState.jobs.alice.chunkIndex
    check(progressChunk > 1 and serverState.jobs.alice.manifestSent == true,
        "第一個 tick 應已送出 manifest 與前幾個分塊")
    env.nowMs = env.nowMs + 4000
    NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "EN", lseq = 3 })
    checkEqual(serverState.jobs.alice.chunkIndex, progressChunk,
        "同語系同序號的重送不得重設推送進度（enqueueJob 是覆寫，會從 manifest 重頭）")
    checkEqual(serverState.jobs.alice.manifestSent, true, "重送不得讓 manifest 再送一次")
    checkEqual(serverState.langPending.alice, nil, "已在推送中就不該留下待推")

    -- 玩家真的又換了一次語系（新序號）-> 必須重排，舊 job 作廢
    NBServer.onClientCommand(MODULE, "register", makePlayer("alice"), { lang = "JP", lseq = 4 })
    checkEqual(serverState.jobs.alice.language, "JP", "新序號＋新語系必須重排成新語系的 job")
    checkEqual(serverState.jobs.alice.chunkIndex, 1, "重排的 job 從頭開始（內容真的換了）")

    -- client 端的對稱面：server 已受理（manifest 帶回本次序號且語系相符）之後不得再送 register。
    -- 這是上面那條 server 防線的另一半——少了它，client 每 3 秒就會敲一次同一份請求。
    diskFiles = {}
    fsWorking = true
    env.nowMs = env.nowMs + 60000
    clientState.registerLanguage = "JP"
    clientState.langSeq = 7
    clientState.languageSwitchPending = true
    clientState.languageSwitchSends = 0
    clientState.languageSwitchExhausted = false
    clientState.lastLanguageAttemptMs = 0
    clientState.settingsPending = nil
    local halfManifest = { { id = "10_a.md", title = "A", n = 2, h = "0f923099" } }
    NBReader.resetReceiver()
    NBReader.receive(MODULE, "manifest",
        { v = 9, sid = "s4", files = halfManifest, lang = "JP", lseq = 7 })
    env.nowMs = env.nowMs + 4000
    fireEvent("OnTick")
    checkEqual(clientState.languageSwitchSends, 0,
        "manifest 帶回本次序號＋語系相符 = server 已受理，不得再送（會讓推送從頭重來）")

    -- 序號相同但語系不符（resync 在 server 已有註冊時忽略 args.lang，卻回帶新序號）：
    -- 那不是這次切換的結果，必須繼續重送。
    NBReader.resetReceiver()
    NBReader.receive(MODULE, "manifest",
        { v = 10, sid = "s4", files = halfManifest, lang = "EN", lseq = 7 })
    env.nowMs = env.nowMs + 4000
    fireEvent("OnTick")
    checkEqual(clientState.languageSwitchSends, 1,
        "序號相同但語系不符不算受理（resync 會回帶新序號的舊語系內容），必須繼續重送")

    -- 跨檔常數關係：client 的鏡像必須與 server 的語系桶同值。分岔的後果全是靜默的——
    -- client 值較小就會送出被 server 丟棄的請求，較大就白等一段 server 早已放行的時間。
    local nbClientSource = readRepoFile("media/lua/client/NoticeBoard/NBClient.lua")
    local nbServerSource = readRepoFile("media/lua/server/NoticeBoard/NBServer.lua")
    local clientLangCooldown = tonumber(string.match(nbClientSource or "",
        "local LANGUAGE_COOLDOWN_MS = (%d+)"))
    local serverLangCooldown = tonumber(string.match(nbServerSource or "",
        "local LANGUAGE_COOLDOWN_MS = (%d+)"))
    check(clientLangCooldown ~= nil, "找不到 client 的 LANGUAGE_COOLDOWN_MS")
    check(serverLangCooldown ~= nil, "找不到 server 的 LANGUAGE_COOLDOWN_MS")
    checkEqual(clientLangCooldown, serverLangCooldown,
        "client 的語系冷卻鏡像必須與 server 的語系桶同值")
end)()

-- ---------------------------------------------------------------------------
-- 對抗式審查：SP 完全沒有維護輪。registerOnTick 的 SP 分支只把自己 Remove 掉就 return，
-- 於是 pumpSettingsRetry 從未被安裝——而 SP 沒有 server 幫忙記語系，settings.ini 就是唯一的
-- 記憶體：寫檔失敗（磁碟滿／防毒鎖檔）後玩家只吃到一則 toast，下次進場靜默回到舊語系。
-- 重新載入 NBClient 才拿得到新的 registerOnTick（它是 local closure，上一輪已把自己拆掉）；
-- NBClient.state 是 `state or newState()`，重載不會清掉狀態。
-- ---------------------------------------------------------------------------
env.isClient = false
clientCommands = {}
package.loaded["NoticeBoard/NBClient"] = nil
NBClient._eventsInstalled = nil
NBClient._maintenanceInstalled = nil
require "NoticeBoard/NBClient"
fireEvent("OnTick")
check(NBClient._maintenanceInstalled == true, "SP 也必須裝上維護輪")
checkEqual(#clientCommands, 0, "SP 不得送出任何網路命令")

diskFiles = {}
fsWorking = false
clientState.languagePreference = "EN"
clientState.registerLanguage = "EN"
clientState.settingsPending = nil
clientState.lastSettingsRetryMs = 0
env.nowMs = env.nowMs + 60000
local spStatus, spWait, spSaved = NBClient.setLanguagePreference("JP")
checkEqual(spSaved, false, "SP 下引擎吞掉寫入錯誤時一樣要回報未保存")
checkEqual(clientState.settingsPending, "JP", "失敗的偏好必須留著重試")

fsWorking = true
env.nowMs = env.nowMs + 31000
fireEvent("OnTick")
checkEqual(clientState.settingsPending, nil, "SP 的維護輪必須自己把偏好補寫進 settings.ini")
checkEqual(diskFiles["NoticeBoard/settings.ini"], "lang=JP\n", "SP 補寫的內容錯誤")
env.isClient = true

-- ---------------------------------------------------------------------------
-- 原地覆蓋偵測：平常輪詢（forceAll=false）時，對已經編碼過的檔名開檔問一次
-- available()（不讀內容）與 entry.b 比對，不同就丟掉 entry 讓既有的重排迴圈接手。
-- 實跑真正出貨的 scanImages，不另寫一份判定邏輯。
-- ---------------------------------------------------------------------------
local function totalImageOpens()
    local count = 0
    local _, value
    for _, value in pairs(imageOpens) do
        count = count + value
    end
    return count
end

local function setImageDir(sizes)
    imageSizes = sizes
    local names = {}
    local name
    for name in pairs(sizes) do
        names[#names + 1] = name
    end
    NBCore.sortSafe(names)
    scannedNames["NoticeBoard/images"] = names
end

-- probeBytes 預設等於 bytes（正常情況：讀到的位元組數＝開檔時 available() 報的大小）。
-- 想模擬串流提早 EOF 的 short-read 就把兩者拆開。
local function putImageEntry(name, bytes, probeBytes)
    serverState.imageEntries[name] = {
        name = name,
        h = "0f923099",
        n = 1,
        b = bytes,
        pb = probeBytes or bytes,
        chunks = { "x" },
    }
end

local function resetImageScan(sizes)
    serverState.imageEntries = {}
    serverState.imageQueue = {}
    serverState.imageJob = nil
    serverState.imageTotalBytes = 0
    serverState.imageIssues = {}
    serverState.imageIssueSignature = nil
    serverState.imageIssuesDirty = false
    serverState.imageDirty = false
    serverState.imageProbeCursor = nil
    imageProbeFails = {}
    imageShortReads = {}
    imageOpens = {}
    imageCloses = 0
    serverState.readIntUsable = nil
    setImageDir(sizes)
end

local function imageIssueOf(name)
    local index
    for index = 1, #serverState.imageIssues do
        if serverState.imageIssues[index].name == name then
            return serverState.imageIssues[index]
        end
    end
    return nil
end

-- 大小變了 -> 丟掉 entry 並重排（這條就是「服主換圖不必按重新載入」的全部）
resetImageScan({ ["logo.png"] = 200 })
putImageEntry("logo.png", 100)
serverState.imageTotalBytes = 100
NBServer.scanImages(false)
checkEqual(serverState.imageEntries["logo.png"], nil, "檔案大小變了必須丟掉舊 entry")
checkEqual(#serverState.imageQueue, 1, "丟掉 entry 之後必須重新排隊")
checkEqual(serverState.imageQueue[1], "logo.png", "重新排隊的必須是被覆蓋的那個檔名")
checkEqual(serverState.imageTotalBytes, 0, "移除 entry 後 imageTotalBytes 必須重算")
checkEqual(imageOpens["logo.png"], 1, "同一輪對同一個檔名只能開一次檔")
checkEqual(serverState.imageDirty, true, "清單有變必須標記 dirty，否則 manifest 不會重建")

-- 大小相同 -> 什麼都不動（誤判會造成整片重編碼）
resetImageScan({ ["logo.png"] = 100 })
putImageEntry("logo.png", 100)
serverState.imageTotalBytes = 100
NBServer.scanImages(false)
check(serverState.imageEntries["logo.png"] ~= nil, "大小相同不得丟掉 entry")
checkEqual(#serverState.imageQueue, 0, "大小相同不得重新排隊")
checkEqual(serverState.imageTotalBytes, 100, "entry 留著時總量必須維持")
checkEqual(serverState.imageDirty, false, "沒有變化不得標記 dirty")

-- 正在編碼中的檔名：連開檔都不做，更不能砍掉推到一半的 job
resetImageScan({ ["logo.png"] = 999 })
putImageEntry("logo.png", 100)
serverState.imageJob = { name = "logo.png" }
NBServer.scanImages(false)
check(serverState.imageEntries["logo.png"] ~= nil, "正在編碼中的檔名不得被大小比對動到")
checkEqual(imageOpens["logo.png"], nil, "正在編碼中的檔名連開檔都不該做")
checkEqual(#serverState.imageQueue, 0, "正在編碼中的檔名不得被重複排隊")
serverState.imageJob = nil

-- 編碼進行中時**整輪**不探測，不只是同名那一個：getFileInput 把串流存在 static 欄位
-- （LuaManager.java:2723），檔案存在但開檔失敗時 :6873-6881 只 log 不 return，照樣回
-- DataInputStream(上一個成功開啟的串流) —— available() 會回 job 檔案的大小（比錯），
-- 而 close() 會直接關掉編碼中的串流。不開檔就沒有這個別名窗口。
resetImageScan({ ["big.png"] = 5000, ["a.png"] = 999 })
putImageEntry("a.png", 100)
serverState.imageTotalBytes = 100
serverState.imageJob = { name = "big.png" }
NBServer.scanImages(false)
check(serverState.imageEntries["a.png"] ~= nil, "job 在飛時不得因大小比對丟掉別的 entry")
checkEqual(totalImageOpens(), 0, "job 在飛時整輪不得開任何檔")
checkEqual(#serverState.imageQueue, 0, "job 在飛時不得重排")
serverState.imageJob = nil

-- short-read（串流比 available() 宣告的早結束）：entry.b < entry.pb。比對必須用 pb，
-- 拿 b 去比會永遠不相等 -> 該圖每輪重編一次、每輪重推 manifest 給全體玩家。
resetImageScan({ ["logo.png"] = 5000 })
putImageEntry("logo.png", 4996, 5000)
serverState.imageTotalBytes = 4996
NBServer.scanImages(false)
check(serverState.imageEntries["logo.png"] ~= nil, "short-read 的 entry 不得被丟掉重編")
checkEqual(#serverState.imageQueue, 0, "short-read 不得造成無限重排")
checkEqual(serverState.imageDirty, false, "short-read 不得標記 dirty，否則每輪重推 manifest")

-- 同一件事的端對端版：實跑一次真正的編碼 job（available() 說 12、串流讀到第 8 個就 EOF），
-- 釘住 entry.pb 來自開檔時的 available() 而不是實際讀到的位元組數。少了這個，下一輪掃描
-- 會判定「大小變了」而重排，於是每輪重編一次、永遠停不下來。
resetImageScan({ ["short.png"] = 12 })
imageShortReads["short.png"] = 8
NBServer.scanImages(false)
checkEqual(#serverState.imageQueue, 1, "沒有 entry 的新圖必須排隊")
do
    local pumpGuard
    for pumpGuard = 1, 20 do
        if serverState.imageEntries["short.png"] then
            break
        end
        NBServer.pumpImageEncode()
    end
    local shortEntry = serverState.imageEntries["short.png"]
    check(shortEntry ~= nil, "短讀的 job 一樣要收尾成 entry")
    checkEqual(shortEntry and shortEntry.b, 8, "entry.b 必須是實際讀到的位元組數")
    checkEqual(shortEntry and shortEntry.pb, 12, "entry.pb 必須是開檔時 available() 報的大小")
end
serverState.imageDirty = false
NBServer.scanImages(false)
check(serverState.imageEntries["short.png"] ~= nil, "下一輪不得把短讀的 entry 丟掉")
checkEqual(#serverState.imageQueue, 0, "下一輪不得重排（重排＝每輪重編的無限迴圈）")

-- 已在佇列裡的檔名同理
resetImageScan({ ["logo.png"] = 999 })
putImageEntry("logo.png", 100)
serverState.imageQueue = { "logo.png" }
NBServer.scanImages(false)
check(serverState.imageEntries["logo.png"] ~= nil, "已排隊的檔名不得被大小比對動到")
checkEqual(imageOpens["logo.png"], nil, "已排隊的檔名連開檔都不該做")
checkEqual(#serverState.imageQueue, 1, "已排隊的檔名不得被排第二次")

-- 開檔失敗：保留既有 entry，只記 issue（否則暫時性 IO 錯誤＝重編碼風暴＋玩家的圖消失）
resetImageScan({ ["logo.png"] = 200 })
putImageEntry("logo.png", 100)
serverState.imageTotalBytes = 100
imageProbeFails["logo.png"] = true
NBServer.scanImages(false)
check(serverState.imageEntries["logo.png"] ~= nil, "開檔失敗不得丟掉既有 entry")
checkEqual(#serverState.imageQueue, 0, "開檔失敗不得重新排隊")
checkEqual(serverState.imageTotalBytes, 100, "entry 留著，總量不得歸零")
checkEqual(imageCloses, 1, "問大小失敗一樣要關檔，否則長跑會洩漏 fd")
local failIssue = imageIssueOf("logo.png")
check(failIssue ~= nil, "開檔失敗必須留下 issue")
checkEqual(failIssue.kind, "img-read", "開檔失敗的 issue 種類必須是 img-read")
local firstFailDetail = failIssue.detail

-- 每輪重掃都會產生同一則 issue：kind/name/detail 三者逐輪相同 -> updateImageIssueLog
-- 的簽章相同 -> 只寫一次 log，不會每個輪詢週期洗一則。
NBServer.scanImages(false)
local repeatIssue = imageIssueOf("logo.png")
check(repeatIssue ~= nil, "第二輪一樣要留下 issue")
checkEqual(repeatIssue.detail, firstFailDetail, "issue 內容必須逐輪相同，否則 log 每輪洗版")
checkEqual(#serverState.imageIssues, 1, "同一輪不得對同一個檔名記兩則 issue")

-- 列舉得到、開檔卻回 nil（列舉與開檔之間被刪掉）：一樣不得丟掉 entry
resetImageScan({})
scannedNames["NoticeBoard/images"] = { "logo.png" }
putImageEntry("logo.png", 100)
NBServer.scanImages(false)
check(serverState.imageEntries["logo.png"] ~= nil, "引擎回 nil（問不到大小）一樣不得丟掉 entry")

-- 每輪開檔次數的上界＝MAX_IMAGE_COUNT，且同一個檔名不得開兩次
local manySizes = {}
local probeIndex
for probeIndex = 1, NBImage.MAX_IMAGE_COUNT do
    manySizes["p" .. tostring(probeIndex) .. ".png"] = 100
end
resetImageScan(manySizes)
for probeIndex = 1, NBImage.MAX_IMAGE_COUNT do
    putImageEntry("p" .. tostring(probeIndex) .. ".png", 100)
end
NBServer.scanImages(false)
checkEqual(totalImageOpens(), NBImage.MAX_IMAGE_COUNT, "每輪開檔次數的上界＝MAX_IMAGE_COUNT")
checkEqual(imageCloses, NBImage.MAX_IMAGE_COUNT, "每次開檔都必須關檔，否則長跑會洩漏 fd")
for probeIndex = 1, NBImage.MAX_IMAGE_COUNT do
    checkEqual(imageOpens["p" .. tostring(probeIndex) .. ".png"], 1,
        "每個檔名一輪只能開一次檔（p" .. tostring(probeIndex) .. ".png）")
end
checkEqual(#serverState.imageQueue, 0, "全部大小相同，不得有任何重排")

-- ---------------------------------------------------------------------------
-- 分批輪替探測：每輪開檔次數有**固定**上限（20，與 MaxImageCount 無關），游標在
-- 排序過的檔名陣列上輪替，下一輪從上次停的位置接著跑。200 張一輪掃完實測單 tick 38ms
-- 會掉幀，這裡守住的就是那個上界，以及「輪替」本身（固定取前 N 個會讓後面的永遠掃不到）。
-- 主 chunk 的區域變數逼近 Lua 的 200 上限，故整段用立即呼叫的函式包起來。
-- ---------------------------------------------------------------------------
;(function()
    local PROBE_LIMIT = 20

    -- 補零讓字典序＝數字序，游標推進的位置才看得懂（游標本身也是靠字串大小比較走的）。
    local function imageName(number)
        if number < 10 then
            return "f0" .. tostring(number) .. ".png"
        end
        return "f" .. tostring(number) .. ".png"
    end

    local function makeDir(count)
        local sizes = {}
        local fillIndex
        for fillIndex = 1, count do
            sizes[imageName(fillIndex)] = 100
        end
        return sizes
    end

    local index

    -- 60 張、上限 20 -> 一輪只能探測 20 個，三輪剛好走完一圈。
    SandboxVars = { MinidoracatNB = { MaxImageCount = 60 } }
    resetImageScan(makeDir(60))
    for index = 1, 60 do
        putImageEntry(imageName(index), 100)
    end
    serverState.imageTotalBytes = 6000

    NBServer.scanImages(false)
    checkEqual(totalImageOpens(), PROBE_LIMIT, "單輪開檔次數不得超過固定上限 20")
    checkEqual(imageOpens[imageName(1)], 1, "第一輪必須從排序最前面的檔名開始")
    checkEqual(imageOpens[imageName(21)], nil, "第一輪不得探測到上限以外的檔名")

    NBServer.scanImages(false)
    checkEqual(totalImageOpens(), PROBE_LIMIT * 2, "第二輪一樣不得超過上限")
    checkEqual(imageOpens[imageName(21)], 1, "第二輪必須從上一輪停的位置接著探測")
    checkEqual(imageOpens[imageName(1)], 1, "第二輪不得回頭重探已經探過的檔名")

    NBServer.scanImages(false)
    checkEqual(totalImageOpens(), 60, "三輪剛好走完一圈")
    for index = 1, 60 do
        checkEqual(imageOpens[imageName(index)], 1,
            "一圈之內每個檔名都必須被探測到、且只探一次（" .. imageName(index) .. "）")
    end
    checkEqual(#serverState.imageQueue, 0, "大小都沒變，不得有任何重排")

    -- 游標跑過尾端要繞回開頭，否則第四輪起就再也不探測任何檔案。
    NBServer.scanImages(false)
    checkEqual(imageOpens[imageName(1)], 2, "游標走到尾端後必須繞回開頭")

    -- ---------------------------------------------------------------------
    -- 檔案數在兩輪之間變動：刪掉游標**前面**的一個檔名（後面所有檔名的名次整體前移一格），
    -- 第二輪仍必須從游標之後接著跑。游標若存索引，這裡就會整整跳過一個還沒探測到的檔名。
    -- ---------------------------------------------------------------------
    resetImageScan(makeDir(30))
    for index = 1, 30 do
        putImageEntry(imageName(index), 100)
    end
    NBServer.scanImages(false)
    checkEqual(totalImageOpens(), PROBE_LIMIT, "第一輪一樣只探 20 個")

    local shrunk = makeDir(30)
    shrunk[imageName(5)] = nil
    setImageDir(shrunk)
    NBServer.scanImages(false)
    for index = 21, 30 do
        checkEqual(imageOpens[imageName(index)], 1,
            "游標前面的檔案被刪掉，不得讓後面還沒探測的檔名被跳過（"
                .. imageName(index) .. "）")
    end
    checkEqual(serverState.imageEntries[imageName(5)], nil, "已刪除的檔名一樣要移除 entry")

    -- ---------------------------------------------------------------------
    -- forceAll（admin「重新載入」）路徑完全不變：無條件全清全排、不開任何檔比大小，
    -- 也不受每輪 20 個的上限限制，更不得動到游標。
    -- ---------------------------------------------------------------------
    resetImageScan(makeDir(30))
    for index = 1, 30 do
        putImageEntry(imageName(index), 100)
    end
    serverState.imageTotalBytes = 3000
    -- 游標停在一個「已經不在清單裡」的檔名上（服主 reload 前剛把它刪掉）。用清單內的檔名
    -- 驗不出東西：整輪走一圈剛好會停回同一個名字，動到游標與沒動到看起來一模一樣。
    serverState.imageProbeCursor = imageName(31)
    NBServer.scanImages(true)
    checkEqual(totalImageOpens(), 0, "forceAll 不得為了比大小開任何檔")
    checkEqual(#serverState.imageQueue, 30, "forceAll 必須全部重排，不受每輪 20 個的上限限制")
    checkEqual(serverState.imageProbeCursor, imageName(31), "forceAll 不得動到游標")
    checkEqual(serverState.imageTotalBytes, 0, "forceAll 之後總量歸零")

    -- ---------------------------------------------------------------------
    -- 服主把 MaxImageCount 從 30 調小到 5：游標指的檔名已經不在夾限後的清單裡。
    -- 索引游標會直接指到界外並漏掃，檔名游標必須繞回開頭把剩下 5 張全部探測到。
    -- ---------------------------------------------------------------------
    SandboxVars = { MinidoracatNB = { MaxImageCount = 5 } }
    resetImageScan(makeDir(30))
    for index = 1, 5 do
        putImageEntry(imageName(index), 100)
    end
    serverState.imageTotalBytes = 500
    serverState.imageProbeCursor = imageName(20)
    NBServer.scanImages(false)
    checkEqual(totalImageOpens(), 5, "上限調小後游標不得越界，夾限後的 5 張必須全部探測到")
    for index = 1, 5 do
        checkEqual(imageOpens[imageName(index)], 1,
            "夾限後的每個檔名都要被探測到（" .. imageName(index) .. "）")
    end
    checkEqual(#serverState.imageQueue, 0, "大小都沒變，調小上限不得造成重排")
    SandboxVars = nil
end)()

-- ---------------------------------------------------------------------------
-- 抽佇列也要限開檔次數。永久被拒的圖（img-oversize 等）拿不到 entry -> 每輪都被重新排隊，
-- 而 startNextImageJob 原本會在同一個 tick 把整條佇列抽乾：探測迴圈省下來的 IO 會在同一個
-- 影格內原樣還回去（200 張全被拒＝單 tick 開 200 個檔）。這裡守的是那個上界，以及
-- 「佇列沒抽乾就不得結算 issue log」（否則會逐 tick 寫一行越來越長的 image issues）。
-- 主 chunk 的區域變數逼近 200 上限，故整段用立即呼叫的函式包起來。
-- ---------------------------------------------------------------------------
;(function()
    local OPEN_LIMIT = 20

    local function imageName(number)
        if number < 10 then
            return "f0" .. tostring(number) .. ".png"
        end
        return "f" .. tostring(number) .. ".png"
    end

    local index

    -- 60 張全部超過 MaxImageKB（預設 512KB）-> 每一張都被永久拒絕、永遠拿不到 entry。
    SandboxVars = { MinidoracatNB = { MaxImageCount = 60 } }
    local sizes = {}
    for index = 1, 60 do
        sizes[imageName(index)] = 600 * 1024
    end
    resetImageScan(sizes)

    NBServer.scanImages(false)
    checkEqual(totalImageOpens(), 0, "沒有 entry 的檔名不消耗探測額度")
    checkEqual(#serverState.imageQueue, 60, "沒有 entry 的檔名全部排隊")

    NBServer.pumpImageEncode()
    checkEqual(totalImageOpens(), OPEN_LIMIT, "單次抽佇列的開檔次數不得超過固定上限 20")
    checkEqual(#serverState.imageQueue, 40, "抽不完的必須留在佇列裡，下一個 tick 接著抽")
    checkEqual(serverState.imageIssuesDirty, true, "佇列還沒抽乾就不得結算 issue log")
    check(serverState.imageIssueSignature == nil, "佇列還沒抽乾不得寫半套 issue log")

    NBServer.pumpImageEncode()
    NBServer.pumpImageEncode()
    checkEqual(#serverState.imageQueue, 0, "三次泵剛好抽乾 60 個")
    checkEqual(totalImageOpens(), 60, "抽乾一輪總共只開 60 次，不得重複開檔")
    checkEqual(imageCloses, 60, "每次開檔都必須關檔，否則長跑會洩漏 fd")
    checkEqual(#serverState.imageIssues, 60, "被拒的圖每一張都要留下 issue")
    check(serverState.imageIssueSignature ~= nil, "抽乾之後才結算 issue log")
    checkEqual(serverState.imageIssuesDirty, false, "結算過就不得重複寫")

    -- ---------------------------------------------------------------------
    -- 探測問不到大小的檔名：issue 必須**每輪都在**。分批之後這個壞檔每 ceil(張數/20) 輪
    -- 才輪到一次，若只在探測到的那一輪記 issue，簽章會在「有 img-read」與「空」之間翻臉
    -- -> 服主會在故障持續中看到 log 印出「image issues cleared」然後又復發。
    -- ---------------------------------------------------------------------
    local ok = {}
    for index = 1, 60 do
        ok[imageName(index)] = 100
    end
    resetImageScan(ok)
    for index = 1, 60 do
        putImageEntry(imageName(index), 100)
    end
    serverState.imageTotalBytes = 6000
    imageProbeFails[imageName(50)] = true

    NBServer.scanImages(false)              -- 第 1 輪：f01..f20
    check(imageIssueOf(imageName(50)) == nil, "還沒輪到探測的檔名不得憑空生出 issue")
    NBServer.scanImages(false)              -- 第 2 輪：f21..f40
    NBServer.scanImages(false)              -- 第 3 輪：f41..f60，這輪才踩到 f50
    local badIssue = imageIssueOf(imageName(50))
    check(badIssue ~= nil, "輪到探測、開檔失敗必須留下 issue")
    checkEqual(badIssue and badIssue.kind, "img-read", "開檔失敗的 issue 種類必須是 img-read")
    check(serverState.imageEntries[imageName(50)] ~= nil, "開檔失敗不得丟掉既有 entry")
    local badDetail = badIssue and badIssue.detail

    NBServer.scanImages(false)              -- 第 4 輪：繞回 f01..f20，沒輪到 f50
    checkEqual(imageOpens[imageName(50)], 1, "第四輪確實沒有再探測 f50（本測試的前提）")
    local carried = imageIssueOf(imageName(50))
    check(carried ~= nil, "沒輪到探測的壞檔必須沿用上一次的 img-read，否則 log 會逐圈翻臉")
    checkEqual(carried and carried.detail, badDetail, "沿用的 issue 內容必須與探測當下相同")
    checkEqual(#serverState.imageIssues, 1, "沿用不得變成每輪多記一則")

    -- 檔案恢復可讀 -> 下一次輪到探測就必須停止回報，否則 issue 會永遠黏著。
    imageProbeFails[imageName(50)] = nil
    NBServer.scanImages(false)              -- 第 5 輪：f21..f40
    check(imageIssueOf(imageName(50)) ~= nil, "還沒重探到就得繼續回報")
    NBServer.scanImages(false)              -- 第 6 輪：f41..f60，重探 f50 成功
    check(imageIssueOf(imageName(50)) == nil, "重探成功之後必須停止回報")
    checkEqual(#serverState.imageQueue, 0, "大小都沒變，全程不得有任何重排")
    SandboxVars = nil
end)()

-- ---------------------------------------------------------------------------
-- 產生端（服主政策）：張數與總量兩個沙盒選項確實接到出貨路徑上。
-- 主 chunk 的區域變數逼近 200 上限，故用立即呼叫的函式包起來（見一致性測試的說明）。
-- ---------------------------------------------------------------------------
;(function()
    local fourImages = { ["a.png"] = 10, ["b.png"] = 20, ["c.png"] = 30, ["d.png"] = 40 }

    -- 回歸：服主什麼都不設 -> 預設 20 張，四張全收，行為與可調之前完全相同。
    resetImageScan(fourImages)
    NBServer.scanImages(false)
    checkEqual(#serverState.imageQueue, 4, "未設定沙盒選項時四張圖必須全部排隊")
    checkEqual(imageIssueOf("d.png"), nil, "未設定沙盒選項時不得有 img-count")

    -- 服主把張數調成 2：依檔名排序保留前兩張，其餘記 img-count。
    SandboxVars = { MinidoracatNB = { MaxImageCount = 2 } }
    resetImageScan(fourImages)
    NBServer.scanImages(false)
    checkEqual(#serverState.imageQueue, 2, "MaxImageCount=2 時只能排隊兩張")
    checkEqual(serverState.imageQueue[1], "a.png", "保留的必須是檔名排序在前的")
    checkEqual(serverState.imageQueue[2], "b.png", "保留的必須是檔名排序在前的")
    local dropped = imageIssueOf("c.png")
    check(dropped ~= nil, "超出張數上限的圖必須留下 issue")
    checkEqual(dropped and dropped.kind, "img-count", "超出張數上限的 issue 種類")
    -- detail 帶生效中的上限，服主才知道這是自己設的值、可以調（不是 MOD 寫死的牆）。
    checkEqual(dropped and dropped.detail, "max2", "img-count 的 detail 必須帶生效中的上限")
    SandboxVars = nil

    -- 總量：預設 4MB。剩 500 bytes 額度時，1000 bytes 的圖必須被擋下並記 img-total。
    resetImageScan({ ["big.png"] = 1000 })
    serverState.imageQueue = { "big.png" }
    serverState.imageTotalBytes = 4194304 - 500
    NBServer.pumpImageEncode()
    local overTotal = imageIssueOf("big.png")
    check(overTotal ~= nil, "超過總量上限的圖必須留下 issue")
    checkEqual(overTotal and overTotal.kind, "img-total", "超過總量上限的 issue 種類")
    check(overTotal and string.find(overTotal.detail or "", "max4194304", 1, true) ~= nil,
        "img-total 的 detail 必須帶生效中的總量上限")

    -- 服主把總量調到 8MB：同一張圖就進得去了（證明夾限吃的是沙盒值而非寫死常數）。
    SandboxVars = { MinidoracatNB = { MaxImageTotalKB = 8192 } }
    resetImageScan({ ["big.png"] = 1000 })
    serverState.imageQueue = { "big.png" }
    serverState.imageTotalBytes = 4194304 - 500
    NBServer.pumpImageEncode()
    checkEqual(imageIssueOf("big.png"), nil, "調高總量後同一張圖不得再被 img-total 擋下")
    check(serverState.imageJob ~= nil or serverState.imageEntries["big.png"] ~= nil,
        "調高總量後這張圖必須真的開始編碼")
    SandboxVars = nil
    serverState.imageJob = nil
end)()

-- forceAll=true 的路徑行為完全不變：全清全排，而且不做任何大小比對
resetImageScan({ ["a.png"] = 10, ["b.png"] = 20 })
putImageEntry("a.png", 10)
putImageEntry("b.png", 20)
serverState.imageTotalBytes = 30
NBServer.scanImages(true)
checkEqual(serverState.imageEntries["a.png"], nil, "forceAll 一律清掉既有 entry")
checkEqual(serverState.imageEntries["b.png"], nil, "forceAll 一律清掉既有 entry")
checkEqual(#serverState.imageQueue, 2, "forceAll 之後兩張都要重排")
checkEqual(serverState.imageTotalBytes, 0, "forceAll 之後總量歸零")
checkEqual(totalImageOpens(), 0, "forceAll 路徑不比大小，不得多開檔")

-- 檔案消失仍照舊移除，而且不為了比大小去開一個不存在的檔
resetImageScan({ ["a.png"] = 10 })
putImageEntry("a.png", 10)
putImageEntry("gone.png", 50)
serverState.imageTotalBytes = 60
NBServer.scanImages(false)
checkEqual(serverState.imageEntries["gone.png"], nil, "檔案不在列舉裡就要移除 entry")
checkEqual(serverState.imageTotalBytes, 10, "移除後總量必須只剩還在的那張")
checkEqual(imageOpens["gone.png"], nil, "已不存在的檔名不得為了比大小去開檔")

-- ---------------------------------------------------------------------------
-- images/ 的多語系說明檔：掃描器必須靜默略過它（只有「.png 但不合法」才報
-- img-invalid-name），且已存在時絕不覆蓋。
-- ---------------------------------------------------------------------------
resetImageScan({ ["logo.png"] = 100 })
scannedNames["NoticeBoard/images"] = { "00_README.txt", "bad name.png", "logo.png", "notes.md" }
NBServer.scanImages(false)
checkEqual(#serverState.imageQueue, 1, "只有合法的 .png 會被排隊")
checkEqual(serverState.imageQueue[1], "logo.png", "排隊的必須是唯一那張合法圖")
checkEqual(imageIssueOf("00_README.txt"), nil, "說明檔（.txt）必須被靜默略過")
checkEqual(imageIssueOf("notes.md"), nil, "非 .png 一律靜默略過")
local badNameIssue = imageIssueOf("bad name.png")
check(badNameIssue ~= nil, "不合法的 .png 必須留下 issue")
checkEqual(badNameIssue.kind, "img-invalid-name", "不合法的 .png 才報 img-invalid-name")
checkEqual(NBImage.isValidName("00_README.txt"), false, "說明檔本身不得被當成合法圖片名")

-- 探測本身拋錯（分不清「不存在」與「讀不到」）：什麼都不寫，才不會蓋掉服主的筆記。
diskFiles = {}
readerFails["NoticeBoard/images/00_README.txt"] = true
checkEqual(NBServer.ensureImagesReadme(), false, "探測失敗時不得寫入說明檔")
checkEqual(diskFiles["NoticeBoard/images/00_README.txt"], nil, "探測失敗時不得留下任何檔案")
readerFails["NoticeBoard/images/00_README.txt"] = nil

diskFiles = {}
checkEqual(NBServer.ensureImagesReadme(), true, "說明檔不存在時必須寫一份")
local readmeWritten = diskFiles["NoticeBoard/images/00_README.txt"]
check(type(readmeWritten) == "string", "說明檔必須真的寫進 images/")
check(string.len(readmeWritten or "") > 2000, "說明檔內容不得是空殼")
check(contains(readmeWritten, "[LIMITS]"), "說明檔必須帶 LIMITS 區塊")
check(contains(readmeWritten, "[EN]") and contains(readmeWritten, "[CH]")
    and contains(readmeWritten, "[CN]") and contains(readmeWritten, "[JP]"),
    "說明檔必須含四語段落")

diskFiles["NoticeBoard/images/00_README.txt"] = "my own notes\n"
checkEqual(NBServer.ensureImagesReadme(), false, "說明檔已存在時不得再寫")
checkEqual(diskFiles["NoticeBoard/images/00_README.txt"], "my own notes\n",
    "絕不覆蓋服主自己加的筆記")

-- ---------------------------------------------------------------------------
-- 圖片上限的數字有**三個來源**：NBImage 的常數（唯一的執行期真相）、
-- images/README.txt 的 [LIMITS] 區塊（服主打開資料夾就看到的）、
-- sandbox-options.txt 的 min/max/default（沒有它服主根本調不到）。
-- 三方任一方單獨改動都必須紅——尤其 sandbox-options.txt：它不被任何 Lua 讀取，
-- 改錯了只會在遊戲裡靜默失效（min/max/default 缺一該選項會被引擎丟棄）。
--
-- 用立即呼叫的函式而不是 do...end：主 chunk 的區域變數已逼近 Lua 的 200 個上限，
-- do 區塊裡的變數在區塊內仍計入主 chunk 的 active 數（lparser.c 的 nactvar），
-- 只有另開一個函式作用域才真的不佔額度。
-- ---------------------------------------------------------------------------
;(function()
    local readmeAsset = readRepoFile("media/NoticeBoardImages/README.txt")
    check(type(readmeAsset) == "string", "找不到 images 說明檔資源")

    local function readmeNumber(key)
        local value = tonumber(string.match(readmeAsset, key .. "%s*=%s*(%d+)"))
        check(value ~= nil, "說明檔的 LIMITS 區塊缺少 " .. key)
        return value
    end

    checkEqual(readmeNumber("max%-image%-kb%-default") * 1024, NBImage.MAX_IMAGE_BYTES,
        "說明檔的單張預設上限與 NBImage.MAX_IMAGE_BYTES 不一致")
    checkEqual(readmeNumber("max%-image%-kb%-min"), NBImage.MIN_IMAGE_KB,
        "說明檔的 MaxImageKB 下限與 NBImage.MIN_IMAGE_KB 不一致")
    checkEqual(readmeNumber("max%-image%-kb%-max"), NBImage.MAX_IMAGE_KB,
        "說明檔的 MaxImageKB 上限與 NBImage.MAX_IMAGE_KB 不一致")
    checkEqual(readmeNumber("max%-image%-count%-default"), NBImage.MAX_IMAGE_COUNT,
        "說明檔的張數預設值與 NBImage.MAX_IMAGE_COUNT 不一致")
    checkEqual(readmeNumber("max%-image%-count%-min"), NBImage.MIN_IMAGE_COUNT,
        "說明檔的 MaxImageCount 下限與 NBImage.MIN_IMAGE_COUNT 不一致")
    checkEqual(readmeNumber("max%-image%-count%-max"), NBImage.MAX_IMAGE_COUNT_LIMIT,
        "說明檔的 MaxImageCount 上限與 NBImage.MAX_IMAGE_COUNT_LIMIT 不一致")
    checkEqual(readmeNumber("max%-total%-kb%-default") * 1024, NBImage.MAX_TOTAL_BYTES,
        "說明檔的總量預設值與 NBImage.MAX_TOTAL_BYTES 不一致")
    checkEqual(readmeNumber("max%-total%-kb%-min"), NBImage.MIN_TOTAL_KB,
        "說明檔的 MaxImageTotalKB 下限與 NBImage.MIN_TOTAL_KB 不一致")
    checkEqual(readmeNumber("max%-total%-kb%-max"), NBImage.MAX_TOTAL_KB,
        "說明檔的 MaxImageTotalKB 上限與 NBImage.MAX_TOTAL_KB 不一致")
    -- 檔名長度原本硬寫在四語段落裡（「64 characters／64 字元／64 字符／64 文字」），
    -- 改 NBImage.MAX_NAME_UTF16 會讓四份說明同時靜默變錯——正是 [LIMITS] 要防的事。
    checkEqual(readmeNumber("max%-name%-chars"), NBImage.MAX_NAME_UTF16,
        "說明檔的檔名長度上限與 NBImage.MAX_NAME_UTF16 不一致")
    -- [LIMITS] 的不變式本身：每個 key 都必須在**四個語系段落各自**出現過。
    -- 只在單一語系把 key 換回裸數字（原本 CN 的「64 字符」就是這樣漏掉的）會紅。
    local limitKeys = {
        "max-image-kb-default", "max-image-kb-min", "max-image-kb-max",
        "max-image-count-default", "max-image-count-min", "max-image-count-max",
        "max-total-kb-default", "max-total-kb-min", "max-total-kb-max",
        "max-name-chars",
    }
    local sectionTags = { "EN", "CH", "CN", "JP" }
    local bounds = {}
    local tagIndex
    for tagIndex = 1, #sectionTags do
        bounds[tagIndex] = string.find(readmeAsset, "%[" .. sectionTags[tagIndex] .. "%]%s")
        check(bounds[tagIndex] ~= nil, "說明檔缺少段落 " .. sectionTags[tagIndex])
    end
    bounds[#sectionTags + 1] = string.len(readmeAsset) + 1
    for tagIndex = 1, #sectionTags do
        local section = string.sub(readmeAsset,
            bounds[tagIndex], bounds[tagIndex + 1] - 1)
        local keyIndex
        for keyIndex = 1, #limitKeys do
            check(string.find(section, limitKeys[keyIndex], 1, true) ~= nil,
                sectionTags[tagIndex] .. " 段落沒有引用 [LIMITS] 的 "
                    .. limitKeys[keyIndex] .. "（硬寫數字會讓它靜默變錯）")
        end
    end

    local sandboxAsset = readRepoFile("media/sandbox-options.txt")
    check(type(sandboxAsset) == "string", "找不到 sandbox-options.txt")

    -- 只取這個 option 區塊（到下一個 } 為止），否則會抓到別的選項的 min/max。
    local function sandboxNumber(optionName, field)
        local block = string.match(sandboxAsset,
            "option%s+MinidoracatNB%." .. optionName .. "%s*(%b{})")
        check(block ~= nil, "sandbox-options.txt 缺少選項 " .. optionName)
        -- page 缺失會讓選項在沙盒 UI 完全不顯示，SandboxVars 讀不到值而靜默退回預設。
        check(string.match(block, "page%s*=%s*MinidoracatNB%s*,") ~= nil,
            optionName .. " 缺少 page = MinidoracatNB")
        local value = tonumber(string.match(block, field .. "%s*=%s*(%d+)%s*,"))
        check(value ~= nil, optionName .. " 缺少 " .. field .. "（三值缺一該選項會被引擎丟棄）")
        return value
    end

    checkEqual(sandboxNumber("MaxImageKB", "min"), NBImage.MIN_IMAGE_KB,
        "sandbox-options 的 MaxImageKB min 與 NBImage.MIN_IMAGE_KB 不一致")
    checkEqual(sandboxNumber("MaxImageKB", "max"), NBImage.MAX_IMAGE_KB,
        "sandbox-options 的 MaxImageKB max 與 NBImage.MAX_IMAGE_KB 不一致")
    checkEqual(sandboxNumber("MaxImageKB", "default") * 1024, NBImage.MAX_IMAGE_BYTES,
        "sandbox-options 的 MaxImageKB default 與 NBImage.MAX_IMAGE_BYTES 不一致")

    checkEqual(sandboxNumber("MaxImageCount", "min"), NBImage.MIN_IMAGE_COUNT,
        "sandbox-options 的 MaxImageCount min 與 NBImage.MIN_IMAGE_COUNT 不一致")
    checkEqual(sandboxNumber("MaxImageCount", "max"), NBImage.MAX_IMAGE_COUNT_LIMIT,
        "sandbox-options 的 MaxImageCount max 與 NBImage.MAX_IMAGE_COUNT_LIMIT 不一致")
    checkEqual(sandboxNumber("MaxImageCount", "default"), NBImage.MAX_IMAGE_COUNT,
        "sandbox-options 的 MaxImageCount default 與 NBImage.MAX_IMAGE_COUNT 不一致")

    checkEqual(sandboxNumber("MaxImageTotalKB", "min"), NBImage.MIN_TOTAL_KB,
        "sandbox-options 的 MaxImageTotalKB min 與 NBImage.MIN_TOTAL_KB 不一致")
    checkEqual(sandboxNumber("MaxImageTotalKB", "max"), NBImage.MAX_TOTAL_KB,
        "sandbox-options 的 MaxImageTotalKB max 與 NBImage.MAX_TOTAL_KB 不一致")
    checkEqual(sandboxNumber("MaxImageTotalKB", "default") * 1024, NBImage.MAX_TOTAL_BYTES,
        "sandbox-options 的 MaxImageTotalKB default 與 NBImage.MAX_TOTAL_BYTES 不一致")

    -- DefaultLanguage 的 enum：沙盒只交「第幾個」給 Lua，所以索引→代碼的對應散在三處
    -- （NBCore.LANG_ORDER／本檔的 numValues+default／四語的 _optionN），任一處單獨改動
    -- 都會讓服主在 UI 上選到 A、伺服器卻用 B，而且完全靜默。
    checkEqual(sandboxNumber("DefaultLanguage", "numValues"), #NBCore.LANG_ORDER,
        "sandbox-options 的 DefaultLanguage numValues 與 NBCore.LANG_ORDER 長度不一致")
    checkEqual(NBCore.LANG_ORDER[sandboxNumber("DefaultLanguage", "default")], "EN",
        "sandbox-options 的 DefaultLanguage default 沒有指向 EN")

    -- LANG_ORDER 與 LANGS 必須是同一組語系（漏一個＝那個語系永遠選不到；多一個＝選到會被
    -- languageByIndex 判為不合法而靜默退回 EN）。
    local orderIndex, orderCount = nil, 0
    for orderIndex = 1, #NBCore.LANG_ORDER do
        check(rawget(NBCore.LANGS, NBCore.LANG_ORDER[orderIndex]) == true,
            "LANG_ORDER 的 " .. NBCore.LANG_ORDER[orderIndex] .. " 不在 LANGS 白名單內")
    end
    local langKey
    for langKey in pairs(NBCore.LANGS) do
        orderCount = orderCount + 1
    end
    checkEqual(orderCount, #NBCore.LANG_ORDER, "LANGS 與 LANG_ORDER 的語系數量不一致")

    -- 四語的 _optionN 必須逐項等於 LANG_ORDER[N]：顯示的就是代碼本身（＝目錄名），
    -- 錯位的話服主選「CH」實際上會拿到別的語系。
    local langFiles = { "EN", "CH", "CN", "JP" }
    local langFileIndex
    for langFileIndex = 1, #langFiles do
        local translateAsset = readRepoFile(
            "media/lua/shared/Translate/" .. langFiles[langFileIndex] .. "/Sandbox.json")
        check(type(translateAsset) == "string",
            "找不到 " .. langFiles[langFileIndex] .. "/Sandbox.json")
        for orderIndex = 1, #NBCore.LANG_ORDER do
            local key = "\"Sandbox_MinidoracatNB_DefaultLanguage_option"
                .. tostring(orderIndex) .. "\"%s*:%s*\"([^\"]*)\""
            checkEqual(string.match(translateAsset, key), NBCore.LANG_ORDER[orderIndex],
                langFiles[langFileIndex] .. " 的 _option" .. tostring(orderIndex)
                    .. " 與 LANG_ORDER 不一致")
        end
    end

    -- languageByIndex 的信任邊界：越界／非整數／非數字一律 nil（呼叫端才決定 fallback）。
    checkEqual(NBCore.languageByIndex(8), "EN", "索引 8 應該是 EN")
    checkEqual(NBCore.languageByIndex(1), NBCore.LANG_ORDER[1], "索引 1 應該是第一個語系")
    checkEqual(NBCore.languageByIndex(#NBCore.LANG_ORDER),
        NBCore.LANG_ORDER[#NBCore.LANG_ORDER], "最後一個索引要取得到")
    checkEqual(NBCore.languageByIndex(0), nil, "索引 0 不合法")
    checkEqual(NBCore.languageByIndex(#NBCore.LANG_ORDER + 1), nil, "越界索引不合法")
    checkEqual(NBCore.languageByIndex(8.5), nil, "非整數索引不合法")
    checkEqual(NBCore.languageByIndex("8"), nil, "字串不合法（呼叫端要自己 tonumber）")
    checkEqual(NBCore.languageByIndex(nil), nil, "nil 不合法")
end)()

-- ---------------------------------------------------------------------------
-- 圖片快取：檔名的命名空間（安全）、LRU 淘汰、寫入時間窗
--
-- 實跑真正出貨的 NBImageCache，不另寫一份邏輯副本。三件事光讀碼保證不了：
--   1. 跨伺服器的快取毒化——攻擊者做一張同長度、base64 的 DJB2 同值的 PNG 餵給玩家，
--      玩家之後連上正牌伺服器時就會拿到攻擊者的圖。DJB2 是線性 hash，而 Kahlua 沒有
--      位元運算，加寬 hash 一樣可解，所以只能靠命名空間隔離。
--   2. 淘汰必須分批、且不得動到正在用的圖。
--   3. 寫入額度用盡後**要能恢復**（舊版是整場遊戲不恢復）。
--
-- 同樣用立即呼叫的函式包起來（主 chunk 的 local 已逼近 200 上限，見上一區塊註解）。
-- ---------------------------------------------------------------------------
;(function()
    -- 快取的 PNG／標記檔走 getFileOutput／getFileInput（只有位元組數有意義）；
    -- 索引檔是文字，走既有的 getFileWriter／getFileReader（diskFiles）。
    local cacheBytes = {}

    function getMyDocumentFolder()
        return "C:/Users/Player/Zomboid"
    end

    local serverAddress = "10.0.0.7"
    function getServerIP()
        return serverAddress
    end

    function getServerPort()
        return "16261"
    end

    -- 被鎖住（防毒／OneDrive 同步／看圖程式開著）的路徑：getFileOutput 開檔失敗時
    -- **不回 nil**，而是回 DataOutputStream(上一個成功開啟的 static outStream)
    -- （LuaManager.java:5833-5840）——拿得到 writer、close() 也不拋錯，檔案卻原封不動。
    local lockedPaths = {}

    -- getFileOutput 一開檔就截斷（new FileOutputStream，LuaManager.java:5833）。
    function getFileOutput(path)
        if lockedPaths[path] then
            return {
                writeBytes = function() end,
                write = function() end,
                close = function() end,
            }
        end
        cacheBytes[path] = 0
        return {
            writeBytes = function(_, text)
                cacheBytes[path] = cacheBytes[path] + string.len(text)
            end,
            write = function()
                cacheBytes[path] = cacheBytes[path] + 1
            end,
            close = function() end,
        }
    end

    local previousGetFileInput = getFileInput
    function getFileInput(path)
        local size = cacheBytes[path]
        if size ~= nil then
            return {
                available = function() return size end,
                close = function() end,
            }
        end
        if string.find(path, "NoticeBoard/cache/", 1, true) == 1 then
            return nil
        end
        return previousGetFileInput(path)
    end

    local CACHE_PREFIX = "NoticeBoard/cache/"
    local CACHE_MODULE = MOD_LUA .. "client/NoticeBoard/NBImageCache.lua"
    local Cache = require "NoticeBoard/NBImageCache"
    local receiver = NBReader.getReceiverState()

    -- 重設＝丟掉 state 後重跑模組本體（newState 是 local，這樣才不會與它分岔）。
    -- _eventsInstalled 已為 true，不會重複掛 OnTick。
    local function resetCache()
        Cache.state = nil
        dofile(CACHE_MODULE)
        cacheBytes = {}
        scannedNames["NoticeBoard/cache"] = {}
        diskFiles[CACHE_PREFIX .. "index.txt"] = nil
    end

    local function seedCache(stem, bytes)
        cacheBytes[CACHE_PREFIX .. stem .. ".png"] = bytes
        cacheBytes[CACHE_PREFIX .. stem .. ".ok"] = 8
    end

    local function relistCache()
        local names = {}
        local path
        for path in pairs(cacheBytes) do
            local base = string.match(path, "^NoticeBoard/cache/(.+)$")
            if base then
                names[#names + 1] = base
            end
        end
        NBCore.sortSafe(names)
        scannedNames["NoticeBoard/cache"] = names
    end

    local function setManifest(images)
        local parts = {}
        local index
        for index = 1, #images do
            parts[index] = string.lower(images[index].name) .. ":" .. images[index].h
        end
        receiver.images = images
        receiver.imagesSignature = table.concat(parts, "|")
    end

    local function tick(count)
        local index
        for index = 1, count do
            Cache.onTick()
        end
    end

    -- onTick 整輪包在 pcall 裡（正確：一個壞 tick 不該弄死整個 MOD），代價是任何執行期
    -- 錯誤都會**靜默**讓整個快取停擺，症狀只是「圖永遠不出現」，沒有任何斷言天生擋得住。
    -- 所以每次清 log 之前、以及整段結束時都收一次網。
    local function clearLog()
        check(not logContains("image cache tick failed"),
            "圖片快取的 onTick 不得拋錯（錯誤會被 pcall 吞掉，快取就此靜默停擺）")
        logLines = {}
    end

    local HASH_A = "0f923099"
    local STEM_A = "10_46_0_46_0_46_7_95_16261_" .. HASH_A
    local function logoManifest()
        setManifest({ { name = "logo.png", h = HASH_A, n = 1, b = 90 } })
    end

    -- (1) 同一台伺服器寫下的快取照樣命中，路徑帶命名空間前綴
    resetCache()
    seedCache(STEM_A, 90)
    relistCache()
    logoManifest()
    tick(4)
    check(Cache.isReady(HASH_A), "同一台伺服器寫下的快取必須命中")
    checkEqual(
        Cache.pathForHash(HASH_A),
        "C:/Users/Player/Zomboid/Lua/NoticeBoard/cache/" .. STEM_A .. ".png",
        "快取路徑必須是 <連線位址>_<hash>.png"
    )

    -- (2) 安全回歸：另一台伺服器留下的「同 hash 同大小」檔案不得被採用。
    -- 這正是 DJB2 碰撞毒化的落地點——沒有命名空間時這裡會是 ready。
    serverAddress = "10.0.0.8"
    Cache.state = nil
    dofile(CACHE_MODULE)
    logoManifest()
    tick(4)
    check(not Cache.isReady(HASH_A),
        "別台伺服器寫下的同 hash 同大小快取不得被採用（跨伺服器毒化）")
    -- (2b) 同一個遊戲程序內離線再連別台（Lua 狀態不會重置）：命名空間必須跟著換，
    -- 而且上一台的 ready 旗標一律作廢——ready 是「檔案驗過了」，檔案卻在別的命名空間下。
    serverAddress = "10.0.0.7"
    resetCache()
    seedCache(STEM_A, 90)
    relistCache()
    logoManifest()
    tick(4)
    check(Cache.isReady(HASH_A), "先在第一台伺服器上讓這張圖成為 ready")
    serverAddress = "10.0.0.9"
    Cache.onTick()
    check(not Cache.isReady(HASH_A),
        "換伺服器後上一台的 ready 旗標必須作廢（否則面板會指向不存在的檔案）")
    tick(4)
    check(not Cache.isReady(HASH_A),
        "重驗之後仍不得命中：新伺服器的命名空間底下沒有這個檔")
    serverAddress = "10.0.0.7"

    -- (2c) SP 與 MP 之間切換也是換命名空間。作廢的比較點必須是 **token** 不是位址：
    -- SP 那條分支根本沒有位址，舊版讓它直接 return，於是 MP -> SP 換掉了前綴卻不觸發
    -- serverChanged（ready 等 per-server 判斷整份留著），而且 serverAddress 停在上一台，
    -- SP -> 原本那台 MP 時比較不成立、token 就永遠卡在 "sp"——兩台伺服器各走一次
    -- MP -> SP -> MP，就會同時落進 "sp" 這個命名空間，隔離全滅、退回修正前的跨伺服器毒化。
    resetCache()
    seedCache(STEM_A, 90)
    relistCache()
    logoManifest()
    tick(4)
    check(Cache.isReady(HASH_A), "先在 MP 上讓這張圖成為 ready（前置條件）")
    env.isClient = false
    Cache.onTick()
    checkEqual(Cache.getState().serverToken, "sp", "SP 的命名空間是固定字串 sp")
    check(not Cache.isReady(HASH_A),
        "MP -> SP 一樣是換命名空間，上一台的 ready 必須作廢")
    env.isClient = true
    tick(4)
    checkEqual(Cache.pathForHash(HASH_A),
        "C:/Users/Player/Zomboid/Lua/NoticeBoard/cache/" .. STEM_A .. ".png",
        "回到原本那台 MP 時命名空間必須跟著回來，不得卡在 sp")

    -- (3) **消毒必須單射**。這是整個命名空間隔離真正站得住的那一條：不同來源只要映射到
    -- 同一個 token 就共用同一個檔名，隔離對那一對來源等於不存在。舊版把每個非 [a-z0-9]
    -- 字元一律塌縮成 "_"，於是 pz.example.com 與 pz-example.com（兩個各自可註冊、可解析
    -- 的名稱）拿到同一個前綴——毒化只要多註冊一個「消毒後同形」的域名就整條復活。
    -- 這裡直接驗「同一組 (hash, 位元組數) 在同形域名底下不得被採用」，而不是比字串：
    -- 換一種消毒法只要仍然單射，這條就照樣綠。
    local dottedStem = "pz_46_example_46_com_95_16261_" .. HASH_A
    serverAddress = "pz.example.com"
    resetCache()
    seedCache(dottedStem, 90)
    relistCache()
    logoManifest()
    tick(4)
    check(Cache.isReady(HASH_A), "自己寫下的快取在同一個域名底下必須命中（前置條件）")

    serverAddress = "pz-example.com"
    resetCache()
    seedCache(dottedStem, 90)
    relistCache()
    logoManifest()
    tick(4)
    check(not Cache.isReady(HASH_A),
        "消毒後同形的另一個域名不得共用快取檔名（單射；塌縮式消毒會在這裡紅）")

    -- (3b) 位址會直接進檔名，而檔名會進 RichText 的 <IMAGE:>。命名空間必須消毒成
    -- [a-z0-9_]，否則逗號／角括號會讓 tokenizer 把整段吃掉（ISRichTextPanel.lua:459-486）。
    -- scanCacheName 的 ^([a-z0-9_]+)%.png$ 與 loadLruIndex 的樣式也都依賴這個字元集。
    serverAddress = "A,B<C>D"
    resetCache()
    local dirtyStem = "a_44_b_60_c_62_d_95_16261_" .. HASH_A
    seedCache(dirtyStem, 90)
    relistCache()
    logoManifest()
    tick(4)
    checkEqual(
        Cache.pathForHash(HASH_A),
        "C:/Users/Player/Zomboid/Lua/NoticeBoard/cache/" .. dirtyStem .. ".png",
        "位址裡的標點必須轉義成 _<字碼>_，不得原樣進 RichText 路徑"
    )
    check(string.match(dirtyStem, "^[a-z0-9_]+$") ~= nil,
        "轉義後的檔名主幹只能含 [a-z0-9_]（掃描與索引的樣式都依賴這件事）")

    -- (3c) 完整形 IPv6（39 字元）+ port 是最長的合法位址。舊版在 40 字元就截斷並補上
    -- 整串的 DJB2，也就是**每一台 IPv6 伺服器**的隔離都落在一個線性、可解方程的 hash 上。
    -- 轉義後是 69 字元，必須完整保留、不得有任何 hash 參與。
    serverAddress = "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
    resetCache()
    local ipv6Stem = "2001_58_0db8_58_85a3_58_0000_58_0000_58_8a2e_58_0370_58_7334_95_16261_"
        .. HASH_A
    seedCache(ipv6Stem, 90)
    relistCache()
    logoManifest()
    tick(4)
    checkEqual(
        Cache.pathForHash(HASH_A),
        "C:/Users/Player/Zomboid/Lua/NoticeBoard/cache/" .. ipv6Stem .. ".png",
        "完整形 IPv6 必須完整轉義保留，不得截斷後補 hash（DJB2 可解，等於沒有隔離）"
    )

    -- (3d) 長到無法安全命名空間化時**失敗關閉**：不截斷（截斷就不再單射），整條快取停用，
    -- 公告退回替代文字。這是唯一不必犧牲單射的降級方式。
    serverAddress = string.rep("a.", 60) .. "x"
    resetCache()
    clearLog()
    logoManifest()
    tick(4)
    -- 直接釘住性質本身：token 是 nil，所以 cacheStem 組不出任何檔名——**沒有一條路徑**
    -- 能在這個位址底下命中或寫入。截斷式的降級會在這裡拿到一個字串而變紅。
    checkEqual(Cache.getState().serverToken, nil,
        "位址長到無法安全轉義時不得湊出 token（有 token 就有檔名，就會有碰撞）")
    checkEqual(Cache.pathForHash(HASH_A), nil, "沒有 token 就不該算得出快取路徑")
    checkEqual(next(cacheBytes), nil, "停用期間一個檔都不該碰")
    check(logContains("too long to namespace safely"),
        "整條快取停用必須留下 log（否則症狀只是『圖永遠不出現』，服主查不到原因）")

    serverAddress = "10.0.0.7"
    resetCache()

    -- (4) 升級路徑：舊格式 <hash>.png（沒有伺服器前綴）不得採用，並回收其空間
    resetCache()
    seedCache(HASH_A, 90)
    relistCache()
    logoManifest()
    tick(6)
    check(not Cache.isReady(HASH_A), "舊格式（無前綴）的快取來源不可考，不得採用")
    checkEqual(cacheBytes[CACHE_PREFIX .. HASH_A .. ".png"], 0,
        "舊格式快取必須截成 0 把空間還給玩家")
    checkEqual(cacheBytes[CACHE_PREFIX .. HASH_A .. ".ok"], 0,
        "舊格式的完成標記必須一起失效")

    -- (4b) 淘汰／回收留下的是 **0 bytes 的目錄項**（PZ 沒有刪檔 API），不是消失的檔案。
    -- 所以「檔案存在」永遠不足以當成有效——有效性必須看內容長度：圖檔位元組數相符
    -- **且**標記檔剛好 8 bytes。少了後半，一個標記被截成 0（寫標記時磁碟滿、或這個
    -- stem 曾被淘汰過）的殘局會被當成完好快取，而它的圖檔內容無人驗證過。
    resetCache()
    seedCache(STEM_A, 90)
    cacheBytes[CACHE_PREFIX .. STEM_A .. ".ok"] = 0
    relistCache()
    logoManifest()
    tick(6)
    check(not Cache.isReady(HASH_A),
        "完成標記被截成 0 bytes 時不得命中（目錄項還在，但內容長度說它無效）")

    -- (5) 完整寫入路徑：下載 -> 解碼 -> 驗證 -> 落在帶命名空間的檔名上 -> 進 LRU 帳。
    -- payload 刻意跨兩個 tick（一 tick 只解 2048 個 base64 字元），順便釘住
    -- 「寫入中不做淘汰」——getFileOutput 開檔失敗時回的是上一個 static outStream 的殼
    -- （LuaManager.java:5833-5840），此時 truncateFile 的 close() 會關掉寫到一半的圖檔。
    resetCache()
    local payload = string.rep("TWFu", 1024)
    local realHash = NBImage.hashHex(NBImage.hashUpdate(NBImage.hashInit(), payload))
    local realStem = "10_46_0_46_0_46_7_95_16261_" .. realHash
    setManifest({ { name = "w.png", h = realHash, n = 1, b = 3072 } })
    Cache.onTick()
    checkEqual(Cache.getState().lru.phase, "scan", "第一個 tick 只走到掃描階段")
    Cache.receiveChunk({ h = realHash, i = 1, part = payload })
    Cache.onTick()
    check(Cache.getState().writeJob ~= nil, "4096 個字元不可能在一個 tick 內寫完")
    checkEqual(Cache.getState().lru.phase, "scan",
        "寫入中的 job 握著跨 tick 的輸出串流，這期間不得做任何淘汰／截斷")
    Cache.onTick()
    check(Cache.isReady(realHash), "收齊分塊後必須寫檔並驗證通過")
    checkEqual(cacheBytes[CACHE_PREFIX .. realStem .. ".png"], 3072,
        "圖檔必須寫在帶命名空間的檔名上")
    checkEqual(cacheBytes[CACHE_PREFIX .. realStem .. ".ok"], 8, "完成標記必須寫出")
    local writtenEntry = Cache.getState().lru.entries[realStem]
    check(writtenEntry ~= nil and writtenEntry.bytes == 3072,
        "新寫入的圖必須立刻進 LRU 帳（掃描名單是進場快照，不會回頭看到它）")

    -- (6) LRU 淘汰：分批、挑最舊、正在用的不動
    resetCache()
    local hashes = { "a0000001", "a0000002", "a0000003", "a0000004",
        "a0000005", "a0000006", "a0000007", "a0000008" }
    local indexLines = { "NBLRU1 7" }
    local hashIndex
    for hashIndex = 1, #hashes do
        seedCache("10_46_0_46_0_46_7_95_16261_" .. hashes[hashIndex], 31457280)
        indexLines[#indexLines + 1] = "10_46_0_46_0_46_7_95_16261_" .. hashes[hashIndex]
            .. " " .. tostring(hashIndex)
    end
    diskFiles[CACHE_PREFIX .. "index.txt"] = table.concat(indexLines, "\n") .. "\n"
    relistCache()
    -- 最舊的那張（seq=1）同時是這份 manifest 正在用的圖 -> 不可被淘汰。
    -- 刻意把它排在 manifest 最後：pumpVerify 一 tick 只驗一個，淘汰會**早於**它被驗到
    -- （驗到才會戳成最新序號）。這正是「正在用的圖被淘汰」的真實競態，也是保護清單
    -- 唯一救得到的情形——排在前面的話它早就因為驗證命中而變成最新的了。
    local wantedImages = {}
    local dummyIndex
    for dummyIndex = 1, 7 do
        wantedImages[dummyIndex] = {
            name = "pending" .. tostring(dummyIndex) .. ".png",
            h = "b000000" .. tostring(dummyIndex),
            n = 1,
            b = 90,
        }
    end
    wantedImages[8] = { name = "keep.png", h = hashes[1], n = 1, b = 31457280 }
    setManifest(wantedImages)

    local scanTicks = 0
    while Cache.getState().lru.phase ~= "evict" and scanTicks < 60 do
        Cache.onTick()
        scanTicks = scanTicks + 1
    end
    check(scanTicks >= 4, "16 個檔名不得在一個 tick 內掃完（純 Lua 全掃會卡影格）")
    checkEqual(Cache.getState().lru.total, 8 * 31457280, "掃描必須把全部條目算進總量")

    local function evictedCount()
        local count = 0
        local index
        for index = 1, #hashes do
            if cacheBytes[CACHE_PREFIX .. "10_46_0_46_0_46_7_95_16261_" .. hashes[index] .. ".png"] == 0 then
                count = count + 1
            end
        end
        return count
    end

    Cache.onTick()
    checkEqual(evictedCount(), 2, "每 tick 最多淘汰 LRU_EVICT_PER_TICK 張")
    checkEqual(Cache.getState().lru.phase, "evict", "還沒降到上限以下時必須留在淘汰階段")
    Cache.onTick()
    checkEqual(evictedCount(), 4, "第二批淘汰後總量才會降到上限以下")
    checkEqual(Cache.getState().lru.phase, "idle", "降到上限以下就結束淘汰")
    check(Cache.getState().lru.total <= NBImage.CACHE_BUDGET_BYTES,
        "淘汰結束時總量必須落在上限以內")
    check(cacheBytes[CACHE_PREFIX .. "10_46_0_46_0_46_7_95_16261_" .. hashes[1] .. ".png"] > 0,
        "manifest 正在用的圖不可被淘汰，即使它是最舊的")
    check(cacheBytes[CACHE_PREFIX .. "10_46_0_46_0_46_7_95_16261_" .. hashes[2] .. ".png"] == 0,
        "淘汰順序必須是最舊的先走")
    check(cacheBytes[CACHE_PREFIX .. "10_46_0_46_0_46_7_95_16261_" .. hashes[8] .. ".png"] > 0,
        "最新的圖不得被淘汰")
    -- (7) 索引 round-trip：這一場的序號 = 上一場 + 1，且會寫回磁碟
    tick(4)
    check(Cache.isReady(hashes[1]), "保留下來的那張圖最後仍要驗證命中")
    env.nowMs = env.nowMs + 20000
    Cache.onTick()
    checkEqual(string.match(diskFiles[CACHE_PREFIX .. "index.txt"] or "", "^NBLRU1 (%d+)"),
        "8", "索引表頭的場次序號必須是上一場 +1")
    check(string.find(diskFiles[CACHE_PREFIX .. "index.txt"],
        "10_46_0_46_0_46_7_95_16261_" .. hashes[1] .. " 8", 1, true) ~= nil,
        "這一場用過的圖必須被戳成最新的序號")

    -- (7b) 伺服器換掉圖之後，舊圖被淘汰時必須連 ready 旗標一起撤銷。
    -- syncManifest 對已 ready 的 hash **不重驗**，旗標留著的話同一個 hash 下次再出現在
    -- manifest（輪替圖片的伺服器很常見）就會拿到一個 0 bytes 的檔。
    resetCache()
    local rotatedStem = "10_46_0_46_0_46_7_95_16261_" .. HASH_A
    seedCache(rotatedStem, 209715200)
    relistCache()
    setManifest({ { name = "rotate.png", h = HASH_A, n = 1, b = 209715200 } })
    tick(2)
    check(Cache.isReady(HASH_A), "先讓這張圖成為 ready")
    setManifest({})
    tick(2)
    checkEqual(cacheBytes[CACHE_PREFIX .. rotatedStem .. ".png"], 0,
        "已不在 manifest 內、又超出總量上限的圖必須被淘汰")
    checkEqual(Cache.getState().ready[HASH_A], nil,
        "被淘汰的 hash 必須連 ready 旗標一起撤銷")

    -- (7c) 淘汰時截斷失敗（防毒鎖檔／OneDrive 同步／磁碟滿）。getFileOutput 開檔失敗時
    -- **不回 nil**，它回的是包著上一個成功 static outStream 的殼（LuaManager.java:5833-5840）
    -- ——拿得到 writer、close() 也不拋錯，檔案卻原封不動。只看回傳值的話「截斷失敗」
    -- 這條路整個是死程式碼，而 evictStem 會照樣把 bytes 從帳上扣掉：掃描名單是進場當下的
    -- 快照，這個 stem 這一場不會再被看到，於是帳永久低估——淘汰自認做完回到 idle，
    -- 磁碟卻持續超出上限。
    resetCache()
    local lockedStem = "10_46_0_46_0_46_7_95_16261_d0000001"
    local freeStem = "10_46_0_46_0_46_7_95_16261_d0000002"
    seedCache(lockedStem, 100000000)
    seedCache(freeStem, 100000000)
    relistCache()
    setManifest({})
    lockedPaths[CACHE_PREFIX .. lockedStem .. ".png"] = true
    clearLog()
    tick(8)
    checkEqual(cacheBytes[CACHE_PREFIX .. lockedStem .. ".png"], 100000000,
        "鎖住的檔案截不掉（getFileOutput 給的是別名殼，不是真的開到這個檔）")
    check(logContains("cache discard failed"),
        "截斷失敗必須留下 log（只看 getFileOutput 的回傳值時這行永遠跑不到）")
    check(Cache.getState().lru.entries[lockedStem] ~= nil,
        "截不掉的位元組不得從 LRU 帳上扣掉，否則這一場的帳永久低估")
    checkEqual(cacheBytes[CACHE_PREFIX .. freeStem .. ".png"], 0,
        "淘汰必須換下一個受害者，不得因為第一個截不掉就自認做完")
    lockedPaths = {}

    -- 0 bytes 的目錄項是淘汰留下的墓碑（PZ 沒有刪檔 API，只能截成 0）。下一場掃描必須
    -- 當它不存在——算進 lru.entries 的話它會被選成淘汰目標，把每 tick 兩個淘汰額度
    -- 花在截斷一個已經是 0 的檔上。
    relistCache()
    Cache.state = nil
    dofile(CACHE_MODULE)
    setManifest({})
    tick(8)
    checkEqual(Cache.getState().lru.entries[freeStem], nil,
        "0 bytes 的墓碑不得被算進 LRU 帳（淘汰額度會被空轉吃光）")

    -- (8) 索引壞掉必須安全降級：快取照樣命中、面板照樣進得去
    resetCache()
    diskFiles[CACHE_PREFIX .. "index.txt"] = "garbage\nnot an index at all\n"
    seedCache(STEM_A, 90)
    relistCache()
    logoManifest()
    tick(6)
    check(Cache.isReady(HASH_A), "索引壞掉時快取仍必須命中（索引只影響淘汰順序）")
    check(logContains("index unreadable"), "索引壞掉必須留下一行 log")
    check(not logContains("image cache tick failed"), "索引壞掉不得讓整個 tick 拋錯")
    checkEqual(Cache.getState().lru.phase, "idle", "索引壞掉仍要走完掃描與淘汰")

    -- (9) 寫入時間窗：額度用盡只停這個窗，換窗後恢復（舊版是整場遊戲不恢復）
    resetCache()
    -- 遊戲內回饋走既有的事件機制（NBClient.LANGUAGE_STATUS_EVENT 的形狀），
    -- 這裡就在事件上掛一個 handler，斷言的是真正會送到 NBPanel 的那份 payload。
    local imageEvents = {}
    Events[Cache.STATUS_EVENT].Add(function(imagePayload)
        imageEvents[#imageEvents + 1] = imagePayload
    end)
    local hashB = "1234abcd"
    setManifest({ { name = "big.png", h = hashB, n = 1, b = 3072 } })
    Cache.onTick()
    Cache.getState().windowWritten = NBImage.WRITE_WINDOW_BYTES - 10
    Cache.receiveChunk({ h = hashB, i = 1, part = payload })
    Cache.onTick()
    checkEqual(Cache.getState().attempts[hashB], 3, "額度用盡的 hash 這個窗內不得再重試")
    checkEqual(Cache.getState().deferred[hashB], true, "被額度擋下的 hash 要記進 deferred")
    checkEqual(cacheBytes[CACHE_PREFIX .. "10_46_0_46_0_46_7_95_16261_" .. hashB .. ".png"], nil,
        "撞到額度時連開檔都不該做")
    check(logContains("write budget exhausted"), "額度用盡必須留下一行 log")

    -- (9b) 玩家看得到的回饋。只有這一種狀態值得打斷玩家：淘汰／回收／重試都是背景行為，
    -- 玩家看到的只會是「圖出現了」。誠實伺服器永遠走不到這裡（合法上界 16MB 遠低於
    -- 一個窗的 64MB），所以這不是雜訊。
    checkEqual(#imageEvents, 1, "額度用盡必須發出一則玩家看得到的狀態事件")
    checkEqual(imageEvents[1].kind, "budget", "事件必須自報 kind，供 NBPanel 分派")
    checkEqual(imageEvents[1].minutes, 30,
        "事件必須帶「多久之後自動恢復」，否則提示只能說『壞了』說不出『等多久』")

    -- 同一個窗內再撞一次不得再發：惡意伺服器可以每 tick 換一批新 hash，
    -- 一次一則就是每秒 60 則 toast。
    local hashC = "1234abce"
    setManifest({ { name = "big2.png", h = hashC, n = 1, b = 3072 } })
    -- 先 tick 讓 syncManifest 認得這個 hash：receiveChunk 對不在 wanted 裡的 hash
    -- 直接丟棄，順序反過來的話這段就只是在測「分塊被丟掉」，永遠不會走到額度那條分支。
    tick(2)
    Cache.receiveChunk({ h = hashC, i = 1, part = payload })
    tick(2)
    checkEqual(Cache.getState().deferred[hashC], true,
        "同一個窗內的第二張圖一樣要被額度擋下（確認真的走到那個分支）")
    checkEqual(#imageEvents, 1, "同一個時間窗內不得再發第二則（否則惡意伺服器可以洗版）")

    env.nowMs = env.nowMs + NBImage.WRITE_WINDOW_MS
    Cache.onTick()
    checkEqual(Cache.getState().attempts[hashB], nil,
        "換窗後被額度擋下的 hash 必須恢復可重試")
    checkEqual(Cache.getState().windowWritten, 0, "換窗後額度必須重新裝滿")
    checkEqual(Cache.getState().deferred[hashB], nil, "換窗後 deferred 必須清空")

    -- 換窗之後才可以再提醒一次（新的窗、新的一則）。
    Cache.getState().windowWritten = NBImage.WRITE_WINDOW_BYTES - 10
    Cache.receiveChunk({ h = hashC, i = 1, part = payload })
    tick(3)
    checkEqual(#imageEvents, 2, "換到新的時間窗後再撞到才可以再發一則")

    -- ---------------------------------------------------------------------
    -- (10) 中斷續傳：逾時不得丟掉已收到的分塊，下一次 imgreq 要帶續傳起點
    --
    -- 舊行為是逾時就把 pending 整份丟掉，於是每次重試都從第 1 塊重來——掉包的連線
    -- 因此永遠收不完一張大圖，三次之後整場退回替代文字。
    -- ---------------------------------------------------------------------
    local function splitParts(text, count)
        local parts = {}
        local size = math.floor(string.len(text) / count)
        local partIndex
        for partIndex = 1, count - 1 do
            parts[partIndex] = string.sub(text, (partIndex - 1) * size + 1, partIndex * size)
        end
        parts[count] = string.sub(text, (count - 1) * size + 1)
        return parts
    end

    local function lastImgReq()
        local reqIndex
        for reqIndex = #clientCommands, 1, -1 do
            if clientCommands[reqIndex].command == "imgreq" then
                return clientCommands[reqIndex].args
            end
        end
        return nil
    end

    resetCache()
    clientCommands = {}
    local parts3 = splitParts(payload, 3)
    setManifest({ { name = "r.png", h = realHash, n = 3, b = 3072 } })
    tick(2)
    local firstReq = lastImgReq()
    check(firstReq ~= nil, "本機缺少的圖必須送出 imgreq")
    checkEqual(firstReq.hashes[1], realHash, "imgreq 必須要求缺少的那個 hash")
    -- 回歸：沒有任何進度時起點就是 1，也就是續傳之前的行為（舊版 server 忽略未知欄位
    -- 一樣會整張送，協定兩個方向都能安全降級）。
    checkEqual(firstReq.from[1], 1, "沒有進度時續傳起點必須是 1（整張送）")

    Cache.receiveChunk({ h = realHash, i = 1, part = parts3[1] })
    checkEqual(Cache.getState().pending[realHash].received, 1, "第一塊必須被記下")

    env.nowMs = env.nowMs + 60000
    tick(1)
    local resumeReq = lastImgReq()
    checkEqual(resumeReq.from[1], 2, "逾時重試必須從第一個缺的分塊接下去，不是從頭")
    checkEqual(Cache.getState().pending[realHash].parts[1], parts3[1],
        "逾時不得丟掉已經收到的分塊")

    Cache.receiveChunk({ h = realHash, i = 2, part = parts3[2] })
    Cache.receiveChunk({ h = realHash, i = 3, part = parts3[3] })
    tick(4)
    check(Cache.isReady(realHash), "續傳拼回來的內容必須通過 digest 驗證並可用")
    checkEqual(cacheBytes[CACHE_PREFIX .. realStem .. ".png"], 3072,
        "續傳完成的圖檔位元組數必須與宣告相同")

    -- (10b) stalled 的傳輸不佔併發額度。佔的話，REQUEST_BATCH 張同時卡住就會讓
    -- pumpRequest 每次都早退，續傳請求一則都送不出去——續傳整個功能死在這裡，
    -- 而且症狀是「圖就是不出現」，看不出跟併發計數有關。
    resetCache()
    clientCommands = {}
    local batch = {}
    local batchIdx
    for batchIdx = 1, 4 do
        batch[batchIdx] = {
            name = "b" .. tostring(batchIdx) .. ".png",
            h = "c000000" .. tostring(batchIdx),
            n = 3,
            b = 3072,
        }
    end
    setManifest(batch)
    tick(6)
    for batchIdx = 1, 4 do
        Cache.receiveChunk({ h = batch[batchIdx].h, i = 1, part = parts3[1] })
    end
    clientCommands = {}
    env.nowMs = env.nowMs + 60000
    tick(1)
    local stalledReq = lastImgReq()
    check(stalledReq ~= nil, "四張圖同時 stalled 時仍必須送得出續傳請求（不得死結）")
    checkEqual(stalledReq and stalledReq.from[1], 2, "全數 stalled 的續傳請求一樣要帶起點")

    -- (10c) 同時在傳的張數上界。每一張 pending 都握著一份 base64 字串，而 stalled 刻意
    -- 不佔併發額度（見 10b），所以這個上界是記憶體用量唯一的實質旋鈕——沒有斷言釘住的話，
    -- 把它從 4 調到 200 不會有任何測試變紅，而症狀（記憶體）也不會在測試裡浮現。
    resetCache()
    clientCommands = {}
    local wide = {}
    local wideIdx
    for wideIdx = 1, 8 do
        wide[wideIdx] = {
            name = "w" .. tostring(wideIdx) .. ".png",
            h = "e000000" .. tostring(wideIdx),
            n = 1,
            b = 3072,
        }
    end
    setManifest(wide)
    tick(12)
    local wideReq = lastImgReq()
    check(wideReq ~= nil, "八張缺圖必須送得出 imgreq")
    checkEqual(wideReq and #wideReq.hashes, 4,
        "一次最多只能要求 REQUEST_BATCH 張（同時握著的 base64 字串張數上界）")

    -- (10d) 逾時的語意是「沒有進度」而不是「沒傳完」：receiveChunk 每收到一個新分塊就
    -- 重新計時。少了那一行，慢連線上的大圖會在傳輸**正常前進**的途中被判成逾時，
    -- 而且每判一次就吃掉 MAX_ATTEMPTS 三次之一，三次之後整場退回替代文字。
    resetCache()
    setManifest({ { name = "slow.png", h = realHash, n = 3, b = 3072 } })
    tick(2)
    Cache.receiveChunk({ h = realHash, i = 1, part = parts3[1] })
    env.nowMs = env.nowMs + 40000
    Cache.receiveChunk({ h = realHash, i = 2, part = parts3[2] })
    env.nowMs = env.nowMs + 40000
    clearLog()
    tick(1)
    checkEqual(Cache.getState().attempts[realHash], nil,
        "距上一個分塊只有 40 秒（< PENDING_TIMEOUT_MS）時不得吃掉一次重試")
    check(not logContains("image transfer stalled"),
        "傳輸一直在前進時不得判成 stalled（逾時看的是進度，不是總耗時）")

    -- (11) 續傳的正確性不可以比整張重傳弱：補回來的分塊被竄改時必須偵測得到並重來。
    -- 位元組數刻意做成完全正確（同樣 3072 bytes），所以只有 digest 抓得到。
    resetCache()
    local badParts = splitParts(string.rep("TWFv", 1024), 3)
    setManifest({ { name = "r.png", h = realHash, n = 3, b = 3072 } })
    tick(2)
    Cache.receiveChunk({ h = realHash, i = 1, part = parts3[1] })
    env.nowMs = env.nowMs + 60000
    tick(1)
    clearLog()
    Cache.receiveChunk({ h = realHash, i = 2, part = badParts[2] })
    Cache.receiveChunk({ h = realHash, i = 3, part = parts3[3] })
    tick(4)
    check(not Cache.isReady(realHash), "續傳補回來的分塊被竄改時不得標記為可用")
    check(logContains("image verify failed"), "digest 不符必須留下 log")
    checkEqual(cacheBytes[CACHE_PREFIX .. realStem .. ".png"], 0,
        "驗證失敗必須把半成品截成 0")
    checkEqual(cacheBytes[CACHE_PREFIX .. realStem .. ".ok"], 0,
        "半成品的完成標記必須一起失效（順序：先標記後圖檔）")

    -- (12) 進度是以 hash 為鍵的，manifest 變動不得把正在傳的圖打回第 0 塊。
    -- 服主多放一張圖（或原地覆蓋產生一個新 hash）每個輪詢週期都會踩到這條。
    resetCache()
    setManifest({ { name = "r.png", h = realHash, n = 3, b = 3072 } })
    tick(2)
    Cache.receiveChunk({ h = realHash, i = 1, part = parts3[1] })
    setManifest({
        { name = "r.png", h = realHash, n = 3, b = 3072 },
        { name = "extra.png", h = "abcdef01", n = 1, b = 90 },
    })
    tick(2)
    local carried = Cache.getState().pending[realHash]
    check(carried ~= nil and carried.received == 1,
        "manifest 多一張圖不得把其餘正在傳的圖打回第 0 塊")

    -- 但同一個 hash 配上不同的宣告值只可能來自惡意或壞掉的 manifest：舊分塊對不上，
    -- 整份丟掉重來比較便宜也比較安全。
    setManifest({ { name = "r.png", h = realHash, n = 2, b = 3072 } })
    tick(1)
    checkEqual(Cache.getState().pending[realHash], nil,
        "同一個 hash 換了分塊數時舊進度必須整份丟掉")
    clearLog()
end)()

-- ---------------------------------------------------------------------------
-- 續傳的另一半：server 端供應。imgreq 的 from 是信任邊界（client 說了算的數字），
-- 壞值只能造成「多送」，不可以少送、更不可以讓 nextJobMessage 去取不存在的 chunks[i]。
-- ---------------------------------------------------------------------------
;(function()
    local function seedImageJob(chunkCount)
        local chunks = {}
        local chunkIdx
        for chunkIdx = 1, chunkCount do
            chunks[chunkIdx] = "img" .. tostring(chunkIdx)
        end
        resetServer(1)
        env.nowMs = env.nowMs + 60000
        NBServer.onClientCommand(MODULE, "register", makePlayer("alice"),
            { lang = "EN", lseq = 0 })
        serverState.imageByHash = {
            aabbccdd = {
                name = "a.png", h = "aabbccdd", n = chunkCount, b = 100, chunks = chunks,
            },
        }
        -- 只留圖片 job，內容 job 會吃掉同一份每人 8 則的額度。
        serverState.jobs = {}
        serverState.queue = {}
        serverState.queued = {}
        sentCommands = {}
    end

    local function imgReq(args)
        NBServer.onClientCommand(MODULE, "imgreq", makePlayer("alice"), args)
    end

    local function sentChunkIndexes()
        local out = {}
        local sentIdx
        for sentIdx = 1, #sentCommands do
            if sentCommands[sentIdx].command == "imgchunk" then
                out[#out + 1] = sentCommands[sentIdx].payload.i
            end
        end
        return out
    end

    seedImageJob(30)
    imgReq({ hashes = { "aabbccdd" }, from = { 26 } })
    NBServer.processQueue()
    local sent = sentChunkIndexes()
    checkEqual(#sent, 5, "續傳起點 26 只該送出 26..30 共 5 塊")
    checkEqual(sent[1], 26, "第一塊必須是 client 指定的續傳起點")
    checkEqual(sent[5], 30, "最後仍要送到最後一個分塊")

    -- 舊版 client 不送 from：必須整張從第 1 塊送（協定向下相容）。
    seedImageJob(30)
    imgReq({ hashes = { "aabbccdd" } })
    NBServer.processQueue()
    checkEqual(sentChunkIndexes()[1], 1, "沒有 from 欄位時必須整張從第 1 塊送")

    -- 壞掉的起點一律退回 1：只會多送，不會少送或炸掉。
    local badFroms = { 0, 31, "x", 1.5 }
    local badIdx
    for badIdx = 1, 4 do
        seedImageJob(30)
        imgReq({ hashes = { "aabbccdd" }, from = { badFroms[badIdx] } })
        NBServer.processQueue()
        checkEqual(sentChunkIndexes()[1], 1,
            "不合法的續傳起點必須退回整張重送（index " .. tostring(badIdx) .. "）")
    end

    -- 同一個 hash 又被要求一次而且還沒送出：取兩者較早的起點。取後到的那個的話，
    -- client 把進度整份丟掉（改送 from=1）會被佇列裡的舊 from=k 蓋掉，前 k-1 塊永遠不送。
    seedImageJob(30)
    imgReq({ hashes = { "aabbccdd" }, from = { 20 } })
    env.nowMs = env.nowMs + 60000
    imgReq({ hashes = { "aabbccdd" }, from = { 5 } })
    NBServer.processQueue()
    checkEqual(sentChunkIndexes()[1], 5,
        "同一個 hash 重複要求時必須取較早的續傳起點")

    -- 跨檔常數關係：client 的 imgreq 間隔必須**大於** server 的 per-player 冷卻。
    -- 兩者相等時「連續兩次請求」在 server 看來是 10 秒 ± 網路抖動，約一半會被冷卻靜默
    -- 丟棄；而送出續傳請求的當下 client 已經樂觀地把 stalled 收掉並重新計時，被丟掉的
    -- 那次要白等一整個 PENDING_TIMEOUT_MS，還吃掉 MAX_ATTEMPTS 三次之一。
    local cacheSource = readRepoFile("media/lua/client/NoticeBoard/NBImageCache.lua")
    local serverSource = readRepoFile("media/lua/server/NoticeBoard/NBServer.lua")
    local clientInterval = tonumber(string.match(cacheSource or "",
        "local REQUEST_INTERVAL_MS = (%d+)"))
    local serverCooldown = tonumber(string.match(serverSource or "",
        "local REQUEST_COOLDOWN_MS = (%d+)"))
    check(clientInterval ~= nil, "找不到 client 的 REQUEST_INTERVAL_MS")
    check(serverCooldown ~= nil, "找不到 server 的 REQUEST_COOLDOWN_MS")
    check(clientInterval > serverCooldown,
        "client 的 imgreq 間隔必須大於 server 的 per-player 冷卻，否則續傳請求會被靜默丟棄")

    -- 預算耗盡的提示要有翻譯鍵可用。四語鍵集一致性（verify_mod.py）擋不住「四語都沒有」。
    local iguiSource = readRepoFile("media/lua/shared/Translate/EN/IG_UI.json")
    local budgetText = string.match(iguiSource or "",
        '"IGUI_MinidoracatNB_ImageBudget"%s*:%s*"([^"]*)"')
    check(budgetText ~= nil, "預算耗盡的玩家提示缺少翻譯鍵 IGUI_MinidoracatNB_ImageBudget")
    check(budgetText ~= nil and string.find(budgetText, "%%1") ~= nil,
        "提示必須帶 %1，否則說得出「暫停了」卻說不出「多久恢復」")
end)()

-- ---------------------------------------------------------------------------
-- NBSkin 純邏輯：9-slice 的最小尺寸夾限與絕對座標 floor。不需要引擎（NinePatchTexture 用假的），
-- 三個 UI 元件的整體落點在 scripts/test_nbpanel.lua 驗。
-- 夾限的理由（NBSkin.lua CORNER 註解）：矩形短於兩個角落之和時，引擎會讓角落互相重疊
-- （半透明填色疊成雙倍 alpha），縮放角落又會把 AA 弧線拉糊，所以直接退回直角 drawRect。
-- ---------------------------------------------------------------------------
;(function()
    dofile(MOD_VERSION_DIR .. "media/lua/client/NoticeBoard/NBSkin.lua")
    local Skin = NBSkin
    -- 角落 6px：四角圓最小 12×12；上圓下直（沒有下排角落）最小 12×6
    check(Skin.fits(12, 12, false), "12x12 恰好放得下四個角落")
    check(not Skin.fits(11, 12, false), "寬 11 放不下左右兩個角落")
    check(not Skin.fits(12, 11, false), "高 11 放不下上下兩個角落")
    check(Skin.fits(12, 6, true), "上圓下直：高 6 = 一排角落即可")
    check(not Skin.fits(12, 5, true), "上圓下直：高 5 放不下角落")
    check(not Skin.fits(11, 6, true), "上圓下直：寬仍需 12")
    check(Skin.fits(1190, 864, false) and Skin.fits(40, 40, false) and Skin.fits(300, 56, false)
        and Skin.fits(80, 18, true) and Skin.fits(420, 16, true),
        "面板／浮窗／Toast／最窄頁籤／最矮標題列全部走得了 9-slice")

    -- 夾限落地：貼圖存在但矩形太小 → drawRect／drawRectBorder；夠大 → render，且座標 floor
    local renders, rects, borders = {}, {}, {}
    _G.NinePatchTexture = { getSharedTexture = function()
        return { render = function(_, x, y, w, h)
            renders[#renders + 1] = { x = x, y = y, w = w, h = h }
        end }
    end }
    local element = {
        x = 10.7,
        y = 20.2,
        getAbsoluteX = function(self) return self.x end,
        getAbsoluteY = function(self) return self.y end,
        drawRect = function(_, x, y, w, h) rects[#rects + 1] = { x = x, y = y, w = w, h = h } end,
        drawRectBorder = function(_, x, y, w, h)
            borders[#borders + 1] = { x = x, y = y, w = w, h = h }
        end,
    }
    local white = { r = 1, g = 1, b = 1, a = 1 }
    Skin.fill(element, 0, 0, 11, 30, white)
    Skin.border(element, 0, 0, 30, 11, white)
    checkEqual(#renders, 0, "太小的矩形不得走 9-slice（角落會重疊）")
    checkEqual(#rects, 1, "太小的填色退回 drawRect")
    checkEqual(#borders, 1, "太小的邊框退回 drawRectBorder")
    check(rects[1].x == 0 and rects[1].w == 11 and rects[1].h == 30,
        "退回的 drawRect 用元件相對座標與原尺寸")
    Skin.fill(element, 0, 0, 30, 6, white, true)
    Skin.fill(element, 5, 5, 12, 12, white)
    checkEqual(#renders, 2, "夠大的矩形走 9-slice")
    checkEqual(renders[1].x, 10, "絕對 x 要 floor（10.7 → 10）")
    checkEqual(renders[1].y, 20, "絕對 y 要 floor（20.2 → 20）")
    checkEqual(renders[2].x, 15, "絕對 x = floor(10.7 + 5) = 15")
    checkEqual(renders[2].y, 25, "絕對 y = floor(20.2 + 5) = 25")
    check(renders[2].w == 12 and renders[2].h == 12, "尺寸原樣交給引擎")
    -- 寬高也 floor：render 不 floor（NinePatchTexture.java:154 起直接吃 float），小數寬高會讓
    -- 右／下角落落在半個像素上、與拉伸段重疊
    Skin.fill(element, 0, 0, 30.9, 12.6, white)
    check(renders[3].w == 30 and renders[3].h == 12, "小數寬高要 floor（30.9x12.6 → 30x12）")
    _G.NinePatchTexture = nil
    Skin.reset()
end)()

print = realPrint

print("Step 1 tests passed: " .. tostring(assertionCount) .. " assertions")
