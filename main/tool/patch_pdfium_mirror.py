#!/usr/bin/env python3
"""把 pdfium_dart 的下载地址改指 GitHub 镜像（本机网络限制的临时补丁）。

背景
----
pdfrx → pdfium_flutter → pdfium_dart 的 build hook 会从
  https://github.com/bblanchon/pdfium-binaries/releases/download/<release>/pdfium-android-<arch>.tgz
下载 libpdfium.so。本机对 github.com 稳定超时（沙箱代理返回 502），
构建会**静默卡死十几分钟**而不是报错。

这个脚本把该 URL 前缀换成 https://gh-proxy.com/，其余不变。
幂等：已经打过补丁就跳过。

注意
----
1. 这是**修改 pub-cache 里的第三方包**，不是改我们自己的代码。
   换机器 / `flutter pub cache repair` / 升级 pdfium_dart 之后需要重新执行。
2. 只在阶段 0 的 T0.4 用。产品化之前必须换成"把 pdfium 二进制放进仓库或内网镜像"的正规做法。
3. 用法：python tool/patch_pdfium_mirror.py
"""

from __future__ import annotations

import glob
import os
import sys

MARKER = "gh-proxy.com/"
PREFIX = "https://gh-proxy.com/"


def find_hook() -> str | None:
    cache = os.environ.get("PUB_CACHE") or os.path.expanduser("~/AppData/Local/Pub/Cache")
    pattern = os.path.join(cache, "hosted", "pub.dev", "pdfium_dart-*", "hook", "build.dart")
    hits = sorted(glob.glob(pattern))
    return hits[-1] if hits else None


def main() -> int:
    hook = find_hook()
    if hook is None:
        print("找不到 pdfium_dart 的 hook/build.dart，先跑一次 flutter pub get")
        return 1

    with open(hook, "r", encoding="utf-8") as handle:
        source = handle.read()

    if MARKER in source:
        print(f"已打过补丁，跳过：{hook}")
        return 0

    target = "https://github.com/bblanchon/pdfium-binaries/releases/download/"
    if target not in source:
        print("hook 里没有预期的下载地址，pdfium_dart 可能改版了，需要人工检查")
        return 2

    patched = source.replace(target, PREFIX + target)
    with open(hook, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(patched)

    print(f"已打补丁：{hook}")
    print(f"  {target}")
    print(f"  → {PREFIX}{target}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
