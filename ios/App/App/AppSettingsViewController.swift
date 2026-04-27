import UIKit
import UserNotifications
import Capacitor
import AVFoundation
import os.log

private let KEY_BIO_USER  = "CapacitorStorage.bio_username"
private let KEY_BIO_PASS  = "CapacitorStorage.bio_password"
private let KEY_BIO_TOTP  = "CapacitorStorage.bio_totp_secret"

private let APP_GROUP_ID  = "group.it.guardroom24.app"
private let SOUND_KEY     = "notif_alarm_sound"

private let SOUND_KEYS   = ["", "firealarm", "funnyalarm", "horroralarm", "meditationalarm",
                             "policealarm", "softalarm", "strongalarm", "sweetalarm"]
private let SOUND_LABELS = ["Suono di sistema", "Fire Alarm", "Funny Alarm", "Horror Alarm",
                             "Meditation Alarm", "Police Alarm", "Soft Alarm", "Strong Alarm", "Sweet Alarm"]

class AppSettingsViewController: UITableViewController {

    private let bridge: CAPBridgeProtocol

    private let sections = ["ACCESSO BIOMETRICO", "NOTIFICHE", "DEBUG"]
    private let bioRows  = ["Impronta / Face ID", "Gestisci impronte del telefono →"]

    private var switchBio   = UISwitch()
    private var switchNotif = UISwitch()

    private var tokenRegistered = false
    private let tokenDotLabel   = UILabel()

    private var previewPlayer: AVAudioPlayer?
    private var debugLog: [String] = []
    private let debugTextView = UITextView()

    // Solo URL base (proprietà semplice, nessuna IPC WKWebView)
    private var cachedServerURL: URL?
    private var cachedToken: String?

    init(bridge: CAPBridgeProtocol) {
        self.bridge = bridge
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Log (sempre su main thread)

    private func dlog(_ msg: String) {
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000)
        let line = String(format: "%.2f %@", t, msg)
        debugLog.append(line)
        os_log("GUARDROOM_SETTINGS %{public}@", type: .fault, line)
        updateDebugHeader()
    }

    private func updateDebugHeader() {
        // Chiamato sempre su main thread
        let text = debugLog.joined(separator: "\n")
        debugTextView.text = text
        let bottom = debugTextView.contentSize.height - debugTextView.bounds.height
        if bottom > 0 {
            debugTextView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Impostazioni App"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        // Header con log debug — visibile subito senza nessun tap
        debugTextView.isEditable = false
        debugTextView.isScrollEnabled = true
        debugTextView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        debugTextView.textColor = .secondaryLabel
        debugTextView.backgroundColor = .systemBackground
        debugTextView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 180)
        tableView.tableHeaderView = debugTextView

        let ud = UserDefaults.standard
        switchBio.isOn = ud.string(forKey: KEY_BIO_USER) != nil
        switchBio.addTarget(self, action: #selector(biometricToggled(_:)), for: .valueChanged)

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.switchNotif.isOn = settings.authorizationStatus == .authorized
            }
        }
        switchNotif.addTarget(self, action: #selector(notifToggled(_:)), for: .valueChanged)

        tokenDotLabel.font = .systemFont(ofSize: 18)
        applyDotColor()

        // ZERO chiamate WKWebView: solo UserDefaults e proprietà .url (lettura semplice, nessuna IPC)
        cachedToken = ud.string(forKey: "apns_device_token")
        dlog("viewDidLoad — token=\(cachedToken?.prefix(8).description ?? "NIL")")

        if let webView = bridge.webView, let url = webView.url {
            cachedServerURL = url
            dlog("viewDidLoad — serverURL=\(url.absoluteString)")
        } else {
            dlog("viewDidLoad — webView.url nil")
        }

        // Cookie: AppDelegate.applicationDidBecomeActive li ha già sincronizzati
        // in HTTPCookieStorage.shared tramite CookieSyncer — URLSession li usa automaticamente
        let cookieCount = HTTPCookieStorage.shared.cookies?.count ?? 0
        dlog("viewDidLoad — cookie in HTTPCookieStorage: \(cookieCount)")
    }

    @objc private func close() {
        previewPlayer?.stop()
        previewPlayer = nil
        dismiss(animated: true)
    }

    // MARK: - UITableView

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section]
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return bioRows.count }
        if section == 1 { return tokenRegistered ? 4 : 3 }
        return 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none

        if indexPath.section == 0 {
            cell.textLabel?.text = bioRows[indexPath.row]
            if indexPath.row == 0 {
                cell.accessoryView = switchBio
            } else {
                cell.textLabel?.textColor = .systemBlue
                cell.selectionStyle = .default
            }
        } else if indexPath.section == 1 {
            switch indexPath.row {
            case 0:
                cell.textLabel?.text = "Notifiche abilitate"
                cell.accessoryView = switchNotif
            case 1:
                cell.textLabel?.text = "Suono allarme"
                cell.detailTextLabel?.text = currentSoundLabel()
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case 2:
                cell.textLabel?.text = "Aggiorna token notifiche"
                cell.textLabel?.textColor = .systemBlue
                cell.selectionStyle = .default
                cell.accessoryView = tokenDotLabel
            case 3:
                cell.textLabel?.text = "Rimuovi token notifiche"
                cell.textLabel?.textColor = .systemBlue
                cell.selectionStyle = .default
            default: break
            }
        } else {
            cell.textLabel?.text = "Copia log negli appunti"
            cell.textLabel?.textColor = .systemOrange
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 && indexPath.row == 1 {
            openSystemSettings()
        } else if indexPath.section == 1 && indexPath.row == 1 {
            showSoundPicker()
        } else if indexPath.section == 1 && indexPath.row == 2 {
            doRegisterToken()
        } else if indexPath.section == 1 && indexPath.row == 3 {
            doRemoveToken()
        } else if indexPath.section == 2 {
            copyLog()
        }
    }

    // MARK: - Debug

    private func copyLog() {
        let text = debugLog.isEmpty ? "(nessun log)" : debugLog.joined(separator: "\n")
        UIPasteboard.general.string = text
        showAlert("Log copiato negli appunti (\(debugLog.count) righe)")
    }

    // MARK: - Suono allarme

    private func currentSoundLabel() -> String {
        let key = UserDefaults(suiteName: APP_GROUP_ID)?.string(forKey: SOUND_KEY) ?? "firealarm"
        return SOUND_LABELS[SOUND_KEYS.firstIndex(of: key) ?? 1]
    }

    private func showSoundPicker() {
        let current = UserDefaults(suiteName: APP_GROUP_ID)?.string(forKey: SOUND_KEY) ?? "firealarm"
        let alert = UIAlertController(title: "Suono allarme", message: nil, preferredStyle: .actionSheet)
        for (i, label) in SOUND_LABELS.enumerated() {
            let key = SOUND_KEYS[i]
            let isSelected = key == current
            let action = UIAlertAction(title: isSelected ? "✓ " + label : label, style: .default) { [weak self] _ in
                self?.previewPlayer?.stop()
                self?.previewPlayer = nil
                UserDefaults(suiteName: APP_GROUP_ID)?.set(key, forKey: SOUND_KEY)
                self?.tableView.reloadRows(at: [IndexPath(row: 1, section: 1)], with: .none)
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { [weak self] _ in
            self?.previewPlayer?.stop()
            self?.previewPlayer = nil
        })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = tableView.cellForRow(at: IndexPath(row: 1, section: 1))
            popover.sourceRect = tableView.cellForRow(at: IndexPath(row: 1, section: 1))?.bounds ?? .zero
        }
        present(alert, animated: true)
    }

    private func playPreview(key: String) {
        previewPlayer?.stop()
        guard !key.isEmpty,
              let url = Bundle.main.url(forResource: key, withExtension: "wav") else { return }
        previewPlayer = try? AVAudioPlayer(contentsOf: url)
        previewPlayer?.play()
    }

    // MARK: - Token state

    private func applyDotColor() {
        tokenDotLabel.text = "●"
        tokenDotLabel.textColor = tokenRegistered ? .systemGreen : .systemRed
        tokenDotLabel.sizeToFit()
    }

    private func updateTokenState(_ registered: Bool) {
        dlog("updateTokenState registered=\(registered)")
        tokenRegistered = registered
        applyDotColor()
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
    }

    // MARK: - Token operations

    // Dismissiamo il modal PRIMA di fare la request:
    // qualsiasi operazione di rete con il modal aperto sopra WKWebView causa deadlock su iOS 17+
    private func doRegisterToken() {
        dlog("doRegisterToken — dismisso il modal, poi invio")
        guard let token = cachedToken else { showAlert("Token APNs non disponibile."); return }
        guard cachedServerURL != nil else { showAlert("URL server non disponibile."); return }
        let presenter = presentingViewController
        previewPlayer?.stop(); previewPlayer = nil
        dismiss(animated: true) { [self] in   // strong ref: mantiene self vivo durante la request
            self.sendToken(token, path: "/json_savefcmtoken") { status in
                let msg = status == 204 ? "Token notifiche registrato con successo." : "Errore registrazione token (http_code=\(status))"
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    presenter?.present(alert, animated: true)
                }
            }
        }
    }

    private func doRemoveToken() {
        dlog("doRemoveToken — dismisso il modal, poi invio")
        guard let token = cachedToken else { showAlert("Token APNs non disponibile."); return }
        guard cachedServerURL != nil else { showAlert("URL server non disponibile."); return }
        let presenter = presentingViewController
        previewPlayer?.stop(); previewPlayer = nil
        dismiss(animated: true) { [self] in
            self.sendToken(token, path: "/json_removefcmtoken") { status in
                let msg = status == 204 ? "Token notifiche rimosso." : "Errore rimozione token (http_code=\(status))"
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    presenter?.present(alert, animated: true)
                }
            }
        }
    }

    private func sendToken(_ token: String, path: String, completion: @escaping (Int) -> Void) {
        guard let baseURL = cachedServerURL,
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            os_log("GUARDROOM_SETTINGS sendToken — URL non costruibile", type: .fault)
            completion(500)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "v_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)".data(using: .utf8)

        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        os_log("GUARDROOM_SETTINGS sendToken — url=%{public}@ cookie:%d", type: .fault, url.absoluteString, cookies.count)
        let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
        for (k, v) in cookieHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)

        session.dataTask(with: request) { data, response, error in
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "nil"
            var status = 500
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["http_code"] {
                status = Int(String(describing: code)) ?? 500
            }
            os_log("GUARDROOM_SETTINGS sendToken — httpStatus=%d http_code=%d body=%{public}@", type: .fault, httpStatus, status, body)
            DispatchQueue.main.async { completion(status) }
        }.resume()
    }

    // MARK: - Azioni

    @objc private func biometricToggled(_ sw: UISwitch) {
        if sw.isOn {
            sw.isOn = false
            showAlert("L'accesso biometrico si attiva al prossimo login")
        } else {
            let ud = UserDefaults.standard
            ud.removeObject(forKey: KEY_BIO_USER)
            ud.removeObject(forKey: KEY_BIO_PASS)
            ud.removeObject(forKey: KEY_BIO_TOTP)
            showAlert("Accesso biometrico disabilitato")
        }
    }

    @objc private func notifToggled(_ sw: UISwitch) {
        let urlString: String
        if #available(iOS 16.0, *) {
            urlString = UIApplication.openNotificationSettingsURLString
        } else {
            urlString = UIApplication.openSettingsURLString
        }
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.switchNotif.isOn = settings.authorizationStatus == .authorized
            }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func showAlert(_ msg: String) {
        let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
