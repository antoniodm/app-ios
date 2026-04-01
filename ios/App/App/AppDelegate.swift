import UIKit
import Capacitor
import UserNotifications

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        AlarmSoundManager.shared.registerNotificationCategory()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Ferma il suono di allarme quando l'utente apre l'app.
        // Nota: per il tap da background, applicationDidBecomeActive scatta PRIMA
        // di userNotificationCenter(_:didReceive:), quindi stop() è no-op in quel caso.
        AlarmSoundManager.shared.stop()
    }

    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    // App in foreground: la notifica arriva mentre l'app è aperta
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let channelId = notification.request.content.userInfo["android_channel_id"] as? String ?? ""
        if channelId == "alarm_channel" {
            AlarmSoundManager.shared.start()
        }
        completionHandler([.banner, .sound, .badge])
    }

    // Tap su notifica o azione (da background o foreground)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == AlarmSoundManager.stopActionId {
            AlarmSoundManager.shared.stop()
        } else {
            let channelId = response.notification.request.content.userInfo["android_channel_id"] as? String ?? ""
            if channelId == "alarm_channel" {
                AlarmSoundManager.shared.start()
            }
        }
        completionHandler()
    }
}
