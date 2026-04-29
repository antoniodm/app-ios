import UIKit
import Capacitor
import UserNotifications
import AVFoundation
import WebKit
import os.log

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

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        window?.backgroundColor = .black
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {}
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {
        // Ferma il suono di allarme quando l'utente torna davvero dal background
        // NON viene chiamato per il ciclo resign/active del banner di notifica
        alarmPlayer?.stop()
        alarmPlayer = nil

        // Se il processo WebContent è stato killato da iOS (schermo bianco), ricarica
        if let vc = window?.rootViewController as? CAPBridgeViewController,
           let wv = vc.webView, wv.url == nil {
            wv.reload()
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
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
        os_log("GUARDROOM willPresent soundName=%{public}@ ud=%{public}@", type: .fault, soundName, ud == nil ? "nil" : "ok")

        let fileUrl = Bundle.main.url(forResource: soundName, withExtension: "wav")
        os_log("GUARDROOM willPresent fileUrl=%{public}@", type: .fault, fileUrl?.path ?? "NIL")

        if !soundName.isEmpty, let url = fileUrl {
            alarmPlayer?.stop()
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
                alarmPlayer = try AVAudioPlayer(contentsOf: url)
                alarmPlayer?.numberOfLoops = -1
                let ok = alarmPlayer?.play() ?? false
                os_log("GUARDROOM willPresent play ok=%{public}@", type: .fault, ok ? "true" : "false")
            } catch {
                os_log("GUARDROOM willPresent error=%{public}@", type: .fault, error.localizedDescription)
            }
            completionHandler([.banner, .badge])
        } else {
            os_log("GUARDROOM willPresent sound not found → system", type: .fault)
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
