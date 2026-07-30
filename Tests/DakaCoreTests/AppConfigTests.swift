import Foundation
import Testing
@testable import DakaCore

struct AppConfigTests {
    @Test func oldConfigWithoutTargetDurationUsesDefaultTenAndHalfHours() throws {
        let json = """
        {
          "evaluationIntervalSeconds": 60,
          "rule": {
            "name": "Default",
            "matchMode": "all",
            "conditions": [
              {
                "type": "screenUnlocked"
              }
            ]
          }
        }
        """

        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.targetDurationSeconds == 10.5 * 60 * 60)
    }

    @Test func externalDisplayConditionRoundTripsThroughConfigJSON() throws {
        let config = AppConfig(
            rule: TimerRule(
                name: "Display",
                matchMode: .all,
                conditions: [.externalDisplayConnected]
            ),
            evaluationIntervalSeconds: 60,
            targetDurationSeconds: 10.3 * 60 * 60,
            monthlyAverageTargetSeconds: 10.3 * 60 * 60
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.rule.conditions == [.externalDisplayConnected])
        #expect(decoded.targetDurationSeconds == 10.3 * 60 * 60)
        #expect(decoded.monthlyAverageTargetSeconds == 10.3 * 60 * 60)
    }
}
