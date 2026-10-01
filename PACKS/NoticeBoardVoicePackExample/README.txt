================================================================================
  Notice Board - Server Voice Pack (example)
  EN English / CH 繁體中文 / CN 简体中文 / JP 日本語
================================================================================

This folder is a template: a tiny mod that carries only your announcement voice
for Minidoracat Notice Board
(https://steamcommunity.com/sharedfiles/filedetails/?id=3789836823).
Make your own copy, put your recording in it, upload it to the Steam Workshop
and add it to your server. Players download it automatically when they join.

--------------------------------------------------------------------------------
[EN] English
--------------------------------------------------------------------------------
WHO HEARS IT: players whose voice setting is "Auto" (the default) hear your
voice when a new notice arrives. While your pack is active, the Voice menu of
the notice panel shows "Auto (server voice)". Players who picked a language
voice or the original sound keep their choice. If your file cannot be played,
the built-in voice is used instead.

1. COPY: copy this whole folder (the one with preview.png and Contents) to
   %USERPROFILE%\Zomboid\Workshop\ . You may rename that folder.
2. YOUR OWN ID: open
   Contents\mods\NoticeBoardVoicePackExample\42\mod.info and change
   id=NoticeBoardVoicePackExample to an id of your own (letters, digits, "_",
   "-" or "."; it must not start with "Minidoracat"). Rename the folder
   Contents\mods\NoticeBoardVoicePackExample to the same id, and change name=
   and description= too. Two packs with the same id overwrite each other for
   players who have both installed, so the server log warns you while the
   example id is still in use.
3. YOUR VOICE: put your recording in 42\media\sound\ named exactly
   MinidoracatNBVoiceServer.ogg (or .wav), and delete the sample
   MinidoracatNBVoiceServer.wav (a one-second chime). Keep it short: the
   whole file is loaded into memory. Make it about as loud as the built-in
   voices (peaks around -8 dB): the game's sound volume does not change it,
   players only have the Notice Board volume slider.
4. PREVIEW IMAGE (optional): preview.png is the Workshop thumbnail. The
   in-game uploader only accepts a square PNG of 256x256 or 512x512, at most
   1,024,000 bytes.
5. TEST IN SINGLE PLAYER (optional): while Steam is running, the Mods screen
   also lists the folders in Zomboid\Workshop. Enable your pack together with
   Notice Board, start a game and open the notice panel > Voice: the item
   below the original sound should read "Auto (server voice)"; pick it to
   hear your voice. Without Steam, copy Contents\mods\<your id> to
   %USERPROFILE%\Zomboid\mods\ instead.
6. UPLOAD: use the in-game Workshop uploader (main menu > Workshop) and pick
   this folder. The Workshop ID is the number in the address of the item's
   Workshop page.
7. SERVER: in your server ini, add \<your id> to Mods= and the Workshop ID to
   WorkshopItems=, then restart the server.
8. CHANGING THE VOICE LATER: replace the file, update the Workshop item and
   restart the server. Players get the new voice the next time they join.

Do not add Lua or script files. Keep common\ and the AnimSets / actiongroups
placeholder files: without them the game logs four "missing folder" errors
for this pack on every start.

--------------------------------------------------------------------------------
[CH] 繁體中文
--------------------------------------------------------------------------------
誰會聽到：語音設定是「自動」（預設值）的玩家，有新公告時會聽到你的語音。你的包啟用時，
公告面板的「語音」選單會顯示「自動（使用伺服器語音）」。自己選了某個語言語音或原提示音的
玩家維持原本的選擇。你的音檔播放失敗時，改用內建語音。

1. 複製：把整個資料夾（有 preview.png 和 Contents 的這一層）複製到
   %USERPROFILE%\Zomboid\Workshop\ ，資料夾名稱可以改。
2. 改成你自己的 id：打開 Contents\mods\NoticeBoardVoicePackExample\42\mod.info，
   把 id=NoticeBoardVoicePackExample 改成你自己的 id（英數字、「_」、「-」或「.」，
   不能以 Minidoracat 開頭），並把 Contents\mods\NoticeBoardVoicePackExample 資料夾
   改成同樣的名稱；name= 與 description= 也一起改。兩個包 id 相同時，兩個都裝的玩家
   只會載入其中一個，所以還在用範例 id 時，伺服器 log 會提醒你。
3. 放你的語音：錄音檔放在 42\media\sound\，檔名必須是 MinidoracatNBVoiceServer.ogg
   （或 .wav），並刪掉範例的 MinidoracatNBVoiceServer.wav（一秒鐘的叮咚聲）。
   請保持簡短：整個檔案會載入記憶體。音量做得和內建語音差不多（峰值約 -8 dB）：
   遊戲的音效音量管不到它，玩家只能用公告欄的音量滑桿調整。
4. 預覽圖（可選）：preview.png 是 Workshop 顯示的縮圖。遊戲內上傳器只接受 256x256
   或 512x512 的正方形 PNG，大小不超過 1,024,000 bytes。
5. 單機測試（可選）：Steam 開著時，模組清單也會列出 Zomboid\Workshop 裡的資料夾。
   把你的包和公告欄一起啟用、開一局遊戲，打開公告面板 > 語音：原提示音下面那一項
   應該顯示「自動（使用伺服器語音）」，點它就能試聽。沒有 Steam 時，改把
   Contents\mods\<你的 id> 複製到 %USERPROFILE%\Zomboid\mods\。
6. 上傳：用遊戲內的 Workshop 上傳器（主選單 > Workshop），選這個資料夾。
   Workshop ID 是該項目 Workshop 頁面網址裡的那串數字。
7. 伺服器：在伺服器 ini 的 Mods= 加上 \<你的 id>，WorkshopItems= 加上 Workshop ID，
   然後重啟伺服器。玩家進服時會自動下載。
8. 之後換語音：替換音檔、更新 Workshop 項目並重啟伺服器，玩家下次進服就會拿到新語音。

不要放 Lua 或 script 檔。common\ 與 AnimSets／actiongroups 的佔位檔請保留：少了它們，
遊戲每次啟動都會為這個包記 4 行「找不到資料夾」的錯誤。

--------------------------------------------------------------------------------
[CN] 简体中文
--------------------------------------------------------------------------------
谁会听到：语音设置为「自动」（默认值）的玩家，有新公告时会听到你的语音。你的包启用时，
公告面板的「语音」菜单会显示「自动（使用服务器语音）」。自己选了某个语言语音或原提示音的
玩家保持原来的选择。你的音频文件播放失败时，改用内置语音。

1. 复制：把整个文件夹（有 preview.png 和 Contents 的这一层）复制到
   %USERPROFILE%\Zomboid\Workshop\ ，文件夹名称可以改。
2. 改成你自己的 id：打开 Contents\mods\NoticeBoardVoicePackExample\42\mod.info，
   把 id=NoticeBoardVoicePackExample 改成你自己的 id（英文字母、数字、「_」、「-」或「.」，
   不能以 Minidoracat 开头），并把 Contents\mods\NoticeBoardVoicePackExample 文件夹
   改成同样的名称；name= 与 description= 也一起改。两个包 id 相同时，两个都装的玩家
   只会加载其中一个，所以仍在使用示例 id 时，服务器 log 会提醒你。
3. 放入你的语音：录音文件放在 42\media\sound\，文件名必须是 MinidoracatNBVoiceServer.ogg
   （或 .wav），并删除示例的 MinidoracatNBVoiceServer.wav（一秒钟的叮咚声）。
   请尽量简短：整个文件会加载到内存。音量做得和内置语音差不多（峰值约 -8 dB）：
   游戏的音效音量管不到它，玩家只能用公告栏的音量滑块调整。
4. 预览图（可选）：preview.png 是 Workshop 显示的缩略图。游戏内上传器只接受 256x256
   或 512x512 的正方形 PNG，大小不超过 1,024,000 bytes。
5. 单机测试（可选）：Steam 运行时，模组列表也会列出 Zomboid\Workshop 里的文件夹。
   把你的包和公告栏一起启用、开一局游戏，打开公告面板 > 语音：原提示音下面那一项
   应该显示「自动（使用服务器语音）」，点它就能试听。没有 Steam 时，改为把
   Contents\mods\<你的 id> 复制到 %USERPROFILE%\Zomboid\mods\。
6. 上传：使用游戏内的 Workshop 上传器（主菜单 > Workshop），选择这个文件夹。
   Workshop ID 是该项目 Workshop 页面网址里的那串数字。
7. 服务器：在服务器 ini 的 Mods= 加上 \<你的 id>，WorkshopItems= 加上 Workshop ID，
   然后重启服务器。玩家进服时会自动下载。
8. 之后更换语音：替换音频文件、更新 Workshop 项目并重启服务器，玩家下次进服就会拿到新语音。

不要放 Lua 或 script 文件。common\ 与 AnimSets／actiongroups 的占位文件请保留：少了它们，
游戏每次启动都会为这个包记录 4 行「找不到文件夹」的错误。

--------------------------------------------------------------------------------
[JP] 日本語
--------------------------------------------------------------------------------
聞こえるプレイヤー：音声設定が「自動」（既定）のプレイヤーは、新しいお知らせが届いたときに
この音声を聞きます。パックが有効な間、お知らせパネルの「音声」メニューには
「自動（サーバーの音声）」と表示されます。言語の音声や元の通知音を自分で選んだプレイヤーは、
その選択のままです。音声ファイルを再生できない場合は内蔵の音声が使われます。

1. コピー：このフォルダー全体（preview.png と Contents がある階層）を
   %USERPROFILE%\Zomboid\Workshop\ にコピーします。フォルダー名は変えてかまいません。
2. 独自の id：Contents\mods\NoticeBoardVoicePackExample\42\mod.info を開き、
   id=NoticeBoardVoicePackExample を独自の id（英数字・「_」・「-」・「.」、Minidoracat で
   始めない）に変えます。Contents\mods\NoticeBoardVoicePackExample フォルダーも同じ名前に
   変え、name= と description= も書き換えてください。同じ id のパックが二つあると、両方を
   入れたプレイヤーにはどちらか一方しか読み込まれません。そのため例の id のままだと、
   サーバーのログに警告が出ます。
3. 音声を入れる：録音を 42\media\sound\ に MinidoracatNBVoiceServer.ogg（または .wav）
   という名前で置き、サンプルの MinidoracatNBVoiceServer.wav（1 秒のチャイム）を削除します。
   ファイル全体がメモリに読み込まれるので短めにしてください。音量は内蔵の音声と同じくらい
   （ピーク約 -8 dB）にします。ゲームの効果音の音量設定は効かず、プレイヤーはお知らせボードの
   音量スライダーでしか調整できません。
4. プレビュー画像（任意）：preview.png は Workshop のサムネイルです。ゲーム内アップローダーは
   256x256 または 512x512 の正方形 PNG で、1,024,000 bytes 以下のものしか受け付けません。
5. シングルプレイで試す（任意）：Steam の起動中は、MOD 一覧に Zomboid\Workshop の
   フォルダーも表示されます。パックをお知らせボードと一緒に有効にしてゲームを始め、
   お知らせパネル > 音声 を開くと、元の通知音の次の項目が「自動（サーバーの音声）」に
   なっているはずです。選ぶと試聴できます。Steam を使わない場合は
   Contents\mods\<独自の id> を %USERPROFILE%\Zomboid\mods\ にコピーしてください。
6. アップロード：ゲーム内の Workshop アップローダー（メインメニュー > Workshop）で
   このフォルダーを選びます。Workshop ID はアイテムの Workshop ページのアドレスにある数字です。
7. サーバー：サーバーの ini の Mods= に \<独自の id> を、WorkshopItems= に Workshop ID を
   追加して、サーバーを再起動します。プレイヤーは参加時に自動でダウンロードします。
8. 音声を後から変える：ファイルを差し替えて Workshop アイテムを更新し、サーバーを
   再起動します。プレイヤーは次に参加したときに新しい音声を受け取ります。

Lua やスクリプトのファイルは入れないでください。common\ と AnimSets／actiongroups の
プレースホルダーファイルは残してください。これがないと、ゲームの起動のたびにこのパックに
ついて「フォルダーが見つからない」エラーが 4 行記録されます。
