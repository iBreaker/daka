import Foundation

struct WiFiSystemProfiler {
    struct Snapshot {
        var currentSSID: String?
        var visibleSSIDs: [String]
    }

    static func snapshot() -> Snapshot {
        guard let output = runSystemProfiler() else {
            return Snapshot(currentSSID: nil, visibleSSIDs: [])
        }

        return parse(output)
    }

    private static func runSystemProfiler() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPAirPortDataType"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private static func parse(_ output: String) -> Snapshot {
        var currentSSID: String?
        var visible = Set<String>()
        var inCurrentNetworkInformation = false
        var inOtherLocalNetworks = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "Current Network Information:" {
                inCurrentNetworkInformation = true
                inOtherLocalNetworks = false
                continue
            }

            if trimmed == "Other Local Wi-Fi Networks:" {
                inCurrentNetworkInformation = false
                inOtherLocalNetworks = true
                continue
            }

            guard trimmed.hasSuffix(":") else {
                continue
            }

            let name = String(trimmed.dropLast())
            guard isLikelySSIDLine(name) else {
                continue
            }

            if inCurrentNetworkInformation, currentSSID == nil {
                currentSSID = name
                visible.insert(name)
            } else if inOtherLocalNetworks {
                visible.insert(name)
            }
        }

        return Snapshot(
            currentSSID: currentSSID,
            visibleSSIDs: visible.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    private static func isLikelySSIDLine(_ value: String) -> Bool {
        let ignored = [
            "Wi-Fi",
            "Software Versions",
            "Interfaces",
            "Current Network Information",
            "Other Local Wi-Fi Networks",
            "AirDrop",
            "Auto Unlock"
        ]

        if ignored.contains(value) {
            return false
        }

        return !value.contains(":")
    }
}
