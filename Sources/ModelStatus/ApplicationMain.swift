import AppKit

@main
enum ModelStatusMain {
    private static let appDelegate = AppDelegate()

    static func main() {
        let arguments = ProcessInfo.processInfo.arguments
        let isQAPreview = arguments.contains { $0.hasPrefix("--qa-") }
        if !arguments.contains(AppConfig.migrationRelaunchArgument), !isQAPreview {
            terminateOtherInstances()
        }
        let application = NSApplication.shared
        application.delegate = appDelegate
        application.run()
    }

    private static func terminateOtherInstances() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: "im.input.model-status"
        ).filter { $0.processIdentifier != currentPID }

        for application in others { application.terminate() }
        if !others.isEmpty {
            Thread.sleep(forTimeInterval: 0.15)
            for application in others where !application.isTerminated { application.forceTerminate() }
        }
    }
}
