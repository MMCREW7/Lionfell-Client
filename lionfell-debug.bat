@echo off
setlocal EnableExtensions
title Lionfell crash report
rem Lionfell crash report (Windows). Double-click it, play until the crash happens, then send the
rem file "Lionfell-crash-report.txt" it puts on your desktop.
rem It records: Windows version, graphics card and driver, the game files' state, the game's own
rem log and crash report, how the game exited, and Windows' error log entries for the game.

rem find the game: next to this file, or the installed copy
set "GAME=%~dp0"
if not exist "%GAME%otclient.exe" set "GAME=%LOCALAPPDATA%\Lionfell\"
if not exist "%GAME%otclient.exe" (
    echo Can't find otclient.exe. Put this file in the Lionfell folder and run it again.
    pause
    exit /b 1
)
cd /d "%GAME%"

set "REPORT=%USERPROFILE%\Desktop\Lionfell-crash-report.txt"
if not exist "%USERPROFILE%\Desktop" set "REPORT=%GAME%Lionfell-crash-report.txt"

echo.
echo   Lionfell crash report
echo   Starting the game. Play until it crashes (or close it), then come back here.
echo.

rem old reports out of the way, so this run's are the ones we read
if exist crash_report.log move /y crash_report.log crash_report.old.log >nul
if exist otclient.log copy /y otclient.log otclient.previous.log >nul

> "%REPORT%" echo ==== Lionfell crash report ====
>>"%REPORT%" echo Date: %DATE% %TIME%
>>"%REPORT%" echo Game folder: %GAME%
>>"%REPORT%" echo.

rem ---- run 1: the game as usual (start /wait: a windowed program would otherwise return at once)
set "START=%TIME%"
start "" /wait otclient.exe
set "CODE=%ERRORLEVEL%"
>>"%REPORT%" echo ==== Run 1: normal start ====
>>"%REPORT%" echo Started %START%, ended %TIME%
call :describe %CODE%
if exist otclient.log copy /y otclient.log otclient.run1.log >nul

rem ---- run 2, only after a crash: the same without the auto-updater (it downloads from GitHub at
rem start), to see whether the crash comes from the update check
if "%CODE%"=="0" goto collect
echo.
echo   The game crashed. Starting it once more without the auto-updater...
echo   (if it opens this time, just close it again)
echo.
set "LIONFELL_UPDATE_URL=off"
set "START=%TIME%"
start "" /wait otclient.exe
set "CODE2=%ERRORLEVEL%"
set "LIONFELL_UPDATE_URL="
>>"%REPORT%" echo ==== Run 2: without the auto-updater ====
>>"%REPORT%" echo Started %START%, ended %TIME%
call :describe %CODE2%

:collect

echo   Collecting the report...

>>"%REPORT%" echo ==== Windows ====
ver >>"%REPORT%"
powershell -NoProfile -Command "Get-CimInstance Win32_OperatingSystem | Format-List Caption,Version,OSArchitecture,TotalVisibleMemorySize,FreePhysicalMemory" >>"%REPORT%" 2>&1
>>"%REPORT%" echo ==== Processor ====
powershell -NoProfile -Command "Get-CimInstance Win32_Processor | Format-List Name,NumberOfCores" >>"%REPORT%" 2>&1
>>"%REPORT%" echo ==== Graphics ====
powershell -NoProfile -Command "Get-CimInstance Win32_VideoController | Format-List Name,DriverVersion,DriverDate,CurrentHorizontalResolution,CurrentVerticalResolution,AdapterRAM" >>"%REPORT%" 2>&1

>>"%REPORT%" echo ==== Game files ====
for %%F in (otclient.exe init.lua lionfell.bat data\things\1310\catalog-content.json data\sounds\1310\catalog-sound.json) do (
    if exist "%%F" (>>"%REPORT%" echo [ok] %%F) else (>>"%REPORT%" echo [MISSING] %%F)
)
for %%A in (otclient.exe) do >>"%REPORT%" echo otclient.exe: %%~zA bytes, %%~tA
>>"%REPORT%" echo.

>>"%REPORT%" echo ==== Game crash report (crash_report.log) ====
if exist crash_report.log (type crash_report.log >>"%REPORT%") else (>>"%REPORT%" echo none written)
>>"%REPORT%" echo.

>>"%REPORT%" echo ==== Game log, run 1 (last 200 lines) ====
if exist otclient.run1.log (
    powershell -NoProfile -Command "Get-Content -Path 'otclient.run1.log' -Tail 200" >>"%REPORT%" 2>&1
) else (>>"%REPORT%" echo no log)
>>"%REPORT%" echo.
>>"%REPORT%" echo ==== Game log, latest run (last 200 lines) ====
if exist otclient.log (
    powershell -NoProfile -Command "Get-Content -Path 'otclient.log' -Tail 200" >>"%REPORT%" 2>&1
) else (>>"%REPORT%" echo no log)
>>"%REPORT%" echo.

>>"%REPORT%" echo ==== Windows error log (recent entries about the game) ====
powershell -NoProfile -Command "Get-WinEvent -FilterHashtable @{LogName='Application'; StartTime=(Get-Date).AddHours(-2)} -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'otclient' } | Select-Object -First 6 | Format-List TimeCreated,ProviderName,Id,Message" >>"%REPORT%" 2>&1
>>"%REPORT%" echo ==== end ====

echo.
echo   Done. The report is here:
echo   %REPORT%
echo   Send that file to the server owner.
echo.
start "" notepad "%REPORT%"
pause
exit /b 0

rem ---- exit code, with a plain-words meaning for the usual crashes
:describe
>>"%REPORT%" echo Exit code: %1
if "%1"=="0" >>"%REPORT%" echo (0 = closed normally)
if "%1"=="-1073741819" >>"%REPORT%" echo (0xC0000005 = access violation: a crash inside the game)
if "%1"=="-1073740940" >>"%REPORT%" echo (0xC0000374 = heap corruption inside the game)
if "%1"=="-1073740791" >>"%REPORT%" echo (0xC0000409 = stack buffer overrun / fail-fast)
if "%1"=="-1073741515" >>"%REPORT%" echo (0xC0000135 = a DLL is missing)
if "%1"=="-1073741795" >>"%REPORT%" echo (0xC000001D = illegal instruction: CPU too old for this build)
>>"%REPORT%" echo.
exit /b 0
