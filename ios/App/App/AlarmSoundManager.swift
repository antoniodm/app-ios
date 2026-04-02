import AVFoundation
import UserNotifications
import os.log

final class AlarmSoundManager: NSObject {
    static let shared = AlarmSoundManager()

    static let stopActionId = "STOP_ALARM"
    static let categoryId   = "ALARM_CATEGORY"

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?
    private var loopTimer: Timer?
    private var startedAt: Date?
    private var interruptionObserver: NSObjectProtocol?

    override private init() {
        super.init()
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
            player?.delegate = self
            player?.numberOfLoops = -1
            player?.prepareToPlay()
            player?.play()
            startedAt = Date()
            glog("avvio isPlaying=\(player?.isPlaying == true)")
        } catch {
            glog("errore player: \(error.localizedDescription)")
        }
        stopTimer?.invalidate()
        stopTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            self?.stop()
        }

        // Watchdog: se numberOfLoops=-1 non funziona o il player si ferma per qualsiasi motivo,
        // lo riavvia entro 1 secondo.
        loopTimer?.invalidate()
        loopTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.startedAt != nil else { return }
            if !(self.player?.isPlaying == true) {
                self.glog("loopWatchdog: player fermo, riavvio")
                try? AVAudioSession.sharedInstance().setActive(true)
                self.player?.currentTime = 0
                self.player?.play()
            }
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        loopTimer?.invalidate()
        loopTimer = nil
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

extension AlarmSoundManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Con numberOfLoops=-1 non dovrebbe mai arrivare qui; se arriva c'è un bug di piattaforma
        glog("audioPlayerDidFinishPlaying flag=\(flag) loops=\(player.numberOfLoops)")
        guard startedAt != nil else { return }
        // Fallback: rilancia manualmente il loop
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.startedAt != nil else { return }
            player.currentTime = 0
            player.play()
            self.glog("loop rilanciato via delegate")
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        glog("audioPlayerDecodeError: \(error?.localizedDescription ?? "?")")
    }

    func audioPlayerBeginInterruption(_ player: AVAudioPlayer) {
        glog("audioPlayerBeginInterruption")
    }

    func audioPlayerEndInterruption(_ player: AVAudioPlayer, withOptions flags: Int) {
        glog("audioPlayerEndInterruption flags=\(flags)")
        guard startedAt != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
    }
}
