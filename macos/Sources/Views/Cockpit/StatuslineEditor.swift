import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The statusline editor's view half (the model half is
// StatuslineEditorModel.swift). Rebuilt 2026-10-03 (owner-picked design,
// UX audit U1): the line IS the UI — a strip of
// draggable chips, each carrying the segment's own rendered bytes, above a
// tray of everything not on it. Drag between the strips to add, remove and
// reorder; click a chip for its options. The preview strip stays the
// daemon's bytes for the whole line (preview == production).

private extension Color {
    /// Parses `#rrggbb` (the only shape a statusline "color" option ever
    /// carries — internal/statusline/tier.go parseHex). Distinct from
    /// Ansi.swift's `AnsiSpan.swiftUIColor`, which also accepts `rgb(...)`
    /// for preview-strip spans; option values are hex-only.
    init?(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    /// The inverse — matches HTML `<input type="color">`'s own wire format
    /// (lowercase `#rrggbb`), which is what the web editor stores.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

/// One segment's option row — native mirror of StatuslineDialog.tsx's
/// `OptionControl` (lines 39-114): bool -> Toggle, enum -> Picker,
/// color -> ColorPicker + conditional "clear" link, string -> TextField
/// where an empty value DELETES the key.
private struct StatuslineOptionControl: View {
    let spec: SLOptionSpec
    let segLabel: String
    let segmentID: String
    @ObservedObject var model: StatuslineEditorModel

    private var currentValue: JSONValue? { model.optionValue(segmentID: segmentID, key: spec.key) }
    private var a11yLabel: String { "\(segLabel): \(spec.label)" }

    var body: some View {
        HStack(spacing: 12) {
            Text(spec.label).font(.system(size: 11.5)).foregroundColor(CockpitTheme.sec)
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.type {
        case "bool":
            Toggle("", isOn: Binding(
                get: { (currentValue ?? spec.defaultValue)?.boolValue == true },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: .bool($0)) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(a11yLabel)

        case "enum":
            let values = spec.values ?? []
            let current = currentValue?.stringValue ?? spec.defaultValue?.stringValue ?? values.first ?? ""
            Picker("", selection: Binding(
                get: { current },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: .string($0)) }
            )) {
                ForEach(values, id: \.self) { v in Text(v).tag(v) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 200)
            .accessibilityLabel(a11yLabel)

        case "color":
            let isSet: Bool = {
                if case let .string(s)? = currentValue, !s.isEmpty { return true }
                return false
            }()
            let hex = isSet ? (currentValue?.stringValue ?? "#0a7aff") : "#0a7aff"
            HStack(spacing: 6) {
                if isSet {
                    Button("clear") {
                        model.setOption(segmentID: segmentID, key: spec.key, value: nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
                    .accessibilityLabel("Clear \(a11yLabel)")
                }
                ColorPicker("", selection: Binding(
                    get: { Color(hexString: hex) ?? CockpitTheme.accent },
                    set: { model.setOption(segmentID: segmentID, key: spec.key, value: .string($0.hexString)) }
                ))
                .labelsHidden()
                .accessibilityLabel(a11yLabel)
            }

        default: // "string"
            TextField("", text: Binding(
                get: { currentValue?.stringValue ?? "" },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: $0.isEmpty ? nil : .string($0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 160)
            .accessibilityLabel(a11yLabel)
        }
    }
}

// MARK: - chip flow layout

/// Wraps chips into rows like the mock's flex-wrap strips. A `Layout` so
/// the strips can report real chip frames for drop-index math.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// Chip frames in the line strip's coordinate space, for the drop index.
private struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Pure: where a drop at `point` lands among chips laid out in rows — the
/// index of the first chip that is on a LOWER row, or on the same row with
/// its midpoint right of the point. `count` when past every chip.
enum ChipDrop {
    static func index(at point: CGPoint, frames: [CGRect]) -> Int {
        for (i, f) in frames.enumerated() {
            if point.y < f.minY { return i }
            if point.y <= f.maxY, point.x < f.midX { return i }
        }
        return frames.count
    }
}

// MARK: - the editor

struct StatuslineEditorView: View {
    @ObservedObject var model: StatuslineEditorModel
    var offline: Bool = false

    /// The chip whose options popover is open.
    @State private var selectedID: String?
    @State private var lineTargeted = false
    @State private var trayTargeted = false
    @State private var chipFrames: [String: CGRect] = [:]

    var body: some View {
        Group {
            if offline {
                offlineView
            } else {
                onlineView
            }
        }
        .task(id: offline) { // re-load when the daemon comes up mid-open (StatuslineDialog.tsx:140 deps [open, offline])
            guard !offline else { return }
            await model.load()
        }
    }

    // MARK: - offline (StatuslineDialog.tsx:192-197)

    private var offlineView: some View {
        (
            Text(StatuslineEditorCopy.offlinePrefix)
                + Text(StatuslineEditorCopy.offlineCommand).fontWeight(.semibold).font(.system(size: 12, design: .monospaced))
        )
        .font(.system(size: 12))
        .foregroundColor(CockpitTheme.sec)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - online

    private var onlineView: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewSection
            Text(StatuslineEditorCopy.previewHelper)
                .font(.system(size: 10.5))
                .foregroundColor(CockpitTheme.ter)
                .fixedSize(horizontal: false, vertical: true)

            if let err = model.err {
                CockpitWarnBox {
                    Text(err).font(.system(size: 11)).foregroundColor(CockpitTheme.warn)
                }
            }

            keptStatuslineChip

            if model.meta != nil {
                eyebrow(StatuslineEditorCopy.presetHeader)
                presetsRow

                HStack(alignment: .firstTextBaseline) {
                    eyebrow(StatuslineEditorCopy.yourLineHeader)
                    Spacer()
                    let n = model.draft?.segments.count ?? 0
                    if n > 0 {
                        Text("\(n) segment\(n == 1 ? "" : "s")")
                            .font(CockpitTheme.numeric(10.5))
                            .foregroundColor(CockpitTheme.ter)
                    }
                }
                lineStrip
                Text(StatuslineEditorCopy.legend)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)

                eyebrow(StatuslineEditorCopy.trayHeader)
                trayStrip
            }

            footer
        }
        // No root padding: SheetChrome owns the inset ring (owner
        // 2026-08-13 — the doubled padding broke the HIG's equal-margins
        // rule on all three cockpit sheets).
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundColor(CockpitTheme.ter)
    }

    // MARK: - preview strip (StatuslineDialog.tsx:200-223)

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command = model.draft?.keep?.command {
                Text(StatuslineEditorCopy.keptPreviewNote(command))
                    .font(.system(size: 11.5, design: .monospaced))
                    .italic()
                    .foregroundColor(CockpitTheme.grayDot)
            }
            // Horizontally scrollable like the web's overflow-x-auto strip
            // (StatuslineDialog.tsx:211): the daemon renders at 120 columns,
            // wider than any sheet — a clipped preview would defeat the
            // preview==production promise.
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if model.preview.isEmpty {
                        Text(model.draft?.segments.isEmpty == true
                            ? StatuslineEditorCopy.emptyLine
                            : StatuslineEditorCopy.renderingPlaceholder)
                            .foregroundColor(CockpitTheme.grayDot)
                    } else {
                        Text(ansiAttributedString(parseAnsi(model.preview), defaultColor: CockpitTheme.hudTx))
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .accessibilityLabel("Statusline preview")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CockpitTheme.hudBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - kept statusline chip (StatuslineDialog.tsx:236-250)

    @ViewBuilder
    private var keptStatuslineChip: some View {
        if let command = model.draft?.keep?.command {
            HStack {
                (
                    Text(StatuslineEditorCopy.keptStatuslineTitle).fontWeight(.semibold)
                        + Text(StatuslineEditorCopy.keptStatuslineMid)
                        + Text(command).font(.system(size: 10.5, design: .monospaced))
                )
                .font(.system(size: 11))
                .foregroundColor(CockpitTheme.sec)
                Spacer(minLength: 8)
                Button(action: { model.clearKeep() }) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(CockpitTheme.ter)
                .accessibilityLabel("Remove kept statusline")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
        }
    }

    // MARK: - presets (a segmented control; Custom lights up by itself)

    private var presetsRow: some View {
        let presets = model.meta?.presets ?? []
        let selected = model.selectedPresetID
        return HStack(spacing: 2) {
            ForEach(presets) { p in
                presetSegment(title: p.name, isOn: selected == p.id, enabled: true) {
                    selectedID = nil
                    model.selectPreset(p)
                }
                .help(Text(p.desc))
                .accessibilityIdentifier("statusline-preset-\(p.id)")
            }
            presetSegment(title: StatuslineEditorCopy.customPreset, isOn: selected.isEmpty, enabled: false) {}
                .help(Text("Becomes active as soon as you change the line"))
                .accessibilityIdentifier("statusline-preset-custom")
        }
        .padding(2)
        .background(CockpitTheme.hatchBg)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(CockpitTheme.hairSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func presetSegment(title: String, isOn: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isOn ? CockpitTheme.text : (enabled ? CockpitTheme.sec : CockpitTheme.grayDot))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(isOn ? CockpitTheme.toolbar : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn ? CockpitTheme.hair : Color.clear, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - your line

    private var lineSegments: [SLSegmentConfig] { model.draft?.segments ?? [] }

    private var lineStrip: some View {
        let segs = lineSegments
        return ZStack(alignment: .center) {
            if segs.isEmpty {
                Text(StatuslineEditorCopy.emptyLine)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.grayDot)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ChipFlowLayout(spacing: 6) {
                    ForEach(segs, id: \.id) { sc in
                        chip(id: sc.id, options: sc.options, onLine: true)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: ChipFramesKey.self, value: [sc.id: geo.frame(in: .named("statusline-line"))])
                            })
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(lineTargeted ? CockpitTheme.accA : CockpitTheme.toolbar)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(lineTargeted ? CockpitTheme.accBd : CockpitTheme.hair, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .coordinateSpace(name: "statusline-line")
        .onPreferenceChange(ChipFramesKey.self) { chipFrames = $0 }
        .dropDestination(for: String.self) { ids, location in
            guard let id = ids.first else { return false }
            selectedID = nil
            let ordered = lineSegments.map(\.id)
            let frames = ordered.compactMap { chipFrames[$0] }
            let index = frames.count == ordered.count
                ? ChipDrop.index(at: location, frames: frames)
                : ordered.count
            if ordered.contains(id) {
                model.moveSegment(id, before: index)
            } else {
                model.addSegment(id, at: index)
            }
            return true
        } isTargeted: { lineTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(StatuslineEditorCopy.yourLineHeader)
        .accessibilityIdentifier("statusline-line")
    }

    // MARK: - not in your line

    private var trayStrip: some View {
        let available = model.availableSegments
        return ZStack {
            if available.isEmpty {
                Text(StatuslineEditorCopy.trayEmpty)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.grayDot)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                ChipFlowLayout(spacing: 6) {
                    ForEach(available) { spec in
                        chip(id: spec.id, options: nil, onLine: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(trayTargeted ? CockpitTheme.accA : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundColor(trayTargeted ? CockpitTheme.accBd : CockpitTheme.hair))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, lineSegments.contains(where: { $0.id == id }) else { return false }
            selectedID = nil
            model.removeSegment(id)
            return true
        } isTargeted: { trayTargeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(StatuslineEditorCopy.trayHeader)
        .accessibilityIdentifier("statusline-tray")
    }

    // MARK: - chip

    private func chip(id: String, options: [String: JSONValue]?, onLine: Bool) -> some View {
        let spec = model.specFor(id)
        let name = spec?.name ?? id
        let rendered = model.segmentPreview(id: id, options: options)
        let bytes = rendered?.line
        let isSelected = selectedID == id
        let lineIDs = lineSegments.map(\.id)
        let position = lineIDs.firstIndex(of: id)
        // A Button, not a tap gesture: it is focusable under Full Keyboard
        // Access and Space/Return opens the options — the keyboard and
        // VoiceOver path the old chevron buttons used to be (review
        // 2026-10-03 P1). The drag still starts on movement.
        return Button(action: { selectedID = isSelected ? nil : id }) {
            VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(CockpitTheme.grayDot)
                    .accessibilityHidden(true)
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundColor(onLine ? CockpitTheme.accTx : CockpitTheme.sec)
                if spec?.fleet == true {
                    Text(StatuslineEditorCopy.daemonBadge)
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(CockpitTheme.chipBg)
                        .foregroundColor(CockpitTheme.accTx)
                        .clipShape(Capsule())
                }
            }
            Group {
                if let bytes, !bytes.isEmpty {
                    Text(ansiAttributedString(parseAnsi(bytes), defaultColor: CockpitTheme.text))
                        .font(.system(size: 11.5, design: .monospaced))
                } else if bytes != nil {
                    Text(StatuslineEditorCopy.quietSegment)
                        .font(.system(size: 11))
                        .foregroundColor(CockpitTheme.grayDot)
                } else {
                    Text(StatuslineEditorCopy.renderingPlaceholder)
                        .font(.system(size: 11))
                        .foregroundColor(CockpitTheme.grayDot)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            }
            // Wide enough for a long fleet line, never wider than the strip:
            // a chip past the strip's edge used to be cut mid-text.
            .frame(maxWidth: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(onLine ? CockpitTheme.chipBg : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(onLine ? CockpitTheme.chipBd : CockpitTheme.hair, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(CockpitTheme.accent, lineWidth: isSelected ? 2.5 : 0))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(onLine ? 1 : 0.62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(id)
        .popover(isPresented: Binding(get: { selectedID == id }, set: { if !$0, selectedID == id { selectedID = nil } }),
                 arrowEdge: .bottom) {
            optionsPopover(id: id, onLine: onLine)
        }
        .accessibilityLabel("\(name), \(onLine ? StatuslineEditorCopy.onLine : StatuslineEditorCopy.offLine)")
        .accessibilityValue(rendered?.plain ?? "")
        .accessibilityAction(named: Text(onLine ? StatuslineEditorCopy.takeOffLine : StatuslineEditorCopy.addToLine)) {
            if onLine { model.removeSegment(id) } else { model.addSegment(id) }
        }
        .accessibilityAction(named: Text(StatuslineEditorCopy.moveLeft)) {
            if let position, position > 0 { model.moveSegment(id, before: position - 1) }
        }
        .accessibilityAction(named: Text(StatuslineEditorCopy.moveRight)) {
            if let position, position < lineIDs.count - 1 { model.moveSegment(id, before: position + 2) }
        }
        .accessibilityIdentifier("statusline-chip-\(id)")
    }

    // MARK: - options popover

    private func optionsPopover(id: String, onLine: Bool) -> some View {
        let spec = model.specFor(id)
        let name = spec?.name ?? id
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(name)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundColor(CockpitTheme.ter)
                Spacer()
                Text(onLine ? StatuslineEditorCopy.onLine : StatuslineEditorCopy.offLine)
                    .font(.system(size: 9))
                    .foregroundColor(CockpitTheme.grayDot)
            }
            .padding(.bottom, 4)
            if let desc = spec?.desc, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10.5))
                    .foregroundColor(CockpitTheme.ter)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
            }
            if let opts = spec?.options, !opts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(opts, id: \.key) { o in
                        StatuslineOptionControl(spec: o, segLabel: name, segmentID: id, model: model)
                            .overlay(alignment: .top) { Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1) }
                    }
                }
            }
            HStack(spacing: 10) {
                if onLine {
                    Button(StatuslineEditorCopy.takeOffLine) {
                        selectedID = nil
                        model.removeSegment(id)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(CockpitTheme.crit)
                    .accessibilityIdentifier("statusline-chip-remove")
                    let ids = lineSegments.map(\.id)
                    if let at = ids.firstIndex(of: id) {
                        Button(action: { model.moveSegment(id, before: at - 1) }) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(at == 0)
                        .opacity(at == 0 ? 0.3 : 1)
                        .foregroundColor(CockpitTheme.sec)
                        .accessibilityLabel(StatuslineEditorCopy.moveLeft)
                        .accessibilityIdentifier("statusline-chip-move-left")
                        Button(action: { model.moveSegment(id, before: at + 2) }) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .disabled(at == ids.count - 1)
                        .opacity(at == ids.count - 1 ? 0.3 : 1)
                        .foregroundColor(CockpitTheme.sec)
                        .accessibilityLabel(StatuslineEditorCopy.moveRight)
                        .accessibilityIdentifier("statusline-chip-move-right")
                    }
                } else {
                    Button(StatuslineEditorCopy.addToLine) {
                        selectedID = nil
                        model.addSegment(id)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(CockpitTheme.accTx)
                    .accessibilityIdentifier("statusline-chip-add")
                }
                Spacer()
                Button(StatuslineEditorCopy.done) { selectedID = nil }
                    .buttonStyle(.plain)
                    .foregroundColor(CockpitTheme.accTx)
            }
            .font(.system(size: 11.5))
            .padding(.top, 8)
            .overlay(alignment: .top) { Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1) }
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - footer (StatuslineDialog.tsx:392-415)

    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: { model.apply() }) {
                Text(StatuslineEditorCopy.applyButton)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(CockpitTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(model.canApply ? 1 : 0.4)
            .disabled(!model.canApply)
            .accessibilityIdentifier("statusline-apply")

            Button(action: { model.discard() }) {
                Text(StatuslineEditorCopy.discardButton)
                    .font(.system(size: 12))
                    .foregroundColor(CockpitTheme.sec)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.hair, lineWidth: 1))
            .opacity(model.dirty ? 1 : 0.4)
            .disabled(!model.dirty)
            .accessibilityIdentifier("statusline-discard")

            if model.applied {
                Text(StatuslineEditorCopy.applied)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.okTx)
                    .padding(.top, 6)
            }

            Spacer(minLength: 8)

            // U5: wire Claude Code from the same sheet — no terminal.
            StatuslineInstallControl(model: model.install)
                .frame(maxWidth: 260, alignment: .trailing)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1)
        }
    }
}
