import UIKit
import AVFoundation
import CapApp_SPM
import Darwin
import os

// MARK: - File logger (leggibile via ifuse/AFC dalla sandbox)

private final class FileLogger {
    static let shared = FileLogger()
    private let queue = DispatchQueue(label: "guardroom.filelog", qos: .utility)
    private var handle: FileHandle?
    private let maxBytes = 2 * 1024 * 1024  // 2 MB poi ruota

    private init() {
        queue.async { self.open() }
    }

    private func logPath() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("guardroom_webrtc.log")
    }

    private func open() {
        let url = logPath()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ msg: String) {
        queue.async {
            guard let h = self.handle else { return }
            // Ruota se troppo grande
            let pos = h.offsetInFile
            if pos > UInt64(self.maxBytes) {
                h.truncateFile(atOffset: 0)
                h.seek(toFileOffset: 0)
            }
            if let data = msg.data(using: .utf8) { h.write(data) }
        }
    }

    /// Percorso del file da mostrare all'utente
    static func logFilePath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("guardroom_webrtc.log").path
    }
}

// Forza os_log su stderr prima che il sistema di logging si inizializzi
private let _oslogSetup: Void = {
    setenv("OS_ACTIVITY_MODE", "disable", 1)
    setenv("OS_LOG_ENABLE_STDERR", "1", 1)
}()

private let _logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.octopusiot.guardroom",
    category: "webrtc"
)

// MARK: - In-app log panel

private final class InAppLogger {
    static let shared = InAppLogger()
    private let queue = DispatchQueue(label: "guardroom.inapplog", qos: .utility)
    private var lines: [String] = []
    private let maxLines = 40
    weak var textView: UITextView?

    func append(_ line: String) {
        queue.async {
            self.lines.append(line)
            if self.lines.count > self.maxLines { self.lines.removeFirst() }
            let text = self.lines.joined()
            DispatchQueue.main.async { self.textView?.text = text }
        }
    }
}

private func glog(_ msg: String) {
    _ = _oslogSetup
    let ts = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 100000))
    let line = "[\(ts)] GUARDROOM \(msg)\n"
    // .info è visibile con: log stream --device --predicate 'subsystem == "com.octopusiot.example"'
    _logger.info("GUARDROOM \(msg, privacy: .public)")
    line.withCString { ptr in _ = write(STDERR_FILENO, ptr, strlen(ptr)) }
    FileLogger.shared.write(line)
    InAppLogger.shared.append(line)
}

class CameraMatrixWebRTCViewController: UIViewController {

    var streamUrls: [String] = []
    var streamNames: [String] = []

    // Stato per ogni stream
    var enabled: [Bool] = []
    private var peerConnections: [RTCPeerConnection?] = []
    private var delegates: [WhepDelegate?] = []
    fileprivate var frameSinks: [FrameSink?] = []
    private var rendererViews: [RTCMTLVideoView?] = []
    private var wrapperViews: [UIView?] = []
    private var statusLabels: [UILabel?] = []
    // 3 righe indipendenti: [0]=rete, [1]=track, [2]=frame
    private var statusLines: [[String]] = []
    // Fallback AVPlayer per H.265 (stesso schema Android)
    private var avPlayers: [AVPlayer?] = []
    private var avLayers: [AVPlayerLayer?] = []
    private var avObservers: [NSObjectProtocol?] = []
    private var isHlsFallback: [Bool] = []

    private var videoW: [Int] = []
    private var videoH: [Int] = []
    private var lastFrameTime: [TimeInterval] = []
    private var frameCount: [Int] = []

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
    private var logPanel: UITextView!
    private var logButton: UIButton!
    private var streamsButton: UIButton!
    private var hideTimer: Timer?
    private var watchdogTimer: Timer?
    private var cols = 1
    private var rows = 1

    private let maxRetries = 4

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let count = streamUrls.count
        enabled         = Array(repeating: true,  count: count)
        peerConnections = Array(repeating: nil,   count: count)
        delegates       = Array(repeating: nil,   count: count)
        frameSinks      = Array(repeating: nil,   count: count)
        rendererViews   = Array(repeating: nil,   count: count)
        wrapperViews    = Array(repeating: nil,   count: count)
        statusLabels    = Array(repeating: nil,   count: count)
        statusLines     = Array(repeating: ["","",""], count: count)
        avPlayers       = Array(repeating: nil,   count: count)
        avLayers        = Array(repeating: nil,   count: count)
        avObservers     = Array(repeating: nil,   count: count)
        isHlsFallback   = Array(repeating: false, count: count)
        videoW          = Array(repeating: 0,     count: count)
        videoH          = Array(repeating: 0,     count: count)
        lastFrameTime   = Array(repeating: 0,     count: count)
        frameCount      = Array(repeating: 0,     count: count)

        setupScrollView()
        setupControls()
        setupLogPanel()
        updateColsRows()

        for i in 0..<count { createWebRTCSlot(at: i) }
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

    private func setupLogPanel() {
        logPanel = UITextView()
        logPanel.backgroundColor = UIColor.black.withAlphaComponent(0.85)
        logPanel.textColor = .green
        logPanel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logPanel.isEditable = false
        logPanel.isHidden = true
        logPanel.layer.cornerRadius = 8
        view.addSubview(logPanel)
        InAppLogger.shared.textView = logPanel

        var cfg = UIButton.Configuration.filled()
        cfg.title = "LOG"
        cfg.baseForegroundColor = .white
        cfg.baseBackgroundColor = UIColor.darkGray.withAlphaComponent(0.9)
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        logButton = UIButton(configuration: cfg)
        logButton.layer.cornerRadius = 6
        logButton.addTarget(self, action: #selector(toggleLog), for: .touchUpInside)
        view.addSubview(logButton)
    }

    @objc private func toggleLog() {
        logPanel.isHidden = !logPanel.isHidden
        if !logPanel.isHidden {
            let b = view.bounds.insetBy(dx: 12, dy: 80)
            logPanel.frame = CGRect(x: b.minX, y: b.minY + 44, width: b.width, height: b.height * 0.6)
            // scroll in fondo
            let bottom = max(logPanel.contentSize.height - logPanel.bounds.height, 0)
            logPanel.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
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

    // MARK: - WebRTC slot

    private func createWebRTCSlot(at i: Int) {
        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFit
        rendererViews[i] = renderer

        let label = UILabel()
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .yellow
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.numberOfLines = 0
        label.text = "[\(i)] avvio..."
        statusLabels[i] = label

        let wrapper = UIView()
        wrapper.backgroundColor = .black
        wrapper.addSubview(renderer)
        wrapper.addSubview(label)
        renderer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            renderer.topAnchor.constraint(equalTo: wrapper.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            renderer.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -4),
        ])
        wrapperViews[i] = wrapper

        startWhep(url: streamUrls[i], idx: i)
    }

    // row: 0=rete, 1=track, 2=frame
    fileprivate func updateStatus(_ i: Int, row: Int = 0, _ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusLines[i][row] = text
            let body = self.statusLines[i].filter { !$0.isEmpty }.joined(separator: "\n")
            self.statusLabels[i]?.text = "[\(i)]\n\(body)"
        }
    }

    // MARK: - WHEP signaling

    fileprivate func startWhep(url: String, idx: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for attempt in 1...self.maxRetries {
                guard self.enabled[idx] else { return }
                self.updateStatus(idx, row: 0, "WHEP tentativo \(attempt)")
                glog("Cam \(idx): WHEP tentativo \(attempt)")
                if self.doWhep(url: url, idx: idx) { return }
                if attempt < self.maxRetries { Thread.sleep(forTimeInterval: 3) }
            }
            glog("Cam \(idx): tutti tentativi WHEP esauriti -> HLS")
            self.updateStatus(idx, row: 0, "WHEP fallito -> HLS")
            self.switchToHls(idx: idx)
        }
    }

    private func doWhep(url: String, idx: Int) -> Bool {
        guard enabled[idx], let renderer = rendererViews[idx] else { return true }

        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require

        let delegate = WhepDelegate(idx: idx, vc: self, renderer: renderer)
        delegates[idx] = delegate
        guard let pc = Self.factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: delegate
        ) else { return false }

        let vt = RTCRtpTransceiverInit(); vt.direction = .recvOnly
        let at = RTCRtpTransceiverInit(); at.direction = .recvOnly
        pc.addTransceiver(of: .video, init: vt)
        pc.addTransceiver(of: .audio, init: at)

        // Offerta SDP
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

        // POST al WHEP endpoint
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
            glog("Cam \(idx): WHEP risposta HTTP \(statusCode)")
            updateStatus(idx, row: 0, "HTTP \(statusCode)")
            pc.close(); return false
        }

        // Estrai codec video dall'SDP answer per debug
        let codec = sdp.components(separatedBy: "\n")
            .first(where: { $0.contains("a=rtpmap") && (
                $0.lowercased().contains("h264") ||
                $0.lowercased().contains("h265") ||
                $0.lowercased().contains("hevc") ||
                $0.lowercased().contains("vp8") ||
                $0.lowercased().contains("vp9") ||
                $0.lowercased().contains("av1")
            )})?.trimmingCharacters(in: .whitespaces) ?? "codec?"
        glog("Cam \(idx): codec SDP answer: \(codec)")
        updateStatus(idx, row: 0, "SDP:\(codec)")

        let sem4 = DispatchSemaphore(value: 0)
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in sem4.signal() }
        sem4.wait()

        // Collega renderer direttamente dal transceiver (bypass callback)
        let capturedRenderer = renderer
        DispatchQueue.main.async {
            let transceivers = pc.transceivers
            glog("Cam \(idx): \(transceivers.count) transceivers dopo setRemote")
            var foundVideoTrack = false
            for transceiver in transceivers {
                if transceiver.mediaType == .video {
                    let rawTrack = transceiver.receiver.track
                    glog("Cam \(idx): video track = \(rawTrack != nil ? "OK" : "NIL")")
                    if let track = rawTrack as? RTCVideoTrack {
                        foundVideoTrack = true
                        let sink = FrameSink(idx: idx, vc: self)
                        self.frameSinks[idx] = sink
                        track.add(sink)
                        track.add(capturedRenderer)
                        track.isEnabled = true
                        self.updateStatus(idx, row: 1, "track OK (transceiver)")
                        glog("Cam \(idx): sink+renderer attaccati via transceiver")
                    } else {
                        self.updateStatus(idx, row: 1, "track NIL dopo setRemote!")
                        glog("Cam \(idx): ERRORE track NIL dopo setRemoteDescription")
                    }
                }
            }
            if !foundVideoTrack {
                self.updateStatus(idx, row: 1, "nessun video transceiver!")
                glog("Cam \(idx): ERRORE nessun video transceiver trovato")
            }
        }

        peerConnections[idx] = pc
        glog("Cam \(idx): WHEP connesso OK")
        return true
    }

    // MARK: - Fallback HLS (H.265 non supportato da WebRTC o errore)

    fileprivate func switchToHls(idx: Int) {
        guard enabled[idx] else { return }
        glog("Cam \(idx): switch a AVPlayer HLS")
        peerConnections[idx]?.close()
        peerConnections[idx] = nil
        rendererViews[idx] = nil
        frameSinks[idx] = nil
        isHlsFallback[idx] = true

        let hlsUrl = streamUrls[idx]
        guard let url = URL(string: hlsUrl) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let wrapper = UIView()
            wrapper.backgroundColor = .black

            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            self.avPlayers[idx] = player

            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            self.avLayers[idx] = layer
            wrapper.layer.addSublayer(layer)

            let obs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, weak player] _ in
                guard let self = self, self.enabled[idx], let p = player else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self = self, self.enabled[idx] else { return }
                    p.seek(to: .zero); p.play()
                }
            }
            self.avObservers[idx] = obs
            player.play()
            self.wrapperViews[idx] = wrapper
            self.buildGrid()
        }
    }

    // Chiamato dal delegate ad ogni frame WebRTC
    fileprivate func onFrame(idx: Int, width: Int, height: Int) {
        lastFrameTime[idx] = Date().timeIntervalSince1970
        frameCount[idx] += 1
        if videoW[idx] == 0 { videoW[idx] = width; videoH[idx] = height }
        if frameCount[idx] == 1 || frameCount[idx] % 30 == 0 {
            updateStatus(idx, row: 2, "frames:\(frameCount[idx]) \(width)x\(height)")
        }
    }

    // MARK: - Layout

    private func updateColsRows() {
        let active = enabled.filter { $0 }.count
        if active == 0 { cols = 1; rows = 1; return }
        let isPortrait = view.bounds.height > view.bounds.width
        cols = isPortrait ? 1 : (active == 1 ? 1 : active <= 4 ? 2 : 3)
        rows = Int(ceil(Double(active) / Double(cols)))
    }

    fileprivate func buildGrid() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.contentView.subviews.forEach { $0.removeFromSuperview() }

            let screenW = self.view.bounds.width
            let cellW = screenW / CGFloat(max(self.cols, 1))
            let cellH = cellW * 9.0 / 16.0

            let active = (0..<self.streamUrls.count).filter {
                self.enabled[$0] && self.wrapperViews[$0] != nil
            }
            glog("buildGrid: \(active.count) attivi, griglia \(self.cols)x\(self.rows)")

            var pos = 0; var yOffset: CGFloat = 0
            for _ in 0..<self.rows {
                var xOffset: CGFloat = 0
                for _ in 0..<self.cols {
                    guard pos < active.count else { break }
                    let si = active[pos]; pos += 1
                    let wrapper = self.wrapperViews[si]!
                    wrapper.frame = CGRect(x: xOffset, y: yOffset, width: cellW, height: cellH)
                    self.contentView.addSubview(wrapper)
                    if self.isHlsFallback[si] { self.avLayers[si]?.frame = wrapper.bounds }
                    xOffset += cellW
                }
                yOffset += cellH
            }

            let totalH = max(CGFloat(self.rows) * cellH, 1)
            self.contentView.frame = CGRect(x: 0, y: 0, width: screenW, height: totalH)
            self.scrollView.contentSize = CGSize(width: screenW, height: totalH)

            self.closeButton.sizeToFit()
            self.closeButton.frame.origin = CGPoint(x: screenW - self.closeButton.frame.width - 16, y: 48)
            self.streamsButton.sizeToFit()
            self.streamsButton.frame.origin = CGPoint(x: 16, y: 48)
            self.view.bringSubviewToFront(self.closeButton)
            self.view.bringSubviewToFront(self.streamsButton)
            // logButton: angolo in basso a destra
            self.logButton.sizeToFit()
            self.logButton.frame.origin = CGPoint(
                x: screenW - self.logButton.frame.width - 16,
                y: self.view.bounds.height - self.logButton.frame.height - 40
            )
            self.view.bringSubviewToFront(self.logButton)
            self.view.bringSubviewToFront(self.logPanel)
        }
    }

    // MARK: - Gestione flussi

    @objc private func showStreamsDialog() {
        let alert = UIAlertController(title: "Flussi", message: nil, preferredStyle: .actionSheet)
        for (i, name) in streamNames.enumerated() {
            let mark = enabled[i] ? "✓ " : "○ "
            alert.addAction(UIAlertAction(title: mark + name + streamInfo(i), style: .default) { [weak self] _ in
                guard let self = self else { return }
                if self.enabled[i] { self.disableStream(i) } else { self.enableStream(i) }
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = streamsButton; pop.sourceRect = streamsButton.bounds
        }
        present(alert, animated: true)
    }

    private func streamInfo(_ i: Int) -> String {
        guard enabled[i] else { return "" }
        let proto = isHlsFallback[i] ? "HLS" : "WebRTC"
        if videoW[i] > 0 { return "\n\(videoW[i])×\(videoH[i])  \(proto)" }
        return "\n\(proto)"
    }

    private func enableStream(_ i: Int) {
        guard !enabled[i] else { return }
        enabled[i] = true; isHlsFallback[i] = false
        videoW[i] = 0; videoH[i] = 0; lastFrameTime[i] = 0; frameCount[i] = 0
        createWebRTCSlot(at: i)
        updateColsRows()
        buildGrid()
        DispatchQueue.main.async { [weak self] in
            self?.streamsButton.setTitle(self?.streamsBtnLabel() ?? "", for: .normal)
            self?.streamsButton.sizeToFit()
        }
    }

    private func disableStream(_ i: Int) {
        guard enabled[i] else { return }
        enabled[i] = false
        peerConnections[i]?.close(); peerConnections[i] = nil
        delegates[i] = nil
        frameSinks[i] = nil
        rendererViews[i] = nil
        statusLabels[i] = nil
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
        let active = enabled.filter { $0 }.count
        return "≡  \(active)/\(streamUrls.count) flussi"
    }

    // MARK: - Watchdog (freeze detection)

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkStreams()
        }
    }

    private func checkStreams() {
        let now = Date().timeIntervalSince1970
        for i in 0..<enabled.count {
            guard enabled[i], !isHlsFallback[i], lastFrameTime[i] > 0,
                  now - lastFrameTime[i] > 10 else { continue }
            glog("Cam \(i): freeze -> restart WebRTC")
            restartWhep(i)
        }
    }

    fileprivate func restartWhep(_ i: Int) {
        guard enabled[i] else { return }
        peerConnections[i]?.close(); peerConnections[i] = nil
        delegates[i] = nil
        frameSinks[i] = nil
        videoW[i] = 0; videoH[i] = 0; lastFrameTime[i] = 0; frameCount[i] = 0

        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFit
        rendererViews[i] = renderer

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wrapper = self.wrapperViews[i] else { return }
            wrapper.subviews.forEach { $0.removeFromSuperview() }
            wrapper.addSubview(renderer)
            renderer.frame = wrapper.bounds
            renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if let label = self.statusLabels[i] { wrapper.addSubview(label) }
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
        InAppLogger.shared.textView = nil
        // Azzera i delegate PRIMA di chiudere le PC:
        // evita che i callback post-close accedano ad array già svuotati
        delegates.removeAll()
        frameSinks.removeAll()
        for i in 0..<peerConnections.count { peerConnections[i]?.close() }
        for obs in avObservers { if let o = obs { NotificationCenter.default.removeObserver(o) } }
        avPlayers.forEach { $0?.pause() }
        avLayers.forEach { $0?.removeFromSuperlayer() }
        peerConnections.removeAll()
        rendererViews.removeAll()
        wrapperViews.removeAll()
        statusLabels.removeAll()
        avPlayers.removeAll()
        avLayers.removeAll()
        avObservers.removeAll()
        enabled.removeAll()
    }

    deinit { releaseAll() }
}

// MARK: - H.265 decoder factory

private class H265VideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()

    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        if info.name == "H265" {
            return RTCVideoDecoderH265()
        }
        return base.createDecoder(info)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        var codecs = base.supportedCodecs()
        if !codecs.contains(where: { $0.name == "H265" }) {
            codecs.insert(RTCVideoCodecInfo(name: "H265"), at: 0)
        }
        return codecs
    }
}

// MARK: - RTCPeerConnectionDelegate

private class WhepDelegate: NSObject, RTCPeerConnectionDelegate {
    let idx: Int
    weak var vc: CameraMatrixWebRTCViewController?
    let renderer: RTCMTLVideoView

    init(idx: Int, vc: CameraMatrixWebRTCViewController, renderer: RTCMTLVideoView) {
        self.idx = idx; self.vc = vc; self.renderer = renderer
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didAdd rtpReceiver: RTCRtpReceiver,
                        streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        glog("Cam \(self.idx): VideoTrack ricevuta via didAdd rtpReceiver")
        vc?.updateStatus(idx, row: 1, "rtpReceiver fired OK")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sink = FrameSink(idx: self.idx, vc: self.vc)
            self.vc?.frameSinks[self.idx] = sink
            track.add(sink)
            track.add(self.renderer)
            track.isEnabled = true
            self.vc?.updateStatus(self.idx, row: 1, "rtpReceiver+sink OK")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        glog("Cam \(self.idx): connectionState=\(newState.rawValue)")
        vc?.updateStatus(idx, row: 0, "conn=\(newState.rawValue)")
        if newState == .connected {
            // Riattacca sink+renderer su .connected (DTLS pronto)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let vc = self.vc else { return }
                for transceiver in peerConnection.transceivers {
                    if transceiver.mediaType == .video,
                       let track = transceiver.receiver.track as? RTCVideoTrack {
                        glog("Cam \(self.idx): riattacco sink+renderer su .connected")
                        let sink = FrameSink(idx: self.idx, vc: vc)
                        vc.frameSinks[self.idx] = sink
                        track.add(sink)
                        track.add(self.renderer)
                        track.isEnabled = true
                        vc.updateStatus(self.idx, row: 1, "sink+rend su connected")
                    }
                }
            }
            // Controlla stats decoder dopo 3s
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self else { return }
                peerConnection.statistics { report in
                    for (_, stats) in report.statistics {
                        if stats.type == "inbound-rtp",
                           let kind = stats.values["kind"] as? String, kind == "video" {
                            let bytes   = stats.values["bytesReceived"]   as? UInt64 ?? 0
                            let packets = stats.values["packetsReceived"] as? UInt32 ?? 0
                            let framesRx  = stats.values["framesReceived"]  as? UInt32 ?? 9999
                            let framesDec = stats.values["framesDecoded"]   as? UInt32 ?? 9999
                            let lost      = stats.values["packetsLost"]     as? Int32  ?? 0
                            let msg = "\(bytes)B \(packets)pkt lost:\(lost) framesRx:\(framesRx) dec:\(framesDec)"
                            glog("Cam \(self.idx): stats \(msg)")
                            self.vc?.updateStatus(self.idx, row: 0, "stats:\(msg)")
                        }
                    }
                }
            }
        }
        if newState == .failed {
            glog("Cam \(self.idx): connessione fallita -> restart in 3s")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, let vc = self.vc,
                      self.idx < vc.enabled.count, vc.enabled[self.idx] else { return }
                vc.restartWhep(self.idx)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DispatchQueue.main.async {
            for track in stream.videoTracks {
                glog("Cam \(self.idx): VideoTrack via didAdd stream")
                self.vc?.updateStatus(self.idx, row: 1, "stream track OK")
                track.add(self.renderer)
                track.isEnabled = true
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        glog("Cam \(self.idx): iceState=\(newState.rawValue)")
        vc?.updateStatus(idx, row: 0, "ICE=\(newState.rawValue)")
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
