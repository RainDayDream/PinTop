#!/bin/zsh
# 构建命令行工具 pintop 和菜单栏 App build/PinTop.app
set -e
cd "$(dirname "$0")"

echo "==> 命令行工具 ./pintop"
swiftc -O Sources/Core.swift Sources/CLI/main.swift -o pintop

echo "==> 菜单栏 App build/PinTop.app"
APP=build/PinTop.app
rm -rf "$APP"
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
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
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

echo "==> 安装包 build/PinTop.dmg"
STAGE=build/dmg
rm -rf "$STAGE" build/PinTop.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PinTop" -srcfolder "$STAGE" -ov -format UDZO build/PinTop.dmg >/dev/null
rm -rf "$STAGE"
echo "完成：build/PinTop.dmg（打开后把 PinTop 拖到 Applications）"
