import UIKit
import AVFoundation
import os

private func glog(_ msg: String) {
    os_log("GUARDROOM %{public}@", type: .fault, msg)
}

class CameraMatrixViewController: UIViewController {

    var streamUrls: [String] = []
    var streamNames: [String] = []

    // Stato per ogni stream
    private var enabled: [Bool] = []
    private var players: [AVPlayer?] = []
    private var playerLayers: [AVPlayerLayer?] = []
    private var playerViews: [UIView?] = []
    private var endObservers: [NSObjectProtocol?] = []

    private var scrollView: UIScrollView!
    private var contentView: UIView!
    private var closeButton: UIButton!
    private var streamsButton: UIButton!
    private var hideTimer: Timer?
    private var watchdogTimer: Timer?

    private var cols = 1
    private var rows = 1

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let count = streamUrls.count
        enabled      = Array(repeating: true, count: count)
        players      = Array(repeating: nil,  count: count)
        playerLayers = Array(repeating: nil,  count: count)
        playerViews  = Array(repeating: nil,  count: count)
        endObservers = Array(repeating: nil,  count: count)

        setupScrollView()
        setupControls()
        updateColsRows()
        for i in 0..<count { createPlayer(at: i) }
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

    private func createPlayer(at i: Int) {
        guard let url = URL(string: streamUrls[i]) else { return }

        let item   = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        players[i]      = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        playerLayers[i] = layer

        let container = UIView()
        container.backgroundColor = .black
        container.layer.addSublayer(layer)
        playerViews[i] = container

        // Auto-reconnect quando il flusso termina
        let obs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.enabled[i] else { return }
            glog("Cam \(i): ENDED → riconnessione in 2s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self = self, self.enabled[i], let p = self.players[i] else { return }
                p.seek(to: .zero)
                p.play()
            }
        }
        endObservers[i] = obs

        player.play()
        glog("Cam \(i): avvio → \(streamUrls[i])")
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

    // MARK: - Layout

    private func updateColsRows() {
        let active = enabled.filter { $0 }.count
        if active == 0 { cols = 1; rows = 1; return }
        let isPortrait = view.bounds.height > view.bounds.width
        cols = isPortrait ? 1 : (active == 1 ? 1 : active <= 4 ? 2 : 3)
        rows = Int(ceil(Double(active) / Double(cols)))
    }

    private func buildGrid() {
        contentView.subviews.forEach { $0.removeFromSuperview() }

        let screenW = view.bounds.width
        let cellW   = screenW / CGFloat(max(cols, 1))
        let cellH   = cellW * 9.0 / 16.0

        let active = (0..<streamUrls.count).filter { enabled[$0] && playerViews[$0] != nil }
        glog("buildGrid: \(active.count) stream attivi, griglia \(cols)x\(rows)")

        var pos = 0
        var yOffset: CGFloat = 0
        for _ in 0..<rows {
            var xOffset: CGFloat = 0
            for _ in 0..<cols {
                guard pos < active.count else { break }
                let si = active[pos]; pos += 1

                let container = playerViews[si]!
                container.frame = CGRect(x: xOffset, y: yOffset, width: cellW, height: cellH)
                contentView.addSubview(container)
                playerLayers[si]?.frame = container.bounds

                xOffset += cellW
            }
            yOffset += cellH
        }

        let totalH = max(CGFloat(rows) * cellH, 1)
        contentView.frame = CGRect(x: 0, y: 0, width: screenW, height: totalH)
        scrollView.contentSize = CGSize(width: screenW, height: totalH)

        // Posiziona i controlli sopra lo scroll
        let safeTop: CGFloat = 48
        closeButton.sizeToFit()
        closeButton.frame.origin = CGPoint(x: screenW - closeButton.frame.width - 16, y: safeTop)
        streamsButton.sizeToFit()
        streamsButton.frame.origin = CGPoint(x: 16, y: safeTop)
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(streamsButton)
    }

    // MARK: - Gestione flussi

    @objc private func showStreamsDialog() {
        let alert = UIAlertController(title: "Flussi", message: nil, preferredStyle: .actionSheet)
        for (i, name) in streamNames.enumerated() {
            let mark = enabled[i] ? "✓ " : "○ "
            let info = streamInfo(i)
            alert.addAction(UIAlertAction(title: mark + name + info, style: .default) { [weak self] _ in
                guard let self = self else { return }
                if self.enabled[i] { self.disableStream(i) } else { self.enableStream(i) }
            })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = streamsButton
            pop.sourceRect = streamsButton.bounds
        }
        present(alert, animated: true)
    }

    private func streamInfo(_ i: Int) -> String {
        guard enabled[i], let item = players[i]?.currentItem else { return "" }
        for track in item.tracks {
            guard let asset = track.assetTrack, asset.mediaType == .video else { continue }
            let size = asset.naturalSize.applying(asset.preferredTransform)
            let w = Int(abs(size.width)); let h = Int(abs(size.height))
            if w > 0 && h > 0 { return "\n\(w)×\(h)  HLS" }
        }
        return "\nHLS"
    }

    private func enableStream(_ i: Int) {
        guard !enabled[i] else { return }
        glog("Cam \(i) (\(streamNames[i])): enable")
        enabled[i] = true
        createPlayer(at: i)
        updateColsRows()
        buildGrid()
        streamsButton.setTitle(streamsBtnLabel(), for: .normal)
        streamsButton.sizeToFit()
    }

    private func disableStream(_ i: Int) {
        guard enabled[i] else { return }
        glog("Cam \(i) (\(streamNames[i])): disable")
        enabled[i] = false
        if let obs = endObservers[i] { NotificationCenter.default.removeObserver(obs) }
        endObservers[i] = nil
        players[i]?.pause()
        players[i] = nil
        playerLayers[i]?.removeFromSuperlayer()
        playerLayers[i] = nil
        playerViews[i]?.removeFromSuperview()
        playerViews[i] = nil
        updateColsRows()
        buildGrid()
        streamsButton.setTitle(streamsBtnLabel(), for: .normal)
        streamsButton.sizeToFit()
    }

    private func streamsBtnLabel() -> String {
        let active = enabled.filter { $0 }.count
        return "≡  \(active)/\(streamUrls.count) flussi"
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkStreams()
        }
    }

    private func checkStreams() {
        for i in 0..<players.count {
            guard enabled[i], let player = players[i],
                  let item = player.currentItem, item.status == .failed else { continue }
            glog("Cam \(i): errore AVPlayerItem → riconnessione")
            if let obs = endObservers[i] { NotificationCenter.default.removeObserver(obs) }
            endObservers[i] = nil
            playerLayers[i]?.removeFromSuperlayer()
            playerLayers[i] = nil
            playerViews[i]?.removeFromSuperview()
            playerViews[i] = nil
            players[i] = nil
            createPlayer(at: i)
            buildGrid()
        }
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
        hideTimer?.invalidate()
        hideTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        for i in 0..<players.count {
            if let obs = endObservers[i] { NotificationCenter.default.removeObserver(obs) }
            players[i]?.pause()
        }
        players.removeAll()
        playerLayers.forEach { $0?.removeFromSuperlayer() }
        playerLayers.removeAll()
        playerViews.removeAll()
        endObservers.removeAll()
        enabled.removeAll()
    }

    deinit { releaseAll() }
}
