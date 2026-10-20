#!/usr/bin/env bash
# 定位 Linux 上的 swiftc（系统未安装时用 ~/swift-toolchain 里的官方 tarball）
if [ -z "${SWIFTC:-}" ]; then
  if command -v swiftc >/dev/null 2>&1; then
    SWIFTC=$(command -v swiftc)
  else
    for c in "$HOME"/swift-toolchain/swift-*/usr/bin/swiftc; do
      [ -x "$c" ] && SWIFTC="$c" && SWIFT_HOME=$(dirname "$(dirname "$c")") && break
    done
  fi
fi
[ -z "${SWIFTC:-}" ] && { echo "找不到 swiftc：装 Swift 或设 SWIFTC=..." >&2; return 1; }
if [ -n "${SWIFT_HOME:-}" ]; then
  export LD_LIBRARY_PATH="$HOME/swiftlib:$SWIFT_HOME/usr/lib/swift/linux:${LD_LIBRARY_PATH:-}"
fi
export SWIFTC
