import UIKit
import UserNotifications
import Capacitor
import AVFoundation

private let KEY_BIO_USER      = "CapacitorStorage.bio_username"
private let KEY_BIO_PASS      = "CapacitorStorage.bio_password"
private let KEY_BIO_TOTP      = "CapacitorStorage.bio_totp_secret"
private let KEY_BIO_ACCOUNTS  = "CapacitorStorage.bio_accounts"
private let KEY_BIO_AUTOLOGIN = "CapacitorStorage.bio_autologin"
private let KEY_TOKEN_REG     = "CapacitorStorage.token_registered"
private let KEY_TOKEN_VAL     = "CapacitorStorage.token_value"

private let APP_GROUP_ID  = "group.it.guardroom24.app"
private let SOUND_KEY     = "notif_alarm_sound"

private let SOUND_KEYS   = ["", "firealarm", "funnyalarm", "horroralarm", "meditationalarm",
                             "policealarm", "softalarm", "strongalarm", "sweetalarm"]
private let SOUND_LABELS = ["Suono di sistema", "Fire Alarm", "Funny Alarm", "Horror Alarm",
                             "Meditation Alarm", "Police Alarm", "Soft Alarm", "Strong Alarm", "Sweet Alarm"]

class AppSettingsViewController: UITableViewController {

    private let bridge: CAPBridgeProtocol
    private var accounts: [[String: String]] = []

    private var switchBio   = UISwitch()
    private var switchNotif = UISwitch()

    private var tokenRegistered = false
    private let tokenDotLabel   = UILabel()

    private var previewPlayer: AVAudioPlayer?
    private var cachedServerURL: URL?
    private var cachedToken: String?

    // Sezioni dinamiche in base alla presenza di account
    private var notifSection: Int { accounts.isEmpty ? 1 : 2 }
    private var sectionCount:  Int { accounts.isEmpty ? 2 : 3 }

    init(bridge: CAPBridgeProtocol) {
        self.bridge = bridge
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Impostazioni App"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))

        let ud = UserDefaults.standard
        loadAccounts(ud)
        tokenRegistered = ud.string(forKey: KEY_TOKEN_REG) == "1"
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

        cachedToken = ud.string(forKey: "apns_device_token")
        if let webView = bridge.webView, let url = webView.url {
            cachedServerURL = url
        }
    }

    private func loadAccounts(_ ud: UserDefaults) {
        accounts = []
        if let json = ud.string(forKey: KEY_BIO_ACCOUNTS),
           let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]] {
            accounts = arr
        } else if let user = ud.string(forKey: KEY_BIO_USER) {
            // Migrazione dal vecchio formato
            let acc: [String: String] = [
                "username":    user,
                "password":    ud.string(forKey: KEY_BIO_PASS) ?? "",
                "totp_secret": ud.string(forKey: KEY_BIO_TOTP) ?? ""
            ]
            accounts = [acc]
            if let data = try? JSONSerialization.data(withJSONObject: accounts),
               let str = String(data: data, encoding: .utf8) {
                ud.set(str, forKey: KEY_BIO_ACCOUNTS)
            }
        }
    }

    @objc private func close() {
        previewPlayer?.stop()
        previewPlayer = nil
        dismiss(animated: true)
    }

    // MARK: - UITableView

    override func numberOfSections(in tableView: UITableView) -> Int { sectionCount }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "ACCESSO BIOMETRICO" }
        if !accounts.isEmpty && section == 1 { return "ACCOUNT MEMORIZZATI" }
        return "NOTIFICHE"
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 2 }
        if !accounts.isEmpty && section == 1 { return accounts.count }
        return tokenRegistered ? 4 : 3
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.selectionStyle = .none

        if indexPath.section == 0 {
            if indexPath.row == 0 {
                cell.textLabel?.text = "Impronta / Face ID"
                cell.accessoryView = switchBio
            } else {
                cell.textLabel?.text = "Gestisci impronte del telefono →"
                cell.textLabel?.textColor = .systemBlue
                cell.selectionStyle = .default
            }
        } else if !accounts.isEmpty && indexPath.section == 1 {
            let acc = accounts[indexPath.row]
            cell.textLabel?.text = acc["username"] ?? ""
            cell.textLabel?.textColor = UIColor(red: 0.267, green: 0.549, blue: 0.796, alpha: 1)
            cell.selectionStyle = .default
            // Bottone "Rimuovi" a destra
            let btn = UIButton(type: .system)
            btn.setTitle("Rimuovi", for: .normal)
            btn.setTitleColor(.systemRed, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 14)
            btn.sizeToFit()
            btn.tag = indexPath.row
            btn.addTarget(self, action: #selector(removeAccountTapped(_:)), for: .touchUpInside)
            cell.accessoryView = btn
        } else {
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
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 && indexPath.row == 1 {
            openSystemSettings()
        } else if !accounts.isEmpty && indexPath.section == 1 {
            switchToAccount(at: indexPath.row)
        } else if indexPath.section == notifSection {
            switch indexPath.row {
            case 1: showSoundPicker()
            case 2: doRegisterToken()
            case 3: doRemoveToken()
            default: break
            }
        }
    }

    // MARK: - Account memorizzati

    @objc private func removeAccountTapped(_ sender: UIButton) {
        let idx = sender.tag
        guard idx < accounts.count else { return }
        let username = accounts[idx]["username"] ?? ""
        let alert = UIAlertController(
            title: "Rimuovi account",
            message: "Rimuovere l'account \(username) dall'accesso biometrico?",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Rimuovi", style: .destructive) { [weak self] _ in
            self?.removeAccount(at: idx)
            self?.removeTokenForUser(username)
        })
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel))
        present(alert, animated: true)
    }

    private func removeAccount(at idx: Int) {
        accounts.remove(at: idx)
        let ud = UserDefaults.standard
        if accounts.isEmpty {
            ud.removeObject(forKey: KEY_BIO_ACCOUNTS)
            ud.removeObject(forKey: KEY_BIO_USER)
            ud.removeObject(forKey: KEY_BIO_PASS)
            ud.removeObject(forKey: KEY_BIO_TOTP)
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: accounts),
               let str = String(data: data, encoding: .utf8) {
                ud.set(str, forKey: KEY_BIO_ACCOUNTS)
            }
            // Aggiorna le vecchie chiavi con il primo account rimasto
            let first = accounts[0]
            ud.set(first["username"], forKey: KEY_BIO_USER)
            ud.set(first["password"], forKey: KEY_BIO_PASS)
            ud.set(first["totp_secret"], forKey: KEY_BIO_TOTP)
        }
        tableView.reloadData()
    }

    private func switchToAccount(at idx: Int) {
        guard idx < accounts.count else { return }
        let acc = accounts[idx]
        let ud = UserDefaults.standard
        ud.set(acc["username"],    forKey: KEY_BIO_USER)
        ud.set(acc["password"],    forKey: KEY_BIO_PASS)
        ud.set(acc["totp_secret"], forKey: KEY_BIO_TOTP)
        ud.set("1", forKey: "CapacitorStorage.bio_pending_login_otp")
        ud.set("1", forKey: KEY_BIO_AUTOLOGIN)
        dismiss(animated: true) { [weak self] in
            guard let self = self,
                  let wv = self.bridge.webView,
                  let url = wv.url else { return }
            var comps = URLComponents()
            comps.scheme = url.scheme
            comps.host   = url.host
            comps.port   = url.port
            comps.path   = "/logout"
            if let logoutURL = comps.url {
                wv.load(URLRequest(url: logoutURL))
            }
        }
    }

    private func removeTokenForUser(_ login: String) {
        guard let token = cachedToken,
              let baseURL = cachedServerURL else { return }
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        comps?.path = "/json_removefcmtoken_login"
        guard let url = comps?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let tokenEnc = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let loginEnc = login.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? login
        request.httpBody = "v_token=\(tokenEnc)&v_login=\(loginEnc)".data(using: .utf8)
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies   = false
        URLSession(configuration: config).dataTask(with: request) { _, _, _ in }.resume()
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
                let ud = UserDefaults(suiteName: APP_GROUP_ID)
                ud?.set(key, forKey: SOUND_KEY)
                ud?.synchronize()
                self?.tableView.reloadRows(at: [IndexPath(row: 1, section: self?.notifSection ?? 1)], with: .none)
                self?.playPreview(key: key)
            }
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "Annulla", style: .cancel) { [weak self] _ in
            self?.previewPlayer?.stop()
            self?.previewPlayer = nil
        })
        if let popover = alert.popoverPresentationController {
            let ip = IndexPath(row: 1, section: notifSection)
            popover.sourceView = tableView.cellForRow(at: ip)
            popover.sourceRect = tableView.cellForRow(at: ip)?.bounds ?? .zero
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
        tokenRegistered = registered
        applyDotColor()
        tableView.reloadSections(IndexSet(integer: notifSection), with: .none)
    }

    // MARK: - Token operations

    private func doRegisterToken() {
        guard let token = cachedToken else { showAlert("Token APNs non disponibile."); return }
        guard cachedServerURL != nil else { showAlert("URL server non disponibile."); return }
        let presenter = presentingViewController
        previewPlayer?.stop(); previewPlayer = nil
        dismiss(animated: true) { [self] in
            self.sendToken(token, path: "/json_savefcmtoken") { status in
                if status == 204 {
                    UserDefaults.standard.set("1", forKey: KEY_TOKEN_REG)
                    UserDefaults.standard.set(token, forKey: KEY_TOKEN_VAL)
                }
                let msg = status == 204
                    ? "Token notifiche registrato con successo."
                    : "Errore registrazione token (http_code=\(status))"
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: nil, message: msg, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    presenter?.present(alert, animated: true)
                }
            }
        }
    }

    private func doRemoveToken() {
        guard let token = cachedToken else { showAlert("Token APNs non disponibile."); return }
        guard cachedServerURL != nil else { showAlert("URL server non disponibile."); return }
        let presenter = presentingViewController
        previewPlayer?.stop(); previewPlayer = nil
        dismiss(animated: true) { [self] in
            self.sendToken(token, path: "/json_removefcmtoken") { status in
                if status == 204 {
                    UserDefaults.standard.removeObject(forKey: KEY_TOKEN_REG)
                }
                let msg = status == 204
                    ? "Token notifiche rimosso."
                    : "Errore rimozione token (http_code=\(status))"
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
            completion(500)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "v_token=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)".data(using: .utf8)
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies   = false
        URLSession(configuration: config).dataTask(with: request) { data, _, _ in
            var status = 500
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = json["http_code"] {
                status = Int(String(describing: code)) ?? 500
            }
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
            ud.removeObject(forKey: KEY_BIO_ACCOUNTS)
            accounts = []
            tableView.reloadData()
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
