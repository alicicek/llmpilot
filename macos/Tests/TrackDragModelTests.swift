import XCTest

// Delta-review N1/N2 regressions: the VoiceOver book action must convert
// the resolver's RESET slot to the TRIGGER onCreate expects (passing it
// straight through books a window FIVE HOURS late), and keyboardMove must
// burn the sync signature so a refused mutation re-seeds from server truth.
@MainActor
final class TrackDragModelReconcileTests: XCTestCase {
    private func lane(_ id: String, trigger: Int) -> BoardClassify.LaneSchedule {
        let input = BoardClassify.ScheduleInput(id: id, accountID: "a", hour: trigger / 60, minute: trigger % 60)
        return BoardClassify.laneSchedules(schedules: [input], accountID: "a")[0]
    }

    func testBookNextAvailableCreatesTheTriggerNotTheReset() {
        var created: (Int, Int)?
        let model = TrackDragModel(onCreate: { created = ($0, $1) })
        model.sync([]) // empty lane
        // nowMinutes 600 (10:00) → floor 900 → first slot (the RESET) 900
        // = 15:00 → the stored TRIGGER must be 10:00, not 15:00.
        XCTAssertTrue(model.bookNextAvailable(nowMinutes: 600, activeEndMinutes: nil))
        XCTAssertEqual(created?.0, 10, "hour must be the TRIGGER (reset − 5h)")
        XCTAssertEqual(created?.1, 0)
    }

    func testKeyboardMoveBurnsSignatureSoRefusalReSyncs() {
        var moved = 0
        let model = TrackDragModel(onMove: { _, _, _ in moved += 1 })
        let ls = lane("s1", trigger: 600) // reset 900
        model.sync([ls])
        model.keyboardMove(index: 0, delta: BoardSchedule.snapMin)
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(model.values, [915], "optimistic value applied")
        // The daemon REFUSED: identical props arrive again — the burned
        // signature must force a re-seed back to server truth (reset 900).
        model.sync([ls])
        XCTAssertEqual(model.values, [900], "a refused move must snap back on the next sync")
    }
}
@testable import llmpilot

/// The Phase 3 chunk B gesture-layer drag state machine, tested as plain
/// state transitions — `TrackDragModel` deliberately has no SwiftUI import
/// so every path Track.tsx exercises via pointer/keyboard events can be
/// driven here directly. A `CountingTicker` stands in for `BoardAudio` (the
/// test seam the brief asks for) so ticks are counted, never played.
final class TrackDragModelTests: XCTestCase {
    private final class CountingTicker: BoardTicker {
        private(set) var detent = 0
        private(set) var book = 0
        private(set) var remove = 0
        private(set) var wall = 0
        func tickDetent() { detent += 1 }
        func tickBook() { book += 1 }
        func tickRemove() { remove += 1 }
        func tickWall() { wall += 1 }
    }

    private func schedule(_ id: String, accountID: String = "a1", hour: Int, minute: Int = 0) -> BoardClassify.ScheduleInput {
        BoardClassify.ScheduleInput(id: id, accountID: accountID, hour: hour, minute: minute)
    }

    /// Builds a `LaneSchedule` at a literal reset-minutes value (bypassing
    /// `laneSchedules`'s own hour/minute -> reset math, which is pinned
    /// separately by the golden vectors) — trigger/chained are irrelevant
    /// to the drag model, which only reads `.schedule.id` and seeds
    /// `values` from `.reset`.
    private func laneSchedule(id: String, reset: Int, accountID: String = "a1") -> BoardClassify.LaneSchedule {
        BoardClassify.LaneSchedule(
            schedule: BoardClassify.ScheduleInput(id: id, accountID: accountID, hour: 0, minute: 0),
            trigger: 0, reset: reset, chained: false
        )
    }

    private func makeModel(
        floor: Int = 0, ticker: BoardTicker,
        onMove: @escaping (String, Int, Int) -> Void = { _, _, _ in },
        onDelete: @escaping (String) -> Void = { _ in },
        onCreate: @escaping (Int, Int) -> Void = { _, _ in }
    ) -> TrackDragModel {
        TrackDragModel(floor: floor, ticker: ticker, onMove: onMove, onDelete: onDelete, onCreate: onCreate)
    }

    // MARK: - sync (prop re-seed)

    func test_sync_seedsValuesFromSchedules() {
        let ticker = CountingTicker()
        let model = makeModel(ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 600), laneSchedule(id: "s2", reset: 1200)])
        XCTAssertEqual(model.values, [600, 1200])
        XCTAssertEqual(model.laneSchedules.map(\.schedule.id), ["s1", "s2"])
    }

    func test_sync_suppressedMidDrag() {
        let ticker = CountingTicker()
        let model = makeModel(ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 600), laneSchedule(id: "s2", reset: 1200)])
        model.beginDrag(index: 0)
        model.moveDrag(to: 615)
        XCTAssertEqual(model.values, [615, 1200])

        // A fresh sync arrives mid-drag (e.g. an SSE reconcile) — Track.tsx
        // never applies it while `dragIdxRef.current !== -1`.
        model.sync([laneSchedule(id: "s1", reset: 900), laneSchedule(id: "s2", reset: 1300)])
        XCTAssertEqual(model.values, [615, 1200], "prop re-sync must be suppressed while a drag is in flight")

        model.endDrag()
        // Now that the drag ended, the NEXT sync call (with a signature that
        // actually changed) must apply normally.
        model.sync([laneSchedule(id: "s1", reset: 900), laneSchedule(id: "s2", reset: 1300)])
        XCTAssertEqual(model.values, [900, 1300])
    }

    // MARK: - chain-snap (early return, skips clampMove)

    func test_chainSnap_earlyReturn_skipsClampMove() {
        let ticker = CountingTicker()
        let model = makeModel(ticker: ticker)
        // index 0 at 10:00 (600), index 1 at 20:00 (1200). Dragging index 1
        // to 915 (trigger 615) is within SNAP_MIN (15) of index 0's reset
        // (600) -> chain-snaps to (600 + 300) % 1440 == 900, NOT 915 (which
        // is what plain clampMove would have allowed, since 915 - 600 ==
        // MIN_GAP_MIN exactly — the snap winning over clamp is the only
        // observable proof the early return fired).
        model.sync([laneSchedule(id: "s1", reset: 600), laneSchedule(id: "s2", reset: 1200)])
        model.beginDrag(index: 1)
        model.moveDrag(to: 915)
        XCTAssertEqual(model.values[1], 900)
        XCTAssertEqual(ticker.detent, 1)
        XCTAssertEqual(ticker.wall, 0, "chain-snap must never flash/wall — it's a magnetized snap, not a clamp")
    }

    func test_chainSnap_noTickWhenAlreadySnapped() {
        let ticker = CountingTicker()
        let model = makeModel(ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 600), laneSchedule(id: "s2", reset: 900)])
        model.beginDrag(index: 1)
        model.moveDrag(to: 905) // snaps back to the same 900 it already was
        XCTAssertEqual(model.values[1], 900)
        XCTAssertEqual(ticker.detent, 0, "no detent tick when the snapped value equals the value before this move")
    }

    // MARK: - clamp + hitWall -> flash

    func test_clampMove_hitsWall_flashesAndTicks() {
        let ticker = CountingTicker()
        let model = makeModel(floor: 0, ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 300), laneSchedule(id: "s2", reset: 900)])
        model.beginDrag(index: 0)
        model.moveDrag(to: 850) // clamps to 900 - 315 = 585
        XCTAssertEqual(model.values[0], 585)
        XCTAssertEqual(ticker.wall, 1)
        XCTAssertEqual(ticker.detent, 0, "a wall hit ticks wall, never detent")
        XCTAssertNotNil(model.flash)
        XCTAssertEqual(model.flash?.from, 585)
        XCTAssertEqual(model.flash?.to, 900)
    }

    func test_clampMove_legalMove_ticksDetentNoFlash() {
        let ticker = CountingTicker()
        let model = makeModel(floor: 0, ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 600)])
        model.beginDrag(index: 0)
        model.moveDrag(to: 615)
        XCTAssertEqual(model.values[0], 615)
        XCTAssertEqual(ticker.detent, 1)
        XCTAssertEqual(ticker.wall, 0)
        XCTAssertNil(model.flash)
    }

    // MARK: - removal arming

    func test_removalArms_pastThreshold_withMultipleSchedules() {
        let ticker = CountingTicker()
        let model = makeModel(ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 300), laneSchedule(id: "s2", reset: 900)])
        model.beginDrag(index: 0)
        model.updateRemoval(dy: 40)
        XCTAssertEqual(model.removingIndex, -1, "below the 56pt threshold, not armed")
        model.updateRemoval(dy: 57)
        XCTAssertEqual(model.removingIndex, 0)
        model.updateRemoval(dy: 30)
        XCTAssertEqual(model.removingIndex, -1, "moving back under the threshold disarms")
    }

    func test_removalNeverArms_withSingleSchedule() {
        let ticker = CountingTicker()
        let model = makeModel(ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 300)])
        model.beginDrag(index: 0)
        model.updateRemoval(dy: 200)
        XCTAssertEqual(model.removingIndex, -1, "a lane's last schedule can't be drag-removed — nowhere to land")
    }

    // MARK: - release commit

    func test_endDrag_commitsOnlyWhenValueChanged() {
        let ticker = CountingTicker()
        var moved: [(String, Int, Int)] = []
        let model = makeModel(ticker: ticker, onMove: { moved.append(($0, $1, $2)) })
        model.sync([laneSchedule(id: "s1", reset: 600)])
        model.beginDrag(index: 0)
        model.endDrag() // no moveDrag call — value unchanged
        XCTAssertTrue(moved.isEmpty, "release without any move must not commit")
        XCTAssertEqual(model.draggingIndex, -1)
    }

    func test_endDrag_commitsWhenValueChanged() {
        let ticker = CountingTicker()
        var moved: [(String, Int, Int)] = []
        let model = makeModel(ticker: ticker, onMove: { moved.append(($0, $1, $2)) })
        model.sync([laneSchedule(id: "s1", reset: 600)])
        model.beginDrag(index: 0)
        model.moveDrag(to: 615)
        model.endDrag()
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.0, "s1")
        // reset 615 -> trigger 615 - 300 = 315 -> 05:15
        XCTAssertEqual(moved.first?.1, 5)
        XCTAssertEqual(moved.first?.2, 15)
    }

    func test_endDrag_armedRemoval_deletesInsteadOfMoving() {
        let ticker = CountingTicker()
        var moved: [(String, Int, Int)] = []
        var deleted: [String] = []
        let model = makeModel(
            ticker: ticker, onMove: { moved.append(($0, $1, $2)) }, onDelete: { deleted.append($0) }
        )
        model.sync([laneSchedule(id: "s1", reset: 300), laneSchedule(id: "s2", reset: 900)])
        model.beginDrag(index: 0)
        model.moveDrag(to: 315)
        model.updateRemoval(dy: 60)
        model.endDrag()
        XCTAssertEqual(deleted, ["s1"])
        XCTAssertTrue(moved.isEmpty, "an armed-removal release must delete, never also commit a move")
        XCTAssertEqual(ticker.remove, 1)
        XCTAssertEqual(ticker.detent, 1, "the drag toward the removal zone still ticked its own detent en route")
    }

    // MARK: - keyboard

    func test_keyboardMove_stepsBySnapAndCommitsImmediately() {
        let ticker = CountingTicker()
        var moved: [(String, Int, Int)] = []
        let model = makeModel(ticker: ticker, onMove: { moved.append(($0, $1, $2)) })
        model.sync([laneSchedule(id: "s1", reset: 600)])
        model.keyboardMove(index: 0, delta: 15)
        XCTAssertEqual(model.values[0], 615)
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(ticker.detent, 1)

        model.keyboardMove(index: 0, delta: -15)
        XCTAssertEqual(model.values[0], 600)
        XCTAssertEqual(moved.count, 2)
    }

    func test_keyboardMove_noOpDoesNotCommit() {
        let ticker = CountingTicker()
        var moved: [(String, Int, Int)] = []
        let model = makeModel(floor: 0, ticker: ticker, onMove: { moved.append(($0, $1, $2)) })
        model.sync([laneSchedule(id: "s1", reset: 0)])
        model.keyboardMove(index: 0, delta: -15) // clamps back to 0 — no-op
        XCTAssertEqual(model.values[0], 0)
        XCTAssertTrue(moved.isEmpty)
        XCTAssertEqual(ticker.detent, 0)
    }

    func test_keyboardDelete_singleSchedule_allowed_noLengthGuard() {
        let ticker = CountingTicker()
        var deleted: [String] = []
        let model = makeModel(ticker: ticker, onDelete: { deleted.append($0) })
        model.sync([laneSchedule(id: "only", reset: 600)])
        // Deliberately the opposite of the drag-release removal rule
        // (which needs >1 schedule to have somewhere to land) — parity
        // with Track.tsx's `Slider.Thumb.onKeyDown`, which has no such
        // guard.
        model.keyboardDelete(index: 0)
        XCTAssertEqual(deleted, ["only"])
        XCTAssertEqual(ticker.remove, 1)
    }

    // MARK: - create (tap on empty track)

    func test_createAt_legal_booksAndTicks() {
        let ticker = CountingTicker()
        var created: [(Int, Int)] = []
        let model = makeModel(floor: 0, ticker: ticker, onCreate: { created.append(($0, $1)) })
        model.createAt(600) // 10:00 reset -> trigger 05:00
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.0, 5)
        XCTAssertEqual(created.first?.1, 0)
        XCTAssertEqual(ticker.book, 1)
        XCTAssertEqual(ticker.wall, 0)
    }

    func test_createAt_illegal_flashesAndTicksWallNoCreate() {
        let ticker = CountingTicker()
        var created: [(Int, Int)] = []
        // floor 300 (an idle-lane mid-window shift-lock stand-in) — a
        // proposed reset before the floor is illegal.
        let model = makeModel(floor: 300, ticker: ticker, onCreate: { created.append(($0, $1)) })
        model.createAt(100)
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(ticker.wall, 1)
        XCTAssertEqual(ticker.book, 0)
        XCTAssertEqual(model.flash?.from, 0)
        XCTAssertEqual(model.flash?.to, 300)
    }

    func test_createAt_suppressedMidDrag() {
        let ticker = CountingTicker()
        var created: [(Int, Int)] = []
        let model = makeModel(ticker: ticker, onCreate: { created.append(($0, $1)) })
        model.sync([laneSchedule(id: "s1", reset: 600)])
        model.beginDrag(index: 0)
        model.createAt(0)
        XCTAssertTrue(created.isEmpty, "a create-tap can't land while a drag from a previous gesture is somehow still open")
    }

    // MARK: - pure geometry helpers

    func test_triggerOf_wrapsAcrossMidnight() {
        XCTAssertEqual(TrackDragModel.triggerOf(0), 24 * 60 - 5 * 60) // 00:00 reset -> 19:00 trigger (previous day)
        XCTAssertEqual(TrackDragModel.triggerOf(300), 0)
        XCTAssertEqual(TrackDragModel.triggerOf(1439), 1439 - 300)
    }

    func test_snappedMinutes_roundsToDetentAndClamps() {
        XCTAssertEqual(TrackDragModel.snappedMinutes(fromTrackX: 0), 0)
        XCTAssertEqual(TrackDragModel.snappedMinutes(fromTrackX: -50, trackWidth: 1160), 0, "clamps below zero")
        XCTAssertEqual(TrackDragModel.snappedMinutes(fromTrackX: 100_000, trackWidth: 1160), 1440 - 15, "clamps above the last detent")
        // Midpoint of the track (580px of 1160) -> 720 minutes (noon),
        // already snap-aligned.
        XCTAssertEqual(TrackDragModel.snappedMinutes(fromTrackX: 580, trackWidth: 1160), 720)
    }

    // MARK: - hover preview (create affordance, beyond the enumerated FEEL PARAMETERS)

    func test_hoverPreview_showsOnlyOverLegalSpots() {
        let ticker = CountingTicker()
        let model = makeModel(floor: 0, ticker: ticker)
        model.sync([laneSchedule(id: "s1", reset: 600)])
        model.updateHoverPreview(1000) // far from 600 — legal
        XCTAssertEqual(model.hoverPreview, 1000)
        model.updateHoverPreview(650) // within MIN_GAP_MIN of 600 — illegal
        XCTAssertNil(model.hoverPreview)
        model.updateHoverPreview(nil)
        XCTAssertNil(model.hoverPreview)
    }
}
