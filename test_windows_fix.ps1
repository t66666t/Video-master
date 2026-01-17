# Windows白屏修复验证脚本

Write-Host "开始验证Windows白屏修复..." -ForegroundColor Green

# 1. 检查语法错误
Write-Host "`n1. 检查Dart语法..." -ForegroundColor Yellow
flutter analyze lib/main.dart lib/screens/home_screen.dart

if ($LASTEXITCODE -ne 0) {
    Write-Host "语法检查失败!" -ForegroundColor Red
    exit 1
}

Write-Host "语法检查通过!" -ForegroundColor Green

# 2. 尝试构建Windows版本
Write-Host "`n2. 构建Windows版本..." -ForegroundColor Yellow
Write-Host "注意: 这可能需要几分钟时间" -ForegroundColor Cyan

flutter build windows --release

if ($LASTEXITCODE -ne 0) {
    Write-Host "构建失败!" -ForegroundColor Red
    exit 1
}

Write-Host "构建成功!" -ForegroundColor Green

# 3. 提示测试步骤
Write-Host "`n3. 手动测试步骤:" -ForegroundColor Yellow
Write-Host "   a. 断开网络连接" -ForegroundColor Cyan
Write-Host "   b. 运行: build\windows\x64\runner\Release\video_player_app.exe" -ForegroundColor Cyan
Write-Host "   c. 应用应该能正常启动,显示主界面" -ForegroundColor Cyan
Write-Host "   d. 不应该出现白屏或无响应" -ForegroundColor Cyan

Write-Host "`n修复验证完成!" -ForegroundColor Green
