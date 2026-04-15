import Capacitor
import Foundation
import UIKit
import AVKit

@objc(ExoPlayerPlugin)
public class ExoPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExoPlayerPlugin"
    public let jsName = "ExoPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openMatrix",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openStream",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "closeStream",   returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadFile",  returnType: CAPPluginReturnPromise),
    ]

    private weak var streamPlayerVC: AVPlayerViewController?

    static weak var sharedBridge: CAPBridgeProtocol?
    static var pendingCloseJs: String?

    @objc func openMatrix(_ call: CAPPluginCall) {
        guard let streams = call.getArray("streams") as? [[String: Any]], !streams.isEmpty else {
            call.reject("Nessuno stream")
            return
        }

        var hlsUrls:      [String] = []
        var names:        [String] = []
        var perCamCloseJs:[String] = []
        var allCloseJsBody = ""

        for (i, stream) in streams.enumerated() {
            let url  = stream["url"]  as? String ?? ""
            let name = stream["name"] as? String ?? "Cam \(i + 1)"
            hlsUrls.append(url)
            names.append(name)

            let seriale            = stream["seriale"]            as? String ?? ""
            let streamSessionCamId = stream["streamSessionCamId"] as? String ?? ""
            if !seriale.isEmpty && !streamSessionCamId.isEmpty {
                let js = "fetch('/dashboard/controlroomremovecam/\(seriale)/\(streamSessionCamId)',{method:'POST',credentials:'same-origin'});"
                allCloseJsBody += js
                perCamCloseJs.append(js)
            } else {
                perCamCloseJs.append("")
            }
        }

        let allCloseJs = "(function(){\(allCloseJsBody)})();"
        ExoPlayerPlugin.sharedBridge = bridge
        call.resolve()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let selVC = CameraSelectionViewController()
            selVC.cameraNames = names
            selVC.onAll = { [weak self] in
                guard let self = self else { return }
                ExoPlayerPlugin.pendingCloseJs = allCloseJs
                self.launchMatrix(type: "webrtc", hlsUrls: hlsUrls, names: names)
            }
            selVC.onConfirm = { [weak self] checked in
                guard let self = self else { return }
                var selUrls:  [String] = []
                var selNames: [String] = []
                var body = ""
                for (i, isChecked) in checked.enumerated() {
                    if isChecked {
                        selUrls.append(hlsUrls[i])
                        selNames.append(names[i])
                        body += perCamCloseJs[i]
                    }
                }
                guard !selUrls.isEmpty else { return }
                ExoPlayerPlugin.pendingCloseJs = "(function(){\(body)})();"
                self.launchMatrix(type: "webrtc", hlsUrls: selUrls, names: selNames)
            }
            selVC.modalPresentationStyle = .pageSheet
            self.bridge?.viewController?.present(selVC, animated: true)
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

    /** Converte URL HLS in URL WHEP */
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

// MARK: - Camera selection dialog

private final class CameraSelectionViewController: UIViewController {
    var cameraNames: [String] = []
    var onConfirm: (([Bool]) -> Void)?
    var onAll: (() -> Void)?

    private var checked: [Bool] = []
    private var tableView: UITableView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checked = Array(repeating: true, count: cameraNames.count)
        setupUI()
    }

    private func setupUI() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .black
        tableView.separatorColor = UIColor.gray.withAlphaComponent(0.3)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        let apriTutte = makeBtn("Apri tutte")
        apriTutte.addTarget(self, action: #selector(tapAll), for: .touchUpInside)
        view.addSubview(apriTutte)

        let apriSel = makeBtn("Apri selezionate")
        apriSel.addTarget(self, action: #selector(tapConfirm), for: .touchUpInside)
        view.addSubview(apriSel)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: apriTutte.topAnchor, constant: -12),

            apriTutte.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            apriTutte.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            apriTutte.heightAnchor.constraint(equalToConstant: 50),
            apriTutte.bottomAnchor.constraint(equalTo: apriSel.topAnchor, constant: -8),

            apriSel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            apriSel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            apriSel.heightAnchor.constraint(equalToConstant: 50),
            apriSel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func makeBtn(_ title: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor(white: 0.2, alpha: 1)
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        let btn = UIButton(configuration: config)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.layer.cornerRadius = 8
        return btn
    }

    @objc private func tapAll() {
        dismiss(animated: true) { [weak self] in self?.onAll?() }
    }

    @objc private func tapConfirm() {
        let sel = checked
        dismiss(animated: true) { [weak self] in self?.onConfirm?(sel) }
    }
}

extension CameraSelectionViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        cameraNames.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cam")
            ?? UITableViewCell(style: .default, reuseIdentifier: "cam")
        cell.textLabel?.text = cameraNames[indexPath.row]
        cell.textLabel?.textColor = .white
        cell.backgroundColor = .black
        cell.tintColor = .white
        cell.accessoryType = checked[indexPath.row] ? .checkmark : .none
        cell.selectionStyle = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        checked[indexPath.row].toggle()
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}
