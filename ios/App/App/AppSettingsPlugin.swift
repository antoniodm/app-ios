import Capacitor
import Foundation
import UIKit

@objc(AppSettingsPlugin)
public class AppSettingsPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "AppSettingsPlugin"
    public let jsName = "AppSettings"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openSettings",      returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "autoRegisterToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateTokenUI",     returnType: CAPPluginReturnPromise),
    ]

    @objc func openSettings(_ call: CAPPluginCall) {
        call.resolve()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let bridge = self.bridge else { return }
            let vc = AppSettingsViewController(bridge: bridge)
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .pageSheet
            if #available(iOS 15.0, *) {
                if let sheet = nav.sheetPresentationController {
                    sheet.detents = [.medium(), .large()]
                    sheet.prefersGrabberVisible = true
                }
            }
            bridge.viewController?.present(nav, animated: true)
        }
    }

    /** Auto-registrazione silenziosa del token APNs al login — nessuna UI */
    @objc func autoRegisterToken(_ call: CAPPluginCall) {
        call.resolve()
        guard let token = UserDefaults.standard.string(forKey: "apns_device_token"),
              let webView = bridge?.webView,
              let currentURL = webView.url else { return }
        var comps = URLComponents()
        comps.scheme = currentURL.scheme
        comps.host   = currentURL.host
        comps.port   = currentURL.port
        comps.path   = "/json_savefcmtoken"
        guard let url = comps.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        request.httpBody = "v_token=\(enc)".data(using: .utf8)
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies   = false
        URLSession(configuration: config).dataTask(with: request) { [weak self] data, _, _ in
            var status = 500
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["http_code"] {
                status = Int(String(describing: code)) ?? 500
            }
            if status == 204 {
                UserDefaults.standard.set("1", forKey: "CapacitorStorage.token_registered")
                UserDefaults.standard.set(token, forKey: "CapacitorStorage.token_value")
                DispatchQueue.main.async {
                    self?.bridge?.webView?.evaluateJavaScript(
                        "window._guardroom_token_registered=true;", completionHandler: nil)
                }
            }
        }.resume()
    }

    @objc func updateTokenUI(_ call: CAPPluginCall) {
        let registered = call.getBool("registered") ?? false
        if registered {
            UserDefaults.standard.set("1", forKey: "CapacitorStorage.token_registered")
        } else {
            UserDefaults.standard.removeObject(forKey: "CapacitorStorage.token_registered")
        }
        call.resolve()
    }
}
