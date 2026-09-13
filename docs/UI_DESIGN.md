# UI 設計方向 — MinidoracatNoticeBoardFor42

> **【2026-08-25 上移註記】** 本文提及的 `nb_round_*`／`nb_roundtop_*`／`nb_dot.png` 貼圖與其
> 載入邏輯已上移家族 UI 框架 repo（`D:/github/MinidoracatUIFor42`，檔名前綴改 `mui_`、目錄
> `42/media/ui/MinidoracatUI/`）；本 repo 的 `NBSkin.lua` 現為框架 thin adapter（缺框架退直角），
> 不再攜帶 PNG。本文的視覺設計決策（色票、圓角語彙、元件版面）仍為權威；貼圖檔名與路徑
> 敘述為歷史原貌，現行以框架 repo 為準。


依據 `.omc/plans/ralplan-noticeboard.md`（NBPanel/NBFloatButton/NBToast、彈窗決策、未讀紅點）與 PZ B42 原生視覺語言（`SurvivalGuide.lua`、`ISUI/ISCollapsableWindow.lua`、`ISUI/ISScrollingListBox.lua`、`ISUI/ISRichTextPanel.lua`）撰寫。全部效果限定 ISUI 既有 API：`drawRect` / `drawRectBorder` / `drawTextureScaled` / `drawText(Centre)` / `ISButton` / `ISScrollingListBox` / `ISRichTextPanel` / `UITransition`，加上引擎原生 9-slice `NinePatchTexture`（`zombie/core/textures/NinePatchTexture.java`，出處與坑見 AGENTS.md API 表）配家族 UI 框架的白色圓角貼圖；不新增自訂 shader、不假設引擎沒有的模糊效果。

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
| `TITLEBAR_FILL` | 1 | 1 | 1 | 0.10 | 標題列疊色（畫在 `BG_PANEL` 面板底之上、`nb_roundtop_fill` 上圓下直） | 取代原生 `Panel_TitleBar.png` 灰階漸層（直角條與 r=6 相衝）。與側欄共用的 `TAB_SELECTED_FILL`(0.12)／`TAB_HOVER_FILL`(0.06) 同屬白色疊層族 |
| `TAB_TRAY_BG` | 0 | 0 | 0 | 0.5 | 工具列與文件樹背景（比面板底稍淺，做出「凹槽」層次） | 對照 `SurvivalGuide.listBox.backgroundColor`（SurvivalGuide.lua:46）；token 名保留以免三個 UI 檔分叉 |
| `TAB_SELECTED_FILL` | 1 | 1 | 1 | 0.12 | 側欄選中公告填色 | 自訂，弱化版白色高亮，避免刺眼 |
| `TAB_HOVER_FILL` | 1 | 1 | 1 | 0.06 | 側欄列與浮窗按鈕 hover 填色 | 自訂，比選中更淡 |
| `TAB_TEXT_SELECTED` | 1 | 1 | 1 | 1.0 | 側欄選中公告文字 | 同 TITLE_TEXT |
| `TAB_TEXT_UNSELECTED` | 0.7 | 0.7 | 0.7 | 1.0 | 側欄未選中公告與分類文字 | `ISRichTextPanel` `TEXT` 指令預設灰（ISRichTextPanel.lua:50-52） |
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

> 色票在程式碼裡的唯一來源是 `NBSkin.COLORS`（NBPanel／NBFloatButton／NBToast 都引用它，不各自複製）。標題列與底部 resize 列改為平面染色：原生 `Panel_TitleBar.png`／`Panel_StatusBar.png` 不再使用；`ResizeIcon.png` 沿用原位、邊長縮 2px。關閉／釘選／收合鈕、三顆共通 ISButton（側欄／語言／重設大小）、admin 額外的重新載入與「重建範例」按鈕、其語系選單（原生 context menu）、捲軸仍是原生鉻件不換皮。

---

## 1. 主面板（NBPanel）

### 1.1 基底與骨架
繼承 `ISCollapsableWindowJoypad`（`SurvivalGuide.lua:1` 同基底），沿用原生標題列鉻件：左上關閉鈕、右上收合／釘選鈕（`ISCollapsableWindow:createChildren`，:55-91）——**不重繪、不隱藏**，這些是玩家熟悉的既有操作。

版面：
```
┌───────────────────────────────────────────────────────┐
│ [X]              伺服器公告欄             [釘][收合] │  原生標題列
├───────────────────────────────────────────────────────┤
│ [側欄] [展開] [收合]   [語音][音量 ━━●━ 60%][語言][重設大小][重建範例][重新載入] │ 工具列
├──────────────────┬────────────────────────────────────┤
│ ▾ 📁 一般公告   ●│                                    │
│    📄 歡迎公告   │                                    │
│ ▸ 📁 伺服器規則 ●│       ISRichTextPanel 內容區       │
│ ▾ 📁 活動公告    │                    ＋原生捲軸      │
│    📄 八月活動  ●│                                    │
│  原生清單捲軸   │                                    │
└──────────────────┴────────────────────────────────────┘
```

- **面板底與外框**：`prerender`／`render` 整段覆寫、不再呼叫父類版本（父類會畫直角底與直角貼圖條）；面板底用 `NBSkin.fill(..., BG_PANEL)`、外框用 `NBSkin.border(..., BORDER)`，底部 resize 列保留原生把手與 1px 分隔線。文件樹與 RichText 各自使用原生 stencil 收支；主面板不再維護舊頁籤的額外巢狀 stencil，因此 `scripts/test_nbpanel.lua` 釘住 `maxLevel == 1` 且沒有主面板 repaint。
- **標題列**：高度與原生 `titleBarHeight()` 相同，疊 `TITLEBAR_FILL`、下緣 1px `BORDER`；標題 `IGUI_MinidoracatNB_PanelTitle` 置中。
- **工具列**：高度 = `getTextManager():getFontHeight(UIFont.Small) + 6`，y = `titleBarHeight()`。左組由左到右為側欄開關、「全部展開」、「全部收合」；右組由左到右為語音、音量滑桿、語言、重設大小、重建範例（僅 admin）、重新載入（僅 admin）。**重新載入固定在最右**，非 admin 不建立兩顆管理按鈕，server 仍重新驗證權限。重建範例先開原生 `ISContextMenu`，CH／EN 選項各自明示「會覆寫 categories.txt」，選定才送請求，關閉選單零副作用。八顆按鈕各掛 14px 框架圖示：`sidebar`／`chevronDown`／`chevronRight`／`language`（語音與文字語系共用）／`resetSize`／`folder`／`reload`。沿用 `ISButton.iconTexture` ＋ `joypadTextureWH = 14`，原生圖示與標題間距為 5（`ISButton.lua:238-246`），有圖示時寬度多留 19px；缺圖示退純文字，不留空欄。minimumWidth 由左組最右的收合鈕與右組最左的語音鈕計算，包含音量滑桿寬度，避免群組互相覆蓋。語音選單與保存規則見 `ADMIN_GUIDE.md`「玩家自己的音效設定」。
- **音量滑桿**：`NBVolumeSlider` 繼承原生 `ISSliderPanel` 的拖曳、框外放開、上下限與步進；「音量」標籤與百分比依實際字寬留位，軌道寬 120px。框架 rev≥3 的 `Skin.slider` 畫琥珀軌道與白色旋鈕，缺能力則退原生繪製，不另造拖曳模型。收合時不繪製；原生 Toggle UI 繞過 Lua setter，因此在既有 UI update 生命週期觀察實際可見狀態並收尾。保存與試聽時機見管理指南；本輪未新增公告面板的完整手把導覽。
- **文件樹**：原生 `ISScrollingListBox` 子類 `NBDocTree`，自繪分類與公告列，不畫原生每列外框。展開／收合時重建可見 items，讓 rowAt、捲動高度與 ensureVisible 全部沿用原生實作。
- **內容區**：`ISRichTextPanel`＋`addScrollBars()`，`autosetheight=false`、`clip=true`、`doRepaintStencil=true`，左右 margin 都是 `10 + scrollbarWidth`，確保 `<H1>`／`<CENTRE>` 以內容區真正中心對齊。側欄寬度改變時 `updateLayout()` 手動調整兩個子元件，不同時使用 anchors。

### 1.2 文件樹視覺與互動

- 分類列的展開／收合記號優先用框架圖示 `chevronDown`／`chevronRight`，並在其右側加一張 `folder`；公告列加一張 `document`。全部染成該列的文字色（選中 `TAB_TEXT_SELECTED`、否則 `TAB_TEXT_UNSELECTED`），資產本身是純白，換色不換材質。圖示版的欄位：chevron x=4、folder x=20、分類文字 x=38；公告 document x=22、文字 x=40，圖示與文字各自在列高內垂直置中。
- **四張核心 tree icons（chevronDown／chevronRight／folder／document）必須全數可用才啟用圖示版面**；任一張缺失、框架 API rev < 2 或能力關閉時，整棵樹退回 ASCII `-`／`+`，分類文字回 x=18、公告文字回 x=26，不留下空圖示欄。分類標籤由 server snapshot 提供，語系根層使用 `IGUI_MinidoracatNB_CategoryRoot`。
- 公告列比分類縮一層（圖示版 x=40、退回版 x=26）；選中時疊 `TAB_SELECTED_FILL`，左緣畫 2px `ACCENT_AMBER`。這是舊頁籤琥珀底線旋轉 90 度後的同一視覺語意。
- Hover 疊 `TAB_HOVER_FILL`；過長標籤依實際字寬截斷並加 `...`，完整標題與內容資料不改。
- 點分類只展開／收合，不選公告、不標已讀；點公告後立即顯示內容並寫入既有 ReadState。
- snapshot 更新以裸檔名保存選取；目標位於收合分類時，先展開父分類再選中並 `ensureVisible()`。
- 空分類不顯示。分類目錄以外的根層公告固定排第一組，其餘依 server 給的分類順序。

### 1.3 未讀紅點

- 公告列右側用 `NBSkin.dot(..., 8, UNREAD_DOT, UNREAD_DOT_OUTLINE)`；貼圖載不到時由 NBSkin 退回方點。
- **垂直捲軸出現時紅點與文字留白一起讓開 17px**。原生 vscroll 是 `x = 寬-16`、寬 17（`ISScrollBar.lua:274-276`），而 `ISScrollingListBox:prerender` 把 stencil 右緣收到 `vscroll.x + 3 = 寬-13`（`:494-496`）——紅點原本從 `寬-14` 起、邊長 8，只剩 1px 露在裁切範圍內，看起來就是紅點消失了。兩者同時平移，紅點與文字之間原本的 6px 間距不變。
- 分類列紅點是所有子公告未讀狀態的 OR；分類收合後仍保留，避免未讀內容被藏起來。
- 選中公告寫回 ReadState 後，公告列與父分類紅點立即刷新；狀態是離散事件，不做淡出動畫。

### 1.4 尺寸與收合

| 項目 | 數值 | 依據 |
|---|---|---|
| 預設寬 × 高 | 螢幕 72% × 88%，上限 1440 × 1080、與螢幕邊留 80、基礎下限 420 × 260 | 1920×1080 約 1382×950；側欄常駐展開後仍留 1082 給內文 |
| 側欄寬 | `clamp(180, floor(width × 0.26), 300)` | 小視窗保住內容，寬視窗避免目錄浪費 |
| 實際最小寬 | `max(420, 左側欄鈕＋間距＋右側工具列整組＋左右 margin)` | createChildren 在圖示、翻譯、字型與 admin 狀態都確定後量測，避免工具列互相覆蓋。admin 多兩顆按鈕（重新載入、重建範例），量測值必須跟著變大，不能寫死——「重建範例」比舊的「範例」更寬，靠量測自動吸收 |
| 強制收合 | 視窗寬 `< 640` | 窄窗把內容寬優先留給 RichText；實際最小寬仍受上一列工具列量測約束 |
| 無偏好預設 | **一律展開** | 目錄是主要導覽；舊版的「公告 >4 或有 server 分類」門檻對玩家不可見，小型公告板永遠開不出目錄 |
| 偏好持久化 | `NoticeBoard/settings.ini` 的 `sidebar=true/false` | 強制收合不覆寫偏好；拉寬後恢復 |
| 可縮放 | 是，沿用原生 `ISResizeWidget` | `updateLayout()` 每幀只在幾何改變時落地 |
| 位置記憶 | 沿用 `ISLayoutManager` | 與原生視窗同套 `layout.ini` 機制 |

---

## 2. 浮窗（NBFloatButton）

- **尺寸**：40 × 40 px 正方形圖示鈕（比原生標題列鈕大一級，因為要獨立浮在畫面上被辨識，且要容納右上角紅點不擠壓圖示本體）。
- **外觀**：沿用面板同款鉻件語彙——`NBSkin.fill(0,0,w,h, BG_PANEL)` 底 + hover 疊 `TAB_HOVER_FILL` + `NBSkin.border(0,0,w,h, BORDER)` 邊框（四角 r=6，與面板同一組 `nb_round_*` 貼圖；維持四角圓的方鈕、不做正圓——正圓要另一組 r=20 貼圖，與面板語彙也不一致），中央疊一張 MOD 自帶的單色圖示貼圖（建議「公告板/圖釘」剪影，白色單色，`drawTextureScaled` 上色即可換色，不必做多套材質）。若暫無自製圖示，退而求其次用 `drawTextCentre("!", ...)`（`UIFont.Medium`，置中）純文字圖示頂上，之後再補真圖示，不阻塞開發。
- **紅點**：位置與規格同 1.3（`NBSkin.dot`，圓點＋光暈），釘在按鈕右上角外緣。只要任一公告未讀即顯示，不顯示數字徽章。
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
- **觸發時機**：在線更新推播抵達（manifest 帶來新 hash）→ 依 PopupMode 決策（見 4）若未直接彈窗，則降級為 Toast＋浮窗紅點；SP 遊戲中改檔同理。文案模板 `IGUI_MinidoracatNB_ToastNewContent` 的 `%1` 是公告標題，禁裸 `%`。
- **提示音與語音**：跳 Toast 時以 `getSoundManager():playUISound` 播放玩家選定的通知音；預設 `MinidoracatNBNotify`，語音使用 `MinidoracatNBVoiceCH`／`EN`／`JP`。全部位於 `42/media/sound/`，走 `GameSounds` 的 non-bank fallback（`GameSounds.java:95-137`），不需要 FMOD bank。自動模式直接讀遊戲 `Translator`，不讀公告內容語系；CN 共用 CH，其他未支援語系使用 EN。資產替換與語系選擇見 `ADMIN_GUIDE.md` 的「換掉提示音」及「玩家自己的音效設定」。
- **音量**：玩家在「選項 → MODS」的滑桿（`PZAPI.ModOptions`，`NBOptions.lua`）決定，0 = 靜音；實作是拿 `playUISound` 回傳的 instance ref 呼叫 `getUIEmitter():setVolume(ref, 0..1)`（`SoundManager.java:201,875-880`、`FMODSoundEmitter.java:284-298`，`FileSound.tick` 每幀套用 `:1242`）。沙盒 `NotifySound` 是服主端總開關，與玩家設定是 AND 關係。**一批一聲不是一則一聲**——首次同步逾時那條路徑會一次帶出所有未讀，逐則播就是連續叭好幾聲；換語系的第一份快照本來就靜音（hash 全變不算新內容），因此也不響。服主可用沙盒選項 `NotifySound` 關閉；沒有 Toast 可跳時（全部已讀）不會有聲音。

---

## 4. 未讀／彈窗決策的視覺呈現

沿用 ralplan「未讀／彈窗決策」邏輯（`always`/`unread`/`never` 三模式 + 10 秒有界等待降級），本節只定視覺：
- **`always`**：內容就緒即直接開面板，開啟時預設選中第一份未讀公告（若多份未讀，依檔名排序取第一份）。
- **`unread`**：有未讀才自動開面板；無未讀則僅浮窗保持無紅點的常態圖示，不做任何提示。
- **`never`**：不自動開面板，僅浮窗紅點反映未讀；Toast 仍會在「在線更新」時彈出（Toast 屬通知層級，不受 PopupMode 影響 popup 開關，但**進場即有內容**的情境下 `never` 模式也不彈 Toast，只點紅點——因為那不是「更新」而是「初始同步」，避免每次進場都跳通知）。
- **有界等待降級（10s）**：面板本身不彈，但玩家若在等待中手動開了面板，內容區顯示「同步中…」置中灰字（`PLACEHOLDER_TEXT`，`UIFont.NewSmall`），可選用 `UITransition` 做 alpha 0.4↔1.0 的緩慢脈動暗示載入中（同 3 節的 UITransition 復用，不需新元件）；10 秒後若內容抵達，直接刷新面板內容並照常規則決定是否彈 Toast。

---

## 5. 字型選用（PZ 內建字型常數，皆為既有 `UIFont` 列舉值，不引入外部字型）

| 用途 | UIFont | 依據 |
|---|---|---|
| 面板標題列 | `UIFont.Small` | `ISCollapsableWindow:new` 預設 `titleFont`（ISCollapsableWindow.lua:398） |
| 文件樹分類／公告文字 | `UIFont.Small` | `ISScrollingListBox:setFont("Small", 3)`，列高由字高＋上下 padding 決定 |
| 內文本文（MDParser 一般段落／`<TEXT>`） | `UIFont.NewSmall` | `ISRichTextPanel` 預設 `defaultFont = UIFont.NewSmall`（ISRichTextPanel.lua:765），MD→RichText 映射沿用引擎原生行為，不覆寫 |
| `# ` 一級標題（`<H1>`） | `UIFont.Large` | `ISRichTextPanel:processCommand` H1 指令固定映射（ISRichTextPanel.lua:35），已由 RichText 原生決定，非本 MOD 可調 |
| `## ` 二級標題（`<H2>`） | `UIFont.Medium` | 同上 H2 指令（:44） |
| admin 按鈕（重新載入／重建範例） | `UIFont.NewSmall` | 對照 `SurvivalGuide.closeButton:setFont(UIFont.NewSmall)`（SurvivalGuide.lua:88）；與其餘工具列按鈕同一字級 |
| Toast 標題/內文 | `UIFont.NewSmall` | 精簡通知，與面板本文字級一致，降低視覺跳動感 |
| 浮窗退回文字圖示（無自製貼圖時的 `!`） | `UIFont.Medium` | 40px 方鈕置中單字需要比 Small 稍大才不會太小氣 |
| 錯誤/占位提示文字 | `UIFont.NewSmall` | 與內文同級，不因為是「提示」就特別放大搶戲 |

不使用任何非 PZ 內建的自訂字型檔——PZ 的 `UIFont` 是引擎編譯期綁定的點陣/向量字型集合，MOD 端無法動態載入新字型（會是「發明引擎做不到的效果」），故本節全表皆為既有列舉值直接指定。

---

## 6. 各狀態視覺示意

### 6.1 文件樹：分類與未讀

有圖示（框架 rev>=2 且資產在）：
```
▾ 📁 一般公告 ●      展開分類；任一子公告未讀時顯示紅點
     📄 歡迎公告      已讀公告
     📄 八月更新 ●    未讀公告
▸ 📁 伺服器規則       收合分類
```

圖示畫不出來時的退回（框架舊／資產缺）——只換記號欄，文字不留空格：
```
- 一般公告 ●        展開分類；任一子公告未讀時顯示紅點
   歡迎公告          已讀公告
   八月更新 ●        未讀公告
+ 伺服器規則         收合分類
```

### 6.2 錯誤占位頁（parse/render pcall 失敗，ralplan「壞 md／服主誤寫」風險項）
- 整頁內容區改顯示單一置中訊息區塊：背景疊一層 `ERROR_BG`（`NBSkin.fill(10, blockY, w-20, 48, ERROR_BG)`，四角 r=6 的半透明暗紅色塊，僅覆蓋文字所在的一段高度，不整頁染色），文字 `ERROR_TEXT`：
  ```
  IGUI_MinidoracatNB_ParseError = "[!] 這個公告目前無法顯示（格式錯誤），請聯絡服主。"
  ```
- 語氣定調：**不責怪玩家、明確指向服主**，因為錯誤源頭必定是公告檔本身，不是玩家操作。
- 該公告列本身**不**額外標記紅色（避免與未讀紅點的紅撞色混淆語意），錯誤只在內容區呈現。

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
- [ ] 文件樹、紅點、Toast 均只用既有 ISUI／NBSkin 繪製能力；文件樹基於原生 `ISScrollingListBox`，不自建第二套捲動或命中模型。
- [ ] 任一貼圖載入失敗（或引擎沒有 `NinePatchTexture`）必退回 `drawRect`／`drawRectBorder` 路徑，面板照樣進得去；`scripts/test_nbpanel.lua` 在沒有 `NinePatchTexture` 的 harness 裡仍全綠，並用 stub 驗有貼圖／壞貼圖兩種環境。
- [ ] 圖示（框架 `Icons`，API v1 rev>=2）一律以回傳值判斷：`get` 回 nil 就不掛 `iconTexture`、`draw` 回 false 就退回 ASCII 記號與純文字寬。舊框架、能力關閉、貼圖缺任一種情況下，面板的每一段文字與每一顆按鈕都要照樣可讀可按；`scripts/test_nbpanel.lua` 的 I0／I1／I2 三段就是這條紅線。
- [ ] 面板的關閉/釘選/收合鈕、縮放把手、位置記憶 100% 沿用 `ISCollapsableWindowJoypad` 原生行為；`prerender`／`render` 整段覆寫但版面數字（`titleBarHeight`／`resizeWidgetHeight`／richText rect／stencil）一個都不動。
- [ ] H1/H2/本文字級與顏色完全交給 `ISRichTextPanel` 原生指令映射，MDParser 只負責產出對應 tag，不在 UI 層覆寫字級/顏色。
- [ ] admin 工具列僅在 client 端判定 admin 時才 `addChild`；server 端 `reload` 與 `examples` 指令仍照網路協定表重新驗證 access level。`examples` 帶 `lang`，client 與 server 都只接受精確的 `CH`／`EN`（其他值零寫入、零冷卻消耗、節流 log、回 `failed`），另有 per-admin 10 秒冷卻與 `examplesResult` 回覆（`success`／`failed`／`cooldown`／`forbidden`），四種都要有面板提示。`success` 帶固定檔數 5 且伺服器已刷新快照——**玩家端畫面會跟著更新**（新公告、通知、未讀紅點），所以提示文案不能再說「畫面不會有變化」。
