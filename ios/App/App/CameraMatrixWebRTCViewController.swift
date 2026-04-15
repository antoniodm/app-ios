import UIKit
import AVFoundation
import CapApp_SPM
import os

private func glog(_ msg: String) {
    os_log("GUARDROOM %{public}@", type: .fault, msg)
}

class CameraMatrixWebRTCViewController: UIViewController {

    var streamUrls: [String] = []
    var streamNames: [String] = []
    var allCameraNames: [String] = []
    var allCameraThumbnails: [UIImage?] = []
    var allCameraInfo: [[String: String]] = []

    var enabled: [Bool] = []
    // true = tutti i retry (WHEP + HLS) esauriti, cam non raggiungibile
    var failed: [Bool] = []
    private var peerConnections: [RTCPeerConnection?] = []
    private var delegates: [WhepDelegate?] = []
    fileprivate var frameSinks: [FrameSink?] = []
    fileprivate var videoTracks: [RTCVideoTrack?] = []
    private var rendererViews: [RTCMTLVideoView?] = []
    private var wrapperViews: [UIView?] = []
    private var avPlayers: [AVPlayer?] = []
    private var avLayers: [AVPlayerLayer?] = []
    private var avObservers: [NSObjectProtocol?] = []
    private var avKVOTokens: [NSKeyValueObservation?] = []
    private var isHlsFallback: [Bool] = []
    private var hlsFailCount: [Int] = []

    private var videoW: [Int] = []
    private var videoH: [Int] = []
    private var lastFrameTime: [TimeInterval] = []

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var scrollView: UIScrollView!
    private var contentView: UIView!
    private var closeButton: UIButton!
    private var streamsButton: UIButton!
    private var hideTimer: Timer?
    private var watchdogTimer: Timer?
    private var cols = 1
    private var rows = 1

    private let maxRetries = 4
    private let maxHlsFails = 3

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let count = streamUrls.count
        enabled       = Array(repeating: true,  count: count)
        failed        = Array(repeating: false, count: count)
        peerConnections = Array(repeating: nil, count: count)
        delegates     = Array(repeating: nil,   count: count)
        frameSinks    = Array(repeating: nil,   count: count)
        videoTracks   = Array(repeating: nil,   count: count)
        rendererViews = Array(repeating: nil,   count: count)
        wrapperViews  = Array(repeating: nil,   count: count)
        avPlayers     = Array(repeating: nil,   count: count)
        avLayers      = Array(repeating: nil,   count: count)
        avObservers   = Array(repeating: nil,   count: count)
        avKVOTokens   = Array(repeating: nil,   count: count)
        isHlsFallback = Array(repeating: false, count: count)
        hlsFailCount  = Array(repeating: 0,     count: count)
        videoW        = Array(repeating: 0,     count: count)
        videoH        = Array(repeating: 0,     count: count)
        lastFrameTime = Array(repeating: 0,     count: count)

        setupScrollView()
        setupControls()
        updateColsRows()

        // Avvia ogni stream indipendentemente; la griglia si aggiorna cam per cam
        for i in 0..<count { startWhep(url: streamUrls[i], idx: i) }
        buildGrid()

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)

        startWatchdog()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self = self else { return }
            self.updateColsRows()
            self.buildGrid()
        }
    }

    // MARK: - Setup

    private func setupScrollView() {
        scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        contentView = UIView()
        contentView.backgroundColor = .black
        scrollView.addSubview(contentView)
    }

    private func setupControls() {
        closeButton = makeControlButton("✕  Chiudi")
        closeButton.addTarget(self, action: #selector(closeAll), for: .touchUpInside)
        closeButton.isHidden = true
        view.addSubview(closeButton)

        streamsButton = makeControlButton(streamsBtnLabel())
        streamsButton.addTarget(self, action: #selector(showStreamsDialog), for: .touchUpInside)
        streamsButton.isHidden = true
        view.addSubview(streamsButton)
    }

    private func makeControlButton(_ title: String) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseForegroundColor = .white
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.8)
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 24)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs; a.font = .systemFont(ofSize: 18, weight: .medium); return a
        }
        let btn = UIButton(configuration: config)
        btn.layer.cornerRadius = 8
        return btn
    }

    // MARK: - Track attachment (lazy, chiamato quando la connessione è pronta)

    /// Crea renderer+wrapper per una cam al primo aggancio, oppure riusa il wrapper esistente per restart.
    /// Deve essere chiamato sul main thread.
    fileprivate func attachTrack(_ track: RTCVideoTrack, idx: Int) {
        assert(Thread.isMainThread)
        guard enabled[idx], !failed[idx] else { return }
        guard videoTracks[idx] == nil else { return }

        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFit
        rendererViews[idx] = renderer

        if wrapperViews[idx] == nil {
            // Prima connessione: crea wrapper e aggiunge alla griglia
            let wrapper = UIView()
            wrapper.backgroundColor = .black
            wrapperViews[idx] = wrapper
            addRendererToWrapper(renderer, wrapper: wrapper)
            updateColsRows()
            buildGridSync()
        } else {
            // Restart: riusa wrapper esistente, sostituisce il renderer
            let wrapper = wrapperViews[idx]!
            wrapper.subviews.forEach { $0.removeFromSuperview() }
            addRendererToWrapper(renderer, wrapper: wrapper)
        }

        videoTracks[idx] = track
        let sink = FrameSink(idx: idx, vc: self)
        frameSinks[idx] = sink
        track.add(sink)
        track.add(renderer)
        track.isEnabled = true
        glog("Cam \(idx): track attaccata, renderer aggiunto alla griglia")
    }

    private func addRendererToWrapper(_ renderer: RTCMTLVideoView, wrapper: UIView) {
        wrapper.addSubview(renderer)
        renderer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            renderer.topAnchor.constraint(equalTo: wrapper.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            renderer.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
    }

    // MARK: - WHEP signaling

    fileprivate func startWhep(url: String, idx: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for attempt in 1...self.maxRetries {
                guard self.enabled[idx], !self.failed[idx] else { return }
                glog("Cam \(idx): WHEP tentativo \(attempt)")
                if self.doWhep(url: url, idx: idx) { return }
                if attempt < self.maxRetries { Thread.sleep(forTimeInterval: 3) }
            }
            glog("Cam \(idx): tutti tentativi WHEP esauriti -> HLS")
            self.switchToHls(idx: idx)
        }
    }

    private func doWhep(url: String, idx: Int) -> Bool {
        guard enabled[idx], !failed[idx] else { return true }

        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let delegate = WhepDelegate(idx: idx, vc: self)
        delegates[idx] = delegate
        guard let pc = Self.factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: delegate
        ) else { return false }

        let vt = RTCRtpTransceiverInit(); vt.direction = .recvOnly
        pc.addTransceiver(of: .video, init: vt)

        let sem1 = DispatchSemaphore(value: 0)
        var offerSdp: RTCSessionDescription?
        pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, _ in
            offerSdp = sdp; sem1.signal()
        }
        sem1.wait()
        guard let offer = offerSdp else { pc.close(); return false }

        let sem2 = DispatchSemaphore(value: 0)
        pc.setLocalDescription(offer) { _ in sem2.signal() }
        sem2.wait()

        guard let whepURL = URL(string: url) else { pc.close(); return false }
        var req = URLRequest(url: whepURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.httpBody = offer.sdp.data(using: .utf8)

        let sem3 = DispatchSemaphore(value: 0)
        var answerSdp: String?
        var statusCode = 0
        URLSession.shared.dataTask(with: req) { data, response, _ in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let d = data { answerSdp = String(data: d, encoding: .utf8) }
            sem3.signal()
        }.resume()
        sem3.wait()

        guard (statusCode == 200 || statusCode == 201), let sdp = answerSdp else {
            glog("Cam \(idx): WHEP HTTP \(statusCode)")
            pc.close(); return false
        }

        let sem4 = DispatchSemaphore(value: 0)
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in sem4.signal() }
        sem4.wait()

        // Aggancia track sul main thread; il delegate può farlo prima via .connected
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.enabled[idx], !self.failed[idx] else { return }
            for transceiver in pc.transceivers where transceiver.mediaType == .video {
                if let track = transceiver.receiver.track as? RTCVideoTrack {
                    self.attachTrack(track, idx: idx)
                }
            }
        }

        peerConnections[idx] = pc
        glog("Cam \(idx): WHEP OK")
        return true
    }

    // MARK: - Fallback HLS

    fileprivate func switchToHls(idx: Int) {
        guard enabled[idx], !failed[idx] else { return }
        glog("Cam \(idx): switch a HLS")
        peerConnections[idx]?.close()
        peerConnections[idx] = nil
        rendererViews[idx] = nil
        frameSinks[idx] = nil
        videoTracks[idx] = nil
        isHlsFallback[idx] = true

        let hlsUrl = streamUrls[idx]
        guard let url = URL(string: hlsUrl) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.enabled[idx], !self.failed[idx] else { return }
            let wrapper = UIView()
            wrapper.backgroundColor = .black
            self.setupHlsPlayer(idx: idx, url: url, wrapper: wrapper)
            self.wrapperViews[idx] = wrapper
            self.updateColsRows()
            self.buildGridSync()
        }
    }

    private func setupHlsPlayer(idx: Int, url: URL, wrapper: UIView) {
        // Rimuovi layer precedente se presente (retry)
        avLayers[idx]?.removeFromSuperlayer()
        avKVOTokens[idx] = nil
        if let obs = avObservers[idx] { NotificationCenter.default.removeObserver(obs) }
        avPlayers[idx]?.pause()

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        avPlayers[idx] = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        avLayers[idx] = layer
        wrapper.layer.addSublayer(layer)

        // Observer fine stream → riavvia
        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak player] _ in
            guard let self = self, self.enabled[idx], !self.failed[idx], let p = player else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.enabled[idx], !self.failed[idx] else { return }
                p.seek(to: .zero); p.play()
            }
        }
        avObservers[idx] = obs

        // KVO su status per rilevare errori HLS
        avKVOTokens[idx] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .failed {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.enabled[idx], !self.failed[idx] else { return }
                    self.hlsFailCount[idx] += 1
                    glog("Cam \(idx): HLS errore \(self.hlsFailCount[idx])/\(self.maxHlsFails)")
                    if self.hlsFailCount[idx] >= self.maxHlsFails {
                        self.markFailed(idx: idx)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            guard let self = self, self.enabled[idx], !self.failed[idx],
                                  let wrapper = self.wrapperViews[idx] else { return }
                            self.setupHlsPlayer(idx: idx, url: url, wrapper: wrapper)
                        }
                    }
                }
            }
        }

        player.play()
    }

    /// Marca una cam come definitivamente irraggiungibile e la rimuove dalla griglia.
    fileprivate func markFailed(idx: Int) {
        guard enabled[idx], !failed[idx] else { return }
        glog("Cam \(idx): \(streamNames[idx]) fallita definitivamente")
        failed[idx] = true
        avKVOTokens[idx] = nil
        if let obs = avObservers[idx] { NotificationCenter.default.removeObserver(obs) }
        avObservers[idx] = nil
        avPlayers[idx]?.pause(); avPlayers[idx] = nil
        avLayers[idx]?.removeFromSuperlayer(); avLayers[idx] = nil
        isHlsFallback[idx] = false
        peerConnections[idx]?.close(); peerConnections[idx] = nil
        delegates[idx] = nil
        frameSinks[idx] = nil
        videoTracks[idx] = nil
        rendererViews[idx] = nil
        wrapperViews[idx]?.removeFromSuperview(); wrapperViews[idx] = nil
        updateColsRows()
        buildGridSync()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.streamsButton.setTitle(self.streamsBtnLabel(), for: .normal)
            self.streamsButton.sizeToFit()
        }
    }

    fileprivate func onFrame(idx: Int, width: Int, height: Int) {
        lastFrameTime[idx] = Date().timeIntervalSince1970
        if videoW[idx] == 0 { videoW[idx] = width; videoH[idx] = height }
    }

    // MARK: - Layout

    private func updateColsRows() {
        let active = (0..<enabled.count).filter { enabled[$0] && !failed[$0] }.count
        if active == 0 { cols = 1; rows = 1; return }
        let isPortrait = view.bounds.height > view.bounds.width
        cols = isPortrait ? 1 : (active == 1 ? 1 : active <= 4 ? 2 : 3)
        rows = Int(ceil(Double(active) / Double(cols)))
    }

    fileprivate func buildGrid() {
        DispatchQueue.main.async { [weak self] in
            self?.buildGridSync()
        }
    }

    private func buildGridSync() {
        assert(Thread.isMainThread)
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let screenW = view.bounds.width
        let cellW = screenW / CGFloat(max(cols, 1))
        let cellH = cellW * 9.0 / 16.0

        let active = (0..<streamUrls.count).filter {
            enabled[$0] && !failed[$0] && wrapperViews[$0] != nil
        }

        var pos = 0; var yOffset: CGFloat = 0
        for _ in 0..<rows {
            var xOffset: CGFloat = 0
            for _ in 0..<cols {
                guard pos < active.count else { break }
                let si = active[pos]; pos += 1
                let wrapper = wrapperViews[si]!
                wrapper.frame = CGRect(x: xOffset, y: yOffset, width: cellW, height: cellH)
                contentView.addSubview(wrapper)
                if isHlsFallback[si] { avLayers[si]?.frame = wrapper.bounds }
                xOffset += cellW
            }
            yOffset += cellH
        }

        let totalH = max(CGFloat(rows) * cellH, 1)
        contentView.frame = CGRect(x: 0, y: 0, width: screenW, height: totalH)
        scrollView.contentSize = CGSize(width: screenW, height: totalH)

        closeButton.sizeToFit()
        closeButton.frame.origin = CGPoint(x: screenW - closeButton.frame.width - 16, y: 48)
        streamsButton.sizeToFit()
        streamsButton.frame.origin = CGPoint(x: 16, y: 48)
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(streamsButton)
    }

    // MARK: - Gestione flussi

    @objc private func showStreamsDialog() {
        let menuVC = StreamsMenuViewController()
        menuVC.allCameraNames      = allCameraNames
        menuVC.allCameraThumbnails = allCameraThumbnails
        menuVC.allCameraInfo       = allCameraInfo
        menuVC.activeNames         = streamNames
        menuVC.activeEnabled       = enabled
        menuVC.activeFailed        = failed
        menuVC.activeInfo          = streamNames.indices.map { streamInfo($0) }
        menuVC.onToggle = { [weak self] idx in
            guard let self = self else { return }
            if self.failed[idx] || !self.enabled[idx] { self.enableStream(idx) }
            else { self.disableStream(idx) }
        }
        menuVC.onAddCamera = { [weak self] info in
            self?.addNewStream(info: info)
        }
        menuVC.modalPresentationStyle = .pageSheet
        present(menuVC, animated: true)
    }

    // Aggiunge una cam non ancora aperta: fa la chiamata addcam al server, poi avvia WHEP
    private func addNewStream(info: [String: String]) {
        let name            = info["name"]            ?? ""
        let seriale         = info["seriale"]         ?? ""
        let camId           = info["camId"]           ?? ""
        let viewerClientId  = info["viewerClientId"]  ?? ""
        let streamSessionId = info["streamSessionId"] ?? ""
        guard !seriale.isEmpty, !camId.isEmpty else { return }

        guard let webView = ExoPlayerPlugin.sharedBridge?.webView,
              let webUrl  = webView.url,
              let scheme  = webUrl.scheme,
              let host    = webUrl.host else { return }

        let baseUrl    = "\(scheme)://\(host)"
        let addCamPath = "\(baseUrl)/dashboard/controlroomaddcam/\(seriale)"

        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }
            let cookieHeader = cookies
                .filter { c in
                    let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return host == domain || host.hasSuffix("." + domain)
                }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            let camFeTarget = "camera\(self.streamUrls.count + 1)"
            let bodyStr = [
                "camFeTarget=\(camFeTarget)",
                "camId=\(camId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? camId)",
                "camName=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)",
                "viewerClientId=\(viewerClientId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? viewerClientId)",
                "streamSessionId=\(streamSessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? streamSessionId)",
            ].joined(separator: "&")

            guard let url = URL(string: addCamPath) else { return }
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
            req.httpBody = bodyStr.data(using: .utf8)

            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resp = json["response"] as? [String: Any],
                      let streamUrl = resp["streamUrl"] as? String,
                      !streamUrl.isEmpty, streamUrl != "null" else { return }

                let sessionCamId = resp["streamSessionCamId"] as? String ?? ""
                let whepUrl = streamUrl
                    .replacingOccurrences(of: ":2053/", with: ":2096/")
                    .replacingOccurrences(of: "/index.m3u8", with: "/whep")

                // Tutto sul main thread: aggiornamento pendingCloseJs + array + avvio stream
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    // Aggiorna pendingCloseJs con la pulizia di questa cam (main thread)
                    if !seriale.isEmpty && !sessionCamId.isEmpty {
                        let extra = "fetch('/dashboard/controlroomremovecam/\(seriale)/\(sessionCamId)',{method:'POST',credentials:'same-origin'});"
                        if var js = ExoPlayerPlugin.pendingCloseJs {
                            js = js.replacingOccurrences(of: "})();", with: extra + "})();")
                            ExoPlayerPlugin.pendingCloseJs = js
                        }
                    }

                    let idx = self.streamUrls.count
                    self.streamUrls.append(whepUrl)
                    self.streamNames.append(name)
                    self.enabled.append(true)
                    self.failed.append(false)
                    self.peerConnections.append(nil)
                    self.delegates.append(nil)
                    self.frameSinks.append(nil)
                    self.videoTracks.append(nil)
                    self.rendererViews.append(nil)
                    self.wrapperViews.append(nil)
                    self.avPlayers.append(nil)
                    self.avLayers.append(nil)
                    self.avObservers.append(nil)
                    self.avKVOTokens.append(nil)
                    self.isHlsFallback.append(false)
                    self.hlsFailCount.append(0)
                    self.videoW.append(0)
                    self.videoH.append(0)
                    self.lastFrameTime.append(0)
                    self.startWhep(url: whepUrl, idx: idx)
                    self.updateColsRows()
                    self.buildGridSync()
                    self.streamsButton.setTitle(self.streamsBtnLabel(), for: .normal)
                    self.streamsButton.sizeToFit()
                    // NON appendere a allCameraNames: la cam è già presente nell'elenco globale
                    // passato da JS (allCameras). Il mapping in StreamsMenuViewController la
                    // troverà come "attiva" perché streamNames ora la contiene.
                }
            }.resume()
        }
    }

    private func streamInfo(_ i: Int) -> String {
        if failed[i] { return "\nfallita — tocca per riprovare" }
        guard enabled[i] else { return "" }
        let proto = isHlsFallback[i] ? "HLS" : "WebRTC"
        if videoW[i] > 0 { return "\n\(videoW[i])×\(videoH[i])  \(proto)" }
        return "\n\(proto) (connessione...)"
    }

    private func enableStream(_ i: Int) {
        guard !enabled[i] || failed[i] else { return }
        enabled[i] = true
        failed[i] = false
        isHlsFallback[i] = false
        hlsFailCount[i] = 0
        videoW[i] = 0; videoH[i] = 0; lastFrameTime[i] = 0
        startWhep(url: streamUrls[i], idx: i)
        updateColsRows()
        buildGrid()
        DispatchQueue.main.async { [weak self] in
            self?.streamsButton.setTitle(self?.streamsBtnLabel() ?? "", for: .normal)
            self?.streamsButton.sizeToFit()
        }
    }

    private func disableStream(_ i: Int) {
        guard enabled[i] || failed[i] else { return }
        enabled[i] = false
        failed[i] = false
        avKVOTokens[i] = nil
        peerConnections[i]?.close(); peerConnections[i] = nil
        delegates[i] = nil
        frameSinks[i] = nil
        videoTracks[i] = nil
        rendererViews[i] = nil
        if let obs = avObservers[i] { NotificationCenter.default.removeObserver(obs) }
        avObservers[i] = nil
        avPlayers[i]?.pause(); avPlayers[i] = nil
        avLayers[i]?.removeFromSuperlayer(); avLayers[i] = nil
        wrapperViews[i]?.removeFromSuperview(); wrapperViews[i] = nil
        isHlsFallback[i] = false
        updateColsRows()
        buildGrid()
        DispatchQueue.main.async { [weak self] in
            self?.streamsButton.setTitle(self?.streamsBtnLabel() ?? "", for: .normal)
            self?.streamsButton.sizeToFit()
        }
    }

    private func streamsBtnLabel() -> String {
        let active = (0..<enabled.count).filter { enabled[$0] && !failed[$0] }.count
        let failedCount = failed.filter { $0 }.count
        var label = "≡  \(active)/\(streamUrls.count) flussi"
        if failedCount > 0 { label += "  ⚠\(failedCount)" }
        return label
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkStreams()
        }
    }

    private func checkStreams() {
        let now = Date().timeIntervalSince1970
        for i in 0..<enabled.count {
            guard enabled[i], !failed[i], !isHlsFallback[i], lastFrameTime[i] > 0,
                  now - lastFrameTime[i] > 10 else { continue }
            glog("Cam \(i): freeze -> restart")
            restartWhep(i)
        }
    }

    fileprivate func restartWhep(_ i: Int) {
        guard enabled[i], !failed[i] else { return }
        peerConnections[i]?.close(); peerConnections[i] = nil
        delegates[i] = nil
        frameSinks[i] = nil
        videoTracks[i] = nil
        rendererViews[i] = nil
        videoW[i] = 0; videoH[i] = 0; lastFrameTime[i] = 0
        // Svuota il wrapper esistente (se presente) ma non lo rimuove dalla griglia
        if let wrapper = wrapperViews[i] {
            wrapper.subviews.forEach { $0.removeFromSuperview() }
        }
        startWhep(url: streamUrls[i], idx: i)
    }

    // MARK: - Actions

    @objc private func handleTap() {
        hideTimer?.invalidate()
        let hidden = closeButton.isHidden
        closeButton.isHidden  = !hidden
        streamsButton.isHidden = !hidden
        if hidden {
            hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.closeButton.isHidden  = true
                self?.streamsButton.isHidden = true
            }
        }
    }

    @objc private func closeAll() {
        ExoPlayerPlugin.executeClose()
        releaseAll()
        dismiss(animated: false)
    }

    // MARK: - Cleanup

    private func releaseAll() {
        hideTimer?.invalidate(); hideTimer = nil
        watchdogTimer?.invalidate(); watchdogTimer = nil
        avKVOTokens.removeAll()
        delegates.removeAll()
        frameSinks.removeAll()
        videoTracks.removeAll()
        for i in 0..<peerConnections.count { peerConnections[i]?.close() }
        for obs in avObservers { if let o = obs { NotificationCenter.default.removeObserver(o) } }
        avPlayers.forEach { $0?.pause() }
        avLayers.forEach { $0?.removeFromSuperlayer() }
        peerConnections.removeAll()
        rendererViews.removeAll()
        wrapperViews.removeAll()
        avPlayers.removeAll()
        avLayers.removeAll()
        avObservers.removeAll()
        enabled.removeAll()
        failed.removeAll()
    }

    deinit { releaseAll() }
}

// MARK: - RTCPeerConnectionDelegate

private class WhepDelegate: NSObject, RTCPeerConnectionDelegate {
    let idx: Int
    weak var vc: CameraMatrixWebRTCViewController?

    init(idx: Int, vc: CameraMatrixWebRTCViewController) {
        self.idx = idx; self.vc = vc
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        glog("Cam \(self.idx): didAdd rtpReceiver video")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.vc?.attachTrack(track, idx: self.idx)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        glog("Cam \(self.idx): connState=\(newState.rawValue)")
        if newState == .failed {
            glog("Cam \(self.idx): failed -> restart in 3s")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, let vc = self.vc,
                      self.idx < vc.enabled.count,
                      vc.enabled[self.idx], !vc.failed[self.idx] else { return }
                vc.restartWhep(self.idx)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        glog("Cam \(self.idx): iceState=\(newState.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Frame tracking

private class FrameSink: NSObject, RTCVideoRenderer {
    let idx: Int
    weak var vc: CameraMatrixWebRTCViewController?

    init(idx: Int, vc: CameraMatrixWebRTCViewController?) {
        self.idx = idx; self.vc = vc
    }

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let f = frame else { return }
        vc?.onFrame(idx: idx, width: Int(f.width), height: Int(f.height))
    }
}

// MARK: - Streams menu (all cameras)

private final class StreamsMenuViewController: UIViewController {
    var allCameraNames:      [String]          = []
    var allCameraThumbnails: [UIImage?]        = []
    var allCameraInfo:       [[String: String]] = []
    var activeNames:         [String]          = []
    var activeEnabled:       [Bool]            = []
    var activeFailed:        [Bool]            = []
    var activeInfo:          [String]          = []
    var onToggle:     ((Int) -> Void)?
    var onAddCamera:  (([String: String]) -> Void)?

    private var activeIndex: [Int] = []   // activeIndex[i] = index in activeNames for allCameraNames[i], or -1
    private var tableView: UITableView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Build mapping: allCameraNames[i] → index in activeNames
        activeIndex = allCameraNames.map { name in
            activeNames.firstIndex(of: name) ?? -1
        }

        tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor    = .black
        tableView.separatorColor     = UIColor.gray.withAlphaComponent(0.3)
        tableView.rowHeight          = 72
        tableView.dataSource         = self
        tableView.delegate           = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
}

extension StreamsMenuViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        allCameraNames.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "smcam")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "smcam")

        let i        = indexPath.row
        let name     = allCameraNames[i]
        let thumb    = i < allCameraThumbnails.count ? allCameraThumbnails[i] : nil
        let aIdx     = activeIndex[i]
        let isActive = aIdx >= 0

        cell.imageView?.image       = thumb ?? UIImage(systemName: "video.slash")
        cell.imageView?.tintColor   = .gray
        cell.imageView?.contentMode = .scaleAspectFill
        cell.imageView?.clipsToBounds = true
        cell.backgroundColor        = .black
        let hasInfo = i < allCameraInfo.count && !(allCameraInfo[i]["seriale"] ?? "").isEmpty
        cell.selectionStyle         = (isActive || hasInfo) ? .default : .none

        if isActive {
            let enabled = aIdx < activeEnabled.count && activeEnabled[aIdx]
            let failed  = aIdx < activeFailed.count  && activeFailed[aIdx]
            let info    = aIdx < activeInfo.count     ? activeInfo[aIdx] : ""
            cell.textLabel?.text        = name
            cell.textLabel?.textColor   = .white
            cell.detailTextLabel?.text  = info.hasPrefix("\n") ? String(info.dropFirst()) : info
            cell.detailTextLabel?.textColor = failed ? .systemRed : .lightGray
            cell.accessoryType          = enabled ? .checkmark : .none
            cell.tintColor              = .white
            cell.contentView.alpha      = 1.0
        } else {
            cell.textLabel?.text        = name
            cell.textLabel?.textColor   = .gray
            cell.detailTextLabel?.text  = "non aperta"
            cell.detailTextLabel?.textColor = .darkGray
            cell.accessoryType          = .none
            cell.contentView.alpha      = 0.6
        }

        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let i    = indexPath.row
        let aIdx = activeIndex[i]
        if aIdx >= 0 {
            dismiss(animated: true) { [weak self] in self?.onToggle?(aIdx) }
        } else if i < allCameraInfo.count {
            let info = allCameraInfo[i]
            dismiss(animated: true) { [weak self] in self?.onAddCamera?(info) }
        }
    }
}
