# Flutter PATH 修复脚本

$validFlutterPath = 'E:\dev\flutter-sdk\bin'

# 修复当前会话的PATH
Write-Host "🔄 正在修复 Flutter 路径..."
$env:PATH = $env:PATH -replace 'E:\\111shijuan\\flutter\\bin', ''
if (-not $env:PATH.Contains($validFlutterPath)) {
    $env:PATH = $env:PATH + ';' + $validFlutterPath
}
# 清理多余的分号
$env:PATH = $env:PATH -replace ';;', ';'
$env:PATH = $env:PATH.TrimStart(';').TrimEnd(';')

Write-Host "✅ Flutter 路径已修复！"
Write-Host "📌 当前PATH包含: $validFlutterPath"
