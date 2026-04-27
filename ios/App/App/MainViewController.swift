import Capacitor

class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(ExoPlayerPlugin())
        bridge?.registerPluginInstance(AppSettingsPlugin())
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        guard top > 0, let wv = webView else { return }
        wv.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: view.bounds.height - top)
    }
}
