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
     * Mostra il dialog di scelta tipo player e restituisce la scelta al JS.
     */
    @objc func askPlayerType(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let alert = UIAlertController(
                title: "Control Room",
                message: "Scegli il tipo di player:",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "WebRTC  (bassa latenza)", style: .default) { _ in
                var result = JSObject(); result["type"] = "webrtc"; call.resolve(result)
            })
            alert.addAction(UIAlertAction(title: "HLS  (compatibile)", style: .default) { _ in
                var result = JSObject(); result["type"] = "hls"; call.resolve(result)
            })
            alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in
                call.reject("cancelled")
            })
            self.bridge?.viewController?.present(alert, animated: true)
        }
    }

    /**
     * Apre la matrix di stream.
     * Se "type" non è specificato mostra il dialog di scelta (WebRTC / RTSP / HLS).
     */
    @objc func openMatrix(_ call: CAPPluginCall) {
        guard let streams = call.getArray("streams") as? [[String: Any]], !streams.isEmpty else {
            call.reject("Nessuno stream")
            return
        }

        var hlsUrls: [String] = []
        var names:   [String] = []
        var closeJs = "(function(){"

        for (i, stream) in streams.enumerated() {
            let url  = stream["url"]  as? String ?? ""
            let name = stream["name"] as? String ?? "Cam \(i + 1)"
            hlsUrls.append(url)
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

        let typeParam = call.getString("type")

        if let type = typeParam {
            launchMatrix(type: type, hlsUrls: hlsUrls, names: names)
            call.resolve()
        } else {
            DispatchQueue.main.async {
                let alert = UIAlertController(
                    title: "Control Room — tipo di player",
                    message: nil,
                    preferredStyle: .actionSheet
                )
                let options: [(String, String)] = [
                    ("WebRTC  (bassa latenza)", "webrtc"),
                    ("RTSP  (H.265 supportato)", "rtsp"),
                    ("HLS  (compatibile)",       "hls"),
                ]
                for (title, type) in options {
                    alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                        self?.launchMatrix(type: type, hlsUrls: hlsUrls, names: names)
                        call.resolve()
                    })
                }
                alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { _ in
                    call.reject("cancelled")
                })
                if let pop = alert.popoverPresentationController {
                    pop.sourceView = self.bridge?.viewController?.view
                    pop.sourceRect = CGRect(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY, width: 0, height: 0)
                    pop.permittedArrowDirections = []
                }
                self.bridge?.viewController?.present(alert, animated: true)
            }
        }
    }

    private func launchMatrix(type: String, hlsUrls: [String], names: [String]) {
        DispatchQueue.main.async {
            let vc: UIViewController
            switch type {
            case "webrtc":
                let webrtcVc = CameraMatrixWebRTCViewController()
                webrtcVc.streamUrls  = hlsUrls.map { ExoPlayerPlugin.hlsToWhep($0) }
                webrtcVc.streamNames = names
                vc = webrtcVc
            case "rtsp":
                // AVPlayer non supporta RTSP su iOS → usa HLS come fallback
                let hlsVc = CameraMatrixViewController()
                hlsVc.streamUrls  = hlsUrls
                hlsVc.streamNames = names
                vc = hlsVc
            default: // "hls"
                let hlsVc = CameraMatrixViewController()
                hlsVc.streamUrls  = hlsUrls
                hlsVc.streamNames = names
                vc = hlsVc
            }
            vc.modalPresentationStyle = .overFullScreen
            self.bridge?.viewController?.present(vc, animated: false)
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
