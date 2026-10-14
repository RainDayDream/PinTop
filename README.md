# PinTop — macOS 窗口悬浮 / 并排工具

让任意 App 的某个窗口始终显示在其他窗口之上（镜像悬浮），或把它摆到屏幕指定位置（并排布局）。
带主窗口和菜单栏图标的 App，也提供命令行用法；Swift 编写，不修改任何窗口内容。

## 安装

**一键安装（推荐）**：在「终端」里粘贴运行，自动下载最新版并安装到「应用程序」：

```bash
curl -fL -o /tmp/PinTop.dmg https://github.com/RainDayDream/PinTop/releases/latest/download/PinTop.dmg \
  && hdiutil attach /tmp/PinTop.dmg -nobrowse -quiet -mountpoint /tmp/PinTopVolume \
  && rm -rf /Applications/PinTop.app \
  && cp -R /tmp/PinTopVolume/PinTop.app /Applications/ ; \
  hdiutil detach /tmp/PinTopVolume -quiet ; rm -f /tmp/PinTop.dmg ; \
  open /Applications/PinTop.app
```

用 `curl` 下载的文件不带系统“隔离”标记，所以不会被 Gatekeeper 拦截。

**手动安装**：
1. 下载 **[PinTop.dmg（最新版）](https://github.com/RainDayDream/PinTop/releases/latest/download/PinTop.dmg)**，或到 [Releases 页面](https://github.com/RainDayDream/PinTop/releases) 选择版本；
2. 双击 DMG，把 **PinTop** 拖到 **Applications**；
3. 首次打开：在「应用程序」里**右键 PinTop → 打开**（本 App 未经苹果公证，浏览器下载的文件会被系统提示“无法验证开发者”）；
   或在终端运行 `xattr -dr com.apple.quarantine /Applications/PinTop.app` 后再打开。

**首次使用需授权**：在 系统设置 → 隐私与安全性 中给 **PinTop** 打开「辅助功能」和「屏幕录制」（授权屏幕录制后，完全退出并重新打开 PinTop）。
主窗口顶部会显示两项权限的状态。

**卸载**：退出 PinTop，把 `/Applications/PinTop.app` 移到废纸篓；可选：`tccutil reset All com.raindaydream.pintop` 清除授权记录。

> 只运行「应用程序」里的那一份 PinTop。DMG 里或 `build/` 里的同名 App 与它是同一个 Bundle ID，混着运行可能让授权状态错乱。

## 使用

打开 PinTop 会出现主窗口（屏幕顶部菜单栏的图钉图标是同样功能的快捷入口）：

1. **选择窗口**：在下拉框里选要操作的窗口，窗口不全时点「刷新」。
2. **镜像悬浮**：在范围下拉框里选在哪个桌面悬浮，点「开始镜像悬浮」：
   - **当前桌面**；**所有桌面（含全屏桌面）**；
   - **指定：桌面 N / 全屏：某 App**：PinTop 会识别你现在有哪些桌面（按 Mission Control 顺序），可以选其中任意一个，镜像只在那个桌面出现，切到别的桌面不显示。新增/删除桌面后点「刷新」更新列表。
   - 悬浮的窗口被别的窗口盖住时，会在最上层显示它的实时画面；点击画面即可继续操作。
   - 悬浮窗口的右上角有一个 **「✕ 取消悬浮」** 小浮标，点一下就取消该窗口的悬浮。
3. **并排布局**：选位置（靠右/靠左/靠上/靠下）和大小（如 `35%` 或 `600`），点「摆放」；「恢复原位置」可还原。
4. **正在悬浮**：每个悬浮的窗口一行，各有「取消」按钮；「全部取消」一键取消。
   默认一次只悬浮一个窗口，勾选「允许同时悬浮多个窗口」后可同时悬浮多个（最近点击的在最上层）。

### 命令行

```bash
./pintop                      # 交互式：选窗口 → 选模式
./pintop list                 # 列出窗口ID
./pintop float <ID>           # 镜像悬浮（当前桌面）
./pintop float <ID> --all     # 镜像悬浮（所有桌面）
./pintop spaces               # 列出识别到的桌面（含全屏桌面）及序号
./pintop float <ID> --space 2 # 镜像悬浮，只出现在第 2 个桌面
./pintop dock <ID> --right 35%                       # 并排布局：靠右占 35%（--left/--top/--bottom，也可写像素）
./pintop dock <ID> --frame x,y,w,h                   # 任意区域
./pintop dock <ID> --right 35% --fit <ID2>,<ID3>     # 同时把其他窗口放进剩余区域
./pintop restore                                     # 恢复被 dock/fit 移动的窗口
```

悬浮模式按 Ctrl+C 退出，不遗留状态。命令行的授权对象是运行它的终端 App（辅助功能；镜像悬浮另需屏幕录制，授权后重启终端）。

## 镜像悬浮原理

macOS（SIP 开启）不允许第三方改变其他 App 窗口的层级：`AXRaise` 对后台 App 无效，`SLSOrderWindow` 被系统拒绝，
“前置 + 还焦点”会与被点击窗口互相抢占而闪动。因此采用镜像方案：

- 用 ScreenCaptureKit 捕获目标窗口，在最上层放一个无边框、不抢焦点的面板，与真窗口位置大小重合；
- 仅当目标窗口被其他窗口盖住时才显示镜像；未被盖住时隐藏，你操作的就是真窗口；
- 点击镜像：先激活真窗口，再把这次鼠标操作转发给它；之后打字走系统原生路径。拖动、滚动同样转发，可通过镜像移动/缩放窗口；
- 所有桌面模式：镜像面板出现在每个桌面，包括其他 App 的全屏桌面。真窗口在其他桌面/全屏桌面时，镜像是离开时刻的静态画面且只读
  （点击不转发，避免被系统带离当前桌面）；回到真窗口所在桌面后恢复实时并可操作；
- 指定桌面模式：识别桌面用到系统的只读接口，不移动任何窗口；只在目标桌面成为当前桌面时才显示镜像面板，面板自然落在那个桌面上；
- 推荐搭配：Dock 右键该 App →「选项 → 分配给 → 所有桌面」，这样在普通桌面里真窗口始终存在、可实时操作；全屏桌面则由镜像显示。

## 安全性

- 不注入代码、不改 SIP/系统设置、不读写窗口内容、不使用抢焦点的私有接口；
- 使用到的非公开符号都是只读的：`_AXUIElementGetWindow`（把 AX 窗口映射为窗口ID）、`CGSCopyManagedDisplaySpaces`（读取桌面列表）；
- 只有「并排布局」的 `--fit` 会改变其他 App 窗口的大小（默认不动），「恢复原位置」可还原。

## 已知限制

- 镜像画面有轻微延迟；输入法候选框、悬停提示等细节可能与真窗口略有差异；
- 其他 App 的全屏桌面里，悬浮窗口只能看、不能操作（系统不允许真窗口出现在那里）；
- 全屏窗口、固定大小窗口可能拒绝被调整（并排布局会提示）；
- App 为 ad-hoc 签名、未经苹果公证，见上面的“首次打开”。

## 从源码构建

需要 Xcode 命令行工具（`xcode-select --install`），macOS 14 及以上。

```bash
./build.sh      # 生成 ./pintop（命令行）、build/PinTop.app、build/PinTop.dmg
open build/PinTop.app
```

构建使用 ad-hoc 签名并固定指定要求（只认 Bundle ID `com.raindaydream.pintop`），重新构建后系统授权仍然有效。

代码结构：

```
Sources/Core.swift        核心：窗口列表、并排布局、镜像悬浮引擎
Sources/App/App.swift     App 入口：主窗口 + 菜单栏
Sources/CLI/main.swift    命令行入口
build.sh                  一键构建（命令行 + App + DMG）
```
