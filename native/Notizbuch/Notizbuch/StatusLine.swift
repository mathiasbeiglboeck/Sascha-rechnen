import Network
import SwiftUI
import UIKit

/// Am iPad steht im Editor statt der Statusleiste des Systems eine eigene Zeile: links Uhrzeit und Datum, rechts WLAN
/// und Akku, dazwischen die Tabs (Wunsch 19.11.). In die Statusleiste des Systems lassen sich die Tabs nicht setzen:
/// Ein Tippen dort gehört iPadOS (es scrollt nach oben), die Tabs würden nicht reagieren. Seit dem Wunsch vom 25.11.
/// führt ein Tippen auf die Uhrzeit zu den Notizbüchern, auf das Datum blendet es die Leiste aus und ein, auf WLAN und
/// Akku wechselt es zwischen Stift und Radierer (siehe EditorView).
struct StatusLine: View {
    /// Höhe der Zeile: Die Statusleiste des Systems ist am iPad 24 Punkte hoch, die Tabs brauchen 26
    static let height: CGFloat = 28

    @ObservedObject var tabs: TabsModel
    /// Tabs zeigen (nicht bei eingeklappter Leiste)
    let showTabs: Bool
    @ObservedObject var device = DeviceStatus.shared
    /// Antippen der Uhrzeit, des Datums, von WLAN und Akku (nil: nichts, etwa über der Seitenübersicht)
    var onClock: (() -> Void)? = nil
    var onDate: (() -> Void)? = nil
    var onDevice: (() -> Void)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Abstand zum Rand links und rechts
    private static let edge: CGFloat = 20

    var body: some View {
        row
            .font(.system(size: 14))
            .padding(.horizontal, Self.edge)
            .frame(height: Self.height)
    }

    @ViewBuilder private var row: some View {
        let line = HStack(spacing: 12) {
            // Waagrecht so breit wie der Inhalt, senkrecht über die ganze Zeile: Dort nehmen Uhrzeit und Datum das
            // Tippen an
            clock.fixedSize(horizontal: true, vertical: false)
            ZStack {
                if showTabs {
                    TabStrip(tabs: tabs)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            // Die Fläche zum Tippen reicht bis an den Rand, die Zeichnung bleibt, wo sie ist
            deviceState.fixedSize()
                .padding(.trailing, Self.edge)
                .tappable(onDevice, hint: "Stift oder Radierer")
                .padding(.trailing, -Self.edge)
        }
        if #available(iOS 26, *) {
            // Im Fenster sitzen links oben die Fensterknöpfe von iPadOS: Die Zeile beginnt dann rechts davon und wird
            // entsprechend schmaler; ohne Knöpfe bleibt alles, wo es ist
            line.containerCornerOffset(.leading, sizeToFit: true)
        } else {
            line
        }
    }

    /// Im schmalen Fenster nur die Uhrzeit, damit für die Tabs Platz bleibt; ohne Tabs (etwa bei mit dem Datum
    /// ausgeblendeter Leiste) auch dort das Datum, sonst käme die Leiste dort nicht mehr zurück
    private var showDate: Bool { sizeClass != .compact || !showTabs }

    private var clock: some View {
        TimelineView(.everyMinute) { context in
            // Zwischen Uhrzeit und Datum 6 Punkte, je zur Hälfte Fläche zum Tippen der beiden. Die Fläche der Uhrzeit
            // reicht bis an den Rand, die Zeichnung bleibt, wo sie ist
            HStack(spacing: 0) {
                Text(context.date, format: .dateTime.hour().minute())
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .padding(.trailing, showDate ? 3 : 0)
                    .padding(.leading, Self.edge)
                    .tappable(onClock, hint: "Zu den Notizbüchern")
                    .padding(.leading, -Self.edge)
                if showDate {
                    Text(Self.day.string(from: context.date))
                        .padding(.leading, 3)
                        .tappable(onDate, hint: "Leiste aus- oder einblenden")
                }
            }
        }
    }

    /// Wie in der Statusleiste des Systems: „Do. 19. Nov.“ (die übliche Vorlage gäbe „Do., 19. Nov.“)
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        if Locale.current.language.languageCode == .german {
            formatter.dateFormat = "EEE d. MMM"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("EEEdMMM")
        }
        return formatter
    }()

    private var deviceState: some View {
        HStack(spacing: 5) {
            if let wifi = device.wifi {
                Image(systemName: wifi ? "wifi" : "wifi.slash")
                    .accessibilityLabel(wifi ? "WLAN" : "Keine Verbindung")
            }
            if let level = device.batteryLevel {
                Text(level, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                Image(systemName: device.batterySymbol)
                    .foregroundStyle(device.batteryLow ? Color.red : Color.primary)
            }
        }
        .fontWeight(.semibold)
    }
}

private extension View {
    /// Nimmt das Tippen auf der ganzen Höhe der Zeile an; ohne Aktion bleibt alles, wie es ist
    @ViewBuilder func tappable(_ action: (() -> Void)?, hint: String) -> some View {
        if let action {
            frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(hint)
        } else {
            self
        }
    }
}

/// Ladestand und Verbindung für die eigene Zeile am iPad. Eine Instanz für die ganze App: Sie lebt, solange die App
/// läuft, und wird erst angelegt, wenn die Zeile zum ersten Mal erscheint
@MainActor
final class DeviceStatus: ObservableObject {
    static let shared = DeviceStatus()

    /// Ladestand 0 … 1; nil, wenn unbekannt (Simulator)
    @Published private(set) var batteryLevel: Double?
    @Published private(set) var charging = false
    /// true: über WLAN verbunden, false: keine Verbindung, nil: anders verbunden oder noch unbekannt
    @Published private(set) var wifi: Bool?

    private let monitor = NWPathMonitor()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        readBattery()
        // Beides kommt auf dem Hauptthread an: UIKit meldet den Akku dort, der Netzwächter läuft auf .main
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            _ = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.readBattery() }
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let state: Bool? = path.status != .satisfied ? false : (path.usesInterfaceType(.wifi) ? true : nil)
            MainActor.assumeIsolated { self?.wifi = state }
        }
        monitor.start(queue: .main)
    }

    private func readBattery() {
        let device = UIDevice.current
        // Auf ganze Prozent: 20 % als Float wäre als Double etwas mehr als 0,2 und damit noch nicht rot
        batteryLevel = device.batteryLevel < 0 ? nil : (Double(device.batteryLevel) * 100).rounded() / 100
        charging = device.batteryState == .charging || device.batteryState == .full
    }

    var batterySymbol: String {
        if charging { return "battery.100percent.bolt" }
        switch batteryLevel ?? 1 {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Wie in der Statusleiste des Systems: rot bei 20 Prozent und weniger, solange er nicht lädt
    var batteryLow: Bool { !charging && (batteryLevel ?? 1) <= 0.2 }
}
