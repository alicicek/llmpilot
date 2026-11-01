import SwiftUI

// The fleet's activity: what the autopilot and the nudges did, newest first.
// Collapsed by default under one quiet "Activity" row, like History — it is
// a record to look back at, not something to watch. Open, each line is a
// time and a plain sentence; only a failure carries a mark. The daemon sends
// the last 20 events (internal/daemon/daemon.go).

/// Newest-first, capped at `limit`. Pure so the ordering/cap rule is
/// independently testable without a view.
func orderedEvents(_ events: [DaemonEvent], limit: Int = 50) -> [DaemonEvent] {
    Array(events.sorted { $0.at > $1.at }.prefix(limit))
}

/// One line of the feed: the newest of a run of identical events, and how
/// many there were.
struct ActivityRow: Equatable {
    let event: DaemonEvent
    let count: Int
}

enum Activity {
    /// Plumbing, not history: re-aiming the Mac's wake. Daemons before 1.6.0
    /// wrote one per schedule edit, and those lines stay in the log.
    static let hiddenKinds: Set<String> = ["wake_armed", "wake"]

    static func isFailure(_ e: DaemonEvent) -> Bool { e.kind.hasSuffix("_failed") }

    /// The feed's lines: plumbing dropped, newest first, and back-to-back
    /// repeats of the same event folded into one line with a count.
    static func rows(_ events: [DaemonEvent]) -> [ActivityRow] {
        var out: [ActivityRow] = []
        for e in orderedEvents(events.filter { !hiddenKinds.contains($0.kind) }) {
            if let last = out.last, last.event.kind == e.kind,
               last.event.accountID == e.accountID, last.event.message == e.message {
                out[out.count - 1] = ActivityRow(event: last.event, count: last.count + 1)
            } else {
                out.append(ActivityRow(event: e, count: 1))
            }
        }
        return out
    }

    /// Failures since local midnight — the one thing the collapsed row says.
    static func failedToday(_ events: [DaemonEvent], now: Date = Date(), calendar: Calendar = .current) -> Int {
        events.filter { isFailure($0) && calendar.isDate($0.at, inSameDayAs: now) }.count
    }
}

struct EventsFeedView: View {
    let events: [DaemonEvent]
    /// `DaemonState.version` — nil from a daemon too old to report it, in
    /// which case the footer is omitted rather than shown blank.
    let version: String?

    @AppStorage("activityOpen") private var open = false

    private var rows: [ActivityRow] { Activity.rows(events) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if open {
                list
            }
        }
    }

    // Same row as History's header (HistorySectionView), so the two read as
    // one family at the foot of the cockpit.
    private var header: some View {
        let failed = Activity.failedToday(events)
        return Button(action: { open.toggle() }) {
            HStack(spacing: 8) {
                Text(open ? "▼" : "▶")
                    .font(.system(size: 9))
                Text("Activity")
                    .font(.system(size: 11.5, weight: .semibold))
                if failed > 0 {
                    Text("\(failed) failed today")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundColor(CockpitTheme.warn)
                }
            }
            .foregroundColor(CockpitTheme.sec)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Divider().overlay(CockpitTheme.hair) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(failed > 0 ? "Activity, \(failed) failed today" : "Activity")
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                // "switched", never "rotation", in user-facing copy
                // (VOICE.md vocabulary, owner 2026-07-11).
                Text("Nothing yet — switches and fresh windows show up here.")
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.ter)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    ActivityLine(row: row)
                }
            }
            if let version, !version.isEmpty {
                Text("daemon v\(version)")
                    .font(CockpitTheme.numeric(9.5))
                    .foregroundColor(CockpitTheme.ter)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

private struct ActivityLine: View {
    let row: ActivityRow

    private var failed: Bool { Activity.isFailure(row.event) }

    /// The sentence, then its quiet asides on the same line: how many times
    /// it repeated, and whether it ran late (the Mac was asleep at its time).
    private var text: Text {
        var t = Text(row.event.message).foregroundColor(CockpitTheme.text)
        if row.count > 1 {
            t = t + Text(" · ×\(row.count)").foregroundColor(CockpitTheme.ter)
        }
        if row.event.late == true {
            t = t + Text(" · ran late").foregroundColor(CockpitTheme.ter)
        }
        return t
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(BoardTime.fmtHMFromIso(boardTimeISOString(from: row.event.at)))
                .font(CockpitTheme.numeric(10.5))
                .foregroundColor(CockpitTheme.ter)
                .frame(width: 36, alignment: .leading)
            Circle()
                .fill(failed ? CockpitTheme.warn : Color.clear)
                .frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1.5 }
                .accessibilityHidden(true)
            text
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        // One VO stop per line, in reading order; the mark is said as a word.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts = [BoardTime.fmtHMFromIso(boardTimeISOString(from: row.event.at))]
        if failed { parts.append("failed") }
        parts.append(row.event.message)
        if row.count > 1 { parts.append("\(row.count) times") }
        if row.event.late == true { parts.append("ran late") }
        return parts.joined(separator: ", ")
    }
}

#Preview("Activity — open") {
    EventsFeedView(
        events: [
            DaemonEvent.previewStub(at: Date(), kind: "switch", message: "Switched to ada — kai rests until 16:05"),
            DaemonEvent.previewStub(
                at: Date().addingTimeInterval(-3600), kind: "trigger",
                message: "06:15 nudge opened a fresh window on ada · resets 11:15", late: true
            ),
            DaemonEvent.previewStub(
                at: Date().addingTimeInterval(-7200), kind: "trigger_failed",
                message: "01:15 nudge failed on kai — no Claude Code installation found on this Mac"
            ),
        ],
        version: "1.6.1"
    )
    .frame(width: 520)
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
