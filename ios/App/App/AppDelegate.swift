import UIKit
import Capacitor
import UserNotifications
import AVFoundation

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var alarmPlayer: AVAudioPlayer?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Ferma il suono di allarme quando l'utente apre/usa l'app (come onActivityResumed su Android)
        alarmPlayer?.stop()
        alarmPlayer = nil
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
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .apnsTokenReceived, object: nil, userInfo: ["token": token])
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("it.guardroom24.apnsTokenReceived")
}

extension AppDelegate: UNUserNotificationCenterDelegate {

    // App in foreground: suona il suono selezionato dall'utente
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let ud = UserDefaults(suiteName: "group.it.guardroom24.app")
        let soundName = ud?.string(forKey: "notif_alarm_sound") ?? "firealarm"

        if !soundName.isEmpty,
           let url = Bundle.main.url(forResource: soundName, withExtension: "wav") {
            alarmPlayer?.stop()
            alarmPlayer = try? AVAudioPlayer(contentsOf: url)
            alarmPlayer?.numberOfLoops = -1  // loop finché l'utente non interagisce
            alarmPlayer?.play()
            completionHandler([.banner, .badge])  // no .sound — suoniamo noi
        } else {
            completionHandler([.banner, .sound, .badge])
        }
    }

    // Tap su notifica: ferma il suono
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        alarmPlayer?.stop()
        alarmPlayer = nil
        completionHandler()
    }
}
