#!/usr/bin/env bash
# 在宿主机跑 `flutter test` 的包装脚本。
#
# 为什么需要它
# ------------
# 项目依赖 pdfrx → pdfium_dart，它是 **native assets 包**。
# 只要它出现在 pubspec.yaml 的 dependencies 里，`flutter test` 就会：
#   1) 试图用 MSVC 为**宿主机 Windows** 编译 pdfium 的 gate 库
#      → native_toolchain_c 靠查注册表（reg.exe）定位 Windows SDK，
#        而本机沙箱禁止 reg.exe → `fatal error C1083: 无法打开包括文件 windows.h`；
#   2) 或者（关掉 native assets 时）直接拒绝启动：
#      `Package(s) ... require the dart assets feature to be enabled`。
#
# 两条路都走不通，所以这里在跑测试期间**临时把 pdfrx 从 pubspec 摘掉**，跑完立刻恢复。
#
# 代价与边界
# ----------
# - 摘掉 pdfrx 后，任何 import 链上碰到 pdfrx 的测试都编译不过。
#   所以 `test/` 下只允许放**纯 Dart** 测试（domain、路径拼装、架构约束）；
#   碰 Widget / UI / PDF / DB 的测试一律放 `integration_test/`，跑在真机上。
# - 每次多两次 `pub get`（约 3–5 秒），换来秒级的测试反馈，值。
#
# 用法：bash tool/run_tests.sh            # 跑 test/ 下全部
#       bash tool/run_tests.sh test/ulid_test.dart
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
FLUTTER="${FLUTTER:-flutter}"
PUBSPEC="pubspec.yaml"
BACKUP=".pubspec.yaml.host-test-backup"

restore() {
  if [ -f "$BACKUP" ]; then
    mv -f "$BACKUP" "$PUBSPEC"
    "$FLUTTER" pub get >/dev/null 2>&1 || true
  fi
}
trap restore EXIT INT TERM

cp "$PUBSPEC" "$BACKUP"

# 只摘 dependencies 段里的 pdfrx 那一行（保留注释，便于人工比对）
python - "$PUBSPEC" <<'PY'
import io, re, sys

path = sys.argv[1]
lines = io.open(path, encoding='utf-8').read().splitlines(keepends=True)
out = []
in_deps = False
for line in lines:
    if line.startswith('dependencies:'):
        in_deps = True
    elif line.startswith('dev_dependencies:') or line.startswith('flutter:'):
        in_deps = False
    if in_deps and re.match(r'^\s+pdfrx:\s', line):
        out.append('# [run_tests] 临时摘除：pdfrx 是 native assets 包，宿主机跑测试会挂\n')
        continue
    out.append(line)
io.open(path, 'w', encoding='utf-8', newline='\n').write(''.join(out))
PY

"$FLUTTER" pub get >/dev/null 2>&1

# 宿主机跑不了的测试（**按路径排除**，跑单个文件时仍然可以直接指定）。
#
# bookshelf_grid_layout_test：它构造 ProviderScope 时只覆盖了 vault + bookshelf，
# 而书架在 2026-10-24 之后还要读 appDependencies（setting 表）、folder/tag DAO
# 与 workbookHealthProvider —— 宿主机没有 sqflite ffi，建不出 AppDependencies。
# 这条测试留作真机/集成测试的回归用例，不参与宿主全量。
HOST_SKIP=(
  "test/bookshelf_grid_layout_test.dart"
)

FILES=()
for f in test/*_test.dart; do
  skip=0
  for s in "${HOST_SKIP[@]}"; do
    if [ "$f" = "$s" ]; then skip=1; fi
  done
  if [ "$skip" -eq 0 ]; then FILES+=("$f"); fi
done

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("${FILES[@]}")
fi

# 清代理：否则 flutter_tester 监听 localhost 的 WebSocket 会被代理接管
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY \
    -u all_proxy -u ALL_PROXY \
    "$FLUTTER" test "${TARGETS[@]}"
status=$?

exit "$status"
