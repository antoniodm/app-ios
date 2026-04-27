import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    private let appGroupID = "group.it.guardroom24.app"
    private let soundKey   = "notif_alarm_sound"

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }

        let ud = UserDefaults(suiteName: appGroupID)
        let soundName = ud?.string(forKey: soundKey) ?? "firealarm"

        if soundName.isEmpty {
            // Suono di sistema: lascia il default del payload
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName + ".wav"))
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS userà il contenuto originale — nessuna azione necessaria
    }
}
