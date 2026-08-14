import SwiftUI

// Native-only events feed — the web never rendered `DaemonState.events`
// (web/src/App.tsx:290 only counts them for the guided-tour gate); this is
// new, plan-ordered surface for the native cockpit. Newest first, capped at
// 50, with a quiet empty state and a "daemon vX" version footer.

/// Newest-first, capped at `limit`. Pure so the ordering/cap rule is
/// independently testable without a view.
func orderedEvents(_ events: [DaemonEvent], limit: Int = 50) -> [DaemonEvent] {
    Array(events.sorted { $0.at > $1.at }.prefix(limit))
}

struct EventsFeedView: View {
    let events: [DaemonEvent]
    /// `DaemonState.version` — nil from a daemon too old to report it, in
    /// which case the footer is omitted rather than shown blank.
    let version: String?

    private var ordered: [DaemonEvent] { orderedEvents(events) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if ordered.isEmpty {
                // "switched", never "rotation", in user-facing copy
                // (VOICE.md vocabulary, owner 2026-07-11).
                Text("No events yet — switches will show up here.")
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.ter)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { idx, event in
                        EventRow(event: event)
                        if idx != ordered.count - 1 {
                            Divider().overlay(CockpitTheme.hairSoft)
                        }
                    }
                }
            }
            if let version, !version.isEmpty {
                Text("daemon v\(version)")
                    .font(CockpitTheme.numeric(9.5))
                    .foregroundColor(CockpitTheme.ter)
                    .padding(.top, 4)
            }
        }
    }
}

private struct EventRow: View {
    let event: DaemonEvent

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(BoardTime.fmtHMFromIso(boardTimeISOString(from: event.at)))
                .font(CockpitTheme.numeric(10.5))
                .foregroundColor(CockpitTheme.ter)
                .frame(width: 36, alignment: .leading)

            Text(event.kind)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(CockpitTheme.chipBg))
                .overlay(Capsule().stroke(CockpitTheme.chipBd, lineWidth: 1))
                .foregroundColor(CockpitTheme.accTx)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.message)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.text)
                if event.late == true {
                    Text("ran late")
                        .font(.system(size: 9.5))
                        .foregroundColor(CockpitTheme.warn)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        // One VO stop per event, in reading order (time, kind, message,
        // late flag) rather than four separate unlabeled Text stops.
        .accessibilityElement(children: .combine)
    }
}

#Preview("Events feed") {
    EventsFeedView(
        events: [
            DaemonEvent.previewStub(at: Date(), kind: "switch", message: "Switched to ada@example.com"),
            DaemonEvent.previewStub(
                at: Date().addingTimeInterval(-3600), kind: "rotate",
                message: "Rotated to next scheduled window", late: true
            ),
            DaemonEvent.previewStub(
                at: Date().addingTimeInterval(-7200), kind: "adopt", message: "Adopted a kept sign-in"
            ),
        ],
        version: "1.4.0"
    )
    .frame(width: 360)
    .padding()
}

#Preview("Events feed — empty") {
    EventsFeedView(events: [], version: nil)
        .frame(width: 360)
        .padding()
}

private extension DaemonEvent {
    static func previewStub(at: Date, kind: String, message: String, late: Bool = false) -> DaemonEvent {
        let json = """
        {"at":"\(ISO8601DateFormatter().string(from: at))","kind":"\(kind)","message":"\(message)","late":\(late)}
        """
        return try! DaemonDates.decoder().decode(DaemonEvent.self, from: json.data(using: .utf8)!)
    }
}
