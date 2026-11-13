@echo off
rem Starts the overlay relay by hand (the launcher will start it later).
rem Then in OBS: Browser Sources: http://127.0.0.1:5012/pokegear.html?card=radio (also card=clock, card=phone) and http://127.0.0.1:5012/clouds.html
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0overlay_relay.ps1" -ListenPort 5012
pause
