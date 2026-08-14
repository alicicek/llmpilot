import SwiftUI

/// One lane's interactive 24h track — the native port of
/// web/src/board/Track.tsx, THE spec for this chunk. 1160x116pt. Owns a
/// `TrackDragModel` (the pure state machine, no SwiftUI import) and
/// translates its published state into layout, gesture wiring, and the
/// flash/HUD motion this file is responsible for — the pieces themselves
/// (BoardPieces.swift) are presentation-only.
///
/// MOTION PARITY NOTE (read before "fixing" either of these): Track.tsx's
/// HUD (`Hud.tsx`) is rendered as a plain conditional, NOT wrapped in
/// `<AnimatePresence>` — it fades IN over 150ms but disappears INSTANTLY
/// when a drag ends (nothing is watching for its removal to play an exit
/// animation). Its flash overlay (0 -> 0.4 -> 0 over 700ms, peak at 25%) IS
/// wrapped in `<AnimatePresence>` and always plays its full keyframe
/// sequence regardless of `prefers-reduced-motion` — Track.tsx never calls
/// `useReducedMotion()`. Both quirks are kept here for cross-stack parity
/// per the brief, not fixed: `useReducedMotion.ts`'s own doc comment scopes
/// reduced-motion to discrete state-swap transitions (the Inspector's
/// slide, a later chunk), never these per-gesture feedback effects.
struct BoardTrackView: View {
    let accountID: String
    let accountLabel: String
    let schedules: [BoardClassify.LaneSchedule]
    let mid: BoardClassify.MidWindow?
    let nowMinutes: Int
    var selectedID: String?
    var canSchedule: Bool = true
    var onSelect: (String?) -> Void = { _ in }
    var onCreate: (Int, Int) -> Void = { _, _ in }
    var onMove: (String, Int, Int) -> Void = { _, _, _ in }
    var onDelete: (String) -> Void = { _ in }
    var ticker: BoardTicker = BoardAudio.shared
    /// Full-lane refusal surface for the VoiceOver book action (the menu
    /// path has its own). Wired by BoardView -> the integrator's flash.
    var onFullyBooked: (String) -> Void = { _ in }

    @StateObject private var model = TrackDragModel()
    @FocusState private var focusedIndex: Int?
    @State private var flashOpacity: Double = 0
    @State private var flashKey: Int = -1
    @State private var hudOpacity: Double = 0

    private var floor: Int { mid.map { $0.end + BoardSchedule.windowHours * 60 } ?? 0 }

    var body: some View {
        // Ref-refresh pattern (see TrackDragModel's header comment): these
        // are plain `var`s on the model, not `@Published` — reassigning
        // them every body evaluation is cheap and never triggers a
        // re-render loop. `sync` IS internally guarded (no-op mid-drag or
        // when the schedule signature hasn't changed), so calling it every
        // body evaluation is likewise safe.
        model.floor = floor
        model.ticker = ticker
        model.onMove = onMove
        model.onDelete = onDelete
        model.onCreate = onCreate
        model.sync(schedules)

        return ZStack(alignment: .topLeading) {
            Color.clear
            railLine
            emptyPlaceholder
            midWindowBadge
            forbiddenZonesOverlay
            flashOverlay
            hoverPreviewBadge
            chips
            hudOverlay
        }
        .frame(width: BoardGeometry.trackPx, height: BoardGeometry.rowPx)
        .contentShape(Rectangle())
        .coordinateSpace(name: "track")
        .onDisappear {
            // A cancelled gesture (sheet mid-drag, scroll steal, teardown)
            // may never deliver onEnded — without this the lane stays
            // "dragging" forever: sync suppressed, overlays stuck. CANCEL,
            // never endDrag: a teardown mid-removal-arm must not commit a
            // silent delete.
            model.cancelDrag()
        }
        .gesture(createGesture)
        .trackHoverPreview { location in
            if let location {
                // Snap BEFORE the preview/legality check (Track.tsx:176) — the
                // badge must promise exactly the minute a click would book.
                model.updateHoverPreview(TrackDragModel.snappedMinutes(fromTrackX: location.x))
            } else {
                model.updateHoverPreview(nil)
            }
        }
        .onChange(of: model.isDragging) { dragging in
            if dragging {
                hudOpacity = 0
                withAnimation(.easeOut(duration: 0.15)) { hudOpacity = 1 }
            } else {
                // No exit animation — see the file header's motion-parity note.
                hudOpacity = 0
            }
        }
        // A plain container gets FLATTENED out of the AX tree, so the
        // identifier would never surface to AX drivers (the e2e locates the
        // track by it) — .contain makes this a real AXGroup that carries it
        // while keeping the chips inside reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track-\(accountID)")
        // VoiceOver twin of click-to-book: a pointer position means nothing
        // to an AX user, so the named action books the next legal slot
        // (Fresh-window semantics). Doubles as the e2e create driver.
        .accessibilityAction(named: "Book next fresh window") {
            if !model.bookNextAvailable(nowMinutes: nowMinutes, activeEndMinutes: mid?.end) {
                // Full lane: same copy the Fresh-window menu shows — a
                // silent no-op is exactly what an AX user can't diagnose.
                onFullyBooked("\(accountLabel) is fully booked — resets must sit ≥ 5 h 15 min apart.")
            }
        }
    }

    // MARK: - background

    @ViewBuilder private var railLine: some View {
        if model.laneSchedules.isEmpty {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: BoardGeometry.trackPx, y: 0))
            }
            .stroke(CockpitTheme.rail, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            .frame(height: 2)
            .offset(y: 48)
            .allowsHitTesting(false)
        } else {
            Rectangle()
                .fill(CockpitTheme.rail)
                .frame(width: BoardGeometry.trackPx, height: 2)
                .offset(y: 48)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var emptyPlaceholder: some View {
        if model.laneSchedules.isEmpty, mid == nil {
            Text(
                canSchedule
                    ? "No fresh windows — click a time to book one"
                    : "Fresh windows open on a schedule the autopilot runs — nothing booked here"
            )
            .font(.system(size: 11))
            .foregroundColor(CockpitTheme.ter)
            .multilineTextAlignment(.center)
            .frame(width: BoardGeometry.trackPx)
            .position(x: BoardGeometry.trackPx / 2, y: 42 + 7)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var midWindowBadge: some View {
        if let mid {
            let x0 = BoardGeometry.toPx(Double(mid.start))
            let x1 = BoardGeometry.toPx(Double(mid.end))
            let w = max(0, x1 - x0)
            ZStack {
                BoardDiagonalHatch(stripeColor: CockpitTheme.hatch, backgroundColor: CockpitTheme.hatchBg, stripeWidth: 3, period: 7.5)
                Text("in use — resets \(BoardSchedule.fmtHM(mid.end))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(CockpitTheme.text)
            }
            .frame(width: w, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(CockpitTheme.hair, lineWidth: 1))
            .position(x: x0 + w / 2, y: 88 + 7.5)
            .allowsHitTesting(false)
        }
    }

    // MARK: - forbidden zones (drag-only)

    @ViewBuilder private var forbiddenZonesOverlay: some View {
        if model.isDragging, model.values.indices.contains(model.draggingIndex) {
            let i = model.draggingIndex
            let dv = model.values[i]
            let others = model.values.enumerated().filter { $0.offset != i }.map(\.element)
            ZStack(alignment: .topLeading) {
                if floor > 0 {
                    zoneView(from: 0, to: floor, kind: .red)
                    wallView(at: floor)
                }
                ForEach(Array(others.enumerated()), id: \.offset) { _, v in
                    let lo = max(0, v - BoardSchedule.minGapMin)
                    let hi = min(BoardSchedule.dayMin, v + BoardSchedule.minGapMin)
                    zoneView(from: lo, to: hi, kind: .red)
                    wallView(at: lo)
                    wallView(at: hi)
                    chainDiamond(at: (v + BoardSchedule.windowHours * 60) % BoardSchedule.dayMin)
                    zoneView(from: hi, to: min(BoardSchedule.dayMin, hi + 120), kind: .amber)
                }
                if model.dragOrigin.indices.contains(i), model.dragOrigin[i] != dv {
                    let origin = model.dragOrigin[i]
                    BoardChargeBlock(trigger: TrackDragModel.triggerOf(origin), reset: origin, ghost: true)
                }
            }
        }
    }

    private enum ZoneKind { case red, amber }

    private func zoneView(from: Int, to: Int, kind: ZoneKind) -> some View {
        let x0 = BoardGeometry.toPx(Double(from))
        let x1 = BoardGeometry.toPx(Double(to))
        let w = max(0, x1 - x0)
        return Group {
            switch kind {
            case .red:
                BoardDiagonalHatch(stripeColor: CockpitTheme.critZone1, backgroundColor: CockpitTheme.critZone2)
                    .frame(width: w, height: 37)
            case .amber:
                Rectangle().fill(CockpitTheme.warnZone).frame(width: w, height: 37)
            }
        }
        .position(x: x0 + w / 2, y: 31 + 18.5)
        .allowsHitTesting(false)
    }

    private func wallView(at m: Int) -> some View {
        Rectangle()
            .fill(CockpitTheme.crit)
            .frame(width: 2, height: 45)
            .position(x: BoardGeometry.toPx(Double(m)), y: 27 + 22.5)
            .allowsHitTesting(false)
    }

    private func chainDiamond(at m: Int) -> some View {
        Rectangle()
            .fill(CockpitTheme.ok)
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .shadow(color: CockpitTheme.ok.opacity(0.6), radius: 3)
            .position(x: BoardGeometry.toPx(Double(m)), y: 45 + 4)
            .allowsHitTesting(false)
    }

    // MARK: - flash (drag illegal-move feedback)

    @ViewBuilder private var flashOverlay: some View {
        if let flash = model.flash {
            let x0 = BoardGeometry.toPx(Double(flash.from))
            let x1 = BoardGeometry.toPx(Double(flash.to))
            let w = max(0, x1 - x0)
            RoundedRectangle(cornerRadius: 3)
                .fill(CockpitTheme.warnRaw)
                .frame(width: w, height: 37)
                .position(x: x0 + w / 2, y: 31 + 18.5)
                .opacity(flashOpacity)
                .allowsHitTesting(false)
                .onAppear { runFlash(key: flash.key) }
                .onChange(of: flash.key) { runFlash(key: $0) }
        }
    }

    /// Two-stage keyframe: 0 -> 0.4 over 175ms (25% of 700ms), 0.4 -> 0 over
    /// the remaining 525ms — Track.tsx's `transition={{ duration: 0.7,
    /// times: [0, 0.25, 1] }}`. Clears `model.flash` on completion
    /// (`onAnimationComplete`'s native equivalent).
    private func runFlash(key: Int) {
        flashKey = key
        flashOpacity = 0
        withAnimation(.easeInOut(duration: 0.175)) { flashOpacity = 0.4 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.175) {
            guard flashKey == key else { return }
            withAnimation(.easeInOut(duration: 0.525)) { flashOpacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.525) {
                guard flashKey == key else { return }
                model.clearFlash()
            }
        }
    }

    // MARK: - hover-only "+ HH:MM" create preview

    @ViewBuilder private var hoverPreviewBadge: some View {
        if let preview = model.hoverPreview {
            Text("+ \(BoardSchedule.fmtHM(preview))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(CockpitTheme.sec)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(CockpitTheme.ok.opacity(0.35)))
                .fixedSize()
                .position(x: BoardGeometry.toPx(Double(preview)), y: 40 + 6)
                .allowsHitTesting(false)
        }
    }

    // MARK: - HUD (drag-only)

    @ViewBuilder private var hudOverlay: some View {
        if model.isDragging, model.values.indices.contains(model.draggingIndex) {
            let i = model.draggingIndex
            let dv = model.values[i]
            let n = model.values.count
            let chained = n > 1 && i > 0 && BoardSchedule.circularGap(TrackDragModel.triggerOf(dv), model.values[i - 1]) == 0
            BoardHud(reset: dv, trigger: TrackDragModel.triggerOf(dv), chained: chained, warn: chained ? nil : "busy-risk")
                .opacity(hudOpacity)
        }
    }

    // MARK: - create (tap on empty track)

    private var createGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .named("track"))
            .onEnded { value in
                onSelect(nil)
                let minutes = TrackDragModel.snappedMinutes(fromTrackX: value.location.x)
                model.createAt(minutes)
            }
    }

    // MARK: - chips (the schedule thumbs + their annotations)

    private var chips: some View {
        ForEach(Array(model.laneSchedules.enumerated()), id: \.element.schedule.id) { i, ls in
            chipRow(index: i, ls: ls)
        }
    }

    @ViewBuilder
    private func chipRow(index i: Int, ls: BoardClassify.LaneSchedule) -> some View {
        if model.values.indices.contains(i) {
            let v = model.values[i]
            let trigger = TrackDragModel.triggerOf(v)
            let n = model.values.count
            let chained = n > 1 && i > 0 && BoardSchedule.circularGap(trigger, model.values[i - 1]) == 0
            let nextChained = n > 1 && i < n - 1 && BoardSchedule.circularGap(TrackDragModel.triggerOf(model.values[i + 1]), v) == 0
            let live = BoardClassify.LaneSchedule(schedule: ls.schedule, trigger: trigger, reset: v, chained: chained)
            let cls = BoardClassify.classify(live, nowMinutes: nowMinutes, mid: mid)
            let copy = BoardClassify.chipCopy(live, cls, mid)
            let dot = BoardClassify.chipDot(cls, chained: chained)
            let selected = selectedID == ls.schedule.id

            ZStack(alignment: .topLeading) {
                BoardChargeBlock(
                    trigger: trigger, reset: v, squareLeft: chained, squareRight: nextChained,
                    dragging: model.draggingIndex == i, hovered: model.hoveredIndex == i
                )

                if chained {
                    chainBadge(at: v - BoardSchedule.windowHours * 60)
                }

                Rectangle()
                    .fill(CockpitTheme.chipBd)
                    .frame(width: 1.5, height: 8)
                    .position(x: BoardGeometry.toPx(Double(v)), y: 26 + 4)
                    .allowsHitTesting(false)

                // A REAL Button, not a tap gesture: AXPress on a genuine
                // button is the only AX invocation System Events reliably
                // delivers to SwiftUI (custom accessibilityAction closures
                // are never invoked — measured), so select-to-inspect stays
                // drivable for AX users and the e2e. The drag rides a
                // high-priority gesture with a 3pt threshold: a still click
                // is the button (select), any real movement is the drag —
                // the web's pointerdown/click split, within one detent's
                // width of feel.
                Button {
                    focusedIndex = i
                    onSelect(ls.schedule.id)
                } label: {
                    BoardTimeChip(label: BoardSchedule.fmtHM(v), dot: dot, selected: selected, removing: model.removingIndex == i)
                }
                    .buttonStyle(.plain)
                    .focusable(true)
                    .focused($focusedIndex, equals: i)
                    .onMoveCommand { direction in
                        switch direction {
                        case .left: model.keyboardMove(index: i, delta: -BoardSchedule.snapMin)
                        case .right: model.keyboardMove(index: i, delta: BoardSchedule.snapMin)
                        default: break
                        }
                    }
                    .onDeleteCommand { model.keyboardDelete(index: i) }
                    .onHover { inside in model.setHovered(inside ? i : nil) }
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 3, coordinateSpace: .named("track"))
                            .onChanged { value in
                                if model.draggingIndex != i { model.beginDrag(index: i) }
                                model.moveDrag(to: TrackDragModel.snappedMinutes(fromTrackX: value.location.x))
                                model.updateRemoval(dy: abs(value.location.y - BoardGeometry.rowPx / 2))
                            }
                            .onEnded { _ in model.endDrag() }
                    )
                    // Same flattening hazard as the track: a gesture-bearing
                    // plain view is not an AX element by default — combine
                    // exposes one addressable element per chip.
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("chip-\(ls.schedule.id)")
                    .accessibilityLabel("reset at \(BoardSchedule.fmtHM(v)) for \(accountLabel)")
                    // VoiceOver: a chip adjusts like the slider it is —
                    // increment/decrement = the ±15-min keyboard moves; the
                    // named action = Backspace/Delete. Also the e2e's
                    // MOVE/DELETE drivers (AX actions reach a backgrounded
                    // window; synthesized keystrokes do not).
                    .accessibilityAdjustableAction { direction in
                        model.keyboardMove(index: i, delta: direction == .increment ? BoardSchedule.snapMin : -BoardSchedule.snapMin)
                    }
                    .accessibilityAction(named: "Remove reset") {
                        model.keyboardDelete(index: i)
                    }
                    // LAST on purpose: .position sizes its container to the
                    // full track, so any AX modifier applied after it would
                    // report a 1160x116 frame for every chip — VoiceOver's
                    // cursor rect and hit lookup would be wrong on all of
                    // them.
                    .position(x: BoardGeometry.toPx(Double(v)), y: 6 + 10)

                if let suffix = copy.suffix {
                    Text(suffix)
                        .font(.system(size: 10, weight: copy.suffixTone == "amber" ? .semibold : .regular))
                        .foregroundColor(suffixColor(copy.suffixTone))
                        .fixedSize()
                        .offset(x: BoardGeometry.toPx(Double(v)) + 68, y: 11)
                        .allowsHitTesting(false)
                }

                Text(copy.trigLine)
                    .font(.system(size: 9.5))
                    .foregroundColor(copy.trigTone == "amber" ? CockpitTheme.warn : CockpitTheme.ter)
                    .fixedSize()
                    .offset(x: BoardGeometry.toPx(Double(trigger)) - 3, y: 71)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(copy.trigTone == "amber" ? CockpitTheme.warnRaw : CockpitTheme.ter)
                    .opacity(0.8)
                    .frame(width: 1.5, height: 6)
                    .offset(x: BoardGeometry.toPx(Double(trigger)), y: 64)
                    .allowsHitTesting(false)
            }
        }
    }

    private func chainBadge(at m: Int) -> some View {
        ZStack {
            Circle().fill(CockpitTheme.win)
            Circle().strokeBorder(CockpitTheme.hair, lineWidth: 1)
            Text("⛓︎").font(.system(size: 9)).foregroundColor(CockpitTheme.sec)
        }
        .frame(width: 16, height: 16)
        .position(x: BoardGeometry.toPx(Double(m)), y: 41 + 8)
        .allowsHitTesting(false)
    }

    private func suffixColor(_ tone: String) -> Color {
        switch tone {
        case "ok": return CockpitTheme.okTx
        case "amber": return CockpitTheme.warn
        default: return CockpitTheme.sec
        }
    }
}

private extension View {
    /// `handleRootPointerMove`'s hover-preview tracking needs a location,
    /// not just an in/out boolean — `onContinuousHover(coordinateSpace:)`
    /// is a macOS 13.3+ API (this project's floor is macOS 13.0,
    /// project.yml), so it's gated behind an availability check; on an
    /// older 13.x runtime the hover-only "+ HH:MM" badge simply never
    /// appears (`hoverPreview` stays nil) — a P2 cosmetic gap on old OS
    /// minor versions only, never a compile-time or crash risk.
    @ViewBuilder
    func trackHoverPreview(_ handler: @escaping (CGPoint?) -> Void) -> some View {
        if #available(macOS 13.3, *) {
            onContinuousHover(coordinateSpace: .named("track")) { phase in
                switch phase {
                case let .active(location): handler(location)
                case .ended: handler(nil)
                }
            }
        } else {
            self
        }
    }
}
