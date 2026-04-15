import Capacitor
import Foundation
import UIKit
import AVKit

@objc(ExoPlayerPlugin)
public class ExoPlayerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExoPlayerPlugin"
    public let jsName = "ExoPlayer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "openMatrix",     returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "selectCameras",  returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openStream",     returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "closeStream",    returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "downloadFile",   returnType: CAPPluginReturnPromise),
    ]

    private weak var streamPlayerVC: AVPlayerViewController?

    static weak var sharedBridge: CAPBridgeProtocol?
    static var pendingCloseJs: String?

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

        ExoPlayerPlugin.sharedBridge    = bridge
        ExoPlayerPlugin.pendingCloseJs  = closeJs

        launchMatrix(hlsUrls: hlsUrls, names: names)
        call.resolve()
    }

    /**
     * Mostra UI di selezione telecamere con anteprime.
     * Input:  { cameras: [{name, thumbnail, seriale, camId}] }
     * Output: { selected: [0, 2, ...] }
     */
    @objc func selectCameras(_ call: CAPPluginCall) {
        guard let cameras = call.getArray("cameras") as? [[String: Any]], !cameras.isEmpty else {
            call.resolve(["selected": []])
            return
        }

        let names = cameras.map { $0["name"] as? String ?? "Cam" }
        let thumbnails: [UIImage?] = cameras.map { cam in
            guard let thumb = cam["thumbnail"] as? String,
                  let comma = thumb.firstIndex(of: ",") else { return nil }
            let b64 = String(thumb[thumb.index(after: comma)...])
            guard let data = Data(base64Encoded: b64) else { return nil }
            return UIImage(data: data)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let selVC = CameraSelectionViewController()
            selVC.cameraNames  = names
            selVC.thumbnails   = thumbnails
            selVC.onAll = {
                let indices = Array(0..<cameras.count)
                call.resolve(["selected": indices])
            }
            selVC.onConfirm = { checked in
                let indices = checked.enumerated().compactMap { $0.element ? $0.offset : nil }
                call.resolve(["selected": indices])
            }
            selVC.onCancel = {
                call.resolve(["selected": []])
            }
            selVC.modalPresentationStyle = .pageSheet
            self.bridge?.viewController?.present(selVC, animated: true)
        }
    }

    private func launchMatrix(hlsUrls: [String], names: [String]) {
        DispatchQueue.main.async {
            let webrtcVc = CameraMatrixWebRTCViewController()
            webrtcVc.streamUrls  = hlsUrls.map { ExoPlayerPlugin.hlsToWhep($0) }
            webrtcVc.streamNames = names
            webrtcVc.modalPresentationStyle = .overFullScreen
            self.bridge?.viewController?.present(webrtcVc, animated: false)
        }
    }

    // MARK: - openStream / closeStream

    @objc func openStream(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("URL mancante"); return
        }
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

    @objc func downloadFile(_ call: CAPPluginCall) {
        guard let urlStr = call.getString("url"), let url = URL(string: urlStr) else {
            call.reject("URL mancante"); return
        }
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

    // MARK: - Helpers

    static func hlsToWhep(_ hlsUrl: String) -> String {
        return hlsUrl
            .replacingOccurrences(of: ":2053/",      with: ":2096/")
            .replacingOccurrences(of: "/index.m3u8", with: "/whep")
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

// MARK: - Camera selection dialog

private final class CameraSelectionViewController: UIViewController {
    var cameraNames: [String]   = []
    var thumbnails:  [UIImage?] = []
    var onConfirm: (([Bool]) -> Void)?
    var onAll:     (() -> Void)?
    var onCancel:  (() -> Void)?

    private var checked: [Bool] = []
    private var tableView: UITableView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checked = Array(repeating: true, count: cameraNames.count)
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
    }

    private func setupUI() {
        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .black
        tableView.separatorColor  = UIColor.gray.withAlphaComponent(0.3)
        tableView.rowHeight       = 72
        tableView.dataSource = self
        tableView.delegate   = self
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
        config.baseForegroundColor   = .white
        config.baseBackgroundColor   = UIColor(white: 0.2, alpha: 1)
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
        let thumb = indexPath.row < thumbnails.count ? thumbnails[indexPath.row] : nil
        cell.imageView?.image       = thumb ?? UIImage(systemName: "video.slash")
        cell.imageView?.tintColor   = .gray
        cell.imageView?.contentMode = .scaleAspectFill
        cell.imageView?.clipsToBounds = true
        cell.textLabel?.text        = cameraNames[indexPath.row]
        cell.textLabel?.textColor   = .white
        cell.backgroundColor        = .black
        cell.tintColor              = .white
        cell.accessoryType          = checked[indexPath.row] ? .checkmark : .none
        cell.selectionStyle         = .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        checked[indexPath.row].toggle()
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}

extension CameraSelectionViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onCancel?()
    }
}
