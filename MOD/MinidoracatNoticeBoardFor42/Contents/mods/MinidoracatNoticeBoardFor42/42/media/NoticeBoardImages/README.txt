================================================================================
  Notice Board - images/ folder
  EN English / CH 繁體中文 / CN 简体中文 / JP 日本語
================================================================================

Put your PNG files in THIS folder. The server syncs them to every player, so you
do NOT need to build or publish a separate texture mod.

--------------------------------------------------------------------------------
[LIMITS]  Every limit in this file lives here, and only here. (The "about 950 px"
          panel width in item 6 is an approximation, not a limit.)
--------------------------------------------------------------------------------
  max-image-kb-default   = 512    per image, default (KB)
  max-image-kb-min       = 64     MaxImageKB sandbox option, lower bound (KB)
  max-image-kb-max       = 4096   MaxImageKB sandbox option, upper bound (KB)
  max-image-count-default = 20    how many images, default
  max-image-count-min    = 1      MaxImageCount sandbox option, lower bound
  max-image-count-max    = 200    MaxImageCount sandbox option, upper bound
  max-total-kb-default   = 4096   all images combined, default (KB)
  max-total-kb-min       = 4096   MaxImageTotalKB sandbox option, lower bound (KB)
  max-total-kb-max       = 16384  MaxImageTotalKB sandbox option, upper bound (KB)
  max-name-chars         = 64     file name length limit (characters)

--------------------------------------------------------------------------------
[EN] English
--------------------------------------------------------------------------------
1. FILE NAMES: ASCII only. Start with a letter or a digit, then letters, digits,
   "-" or "_", and end with ".png". max-name-chars characters or less in total,
   and no extra "." in the name. No spaces, no Chinese/Japanese characters - this
   is by far the most common cause of "img-invalid-name" in the server log. Upper
   and lower case are NOT distinguished: Logo.png and logo.png are the same image.
2. SIZE PER IMAGE: default max-image-kb-default KB (see [LIMITS]). Admins can
   change it with the sandbox option "MaxImageKB", allowed range
   max-image-kb-min to max-image-kb-max (KB).
3. HOW MANY: default max-image-count-default files, max-total-kb-default KB in
   total. Both are sandbox options too: "MaxImageCount" (range
   max-image-count-min to max-image-count-max) and "MaxImageTotalKB" (range
   max-total-kb-min to max-total-kb-max KB). Files are sorted by name and the
   ones past a limit are skipped. Raising a limit raises what EVERY player has
   to download by the same factor, and players have their own cache write limit
   that no server setting can raise.
4. USE IT IN A NOTICE: ![alt text](images/your-file.png)
   Optional display size: =600x200 (width x height), =600x (width only),
   =x200 (height only). Example: ![Map](images/map.png =600x200)
5. UPDATING: a NEW file name goes live automatically within one poll cycle.
   Overwriting an existing file in place is now detected automatically too, by
   comparing the file size. That is a heuristic, not a guarantee: if the new
   image happens to have EXACTLY the same byte count as the old one it will not
   be noticed - press "Reload" in the notice panel (admin only) or restart the
   server. If the new file breaks a limit, the image disappears from the notice
   and falls back to its alt text placeholder; the reason is in the server log.
6. A SMALLER DISPLAY SIZE DOES NOT REDUCE TRANSFER. Every player downloads the
   whole PNG. Compress the file itself. The panel content area is about 950 px
   wide, so anything wider is scaled down on screen and simply wasted.
7. THIS FILE IS IGNORED by the image scanner (only .png files are scanned). Edit
   it, add your own notes, or delete it. It is only re-created when missing. Do
   NOT rename it to ".png": it would then be treated as an image and synced to
   every player as a broken picture, eating into the limits above.

--------------------------------------------------------------------------------
[CH] 繁體中文
--------------------------------------------------------------------------------
1. 檔名：只能用 ASCII。開頭是英文字母或數字，其餘只能是英數、「-」、「_」，副檔名
   必須是 .png。全長 max-name-chars 字元以內，主檔名不能再有「.」。不可有空白，不可有中日文字
   ——這是伺服器 log 出現 img-invalid-name 最常見的原因。檔名不分大小寫：Logo.png
   與 logo.png 視為同一張圖。
2. 單張大小上限：預設 max-image-kb-default KB（見 [LIMITS]）。服主可用沙盒選項
   「MaxImageKB」調整，允許範圍是 max-image-kb-min 到 max-image-kb-max（KB）。
3. 張數與總量：預設最多 max-image-count-default 張、總量 max-total-kb-default KB。
   兩者一樣是沙盒選項：「MaxImageCount」（範圍 max-image-count-min 到
   max-image-count-max）與「MaxImageTotalKB」（範圍 max-total-kb-min 到
   max-total-kb-max KB）。超限時依檔名排序，排在後面的被略過。**調高上限＝每一位玩家
   要下載的量等比增加**；另外玩家端有自己的快取寫入上限，服主再怎麼調都突破不了。
4. 在公告裡引用：![說明文字](images/檔名.png)
   可指定顯示尺寸：=600x200（寬x高）、=600x（只給寬）、=x200（只給高）。
   例：![地圖](images/map.png =600x200)
5. 更新機制：放進**新檔名**的圖，下一輪輪詢就會自動生效。**原地覆蓋同名檔案**現在
   也會自動偵測（比對檔案大小）。這是啟發式不是保證：新圖的位元組數若與舊圖**剛好
   相同**就抓不到，這時請在公告面板按「重新載入」（管理員限定）或重啟伺服器。若新檔
   超過上限，那張圖會從公告上消失、退回替代文字占位，原因會寫在伺服器 log。
6. 縮小顯示尺寸**不會**減少傳輸量：每位玩家都要下載整個 PNG 檔。請直接壓縮圖檔本身
   （面板內容區約 950 px 寬，超過的像素顯示時本來就會被縮掉，純屬浪費）。
7. 本說明檔會被圖片掃描器忽略（只掃 .png），可以自由編輯、加自己的筆記或刪除。只有
   在檔案不存在時才會被重新建立，不會覆蓋你改過的內容。請勿把副檔名改成 .png——那會
   讓這份純文字被當成圖片同步給每位玩家（顯示為壞圖），白白吃掉上面的容量額度。

--------------------------------------------------------------------------------
[CN] 简体中文
--------------------------------------------------------------------------------
1. 文件名：只能用 ASCII。开头是英文字母或数字，其余只能是英数、「-」、「_」，扩展名
   必须是 .png。全长 max-name-chars 字符以内，主文件名不能再有「.」。不可有空格，不可有中日文字
   ——这是服务器 log 出现 img-invalid-name 最常见的原因。文件名不分大小写：Logo.png
   与 logo.png 视为同一张图。
2. 单张大小上限：默认 max-image-kb-default KB（见 [LIMITS]）。服主可用沙盒选项
   「MaxImageKB」调整，允许范围是 max-image-kb-min 到 max-image-kb-max（KB）。
3. 张数与总量：默认最多 max-image-count-default 张、总量 max-total-kb-default KB。
   两者同样是沙盒选项：「MaxImageCount」（范围 max-image-count-min 到
   max-image-count-max）与「MaxImageTotalKB」（范围 max-total-kb-min 到
   max-total-kb-max KB）。超限时按文件名排序，排在后面的被跳过。**调高上限＝每一位玩家
   要下载的量等比增加**；另外玩家端有自己的缓存写入上限，服主再怎么调都突破不了。
4. 在公告里引用：![说明文字](images/文件名.png)
   可指定显示尺寸：=600x200（宽x高）、=600x（只给宽）、=x200（只给高）。
   例：![地图](images/map.png =600x200)
5. 更新机制：放进**新文件名**的图，下一轮轮询就会自动生效。**原地覆盖同名文件**现在
   也会自动检测（比对文件大小）。这是启发式而不是保证：新图的字节数若与旧图**刚好
   相同**就抓不到，这时请在公告面板按「重新载入」（管理员限定）或重启服务器。若新文件
   超过上限，那张图会从公告上消失、退回替代文字占位，原因会写在服务器 log。
6. 缩小显示尺寸**不会**减少传输量：每位玩家都要下载整个 PNG 文件。请直接压缩图片文件
   本身（面板内容区约 950 px 宽，超过的像素显示时本来就会被缩掉，纯属浪费）。
7. 本说明文件会被图片扫描器忽略（只扫 .png），可以自由编辑、加自己的笔记或删除。只有
   在文件不存在时才会被重新创建，不会覆盖你改过的内容。请勿把扩展名改成 .png——那会
   让这份纯文本被当成图片同步给每位玩家（显示为坏图），白白吃掉上面的容量额度。

--------------------------------------------------------------------------------
[JP] 日本語
--------------------------------------------------------------------------------
1. ファイル名: ASCII のみ。先頭は英数字、以降は英数字・「-」・「_」、拡張子は .png。
   全体で max-name-chars 文字以内、拡張子以外に「.」を含めないこと。空白と日本語・中国語の文字は
   使えません。サーバーログの img-invalid-name はほぼこれが原因です。大文字と小文字は
   区別しません: Logo.png と logo.png は同じ画像として扱われます。
2. 1 枚あたりのサイズ上限: 既定は max-image-kb-default KB ([LIMITS] を参照)。
   サンドボックスオプション「MaxImageKB」で変更でき、範囲は max-image-kb-min から
   max-image-kb-max (KB) です。
3. 枚数と合計: 既定は最大 max-image-count-default 枚、合計 max-total-kb-default KB
   まで。どちらもサンドボックスオプションです:「MaxImageCount」(範囲
   max-image-count-min から max-image-count-max)、「MaxImageTotalKB」(範囲
   max-total-kb-min から max-total-kb-max KB)。超過分はファイル名順で後ろのものから
   スキップされます。上限を引き上げると全プレイヤーのダウンロード量が比例して増えます。
   またプレイヤー側には、サーバー設定では引き上げられない独自のキャッシュ書き込み上限が
   あります。
4. お知らせでの書き方: ![説明](images/ファイル名.png)
   表示サイズの指定: =600x200 (幅x高さ)、=600x (幅のみ)、=x200 (高さのみ)。
   例: ![地図](images/map.png =600x200)
5. 更新: 新しいファイル名の画像は次のポーリングで自動的に反映されます。同名ファイルの
   上書きも、ファイルサイズの比較で自動検出されるようになりました。ただしこれは
   経験則であり保証ではありません: 新旧のバイト数が完全に同じ場合は検出できないため、
   お知らせパネルの「再読み込み」(管理者のみ) を押すか、サーバーを再起動してください。
   新しいファイルが上限を超えた場合、その画像はお知らせから消えて代替テキストの
   プレースホルダーに戻ります。理由はサーバーログに記録されます。
6. 表示サイズを小さくしても転送量は減りません。全プレイヤーが PNG 全体をダウンロード
   します。画像ファイル自体を圧縮してください (パネルの本文領域は約 950 px 幅なので、
   それを超えるピクセルは表示時に縮小されるだけで無駄になります)。
7. このファイルは画像スキャナーに無視されます (.png のみが対象)。自由に編集・追記・
   削除できます。存在しない場合のみ再作成され、編集した内容が上書きされることは
   ありません。拡張子を .png に変更しないでください: 画像として扱われ、壊れた画像と
   して全プレイヤーに同期され、上記の上限を無駄に消費します。
