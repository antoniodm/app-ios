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

    init(bridge: CAPBridgeProtocol) {
        self.bridge = bridge
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func dlog(_ msg: String) {
        let t = Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10000)
        let line = String(format: "%.2f %@", t, msg)
        debugLog.append(line)
        os_log("GUARDROOM_SETTINGS %{public}@", type: .fault, line)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dlog("viewDidLoad")
        title = "Impostazioni App"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

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
        return 1 // debug
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
            cell.textLabel?.text = "Mostra log debug"
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
            showDebugLog()
        }
    }

    // MARK: - Debug

    private func showDebugLog() {
        let text = debugLog.isEmpty ? "(nessun log)" : debugLog.joined(separator: "\n")
        let alert = UIAlertController(title: "Debug Log", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copia", style: .default) { _ in
            UIPasteboard.general.string = text
        })
        alert.addAction(UIAlertAction(title: "Cancella", style: .destructive) { [weak self] _ in
            self?.debugLog.removeAll()
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
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

    private func doRegisterToken() {
        let cachedToken = UserDefaults.standard.string(forKey: "apns_device_token")
        dlog("doRegisterToken — token=\(cachedToken?.prefix(8) ?? "NIL")")
        guard let token = cachedToken else {
            dlog("doRegisterToken — token nil, chiamo registerForRemoteNotifications")
            UIApplication.shared.registerForRemoteNotifications()
            dlog("doRegisterToken — registerForRemoteNotifications tornato, token=\(UserDefaults.standard.string(forKey: "apns_device_token")?.prefix(8) ?? "ancora NIL")")
            showAlert("Token non ancora disponibile. Controlla log debug.")
            return
        }
        sendToken(token, path: "/json_savefcmtoken") { [weak self] status in
            self?.updateTokenState(status == 204)
        }
    }

    private func doRemoveToken() {
        let cachedToken = UserDefaults.standard.string(forKey: "apns_device_token")
        dlog("doRemoveToken — token=\(cachedToken?.prefix(8) ?? "NIL")")
        guard let token = cachedToken else {
            showAlert("Token non disponibile.")
            return
        }
        sendToken(token, path: "/json_removefcmtoken") { [weak self] status in
            self?.updateTokenState(status != 204)
        }
    }

    // Usa HTTPCookieStorage.shared (sincrono, zero WKWebView) + URLSession puro
    private func sendToken(_ token: String, path: String, completion: @escaping (Int) -> Void) {
        dlog("sendToken path=\(path) token=\(token.prefix(8))")
        guard let webView = bridge.webView,
              let currentURL = webView.url else {
            dlog("sendToken — webView o url nil, esco")
            return
        }
        guard let url = URL(string: path, relativeTo: currentURL) else {
            dlog("sendToken — URL non costruibile da \(path) + \(currentURL)")
            return
        }
        dlog("sendToken — URL=\(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "v_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)".data(using: .utf8)

        // Cookie da HTTPCookieStorage.shared (sincrono, mai blocca)
        let sharedCookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        dlog("sendToken — cookie shared: \(sharedCookies.count) (nomi: \(sharedCookies.map(\.name).joined(separator: ",")))")
        let headers = HTTPCookie.requestHeaderFields(with: sharedCookies)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        dlog("sendToken — avvio URLSession.dataTask")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodySnippet = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "nil"
            self?.dlog("sendToken — risposta httpStatus=\(httpStatus) error=\(error?.localizedDescription ?? "none") body=\(bodySnippet)")

            var status = 500
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["http_code"] {
                status = Int(String(describing: code)) ?? 500
            }
            self?.dlog("sendToken — http_code parsed=\(status)")
            DispatchQueue.main.async { completion(status) }
        }.resume()
        dlog("sendToken — dataTask avviato")
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
