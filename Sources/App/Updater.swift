// 应用内更新：检查 GitHub 上的最新 Release，下载、校验并替换自己，然后重启。
//
// 安全措施：
//   * 只访问本仓库的 Release 接口；下载文件先核对大小和 GitHub 给出的 SHA-256。
//   * 挂载 DMG 后检查：Bundle ID 一致、版本确实更高、代码签名完好。
//   * 替换时先把旧版改名备份，新版复制失败就回滚，不会留下“没有 App”的状态。
//   * 新旧版本的签名要求相同（只认 Bundle ID），辅助功能 / 屏幕录制授权会保留。
import AppKit
import CryptoKit

final class Updater: NSObject, URLSessionDownloadDelegate {
    enum State {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(Double)          // 0...1
        case installing
        case failed(String)
    }

    static let bundleID = "com.raindaydream.pintop"
    static let defaultFeed = "https://api.github.com/repos/RainDayDream/PinTop/releases/latest"

    /// 更新源。默认是本仓库的最新 Release；环境变量 PINTOP_UPDATE_FEED 可指向别处，仅用于测试。
    var feed: URL { URL(string: ProcessInfo.processInfo.environment["PINTOP_UPDATE_FEED"] ?? Updater.defaultFeed)! }

    let currentVersion: String
    private(set) var latest: ReleaseInfo?          // 最近一次查到的最新版本（不一定比当前新）
    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?

    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    private var checkTimer: Timer?

    override init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        super.init()
    }

    /// 有比当前更新的版本可用（包含正在下载/安装/上次更新失败的情况）。
    var updateAvailable: Bool {
        guard let l = latest else { return false }
        return isNewerVersion(l.version, than: currentVersion)
    }

    // MARK: 检查
    /// 启动后检查一次，之后每 6 小时检查一次。
    func startAutoChecking() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.check(manual: false) }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t
    }

    /// manual = true：用户主动点击，会显示“正在检查”并如实报告失败；自动检查失败时保持静默。
    func check(manual: Bool) {
        switch state { case .checking, .downloading, .installing: return; default: break }
        let previous = state
        if manual { state = .checking }
        var req = URLRequest(url: feed, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PinTop/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 正式更新源是 https，必须返回 200；测试时可指向本地文件（file://），那时没有 HTTP 状态码
                let httpOK = (resp as? HTTPURLResponse).map { $0.statusCode == 200 } ?? self.feed.isFileURL
                if let data = data, httpOK, let rel = parseLatestRelease(data) {
                    self.latest = rel
                    self.state = isNewerVersion(rel.version, than: self.currentVersion) ? .available(rel) : .upToDate
                } else if manual {
                    let code = (resp as? HTTPURLResponse)?.statusCode
                    self.state = .failed(err?.localizedDescription ?? (code.map { "服务器返回 \($0)" } ?? "无法解析返回内容"))
                } else {
                    self.state = previous
                }
            }
        }.resume()
    }

    // MARK: 下载
    /// 开始更新：下载 → 校验 → 安装 → 重启。
    func startUpdate() {
        guard let rel = latest, isNewerVersion(rel.version, than: currentVersion) else { return }
        switch state { case .downloading, .installing, .checking: return; default: break }
        // 在不可写的位置（比如直接从 DMG 里运行）无法原地替换：提前说明，不要下载完才失败
        let dest = Bundle.main.bundleURL
        if let why = Updater.cannotReplace(at: dest) { state = .failed(why); return }
        state = .downloading(0)
        session.downloadTask(with: rel.dmgURL).resume()
    }

    /// 返回 nil 表示可以原地替换；否则是给用户看的原因。
    static func cannotReplace(at app: URL) -> String? {
        if app.path.hasPrefix("/Volumes/") { return "PinTop 正在从磁盘映像里运行，请先把它拖到「应用程序」再更新" }
        if !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return "没有权限替换 \(app.path)，请手动下载安装（见 README）"
        }
        return nil
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData written: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : Int64(latest?.dmgSize ?? 0)
        if total > 0 { state = .downloading(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 临时文件在本方法返回后就会被系统删除，必须立刻移走
        let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("PinTop-update-\(UUID().uuidString).dmg")
        do { try FileManager.default.moveItem(at: location, to: dmg) } catch { state = .failed("保存下载文件失败：\(error.localizedDescription)"); return }
        guard let rel = latest else { return }
        state = .installing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.install(dmg: dmg, release: rel) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error, task is URLSessionDownloadTask { state = .failed("下载失败：\(error.localizedDescription)") }
    }

    // MARK: 校验 + 安装
    private struct UpdateError: Error { let message: String }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 从启动服务里注销一个路径（只清登记，不删文件）。
    static func unregister(_ path: String) {
        let lsr = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        if FileManager.default.isExecutableFile(atPath: lsr) { run(lsr, ["-u", path]) }
    }

    private func fail(_ msg: String) { DispatchQueue.main.async { self.state = .failed(msg) } }

    private func install(dmg: URL, release rel: ReleaseInfo) {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("PinTopUpdate-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt"), staged = work.appendingPathComponent("PinTop.app")
        var mounted = false
        func cleanup(keepWork: Bool) {
            Updater.unregister(mount.appendingPathComponent("PinTop.app").path)     // 映像里的 App 不应留在启动服务里（否则会出现“多个 PinTop”）
            if mounted { if Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]).status != 0 { Updater.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"]) } }
            try? fm.removeItem(at: dmg)
            if !keepWork { try? fm.removeItem(at: work) }
        }
        do {
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)

            // 1. 下载文件完整性：大小 + SHA-256
            let attrs = try fm.attributesOfItem(atPath: dmg.path)
            if rel.dmgSize > 0, (attrs[.size] as? Int) != rel.dmgSize { throw UpdateError(message: "下载的文件大小不对（期望 \(rel.dmgSize) 字节），已放弃") }
            if let want = rel.sha256 {
                let got = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
                if got != want { throw UpdateError(message: "下载文件的 SHA-256 校验失败，已放弃（文件可能损坏或被篡改）") }
            }

            // 2. 挂载（只读、不弹窗、不出现在 Finder 侧边栏）
            let att = Updater.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
            if att.status != 0 { throw UpdateError(message: "无法打开更新包：\(att.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            mounted = true
            let src = mount.appendingPathComponent("PinTop.app")
            guard fm.fileExists(atPath: src.path) else { throw UpdateError(message: "更新包里没有 PinTop.app") }

            // 3. 校验新版本 App：Bundle ID、版本、签名
            guard let info = NSDictionary(contentsOf: src.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Updater.bundleID else { throw UpdateError(message: "更新包里的 App 不是 PinTop（Bundle ID 不符），已放弃") }
            let newVersion = info["CFBundleShortVersionString"] as? String ?? "0"
            if !isNewerVersion(newVersion, than: currentVersion) { throw UpdateError(message: "更新包的版本（\(newVersion)）并不比当前版本（\(currentVersion)）新，已放弃") }
            let cs = Updater.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", src.path])
            if cs.status != 0 { throw UpdateError(message: "更新包的代码签名无效，已放弃：\(cs.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            let req = Updater.run("/usr/bin/codesign", ["-d", "-r-", src.path]).output
            if !req.contains("identifier \"\(Updater.bundleID)\"") { throw UpdateError(message: "更新包的签名要求与当前版本不一致（授权将无法保留），已放弃") }

            // 4. 复制到临时位置（ditto 保留签名和扩展属性），再卸载映像
            let cp = Updater.run("/usr/bin/ditto", [src.path, staged.path])
            if cp.status != 0 { throw UpdateError(message: "复制新版本失败：\(cp.output)") }
            cleanup(keepWork: true)
            mounted = false

            // 5. 交给辅助脚本：等本进程退出 → 备份旧版 → 放入新版（失败则回滚）→ 重新打开
            let script = work.appendingPathComponent("replace.sh")
            try Updater.replaceScript.write(to: script, atomically: true, encoding: .utf8)
            let dest = Bundle.main.bundleURL
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = [script.path, String(getpid()), dest.path, staged.path, work.path]
            helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }     // 退出，脚本随后完成替换并重启
        } catch let e as UpdateError {
            cleanup(keepWork: false); fail(e.message)
        } catch {
            cleanup(keepWork: false); fail("更新失败：\(error.localizedDescription)")
        }
    }

    /// 替换脚本：参数依次为 旧进程 PID、目标 App 路径、新版 App 路径、临时目录。
    private static let replaceScript = """
    #!/bin/bash
    PID="$1"; DEST="$2"; NEW="$3"; WORK="$4"
    # 等当前 PinTop 退出（最多约 20 秒）
    for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    BACKUP="${DEST}.old-$$"
    if /bin/mv "$DEST" "$BACKUP"; then
      if /usr/bin/ditto "$NEW" "$DEST"; then
        /bin/rm -rf "$BACKUP"
      else
        # 复制失败：回滚到旧版，保证机器上始终有一个可用的 PinTop
        /bin/rm -rf "$DEST"; /bin/mv "$BACKUP" "$DEST"
      fi
    fi
    /usr/bin/touch "$DEST"
    # 临时副本和旧版备份不应留在启动服务里（否则会出现“多个 PinTop”）
    LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
    [ -x "$LSR" ] && { "$LSR" -u "$NEW"; "$LSR" -u "$BACKUP"; } >/dev/null 2>&1
    /usr/bin/open "$DEST"
    /bin/rm -rf "$WORK"
    """
}
