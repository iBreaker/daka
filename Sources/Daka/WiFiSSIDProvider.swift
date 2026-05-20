import CoreWLAN
import Foundation

enum WiFiSSIDProvider {
    static func availableSSIDs(keeping selected: String = "") -> [String] {
        var names = Set<String>()

        if !selected.isEmpty {
            names.insert(selected)
        }

        guard let interface = CWWiFiClient.shared().interface() else {
            return names.sorted()
        }

        if let current = interface.ssid(), !current.isEmpty {
            names.insert(current)
        }

        if let networks = try? interface.scanForNetworks(withSSID: nil) {
            for network in networks {
                if let ssid = network.ssid, !ssid.isEmpty {
                    names.insert(ssid)
                }
            }
        }

        let snapshot = WiFiSystemProfiler.snapshot()
        if let currentSSID = snapshot.currentSSID {
            names.insert(currentSSID)
        }
        for ssid in snapshot.visibleSSIDs {
            names.insert(ssid)
        }

        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
