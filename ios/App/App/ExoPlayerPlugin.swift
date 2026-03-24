import Capacitor
import Foundation
import UIKit

@objc(ExoPlayerPlugin)
public class ExoPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExoPlayerPlugin"
    public let jsName = "ExoPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "askPlayerType", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openMatrix",    returnType: CAPPluginReturnPromise),
    ]

    static weak var sharedBridge: CAPBridgeProtocol?
    static var pendingCloseJs: String?

    /**
     * Su iOS AVPlayer supporta solo HLS. Restituisce sempre "hls".
     */
    @objc func askPlayerType(_ call: CAPPluginCall) {
        var result = JSObject()
        result["type"] = "hls"
        call.resolve(result)
    }

    /**
     * Apre la matrix di stream.
     * Il parametro "type" è ignorato su iOS (AVPlayer supporta solo HLS).
     */
    @objc func openMatrix(_ call: CAPPluginCall) {
        guard let streams = call.getArray("streams") as? [[String: Any]], !streams.isEmpty else {
            call.reject("Nessuno stream")
            return
        }

        var urls:   [String] = []
        var names:  [String] = []
        var closeJs = "(function(){"

        for (i, stream) in streams.enumerated() {
            let url  = stream["url"]  as? String ?? ""
            let name = stream["name"] as? String ?? "Cam \(i + 1)"
            urls.append(url)
            names.append(name)

            let seriale            = stream["seriale"]            as? String ?? ""
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
            vc.streamUrls  = urls
            vc.streamNames = names
            vc.modalPresentationStyle = .overFullScreen
            self.bridge?.viewController?.present(vc, animated: false)
            call.resolve()
        }
    }

    // MARK: - Helpers URL (per compatibilità con Android)

    /** Converte URL HLS in URL RTSP (non usato su iOS — AVPlayer non supporta RTSP) */
    static func hlsToRtsp(_ hlsUrl: String) -> String {
        return hlsUrl
            .replacingOccurrences(of: "https://",    with: "rtsp://")
            .replacingOccurrences(of: "ssb-pull.",   with: "ssb.")
            .replacingOccurrences(of: "ssa-pull.",   with: "ssa.")
            .replacingOccurrences(of: ":2053/",      with: ":8554/")
            .replacingOccurrences(of: "/index.m3u8", with: "")
    }

    /** Converte URL HLS in URL WHEP (non usato su iOS senza libreria WebRTC) */
    static func hlsToWhep(_ hlsUrl: String) -> String {
        return hlsUrl
            .replacingOccurrences(of: ":2053/",      with: ":2096/")
            .replacingOccurrences(of: "/index.m3u8", with: "/whep")
    }

    // MARK: - Close callback

    static func executeClose() {
        guard let js = pendingCloseJs else { return }
        let jsToRun = js
        pendingCloseJs = nil
        DispatchQueue.main.async {
            sharedBridge?.webView?.evaluateJavaScript(jsToRun, completionHandler: nil)
        }
    }
}
