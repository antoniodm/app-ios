import UIKit
import AVFoundation
import CapApp_SPM
import Darwin

private func glog(_ msg: String) {
    let line = "GUARDROOM \(msg)\n"
    line.withCString { ptr in _ = write(STDERR_FILENO, ptr, strlen(ptr)) }
}

class CameraMatrixWebRTCViewController: UIViewController {

    var streamUrls: [String] = []
    var streamNames: [String] = []

    // Stato per ogni stream
    var enabled: [Bool] = []
    private var peerConnections: [RTCPeerConnection?] = []
    private var delegates: [WhepDelegate?] = []
    private var rendererViews: [RTCMTLVideoView?] = []
    private var wrapperViews: [UIView?] = []
    // Fallback AVPlayer per H.265 (stesso schema Android)
    private var avPlayers: [AVPlayer?] = []
    private var avLayers: [AVPlayerLayer?] = []
    private var avObservers: [NSObjectProtocol?] = []
    private var isHlsFallback: [Bool] = []

    private var videoW: [Int] = []
    private var videoH: [Int] = []
    private var lastFrameTime: [TimeInterval] = []

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: H265VideoDecoderFactory()
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
        rendererViews   = Array(repeating: nil,   count: count)
        wrapperViews    = Array(repeating: nil,   count: count)
        avPlayers       = Array(repeating: nil,   count: count)
        avLayers        = Array(repeating: nil,   count: count)
        avObservers     = Array(repeating: nil,   count: count)
        isHlsFallback   = Array(repeating: false, count: count)
        videoW          = Array(repeating: 0,     count: count)
        videoH          = Array(repeating: 0,     count: count)
        lastFrameTime   = Array(repeating: 0,     count: count)

        setupScrollView()
        setupControls()
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

    private func makeControlButton(_ title: String) -> UIButton {
        let btn = UIButton(type: .custom)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
        btn.setTitleColor(.white, for: .normal)
        btn.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        btn.layer.cornerRadius = 8
        btn.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        return btn
    }

    // MARK: - WebRTC slot

    private func createWebRTCSlot(at i: Int) {
        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFit
        rendererViews[i] = renderer

        let wrapper = UIView()
        wrapper.backgroundColor = .black
        wrapper.addSubview(renderer)
        renderer.frame = wrapper.bounds
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        wrapperViews[i] = wrapper

        startWhep(url: streamUrls[i], idx: i)
    }

    // MARK: - WHEP signaling

    fileprivate func startWhep(url: String, idx: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for attempt in 1...self.maxRetries {
                guard self.enabled[idx] else { return }
                glog("Cam \(idx): WHEP tentativo \(attempt)")
                if self.doWhep(url: url, idx: idx) { return }
                if attempt < self.maxRetries { Thread.sleep(forTimeInterval: 3) }
            }
            glog("Cam \(idx): tutti tentativi WHEP esauriti -> HLS")
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
            pc.close(); return false
        }

        let sem4 = DispatchSemaphore(value: 0)
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { _ in sem4.signal() }
        sem4.wait()

        // Collega renderer direttamente dal transceiver (bypass callback)
        let capturedRenderer = renderer
        DispatchQueue.main.async {
            for transceiver in pc.transceivers {
                if transceiver.mediaType == .video,
                   let track = transceiver.receiver.track as? RTCVideoTrack {
                    glog("Cam \(idx): attacco renderer via transceiver")
                    track.add(capturedRenderer)
                    track.isEnabled = true
                }
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
        if videoW[idx] == 0 { videoW[idx] = width; videoH[idx] = height }
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
        videoW[i] = 0; videoH[i] = 0; lastFrameTime[i] = 0
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
        videoW[i] = 0; videoH[i] = 0; lastFrameTime[i] = 0

        let renderer = RTCMTLVideoView(frame: .zero)
        renderer.videoContentMode = .scaleAspectFit
        rendererViews[i] = renderer

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let wrapper = self.wrapperViews[i] else { return }
            wrapper.subviews.forEach { $0.removeFromSuperview() }
            wrapper.addSubview(renderer)
            renderer.frame = wrapper.bounds
            renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
        for i in 0..<peerConnections.count { peerConnections[i]?.close() }
        for obs in avObservers { if let o = obs { NotificationCenter.default.removeObserver(o) } }
        avPlayers.forEach { $0?.pause() }
        avLayers.forEach { $0?.removeFromSuperlayer() }
        peerConnections.removeAll()
        delegates.removeAll()
        rendererViews.removeAll()
        wrapperViews.removeAll()
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
        glog("Cam \(self.idx): VideoTrack ricevuta")
        let sink = FrameSink(idx: self.idx, vc: vc)
        track.add(sink)
        DispatchQueue.main.async { track.add(self.renderer) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection,
                        didChange newState: RTCPeerConnectionState) {
        glog("Cam \(self.idx): connectionState=\(newState.rawValue)")
        if newState == .failed {
            glog("Cam \(self.idx): connessione fallita -> restart in 3s")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, let vc = self.vc, vc.enabled[self.idx] else { return }
                vc.restartWhep(self.idx)
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        DispatchQueue.main.async {
            for track in stream.videoTracks {
                glog("Cam \(self.idx): VideoTrack via didAdd stream")
                track.add(self.renderer)
                track.isEnabled = true
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
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
