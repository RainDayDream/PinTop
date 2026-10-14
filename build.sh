#!/bin/zsh
# 构建命令行工具 pintop 和菜单栏 App build.noindex/PinTop.app
set -e
cd "$(dirname "$0")"

# 构建输出放在 build.noindex/：以 .noindex 结尾的目录会被 Spotlight 跳过，
# 避免构建中间产物（App、DMG 临时目录）被系统登记成“又一个 PinTop”。
OUT=build.noindex
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister() { [ -x "$LSR" ] && "$LSR" -u "$1" >/dev/null 2>&1 || true; }   # 清除启动服务里对该路径的登记

echo "==> 命令行工具 ./pintop"
swiftc -O Sources/Core.swift Sources/CLI/main.swift -o pintop

echo "==> 菜单栏 App build.noindex/PinTop.app"
APP=$OUT/PinTop.app
unregister "$APP"
rm -rf "$APP"
mkdir -p "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library Sources/Core.swift Sources/App/App.swift -o "$APP/Contents/MacOS/PinTop"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PinTop</string>
    <key>CFBundleDisplayName</key><string>PinTop</string>
    <key>CFBundleIdentifier</key><string>com.raindaydream.pintop</string>
    <key>CFBundleExecutable</key><string>PinTop</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleVersion</key><string>0.1.2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# ad-hoc 签名（无需开发者账号；每次重新构建后系统可能要求重新授权）
# 指定固定的 designated requirement（只认 Bundle ID），重新构建后系统授权（TCC）仍然有效
codesign --force --deep --sign - --identifier com.raindaydream.pintop \
    -r='designated => identifier "com.raindaydream.pintop"' "$APP"
echo "完成：$APP"

echo "==> 安装包 build.noindex/PinTop.dmg"
STAGE=$OUT/dmg
rm -rf "$STAGE" $OUT/PinTop.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PinTop" -srcfolder "$STAGE" -ov -format UDZO $OUT/PinTop.dmg >/dev/null
rm -rf "$STAGE"
unregister "$STAGE/PinTop.app"      # 打包用的临时副本不应留在登记表里
echo "完成：build.noindex/PinTop.dmg（打开后把 PinTop 拖到 Applications）"
