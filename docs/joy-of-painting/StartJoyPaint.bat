@echo off
title Joy of Painting Helper
set "SCRIPT=%TEMP%\RunJoyPaintHelper.ps1"
echo Downloading the Joy of Painting helper...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/yarin51013-source/shooting-aircrafts/main/docs/joy-of-painting/desktop-helper/RunJoyPaintHelper.ps1' -OutFile '%SCRIPT%'; if (!(Test-Path '%SCRIPT%')) { exit 1 } } catch { Write-Host $_; exit 1 }"
if errorlevel 1 (
  echo Could not download the helper. Check your internet connection.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
pause
