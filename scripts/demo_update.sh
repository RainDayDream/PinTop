#!/bin/zsh
# 在临时目录里演示“应用内更新”，不会动「应用程序」里的 PinTop。
#
#   ./scripts/demo_update.sh          启动演示：一份旧版（当前构建）PinTop，更新源声称有 V9.9.9
#   ./scripts/demo_update.sh clean    清理演示留下的文件和启动服务登记
#
# 演示：约 3 秒后主窗口顶部出现「发现新版本 V9.9.9」横幅，菜单栏图标旁出现「↑」，Dock 图标出现角标；
# 点「立即更新」会走完 下载 → 校验 → 替换 → 自动重启（只替换演示目录里的那份，且新版本是当前构建的副本，版本号改成 9.9.9）。
set -e
cd "$(dirname "$0")/.."
DEMO=/tmp/pintop-demo
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

clean() {
    pkill -f "$DEMO/" 2>/dev/null || true
    sleep 1
    [ -d "$DEMO/old/PinTop.app" ] && "$LSR" -u "$DEMO/old/PinTop.app" >/dev/null 2>&1 || true
    rm -rf "$DEMO"
    echo "已清理演示文件"
}
[ "$1" = "clean" ] && { clean; exit 0; }

APP=build.noindex/PinTop.app
[ -d "$APP" ] || ./build.sh
clean >/dev/null 2>&1 || true
mkdir -p "$DEMO/old" "$DEMO/stage"

# 新版：当前构建的副本，版本号改为 9.9.9，同样的签名要求（只认 Bundle ID）
cp -R "$APP" "$DEMO/stage/PinTop.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 9.9.9" -c "Set :CFBundleVersion 9.9.9" "$DEMO/stage/PinTop.app/Contents/Info.plist"
codesign --force --deep --sign - --identifier com.raindaydream.pintop \
    -r='designated => identifier "com.raindaydream.pintop"' "$DEMO/stage/PinTop.app" >/dev/null 2>&1
hdiutil create -volname PinTop -srcfolder "$DEMO/stage" -ov -format UDZO "$DEMO/PinTop.dmg" >/dev/null
rm -rf "$DEMO/stage"

# 更新源（和 GitHub 接口同样的格式），指向本地的新版 DMG
SIZE=$(stat -f%z "$DEMO/PinTop.dmg"); SHA=$(shasum -a 256 "$DEMO/PinTop.dmg" | cut -d' ' -f1)
cat > "$DEMO/feed.json" <<JSON
{"tag_name":"V9.9.9","draft":false,"prerelease":false,"html_url":"https://github.com/RainDayDream/PinTop/releases","body":"演示","assets":[{"name":"PinTop.dmg","browser_download_url":"file://$DEMO/PinTop.dmg","size":$SIZE,"digest":"sha256:$SHA"}]}
JSON

# 旧版：当前构建的副本，放在演示目录里
cp -R "$APP" "$DEMO/old/PinTop.app"
open --env PINTOP_UPDATE_FEED="file://$DEMO/feed.json" -n "$DEMO/old/PinTop.app"
echo "已启动演示（版本 $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEMO/old/PinTop.app/Contents/Info.plist")，更新源声称有 V9.9.9）。"
echo "几秒后看主窗口顶部的横幅，点「立即更新」。结束后运行：./scripts/demo_update.sh clean"
