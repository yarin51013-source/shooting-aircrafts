@echo off
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
 echo Python 3.10+ was not found. Install it from https://www.python.org/downloads/ and enable Add Python to PATH.
 pause
 exit /b 1
)
py -m pip install -r requirements.txt
if errorlevel 1 (echo Dependency installation failed.&pause&exit /b 1)
py joy_paint_helper.py
pause
