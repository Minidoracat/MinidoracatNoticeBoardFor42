# Minidoracat Notice Board for B42

遊戲內公告欄，直接編輯 Markdown 檔案即可更新（依伺服器輪詢間隔生效），多份檔案自動分頁

Project Zomboid Build 42 MOD。

## 功能

- **Markdown 公告**：公告內容以 Markdown 撰寫，遊戲內自動排版顯示
- **近即時更新**：編輯公告檔案存檔後，遊戲內於伺服器輪詢間隔（`PollIntervalSeconds`，預設 60 秒；管理員可按面板「重新載入」立即刷新）內反映，不需重啟伺服器
- **多檔自動分頁**：每份 `.md`/`.txt` 檔自動產生一個分頁（每語系上限 200 檔），適合把伺服器規則、指令說明、活動公告分開管理

## 安裝

- Steam Workshop：（首次上傳後補上連結）
- 手動安裝：把 `MOD/MinidoracatNoticeBoardFor42/Contents/mods/MinidoracatNoticeBoardFor42` 複製到 `%USERPROFILE%\Zomboid\mods\` 並將資料夾改名為 `MinidoracatNoticeBoardFor42`

## 開發

- `link_workshop.bat`：把 repo 掛載到 `Zomboid\Workshop\` 與 `Zomboid\mods\`（符號連結，repo 改動即時生效）
- `PZ_Test.bat`：啟動測試（客戶端 / 專用伺服器 / 多客戶端組合）

## 版本

版本號格式：`{PZ 版本}-{mod 版本}`（例 `42.20.2-0.1.0`），詳見 [CHANGELOG.md](CHANGELOG.md)。

## 作者

Minidoracat — [Discord](https://discord.gg/Gur2V67) | [Twitch](https://www.twitch.tv/minidoracat)
