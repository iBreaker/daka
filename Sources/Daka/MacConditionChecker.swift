import CoreGraphics
import CoreWLAN
import DakaCore
import Foundation
import IOKit.ps
import Network

final class MacConditionChecker: ConditionChecking {
    private struct Endpoint: Hashable {
        var host: String
        var port: Int
    }

    private let stateLock = NSLock()
    private var screenSaverRunning = false
    private var reachabilityCache: [Endpoint: (checkedAt: Date, reachable: Bool)] = [:]

    var isScreenSaverRunning: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return screenSaverRunning
        }
        set {
            stateLock.lock()
            screenSaverRunning = newValue
            stateLock.unlock()
        }
    }

    func evaluate(_ condition: TimerCondition, at date: Date) -> Bool {
        switch condition {
        case .screenUnlocked:
            return isScreenUnlocked() && !isScreenSaverRunning
        case let .wifiConnected(ssid):
            return wifiSSIDMatches(current: currentSSID(), expected: ssid)
        case .powerConnected:
            return isPowerConnected()
        case .externalDisplayConnected:
            return isExternalDisplayConnected()
        case let .networkReachable(host, port):
            return isReachable(host: host, port: port)
        case let .timeRange(start, end):
            return isInTimeRange(start: start, end: end, at: date)
        }
    }

    private func isScreenUnlocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        return !(session["CGSSessionScreenIsLocked"] as? Bool ?? false)
    }

    private func currentSSID() -> String? {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return ssid
        }

        return WiFiSystemProfiler.snapshot().currentSSID
    }

    private func wifiSSIDMatches(current: String?, expected: String) -> Bool {
        WiFiSSIDMatcher.matches(current: current, expected: expected)
    }

    private func isPowerConnected() -> Bool {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() != nil
    }

    private func isExternalDisplayConnected() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        let error = CGGetOnlineDisplayList(
            UInt32(displays.count),
            &displays,
            &displayCount
        )
        guard error == .success else {
            return false
        }

        return displays.prefix(Int(displayCount)).contains {
            CGDisplayIsBuiltin($0) == 0
        }
    }

    private func isReachable(host: String, port: Int) -> Bool {
        let endpoint = Endpoint(host: host, port: port)
        if let cached = reachabilityCache[endpoint],
           Date().timeIntervalSince(cached.checkedAt) <= 15 {
            return cached.reachable
        }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "daka.network-reachability")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        var reachable = false

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                reachable = true
                connection.cancel()
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        connection.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 2)
        connection.cancel()
        reachabilityCache[endpoint] = (Date(), reachable)
        return reachable
    }

    private func isInTimeRange(start: String, end: String, at date: Date) -> Bool {
        guard let startMinutes = minutes(from: start),
              let endMinutes = minutes(from: end) else {
            return false
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if startMinutes <= endMinutes {
            return current >= startMinutes && current <= endMinutes
        }

        return current >= startMinutes || current <= endMinutes
    }

    private func minutes(from value: String) -> Int? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        return hour * 60 + minute
    }
}
