import Capacitor
import Foundation
import UIKit
import AVKit

@objc(ExoPlayerPlugin)
public class ExoPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExoPlayerPlugin"
    public let jsName = "ExoPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "askPlayerType", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openMatrix",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openStream",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "closeStream",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadFile",  returnType: CAPPluginReturnPromise),
    ]

    private weak var streamPlayerVC: AVPlayerViewController?

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

        launchMatrix(type: "webrtc", hlsUrls: hlsUrls, names: names)
        call.resolve()
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

    // MARK: - openStream / closeStream (video registrato: MP4, ecc.)

    @objc func openStream(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("URL mancante"); return
        }
        // Copia i cookie dalla WKWebView per autenticare la richiesta AVPlayer (sessione PHP)
        bridge?.webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let host = url.host ?? ""
            let cookieHeader = cookies
                .filter { c in
                    let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return host == domain || host.hasSuffix("." + domain)
                }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            DispatchQueue.main.async {
                var assetOptions: [String: Any] = [:]
                if !cookieHeader.isEmpty {
                    assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = ["Cookie": cookieHeader]
                }
                let asset = AVURLAsset(url: url, options: assetOptions)
                let item = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: item)
                let vc = AVPlayerViewController()
                vc.player = player
                vc.modalPresentationStyle = .fullScreen
                self.streamPlayerVC = vc
                self.bridge?.viewController?.present(vc, animated: true) {
                    player.play()
                }
                call.resolve()
            }
        }
    }

    /// Scarica un file dal server (con cookie di sessione) e mostra lo share sheet iOS.
    @objc func downloadFile(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("URL mancante"); return
        }
        // Copia i cookie dalla WKWebView a URLSession così la sessione autenticata viene usata
        bridge?.webView?.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = HTTPCookieStorage.shared
            config.httpShouldSetCookies = true
            URLSession(configuration: config).downloadTask(with: url) { [weak self] tempURL, response, error in
                guard let self = self else { return }
                if let error = error { call.reject(error.localizedDescription); return }
                guard let tempURL = tempURL else { call.reject("File non ricevuto"); return }
                let filename = response?.suggestedFilename ?? url.lastPathComponent
                let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.moveItem(at: tempURL, to: destURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let vc = UIActivityViewController(activityItems: [destURL], applicationActivities: nil)
                    if let pop = vc.popoverPresentationController {
                        pop.sourceView = self.bridge?.viewController?.view
                    }
                    self.bridge?.viewController?.present(vc, animated: true)
                    call.resolve()
                }
            }.resume()
        }
    }

    @objc func closeStream(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.streamPlayerVC?.player?.pause()
            self.streamPlayerVC?.dismiss(animated: true)
            self.streamPlayerVC = nil
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
