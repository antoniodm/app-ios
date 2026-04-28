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

        // Test minimale: suono fisso senza App Group
        content.sound = UNNotificationSound(named: UNNotificationSoundName("firealarm.wav"))

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestContent {
            content.sound = .default
            contentHandler?(content)
        }
    }
}
