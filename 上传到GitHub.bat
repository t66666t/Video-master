@echo off
chcp 65001 >nul
echo ========================================
echo Fluent Player - 上传到 GitHub
echo ========================================
echo.

REM 切换到脚本所在目录
cd /d "%~dp0"

REM 运行 PowerShell 脚本
powershell -ExecutionPolicy Bypass -File "%~dp0upload.ps1"

pause
