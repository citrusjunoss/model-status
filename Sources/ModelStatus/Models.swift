import Foundation

struct ModelDefinition {
    let id: String
    let name: String
    let shortName: String

    static let monitored = [
        ModelDefinition(id: "gpt-5.6-sol", name: "GPT-5.6 Sol", shortName: "S"),
        ModelDefinition(id: "gpt-5.6-terra", name: "GPT-5.6 Terra", shortName: "T"),
        ModelDefinition(id: "gpt-5.6-luna", name: "GPT-5.6 Lunna", shortName: "L"),
        ModelDefinition(id: "gpt-5.5", name: "GPT-5.5", shortName: "5.5")
    ]

    static var orbModel: ModelDefinition { monitored[0] }
    static var orbModels: [ModelDefinition] { [orbModel] }
    static var detailOnlyModels: [ModelDefinition] { Array(monitored.dropFirst()) }
}

struct ProbeHistoryEntry: Codable {
    var isOnline: Bool
    var statusStartedAt: Date
    var previousOppositeDuration: TimeInterval?
    var lastLatencyMilliseconds: Int?
    var lastCheckedAt: Date
}

struct ProbeBackoffState: Codable {
    var consecutiveFailures: Int
    var nextAllowedAt: Date
}

struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

enum ProbePhase {
    case unknown
    case online
    case failed
}

struct ProbePresentation {
    let phase: ProbePhase
    let latencyMilliseconds: Int?
    let previousOppositeDuration: TimeInterval?
    let hasRecentInterruption: Bool
}

struct UsageResponse: Decodable {
    struct Quota: Decodable {
        let limit: Double
        let used: Double
        let remaining: Double
    }

    struct Subscription: Decodable {
        let dailyUsageUSD: Double?
        let dailyLimitUSD: Double?
        let weeklyUsageUSD: Double?
        let weeklyLimitUSD: Double?
        let monthlyUsageUSD: Double?
        let monthlyLimitUSD: Double?

        enum CodingKeys: String, CodingKey {
            case dailyUsageUSD = "daily_usage_usd"
            case dailyLimitUSD = "daily_limit_usd"
            case weeklyUsageUSD = "weekly_usage_usd"
            case weeklyLimitUSD = "weekly_limit_usd"
            case monthlyUsageUSD = "monthly_usage_usd"
            case monthlyLimitUSD = "monthly_limit_usd"
        }
    }

    struct Usage: Decodable {
        struct Today: Decodable {
            let actualCost: Double?

            enum CodingKeys: String, CodingKey {
                case actualCost = "actual_cost"
            }
        }

        let actualCost: Double?
        let today: Today?

        enum CodingKeys: String, CodingKey {
            case actualCost = "actual_cost"
            case today
        }
    }

    struct DailyUsage: Decodable {
        let actualCost: Double?

        enum CodingKeys: String, CodingKey {
            case actualCost = "actual_cost"
        }
    }

    let mode: String?
    let planName: String?
    let quota: Quota?
    let subscription: Subscription?
    let balance: Double?
    let remaining: Double?
    let usage: Usage?
    let dailyUsage: [DailyUsage]?

    var currentActualCost: Double? {
        usage?.today?.actualCost ?? usage?.actualCost ?? dailyUsage?.first?.actualCost
    }

    enum CodingKeys: String, CodingKey {
        case mode
        case planName
        case quota
        case subscription
        case balance
        case remaining
        case usage
        case dailyUsage = "daily_usage"
    }
}

struct QuotaSnapshot {
    let current: Double
    let other: Double
    let remaining: Double
    let total: Double
    let remainingFraction: Double
    let updatedAt: Date

    init(response: UsageResponse, now: Date = Date()) {
        let period: (used: Double, limit: Double)
        if let subscription = response.subscription,
           let limit = subscription.dailyLimitUSD, limit > 0 {
            period = (subscription.dailyUsageUSD ?? 0, limit)
        } else if let quota = response.quota, quota.limit > 0 {
            period = (quota.used, quota.limit)
        } else if let subscription = response.subscription,
                  let limit = subscription.weeklyLimitUSD, limit > 0 {
            period = (subscription.weeklyUsageUSD ?? 0, limit)
        } else if let subscription = response.subscription,
                  let limit = subscription.monthlyLimitUSD, limit > 0 {
            period = (subscription.monthlyUsageUSD ?? 0, limit)
        } else {
            let used = max(response.currentActualCost ?? 0, 0)
            period = (used, used + max(response.remaining ?? response.balance ?? 0, 0))
        }

        let used = min(max(period.used, 0), max(period.limit, 0))
        let current = min(max(response.currentActualCost ?? response.quota?.used ?? 0, 0), used)
        let other = max(used - current, 0)
        let remaining = max(period.limit - used, 0)
        self.current = current
        self.other = other
        self.remaining = remaining
        self.total = max(period.limit, 0)
        self.remainingFraction = period.limit > 0 ? min(max(remaining / period.limit, 0), 1) : 0
        updatedAt = now
    }

    init(current: Double, other: Double, remaining: Double, total: Double, updatedAt: Date) {
        self.current = current
        self.other = other
        self.remaining = remaining
        self.total = total
        self.remainingFraction = total > 0 ? min(max(remaining / total, 0), 1) : 0
        self.updatedAt = updatedAt
    }
}
