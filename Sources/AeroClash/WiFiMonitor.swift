import Foundation
import AppKit
import CoreWLAN
import CoreLocation

/// 读取当前 Wi‑Fi 名称。新版 macOS 要求应用获得“定位服务”授权后才能读取 Wi‑Fi 名称（KongBabel 不读取位置）。
@MainActor
final class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    var onAuthorizationChange: (() -> Void)?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    /// 当前连接的 Wi‑Fi 名称；未连接 Wi‑Fi 或没有定位授权时为 nil
    var currentSSID: String? {
        guard let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty else { return nil }
        return ssid
    }

    var needsLocationPermission: Bool {
        switch locationManager.authorizationStatus {
        case .notDetermined, .denied, .restricted: return true
        default: return false
        }
    }

    /// 首次请求时弹出系统授权；已拒绝过则打开系统设置中的定位服务页面
    func requestPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onAuthorizationChange?() }
    }
}
