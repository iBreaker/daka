import Foundation

public enum ClockInSessionDecision: Equatable, Sendable {
    case none
    case showManualConfirmation
    case startOrUpdateAutomatically
    case closeExternalDisplaySession
}

public enum ClockInSessionDecider {
    public static func decide(
        hasStartedToday: Bool,
        ruleMatched: Bool,
        statsPaused: Bool,
        usesExternalDisplayCondition: Bool,
        externalDisplayMatched: Bool,
        previousExternalDisplayMatched: Bool,
        externalDisplaySessionActive: Bool,
        externalDisplaySessionClosed: Bool
    ) -> ClockInSessionDecision {
        guard !statsPaused else {
            return .none
        }

        if
            usesExternalDisplayCondition,
            externalDisplaySessionActive,
            previousExternalDisplayMatched,
            !externalDisplayMatched,
            hasStartedToday
        {
            return .closeExternalDisplaySession
        }

        guard ruleMatched else {
            return .none
        }

        guard hasStartedToday else {
            if usesExternalDisplayCondition {
                return externalDisplayMatched
                    ? .startOrUpdateAutomatically
                    : .showManualConfirmation
            }
            return .showManualConfirmation
        }

        if usesExternalDisplayCondition {
            if externalDisplayMatched {
                return .startOrUpdateAutomatically
            }

            if externalDisplaySessionActive || externalDisplaySessionClosed {
                return .none
            }
        }

        return .startOrUpdateAutomatically
    }
}
