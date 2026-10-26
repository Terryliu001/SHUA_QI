# 宿主测试运行器（PowerShell 版）。
#
# 为什么需要它：本机没有 bash（Git Bash 在沙箱里还会因信号管道被拒），
# 而 `tool/run_tests.sh` 依赖 bash + python。这里用 PowerShell 做同一件事：
# 临时摘掉 pdfrx（native assets 包，宿主机测试会挂）→ flutter test → 恢复 pubspec。
#
# 用法（在 main/ 下）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/run_tests.ps1
#   powershell ... -File tool/run_tests.ps1 test/export_options_test.dart
#
# 注意：flutter 会写 .dart_tool / build，必须在可写环境下运行。

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$pubspec = Join-Path $root 'pubspec.yaml'
$backup = Join-Path $root '.pubspec.yaml.host-test-backup'
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$hostSkip = @('bookshelf_grid_layout_test.dart')

function Restore-Pubspec {
    if (Test-Path $backup) {
        Move-Item -Force $backup $pubspec
        & $flutter pub get | Out-Null
    }
}

Copy-Item -Force $pubspec $backup
try {
    $text = Get-Content -Raw $pubspec
    $text = [regex]::Replace(
        $text,
        '(?m)^\s*pdfrx:\s.*$',
        '# [run_tests.ps1] 临时摘除：pdfrx 是 native assets 包，宿主机跑测试会挂'
    )
    Set-Content -NoNewline -Encoding utf8 $pubspec $text

    & $flutter pub get | Out-Null

    $files = @()
    if ($args.Count -gt 0) {
        $files = $args
    }
    else {
        $files = Get-ChildItem (Join-Path $root 'test') -Filter '*_test.dart' |
            Where-Object { $hostSkip -notcontains $_.Name } |
            ForEach-Object { 'test/' + $_.Name }
    }
    if ($files.Count -eq 0) {
        throw '没有找到测试文件'
    }

    & $flutter test @files
    $code = $LASTEXITCODE
}
finally {
    Restore-Pubspec
}
exit $code
