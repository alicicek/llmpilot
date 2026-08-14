import Combine
import Foundation

/// Test seam (Phase 3 chunk B brief): production wires `BoardAudio` here;
/// unit tests substitute a counting fake so the drag state machine is
/// verifiable without touching AVFoundation or the sound card.
protocol BoardTicker {
    func tickDetent()
    func tickBook()
    func tickRemove()
    func tickWall()
}

/// Silent default — used wherever a caller doesn't care about audio (e.g. a
/// `TrackDragModel` built for a preview or a test that only checks values).
struct NoOpBoardTicker: BoardTicker {
    func tickDetent() {}
    func tickBook() {}
    func tickRemove() {}
    func tickWall() {}
}

/// THE GESTURE LAYER's pure state machine — a 1:1 behavioral port of
/// Track.tsx's drag/keyboard/create handlers (handleValueChange, the
/// `pointerup` `up` handler, handleRootPointerMove/DownCapture, and the
/// Radix Slider's keyboard-step-then-commit path), deliberately holding NO
/// SwiftUI import so it is unit-testable as plain state transitions (see
/// macos/Tests/TrackDragModelTests.swift). One instance owns ONE lane's
/// track; `BoardTrackView` hosts it via `@StateObject` and re-assigns the
/// plain (non-`@Published`) `floor`/`ticker`/`onMove`/`onDelete`/`onCreate`
/// properties every body evaluation — mirroring Track.tsx's own
/// `onMoveRef.current = onMove`-style ref-refresh pattern, safe because
/// those properties are not `@Published` and so never trigger a re-render
/// loop when re-assigned to an equal value.
final class TrackDragModel: ObservableObject {
    // MARK: - context (mutable, NOT @Published — refreshed every render)

    /// Track.tsx's `floor`: the earliest legal reset for this lane (0 for an
    /// idle lane; `mid.end + WINDOW_MIN` for a mid-window lane's shift-lock).
    var floor: Int
    var ticker: BoardTicker
    /// `(scheduleID, hour, minute) -> Void` — fired on a committed move.
    var onMove: (String, Int, Int) -> Void
    var onDelete: (String) -> Void
    /// `(hour, minute) -> Void` — fired on a legal create-tap.
    var onCreate: (Int, Int) -> Void

    // MARK: - live state (@Published — read by the view)

    /// This lane's schedules, sorted by reset and chain-flagged
    /// (`BoardClassify.laneSchedules`'s own output) — index-aligned 1:1
    /// with `values`.
    @Published private(set) var laneSchedules: [BoardClassify.LaneSchedule] = []
    /// The live (possibly mid-drag, optimistic) reset minutes per index.
    @Published private(set) var values: [Int] = []
    @Published private(set) var draggingIndex: Int = -1
    @Published private(set) var removingIndex: Int = -1
    @Published private(set) var hoveredIndex: Int = -1
    @Published private(set) var flash: FlashState?
    /// Track.tsx's `preview`: a hover-only "+ HH:MM" badge shown while the
    /// pointer rests over a LEGAL, bookable empty spot (nil while illegal,
    /// while dragging, or while off-track). Beyond the brief's enumerated
    /// FEEL PARAMETERS but present in the ground truth (Track.tsx:74,
    /// 178, 344-351) — kept for fidelity.
    @Published private(set) var hoverPreview: Int?

    struct FlashState: Equatable {
        let from: Int
        let to: Int
        let key: Int
    }

    // MARK: - drag-scoped state

    /// The values snapshot at `beginDrag` — the release-commit diff base and
    /// the ghost block's position. Read by the view while dragging (not
    /// `@Published`: it only ever changes in lockstep with `draggingIndex`,
    /// which IS `@Published` and already triggers the re-render that picks
    /// this up).
    private(set) var dragOrigin: [Int] = []
    private var flashKeyCounter = 0
    /// The signature `sync(_:)` last applied — Track.tsx's `sig` dependency,
    /// ported so a no-op re-sync (same schedules, different array identity)
    /// never touches `@Published` and never triggers a redundant re-render.
    private var appliedSignature = ""

    /// A refused mutation (402 pro gate, 409 conflict) leaves the wire
    /// state unchanged — identical signature — so the guard would pin the
    /// optimistic local value forever. Every commit callback burns the
    /// signature so the NEXT prop sync re-seeds unconditionally, converging
    /// local values back to server truth whether the write landed or not.
    /// KNOWN TRADE (delta review N4): burning BEFORE the request means the
    /// first re-render after a SUCCESSFUL commit re-seeds from still-stale
    /// props (a 1-3 frame rubber-band on localhost) before the SSE push
    /// lands. Accepted: correctness beats cosmetics - the alternative
    /// (burning only on refusal) needs the async result threaded back into
    /// this model and leaves a failure window if that plumbing ever breaks.
    private func expectReconcile() { appliedSignature = "" }

    init(
        floor: Int = 0,
        ticker: BoardTicker = NoOpBoardTicker(),
        onMove: @escaping (String, Int, Int) -> Void = { _, _, _ in },
        onDelete: @escaping (String) -> Void = { _ in },
        onCreate: @escaping (Int, Int) -> Void = { _, _ in }
    ) {
        self.floor = floor
        self.ticker = ticker
        self.onMove = onMove
        self.onDelete = onDelete
        self.onCreate = onCreate
    }

    var isDragging: Bool { draggingIndex >= 0 }

    // MARK: - geometry helpers (pure, no SwiftUI)

    private static func wrap(_ m: Int) -> Int {
        ((m % BoardSchedule.dayMin) + BoardSchedule.dayMin) % BoardSchedule.dayMin
    }

    /// Track.tsx's `triggerOf` — reset minus the 5h window, wrapped.
    static func triggerOf(_ reset: Int) -> Int {
        wrap(reset - BoardSchedule.windowHours * 60)
    }

    /// Track.tsx's pointer→minutes math (`handleRootPointerMove`/
    /// `handleRootPointerDownCapture`): round to the nearest 15-min detent,
    /// then clamp into `[0, dayMin - snapMin]`.
    static func snappedMinutes(fromTrackX x: Double, trackWidth: Double = BoardGeometry.trackPx) -> Int {
        guard trackWidth > 0 else { return 0 }
        let raw = (x / trackWidth) * Double(BoardSchedule.dayMin) / Double(BoardSchedule.snapMin)
        let t = Int(raw.rounded()) * BoardSchedule.snapMin
        return min(BoardSchedule.dayMin - BoardSchedule.snapMin, max(0, t))
    }

    // MARK: - prop re-sync (Track.tsx's `sig`-gated `useEffect`)

    /// Re-seeds `values`/`laneSchedules` from fresh props — SUPPRESSED while
    /// a drag is in flight (Track.tsx: `if (dragIdxRef.current === -1)
    /// setValues(...)`), and a no-op when the signature hasn't changed (so
    /// calling this every SwiftUI body evaluation is safe and cheap).
    func sync(_ schedules: [BoardClassify.LaneSchedule]) {
        guard !isDragging else { return }
        let sig = schedules.map { "\($0.schedule.id):\($0.reset)" }.joined(separator: ",")
        guard sig != appliedSignature else { return }
        appliedSignature = sig
        laneSchedules = schedules
        values = schedules.map { $0.reset }
    }

    // MARK: - the shared onValueChange path (drag AND keyboard both funnel here)

    /// Track.tsx's `handleValueChange`: given the array with only `index`
    /// differing from `prev`, apply chain-snap first (an early return that
    /// SKIPS clampMove entirely — the interaction contract's explicit
    /// exception for the exact 5h seam-touch), else `clampMove`. Fires
    /// detent/wall ticks as a side effect, matching the web (one handler,
    /// shared by pointer drag and keyboard step). Returns the resulting
    /// array; does NOT commit (that's the caller's job — pointer commits on
    /// release, keyboard commits immediately after this call).
    private func applyValueChange(prev: [Int], next: [Int], at index: Int) -> [Int] {
        let i = index
        guard next[i] != prev[i] else { return prev }

        if i > 0 {
            let prevReset = next[i - 1]
            let trigger = Self.triggerOf(next[i])
            if BoardSchedule.circularGap(trigger, prevReset) <= BoardSchedule.snapMin {
                let snapped = (prevReset + BoardSchedule.windowHours * 60) % BoardSchedule.dayMin
                var out = next
                out[i] = snapped
                if snapped != prev[i] { ticker.tickDetent() }
                return out
            }
        }

        guard let res = BoardClamp.clampMove(prev: prev, next: next, floor: floor) else {
            return next
        }
        if let fz = res.flashZone {
            doFlash(from: fz.0, to: fz.1)
            if res.hitWall { ticker.tickWall() }
        } else if res.values[i] != prev[i] {
            ticker.tickDetent()
        }
        return res.values
    }

    private func doFlash(from: Int, to: Int) {
        flashKeyCounter += 1
        flash = FlashState(from: from, to: to, key: flashKeyCounter)
    }

    /// Clears the flash overlay — called by the view once its 0.7s
    /// keyframe animation completes (Track.tsx's `onAnimationComplete`).
    func clearFlash() {
        flash = nil
    }

    // MARK: - pointer drag

    /// Slider.Thumb's `onPointerDown` — snapshots the drag origin for the
    /// ghost block + release-commit diff.
    func beginDrag(index: Int) {
        guard values.indices.contains(index) else { return }
        draggingIndex = index
        dragOrigin = values
    }

    /// Track.tsx's `handleValueChange`, called with the dragged thumb's
    /// proposed new value (already snapped to 15-min detents by the caller
    /// via `Self.snappedMinutes`).
    func moveDrag(to proposed: Int) {
        guard isDragging else { return }
        let i = draggingIndex
        let prev = values
        var next = prev
        next[i] = proposed
        values = applyValueChange(prev: prev, next: next, at: i)
    }

    /// `handleRootPointerMove`'s removal-arm check: vertical distance from
    /// the row center, in points.
    func updateRemoval(dy: Double) {
        guard isDragging else { return }
        removingIndex = (dy > 56 && values.count > 1) ? draggingIndex : -1
    }

    /// The `window`-level `pointerup` handler — fires wherever the pointer
    /// releases (global semantics, not just over the track), matching the
    /// web's `window.addEventListener("pointerup", ...)`.
    func endDrag() {
        guard isDragging else { return }
        let i = draggingIndex
        defer {
            draggingIndex = -1
            removingIndex = -1
            flash = nil
        }
        guard laneSchedules.indices.contains(i), values.indices.contains(i) else { return }
        let id = laneSchedules[i].schedule.id
        if removingIndex == i, values.count > 1 {
            ticker.tickRemove()
            expectReconcile()
            onDelete(id)
        } else if dragOrigin.indices.contains(i), dragOrigin[i] != values[i] {
            let t = Self.triggerOf(values[i])
            expectReconcile()
            onMove(id, t / 60, t % 60)
        }
    }

    /// Teardown-safe CANCEL: restores the pre-drag values and clears every
    /// drag flag WITHOUT firing any commit callback. `endDrag` on teardown
    /// would be destructive - a chip held past the removal threshold when
    /// the view disappears would silently DELETE the schedule.
    func cancelDrag() {
        guard isDragging else { return }
        if !dragOrigin.isEmpty { values = dragOrigin }
        draggingIndex = -1
        removingIndex = -1
        dragOrigin = []
    }

    // MARK: - keyboard

    /// Focused-chip ←/→: ±15 minutes, clamped into the slider's own
    /// [0, dayMin - snapMin] range (Radix's `min`/`max`/`step` on the
    /// underlying `<input type=range>`), routed through the SAME
    /// chain-snap/clamp path as a drag, then committed immediately —
    /// Track.tsx's Radix Slider fires `onValueChange` then `onValueCommit`
    /// synchronously for a keyboard step (no pointer drag in flight).
    /// The track's named accessibility action (VoiceOver's click-to-book
    /// twin — a pointer position means nothing to AX users, so this books
    /// the next legal slot exactly like the Fresh-window menu). The
    /// resolver returns a RESET slot; `onCreate` takes the TRIGGER — the
    /// same reset→trigger conversion every other caller makes
    /// (FreshWindowMenu's resolver, web App.tsx:259). Passing the slot
    /// straight through would book a window FIVE HOURS after the one the
    /// gap check just validated.
    func bookNextAvailable(nowMinutes: Int, activeEndMinutes: Int?) -> Bool {
        guard let slot = BoardSchedule.nextBookableReset(
            nowMinutes: nowMinutes, existingResets: values,
            activeEndMinutes: activeEndMinutes)
        else { return false }
        ticker.tickBook()
        expectReconcile()
        let trigger = Self.triggerOf(slot.hour * 60 + slot.minute)
        onCreate(trigger / 60, trigger % 60)
        return true
    }

    func keyboardMove(index: Int, delta: Int) {
        guard !isDragging, values.indices.contains(index) else { return }
        let prev = values
        var next = prev
        next[index] = max(0, min(BoardSchedule.dayMin - BoardSchedule.snapMin, prev[index] + delta))
        let result = applyValueChange(prev: prev, next: next, at: index)
        values = result
        guard result[index] != prev[index] else { return }
        let id = laneSchedules[index].schedule.id
        let t = Self.triggerOf(result[index])
        expectReconcile()
        onMove(id, t / 60, t % 60)
    }

    /// Backspace/Delete on a focused chip — Track.tsx's
    /// `Slider.Thumb.onKeyDown`, deliberately WITHOUT the pointer-release
    /// path's `values.count > 1` guard (parity with the web: a lane's last
    /// schedule can be deleted from the keyboard, just not by dragging it
    /// off — the drag-removal gesture needs >1 to have somewhere to land).
    func keyboardDelete(index: Int) {
        guard !isDragging, laneSchedules.indices.contains(index) else { return }
        ticker.tickRemove()
        expectReconcile()
        onDelete(laneSchedules[index].schedule.id)
    }

    // MARK: - create (tap on empty track)

    /// `handleRootPointerMove`'s preview: updates the hover-only
    /// "+ HH:MM" badge position. `t` is unclamped/unsnapped pointer-x
    /// minutes; nil hides the badge (e.g. pointer left the track).
    func updateHoverPreview(_ t: Int?) {
        guard !isDragging else {
            if hoverPreview != nil { hoverPreview = nil }
            return
        }
        guard let t else {
            if hoverPreview != nil { hoverPreview = nil }
            return
        }
        let clamped = min(BoardSchedule.dayMin - BoardSchedule.snapMin, max(0, t))
        let next = BoardClamp.canBookAt(clamped, existing: values, floor: floor) == nil ? clamped : nil
        if hoverPreview != next { hoverPreview = next }
    }

    /// `handleRootPointerDownCapture` — a tap/click on the empty track (the
    /// caller is responsible for confirming the tap did NOT land on a chip;
    /// this model has no view hierarchy to check that itself). `t` is
    /// unclamped/unsnapped pointer-x minutes.
    func createAt(_ t: Int) {
        guard !isDragging else { return }
        let clamped = min(BoardSchedule.dayMin - BoardSchedule.snapMin, max(0, t))
        if let bad = BoardClamp.canBookAt(clamped, existing: values, floor: floor) {
            doFlash(from: bad.0, to: bad.1)
            ticker.tickWall()
            return
        }
        let trigger = Self.triggerOf(clamped)
        ticker.tickBook()
        expectReconcile()
        onCreate(trigger / 60, trigger % 60)
        hoverPreview = nil
    }

    // MARK: - hover (non-drag chip hover, for ChargeBlock's ring)

    func setHovered(_ index: Int?) {
        hoveredIndex = index ?? -1
    }
}
