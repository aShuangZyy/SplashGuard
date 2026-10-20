#!/usr/bin/env bash
# 在 Linux 上验证 DNS / IP 编解码（不依赖 NetworkExtension）
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/tools/_swift.sh"
"$SWIFTC" -swift-version 5 -O -o /tmp/sg-codec-test \
  main.swift "$ROOT/SplashGuard/Tunnel/DNSWire.swift" "$ROOT/SplashGuard/Tunnel/IPPacket.swift"
/tmp/sg-codec-test
