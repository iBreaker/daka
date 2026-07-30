import Foundation
import Testing
@testable import DakaCore

struct ClockInSessionDecisionTests {
    @Test func uniqueExternalDisplayConditionStartsAutomaticallyWhenConnected() {
        let decision = ClockInSessionDecider.decide(
            hasStartedToday: false,
            ruleMatched: true,
            statsPaused: false,
            usesExternalDisplayCondition: true,
            externalDisplayMatched: true,
            previousExternalDisplayMatched: false,
            externalDisplaySessionActive: false,
            externalDisplaySessionClosed: false
        )

        #expect(decision == .startOrUpdateAutomatically)
    }

    @Test func anyMixedRuleDoesNotAutoStartWhenExternalDisplayIsDisconnected() {
        let decision = ClockInSessionDecider.decide(
            hasStartedToday: false,
            ruleMatched: true,
            statsPaused: false,
            usesExternalDisplayCondition: true,
            externalDisplayMatched: false,
            previousExternalDisplayMatched: false,
            externalDisplaySessionActive: false,
            externalDisplaySessionClosed: false
        )

        #expect(decision == .showManualConfirmation)
    }

    @Test func allMixedRuleDoesNothingUntilEveryConditionMatches() {
        let decision = ClockInSessionDecider.decide(
            hasStartedToday: false,
            ruleMatched: false,
            statsPaused: false,
            usesExternalDisplayCondition: true,
            externalDisplayMatched: true,
            previousExternalDisplayMatched: false,
            externalDisplaySessionActive: false,
            externalDisplaySessionClosed: false
        )

        #expect(decision == .none)
    }

    @Test func unpluggingExternalDisplayClosesSessionEvenWhenOtherConditionStillMatches() {
        let decision = ClockInSessionDecider.decide(
            hasStartedToday: true,
            ruleMatched: true,
            statsPaused: false,
            usesExternalDisplayCondition: true,
            externalDisplayMatched: false,
            previousExternalDisplayMatched: true,
            externalDisplaySessionActive: true,
            externalDisplaySessionClosed: false
        )

        #expect(decision == .closeExternalDisplaySession)
    }

    @Test func closedExternalDisplaySessionDoesNotKeepRefreshingFromOtherConditions() {
        let decision = ClockInSessionDecider.decide(
            hasStartedToday: true,
            ruleMatched: true,
            statsPaused: false,
            usesExternalDisplayCondition: true,
            externalDisplayMatched: false,
            previousExternalDisplayMatched: false,
            externalDisplaySessionActive: false,
            externalDisplaySessionClosed: true
        )

        #expect(decision == .none)
    }

    @Test func manuallyStartedMixedRuleCanStillRefreshWithoutExternalDisplay() {
        let decision = ClockInSessionDecider.decide(
            hasStartedToday: true,
            ruleMatched: true,
            statsPaused: false,
            usesExternalDisplayCondition: true,
            externalDisplayMatched: false,
            previousExternalDisplayMatched: false,
            externalDisplaySessionActive: false,
            externalDisplaySessionClosed: false
        )

        #expect(decision == .startOrUpdateAutomatically)
    }
}
