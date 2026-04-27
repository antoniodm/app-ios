import UIKit
import UserNotifications
import Capacitor
import AVFoundation

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

    private let sections = ["ACCESSO BIOMETRICO", "NOTIFICHE"]
    private let bioRows  = ["Impronta / Face ID", "Gestisci impronte del telefono →"]

    private var switchBio   = UISwitch()
    private var switchNotif = UISwitch()

    private var tokenRegistered = false
    private let tokenDotLabel   = UILabel()

    private var previewPlayer: AVAudioPlayer?

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
        switchBio.isOn = ud.string(forKey: KEY_BIO_USER) != nil
        switchBio.addTarget(self, action: #selector(biometricToggled(_:)), for: .valueChanged)

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.switchNotif.isOn = settings.authorizationStatus == .authorized
            }
        }
        switchNotif.addTarget(self, action: #selector(notifToggled(_:)), for: .valueChanged)

        tokenDotLabel.font = .systemFont(ofSize: 18)
        tokenDotLabel.sizeToFit()

        bridge.webView?.evaluateJavaScript(
            "window._guardroom_token_registered === true ? 'true' : 'false'"
        ) { [weak self] result, _ in
            DispatchQueue.main.async {
                self?.tokenRegistered = (result as? String) == "true"
                self?.applyDotColor()
                self?.tableView.reloadSections(IndexSet(integer: 1), with: .none)
            }
        }
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
        section == 0 ? bioRows.count : (tokenRegistered ? 4 : 3)
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
        } else if indexPath.section == 1 && indexPath.row == 1 {
            showSoundPicker()
        } else if indexPath.section == 1 && indexPath.row == 2 {
            doRegisterToken()
        } else if indexPath.section == 1 && indexPath.row == 3 {
            doRemoveToken()
        }
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

        // Preview: suona al tap sull'azione (non standard UIKit ma facile via swizzling alternativo)
        // Implementiamo con tap gesture sul tableView selection + override

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
        let wasRegistered = tokenRegistered
        tokenRegistered = registered
        applyDotColor()

        let removeIP = IndexPath(row: 3, section: 1)
        if registered && !wasRegistered {
            tableView.insertRows(at: [removeIP], with: .automatic)
        } else if !registered && wasRegistered {
            tableView.deleteRows(at: [removeIP], with: .automatic)
        }
        tableView.reloadRows(at: [IndexPath(row: 2, section: 1)], with: .none)
    }

    // MARK: - Token operations

    private func doRegisterToken() {
        guard let webView = bridge.webView else { return }
        webView.callAsyncJavaScript("""
            var PN = window.Capacitor && window.Capacitor.Plugins.PushNotifications;
            if (!PN) throw new Error("PushNotifications non disponibile");
            await PN.removeAllListeners();
            var data = await new Promise(function(resolve, reject) {
                PN.addListener('registration', function(d) { resolve(d); });
                PN.addListener('registrationError', function(e) { reject(new Error(e.error || 'error')); });
                PN.register();
            });
            var res = await fetch('/json_savefcmtoken', {
                method: 'POST',
                credentials: 'same-origin',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'v_token=' + encodeURIComponent(data.value)
            });
            var json = await res.json();
            return parseInt(json.http_code);
        """, arguments: [:], in: nil, in: .page) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let val) = result, let status = val as? Int {
                    self?.updateTokenState(status == 204)
                }
            }
        }
    }

    private func doRemoveToken() {
        guard let webView = bridge.webView else { return }
        webView.callAsyncJavaScript("""
            var PN = window.Capacitor && window.Capacitor.Plugins.PushNotifications;
            if (!PN) throw new Error("PushNotifications non disponibile");
            await PN.removeAllListeners();
            var data = await new Promise(function(resolve, reject) {
                PN.addListener('registration', function(d) { resolve(d); });
                PN.addListener('registrationError', function(e) { reject(new Error(e.error || 'error')); });
                PN.register();
            });
            var res = await fetch('/json_removefcmtoken', {
                method: 'POST',
                credentials: 'same-origin',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'v_token=' + encodeURIComponent(data.value)
            });
            var json = await res.json();
            return parseInt(json.http_code);
        """, arguments: [:], in: nil, in: .page) { [weak self] result in
            DispatchQueue.main.async {
                if case .success(let val) = result, let status = val as? Int {
                    self?.updateTokenState(status != 204)
                }
            }
        }
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
