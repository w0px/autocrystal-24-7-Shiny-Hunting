@echo off
rem The 24/7 stream bot: BizHawk 2.11.1 (in BizHawk\ next to this file) with the
rem stream launcher loaded, plus the --url_post/--url_get flags BizHawk needs
rem before Lua may send anything over HTTP (the overlay relay on port 5012).
start "" "%~dp0BizHawk\EmuHawk.exe" --url_post=http://127.0.0.1:5012/ --url_get=http://127.0.0.1:5012/ --lua="%~dp0bot\launcher.lua"
