import Foundation

public enum MatchMode: String, Codable, Sendable {
    case all
    case any
}

public enum TimerCondition: Codable, Equatable, Hashable, Sendable {
    case screenUnlocked
    case wifiConnected(ssid: String)
    case powerConnected
    case networkReachable(host: String, port: Int)
    case timeRange(start: String, end: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case ssid
        case host
        case port
        case start
        case end
    }

    private enum Kind: String, Codable {
        case screenUnlocked
        case wifiConnected
        case powerConnected
        case networkReachable
        case timeRange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)

        switch kind {
        case .screenUnlocked:
            self = .screenUnlocked
        case .wifiConnected:
            self = .wifiConnected(ssid: try container.decode(String.self, forKey: .ssid))
        case .powerConnected:
            self = .powerConnected
        case .networkReachable:
            self = .networkReachable(
                host: try container.decode(String.self, forKey: .host),
                port: try container.decode(Int.self, forKey: .port)
            )
        case .timeRange:
            self = .timeRange(
                start: try container.decode(String.self, forKey: .start),
                end: try container.decode(String.self, forKey: .end)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .screenUnlocked:
            try container.encode(Kind.screenUnlocked, forKey: .type)
        case let .wifiConnected(ssid):
            try container.encode(Kind.wifiConnected, forKey: .type)
            try container.encode(ssid, forKey: .ssid)
        case .powerConnected:
            try container.encode(Kind.powerConnected, forKey: .type)
        case let .networkReachable(host, port):
            try container.encode(Kind.networkReachable, forKey: .type)
            try container.encode(host, forKey: .host)
            try container.encode(port, forKey: .port)
        case let .timeRange(start, end):
            try container.encode(Kind.timeRange, forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
        }
    }
}

public struct TimerRule: Codable, Equatable, Sendable {
    public var name: String
    public var matchMode: MatchMode
    public var conditions: [TimerCondition]

    public init(name: String, matchMode: MatchMode, conditions: [TimerCondition]) {
        self.name = name
        self.matchMode = matchMode
        self.conditions = conditions
    }

    public static let defaultRule = TimerRule(
        name: "Default",
        matchMode: .all,
        conditions: [.screenUnlocked]
    )
}

public protocol ConditionChecking {
    func evaluate(_ condition: TimerCondition, at date: Date) -> Bool
}

public struct RuleEvaluator {
    private let checker: ConditionChecking

    public init(checker: ConditionChecking) {
        self.checker = checker
    }

    public func evaluate(_ rule: TimerRule, at date: Date) -> Bool {
        guard !rule.conditions.isEmpty else {
            return false
        }

        switch rule.matchMode {
        case .all:
            return rule.conditions.allSatisfy { checker.evaluate($0, at: date) }
        case .any:
            return rule.conditions.contains { checker.evaluate($0, at: date) }
        }
    }
}
