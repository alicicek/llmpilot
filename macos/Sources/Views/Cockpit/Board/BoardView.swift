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
    @Binding var selectedID: String?

    private var scheduleInputs: [BoardClassify.ScheduleInput] {
        schedules.map { BoardClassify.ScheduleInput(id: $0.id, accountID: $0.accountID, hour: $0.hour, minute: $0.minute) }
    }

    private var totalHeight: Double {
        30 + Double(state.accounts.count) * BoardGeometry.rowPx
    }

    var body: some View {
        if state.accounts.isEmpty {
            Text("No accounts added yet — nothing here is scheduled.")
                .font(.system(size: 12.5))
                .foregroundColor(CockpitTheme.ter)
                .padding(32)
        } else {
            let inputs = scheduleInputs
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
            .frame(width: BoardGeometry.headerPx + BoardGeometry.trackPx, alignment: .topLeading)
            .background(CockpitTheme.win)
            .clipped()
        }
    }

    @ViewBuilder
    private func laneRow(account: AccountState, inputs: [BoardClassify.ScheduleInput]) -> some View {
        let sched = BoardClassify.laneSchedules(schedules: inputs, accountID: account.id)
        let mid = Self.midWindowFor(account)
        HStack(alignment: .top, spacing: 0) {
            FleetLaneRow(account: account, active: account.id == state.activeID, nowMinutes: nowMinutes, onSwitch: onSwitch)
                .frame(width: BoardGeometry.headerPx, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CockpitTheme.hairSoft).frame(width: 1)
                }

            BoardTrackView(
                accountID: account.id,
                accountLabel: account.label,
                schedules: sched,
                mid: mid,
                nowMinutes: nowMinutes,
                selectedID: selectedID,
                canSchedule: canSchedule,
                onSelect: { selectedID = $0 },
                onCreate: { hour, minute in onCreate(account.id, hour, minute) },
                onMove: onMove,
                onDelete: { id in
                    if id == selectedID { selectedID = nil }
                    onDelete(id)
                },
                onFullyBooked: onFullyBooked
            )
        }
    }

    /// web/src/board/Board.tsx `midWindowFor`: the lane's currently-active
    /// session window, if any. `BoardTime.minutesOfDay` (Support/, Phase
    /// 1/2) already ports `severity.ts`'s local-wall-clock read; bridged
    /// via `boardTimeISOString` (FleetLanesView.swift) the same way that
    /// file's own status-line derivation does.
    static func midWindow(for account: AccountState) -> BoardClassify.MidWindow? {
        midWindowFor(account)
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
