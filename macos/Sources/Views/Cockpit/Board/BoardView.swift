import SwiftUI

/// THE ONE-PLACE FLEET BOARD — the native port of web/src/board/Board.tsx +
/// Lane.tsx, chunk B's public entry point. Renders ONLY from the arguments
/// below (no fetching/transport here — same rule as the web's contract.ts:
/// "the shell owns transport"). Reuses `FleetLaneRow` (FleetLanesView.swift,
/// Phase 1/2 chunk B — read-only from this chunk) for the identity/runway
/// header column instead of re-deriving avatar color, status-line, or
/// runway-bar logic a second time.
///
/// `selectedID` is a `Binding`, NOT board-internal `@State` the way
/// Board.tsx's `useState` is — contract.ts's own comment marks selection as
/// "board-internal" on the web, but the brief for this chunk asks for an
/// externally owned binding specifically so the Inspector (a separate,
/// later chunk) can read/drive it without editing this file. The
/// integrator (also a later chunk) owns the backing `@State`.
struct BoardView: View {
    let state: DaemonState
    let schedules: [Schedule]
    /// minutes since local midnight, ticking (the now-line + past wash).
    let nowMinutes: Int
    /// False when this build/licence cannot save a schedule — lanes then
    /// explain what a fresh window is instead of inviting a click the
    /// daemon must refuse.
    var canSchedule: Bool = true
    var onSwitch: (String) -> Void = { _ in }
    var onCreate: (String, Int, Int) -> Void = { _, _, _ in }
    var onMove: (String, Int, Int) -> Void = { _, _, _ in }
    var onDelete: (String) -> Void = { _ in }
    var onFullyBooked: (String) -> Void = { _ in }
    /// Rolling on/off or a one-tap start for an account (nil cancels it).
    var onPlan: (_ accountID: String, _ rolling: Bool, _ nextAt: Date?) -> Void = { _, _, _ in }
    /// Width of whatever the integrator lays over the board's trailing
    /// edge (the Inspector while a schedule is selected). Subtracted from
    /// the measured width before the track is derived, so the 24h axis
    /// always fits the part of the board a person can see (U3).
    var reservedTrailing: Double = 0
    @Binding var selectedID: String?

    private var scheduleInputs: [BoardClassify.ScheduleInput] {
        schedules.map { BoardClassify.ScheduleInput(id: $0.id, accountID: $0.accountID, hour: $0.hour, minute: $0.minute) }
    }

    /// Each lane's measured identity-column height: a lane is as tall as
    /// its track or its column, whichever is taller — a fixed height cut the
    /// last lane off once a column carried the pace line and the rolling
    /// switch.
    @State private var columnHeights: [String: Double] = [:]

    private func rowHeight(_ accountID: String) -> Double {
        max(BoardGeometry.rowPx, columnHeights[accountID] ?? BoardGeometry.rowPx)
    }

    private var totalHeight: Double {
        let dividers = Double(max(0, state.accounts.count - 1))
        return 30 + state.accounts.reduce(0) { $0 + rowHeight($1.id) } + dividers
    }

    var body: some View {
        if state.accounts.isEmpty {
            Text("No accounts added yet — nothing here is scheduled.")
                .font(.system(size: 12.5))
                .foregroundColor(CockpitTheme.ter)
                .padding(32)
        } else {
            let inputs = scheduleInputs
            // F16 (fresh-user audit 2026-08-16): the row used to be a FIXED
            // headerPx+trackPx (1400pt) laid out inside a horizontal
            // ScrollView — at any cockpit width narrower than that the day
            // clipped at the right edge with no visible scroll hint. A
            // GeometryReader here measures the board's own available width
            // every render and derives a fluid track width from it
            // (BoardGeometry.trackWidth(forAvailable:)); every descendant
            // (BoardAxis, BoardNowLine, each lane's BoardTrackView and its
            // pieces) reads that live width back out through the
            // `boardTrackPx` environment value instead of the old fixed
            // `BoardGeometry.trackPx` constant, so the whole row always
            // fills — and never overflows — its container. See
            // NativeBoardSection.swift for the ScrollView this replaced.
            GeometryReader { proxy in
                let trackPx = BoardGeometry.trackWidth(forAvailable: proxy.size.width, reservedTrailing: reservedTrailing)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        BoardAxis()
                        ForEach(state.accounts) { account in
                            laneRow(account: account, inputs: inputs)
                            if account.id != state.accounts.last?.id {
                                Divider().overlay(CockpitTheme.hairSoft)
                            }
                        }
                    }
                    BoardNowLine(nowMinutes: nowMinutes, totalHeight: totalHeight)
                }
                .frame(width: BoardGeometry.headerPx + trackPx, height: totalHeight, alignment: .topLeading)
                .environment(\.boardTrackPx, trackPx)
                .onPreferenceChange(LaneColumnHeightKey.self) { columnHeights = $0 }
            }
            .frame(height: totalHeight)
            .background(CockpitTheme.win)
            .clipped()
        }
    }

    @ViewBuilder
    private func laneRow(account: AccountState, inputs: [BoardClassify.ScheduleInput]) -> some View {
        let sched = BoardClassify.laneSchedules(schedules: inputs, accountID: account.id)
        let mid = Self.midWindowFor(account)
        let plan = state.windowPlans.first { $0.accountID == account.id }
        let rolling = plan?.rolling == true
        // No 5-hour limit (verified accounts on some plans): no window to
        // schedule, start or roll — only the weekly limit.
        let noFive = account.noFiveHourLimit
        HStack(alignment: .top, spacing: 0) {
            FleetLaneRow(
                account: account, active: account.id == state.activeID, nowMinutes: nowMinutes, onSwitch: onSwitch,
                // Shown while a plan exists even without Pro: what was set up
                // can always be switched off.
                plan: plan,
                planEnabled: (canSchedule && !noFive) || plan?.rolling == true || plan?.nextAt != nil,
                hasDailyTimes: !sched.isEmpty,
                onPlan: { rolling, nextAt in onPlan(account.id, rolling, nextAt) })
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in
                    Color.clear.preference(key: LaneColumnHeightKey.self, value: [account.id: g.size.height])
                })
                .frame(width: BoardGeometry.headerPx, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CockpitTheme.hairSoft).frame(width: 1)
                }

            BoardTrackView(
                accountID: account.id,
                accountLabel: account.label,
                // A rolling account's fixed times are paused: off the track,
                // and the track books nothing new while it rolls.
                schedules: rolling || noFive ? [] : sched,
                mid: mid,
                nowMinutes: nowMinutes,
                selectedID: selectedID,
                canSchedule: canSchedule && !rolling && !noFive,
                onSelect: { selectedID = $0 },
                onCreate: { hour, minute in onCreate(account.id, hour, minute) },
                onMove: onMove,
                onDelete: { id in
                    if id == selectedID { selectedID = nil }
                    onDelete(id)
                },
                onFullyBooked: onFullyBooked,
                rollingStarts: rolling && !noFive
                    ? RollingChain.starts(
                        reset: account.snapshot?.buckets.first { $0.kind == "session" || $0.kind == "five_hour" }?.resetsAt,
                        now: Date())
                    : [],
                emptyNote: noFive ? Self.noFiveNote(dailyTimes: sched.count) : nil,
                noBooking: Self.noBookingReason(label: account.label, rolling: rolling, noFive: noFive),
                noteAction: noFive && !sched.isEmpty
                    ? (label: sched.count == 1 ? "Remove it" : "Remove them",
                       run: { for s in sched { onDelete(s.schedule.id) } })
                    : nil
            )
        }
        .frame(height: rowHeight(account.id), alignment: .top)
    }

    /// web/src/board/Board.tsx `midWindowFor`: the lane's currently-active
    /// session window, if any. `BoardTime.minutesOfDay` (Support/, Phase
    /// 1/2) already ports `severity.ts`'s local-wall-clock read; bridged
    /// via `boardTimeISOString` (FleetLanesView.swift) the same way that
    /// file's own status-line derivation does.
    static func midWindow(for account: AccountState) -> BoardClassify.MidWindow? {
        midWindowFor(account)
    }

    /// Why a lane books nothing (its clicks do nothing; VoiceOver's book
    /// action says this), or nil where it books — a lane without Pro books
    /// too: the daemon's answer is the Pro offer.
    static func noBookingReason(label: String, rolling: Bool, noFive: Bool) -> String? {
        if noFive {
            return "\(label) has no 5-hour limit, so there's no window to start — only the weekly limit applies."
        }
        if rolling {
            return "\(label) keeps its windows rolling — switch that off to set daily times."
        }
        return nil
    }

    /// The track's note on an account with no 5-hour limit. Its daily times
    /// are kept off the track (they draw windows that never come), so the
    /// note counts them — beside the button that removes them.
    static func noFiveNote(dailyTimes: Int) -> String {
        switch dailyTimes {
        case 0: return "No 5-hour limit on this account — nothing to schedule"
        case 1: return "No 5-hour limit on this account — its daily time is skipped"
        default: return "No 5-hour limit on this account — its \(dailyTimes) daily times are skipped"
        }
    }

    private static func midWindowFor(_ account: AccountState) -> BoardClassify.MidWindow? {
        guard
            let session = account.snapshot?.buckets.first(where: { ($0.kind == "session" || $0.kind == "five_hour") }),
            session.active == true,
            let resetsAt = session.resetsAt
        else { return nil }
        let end = BoardTime.minutesOfDay(boardTimeISOString(from: resetsAt))
        let windowMin = BoardSchedule.windowHours * 60
        let start = (end - windowMin + BoardSchedule.dayMin) % BoardSchedule.dayMin
        return BoardClassify.MidWindow(start: start, end: end)
    }
}

/// Each lane's identity-column height, keyed by account (BoardView sizes the
/// lane to fit it).
private struct LaneColumnHeightKey: PreferenceKey {
    static var defaultValue: [String: Double] = [:]
    static func reduce(value: inout [String: Double], nextValue: () -> [String: Double]) {
        value.merge(nextValue()) { $1 }
    }
}
