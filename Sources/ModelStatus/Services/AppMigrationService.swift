import AppKit

final class AppMigrationService {
    func offerIfNeeded(arguments: [String], isQAPreview: Bool) {
        guard !isQAPreview,
              !arguments.contains(AppConfig.migrationRelaunchArgument) else { return }

        let fileManager = FileManager.default
        let currentAppURL = Bundle.main.bundleURL.standardizedFileURL
        guard currentAppURL.pathExtension == "app",
              !isInsideApplicationsFolder(currentAppURL) else { return }

        let systemApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        let destinationFolder: URL
        if fileManager.isWritableFile(atPath: systemApplications.path) {
            destinationFolder = systemApplications
        } else {
            do {
                try fileManager.createDirectory(at: userApplications, withIntermediateDirectories: true)
                destinationFolder = userApplications
            } catch {
                showAlert(title: "无法准备应用程序文件夹", message: error.localizedDescription)
                return
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "将 InputStatus 移到“应用程序”文件夹？"
        alert.informativeText = "移动后可以正常安装自动更新，并避免从下载或隔离位置运行。已有旧版本时会自动替换。"
        alert.addButton(withTitle: "移到应用程序文件夹")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try beginMigration(from: currentAppURL, to: destinationFolder)
        } catch {
            showAlert(title: "迁移失败", message: error.localizedDescription)
        }
    }

    private func isInsideApplicationsFolder(_ appURL: URL) -> Bool {
        let path = appURL.resolvingSymlinksInPath().standardizedFileURL.path
        let folders = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        return folders.contains { folder in
            let prefix = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            return path.hasPrefix(prefix)
        }
    }

    private func beginMigration(from sourceAppURL: URL, to destinationFolder: URL) throws {
        let fileManager = FileManager.default
        let identifier = UUID().uuidString
        let targetAppURL = destinationFolder.appendingPathComponent("\(AppConfig.appName).app", isDirectory: true)
        let stagingAppURL = destinationFolder.appendingPathComponent(".InputStatus-installing-\(identifier).app", isDirectory: true)
        let backupAppURL = destinationFolder.appendingPathComponent(".InputStatus-migration-backup-\(identifier).app", isDirectory: true)

        do {
            try fileManager.copyItem(at: sourceAppURL, to: stagingAppURL)
            guard let copiedBundle = Bundle(url: stagingAppURL),
                  copiedBundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  SystemProcess.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stagingAppURL.path]) else {
                throw NSError(
                    domain: "InputStatusMigration",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "复制后的应用标识或代码签名无效。"]
                )
            }

            let hadExistingApp = fileManager.fileExists(atPath: targetAppURL.path)
            if hadExistingApp {
                try fileManager.moveItem(at: targetAppURL, to: backupAppURL)
            }
            do {
                try fileManager.moveItem(at: stagingAppURL, to: targetAppURL)
            } catch {
                if hadExistingApp {
                    try? fileManager.moveItem(at: backupAppURL, to: targetAppURL)
                }
                throw error
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [AppConfig.migrationRelaunchArgument]
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: targetAppURL, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async {
                    if let error {
                        try? fileManager.removeItem(at: targetAppURL)
                        if hadExistingApp {
                            try? fileManager.moveItem(at: backupAppURL, to: targetAppURL)
                        }
                        self?.showAlert(title: "无法启动迁移后的应用", message: error.localizedDescription)
                        return
                    }
                    if hadExistingApp {
                        try? fileManager.removeItem(at: backupAppURL)
                    }
                    NSApp.terminate(nil)
                }
            }
        } catch {
            try? fileManager.removeItem(at: stagingAppURL)
            throw error
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
