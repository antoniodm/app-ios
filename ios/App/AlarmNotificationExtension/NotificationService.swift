import UserNotifications
import os.log

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
        let stored = ud?.string(forKey: soundKey)
        let soundName = stored ?? "firealarm"

        os_log("GUARDROOM_EXT didReceive — ud=%{public}@ stored=%{public}@ soundName=%{public}@",
               type: .fault,
               ud == nil ? "nil" : "ok",
               stored ?? "nil",
               soundName)

        if soundName.isEmpty {
            content.sound = .default
        } else {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName + ".wav"))
        }

        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        os_log("GUARDROOM_EXT serviceExtensionTimeWillExpire", type: .fault)
        if let content = bestContent {
            content.sound = .default
            contentHandler?(content)
        }
    }
}
