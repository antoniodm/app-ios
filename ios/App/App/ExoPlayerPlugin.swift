import Capacitor
import Foundation
import UIKit

@objc(ExoPlayerPlugin)
public class ExoPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExoPlayerPlugin"
    public let jsName = "ExoPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openMatrix", returnType: CAPPluginReturnPromise),
    ]

    static weak var sharedBridge: CAPBridgeProtocol?
    static var pendingCloseJs: String?

    @objc func openMatrix(_ call: CAPPluginCall) {
        guard let streams = call.getArray("streams") as? [[String: Any]], !streams.isEmpty else {
            call.reject("Nessuno stream")
            return
        }

        var urls: [String] = []
        var names: [String] = []
        var closeJs = "(function(){"

        for (i, stream) in streams.enumerated() {
            let url = stream["url"] as? String ?? ""
            let name = stream["name"] as? String ?? "Cam \(i + 1)"
            urls.append(url)
            names.append(name)

            let seriale = stream["seriale"] as? String ?? ""
            let streamSessionCamId = stream["streamSessionCamId"] as? String ?? ""
            if !seriale.isEmpty && !streamSessionCamId.isEmpty {
                closeJs += "fetch('/dashboard/controlroomremovecam/\(seriale)/\(streamSessionCamId)',{method:'POST',credentials:'same-origin'});"
            }
        }
        closeJs += "})();"

        ExoPlayerPlugin.sharedBridge = bridge
        ExoPlayerPlugin.pendingCloseJs = closeJs

        DispatchQueue.main.async {
            let vc = CameraMatrixViewController()
            vc.streamUrls = urls
            vc.streamNames = names
            vc.modalPresentationStyle = .overFullScreen
            self.bridge?.viewController?.present(vc, animated: false)
            call.resolve()
        }
    }

    static func executeClose() {
        guard let js = pendingCloseJs else { return }
        let jsToRun = js
        pendingCloseJs = nil
        DispatchQueue.main.async {
            sharedBridge?.webView?.evaluateJavaScript(jsToRun, completionHandler: nil)
        }
    }
}
