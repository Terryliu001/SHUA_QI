#!/usr/bin/env bash
# 在本机跑 `flutter test` 的包装脚本。
#
# 为什么需要它
# ------------
# 项目依赖 pdfrx → pdfium_dart，它是 **native assets** 包。
# `flutter test` 在宿主机（Windows）上跑，就会试图用 MSVC 编译
# `pdfrx_pdfium_gate.dll`；而 native_toolchain_c 靠**查注册表**（reg.exe）定位 Windows SDK，
# 本机沙箱禁止 reg.exe 启动 → INCLUDE 里没有 Windows Kits 路径 →
# `fatal error C1083: 无法打开包括文件 windows.h`。
#
# 绕法：跑测试期间关掉 native assets（测试根本用不到原生库），跑完立刻恢复，
# 否则后续 `flutter build apk` 会因为没有 libpdfium 而失败。
#
# 用法：bash tool/run_tests.sh            # 跑全部
#       bash tool/run_tests.sh test/db_test.dart
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
FLUTTER="${FLUTTER:-flutter}"

restore() {
  "$FLUTTER" config --enable-native-assets >/dev/null 2>&1 || true
}
# 无论成功、失败、Ctrl-C，都要把开关恢复回去
trap restore EXIT INT TERM

"$FLUTTER" config --no-enable-native-assets >/dev/null 2>&1

# 清代理：否则 flutter_tester 监听 localhost 的 WebSocket 会被代理接管
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u all_proxy -u ALL_PROXY \
    "$FLUTTER" test "$@"
status=$?

exit "$status"
