[h1]📢 Minidoracat Notice Board for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⚠️ Required dependency[/h2]
This mod requires [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]Minidoracat UI Library for B42[/b][/url] (the shared UI library). Please subscribe to it as well — see Required Items on this page. Without it this mod will not load.

[hr][/hr]

[h2]✨ What is this[/h2]
An in-game notice board. Write announcements in Markdown, edit the files directly, and the board refreshes on the server polling interval (default 60s; admins can force an immediate reload). Multiple files appear in a collapsible document tree, while server owners can define custom categories and localized notice sets; players can follow their game language or switch among the languages provided by the server (up to 200 files per language).

[h2]🧰 Features[/h2]
[list]
[*] [b]Markdown announcements[/b]: write your notices in Markdown and they are laid out and rendered in game
[*] [b]Near-live updates[/b]: save the file and the change shows up in game within the server polling interval (default 60s), no server restart needed
[*] [b]Document tree and custom categories[/b]: each .md/.txt file is a separate notice; declare translated categories in NoticeBoard/categories.txt, place files in the matching folders, and players can navigate them from a collapsible sidebar; the toolbar provides one-click expand-all and collapse-all buttons so players never have to click individual categories
[*] [b]Custom notice languages[/b]: create a NoticeBoard/<LANG>/ folder using any supported PZ language code and add .md/.txt notices; every language that actually contains notices appears automatically in the toolbar, where players can follow their game language or switch manually
[*] [b]One-click example rebuild (admins only)[/b]: the Rebuild Examples button in the panel toolbar asks the admin to pick a language (Traditional Chinese or English), then the server writes that language's complete example set — three sample notices plus the root README.txt and categories.txt — straight into the live notice folders and refreshes immediately. It is always the same 5 files: the other language, your own notices and images/ are never touched. The trade-off is that the root categories.txt is overwritten, which the menu label warns you about up front
[*] [b]Images in your notices, synced to every player[/b]: drop PNG files into the server's NoticeBoard/images/ folder and reference them from your notices — the server streams them to each player's local cache in chunks, so [b]you never have to build a texture-pack mod and players never have to subscribe to anything extra[/b]. Overwrite a file in place and the new image goes live on the next poll
[*] [b]Display size and storage are both under your control[/b]: the Markdown image syntax takes an explicit display size (give only width or height and the other side follows the original aspect ratio); image count, per-file size and total budget are sandbox options, while the client-side cache is bounded, evicts the least recently used images automatically, and resumes an interrupted transfer from the missing part instead of restarting it
[/list]

[h2]⚠️ Display limitations and trade-offs[/h2]
Notices are rendered by the game's built-in text panel, which only knows two styles: color and font size. It has no bold, italic, monospace or strikethrough fonts. Getting a real bold font in there would mean either replacing a font that other game screens already use (changing those screens too), or shipping our own bold fonts and doing the layout ourselves — and since notices support every language the game does, that means a separate font set per script just like the game itself (Chinese, Japanese, Korean, Thai, Cyrillic, ... one per font-size setting; the Chinese set alone is 10,000+ glyphs and tens of MB), and any script we missed would simply render blank. We decided that isn't worth it, so styles are shown as colors instead:
[list]
[*] [b]Bold[/b] shows as amber text, [b]italic[/b] as green text, and [b]inline code[/b] as pink text (backticks are kept as a visual boundary)
[*] [b]Strikethrough[/b] only removes the ~~ markers and shows the text as-is; [b]tables[/b] are not supported
[*] The built-in fonts have no emoji glyphs, so never rely on emoji alone for important information
[/list]
Headings, lists, quotes, rules, links and images all work as expected; the full syntax and difference list is in the admin guide on GitHub.

[h2]🔗 MOD Series[/h2]
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3779823349]Minidoracat Cleaner for B42[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3653490664]Minidoracat Safe Spawn[/url]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3386633401]Traditional & Simplified Chinese Translation[/url]
[/list]

[h2]📋 MOD Info[/h2]
[list]
[*] [b]Workshop ID:[/b] 3789836823
[*] [b]Mod ID:[/b] MinidoracatNoticeBoardFor42
[*] [b]Supported version:[/b] Build 42.20.2+
[*] [b]Singleplayer / Multiplayer:[/b] both supported
[/list]

[h2]💬 Feedback[/h2]
[list]
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[/list]

[h2]☕ Support the author[/h2]
If this helped, a 👍 on this page and a ⭐ on GitHub help other players find it.
The mod is free and always will be. If you enjoy it, consider buying me a coffee - tips go straight into servers and mod development. Source code is public on GitHub.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatNoticeBoardFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#Minidoracat[/b]
