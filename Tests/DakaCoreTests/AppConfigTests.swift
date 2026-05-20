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
}
