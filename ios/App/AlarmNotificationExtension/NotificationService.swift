import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler

        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestContent = content

        let soundName: String
        if let ud = UserDefaults(suiteName: "group.it.guardroom24.app"),
           let stored = ud.string(forKey: "notif_alarm_sound"),
           !stored.isEmpty {
            soundName = stored
        } else {
            soundName = "firealarm"
        }

        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName + ".wav"))
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestContent {
            content.sound = .default
            contentHandler?(content)
        }
    }
}
