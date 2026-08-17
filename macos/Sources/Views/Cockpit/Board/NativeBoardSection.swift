import SwiftUI

/// Phase-3 integration: the full scheduler board section for the native
/// cockpit — BoardView (lanes + tracks) with the Inspector slide-over, the
/// pro offer card, the schedule flash, and the Fresh-window menu's data
/// plumbing. Mirrors web App.tsx's wiring: actions route through
/// ScheduleActions (402 pro codes → offer card, everything else → flash),
/// selection is owned here and the Inspector derives everything else from
/// the same pure helpers the chips use.
struct NativeBoardSection: View {
    @ObservedObject var fleet: FleetViewModel
    @ObservedObject var actions: ScheduleActions
    let state: DaemonState
    let nowMinutes: Int
    /// Phase 4 wires the native paywall; until then the CTA opens the web
    /// cockpit (the plan's stated interim recommendation).
    let onProCTA: () -> Void

    @State private var selectedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let offer = actions.offer {
                ProOfferCard(
                    message: offer.message,
                    showCTA: offer.code == "pro_required",
                    code: offer.code,
                    onCTA: {
                        // App.tsx:462-465: the CTA dismisses the offer
                        // BEFORE opening the paywall — the banner must not
                        // stay pinned above the board afterwards.
                        actions.dismissOffer()
                        onProCTA()
                    },
                    onDismiss: { actions.dismissOffer() })
            }
            if let flash = actions.flash {
                FlashBanner(message: flash, onDismiss: { actions.dismissFlash() })
            }
            ZStack(alignment: .trailing) {
                // F16 (fresh-user audit 2026-08-16): the board row used to
                // be a FIXED headerPx+trackPx (1400pt) wider than the
                // default 1180pt window, scrolled horizontally so nothing
                // was unreachable — but macOS hides scroll indicators until
                // a trackpad scroll, so at any width under 1400pt the day
                // clipped with no visible hint. BoardView now derives its
                // track width from this section's own live width (see its
                // GeometryReader), so it always fills — and never
                // overflows — the space given to it; no horizontal
                // ScrollView is needed as a result.
                BoardView(
                    state: state,
                    schedules: state.schedules,
                    nowMinutes: nowMinutes,
                    canSchedule: state.licensed,
                    onSwitch: { id in Task { await fleet.switchTo(id) } },
                    onCreate: { accountID, hour, minute in
                        Task { _ = await actions.create(accountID: accountID, hour: hour, minute: minute) }
                    },
                    onMove: { id, hour, minute in
                        Task { _ = await actions.move(id: id, hour: hour, minute: minute) }
                    },
                    onDelete: { id in
                        selectedID = nil
                        Task { await actions.delete(id: id) }
                    },
                    onFullyBooked: { actions.flashLocal($0) },
                    selectedID: $selectedID)

                if let sel = selectedInspector {
                    BoardInspector(
                        email: sel.email,
                        ls: sel.ls,
                        cls: sel.cls,
                        mid: sel.mid,
                        nowMinutes: nowMinutes,
                        chainTarget: sel.chainTarget,
                        onChain: {
                            // "Chain at HH:MM — guaranteed": the new reset is
                            // chainTarget+WINDOW, i.e. the trigger lands
                            // exactly on the previous block's reset.
                            if let t = sel.chainTarget {
                                Task { _ = await actions.move(id: sel.ls.schedule.id, hour: t / 60, minute: t % 60) }
                            }
                        },
                        onDelete: {
                            let id = sel.ls.schedule.id
                            selectedID = nil
                            Task { await actions.delete(id: id) }
                        },
                        onClose: { selectedID = nil },
                        onNudge: { delta in
                            // Same physics as the drag: clampMove decides;
                            // a wall means no commit (the web keyboard path
                            // silently clamps the same way).
                            var next = sel.laneResets
                            next[sel.laneIndex] = ((sel.laneResets[sel.laneIndex] + delta) % 1440 + 1440) % 1440
                            guard let out = BoardClamp.clampMove(prev: sel.laneResets, next: next, floor: sel.floor) else { return }
                            let newReset = out.values[sel.laneIndex]
                            guard newReset != sel.ls.reset else {
                                // Same standard as the VO book action: a
                                // silent refusal is undiagnosable — say why.
                                actions.flashLocal("That nudge lands inside a forbidden zone — resets must sit ≥ 5 h 15 min apart.")
                                return
                            }
                            let t = ((newReset - BoardSchedule.windowHours * 60) % 1440 + 1440) % 1440
                            Task { _ = await actions.move(id: sel.ls.schedule.id, hour: t / 60, minute: t % 60) }
                        })
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }

    private struct SelectedInspector {
        let email: String
        let ls: BoardClassify.LaneSchedule
        let cls: BoardClassify.ChipClass
        let mid: BoardClassify.MidWindow?
        let chainTarget: Int?
        /// The whole lane's resets (sorted) + this schedule's index + the
        /// lane floor — the nudge must run the SAME clamp physics the drag
        /// does, or one click at a time walks a chip through the 5h15m
        /// exclusion zones the daemon's spacing contract forbids.
        let laneResets: [Int]
        let laneIndex: Int
        let floor: Int
    }

    /// Board.tsx `findSelected`: walk lanes, find the schedule, derive its
    /// classification against the lane's mid-window, and the reset-order
    /// PREVIOUS schedule's reset as the chain target (nil for a lone
    /// schedule).
    private var selectedInspector: SelectedInspector? {
        guard let selectedID else { return nil }
        let inputs = state.schedules.map {
            BoardClassify.ScheduleInput(id: $0.id, accountID: $0.accountID, hour: $0.hour, minute: $0.minute)
        }
        for account in state.accounts {
            let lane = BoardClassify.laneSchedules(schedules: inputs, accountID: account.id)
            guard let idx = lane.firstIndex(where: { $0.schedule.id == selectedID }) else { continue }
            let ls = lane[idx]
            let mid = BoardView.midWindow(for: account)
            let cls = BoardClassify.classify(ls, nowMinutes: nowMinutes, mid: mid)
            let chainTarget: Int? = lane.count > 1
                ? lane[(idx - 1 + lane.count) % lane.count].reset
                : nil
            // Track.tsx:68 — the floor exists only while a window is active.
            let floor = mid.map { $0.end + BoardSchedule.windowHours * 60 } ?? 0
            return SelectedInspector(
                email: account.email.isEmpty ? account.label : account.email,
                ls: ls, cls: cls, mid: mid, chainTarget: chainTarget,
                laneResets: lane.map(\.reset), laneIndex: idx, floor: floor)
        }
        return nil
    }
}
