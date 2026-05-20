import Foundation
import Testing
@testable import DakaCore

struct RuleEvaluatorTests {
    @Test func allRequiresEveryCondition() {
        let checker = StubChecker(results: [.screenUnlocked: true, .powerConnected: false])
        let evaluator = RuleEvaluator(checker: checker)
        let rule = TimerRule(name: "Office", matchMode: .all, conditions: [.screenUnlocked, .powerConnected])

        #expect(!evaluator.evaluate(rule, at: Date()))
    }

    @Test func anyRequiresOneCondition() {
        let checker = StubChecker(results: [.screenUnlocked: false, .powerConnected: true])
        let evaluator = RuleEvaluator(checker: checker)
        let rule = TimerRule(name: "Office", matchMode: .any, conditions: [.screenUnlocked, .powerConnected])

        #expect(evaluator.evaluate(rule, at: Date()))
    }

    @Test func emptyRuleDoesNotMatch() {
        let checker = StubChecker(results: [:])
        let evaluator = RuleEvaluator(checker: checker)
        let rule = TimerRule(name: "Empty", matchMode: .all, conditions: [])

        #expect(!evaluator.evaluate(rule, at: Date()))
    }
}

private struct StubChecker: ConditionChecking {
    var results: [TimerCondition: Bool]

    func evaluate(_ condition: TimerCondition, at date: Date) -> Bool {
        results[condition] ?? false
    }
}
