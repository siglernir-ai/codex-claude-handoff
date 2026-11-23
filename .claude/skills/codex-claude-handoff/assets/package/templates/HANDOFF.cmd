@echo off
rem HANDOFF.cmd - double-click to open the roles window for this project.
rem It has no rules of its own. It runs handoff.ps1 and reacts only to the exit
rem codes handoff.ps1 documents: 14 = setup required (open the setup picker
rem first), 2 = setup cancelled by the user (end quietly). Any other failure
rem stays on screen so it can be read.
rem It moves into its own folder once, with pushd (which also maps a network
rem path to a drive letter), and from then on names handoff.ps1 relative to
rem that folder. %~dp0 is read only once: started through a quoted relative
rem path, cmd resolves it again against the new folder after a change of folder.
setlocal
set "HANDOFF_EXIT=1"
pushd "%~dp0" || goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\handoff.ps1" roles -Window
set "HANDOFF_EXIT=%ERRORLEVEL%"
if "%HANDOFF_EXIT%"=="0" goto done
if not "%HANDOFF_EXIT%"=="14" goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\handoff.ps1" setup -Window
set "HANDOFF_EXIT=%ERRORLEVEL%"
if "%HANDOFF_EXIT%"=="2" goto cancelled
if not "%HANDOFF_EXIT%"=="0" goto failed

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "scripts\handoff.ps1" roles -Window
set "HANDOFF_EXIT=%ERRORLEVEL%"
if "%HANDOFF_EXIT%"=="0" goto done

:failed
echo.
echo HANDOFF.cmd: stopped with exit code %HANDOFF_EXIT%. Read the message above.
pause
popd
exit /b %HANDOFF_EXIT%

:cancelled
popd
exit /b 2

:done
popd
exit /b 0
