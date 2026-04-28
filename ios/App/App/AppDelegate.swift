import UIKit
import Capacitor
import UserNotifications
import AVFoundation
import WebKit

// Sincronizza i cookie WKWebView → HTTPCookieStorage.shared
// In questo modo URLSession.shared li usa automaticamente senza toccare WKWebView dal modal
private class CookieSyncer: NSObject, WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        cookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var alarmPlayer: AVAudioPlayer?
    private let cookieSyncer = CookieSyncer()
    private var cookieSyncerAdded = false
    private var resignedActiveAt: Date?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        resignedActiveAt = Date()
    }
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Ferma il suono di allarme solo se l'app era davvero in background (>0.5s)
        // Un banner di notifica causa un ciclo resign/active di ~50ms: in quel caso NON stoppare il player
        let wasReallyInactive = resignedActiveAt.map { Date().timeIntervalSince($0) > 0.5 } ?? true
        resignedActiveAt = nil
        if wasReallyInactive {
            alarmPlayer?.stop()
            alarmPlayer = nil
        }
        // Aggiorna il token APNs in cache
        UIApplication.shared.registerForRemoteNotifications()
        // Sincronizza cookie WKWebView → HTTPCookieStorage.shared (contesto sicuro, nessun modal)
        let store = WKWebsiteDataStore.default().httpCookieStore
        if !cookieSyncerAdded {
            store.add(cookieSyncer)
            cookieSyncerAdded = true
        }
        store.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {}

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apns_device_token")
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }
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
            alarmPlayer?.numberOfLoops = -1
            alarmPlayer?.play()
            completionHandler([.banner, .badge])
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
