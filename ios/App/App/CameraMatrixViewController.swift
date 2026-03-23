import UIKit
import AVFoundation

class CameraMatrixViewController: UIViewController {

    var streamUrls: [String] = []
    var streamNames: [String] = []

    private var players: [AVPlayer] = []
    private var playerLayers: [AVPlayerLayer] = []
    private var containerViews: [UIView] = []
    private var closeButton: UIButton!
    private var hideTimer: Timer?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPlayers()
        setupCloseButton()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutGrid()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.layoutGrid()
        }
    }

    // MARK: - Setup

    private func setupPlayers() {
        for urlStr in streamUrls {
            guard let url = URL(string: urlStr) else { continue }

            let player = AVPlayer(url: url)
            player.isMuted = true  // Telecamere di sorveglianza: nessun audio
            players.append(player)

            let layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = UIColor.black.cgColor
            playerLayers.append(layer)

            let container = UIView()
            container.backgroundColor = .black
            container.layer.addSublayer(layer)
            containerViews.append(container)
            view.addSubview(container)

            player.play()
        }
    }

    private func setupCloseButton() {
        closeButton = UIButton(type: .system)
        closeButton.setTitle("✕  Chiudi", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        closeButton.layer.cornerRadius = 8
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 12, left: 24, bottom: 12, right: 24)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(closeAll), for: .touchUpInside)
        view.addSubview(closeButton)
    }

    // MARK: - Layout

    private func layoutGrid() {
        let bounds = view.bounds
        let count = containerViews.count
        guard count > 0 else { return }

        // Portrait: 1 colonna impilata; Landscape: griglia come Android
        let isPortrait = bounds.height > bounds.width
        let cols: Int
        if isPortrait {
            cols = 1
        } else {
            cols = count == 1 ? 1 : count <= 4 ? 2 : 3
        }
        let rows = Int(ceil(Double(count) / Double(cols)))

        let cellW = bounds.width / CGFloat(cols)
        let cellH = bounds.height / CGFloat(rows)

        for (i, container) in containerViews.enumerated() {
            let col = i % cols
            let row = i / cols
            let frame = CGRect(
                x: CGFloat(col) * cellW,
                y: CGFloat(row) * cellH,
                width: cellW,
                height: cellH
            )
            container.frame = frame
            playerLayers[i].frame = container.bounds
        }

        closeButton.sizeToFit()
        closeButton.center = CGPoint(x: bounds.midX, y: bounds.midY)
        view.bringSubviewToFront(closeButton)
    }

    // MARK: - Actions

    @objc private func handleTap() {
        hideTimer?.invalidate()
        if closeButton.isHidden {
            closeButton.isHidden = false
            hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                self?.closeButton.isHidden = true
            }
        } else {
            closeButton.isHidden = true
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
        players.forEach { $0.pause() }
        players.removeAll()
        playerLayers.forEach { $0.removeFromSuperlayer() }
        playerLayers.removeAll()
        containerViews.removeAll()
    }

    deinit {
        releaseAll()
    }
}
