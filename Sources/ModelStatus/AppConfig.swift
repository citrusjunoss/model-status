import AppKit
import CoreGraphics

enum AppConfig {
    static let appName = "InputStatus"
    static let legacyWindowFrameKey = "ModelStatusDesktopWidget"
    static let orbFrameKey = "orbFrame.v1"
    static let detailFrameKey = "detailFrame.v1"
    static let backgroundAlphaKey = "backgroundAlpha"
    static let refreshIntervalKey = "refreshIntervalSeconds"
    static let probeHistoryKey = "probeHistory.v1"
    static let probeBackoffKey = "probeBackoff.v1"
    static let migrationRelaunchArgument = "--migrated-to-applications"
    static let defaultSize = NSSize(width: 500, height: 470)
    static let minimumSize = NSSize(width: 430, height: 450)
    static let orbSize = NSSize(width: 104, height: 104)
    static let orbInfoSize = NSSize(width: 272, height: 170)
    static let defaultBackgroundAlpha = 0.92
    static let defaultRefreshInterval: TimeInterval = 60
    static let allowedRefreshIntervals: [TimeInterval] = [60, 120, 300, 600, 900]
    static let probeTimeout: TimeInterval = 45
    static let slowLatencyMilliseconds = 5_000
    static let stabilityWindow: TimeInterval = 60 * 60
    static let keychainService = "im.input.model-status.secure-v2"
    static let keychainAccount = "quota-api-key"
    static let usageURL = URL(string: "https://ai.input.im/v1/usage")!
    static let probeURL = URL(string: "https://ai.input.im/v1/responses")!
    static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    static let githubRepository = "citrusjunoss/model-status"
    static let probeBackoffDelays: [TimeInterval] = [5 * 60, 10 * 60, 30 * 60]

    static var desktopLevel: NSWindow.Level {
        // Matches the level used by WidgetKit desktop widgets.
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    }
}

enum WidgetMode: String {
    case orb
    case detail
}

enum PauseReason: Hashable {
    case session
    case systemSleep
}

enum Palette {
    static let text = NSColor(calibratedWhite: 0.08, alpha: 1)
    static let secondaryText = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let tertiaryText = NSColor(calibratedWhite: 0.54, alpha: 1)
    static let separator = NSColor(calibratedWhite: 0.78, alpha: 0.55)
    static let green = NSColor(calibratedRed: 0.08, green: 0.68, blue: 0.32, alpha: 1)
    static let amber = NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.02, alpha: 1)
    static let red = NSColor(calibratedRed: 0.88, green: 0.12, blue: 0.10, alpha: 1)
    static let gray = NSColor(calibratedWhite: 0.62, alpha: 1)
}
