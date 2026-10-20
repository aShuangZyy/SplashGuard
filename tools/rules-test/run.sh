#!/usr/bin/env bash
# 在 Linux 上验证规则表命中率 / 误杀 / 查询耗时
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/tools/_swift.sh"
"$SWIFTC" -swift-version 5 -O -o /tmp/sg-rules-test \
  main.swift "$ROOT/SplashGuard/Core/BlockList.swift" "$ROOT/SplashGuard/Core/RuleEngine.swift"
/tmp/sg-rules-test "$ROOT/SplashGuard/Resources"
