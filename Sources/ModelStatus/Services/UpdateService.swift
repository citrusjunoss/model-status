import AppKit
import CryptoKit

final class UpdateService {
    private var isChecking = false

    func check(manual: Bool) {
        guard !isChecking else { return }
        guard let url = URL(string: "https://api.github.com/repos/\(AppConfig.githubRepository)/releases/latest") else { return }
        isChecking = true
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("model-status-updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data,
                      let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                    if manual { self.showAlert(title: "检查更新失败", message: "暂时无法读取 GitHub Release。") }
                    return
                }
                let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                guard self.isVersion(latest, newerThan: current) else {
                    if manual { self.showAlert(title: "已是最新版本", message: "当前版本为 \(current)。") }
                    return
                }
                self.presentUpdate(release: release, version: latest)
            }
        }.resume()
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private func presentUpdate(release: GitHubRelease, version: String) {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "intel"
        #endif
        guard let package = release.assets.first(where: { $0.name.hasSuffix("-\(architecture).zip") && !$0.name.contains("-adhoc") }),
              let checksums = release.assets.first(where: { $0.name == "SHA256SUMS" }) else {
            showAlert(title: "更新包不完整", message: "Release 中缺少当前架构安装包或 SHA256SUMS。")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alert.informativeText = notes.isEmpty ? "是否下载、校验并安装更新？" : String(notes.prefix(1_200))
        alert.addButton(withTitle: "安装更新")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "查看发布页")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            downloadUpdate(package: package, checksums: checksums, version: version)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        default:
            break
        }
    }

    private func downloadUpdate(package: GitHubRelease.Asset, checksums: GitHubRelease.Asset, version: String) {
        var checksumRequest = URLRequest(url: checksums.browserDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        checksumRequest.setValue("model-status-updater", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: checksumRequest) { [weak self] checksumData, checksumResponse, checksumError in
            guard let self,
                  checksumError == nil,
                  let checksumHTTP = checksumResponse as? HTTPURLResponse,
                  (200..<300).contains(checksumHTTP.statusCode),
                  let checksumData,
                  let checksumText = String(data: checksumData, encoding: .utf8),
                  let expectedHash = self.expectedHash(for: package.name, in: checksumText) else {
                DispatchQueue.main.async { self?.showAlert(title: "更新校验失败", message: "无法读取 Release 校验文件。") }
                return
            }
            var packageRequest = URLRequest(url: package.browserDownloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
            packageRequest.setValue("model-status-updater", forHTTPHeaderField: "User-Agent")
            URLSession.shared.downloadTask(with: packageRequest) { [weak self] location, response, error in
                guard let self,
                      error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let location,
                      let data = try? Data(contentsOf: location),
                      self.sha256(data) == expectedHash else {
                    DispatchQueue.main.async { self?.showAlert(title: "更新校验失败", message: "下载文件与 GitHub Release 的 SHA-256 不一致。") }
                    return
                }
                self.prepareUpdate(packageData: data, expectedVersion: version, downloadURL: package.browserDownloadURL)
            }.resume()
        }.resume()
    }

    private func expectedHash(for filename: String, in checksumText: String) -> String? {
        for line in checksumText.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2 else { continue }
            let path = String(parts.last!)
            if URL(fileURLWithPath: path).lastPathComponent == filename {
                return String(parts[0]).lowercased()
            }
        }
        return nil
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func prepareUpdate(packageData: Data, expectedVersion: String, downloadURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-status-update-\(UUID().uuidString)", isDirectory: true)
            let archive = root.appendingPathComponent("update.zip")
            let extracted = root.appendingPathComponent("extracted", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
                try packageData.write(to: archive, options: .atomic)
                guard SystemProcess.run("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extracted.path]),
                      let appURL = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
                        .first(where: { $0.pathExtension == "app" }),
                      let bundle = Bundle(url: appURL),
                      bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                      bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == expectedVersion,
                      SystemProcess.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path]) else {
                    throw NSError(domain: "ModelStatusUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "更新包结构或代码签名无效。"])
                }
                DispatchQueue.main.async {
                    self.installPreparedUpdate(appURL, fallbackDownloadURL: downloadURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                DispatchQueue.main.async {
                    self.showAlert(title: "安装更新失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func installPreparedUpdate(_ updateAppURL: URL, fallbackDownloadURL: URL) {
        let currentAppURL = Bundle.main.bundleURL
        let parent = currentAppURL.deletingLastPathComponent()
        let targetAppURL = parent.appendingPathComponent("\(AppConfig.appName).app", isDirectory: true)
        guard currentAppURL.pathExtension == "app",
              !currentAppURL.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: parent.path),
              currentAppURL == targetAppURL || !FileManager.default.fileExists(atPath: targetAppURL.path) else {
            NSWorkspace.shared.open(fallbackDownloadURL)
            showAlert(title: "需要手动安装", message: "当前应用位置无法直接替换，已打开下载地址。请退出应用后手动覆盖旧版本。")
            return
        }

        let installerScript = """
        set -eu
        current="$1"
        target="$2"
        source="$3"
        pid="$4"
        while /bin/kill -0 "$pid" 2>/dev/null; do /bin/sleep 0.2; done
        backup="${current}.update-backup"
        /bin/rm -rf "$backup"
        /bin/mv "$current" "$backup"
        if /bin/mv "$source" "$target"; then
          /bin/rm -rf "$backup"
          /usr/bin/open "$target"
        else
          /bin/mv "$backup" "$current"
          exit 1
        fi
        """
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/zsh")
        installer.arguments = [
            "-c", installerScript, "model-status-updater",
            currentAppURL.path, targetAppURL.path, updateAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]
        installer.standardOutput = FileHandle.nullDevice
        installer.standardError = FileHandle.nullDevice
        do {
            try installer.run()
            NSApp.terminate(nil)
        } catch {
            showAlert(title: "安装更新失败", message: "无法启动更新替换程序。")
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
