#!/usr/bin/env bash
# 把编译产物打成 fakesign 过的 IPA
# 用法: pack.sh <AppName> <AppEntitlements> <OutIpa> [TunnelEntitlements]
# 环境变量 PRODUCTS 指定 Release-iphoneos 目录（默认 build/Build/Products/Release-iphoneos）
set -euo pipefail

APP_NAME="$1"
APP_ENT="$2"
OUT="$3"
TUN_ENT="${4:-}"
PRODUCTS="${PRODUCTS:-build/Build/Products/Release-iphoneos}"

[ -d "$PRODUCTS/$APP_NAME.app" ] || { echo "找不到 $PRODUCTS/$APP_NAME.app"; exit 1; }

D=$(mktemp -d)
mkdir -p "$D/Payload"
cp -R "$PRODUCTS/$APP_NAME.app" "$D/Payload/"
APPDIR="$D/Payload/$APP_NAME.app"

EXEC="$APPDIR/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPDIR/Info.plist")"
echo "signing $EXEC"
ldid -S"$APP_ENT" "$EXEC"

# 嵌入的 Swift 运行时也要签
for DYLIB in "$APPDIR"/Frameworks/*.dylib; do
  [ -f "$DYLIB" ] || continue
  echo "signing $DYLIB"
  ldid -S "$DYLIB"
done

if [ -n "$TUN_ENT" ]; then
  for APPEX in "$APPDIR"/PlugIns/*.appex; do
    [ -d "$APPEX" ] || continue
    EXE="$APPEX/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APPEX/Info.plist")"
    echo "signing $EXE"
    ldid -S"$TUN_ENT" "$EXE"
  done
fi

( cd "$D" && zip -qry "$OLDPWD/$OUT" Payload )
ls -lh "$OUT"
