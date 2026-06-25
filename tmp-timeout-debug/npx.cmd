@echo off
setlocal EnableDelayedExpansion
set "ALL=%*"
set IS_VERSION=
if not "!ALL:--version=!"=="!ALL!" set IS_VERSION=1
if defined IS_VERSION (
  echo claude-code-test
  exit /b 0
)
echo started> "%FAKE_NPX_MARKER%"
cmd /c "ping -n 31 127.0.0.1 > nul"
echo finished> "%FAKE_NPX_MARKER%"
exit /b 0
