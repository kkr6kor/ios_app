import Foundation
import NetworkExtension
import SystemConfiguration.CaptiveNetwork

/// Joins the Tripper Dash Wi-Fi (`RE_*`) via `NEHotspotConfiguration` — the iOS
/// analogue of Android's `WifiNetworkSpecifier`. iOS 13+ supports prefix join, so
/// any rider's dash associates without hardcoding the exact SSID.
///
/// Requires the `com.apple.developer.networking.HotspotConfiguration` entitlement
/// (free) and, to read back the joined SSID, location permission.
final class DashWiFiManager: ObservableObject {
    enum Status: String { case idle, requesting, connected, error }

    @Published private(set) var status: Status = .idle
    @Published private(set) var ssid: String = ""
    @Published private(set) var error: String?

    /// `password` defaults to the RE Tripper factory passphrase; rider-overridable.
    func connect(ssidPrefix: String = "RE_", password: String = "12345678") {
        status = .requesting; error = nil

        let config = NEHotspotConfiguration(ssidPrefix: ssidPrefix, passphrase: password, isWEP: false)
        config.joinOnce = false

        NEHotspotConfigurationManager.shared.apply(config) { [weak self] err in
            DispatchQueue.main.async {
                guard let self else { return }
                if let nsErr = err as NSError?,
                   nsErr.code != NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    self.status = .error
                    self.error = nsErr.localizedDescription
                    DiagnosticsLog.shared.log("wifi", "apply failed: \(nsErr.localizedDescription)")
                } else {
                    self.ssid = Self.currentSSID() ?? ""
                    self.status = .connected
                    DiagnosticsLog.shared.log("wifi", "connected ssid='\(self.ssid)'")
                }
            }
        }
    }

    func disconnect() {
        if !ssid.isEmpty {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        }
        status = .idle
        ssid = ""
    }

    /// Read the connected Wi-Fi SSID (needs location permission on iOS 13+).
    static func currentSSID() -> String? {
        guard let interfaces = CNCopySupportedInterfaces() as? [String] else { return nil }
        for iface in interfaces {
            if let info = CNCopyCurrentNetworkInfo(iface as CFString) as? [String: Any],
               let ssid = info[kCNNetworkInfoKeySSID as String] as? String {
                return ssid
            }
        }
        return nil
    }
}
