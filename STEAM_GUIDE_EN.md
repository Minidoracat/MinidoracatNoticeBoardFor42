<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817843667 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Notice Board Mod Guide: Server Owner Manual & Markdown -->
<!-- 摘要：Illustrated guide to the Minidoracat Notice Board mod: where notices live, file names and languages, categories, supported Markdown and images, search, notification sound and voice, admin tools and sandbox options. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817843626]公告板 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3789836823
[list]
[*] [b]Requires[/b]: Build 42.20.2+ and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url].
[*] [b]Multiplayer[/b]: the server must enable this mod.
[/list]
{{img:01-panel-document-tree.jpg}}
[olist]
[*] [b]Start once[/b]: enable the mod and start the server (or a singleplayer game) once. If there are no notices yet, EN and CH starter examples are created.
[*] [b]Write notices[/b]: open the notice folder (see "Where notices live") and edit the examples or add your own .md / .txt notices.
[*] [b]Save[/b]: online players get it with a new-notice alert within one polling interval (default 60s), or at once when an admin presses Reload on the panel.
[*] [b]Players open the board[/b]: click the speaker icon in the family toolbar, or press Insert. A red dot means unread notices, and hovering it shows "You have unread notices."
[/olist]
[list]
[*] If the UI Library hasn't been updated yet, a draggable floating speaker icon is used instead.
[*] The button can be hidden; see "Board button & shortcut".
[/list]
=== 🧰 Where notices live
{{img:03-server-language-folders.jpg}}
In [b]Lua/NoticeBoard/[/b] inside the Zomboid folder, not in the mod, so editing notices never needs a Workshop update.
[list]
[*] [b]Dedicated server[/b]: Zomboid/Lua/NoticeBoard/ on the server machine (under your -cachedir if you set one)
[*] [b]Co-op host and singleplayer[/b]: %USERPROFILE%/Zomboid/Lua/NoticeBoard/ on the host's PC
[/list]
[h3]Language folders[/h3]
[list]
[*] [b]One subfolder per language[/b]: use the PZ language code (uppercase), e.g. NoticeBoard/EN/, CH/ (Traditional Chinese), CN/ (Simplified), JP/.
[*] [b]Valid codes[/b]: the sandbox "Default notice language" dropdown lists them all.
[*] [b]Shown automatically[/b]: languages with notices appear in the players' Language menu.
[/list]
[h3]File names and order[/h3]
[list]
[*] [b]Format[/b]: .md or .txt, named "number_name", e.g. 10_welcome.md.
[*] [b]Characters[/b]: only ASCII letters, digits, _ and -; put other text inside the file.
[*] [b]Order[/b]: sorted by number prefix; leave gaps (10_, 20_, 30_) for later inserts.
[*] [b]Sidebar name[/b]: the first "# heading", or the file name if none. Hover a cut-off name to see it in full.
[*] [b]The file name is the notice ID[/b]: use the same name (with extension) in every language. Renaming makes it a new notice and notifies players again.
[*] [b]Limits[/b]: 200 KB per file; 200 notices and 512 KB per language. Past that, the highest prefixes are dropped.
[/list]
=== 🧰 Languages and categories
{{img:02-language-menu.jpg}}
[h3]Which notices each player sees[/h3]
[list]
[*] [b]Shared baseline[/b]: the sandbox "Default notice language" folder (default EN), shown to every language.
[*] [b]Translations replace it[/b]: a same-named file in the player's language folder replaces it; untranslated notices fall back to the baseline, so one version is enough.
[*] [b]One language only[/b]: add .only to the name, e.g. EN/20_notice.only.txt. Marked files are never used as baseline.
[*] [b]Switching[/b]: players can follow the game language or pick one in the panel's Language menu.
[*] [b]Fonts[/b]: text uses the font of the player's game language; see "Known limitations".
[/list]
[h3]Categories (optional)[/h3]
[list]
[*] [b]Declare[/b]: in NoticeBoard/categories.txt, one label per line: key|language|name, e.g. 10_news|EN|News.
[*] [b]Create the folders yourself[/b]: the file only declares; create NoticeBoard/<LANG>/<key>/ yourself. Undeclared folders are not read.
[*] [b]Keys[/b]: ASCII letters, digits, _ and -; the number prefix sets sidebar order. Max 32 categories.
[*] [b]General[/b]: root notices go under "General".
[*] [b]Unique names[/b]: file names must be unique across a language's categories.
[/list]
=== 🧰 Supported Markdown
The game's text panel has no bold or italic fonts, so some styles become colors. Anything not listed shows as plain text; for what isn't supported, see "Known limitations".
[h3]Blocks[/h3]
[table]
[tr][th]Syntax[/th][th]Result[/th][/tr]
[tr][td]# heading[/td][td]Large, white, centered[/td][/tr]
[tr][td]##[/td][td]Medium, light gray[/td][/tr]
[tr][td]###[/td][td]Same size, cyan[/td][/tr]
[tr][td]#### to ######[/td][td]Body size, each dimmer[/td][/tr]
[tr][td]Paragraphs[/td][td]Blank line between; a single line break joins the paragraph. Force a break with two trailing spaces or a trailing \ (backslash)[/td][/tr]
[tr][td]Lists: - * +[/td][td]Bullets; 1. auto-numbered; indent 2+ spaces to nest, up to 4 levels[/td][/tr]
[tr][td]Quotes: >[/td][td]Gray and indented, up to 4 levels[/td][/tr]
[tr][td]Rule: --- / *** / ___ on its own line[/td][td]A horizontal rule[/td][/tr]
[tr][td]Code block: fence with ```[/td][td]Light blue, not parsed[/td][/tr]
[/table]
[h3]Inline[/h3]
[table]
[tr][th]Syntax[/th][th]Result[/th][/tr]
[tr][td]**bold** / __bold__[/td][td][b]Amber[/b] text[/td][/tr]
[tr][td]*italic* / _italic_[/td][td][b]Green[/b] text; bold italic shows green[/td][/tr]
[tr][td]`inline code`[/td][td][b]Pink[/b] text, backticks kept[/td][/tr]
[tr][td]~~strike~~[/td][td]Markers removed, text shown normally[/td][/tr]
[tr][td][text](https://url) or <https://url>[/td][td]Blue link; clicking copies it, and official PZ and Steam Community links also try to open. Bare URLs aren't linked[/td][/tr]
[tr][td]![caption](images/name.png)[/td][td]Image, optional " =WxH"; see "Images"[/td][/tr]
[/table]
=== 🧰 Images
[list]
[*] [b]Where[/b]: put PNGs in NoticeBoard/images/ (shared by all languages) and write ![caption](images/name.png).
[*] [b]Synced for you[/b]: the server syncs them to players: no texture-pack mod, nothing extra to subscribe to.
[*] [b]Format[/b]: PNG only; names use ASCII letters, digits, _ and -, max 64 characters, no "." in the base name.
[*] [b]Size[/b]: ![caption](images/a.png =600x200), or =600x / =x200 to keep the aspect ratio. A space before "=" is required; a malformed size shows the line as raw text.
[*] [b]Width[/b]: the panel is about 950px wide; wider images are scaled down, so shrink files first.
[*] [b]Updates[/b]: adding, deleting or overwriting takes effect on the next poll.
[/list]
[h3]Limits[/h3]
[table]
[tr][th]Limit[/th][th]Default[/th][th]Sandbox max[/th][/tr]
[tr][td]Per image[/td][td]512 KB[/td][td]4096 KB[/td][/tr]
[tr][td]Images[/td][td]20[/td][td]200[/td][/tr]
[tr][td]Total[/td][td]4 MB[/td][td]16384 KB[/td][/tr]
[/table]
Players download it all on first join (16 MB ≈ 3 min in the background).
=== 🧰 Searching notices
The search box at the top of the sidebar searches every notice in the current notice language at once.
[list]
[*] [b]Type a keyword[/b]: the list keeps only notices with matches, with every category expanded. Case and extra spaces don't matter.
[*] [b]Typing doesn't switch notices[/b]: it never switches the open notice or marks anything as read.
[*] [b]Enter[/b]: opens the first matching notice and scrolls to the match. Every match is highlighted, the current one also gets an outline, and the line under the box shows "N of M in this notice".
[*] [b]Next / previous[/b]: press Enter again for the next match; after the last match in a notice it moves on to the next notice. Shift+Enter goes back.
[*] [b]End the search[/b]: press Esc or the clear button in the search box; the list goes back to how you had it expanded.
[*] [b]What counts[/b]: only text you can see; link addresses, image paths and Markdown symbols are ignored.
[/list]
=== 🧰 Board button & shortcut
[list]
[*] [b]Shown by default[/b]: the speaker icon in the family toolbar, or a draggable floating speaker button when there is no toolbar.
[*] [b]Hide it[/b]: in the notice board settings under Options → MODS, untick "Show Server Notice Board button" and press Apply; it takes effect at once.
[*] [b]While hidden[/b]: new notices don't bring the button back, and the board still pops up following the server's popup mode.
[*] [b]Shortcut[/b]: press Insert to open the board (it also works while the button is shown).
[*] [b]Change the key[/b]: Options → Key Bindings, "Minidoracat Notice Board", "Toggle notice board".
[*] [b]Get the button back[/b]: tick the same option again.
[/list]
=== 🧰 Notification sound & voice
New or updated notices play one sound per batch, set per player at the top of the panel.
[list]
[*] [b]Voice menu[/b]: Auto (default; matches a Chinese or Japanese game, else English), Chinese, English, Japanese or "Original sound (no voice)".
[list]
[*] Traditional and Simplified Chinese share the Chinese voice.
[*] This menu only picks the voice language; the language of the notice text is picked separately in the Language menu.
[/list]
[*] [b]Speaker[/b]: the menu's last item, "Voice: …", picks Stacy (sweet, default), Yui (gentle) or Classic (the voice before this update); all three speak Chinese, English and Japanese.
[*] [b]Volume[/b]: the slider takes a drag or the mouse wheel (5% per notch) and plays a preview. It is the same setting as Options → MODS, where the sound can also be turned off.
[/list]
[h3]Server voice pack (optional, for server owners)[/h3]
[list]
[*] [b]What it is[/b]: to play your own recorded line for new notices, make a small MOD that only holds the audio file, upload it to the Workshop and add it to the server's Mods= and WorkshopItems=.
[*] [b]Who hears it[/b]: players whose voice setting is Auto hear that line, and the menu shows "Auto (server voice)".
[*] [b]Template download[/b]: [url=https://github.com/Minidoracat/MinidoracatNoticeBoardFor42/releases/latest/download/NoticeBoardVoicePackExample.zip]NoticeBoardVoicePackExample.zip[/url], then follow the README.txt inside (four languages).
[*] [b]Before uploading[/b]: give the pack its own id.
[/list]
=== ⚙️ Admin tools
On the notice panel, admins only (the server re-checks permissions).
[list]
[*] [b]Reload[/b]: re-reads and pushes all notices and images now, the fastest way for urgent notices. The polling interval can also go down to 10s.
[*] [b]Rebuild examples[/b]: pick Traditional Chinese or English to write a full reference set (every supported syntax, categories, .only), pushed at once.
[*] [b]What it writes[/b]: 5 fixed files (root README.txt and categories.txt, plus 3 notices in that language); other notices, the other language and images/ are untouched.
[*] [b]Warning[/b]: the root categories.txt is replaced (only 10_news and 20_rules remain) and edits to those 5 files are reverted; back up first.
[/list]
=== ⚙️ Sandbox options and defaults
{{img:04-sandbox-options.jpg}}
The sandbox options are on the "Minidoracat Notice Board" page.
[table]
[tr][th]Option[/th][th]Default[/th][th]Notes[/th][/tr]
[tr][td]Automatic popup mode[/td][td]Unread notices only[/td][td]Also: Always, Never. Players can always open the board with the toolbar speaker icon or Insert[/td][/tr]
[tr][td]Notice polling interval[/td][td]60s[/td][td]10–3600[/td][/tr]
[tr][td]Default notice language[/td][td]EN[/td][td]The baseline language[/td][/tr]
[tr][td]Play a sound for new notices[/td][td]On[/td][td]Server-wide switch for the notice sound and voice[/td][/tr]
[tr][td]Max image size (KB)[/td][td]512[/td][td]Up to 4096[/td][/tr]
[tr][td]Max number of images[/td][td]20[/td][td]Up to 200[/td][/tr]
[tr][td]Max total image size (KB)[/td][td]4096[/td][td]Up to 16384[/td][/tr]
[/table]
=== ⚠️ Known limitations
[list]
[*] [b]No font fallback[/b]: text uses the font of the player's game language. The English font lacks Chinese and Japanese, the Chinese font lacks kana; missing characters show as ? or blanks.
[*] [b]No bold or italic fonts[/b]: they become colors; see "Supported Markdown".
[*] [b]Tables are not supported[/b]: use lists or code blocks.
[*] [b]No emoji[/b]: game fonts have none (shown as ? or nothing). Don't rely on emoji; use a PNG for pictures.
[*] [b]Overwriting an image[/b]: an overwrite with the exact same byte size isn't detected; press Reload or use a new name.
[/list]
=== ❓ FAQ
[h3]Can the board pop up automatically when players join?[/h3]
[list]
[*] Yes. Set the sandbox option "Minidoracat Notice Board → Automatic popup mode" to "Always".
[*] By default it only pops up when there are unread notices.
[/list]
[h3]I edited a notice but players don't see it?[/h3]
[list]
[*] Wait one polling interval or press Reload.
[*] Then check the file is in Zomboid/Lua/NoticeBoard/ (not the mod folder), the language folder is uppercase, the category is declared and the name is ASCII.
[*] Server log lines tagged [MinidoracatNoticeBoardFor42] say why a file was skipped.
[/list]
[h3]The notice board button is gone?[/h3]
[list]
[*] It was probably hidden: tick "Show Server Notice Board button" under Options → MODS to bring it back.
[*] Or just press Insert to open the board.
[/list]
[h3]Why do bold and italic turn into colors?[/h3]
[list]
[*] The game's text panel has no bold or italic fonts.
[*] Real bold would mean replacing fonts other game screens use, or shipping a font set per language (tens of MB for Chinese alone); we judged it not worth it, so colors are used instead (see "Supported Markdown").
[/list]
[h3]Images show only a [caption] placeholder?[/h3]
[list]
[*] It's still syncing right after you add an image or join.
[*] If it never appears, check it's a PNG with a valid name, the path is right and the limits aren't exceeded.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatNoticeBoardFor42/issues]GitHub Issues[/url][/b]: please include (remove private server details)
[list]
[*] game and mod versions
[*] SP or MP
[*] the problem notice text
[*] log lines
[/list]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]
[/list]
