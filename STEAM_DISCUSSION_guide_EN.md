<!-- Steam 討論區貼文稿源（英文）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3789836823/586187095760095724/ -->
<!-- 標題：📖 Notice Board Guide: Server Owner Manual & Markdown -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3789836823/586187095760095709/]Notice Board 完整說明：服主手冊與 Markdown 語法[/url]

[h2]🚀 Quick start[/h2]
[list]
[*] Requires Build 42.20.2+ and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url]. In multiplayer the server must enable this mod.
[/list]
[olist]
[*] Enable the mod and start the server (or a singleplayer game) once. If there are no notices yet, EN and CH starter examples are created.
[*] Open the notice folder (below) and edit the examples or add your own .md / .txt notices.
[*] Save: online players get it with a new-notice alert within one polling interval (default 60s), or at once when an admin presses Reload on the panel.
[*] Players click the speaker icon in the family toolbar to open or close the board. A red dot means unread notices, and hovering it shows "You have unread notices." If the UI Library hasn't been updated yet, a draggable floating speaker icon is used instead. Insert also opens or closes the board, and the button can be hidden; see "Board button & shortcut" below.
[/olist]

[h2]📁 Where notices live[/h2]
In [b]Lua/NoticeBoard/[/b] inside the Zomboid folder, not in the mod, so editing notices never needs a Workshop update.
[list]
[*] [b]Dedicated server[/b]: Zomboid/Lua/NoticeBoard/ on the server machine (under your -cachedir if you set one)
[*] [b]Co-op host and singleplayer[/b]: %USERPROFILE%/Zomboid/Lua/NoticeBoard/ on the host's PC
[/list]

[h3]Language folders[/h3]
[list]
[*] One subfolder per PZ language code (uppercase), e.g. NoticeBoard/EN/, CH/ (Traditional Chinese), CN/ (Simplified), JP/. The sandbox "Default notice language" dropdown lists all valid codes. Languages with notices appear automatically in the players' Language menu.
[/list]

[h3]File names and order[/h3]
[list]
[*] .md or .txt, named "number_name", e.g. 10_welcome.md. Use only ASCII letters, digits, _ and -; put other text inside the file.
[*] Sorted by number prefix; leave gaps (10_, 20_, 30_) for later inserts.
[*] The sidebar shows the first "# heading", or the file name if none.
[*] The file name is the notice ID: use the same name (with extension) in every language. Renaming makes it a new notice and notifies players again.
[*] Limits: 200 KB per file; 200 notices and 512 KB per language. Past that, the highest prefixes are dropped.
[/list]

[h3]Which notices each player sees[/h3]
[list]
[*] The sandbox "Default notice language" folder (default EN) is the [b]shared baseline[/b], shown to every language.
[*] A same-named file in the player's language folder replaces it; untranslated notices fall back to the baseline, so one version is enough.
[*] For one language only, add .only to the name, e.g. EN/20_notice.only.txt. Marked files are never used as baseline.
[*] Players can follow the game language or pick one in the panel's Language menu.
[*] Text uses the font of the player's game language with no fallback: the English font lacks Chinese and Japanese, the Chinese font lacks kana; missing characters show as ? or blanks.
[/list]

[h3]Categories (optional)[/h3]
[list]
[*] In NoticeBoard/categories.txt, one label per line: key|language|name, e.g. 10_news|EN|News.
[*] It only declares; create NoticeBoard/<LANG>/<key>/ yourself. Undeclared folders are not read.
[*] Keys: ASCII letters, digits, _ and -; the number prefix sets sidebar order. Max 32 categories.
[*] Root notices go under "General". File names must be unique across a language's categories.
[/list]

[h2]🖼️ Images[/h2]
[list]
[*] Put PNGs in NoticeBoard/images/ (shared by all languages) and write ![caption](images/name.png). The server syncs them to players: no texture-pack mod, nothing extra to subscribe to.
[*] PNG only; names use ASCII letters, digits, _ and -, max 64 characters, no "." in the base name.
[*] Size: ![caption](images/a.png =600x200), or =600x / =x200 to keep the aspect ratio. A space before "=" is required; a malformed size shows the line as raw text.
[*] Defaults: 512 KB per image, 20 images, 4 MB total; sandbox allows up to 4096 KB / 200 / 16384 KB. Players download it all on first join (16 MB ≈ 3 min in the background).
[*] The panel is about 950px wide; wider images are scaled down, so shrink files first.
[*] Adding, deleting or overwriting takes effect on the next poll. An overwrite with the exact same byte size isn't detected; press Reload or use a new name.
[/list]

[h2]🔊 Notification sound & voice[/h2]
New or updated notices play one sound per batch, set per player at the top of the panel:
[list]
[*] [b]Voice[/b] menu: Auto (default; matches a Chinese or Japanese game, else English), Chinese, English, Japanese or "Original sound (no voice)". Its last item, "Voice: …", picks the speaker: Stacy (default), Yui or Classic.
[*] The volume slider takes a drag or the mouse wheel (5% per notch) and plays a preview. It is the same setting as Options → MODS, where the sound can also be turned off.
[*] [b]Server voice pack (optional, for server owners)[/b]: to play your own recorded line for new notices, make a small MOD that only holds the audio file, upload it to the Workshop and add it to the server's Mods= and WorkshopItems=. Players whose voice setting is Auto hear that line, and the menu shows "Auto (server voice)". Template download: [url=https://github.com/Minidoracat/MinidoracatNoticeBoardFor42/releases/latest/download/NoticeBoardVoicePackExample.zip]NoticeBoardVoicePackExample.zip[/url], then follow the README.txt inside (four languages). Give the pack its own id before uploading.
[/list]

[h2]🎛️ Board button & shortcut[/h2]
[list]
[*] The board button is shown by default: the speaker icon in the family toolbar, or a draggable floating speaker button when there is no toolbar.
[*] [b]Hide it[/b]: in the notice board settings under Options → MODS, untick "Show Server Notice Board button" and press Apply; it takes effect at once. New notices don't bring the button back, and the board still pops up following the server's popup mode.
[*] [b]Open the board while hidden[/b]: press Insert (it also works while the button is shown). To change the key, go to Options → Key Bindings, "Minidoracat Notice Board", "Toggle notice board".
[*] To get the button back, tick the same option again.
[/list]

[h2]🛠️ Admin tools[/h2]
On the notice panel, admins only (the server re-checks permissions).
[list]
[*] [b]Reload[/b]: re-reads and pushes all notices and images now, the fastest way for urgent notices. The polling interval can also go down to 10s.
[*] [b]Rebuild examples[/b]: pick Traditional Chinese or English to write a full reference set (every supported syntax, categories, .only), pushed at once.
[*] It writes 5 fixed files (root README.txt and categories.txt, plus 3 notices in that language); other notices, the other language and images/ are untouched.
[*] [b]Warning[/b]: the root categories.txt is replaced (only 10_news and 20_rules remain) and edits to those 5 files are reverted; back up first.
[/list]

[h2]⚙️ Sandbox options (Minidoracat Notice Board)[/h2]
[list]
[*] [b]Automatic popup mode[/b]: Always / Unread notices only (default) / Never. Players can always open the board with the toolbar speaker icon or Insert.
[*] [b]Notice polling interval[/b]: 60s default, 10–3600.
[*] [b]Default notice language[/b]: the baseline language, default EN.
[*] [b]Play a sound for new notices[/b]: server-wide switch for the notice sound and voice.
[/list]

[h2]✍️ Supported Markdown[/h2]
The game's text panel has no bold or italic fonts, so some styles become colors. Anything not listed shows as plain text.
[list]
[*] # large, white, centered; ## medium light gray; ### same size, cyan; #### to ###### body size, each dimmer.
[*] Paragraphs: blank line between; a single line break joins the paragraph. Force a break with two trailing spaces or a trailing \.
[*] Lists: - * + bullets; 1. auto-numbered; indent 2+ spaces to nest, up to 4 levels.
[*] Quotes: >, gray and indented, up to 4 levels.
[*] Rule: --- / *** / ___ on its own line.
[*] Code block: fence with ```; light blue, not parsed.
[*] **bold** / __bold__ → [b]amber[/b] text.
[*] *italic* / _italic_ → [b]green[/b] text; bold italic shows green.
[*] `inline code` → [b]pink[/b] text, backticks kept.
[*] ~~strike~~ → markers removed, text shown normally.
[*] [text](https://url) or <https://url> → blue link; clicking copies it, and official PZ and Steam Community links also try to open. Bare URLs aren't linked.
[*] Images: ![caption](images/name.png), optional " =WxH".
[*] [b]Tables are not supported[/b]; use lists or code blocks.
[*] Game fonts have [b]no emoji[/b] (shown as ? or nothing). Don't rely on emoji; use a PNG for pictures.
[/list]

[h2]❓ FAQ[/h2]
[b]Q: I edited a notice but players don't see it.[/b]
A: Wait one polling interval or press Reload. Then check the file is in Zomboid/Lua/NoticeBoard/ (not the mod folder), the language folder is uppercase, the category is declared and the name is ASCII. Server log lines tagged [MinidoracatNoticeBoardFor42] say why a file was skipped.

[b]Q: The notice board button is gone.[/b]
A: It was probably hidden: tick "Show Server Notice Board button" under Options → MODS to bring it back, or just press Insert to open the board.

[b]Q: Images show only a [caption] placeholder.[/b]
A: It's still syncing right after you add an image or join. If it never appears, check it's a PNG with a valid name, the path is right and the limits aren't exceeded.

[h2]📝 Reporting issues[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatNoticeBoardFor42/issues]GitHub Issues[/url]: include game/mod versions, SP or MP, the problem notice text and log lines (remove private server details).
[*] [url=https://discord.gg/Gur2V67]Discord[/url]
[/list]
