import AVFoundation
import UserNotifications
import os.log

final class AlarmSoundManager {
    static let shared = AlarmSoundManager()

    static let stopActionId  = "STOP_ALARM"
    static let categoryId    = "ALARM_CATEGORY"

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?

    private init() {}

    func registerNotificationCategory() {
        let stopAction = UNNotificationAction(
            identifier: AlarmSoundManager.stopActionId,
            title: "Ferma allarme",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: AlarmSoundManager.categoryId,
            actions: [stopAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func start() {
        guard player?.isPlaying != true else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            glog("AVAudioSession error: \(error.localizedDescription)")
        }
        guard let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") else {
            glog("alarm.wav non trovato")
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.play()
            glog("avvio")
        } catch {
            glog("errore player: \(error.localizedDescription)")
        }
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        guard player?.isPlaying == true else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        glog("stop")
    }

    var isPlaying: Bool { player?.isPlaying == true }

    private func glog(_ msg: String) {
        os_log("GUARDROOM AlarmSoundManager %{public}@", type: .fault, msg)
    }
}
