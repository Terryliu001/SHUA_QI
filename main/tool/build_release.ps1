# 构建 release APK（只发 arm64），并把反馈通道的 GitHub 凭证注入进去。
#
# 为什么要有这个脚本（而不是手敲 flutter build）：
# 1. 反馈 token 走 `--dart-define`，**不能**写进 git，也不该出现在命令行历史里；
#    脚本从 `_verify/.gh_app_token`（已 gitignore）读，构建时只多一个文件路径；
# 2. 反馈仓库/分支有固定默认值，少一个参数就会在用户手机上静默失败；
# 3. 只发 arm64（074 §1.2：-12.6MB），同时把产物名固定下来给 Rpage/Release 用。
#
# 用法（在 main/ 下）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_release.ps1
#
# 产物：
#   build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
#   （复制到 Rpage/download/shuaqi-<version>.apk 由发布步骤做）

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$flutter = (Get-Command flutter -ErrorAction Stop).Source

# token：优先专用（只读写私有反馈仓库）；没有就构建成"只存本机"。
$tokenFile = Join-Path (Split-Path -Parent $root) '_verify\.gh_app_token'
$token = ''
if (Test-Path $tokenFile) {
    $token = (Get-Content -Raw $tokenFile).Trim()
}

$buildArgs = @('build', 'apk', '--release', '--split-per-abi')
if ($token) {
    $buildArgs += "--dart-define=FEEDBACK_GH_TOKEN=$token"
    Write-Host 'feedback: GitHub 私有仓库通道已注入（token 不打印）'
}
else {
    Write-Warning 'feedback: 没有 _verify/.gh_app_token，本次构建的反馈只存本机'
}

& $flutter @buildArgs
if ($LASTEXITCODE -ne 0) {
    throw "flutter build 失败（$LASTEXITCODE）"
}

$apk = Join-Path $root 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
if (-not (Test-Path $apk)) {
    throw "没找到产物：$apk"
}
$item = Get-Item $apk
$hash = (Get-FileHash $apk -Algorithm SHA256).Hash
Write-Host ''
Write-Host "APK : $apk"
Write-Host "大小: $($item.Length) 字节（$([math]::Round($item.Length / 1MB, 2)) MB）"
Write-Host "SHA : $hash"
