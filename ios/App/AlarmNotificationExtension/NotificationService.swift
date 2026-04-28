import UserNotifications

class NotificationService: UNNotificationServiceExtension {

    private let appGroupID = "group.it.guardroom24.app"
    private let soundKey   = "notif_alarm_sound"

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

        let ud = UserDefaults(suiteName: appGroupID)
        let soundName = ud?.string(forKey: soundKey) ?? "firealarm"

        if soundName.isEmpty {
            content.sound = .default
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName + ".wav"))
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestContent {
            content.sound = .default
            contentHandler?(content)
        }
    }
}
