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

        // Legge il suono dal payload APNs (campo "sound_name"), fallback "firealarm"
        let soundName = request.content.userInfo["sound_name"] as? String ?? "firealarm"

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
