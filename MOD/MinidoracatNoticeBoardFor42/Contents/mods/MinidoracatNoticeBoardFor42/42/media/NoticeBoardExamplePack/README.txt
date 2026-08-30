================================================================================
  Notice Board - "Rebuild examples" output
  EN English / CH 繁體中文
================================================================================

--------------------------------------------------------------------------------
[MANAGED FILES]  One press writes exactly 5 files under NoticeBoard/.
                 Everything else in the folder is left untouched.
--------------------------------------------------------------------------------
  README.txt                                shared, this file
  categories.txt                            shared
  <LANG>/10_welcome.txt
  <LANG>/10_news/20_markdown_showcase.txt
  <LANG>/20_rules/30_server_rules.only.txt

  <LANG> is the language you picked in the button menu: CH or EN, nothing else.

  Picking CH writes exactly:
    NoticeBoard/README.txt
    NoticeBoard/categories.txt
    NoticeBoard/CH/10_welcome.txt
    NoticeBoard/CH/10_news/20_markdown_showcase.txt
    NoticeBoard/CH/20_rules/30_server_rules.only.txt

  Picking EN writes exactly:
    NoticeBoard/README.txt
    NoticeBoard/categories.txt
    NoticeBoard/EN/10_welcome.txt
    NoticeBoard/EN/10_news/20_markdown_showcase.txt
    NoticeBoard/EN/20_rules/30_server_rules.only.txt

--------------------------------------------------------------------------------
[EN] English
--------------------------------------------------------------------------------
1. WHAT THE BUTTON DOES. "Rebuild examples" sits in the notice panel toolbar,
   admin only, and opens a small menu with two entries: CH and EN. Pick one and
   the server writes the 5 files listed above straight into the live notice
   board, then refreshes the snapshot. Eligible players can read the three
   notices immediately; new or changed content follows the normal notification,
   sound and unread-dot rules. Nothing is written to a hidden reference folder:
   the 5 files land in the live notice board and nowhere else.
2. WHAT IT OVERWRITES. Exactly those 5 relative paths, and only for the
   language you picked. The other language folder is not touched, and neither
   is anything else you put in the notice board: your own notices, extra files,
   images/. There is no delete path anywhere in this feature - nothing is ever
   removed from disk.
3. categories.txt REPLACES YOUR CATEGORY DECLARATIONS. The generated file
   declares 10_news and 20_rules, with EN and CH labels, and nothing else. If
   you had declared other categories, those lines are gone: their folders are
   no longer declared, so they and their notices disappear from the sidebar
   until you add the lines back. The notice files themselves stay on disk, so
   re-adding one line brings a whole category back. Copy your categories.txt
   somewhere safe before you press, or press on a fresh notice board.
   categories.txt only DECLARES folders; the language and category folders of
   the 5 managed paths are created by the write itself.
4. THE WRITE IS NOT ATOMIC, AND THE RESULT MESSAGE IS NOT GUARANTEED. All 5
   assets are read into memory first, so a missing asset writes nothing at all.
   After that the files are written one at a time, each read back to verify it
   really landed, in this order: the three language files, then categories.txt,
   then README.txt. A failure midway leaves the files already verified in
   place. The order is deliberate: the most likely partial state is "new
   notices, old categories.txt", where the two category notices are invisible
   until categories.txt lands - not a wiped category setup with nothing to show
   for it. Press again after fixing the cause; a rebuild is fully repeatable
   and nothing accumulates. If you only see "request sent" and no result, your
   connection dropped or the reply itself failed to send: check the server log
   and look at the files on disk before pressing again.
   The snapshot is refreshed only after all 5 files verified, and a refresh
   that fails is reported as a failure even though the files are on disk: hit
   Reload, or wait one poll cycle, and they go out.
5. COOLDOWN. 10 seconds per admin, separate from the Reload button. A press
   inside the cooldown writes nothing at all, and an unknown language is
   rejected before any file is opened.
6. WHO SEES WHAT. One rule decides it: every file in the DefaultLanguage folder
   that is not marked .only is a shared base copy, and a file with the same
   name in the player's own language folder overrides it. So with
   DefaultLanguage set to EN, generating EN gives every player 10_welcome.txt
   and 20_markdown_showcase.txt, in English, while 30_server_rules.only.txt
   reaches EN readers alone because of the .only marker. Generating CH instead
   gives those three notices to CH readers only. Want both? Press the button
   again and pick the other language: that adds its three notices and rewrites
   the two shared files with identical content.
7. KEEPING YOUR OWN EDITS. Anything you change inside one of the 5 managed
   paths is lost the next time you rebuild that language. To keep an edited
   version, save it under a different file name - but remember the file name is
   the notice ID, so a renamed notice is a brand new notice for everyone who
   can see it: notification, sound and unread dot fire again.
8. THIS FILE AND categories.txt ARE NOT NOTICES. They sit at the root of
   NoticeBoard/, and the scanner only reads the language folders and the
   category folders declared in categories.txt. Players never see either file;
   they are here for whoever administers the server.
9. EMOJI ARE EFFECTIVELY UNSUPPORTED. Files, hashes, network sync and the
   sidebar all handle emoji correctly, so nothing breaks. The game simply
   cannot draw them: PZ renders text from pre-baked bitmap fonts and never
   falls back to an operating system emoji font. A missing glyph comes out as a
   question mark, or as nothing at all. Never carry meaning with an emoji - not
   in a notice title, not in a category label, not in the body. Use plain
   words, a PNG from NoticeBoard/images/, or the shared icons of the
   Minidoracat UI Library. These generated files contain no emoji on purpose.
10. WHAT YOU GET.
     categories.txt           two ready-to-use categories, EN and CH labels
     10_welcome.txt           folder layout, file naming and ordering, the
                              DefaultLanguage fallback rule, the .only marker
     20_markdown_showcase.txt every syntax this mod parses, as live examples
     30_server_rules.only.txt a short, real announcement you can edit and ship

--------------------------------------------------------------------------------
[CH] 繁體中文
--------------------------------------------------------------------------------
1. 這顆按鈕做什麼：「重建範例」在公告面板工具列上，管理員限定，按下會開出一個只有
   兩項的選單：CH 與 EN。選好之後伺服器會把上面那 5 個檔**直接寫進正式公告目錄**，
   然後刷新快照。符合該語系可見規則的玩家會立刻看到三則公告；內容是新增或變更時，
   通知、提示音與未讀紅點照既有規則觸發。不會寫到任何藏起來的參考資料夾：那 5 個檔
   就落在正式公告目錄裡，沒有別的地方。
2. 它會覆寫什麼：就是上面那 5 個相對路徑，而且只針對你選的那個語系。另一個語系目錄
   一個位元組都不會動，你自己的公告、額外檔案與 images/ 也一樣不動。這個功能沒有任何
   刪除路徑——磁碟上不會有東西被移除。
3. categories.txt 會取代你的分類宣告：產生的檔案只宣告 10_news 與 20_rules（含 EN 與
   CH 標籤），其他一律沒有。你原本宣告過的分類會連同那幾行一起消失：那些目錄不再被
   宣告，所以它們與裡面的公告會從側欄暫時不見，直到你把行加回去。公告檔本身仍留在
   磁碟上，補回一行就能讓整個分類回來。**按之前請先備份 categories.txt**，或是在還沒
   設定過分類的公告板上再按。categories.txt 只「宣告」目錄；上面那 5 個受管路徑需要的
   語系與分類目錄，是寫入本身建立的。
4. 寫入不是原子操作，也不保證收到結果訊息：5 份資源會先全部讀進記憶體，缺一份就一個
   檔都不寫。接著逐檔寫入、每寫完一檔就讀回驗證是否真的落地，順序是「選定語系的三個
   檔 -> categories.txt -> README.txt」。中途失敗時，前面已驗證成功的檔案會留下來。
   這個順序是刻意的：最可能出現的中間狀態是「新公告已在、categories.txt 還是舊的」，
   此時那兩則分類公告會在 categories.txt 落地前看不到——而不是分類設定先被清掉、卻
   什麼都沒生出來。修好原因後再按一次即可，重建完全可重複、不會累積殘留。若只看到
   「已送出」卻沒有後續結果，代表你已斷線或那則回覆本身傳送失敗：請看伺服器 log，
   並在再按之前確認磁碟上的檔案狀態。
   全部 5 個檔都驗證成功之後才會刷新快照；刷新失敗時檔案其實已經在磁碟上，但回報仍是
   失敗——按「重新載入」或等下一輪輪詢就會推給玩家。
5. 冷卻：每位管理員各自 10 秒，與「重新載入」的冷卻分開。在冷卻內按下完全不寫任何
   檔案；語系不在 CH／EN 之內時，也會在開檔之前就被拒絕。
6. 誰看得到哪一份：規則只有一條——**DefaultLanguage 目錄裡沒有標記 .only 的每一份
   檔案，都是全體共用的底稿；玩家自己語系目錄裡的同名檔案會覆蓋上去**。所以
   DefaultLanguage 設成 EN 時，產生 EN 會讓每一位玩家都看到 10_welcome.txt 與
   20_markdown_showcase.txt（內容是英文），而 30_server_rules.only.txt 因為有 .only
   標記，只有讀 EN 的玩家看得到。改成產生 CH，則那三則只有讀 CH 的玩家看得到。兩種
   都要？再按一次按鈕選另一個語系即可：那會補上該語系的三則公告，並用完全相同的內容
   重寫兩個共用檔。
7. 想保留自己的修改：改在那 5 個受管路徑「裡面」的內容，下次重建同一語系時會消失。
   要留下修改過的版本，請另存成不同檔名——但記得檔名就是公告 ID，改名等於變成一則
   全新公告：看得到它的玩家會再收到一次通知、提示音與未讀紅點。
8. 本檔與 categories.txt 都不是公告：它們放在 NoticeBoard/ 根層，而掃描只讀語系目錄
   與 categories.txt 已宣告的分類目錄。玩家看不到這兩個檔，它們是給管理伺服器的人看的。
9. emoji 實務上視為不支援：檔案、雜湊、網路同步與側欄都能正確處理 emoji，不會弄壞任何
   東西；問題在於遊戲畫不出來。PZ 用預先烘焙的點陣字型繪製文字，不會回退到作業系統的
   emoji 字型，缺字會變成問號、或是完全不繪製。**不要用 emoji 傳達必要資訊**——公告標題、
   分類名稱、內文都一樣。請改用文字、NoticeBoard/images/ 裡的 PNG，或 Minidoracat UI
   Library 的共用圖示。這些產生出來的檔案刻意完全不含 emoji。
10. 你會拿到什麼：
     categories.txt           兩個可直接使用的分類，含 EN 與 CH 標籤
     10_welcome.txt           目錄結構、檔名與排序、DefaultLanguage fallback、.only 標記
     20_markdown_showcase.txt 本 MOD 解析的所有語法，全部是實際可運作的示範
     30_server_rules.only.txt 一份可直接改用的簡短正式公告
