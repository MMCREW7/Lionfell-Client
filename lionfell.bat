@echo off
rem Lionfell client launcher (Windows): installs a client program downloaded by the updater
rem (modules/updater: saved as otclient.exe.new), then starts the client.
cd /d "%~dp0"
if not exist otclient.exe.new goto start
rem the old client may still be closing: try for a few seconds while it lets go of otclient.exe
set tries=0
:swap
move /y otclient.exe.new otclient.exe >nul 2>&1
if not exist otclient.exe.new goto start
set /a tries+=1
if %tries% geq 10 goto start
ping -n 2 127.0.0.1 >nul
goto swap
:start
start "" otclient.exe
