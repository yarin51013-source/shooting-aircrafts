@echo off
title Joy of Painting Helper
set "SCRIPT=%TEMP%\RunJoyPaintHelper.ps1"
echo Closing any old Joy of Painting helper...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $p = Get-NetTCPConnection -LocalPort 8765,8766 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique; foreach ($id in $p) { if ($id -ne $PID) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } } } catch {}"
echo Downloading the latest Joy of Painting helper...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/yarin51013-source/shooting-aircrafts/main/docs/joy-of-painting/desktop-helper/RunJoyPaintHelper.ps1' -OutFile '%SCRIPT%'; if (!(Test-Path '%SCRIPT%')) { exit 1 }; if ((Get-Content '%SCRIPT%' -Raw) -notmatch '/prepare') { throw 'Downloaded helper is outdated or incomplete' } } catch { Write-Host $_; exit 1 }"
if errorlevel 1 (
  echo Could not download the helper. Check your internet connection.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
pause
