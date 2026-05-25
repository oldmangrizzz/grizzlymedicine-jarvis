import SwiftUI

// Local copy of the canonical GMRI palette from JARVISMacCockpit/GMRITheme.swift.
enum GMRITheme { enum color { static let background = Color(red: 0.02, green: 0.023, blue: 0.025) } }

import WatchConnectivity
import WidgetKit

struct JARVISStatusEntry: TimelineEntry {
    let date: Date
    let state: String
}

struct JARVISStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> JARVISStatusEntry {
        JARVISStatusEntry(date: Date(), state: "idle")
    }

    func getSnapshot(in context: Context, completion: @escaping (JARVISStatusEntry) -> Void) {
        completion(JARVISStatusEntry(date: Date(), state: Self.currentState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JARVISStatusEntry>) -> Void) {
        let entry = JARVISStatusEntry(date: Date(), state: Self.currentState())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    private static func currentState() -> String {
        if WCSession.isSupported(),
           let state = WCSession.default.receivedApplicationContext["jarvis_state"] as? String,
           !state.isEmpty {
            return state
        }
        return UserDefaults.standard.string(forKey: "jarvis.watch.complication.state") ?? "idle"
    }
}

struct JARVISStatusComplicationView: View {
    var entry: JARVISStatusEntry

    var body: some View {
        Image(systemName: symbol)
            .widgetAccentable()
            .containerBackground(GMRITheme.color.background, for: .widget)
            .accessibilityLabel("JARVIS \(entry.state)")
    }

    private var symbol: String {
        switch entry.state {
        case "active": return "waveform.circle.fill"
        case "distress": return "heart.circle.fill"
        default: return "circle"
        }
    }
}

struct JARVISStatusComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JARVISStatusComplication", provider: JARVISStatusProvider()) { entry in
            JARVISStatusComplicationView(entry: entry)
        }
        .configurationDisplayName("JARVIS Status")
        .description("Quick glance JARVIS idle, active, or distress state.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

@main
struct JARVISWatchCompanionComplicationBundle: WidgetBundle {
    var body: some Widget {
        JARVISStatusComplication()
    }
}
