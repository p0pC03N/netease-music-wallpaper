@echo off
set "NETEASE_EXE=D:\CloudMusic\cloudmusic.exe"
taskkill /IM cloudmusic.exe /F >nul 2>nul
taskkill /IM cloudmusic_reporter.exe /F >nul 2>nul
timeout /T 2 /NOBREAK >nul
start "" "%NETEASE_EXE%" --remote-debugging-port=9222 --remote-allow-origins=*
