# Minidoracat Notice Board for B42

遊戲內公告欄，直接編輯 Markdown 檔案即可更新（依伺服器輪詢間隔生效），多份檔案以可收合文件樹瀏覽，並支援自訂分類目錄

Project Zomboid Build 42 MOD。

## 功能

- **Markdown 公告**：公告內容以 Markdown 撰寫，遊戲內自動排版顯示
- **近即時更新**：編輯公告檔案存檔後，遊戲內於伺服器輪詢間隔（`PollIntervalSeconds`，預設 60 秒；管理員可按面板「重新載入」立即刷新）內反映，不需重啟伺服器
- **多檔文件樹與自訂分類**：每份 `.md`/`.txt` 都是獨立公告（每語系上限 200 檔）；服主可用 `NoticeBoard/categories.txt` 宣告多語分類並把檔案放進對應目錄，玩家從側欄快速切換。側欄預設就是展開的，分類與公告各有圖示（缺前置 MOD 的圖示資產時自動退回文字記號，功能不受影響）。側欄工具列提供「全部展開」與「全部收合」按鈕，一鍵操作所有分類，不必逐個點擊；展開時若玩家曾明確收合側欄，會一併打開側欄；窄視窗強制收合仍優先保護內文寬度
- **公告可放圖片，自動同步給玩家**：把 PNG 放進伺服器的 `NoticeBoard/images/`，在公告裡用 Markdown 圖片語法引用即可；伺服器分批推送到玩家本機快取，**不需要另外做圖包 MOD、玩家也不必額外訂閱**。放新檔名的圖或原地覆蓋同名檔案都會自動偵測（比對檔案大小），下一輪輪詢生效
- **圖片尺寸與容量可控**：支援 `![alt](path =600x200)` 指定顯示尺寸（`=600x`／`=x200` 依原圖比例補另一邊）；張數（`MaxImageCount`）、單張大小（`MaxImageKB`）、總量（`MaxImageTotalKB`）皆為沙盒選項。玩家端快取以連線的伺服器位址分命名空間、總量 128 MB 上限、最久未使用者優先在背景淘汰，同步中斷會從缺的分塊接續而非整張重傳
- **一鍵重建範例公告（管理員限定）**：按面板上的「重建範例」並選 CH 或 EN，伺服器會把所選語系三則示範公告連同根層 `README.txt`、`categories.txt` 直接寫進正式公告目錄並立即刷新；符合語系可見規則的玩家不必等下一輪輪詢。每次固定覆寫這 5 個路徑，另一語系、其他公告與 `images/` 不動不刪。根層 `categories.txt` 會改成範例分類，選單已明示警告，按前請先備份

## 安裝

- Steam Workshop：https://steamcommunity.com/sharedfiles/filedetails/?id=3789836823
- **必要前置 MOD**：[Minidoracat UI Library for B42](https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701)（`require=MinidoracatUIFor42`；未訂閱時本 MOD 不會載入）
- 手動安裝：把 `MOD/MinidoracatNoticeBoardFor42/Contents/mods/MinidoracatNoticeBoardFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatNoticeBoardFor42`

## 開發

- `link_workshop.bat`：把 repo 掛載到 `Zomboid\Workshop\` 與 `Zomboid\mods\`（符號連結，repo 改動即時生效）
- `PZ_Test.bat`：啟動測試（客戶端 / 專用伺服器 / 多客戶端組合）

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.2-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)
