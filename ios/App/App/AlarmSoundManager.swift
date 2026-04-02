import AVFoundation
import UserNotifications
import os.log

final class AlarmSoundManager {
    static let shared = AlarmSoundManager()

    static let stopActionId = "STOP_ALARM"
    static let categoryId   = "ALARM_CATEGORY"

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var startedAt: Date?
    private var interruptionObserver: NSObjectProtocol?

    private init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .ended, self.startedAt != nil {
                // Ripristina la sessione e rilancia il loop dopo l'interruzione
                try? AVAudioSession.sharedInstance().setActive(true)
                self.player?.play()
                self.glog("resume dopo interruzione")
            }
        }
    }

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
            startedAt = Date()
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
        startedAt = nil
        guard player?.isPlaying == true else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        glog("stop")
    }

    var isPlaying: Bool { player?.isPlaying == true }

    /// Secondi trascorsi dall'avvio (0 se non in riproduzione)
    var secondsSinceStart: TimeInterval {
        guard let s = startedAt else { return 0 }
        return Date().timeIntervalSince(s)
    }

    private func glog(_ msg: String) {
        os_log("GUARDROOM AlarmSoundManager %{public}@", type: .fault, msg)
    }
}
