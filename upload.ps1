# Fluent Player - 一键上传到 GitHub 脚本
# 使用方法：在 PowerShell 中运行 .\upload.ps1

# 设置错误时停止
$ErrorActionPreference = "Stop"

# 获取当前日期
$date = Get-Date -Format "yyyy-MM-dd"

# 提示用户输入版本号
$version = Read-Host "请输入版本号（例如：3.8）"

# 如果用户输入为空，使用默认格式
if ([string]::IsNullOrWhiteSpace($version)) {
    $version = "更新"
}

# 提交信息
$commitMessage = "Fluent player $version 版本 ($date)"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Fluent Player - 上传到 GitHub" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# 切换到项目目录
Set-Location -Path $PSScriptRoot

# 检查是否有 git 仓库
if (-not (Test-Path ".git")) {
    Write-Host "错误：当前目录不是 Git 仓库！" -ForegroundColor Red
    Write-Host "请先在 D:\1spbfq\video_player_app 目录运行 git init" -ForegroundColor Yellow
    pause
    exit 1
}

# 检查远程仓库
$remote = git remote -v
if ([string]::IsNullOrWhiteSpace($remote)) {
    Write-Host "警告：未配置远程仓库！" -ForegroundColor Yellow
    $setupRemote = Read-Host "是否现在配置远程仓库？(Y/N)"
    if ($setupRemote -eq "Y" -or $setupRemote -eq "y") {
        $remoteUrl = Read-Host "请输入远程仓库 URL（例如：https://github.com/t66666t/Video-master.git）"
        git remote add origin $remoteUrl
        Write-Host "远程仓库已添加：$remoteUrl" -ForegroundColor Green
    }
}

# 检查是否有文件修改
Write-Host "正在检查文件修改..." -ForegroundColor Yellow
$status = git status --porcelain

if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "没有文件被修改，无需提交。" -ForegroundColor Yellow
    Write-Host ""
    $pushOnly = Read-Host "是否只推送已有的提交？(Y/N)"
    if ($pushOnly -eq "Y" -or $pushOnly -eq "y") {
        Write-Host "正在推送到 GitHub..." -ForegroundColor Yellow
        git push origin main
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ 推送成功！" -ForegroundColor Green
        } else {
            Write-Host "❌ 推送失败！请检查网络或远程仓库配置。" -ForegroundColor Red
        }
    }
    pause
    exit 0
}

# 显示将要提交的文件
Write-Host "以下文件将被提交：" -ForegroundColor Yellow
git status --short

Write-Host ""
Write-Host "提交信息：$commitMessage" -ForegroundColor Cyan
Write-Host ""

# 确认提交
$confirm = Read-Host "确认提交并推送？(Y/N)"
if ($confirm -ne "Y" -and $confirm -ne "y") {
    Write-Host "已取消。" -ForegroundColor Yellow
    pause
    exit 0
}

# 添加所有文件
Write-Host ""
Write-Host "正在添加文件..." -ForegroundColor Yellow
git add .

# 提交
Write-Host "正在提交..." -ForegroundColor Yellow
git commit -m $commitMessage

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ 提交失败！" -ForegroundColor Red
    pause
    exit 1
}

# 推送
Write-Host "正在推送到 GitHub..." -ForegroundColor Yellow
Write-Host ""

# 尝试正常推送
git push origin main

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "⚠️  正常推送失败，可能的原因：" -ForegroundColor Yellow
    Write-Host "  1. 远程仓库有新的提交" -ForegroundColor Yellow
    Write-Host "  2. 网络连接问题" -ForegroundColor Yellow
    Write-Host ""
    $forcePush = Read-Host "是否强制推送（会覆盖远程仓库）？(Y/N)"
    if ($forcePush -eq "Y" -or $forcePush -eq "y") {
        Write-Host "正在强制推送..." -ForegroundColor Yellow
        git push -f origin main
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ 强制推送成功！" -ForegroundColor Green
        } else {
            Write-Host "❌ 强制推送失败！" -ForegroundColor Red
        }
    } else {
        Write-Host "已取消推送。" -ForegroundColor Yellow
    }
} else {
    Write-Host "✅ 推送成功！" -ForegroundColor Green
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "完成！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

pause
