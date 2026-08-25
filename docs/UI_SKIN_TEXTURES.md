# UI 圓角皮膚 — 貼圖規格書（MinidoracatNoticeBoardFor42）

> **【2026-08-25 上移註記】** 本文件描述的 5 張貼圖與生成器 `gen_ui_textures.py` 已上移家族
> UI 框架 repo（`D:/github/MinidoracatUIFor42`），檔名前綴 `nb_` → `mui_`、輸出目錄
> `42/media/ui/MinidoracatUI/`、貼圖驗證改由該 repo 的 `verify_mod.py` 第 12 項把關。
> 本 repo 的 `NBSkin.lua` 現為框架 thin adapter（框架缺席退直角），不再攜帶任何 PNG。
> 本文件保留作為貼圖規格的權威原始出處（框架生成器的參考表與斷言即源自 §2-§4）；
> **正文中的 nb_ 檔名與 `42/media/ui/NoticeBoard/` 路徑為歷史原貌**，現行檔名／路徑／
> 驗證入口一律以框架 repo 為準。


給「生成貼圖」與「換皮 Lua」兩個後續階段照著做。設計基線沿用 `docs/UI_DESIGN.md`（色票 §0 全部沿用），本文件只定義：貼圖清單、像素規格、9-slice 切線、抗鋸齒策略、各元件的套用方式、色票增補、UI_DESIGN.md 需改動的章節。

貼圖輸出目錄（MOD 樹內、隨 Workshop 上傳）：
`MOD/MinidoracatNoticeBoardFor42/Contents/mods/MinidoracatNoticeBoardFor42/42/media/ui/NoticeBoard/`
Lua 端引用路徑：`media/ui/NoticeBoard/<檔名>`（`ZomboidFileSystem.getString` 大小寫不敏感，仍請完全照檔名寫）。

---

## 0. 關鍵修正：引擎**有**原生 9-slice，用它，不自寫

任務前提寫「引擎沒有原生 9-slice（`UIElement.java` / `SpriteRenderer.java` 皆無 NinePatch）」——那兩個檔確實沒有，但它在別處：**`zombie/core/textures/NinePatchTexture.java`**，Lua 暴露於 `LuaManager.java:1850`（`setExposed(NinePatchTexture.class)`）。NeatUI 自己的捲軸就是用它（`neatui_framework/scrollview/niscrollbar.lua:45,78`），它的 Lua 版 `neattool_9patch.lua` 只是為了「小元件配大貼圖」的舊路徑（該檔 :5 註解自承 B42.9 起引擎有原生 9-patch）。

決策：**全部走 `NinePatchTexture`**。理由（ponytail 階梯第 4 階：平台原生功能）：
- 一張 PNG 一個形狀，切線寫在貼圖裡（第一列／第一欄標記），Lua 端零切片常數、零多次 `drawTextureScaled` 拼接、零 NeatUI 依賴。
- 它的貼圖以 flags=3 建立（`NinePatchTexture.java:315`）→ GL_NEAREST（`TextureID.java:406-407,423-424`）→ 拉伸區不會與相鄰透明像素混色；反之一般 `getTexture` 貼圖是 GL_LINEAR，用 `drawTextureScaled` 自拼 1px 邊條必出灰邊（`drawTextureScaled` 沒有 UV inset 參數可救）。
- 角落永遠 1:1 繪製（`render` `:154,:158,:188,:203` 直接用 `widths[]/heights[]` 當目的寬高，不縮放），AA 弧線原樣上屏。

已查證的行為與坑（都寫進 AGENTS.md API 表了）：
| 行為 | 出處 | 對我們的意義 |
|---|---|---|
| `getSharedTexture(path)` **第一次呼叫必回 null**（載入完直接 `return null`，第二次才命中快取） | `NinePatchTexture.java:42-67`（`:56-63` 無條件 return null；`:46-48` 快取命中） | 預檢要**連呼兩次**；第二次仍 nil 才算壞 |
| 失敗路徑進 `s_nullTextures` 永久黑名單 | `:43-44,:53,:57-58` | 同 `Texture.nullTextures` 那套紀律：pcall＋nil 檢查＋不重試 |
| 載入同步（讀檔＋解碼在呼叫執行緒） | `NinePatchTextureAssetManager.java:28-40` | 第二次呼叫拿到的物件已可 render |
| `render(x,y,w,h,r,g,b,a)` 吃**絕對螢幕座標**、不 floor、走 `SpriteRenderer.render` | `:145-213`、`:249`；UIElement 的 stencil 也是同一佇列（`UIElement.java:1875-1889`） | 呼叫端要加 `getAbsoluteX/Y()`、先 `math.floor`；頁籤列的 `setStencilRect` 一樣會裁它 |
| 標記解析：只讀**第一列（橫向拉伸區）＋第一欄（縱向拉伸區）**，alpha≥128 為可拉伸，剝掉這一列一欄後才是內容；**不讀右／下**（不是 Android 完整版 .9.png） | `:253-325`（`:262-298` 掃描、`:306-310` 剝除） | PNG 尺寸＝內容＋1 列＋1 欄；千萬別加右／下 padding 標記（會被當內容畫出來） |
| 拉伸區可為 0 高（`heights[6]=0`）→ 該排 patch 直接略過 | `:222` `width<=0 or height<=0` return | 「只圓上方」貼圖讓縱向拉伸標記一路畫到最底列即可 |
| 縮到比角落總和還小時中段負寬直接略過、角落互相重疊 | 同上 | 各元件最小尺寸 ≥ 12×12（我們的最小是 16px 標題列） |

退回路徑：任一貼圖 nil（打錯路徑、dedicated、測試 harness 沒有 `NinePatchTexture` 全域、B42.9 之前）→ **原封不動用現在的 `drawRect`／`drawRectBorder` 畫法**。零新程式，只是把現有呼叫留在 else 分支。

---

## 1. 總體視覺決策

| 決策 | 值 | 理由 |
|---|---|---|
| 圓角半徑 | **6 px，全元件統一** | 約 1000×730 的面板（1080p 預設 `NBPanel.defaultSize()`）上「看得出圓角但不像卡片」；16-22px 高的標題列／頁籤上不會變成藥丸；統一半徑讓面板／浮窗／Toast／錯誤區塊共用同一組貼圖、標題列與頁籤共用另一組——**總共 4 張 9-slice PNG** |
| 邊框 | 1 px，獨立一張 border 貼圖 | 填色與邊框要各自染色（黑 0.8 vs 灰 1.0），一張貼圖一個 tint 做不到；兩張＝完全對應現在的 `drawRect`＋`drawRectBorder` 兩個呼叫，語意不變 |
| 貼圖顏色 | RGB 全 255（含 alpha=0 像素），alpha＝形狀 | 顏色一律運行時由 COLORS 染。透明像素也要白：`nb_dot.png` 走 GL_LINEAR，透明鄰居若是黑會混出黑邊 |
| 標題列原生貼圖 `Panel_TitleBar.png`／`Panel_StatusBar.png` | **不再用** | 兩張都是直角條，塞進 r=6 的角會露角；改成平面染色（新色票 `TITLEBAR_FILL`），底部只留 1px 分隔線＋原生 `ResizeIcon.png` |
| 頁籤形狀 | 上方兩角圓、底邊開放（3 邊框） | 經典「站在軌道上的頁籤」；選中頁籤的 2px 琥珀底線蓋住軌道線，形成「與內容相連」感 |
| 三顆 ISButton（語系／重設大小／重新載入）、關閉／釘選／收合鈕、捲軸、resize 把手 | **不換皮** | ISButton 的 `textureBackground` 是整張拉伸（`ISButton.lua:135`），套圓角貼圖會變形；這些是玩家熟悉的原生鉻件，與 UI_DESIGN §1.1「不重繪」一致 |

### 1.1 抗鋸齒（AA）策略

- **弧線像素做覆蓋率 AA**（8×8 超取樣或解析式覆蓋率），**直線邊像素不做 AA**——alpha 只能是 0 或 255。
- 為什麼 9-slice 拉伸不會弄壞 AA：角落 patch 永遠 1:1（見 §0），弧線像素原樣上屏；拉伸的只有中段，而中段的每一列／每一欄都是**逐像素相同**的（見 §3 alpha 表：拉伸區 x=6..9、y=6..9 全部一樣），GL_NEAREST 不管取到哪個 texel 都同值 → 沒有東西可以被拉糊。
- 直線邊為什麼必須精確 0/255：它在拉伸區內，任何中間值會變成整條半透明線；而且 tint alpha（`BORDER.a=1.0`、`BG_PANEL.a=0.8`）要精確等於設計值。
- 座標一律 `math.floor` 後再 render：`NinePatchTexture.render` 不 floor（`:154-212` 直接把 float 丟給 `SpriteRenderer.render`），GL_NEAREST 遇到半像素位置會在邊上抖 1px（Toast 滑入動畫的 x 是小數）。
- 邊框 AA 疊在填色 AA 上的極角像素會有一點點暗色 fringe（fill 的部分覆蓋透出來），1px 弧線上肉眼不可辨，接受；不要為此把 fill 內縮 1px（那會在 fill/border 之間留亮縫，更醜）。

### 1.2 尺寸為什麼是 17×17

- 內容 16×16 ＝ 角落 6 ＋ 拉伸區 4 ＋ 角落 6；PNG 再加 1 列 1 欄標記 → **17×17**。
- 角落 = 半徑（6）就夠：邊框 1px 在弧線之內，弧線以外的直邊像素在拉伸區裡是均勻的，不需要多留角落寬度。
- 拉伸區留 4px 而不是 1px：給 UV 邊界的浮點運算餘裕（1px 也能動，但 4px 保險且免費）。
- 16 是 2 的冪：`ImageUtils.getNextPowerOfTwoHW(16)=16`，顯存零補邊。
- 再大沒有意義：角落永遠 1:1，AA 品質只取決於半徑，不取決於貼圖大小；193×193（NeatUI）只是他們半徑更大又用同一張放不同大小。
- 最小可繪尺寸 12×12（角落 6+6）；我們最小的用途是 `titleBarHeight()` ≥ 16。

---

## 2. 貼圖清單總覽

| # | 檔名 | PNG 尺寸 | 內容尺寸 | 圓角 | 切線（內容座標） | 用途 |
|---|---|---|---|---|---|---|
| 1 | `nb_round_fill.png` | 17×17 | 16×16 | 四角 r=6 | 橫 6/4/6、縱 6/4/6 | 面板底、浮窗底、Toast 底、錯誤區塊底、浮窗 hover 疊層 |
| 2 | `nb_round_border.png` | 17×17 | 16×16 | 四角 r=6 | 同上 | 面板外框、浮窗框、Toast 框 |
| 3 | `nb_roundtop_fill.png` | 17×17 | 16×16 | 上兩角 r=6，下方直角 | 橫 6/4/6、縱 6/10/0 | 標題列疊色、頁籤選中／hover 填色 |
| 4 | `nb_roundtop_border.png` | 17×17 | 16×16 | 上兩角 r=6，下方**開放** | 同上 | 頁籤 3 邊框 |
| 5 | `nb_dot.png`（選配，建議做） | 16×16 | 16×16 | 正圓 d=16 | 非 9-slice，走 `getTexture`＋`drawTextureScaled` | 未讀紅點（頁籤、浮窗） |

「切線 a/b/c」＝固定 a px ／ 拉伸 b px ／ 固定 c px。內容座標 (cx, cy) 對應 PNG 像素 (cx+1, cy+1)。

---

## 3. 各貼圖規格

### 3.1 `nb_round_fill.png`
- PNG 17×17，RGBA 8-bit（colortype 6）。內容 16×16 = 外框為 [0,16)×[0,16) 的圓角矩形，四角半徑 6，實心。
- 標記：PNG 第 0 列 x=7..10 alpha 255（4 px），其餘 alpha 0；PNG 第 0 欄 y=7..10 alpha 255，其餘 0；(0,0) alpha 0。
- 引擎解析結果（已用 `:262-298` 同邏輯模擬驗證）：`widths = {6,4,6}`、`heights = {6,4,6}`。
- 用途與 tint：面板底 `BG_PANEL`、浮窗底 `BG_PANEL`、浮窗 hover 疊層 `TAB_HOVER_FILL`、Toast 底 `TOAST_BG`（×動畫 alpha）、錯誤區塊 `ERROR_BG`。
- 最小繪製 12×12。

alpha 參考表（PNG 座標，第 0 列／第 0 欄是標記；由覆蓋率 AA 算出，生成階段數值可±1）：
```
  0   0   0   0   0   0   0 255 255 255 255   0   0   0   0   0   0
  0   0   0   8 112 203 251 255 255 255 255 251 203 112   8   0   0
  0   0  24 211 255 255 255 255 255 255 255 255 255 255 211  24   0
  0   8 211 255 255 255 255 255 255 255 255 255 255 255 255 211   8
  0 112 255 255 255 255 255 255 255 255 255 255 255 255 255 255 112
  0 203 255 255 255 255 255 255 255 255 255 255 255 255 255 255 203
  0 251 255 255 255 255 255 255 255 255 255 255 255 255 255 255 251
255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255
255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255
255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255
255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255 255
  0 251 255 255 255 255 255 255 255 255 255 255 255 255 255 255 251
  0 203 255 255 255 255 255 255 255 255 255 255 255 255 255 255 203
  0 112 255 255 255 255 255 255 255 255 255 255 255 255 255 255 112
  0   8 211 255 255 255 255 255 255 255 255 255 255 255 255 211   8
  0   0  24 211 255 255 255 255 255 255 255 255 255 255 211  24   0
  0   0   0   8 112 203 251 255 255 255 255 251 203 112   8   0   0
```

### 3.2 `nb_round_border.png`
- PNG 17×17。內容 = 3.1 的外形 **減去** 內縮 1px、半徑 5 的圓角矩形（[1,15)×[1,15)），即 1px 描邊。直邊像素（x=0 / x=15 / y=0 / y=15 的非弧線段）alpha 精確 255，內部 alpha 0。
- 標記、切線、解析結果同 3.1（`{6,4,6}` / `{6,4,6}`）。
- 用途與 tint：面板外框 `BORDER`（在 `render()` 階段畫，蓋在子元件之上，同原生）、浮窗框 `BORDER`、Toast 框 `TOAST_BORDER`（×動畫 alpha）。

alpha 參考表：
```
  0   0   0   0   0   0   0 255 255 255 255   0   0   0   0   0   0
  0   0   0   8 112 203 251 255 255 255 255 251 203 112   8   0   0
  0   0  24 211 179  60   8   0   0   0   0   8  60 179 211  24   0
  0   8 211 112   0   0   0   0   0   0   0   0   0   0 112 211   8
  0 112 179   0   0   0   0   0   0   0   0   0   0   0   0 179 112
  0 203  60   0   0   0   0   0   0   0   0   0   0   0   0  60 203
  0 251   8   0   0   0   0   0   0   0   0   0   0   0   0   8 251
255 255   0   0   0   0   0   0   0   0   0   0   0   0   0   0 255
255 255   0   0   0   0   0   0   0   0   0   0   0   0   0   0 255
255 255   0   0   0   0   0   0   0   0   0   0   0   0   0   0 255
255 255   0   0   0   0   0   0   0   0   0   0   0   0   0   0 255
  0 251   8   0   0   0   0   0   0   0   0   0   0   0   0   8 251
  0 203  60   0   0   0   0   0   0   0   0   0   0   0   0  60 203
  0 112 179   0   0   0   0   0   0   0   0   0   0   0   0 179 112
  0   8 211 112   0   0   0   0   0   0   0   0   0   0 112 211   8
  0   0  24 211 179  60   8   0   0   0   0   8  60 179 211  24   0
  0   0   0   8 112 203 251 255 255 255 255 251 203 112   8   0   0
```

### 3.3 `nb_roundtop_fill.png`
- PNG 17×17。內容 = 上兩角半徑 6、下兩角直角的實心矩形 [0,16)×[0,16)；y ≥ 6 的每一列全 255。
- 標記：第 0 列 x=7..10（同上）；第 0 欄 **y=7..16 一路到底**（縱向拉伸區直達最底列，不留固定底列）。
- 解析結果：`widths = {6,4,6}`、`heights = {6,10,0}`（`hasBottomRow()=false`，底排 patch 高 0 直接略過，`:222`）。
- 用途與 tint：標題列疊色 `TITLEBAR_FILL`（新色票，見 §7）、頁籤選中 `TAB_SELECTED_FILL`、頁籤 hover `TAB_HOVER_FILL`。
- 最小繪製 12 寬 × 6 高。

### 3.4 `nb_roundtop_border.png`
- PNG 17×17。內容 = 3.3 外形減去內縮 1px（左右各 1、上 1、**下不內縮**）半徑 5 的同型：得到上弧＋左右直邊、**底邊開放**的 3 邊框。y ≥ 6 的每列 = x=0 與 x=15 為 255、其餘 0。
- 標記、解析結果同 3.3。
- 用途與 tint：每個頁籤的邊框 `BORDER`（選中／未選中都畫，與現況一致）。

### 3.5 `nb_dot.png`（選配，建議做）
- PNG 16×16，RGBA。內容 = 直徑 16 的實心圓，圓心 (8,8)，覆蓋率 AA；RGB 全 255（含透明像素——這張走 GL_LINEAR，黑色透明鄰居會混出黑邊）。**沒有標記列**（不是 9-slice）。
- 載入：`getTexture("media/ui/NoticeBoard/nb_dot.png")`，走 NBPanel 既有 `preflightImages` 的紀律（pcall＋nil＋不重試）。
- 繪製：`drawTextureScaled(tex, x-1, y-1, 10, 10, UNREAD_DOT_OUTLINE...)` 當光暈（放大 1.25 倍會微糊，正是光暈要的），再 `drawTextureScaled(tex, x, y, 8, 8, UNREAD_DOT...)`。16→8 是 2:1 縮小，GL_LINEAR 剛好每像素平均 2×2 texel，邊緣乾淨。
- 退回：nil 時維持現在的方點（`drawRect`＋`drawRectBorder`）。

---

## 4. 生成規則（給生成階段）

1. 格式：PNG，8-bit RGBA（colortype 6），非交錯，不用調色盤／灰階／16-bit；不要 APNG。sRGB/gAMA chunk 有無皆可（引擎 PNGDecoder 直接讀原始 alpha）。
2. 所有像素 RGB = (255,255,255)，包含 alpha=0 的像素與標記像素。
3. 弧線：以覆蓋率 AA 生成（8×8 超取樣或解析式），形狀定義見各節：外形 = 內容矩形的圓角矩形（半徑 6，圓心在距角 (6,6) 的像素格點）；邊框 = 外形 − 內縮 1px 半徑 5 的同型。
4. 直線段 alpha 精確 0 或 255（矩形對齊像素邊界自然如此）；驗證：內容區 x=6..9 每一欄逐像素相同、y=6..9（roundtop 為 y=6..15）每一列逐像素相同。
5. 標記只在 PNG 第 0 列與第 0 欄；(0,0) 透明；**右邊與底邊不得有標記**。標記像素 alpha 用 255（門檻是 ≥128）。
6. 生成後用與 `NinePatchTexture.setImageData:262-298` 同邏輯的腳本反解析，確認 `{6,4,6}/{6,4,6}`（round）與 `{6,4,6}/{6,10,0}`（roundtop）——scratchpad 已有 `ninepatch_sim.py` 可直接改成讀 PNG。
7. 檔案放 `42/media/ui/NoticeBoard/`；`verify_mod.py` 對此目錄沒有特別檢查（只掃 .omc/.claude/.gitnexus 雜物），但 Workshop 上傳整包，別留 .psd／草稿。

---

## 5. 套用方式（版面座標一律不動，只換繪製呼叫）

建議新增一個 client 端小工具 `lua/client/NoticeBoard/NBSkin.lua`，三個 UI 檔都改呼叫它，貼圖路徑與預檢只寫一次：

```
NBSkin.fill(el, x, y, w, h, color[, topOnly[, alphaScale]])   -- 有貼圖: npt:render(floor(absX+x), floor(absY+y), w, h, r,g,b,a); 沒有: el:drawRect(x,y,w,h,a,r,g,b)
NBSkin.border(el, x, y, w, h, color[, topOnly[, alphaScale]]) -- 同上，退回 el:drawRectBorder
NBSkin.fits(w, h, topOnly)                       -- 純函式：矩形任一邊短於兩個角落之和（四角圓 12x12、上圓下直 12x6）→ false，fill/border 直接走退回（不縮放角落、不讓角落重疊）
NBSkin.dot(el, x, y, size, color, outlineColor) -- 有貼圖: 兩次 drawTextureScaled；沒有: 現在的 drawRect+drawRectBorder 方點
```
預檢協定（放在 lazy 首次繪製或 `ensureInstance` 之後，**不要**在檔案載入期呼叫）：
- `NinePatchTexture` 全域不存在（harness／dedicated／舊版）→ 全部退回。
- 存在：對每個路徑 `pcall(NinePatchTexture.getSharedTexture, path)` **兩次**，取第二次；nil 或 pcall 失敗 → 該貼圖標為壞（session 內不再試，反正已進黑名單）。
- render 包 pcall；一旦丟錯（理論上只有 PNG 損毀會 NPE，`:223` `this.texture` 為 null）→ 該貼圖標為壞、之後走退回。
- 測試 harness（`scripts/test_nbpanel.lua`）：`_G.require` 全回 nil，所以要嘛 harness 直接 `dofile` NBSkin.lua（讓退回路徑跑到 Base 的 drawRect stub），要嘛 stub `_G.NBSkin`。建議前者，並額外 stub 一個 `_G.NinePatchTexture` 記錄 `render` 落點，比照現有 `drawTextureScaled` 攔截驗幾何。

### 5.1 NBPanel（`ISCollapsableWindowJoypad` 派生）
`prerender` 與 `render` **整段覆寫**、不再呼叫父類版本（父類 `ISCollapsableWindow.lua:152-177` / `:179-204` 各約 20 行，照抄順序、只換繪製呼叫；別用 `drawFrame=false` 的旗標繞路，那會連標題文字、resize 列一起關掉且語意外溢）。

| 位置 | 原生／現況呼叫 | 新呼叫 | 備註 |
|---|---|---|---|
| 面板底（含標題列範圍） | 父類 `drawRect(0,0,w,th,bg)` + `drawRect(0,th,w,h-th,bg)`（`:159,:166`） | `NBSkin.fill(self, 0, 0, w, H, BG_PANEL)` 一次畫滿 | `H = isCollapsed and th or height`（鏡射 `:155-157`）；`BG_PANEL` 要補進 NBPanel 的 COLORS |
| 標題列質感 | `drawTextureScaled(titlebarbkg, 2, 1, w-4, th-2)`（`:160`） | `NBSkin.fill(self, 0, 0, w, th, TITLEBAR_FILL, not isCollapsed)` | 上圓下直，弧線與面板底重合；收合時面板只剩這一條、改四角圓（否則下兩角的直角從面板底弧線外露出）；`Panel_TitleBar.png` 不再用 |
| 標題列下緣線 | `drawRectBorder(0,0,w,th,border)`（`:161`） | `if not isCollapsed then drawRect(0, th-1, w, 1, BORDER) end` | 只要分隔線；外框由 3.2 統一畫；收合時外框就是底線（原版 drawRect 有 isCollapsed 守衛 ISUIElement.lua:1191-1197，這裡寫明） |
| 標題文字 | `drawTextCentre(title, w/2, 1, ...)`（`:174`） | 不變 | |
| stencil | `setStencilRect(0,0,w,H)`（`:170`）／`clearStencilRect()`（`:194`） | 不變 | NinePatch 走同一佇列，會被裁。頁籤區巢狀 stencil 收尾：`clearStencilRect()` 後 **`repaintStencilRect(0, tabY, tabAreaWidth, tabHeight)`**（UIElement.java:1928-1940，原版 ISRichTextPanel.lua:688-690），不可再 set 一次——`stencilLevel` 是 static、只在 UIManager.render 開頭歸零（UIManager.java:274），set/clear 不成對每幀淨 +1，render 的 clear 回不到 0 → 外框畫不出來、同幀之後的 alwaysOnTop 元件（浮窗／Toast）被 stencil 整個擋掉 |
| 底部 resize 列 | `drawRectBorder(0,H-rh,w,rh)` + `drawTextureScaled(statusbarbkg,...)` + `drawTextureScaled(resizeimage, w-rh+1, H-rh+1, rh-2, rh-2)`（`:187-190`） | `drawRect(0, H-rh, w, 1, BORDER)` + `drawTextureScaled(resizeimage, w-rh+1, H-rh+1, rh-4, rh-4, 1,1,1,1)` | 條件同原生（`not isCollapsed and resizable and drawFrame and resizeWidget:getIsVisible()`）；`Panel_StatusBar.png` 不再用；把手圖示原位（分隔線下方 1px）、邊長縮 2px 讓三角形直角落在弧線內（原尺寸的角會壓到邊框弧；若改成整個圖示左上挪 2px，三角尖端會穿到分隔線上方 1px） |
| 面板外框 | `drawRectBorder(0,0,w,H,border)`（`:197`，render 階段） | `NBSkin.border(self, 0, 0, w, H, BORDER)` | 仍在 render 階段、子元件之後 |
| Joypad focus | `drawRectBorder` ×2（`:200-203`） | 不變 | 直角藍框，出現頻率低，不值得多一張貼圖 |
| 頁籤列底 | `drawRect(0, tabY, w, tabHeight, TAB_TRAY_BG)`（NBPanel:1040） | 不變，**再加** `drawRect(0, tabY+tabHeight-1, tabAreaWidth(), 1, BORDER)` 當軌道線 | 軌道線在 stencil 前畫、頁籤之前畫 |
| 頁籤填色 | `drawRect(tab.x, tabY, tab.width, tabHeight, TAB_SELECTED_FILL / TAB_HOVER_FILL)`（:1057,:1061） | `NBSkin.fill(self, tab.x, tabY, tab.width, tabHeight, 同色, true)` | 上圓下直 |
| 頁籤框 | `drawRectBorder(tab.x, tabY, tab.width, tabHeight, BORDER)`（:1066） | `NBSkin.border(self, tab.x, tabY, tab.width, tabHeight, BORDER, true)` | 3 邊框，底邊開放落在軌道線上；相鄰頁籤仍是 2px 雙線（現況亦然） |
| 頁籤文字 | `drawTextCentre(..., tabY+3, ...)`（:1070） | 不變 | |
| 選中底線 | `drawRect(tab.x, tabY+tabHeight-2, tab.width, 2, ACCENT_AMBER)`（:1075） | 不變 | 剛好蓋掉軌道線那 2 列 → 選中頁籤與內容相連 |
| 頁籤未讀點 | `drawRect(tab.x+tab.width-8, tabY+2, 6, 6)` + `drawRectBorder`（:1082-1085） | `NBSkin.dot(self, tab.x+tab.width-10, tabY+2, 8, UNREAD_DOT, UNREAD_DOT_OUTLINE)` | 左移 2px、放大到 8：圓心正好落在右上弧的圓心 (right-6, +6)，半徑 4 < 邊框內緣 5，不壓到弧線；仍在 stencil 內 |
| 錯誤區塊 | `drawRect(10, blockY, w-20, 48, ERROR_BG)`（:1105） | `NBSkin.fill(self, 10, blockY, w-20, 48, ERROR_BG)` | 四角圓；文字不變 |
| 同步中／逾時／空 占位文字 | 不變 | 不變 | |

繪製順序（prerender）：面板底 → 標題疊色 → 標題下緣線 → stencil → 標題文字 → 頁籤列（tray → 軌道線 → stencil(tabs) → 每頁籤 fill/border/text/underline/dot → clear → repaint(tabs)）→ 占位／錯誤區塊。（render）：resize 列 → clear stencil → 外框 → joypad focus。收合（`isCollapsed`）時 prerender 只到標題文字為止（不畫分隔線、不呼叫 drawTabs／drawContentPlaceholder），render 只剩 clear stencil → 外框。

### 5.2 NBFloatButton（40×40）
| 現況（`NBFloatButton.lua:35-61`） | 新 |
|---|---|
| `drawRect(0,0,w,h,BG_PANEL)` | `NBSkin.fill(self,0,0,w,h,BG_PANEL)` |
| hover `drawRect(0,0,w,h,TAB_HOVER_FILL)` | `NBSkin.fill(self,0,0,w,h,TAB_HOVER_FILL)` |
| `drawRectBorder(0,0,w,h,BORDER)` | `NBSkin.border(self,0,0,w,h,BORDER)` |
| `drawTextCentre("!", ...)` | 不變 |
| 未讀點 `drawRect(w-8,-2,8,8)`＋描邊 | `NBSkin.dot(self, w-8, -2, 8, UNREAD_DOT, UNREAD_DOT_OUTLINE)`，位置不變——徽章壓在右上弧上是刻意的「掛角」擺法（UI_DESIGN §2） |

拖曳、點擊、位置記憶完全不動。維持四角圓的方鈕，不做正圓（正圓要 r=20 另一組貼圖，與面板語彙也不一致）。

### 5.3 NBToast（300×56）
| 現況（`NBToast.lua:153-160`） | 新 |
|---|---|
| `drawRect(0,0,w,h, TOAST_BG.a*alpha, ...)` | `NBSkin.fill(self,0,0,w,h, TOAST_BG, false, alpha)`（第 7 個參數是 `topOnly`，動畫 alpha 走第 8 個 `alphaScale`；漏掉 `false` 會把 alpha 當 topOnly → 拿到上圓下直貼圖且 alpha=1） |
| `drawRectBorder(0,0,w,h, TOAST_BORDER.a*alpha, ...)` | `NBSkin.border(self,0,0,w,h, TOAST_BORDER, false, alpha)` |
| 兩行文字 | 不變 |

動畫期間 `setX/setY` 是小數：helper 內 `math.floor(absX+x)`／`floor(absY+y)` 必做（§1.1）。

---

## 6. 與現有版面的相容確認

- `titleBarHeight()`、`tabY`、`tabHeight`、`contentY`、richText 的 rect 與 margins、三顆 ISButton 的 rect、`tabAreaWidth()`、`tabAt()`／`onMouseDown/Up` 的判定區：**一個數字都不動**。圓角只改變四個角落 6×6 內的像素。
- 上兩角落在標題列內（th ≥ 16 > 6）：關閉鈕在 (1,1,th-2,th-2)，其 `backgroundColor.a=0`／`borderColor.a=0`／`backgroundColorMouseOver.a=0`（`ISCollapsableWindow.lua:57-59`），只畫置中的小圖示，圖示本體不到角落像素 → 不會露出直角；釘選／收合鈕同理（`:76-89`）。
- 下兩角落在 resize 列內（rh = FONT_HGT_SMALL/2+5 ≈ 13 > 6）：richText 底部在 `height - rh`，碰不到弧線；左右邊緣直邊處 richText 到 x=0..w，外框在 render 階段蓋上（同原生）。`ISResizeWidget` 本身不畫任何東西，可拖區不變。把手圖示縮 2px 只是視覺，`resizeWidget` 的 rect 不變。
- 頁籤列橫跨全寬 x=0..w，y ≥ th ≥ 16 → 在直邊段，與圓角無交集。
- 頁籤 stencil `setStencilRect(0, tabY, tabAreaWidth(), tabHeight)`：NinePatch 走同一命令佇列，被裁切行為與 drawRect 相同（在遊戲內確認：捲動時最右頁籤被按鈕遮住的情境）。
- 縮到最小 420×260：所有 9-slice 呼叫的寬高遠大於 12；標題列 collapsed 時高 th ≥ 16 也 ≥ 12。
- 字型放大（`getOptionFontSizeReal`）讓 th／tabHeight 變大：半徑固定 6px，比例上更不顯眼，無風險。

---

## 7. 色票增補（與 UI_DESIGN §0 同格式）

| Token | r | g | b | a | 用途 | 出處/依據 |
|---|---|---|---|---|---|---|
| `TITLEBAR_FILL` | 1 | 1 | 1 | 0.10 | 標題列疊色（畫在 `BG_PANEL` 面板底之上、`nb_roundtop_fill`） | 新增：取代原生 `Panel_TitleBar.png` 灰階漸層（直角條與 r=6 相衝）。與 `TAB_SELECTED_FILL`(0.12)／`TAB_HOVER_FILL`(0.06) 同屬白色疊層族；0.10 讓標題列比面板底亮、比選中頁籤（在更暗的 `TAB_TRAY_BG` 上）稍暗，維持「標題列 > 頁籤列凹槽 > 選中頁籤跳出」的層次 |

既有 token 需補進程式碼的：`BG_PANEL`（0,0,0,0.8）目前只在 UI_DESIGN §0 與 NBFloatButton 的 COLORS 副本裡，NBPanel 一直靠父類 `self.backgroundColor` 畫底——覆寫 prerender 後 NBPanel 的 COLORS 要補 `BG_PANEL`。其餘全部沿用：`BORDER`、`TAB_TRAY_BG`、`TAB_SELECTED_FILL`、`TAB_HOVER_FILL`、`ACCENT_AMBER`、`UNREAD_DOT`、`UNREAD_DOT_OUTLINE`、`ERROR_BG`、`TOAST_BG`、`TOAST_BORDER`。

（已落地）COLORS 已搬進 `NBSkin.COLORS` 當唯一來源，NBPanel／NBFloatButton／NBToast 三檔皆 `local COLORS = NBSkin.COLORS`，不再各自複製。

---

## 8. UI_DESIGN.md 需改動的章節

| 章節 | 改什麼 |
|---|---|
| 開頭「設計基調」 | 「不做卡片式圓角」→ 改為「小半徑（6px）圓角、平面染色，不做漸層／模糊」；效果限定清單加入 `NinePatchTexture`（引擎原生 9-slice）與自帶白色貼圖 |
| §0 色票表 | 加 `TITLEBAR_FILL` 一列（§7）；表尾註「標題列底圖沿用原生 `Panel_TitleBar.png` … 不重繪」→ 改為「標題列與底部 resize 列改平面染色，`Panel_TitleBar.png`／`Panel_StatusBar.png` 不再使用；`ResizeIcon.png` 沿用、內縮 2px」 |
| §1.1 基底與骨架 | 標題列一段補「疊色 `TITLEBAR_FILL`、上兩角 r=6」；頁籤列一段「改用 drawRect＋drawRectBorder 全自繪」→ 「改用 `nb_roundtop_*` 9-slice 染色 + drawRect 底線」；補一句 prerender/render 整段覆寫、順序見本文件 §5.1 |
| §1.2 頁籤 | 形狀改為上圓下開放 3 邊框＋軌道線；填色／hover／選中／底線／分隔線各點對照 §5.1 更新；「頁籤之間 1px BORDER 分隔線」→ 改為各自 3 邊框（相鄰 2px，現況亦然） |
| §1.3 未讀紅點 | 「方點是唯一零新增資源的解法…圓點選配」→ 圓點成為預設（`nb_dot.png`），方點降為退回路徑；頁籤點座標改 (right-10, +2) 8×8 |
| §1.4 尺寸建議 | 無數值變動；補一句「所有 9-slice 呼叫最小 12×12，最小尺寸 420×260 遠大於此」 |
| §2 浮窗 | 外觀一段：`drawRect`＋`drawRectBorder` → `nb_round_fill/border` 四角 r=6；紅點改圓形貼圖 |
| §3 Toast | 配色一段：背景／邊框改 `nb_round_fill/border`，alpha 乘數不變；補「動畫座標 floor」 |
| §6.2 錯誤占位頁 | 色塊改四角圓（`nb_round_fill` × `ERROR_BG`） |
| §6.5 浮窗示意 | 圖示更新為圓角＋圓點 |
| 落地檢查清單 | 「只用 drawRect/drawRectBorder/drawTextureScaled/drawText(Centre)+UITransition，不引入新繪圖 API」→ 加上 `NinePatchTexture.getSharedTexture/render`（附 AGENTS.md 出處）；新增一條「任一貼圖載入失敗必退回 drawRect 路徑，harness 無 `NinePatchTexture` 時 test_nbpanel 仍全綠」 |

---

## 9. 已同步的其他文件

- `AGENTS.md` API 出處對照表新增兩列：`NinePatchTexture.getSharedTexture / render`（含首呼叫回 null、黑名單、絕對座標、標記解析、GL_NEAREST 等出處）與 `ISUIElement:drawTextureScaled` 染色路徑（`DrawTextureScaledColor:497 → DrawTextureScaledCol:469-483`）。
