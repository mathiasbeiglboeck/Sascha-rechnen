import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Im Stromsparmodus sperrt iOS den Bildschirm schon nach 30 Sekunden. Solange die App vorne ist, hält sie ihn dann
/// wach, bis 7 Minuten lang niemand den Bildschirm berührt hat; danach übernimmt wieder iOS und dunkelt wie gewohnt ab
/// (Wunsch 19.11.). Ohne Stromsparmodus bleibt die eigene Einstellung (Automatische Sperre) unangetastet.
@MainActor
final class KeepAwake: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeepAwake()

    /// So lange nach der letzten Berührung bleibt der Bildschirm an
    private var idleTime: TimeInterval = 7 * 60
    /// Die App ist vorne
    private var active = false
    /// Zeitpunkt der letzten Berührung (Systemlaufzeit, läuft nicht rückwärts)
    private var lastTouch: TimeInterval = 0
    /// Prüft, ob die Frist um ist; läuft nur, solange die App den Bildschirm wach hält
    private var timer: Timer?
    #if DEBUG
    /// Nur für Tests im Simulator, der keinen Stromsparmodus kennt (debug/awake?lowpower=1)
    private var lowPowerOverride: Bool?
    #endif

    private override init() {
        super.init()
        // Kommt auf einem beliebigen Thread; ausgewertet wird auf dem Hauptthread
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerStateChanged() }
        }
    }

    private var lowPower: Bool {
        #if DEBUG
        if let lowPowerOverride { return lowPowerOverride }
        #endif
        return ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Die App kommt nach vorne oder geht weg. Nach vorne kommen zählt wie eine Berührung (Entsperren, App-Wechsel)
    func scene(active: Bool) {
        self.active = active
        if active {
            watchTouches()
            touched()
        } else {
            release()
        }
    }

    /// Eine Berührung irgendwo in der App: Frist beginnt neu. Kostet nur einen Zeitstempel; der Timer läuft schon
    fileprivate func touched() {
        lastTouch = now
        guard active, lowPower else { return release() }
        if !UIApplication.shared.isIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = true
            debugLog("an")
        }
        if timer == nil { check(after: idleTime) }
    }

    private func check(after seconds: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: max(seconds, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
    }

    private func expire() {
        timer = nil
        let left = lastTouch + idleTime - now
        if active, lowPower, left > 1 {
            check(after: left)
        } else {
            release()
        }
    }

    /// iOS übernimmt wieder: Es dunkelt nach seiner eigenen Frist ab (im Stromsparmodus nach 30 Sekunden)
    private func release() {
        timer?.invalidate()
        timer = nil
        if UIApplication.shared.isIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = false
            debugLog("aus")
        }
    }

    private func powerStateChanged() {
        // Stromsparmodus eben eingeschaltet (im Kontrollzentrum, also eine Berührung): Frist ab jetzt
        if active && lowPower { touched() } else { release() }
    }

    /// Ein Beobachter je Fenster der App, der jede Berührung meldet, ohne mitzuspielen
    private func watchTouches() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchWatcher }) {
                let watcher = TouchWatcher(target: nil, action: nil)
                watcher.delegate = self
                window.addGestureRecognizer(watcher)
            }
        }
    }

    // Der Beobachter steht nie einer anderen Geste im Weg
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    private func debugLog(_ state: String) {
        #if DEBUG
        NSLog("Link-Debug: Wach: Sperre %@ (Stromsparen %@, Frist %.0f s)", state == "an" ? "ausgesetzt" : "wieder an",
              lowPower ? "true" : "false", idleTime)
        #endif
    }

    #if DEBUG
    /// debug/awake?lowpower=1|0|auto&seconds=N: Stromsparmodus vortäuschen, Frist verkürzen, Stand melden
    func debug(lowPower value: String?, seconds: Double?) {
        switch value {
        case "1"?: lowPowerOverride = true
        case "0"?: lowPowerOverride = false
        case "auto"?: lowPowerOverride = nil
        default: break
        }
        if let seconds { idleTime = max(seconds, 2) }
        timer?.invalidate()
        timer = nil
        touched()
        let left = UIApplication.shared.isIdleTimerDisabled ? max(lastTouch + idleTime - now, 0) : 0
        NSLog("Link-Debug: Wach: Stromsparen %@, Sperre ausgesetzt %@, Frist %.0f s, noch %.0f s",
              lowPower ? "true" : "false", UIApplication.shared.isIdleTimerDisabled ? "true" : "false", idleTime, left)
    }
    #endif
}

/// Meldet jeden Beginn einer Berührung (Finger, Pencil) und schlägt sofort fehl: hält nichts auf, verzögert nichts,
/// bricht nichts ab. Ein langer Strich zählt so ab seinem Beginn
private final class TouchWatcher: UIGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        KeepAwake.shared.touched()
        state = .failed
    }
}
