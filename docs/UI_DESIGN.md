# UI 設計方向 — MinidoracatNoticeBoardFor42

依據 `.omc/plans/ralplan-noticeboard.md`（NBPanel/NBFloatButton/NBToast、彈窗決策、未讀紅點）與 PZ B42 原生視覺語言（`SurvivalGuide.lua`、`ISUI/ISCollapsableWindow.lua`、`ISUI/ISTabPanel.lua`、`ISUI/ISRichTextPanel.lua`）撰寫。全部效果限定 ISUI 既有 API：`drawRect` / `drawRectBorder` / `drawTextureScaled` / `drawText(Centre)` / `ISButton` / `ISRichTextPanel` / `UITransition`，加上引擎原生 9-slice `NinePatchTexture`（`zombie/core/textures/NinePatchTexture.java`，出處與坑見 AGENTS.md API 表）配 MOD 自帶的白色圓角貼圖（`media/ui/NoticeBoard/`，規格見 `docs/UI_SKIN_TEXTURES.md`）；不新增自訂 shader、不假設引擎沒有的模糊效果。

設計基調：延續原生「深色半透明公告板」語彙（黑底高透明度＋淺灰細邊框），小半徑（6px）圓角、平面染色，不做漸層／模糊，貼合 PZ 廢土求生的樸素工具面板風格。琥珀色（amber）作為公告板慣用的警示膠帶/圖釘意象，僅用於少量強調點（粗體、Toast 邊框、未讀強調），不大面積使用。

圓角的實作集中在 `lua/client/NoticeBoard/NBSkin.lua`（`fill`／`border`／`dot` 三個 helper＋色票 `NBSkin.COLORS`）：貼圖第一次繪製時才載入（pcall＋nil 檢查、失敗永不重試），**任一貼圖缺失或引擎沒有 `NinePatchTexture` 時一律退回原本的 `drawRect`／`drawRectBorder` 直角畫法**，版面與功能零差異。

---

## 0. 色票總表（全篇色彩的唯一權威來源）

r,g,b,a 皆為 0–1 浮點，對應 PZ 所有 draw 系 API 的參數格式。命名供後續章節引用。

| Token | r | g | b | a | 用途 | 出處/依據 |
|---|---|---|---|---|---|---|
| `BG_PANEL` | 0 | 0 | 0 | 0.8 | 主面板背景 | `ISCollapsableWindow:new` 預設 `backgroundColor`（ISCollapsableWindow.lua:374） |
| `BORDER` | 0.4 | 0.4 | 0.4 | 1.0 | 面板/分隔線/未選取邊框 | `ISCollapsableWindow:new` 預設 `borderColor`（:373）、`ISTabPanel:new`（:622） |
| `TITLE_TEXT` | 1 | 1 | 1 | 1.0 | 標題列文字 | `ISCollapsableWindow:prerender` `drawTextCentre(self.title,...,1,1,1,1,...)`（:174） |
| `TITLEBAR_FILL` | 1 | 1 | 1 | 0.10 | 標題列疊色（畫在 `BG_PANEL` 面板底之上、`nb_roundtop_fill` 上圓下直） | 取代原生 `Panel_TitleBar.png` 灰階漸層（直角條與 r=6 相衝）。與 `TAB_SELECTED_FILL`(0.12)／`TAB_HOVER_FILL`(0.06) 同屬白色疊層族；0.10 讓標題列比面板底亮、比選中頁籤（在更暗的 `TAB_TRAY_BG` 上）稍暗 |
| `TAB_TRAY_BG` | 0 | 0 | 0 | 0.5 | 頁籤列背景（比面板底稍淺，做出「凹槽」層次） | 對照 `SurvivalGuide.listBox.backgroundColor`（SurvivalGuide.lua:46） |
| `TAB_SELECTED_FILL` | 1 | 1 | 1 | 0.12 | 選中頁籤填色（疊在 BORDER 之上） | 自訂，弱化版白色高亮，避免刺眼 |
| `TAB_HOVER_FILL` | 1 | 1 | 1 | 0.06 | 滑鼠懸停頁籤填色 | 自訂，比選中更淡 |
| `TAB_TEXT_SELECTED` | 1 | 1 | 1 | 1.0 | 選中頁籤文字 | 同 TITLE_TEXT |
| `TAB_TEXT_UNSELECTED` | 0.7 | 0.7 | 0.7 | 1.0 | 未選中頁籤文字 | `ISRichTextPanel` `TEXT` 指令預設灰（ISRichTextPanel.lua:50-52） |
| `ACCENT_AMBER` | 1 | 0.85 | 0.4 | 1.0 | 強調色（粗體、Toast 邊框、admin 按鈕圖示） | 與 MDParser 粗體映射 `<PUSHRGB:1,0.85,0.4>` 同值（ralplan 表格） |
| `LINK` | 0.45 | 0.75 | 1.0 | 1.0 | 連結文字 | 自訂：與 amber/red 區隔的冷色，暗底上清楚可讀 |
| `LINK_HOVER` | 0.65 | 0.85 | 1.0 | 1.0 | 連結 hover（加亮＋底線） | 自訂 |
| `UNREAD_DOT` | 0.85 | 0.15 | 0.15 | 1.0 | 未讀紅點主色 | 自訂：PZ「壞/警示」語彙的飽和紅（對照 RichText `RED` 指令 `1,0,0`，此處降飽和避免過刺眼） |
| `UNREAD_DOT_OUTLINE` | 0 | 0 | 0 | 0.6 | 未讀紅點描邊，確保任何背景下可辨識 | 自訂 |
| `ERROR_BG` | 0.3 | 0.05 | 0.05 | 0.5 | 錯誤占位頁背景色塊 | 自訂，暗紅低飽和 |
| `ERROR_TEXT` | 0.9 | 0.35 | 0.3 | 1.0 | 錯誤占位頁文字 | 自訂 |
| `PLACEHOLDER_TEXT` | 0.55 | 0.55 | 0.55 | 1.0 | 缺圖 `[alt]` 占位文字（中性灰，非錯誤語氣） | 比 TAB_TEXT_UNSELECTED 略暗，區隔「純提示」與「錯誤」 |
| `TOAST_BG` | 0 | 0 | 0 | 0.85 | Toast 背景 | 比 BG_PANEL 更不透明，蓋在遊戲畫面上仍需可讀 |
| `TOAST_BORDER` | 1 | 0.85 | 0.4 | 0.9 | Toast 邊框（=ACCENT_AMBER，略降 a） | 與強調色一致，讓玩家一眼認出「這是公告通知」 |
| `SCROLLBAR_TRACK` | 0 | 0 | 0 | 0.4 | 內容區捲軸軌道（若需自繪，多數情況用 `addScrollBars()` 內建即可） | 對照 BG_PANEL 系列降階 |

> 色票在程式碼裡的唯一來源是 `NBSkin.COLORS`（NBPanel／NBFloatButton／NBToast 都引用它，不各自複製）。標題列與底部 resize 列改為平面染色：原生 `Panel_TitleBar.png`／`Panel_StatusBar.png` 不再使用（兩張都是直角條，塞進 r=6 的角會露角）；`ResizeIcon.png` 沿用原位、邊長縮 2px（`rh-4`，留在 resize 列內、直角在弧線內）。關閉／釘選／收合鈕、三顆 ISButton、捲軸仍是原生鉻件不換皮。

---

## 1. 主面板（NBPanel）

### 1.1 基底與骨架
繼承 `ISCollapsableWindowJoypad`（`SurvivalGuide.lua:1` 同基底），沿用原生標題列鉻件：左上關閉鈕、右上收合/釘選鈕（`ISCollapsableWindow:createChildren`，:55-91）——**不重繪、不隱藏**，這些是玩家熟悉的既有操作。

垂直佈局（由上而下）：
```
┌───────────────────────────────────────────┐
│ [X]        公告欄標題（原生標題列）    [釘][收合] │  titleBarHeight()
├───────────────────────────────────────────┤
│ 綜合公告 ●  維修通知    活動   規則        │  頁籤列（本 MOD 自繪）
├───────────────────────────────────────────┤
│                                    [重新載入]│  admin 工具列（僅 admin 可見，條件實例化）
├───────────────────────────────────────────┤
│                                             │
│         ISRichTextPanel 內容區＋捲軸        │
│                                             │
└───────────────────────────────────────────┘
```

- **面板底與外框**：`prerender`／`render` 整段覆寫、不再呼叫父類版本（父類 ISCollapsableWindow.lua:152-177 / :179-204 畫的是直角底＋直角貼圖條），順序與父類逐行對應、只換繪製呼叫：面板底一次畫滿 `NBSkin.fill(0,0,w,H, BG_PANEL)`（四角 r=6，`nb_round_fill`）；外框在 render 階段、子元件之後 `NBSkin.border(0,0,w,H, BORDER)`（`nb_round_border`）；底部 resize 列只留上緣 1px `BORDER` 分隔線＋原位、邊長 `rh-4` 的 `ResizeIcon.png`。stencil 範圍、`titleBarHeight`／`resizeWidgetHeight` 數字一個都不動（`scripts/test_nbpanel.lua` 用字面數字釘住 richText rect）。**stencil 收支必須成對**：頁籤區的巢狀 stencil 畫完後 `clearStencilRect()` 再 `repaintStencilRect(0, tabY, tabAreaWidth, tabHeight)` 還回父層（UIElement.java:1928-1940；原版 ISRichTextPanel.lua:688-690 同款），不可再 `setStencilRect` 一次——`stencilLevel` 是 static、只在 UIManager.render 開頭歸零（UIManager.java:274），每幀淨 +1 會讓 render 的 clear 回不到 0：外框畫不出來、同幀之後的 alwaysOnTop 元件（浮窗／Toast）整個被 stencil 擋掉。**收合（isCollapsed）時**面板只剩標題列一條：面板底與外框都是四角圓、`TITLEBAR_FILL` 疊色也改四角圓（`topOnly = not isCollapsed`，否則下兩角的直角從弧線外露出）、不畫分隔線、不呼叫 `drawTabs`／`drawContentPlaceholder`（原版 `drawRect`／`drawTextCentre` 靠 `isCollapsed` 守衛不畫，ISUIElement.lua:1191-1197,:1280-1284；9-slice 沒有那道守衛，得自己跳過）。
- **標題列**：高度 = `titleBarHeight()` = `math.max(16, titleFontHgt+1)`（ISCollapsableWindow.lua:298-300），`titleFont = UIFont.Small`。面板底之上疊一層 `TITLEBAR_FILL`（`nb_roundtop_fill`，上兩角 r=6 與面板底弧線重合），下緣 1px `BORDER` 分隔線。標題文字用 `IGUI_MinidoracatNB_PanelTitle`（i18n），置中，色 `TITLE_TEXT`。上兩個圓角落在關閉／釘選鈕範圍內，但那些鈕的背景／邊框 alpha 為 0（ISCollapsableWindow.lua:57-59,76-89），只畫置中小圖示，不會露出直角。
- **頁籤列**：高度固定 `getTextManager():getFontHeight(UIFont.Small) + 6`（比照 `ISTabPanel:new` 的 `tabHeight` 公式，ISTabPanel.lua:642），y 起點 = `titleBarHeight()`。**不沿用 `ISTabPanel` 的貼圖式選中/未選中材質**（`tab_selected.png`/`tab_unselected.png`），因為未讀紅點需要疊在頁籤上，改用 `nb_roundtop_*` 9-slice 染色（`NBSkin.fill/border(..., topOnly=true)`）＋ `drawRect` 軌道線／底線＋ `drawTextCentre` 全自繪（見 1.2），保留座標運算邏輯（等寬或依文字寬 `MeasureStringX + padding` 兩者皆可，建議等寬簡化紅點定位）。
- **admin 重新載入鈕**：**放在頁籤列右端同一行**（原設計的獨立工具列改掉了：單一按鈕撐開整列會留下大片空白、看起來像壞掉的工具列，也白佔內容高度）。頁籤可用寬度須扣掉按鈕寬（`NBPanel:tabAreaWidth()`），否則頁籤會捲到按鈕底下被蓋住。**只有 client 端 `getPlayer():getAccessLevel()` 判定為 admin/moderator 時才建立**（不只是隱藏，直接不 `addChild`，避免非 admin 誤按；server 端 `OnClientCommand` 仍要重驗，見 ralplan 網路協定表）。非 admin 玩家此行完全不佔版面，內容區直接從頁籤列下緣開始。
- **內容區**：`ISRichTextPanel`＋`addScrollBars()`（同 `SurvivalGuide.descriptionRichText` 手法，SurvivalGuide.lua:65-73），`autosetheight=false`、`clip=true`、`doRepaintStencil=true`，`setMargins(10+scrollbarWid, 10, 10+scrollbarWid, 0)`，`scrollbarWid=13`（同上出處 :63）。**左右邊界刻意對稱**：引擎的置中算在 `[marginLeft, width-marginRight]` 之間（`ISRichTextPanel.lua:649`），右邊多預留捲軸寬而左邊沒有時，`#` 標題與 `<CENTRE>` 的中心恆偏左 `(marginRight-marginLeft)/2`，與標題列的 `drawTextCentre(title, width/2)` 差 6.5px、肉眼看得出兩行標題沒對齊。代價是左側留白 23 而非 10。

### 1.2 頁籤（單頁籤視覺規格）
- 形狀：上兩角 r=6、底邊開放的「站在軌道上的頁籤」。整列先畫 `TAB_TRAY_BG` 底，再在 `tabY+tabHeight-1` 畫 1px `BORDER` 軌道線（寬 = `tabAreaWidth()`），每個頁籤各自一個 3 邊框 `NBSkin.border(x, tabY, w, tabHeight, BORDER, true)`（`nb_roundtop_border`；相鄰頁籤之間仍是 2px 雙線，與換皮前一致）。
- 未選中：只有 3 邊框 + 文字 `TAB_TEXT_UNSELECTED`（灰）。
- Hover：疊一層 `NBSkin.fill(..., TAB_HOVER_FILL, true)`。
- 選中：疊一層 `NBSkin.fill(..., TAB_SELECTED_FILL, true)` + 文字改 `TAB_TEXT_SELECTED` + 底部一條 2px `ACCENT_AMBER` 底線（`drawRect(x, tabY+tabHeight-2, tabWidth, 2, ACCENT_AMBER)`），剛好蓋掉軌道線那 2 列 → 選中頁籤與內容區「相連」，作為「這是目前頁」的強對比視覺錨點。不整塊染琥珀（amber 只做強調點，見設計基調）。
- 超出寬度時捲動手感沿用 `ISTabPanel:ensureVisible` / `smoothScrollX` 邏輯（ISTabPanel.lua:15-45），不必重新發明平滑捲動公式；stencil 一樣裁得到 9-slice（`NinePatchTexture.render` 與 UIElement 走同一個 SpriteRenderer 命令佇列）。

### 1.3 未讀紅點（頁籤上）
- 位置：頁籤右上角，`NBSkin.dot(tabRight - 10, tabY + 2, 8, UNREAD_DOT, UNREAD_DOT_OUTLINE)`：8×8 圓點的圓心 (right-6, +6) 正好是右上弧的圓心，半徑 4 小於邊框內緣 5，不壓弧線。
- 圓點是預設：MOD 自帶 `nb_dot.png`（16×16 白色正圓，`getTexture`＋`drawTextureScaled` 染色），先畫放大一圈（10×10）的 `UNREAD_DOT_OUTLINE` 光暈再疊 8×8 主點；貼圖載不到時退回方點（`drawRect`＋`drawRectBorder`，同座標同尺寸）。
- 該頁籤讀取後（切到該頁即寫回 ReadState）紅點立即移除，不做淡出動畫（狀態切換是離散事件，不需要過場）。

### 1.4 尺寸建議
| 項目 | 數值 | 依據 |
|---|---|---|
| 預設寬 × 高 | 螢幕 62% × 80%，上限 1280 × 960、與螢幕邊留 80、下限 420 × 260（`NBPanel.defaultSize()`；1920×1080 → 1190 × 864；早期固定 820×600 與 620×460 都偏小，比例 52%×68%（998×734）在有圖的公告上仍是一開就得手動拉大） | 依螢幕等比，4K 不會變成小方塊、1080p 也不會滿版；1190 寬扣掉左右各 23（margin 10＋捲軸 13，對稱）後文字寬約 1144，單行仍可讀，864 高約 29 行內文 |
| 最小寬 | 420 px | 需 ≥ `minTitleBarWidth()`（關閉/釘選鈕＋標題文字，ISCollapsableWindow.lua:306-324）＋至少 2 個頁籤不重疊的下限，取整數留餘裕 |
| 最小高 | 260 px | 標題列＋頁籤列（含 admin 鈕）＋至少 3 行內文可讀高度 |
| 可縮放 | 是（`resizable = true`），縮放把手沿用原生 `ISResizeWidget`（ISCollapsableWindow.lua:32-49） |
| 位置記憶 | `RestoreLayout`/`SaveLayout` 沿用 `ISLayoutManager.DefaultRestoreWindow`/`DefaultSaveWindow`（ISCollapsableWindow.lua:336-354），與原生視窗同套機制，不自建存檔格式 |
| 9-slice 最小尺寸 | 四角圓 12×12、上圓下直 12×6（角落 6px）；比這小的矩形 `NBSkin` 直接退回直角 `drawRect`（引擎會讓角落重疊、縮放又會糊）。最小視窗 420×260、最矮標題列 16、最窄頁籤 80 都遠大於此 |

---

## 2. 浮窗（NBFloatButton）

- **尺寸**：40 × 40 px 正方形圖示鈕（比原生標題列鈕大一級，因為要獨立浮在畫面上被辨識，且要容納右上角紅點不擠壓圖示本體）。
- **外觀**：沿用面板同款鉻件語彙——`NBSkin.fill(0,0,w,h, BG_PANEL)` 底 + hover 疊 `TAB_HOVER_FILL` + `NBSkin.border(0,0,w,h, BORDER)` 邊框（四角 r=6，與面板同一組 `nb_round_*` 貼圖；維持四角圓的方鈕、不做正圓——正圓要另一組 r=20 貼圖，與面板語彙也不一致），中央疊一張 MOD 自帶的單色圖示貼圖（建議「公告板/圖釘」剪影，白色單色，`drawTextureScaled` 上色即可換色，不必做多套材質）。若暫無自製圖示，退而求其次用 `drawTextCentre("!", ...)`（`UIFont.Medium`，置中）純文字圖示頂上，之後再補真圖示，不阻塞開發。
- **紅點**：位置與規格同 1.3（`NBSkin.dot`，圓點＋光暈），釘在按鈕右上角外緣：`NBSkin.dot(width-8, -2, 8, UNREAD_DOT, UNREAD_DOT_OUTLINE)`，讓紅點「掛」在方塊的右上弧上，是最常見的通知徽章擺法。只要任一頁有未讀內容即顯示（不分頁籤加總數字，數字徽章需要額外排版邏輯，未讀/已讀二元狀態已足夠傳達「有新東西」）。
- **拖曳手感**：完全比照 `ISCollapsableWindow` 的拖動實作（ISCollapsableWindow.lua:206-280）——`onMouseDown` 記錄 `downX/downY`、設 `self.moving=true`、`bringToTop()`；`onMouseMove` 期間依 `dx,dy` 更新 `setX/setY`；`onMouseUp` 清 `moving`。點擊（mouseDown 後未發生 `onMouseMove` 就 mouseUp）視為「開/關面板」；一旦收到 `onMouseMove` 事件即判定為拖曳，不觸發開面板——避免拖曳結束時誤觸開面板。
- **位置持久化**：`ISLayoutManager.RegisterWindow`（沿用原生視窗位置記憶機制，同面板 1.4 出處），重開遊戲後浮窗停在玩家上次拖放的位置；預設初始位置建議螢幕右側中段（`getScreenWidth()-56, getScreenHeight()/2-20`），避開常見的右下角物欄與右上角血條/moodle 堆疊。

---

## 3. Toast

- **位置**：畫面右上角，`x = getScreenWidth() - width - 16`，`y = 60`（預留 60px 避開伺服器 MOTD/FPS 顯示等頂部覆蓋物），多則 Toast 由上而下堆疊，每則間距 8px；同時最多顯示 3 則，超出排入佇列依序播放（避免刷屏）。選右上角是因為 PZ 預設 HUD 熱區集中在左下（聊天）、下中（快捷欄）、右下（物欄常見停靠位）——右上是原生留白最大、最不易與其他浮動視窗重疊的角落。
- **尺寸**：寬 300 px（依文字自適應，上限 300，內文超長時截斷加「…」，避免無界長寬）；高依單/雙行文字自動：`titleLine(NewSmall) + bodyLine(NewSmall) + 上下 padding 各 8px`，約 48-64 px。
- **配色**：背景 `NBSkin.fill(0,0,w,h, TOAST_BG, false, alpha)`、邊框 `NBSkin.border(0,0,w,h, TOAST_BORDER, false, alpha)`（四角 r=6，`nb_round_*`；`TOAST_BORDER`=`ACCENT_AMBER` 略降 a），alpha 乘上動畫值；文字白 `TITLE_TEXT`；小圖示（可選）用同款公告板剪影，8px 內邊距。動畫期間 `setX/setY` 是小數，`NBSkin` 內部先 `math.floor` 絕對座標再交給 `NinePatchTexture.render`（它不 floor，GL_NEAREST 遇半像素會在邊上抖 1px）。
- **進出場動畫**：
  - **進場**：250ms，`x` 從 `screenWidth+width`（畫面外）滑入到目標 `x`，同時 alpha `0→1`；用簡單線性/緩出插值即可（`UIManager.getMillisSinceLastRender()` 累加計時，同 `ISTabPanel` 淡入淡出的計時手法，ISTabPanel.lua:134-146，或直接用引擎既有的 `UITransition`，`ISTabPanel.lua:490` 已示範 `UITransition.new()` 的用法，可直接複用做 alpha 補間，不必手刻緩動函式）。
  - **停留**：3000ms 原樣顯示（沿用 ralplan 定案「自製 3 秒淡出 toast」）。
  - **退場**：400ms，alpha `1→0` 同時 `y` 向上位移 -10px 做輕微上浮消失感；結束後 `removeFromUIManager()` 並讓佇列遞補下一則。
  - 總時長：250 + 3000 + 400 = 3650ms／則。
- **觸發時機**：在線更新推播抵達（manifest 帶來新 hash）→ 依 PopupMode 決策（見 4）若未直接彈窗，則降級為 Toast＋浮窗紅點；SP 遊戲中改檔同理。文案模板：`IGUI_MinidoracatNB_ToastNewContent` = 「公告欄有新內容：{1}」（`{1}`＝頁籤標題，注意 ralplan Step5 的 `%1` placeholder 規則，禁裸 `%`）。
- **提示音**：跳 Toast 的同時播一聲 `getSoundManager():playUISound("MinidoracatNBNotify")`——**MOD 自帶的音檔**（`42/media/sound/MinidoracatNBNotify.wav`；走 `GameSounds` 的 non-bank fallback（`GameSounds.java:95-137`），不需要 FMOD bank）。不用遊戲內建音效是因為那 19 個 UI 音效都是點擊／勾選的操作回饋，當「有新東西」的通知太輕。音檔可由服主替換（`docs/ADMIN_GUIDE.md`「換掉提示音」），原創的備援版本由 `scripts/gen_notify_sound.py` 生成、服主自備素材由 `scripts/prep_notify_sound.py` 處理成合規資產。
- **音量**：玩家在「選項 → MODS」的滑桿（`PZAPI.ModOptions`，`NBOptions.lua`）決定，0 = 靜音；實作是拿 `playUISound` 回傳的 instance ref 呼叫 `getUIEmitter():setVolume(ref, 0..1)`（`SoundManager.java:201,875-880`、`FMODSoundEmitter.java:284-298`，`FileSound.tick` 每幀套用 `:1242`）。沙盒 `NotifySound` 是服主端總開關，與玩家設定是 AND 關係。**一批一聲不是一則一聲**——首次同步逾時那條路徑會一次帶出所有未讀，逐則播就是連續叭好幾聲；換語系的第一份快照本來就靜音（hash 全變不算新內容），因此也不響。服主可用沙盒選項 `NotifySound` 關閉；沒有 Toast 可跳時（全部已讀）不會有聲音。

---

## 4. 未讀／彈窗決策的視覺呈現

沿用 ralplan「未讀／彈窗決策」邏輯（`always`/`unread`/`never` 三模式 + 10 秒有界等待降級），本節只定視覺：
- **`always`**：內容就緒即直接開面板，開啟時預設選中「有未讀」的第一個頁籤（若多個都未讀，取檔名數字前綴最小者）。
- **`unread`**：有未讀才自動開面板；無未讀則僅浮窗保持無紅點的常態圖示，不做任何提示。
- **`never`**：不自動開面板，僅浮窗紅點反映未讀；Toast 仍會在「在線更新」時彈出（Toast 屬通知層級，不受 PopupMode 影響 popup 開關，但**進場即有內容**的情境下 `never` 模式也不彈 Toast，只點紅點——因為那不是「更新」而是「初始同步」，避免每次進場都跳通知）。
- **有界等待降級（10s）**：面板本身不彈，但玩家若在等待中手動開了面板，內容區顯示「同步中…」置中灰字（`PLACEHOLDER_TEXT`，`UIFont.NewSmall`），可選用 `UITransition` 做 alpha 0.4↔1.0 的緩慢脈動暗示載入中（同 3 節的 UITransition 復用，不需新元件）；10 秒後若內容抵達，直接刷新面板內容並照常規則決定是否彈 Toast。

---

## 5. 字型選用（PZ 內建字型常數，皆為既有 `UIFont` 列舉值，不引入外部字型）

| 用途 | UIFont | 依據 |
|---|---|---|
| 面板標題列 | `UIFont.Small` | `ISCollapsableWindow:new` 預設 `titleFont`（ISCollapsableWindow.lua:398） |
| 頁籤文字 | `UIFont.Small` | 對照 `ISTabPanel:render` `drawTextCentre(..., UIFont.Small)`（ISTabPanel.lua:165）與 `tabHeight` 公式同源 |
| 內文本文（MDParser 一般段落／`<TEXT>`） | `UIFont.NewSmall` | `ISRichTextPanel` 預設 `defaultFont = UIFont.NewSmall`（ISRichTextPanel.lua:765），MD→RichText 映射沿用引擎原生行為，不覆寫 |
| `# ` 一級標題（`<H1>`） | `UIFont.Large` | `ISRichTextPanel:processCommand` H1 指令固定映射（ISRichTextPanel.lua:35），已由 RichText 原生決定，非本 MOD 可調 |
| `## ` 二級標題（`<H2>`） | `UIFont.Medium` | 同上 H2 指令（:44） |
| admin 重新載入按鈕 | `UIFont.NewSmall` | 對照 `SurvivalGuide.closeButton:setFont(UIFont.NewSmall)`（SurvivalGuide.lua:88） |
| Toast 標題/內文 | `UIFont.NewSmall` | 精簡通知，與面板本文字級一致，降低視覺跳動感 |
| 浮窗退回文字圖示（無自製貼圖時的 `!`） | `UIFont.Medium` | 40px 方鈕置中單字需要比 Small 稍大才不會太小氣 |
| 錯誤/占位提示文字 | `UIFont.NewSmall` | 與內文同級，不因為是「提示」就特別放大搶戲 |

不使用任何非 PZ 內建的自訂字型檔——PZ 的 `UIFont` 是引擎編譯期綁定的點陣/向量字型集合，MOD 端無法動態載入新字型（會是「發明引擎做不到的效果」），故本節全表皆為既有列舉值直接指定。

---

## 6. 各狀態視覺示意

### 6.1 頁籤：未讀 vs 已讀
```
未讀： [ 綜合公告 ● ]   文字=TAB_TEXT_UNSELECTED(選中時 TEXT_SELECTED)，右上 8x8 UNREAD_DOT 圓點（nb_dot.png，光暈 10x10）
已讀： [ 綜合公告   ]   同色，僅無紅點
```

### 6.2 錯誤占位頁（parse/render pcall 失敗，ralplan「壞 md／服主誤寫」風險項）
- 整頁內容區改顯示單一置中訊息區塊：背景疊一層 `ERROR_BG`（`NBSkin.fill(10, blockY, w-20, 48, ERROR_BG)`，四角 r=6 的半透明暗紅色塊，僅覆蓋文字所在的一段高度，不整頁染色），文字 `ERROR_TEXT`：
  ```
  IGUI_MinidoracatNB_ParseError = "[!] 這個公告目前無法顯示（格式錯誤），請聯絡服主。"
  ```
- 語氣定調：**不責怪玩家、明確指向服主**，因為錯誤源頭必定是公告檔本身，不是玩家操作。
- 該頁籤本身**不**額外標記紅色（避免與未讀紅點的紅撞色混淆語意），錯誤只在內容區呈現。

### 6.3 缺圖占位（`![alt](path)` 的 `getTexture` 為 nil）
- 原圖片位置改印純文字 `[alt文字]`，色 `PLACEHOLDER_TEXT`（中性灰，非錯誤紅），與周圍本文字級相同（`UIFont.NewSmall`），不加框、不加背景色塊——刻意做得「安靜」，因為缺圖是常見的服主疏漏（漏塞圖檔），不是需要玩家警覺的異常，跟 6.2 的錯誤語氣區隔開。
- 若 `alt` 為空字串，退回顯示 `[圖片]`（`IGUI_MinidoracatNB_ImagePlaceholder`），避免留白到看不出這裡本該有內容。

### 6.4 同步中（有界等待內手動開面板）
```
        （內容區置中）
        同步中…
```
- 灰字 `PLACEHOLDER_TEXT`、`UIFont.NewSmall`，可選 alpha 脈動（見第 4 節），10 秒等待上限一到即被真實內容或「錯誤/空」狀態取代，不會無限轉圈。

### 6.5 浮窗：一般 vs 有未讀
```
一般：  ╭────╮
        │ 🏳 │      BG_PANEL + BORDER（四角 r=6）+ 白色圖示
        ╰────╯

有未讀：╭────╮●
        │ 🏳 │      同上 + 右上弧上 8x8 UNREAD_DOT 圓點（黑色光暈）
        ╰────╯
```

---

## 落地檢查清單（供 Step 4 實作對照）
- [ ] 全部顏色數值取自本文件第 0 節 token（程式碼裡＝`NBSkin.COLORS`），禁止面板/浮窗/Toast 內散落魔法數字色碼。
- [ ] 頁籤列、紅點、Toast 均只用 `drawRect`/`drawRectBorder`/`drawTextureScaled`/`drawText(Centre)` + 既有 `UITransition` + `NinePatchTexture.getSharedTexture/render`（AGENTS.md API 表有出處與坑：首呼叫回 null、永久黑名單、絕對座標不 floor），不引入其他繪圖 API。
- [ ] 任一貼圖載入失敗（或引擎沒有 `NinePatchTexture`）必退回 `drawRect`／`drawRectBorder` 路徑，面板照樣進得去；`scripts/test_nbpanel.lua` 在沒有 `NinePatchTexture` 的 harness 裡仍全綠，並用 stub 驗有貼圖／壞貼圖兩種環境。
- [ ] 面板的關閉/釘選/收合鈕、縮放把手、位置記憶 100% 沿用 `ISCollapsableWindowJoypad` 原生行為；`prerender`／`render` 整段覆寫但版面數字（`titleBarHeight`／`resizeWidgetHeight`／richText rect／stencil）一個都不動。
- [ ] H1/H2/本文字級與顏色完全交給 `ISRichTextPanel` 原生指令映射，MDParser 只負責產出對應 tag，不在 UI 層覆寫字級/顏色。
- [ ] admin 工具列僅在 client 端判定 admin 時才 `addChild`；server 端 `reload` 指令仍照 ralplan 網路協定表重新驗證 access level。
