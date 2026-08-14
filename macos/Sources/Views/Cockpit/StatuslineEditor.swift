import AppKit
import SwiftUI

// Native port of web/src/shell/StatuslineDialog.tsx's markup half — the
// model half (fetch/debounce/preset-detach/apply-discard) lives in
// StatuslineEditorModel.swift. Split the same way StashPanelView.swift
// pairs StashPanelModel with its View.

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
        switch spec.type {
        case "bool":
            Toggle(isOn: Binding(
                get: { (currentValue ?? spec.defaultValue)?.boolValue == true },
                set: { model.setOption(segmentID: segmentID, key: spec.key, value: .bool($0)) }
            )) {
                Text(spec.label).font(.system(size: 10.5)).foregroundColor(CockpitTheme.sec)
            }
            .toggleStyle(.switch)
            .accessibilityLabel(a11yLabel)

        case "enum":
            let values = spec.values ?? []
            let current = currentValue?.stringValue ?? spec.defaultValue?.stringValue ?? values.first ?? ""
            HStack(spacing: 4) {
                Text(spec.label).font(.system(size: 10.5)).foregroundColor(CockpitTheme.sec)
                Picker("", selection: Binding(
                    get: { current },
                    set: { model.setOption(segmentID: segmentID, key: spec.key, value: .string($0)) }
                )) {
                    ForEach(values, id: \.self) { v in Text(v).tag(v) }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(a11yLabel)

        case "color":
            let isSet: Bool = {
                if case let .string(s)? = currentValue, !s.isEmpty { return true }
                return false
            }()
            let hex = isSet ? (currentValue?.stringValue ?? "#0a7aff") : "#0a7aff"
            HStack(spacing: 4) {
                Text(spec.label).font(.system(size: 10.5)).foregroundColor(CockpitTheme.sec)
                ColorPicker("", selection: Binding(
                    get: { Color(hexString: hex) ?? CockpitTheme.accent },
                    set: { model.setOption(segmentID: segmentID, key: spec.key, value: .string($0.hexString)) }
                ))
                .labelsHidden()
                .accessibilityLabel(a11yLabel)
                if isSet {
                    Button("clear") {
                        model.setOption(segmentID: segmentID, key: spec.key, value: nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(CockpitTheme.ter)
                    .accessibilityLabel("Clear \(a11yLabel)")
                }
            }

        default: // "string"
            HStack(spacing: 4) {
                Text(spec.label).font(.system(size: 10.5)).foregroundColor(CockpitTheme.sec)
                TextField("", text: Binding(
                    get: { currentValue?.stringValue ?? "" },
                    set: { model.setOption(segmentID: segmentID, key: spec.key, value: $0.isEmpty ? nil : .string($0)) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10.5))
                .frame(width: 150)
                .accessibilityLabel(a11yLabel)
            }
        }
    }
}

struct StatuslineEditorView: View {
    @ObservedObject var model: StatuslineEditorModel
    var offline: Bool = false

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

            if let err = model.err {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.warn)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(CockpitTheme.warnBg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CockpitTheme.warnBd, lineWidth: 1))
            }

            keptStatuslineChip

            presetsRow

            segmentListSection

            addSegmentsSection

            footer

            (
                Text(StatuslineEditorCopy.installHintPrefix)
                    + Text(StatuslineEditorCopy.installHintCommand).fontWeight(.semibold).font(.system(size: 10.5, design: .monospaced))
                    + Text(StatuslineEditorCopy.installHintSuffix)
            )
            .font(.system(size: 10.5))
            .foregroundColor(CockpitTheme.ter)
            .fixedSize(horizontal: false, vertical: true)
        }
        // No root padding: SheetChrome owns the inset ring (owner
        // 2026-08-13 — the doubled padding broke the HIG's equal-margins
        // rule on all three cockpit sheets).
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
                        Text(StatuslineEditorCopy.renderingPlaceholder)
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
                    Text("✕").font(.system(size: 11))
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

    // MARK: - presets (StatuslineDialog.tsx:252-270)

    @ViewBuilder
    private var presetsRow: some View {
        if let presets = model.meta?.presets, !presets.isEmpty {
            HStack(spacing: 8) {
                ForEach(presets) { p in
                    let selected = model.draft?.preset == p.id
                    Button(action: { model.selectPreset(p) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.system(size: 11.5, weight: .semibold))
                            Text(p.desc).font(.system(size: 10)).foregroundColor(CockpitTheme.ter).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(selected ? CockpitTheme.accA : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? CockpitTheme.accBd : CockpitTheme.hair, lineWidth: 1))
                }
            }
        }
    }

    // MARK: - segment list (StatuslineDialog.tsx:272-363)

    private var segmentListSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(StatuslineEditorCopy.yourLineHeader)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(CockpitTheme.ter)
                .textCase(.uppercase)

            let segments = model.draft?.segments ?? []
            if segments.isEmpty {
                Text(StatuslineEditorCopy.emptyLine)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.ter)
                    .padding(.vertical, 6)
            } else {
                List {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { idx, sc in
                        segmentRow(sc, index: idx, count: segments.count)
                            .listRowSeparator(.visible)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                    .onMove { model.onMove(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(segments.count) * 44 + 8, 260))
            }
        }
    }

    private func segmentRow(_ sc: SLSegmentConfig, index: Int, count: Int) -> some View {
        let spec = model.specFor(sc.id)
        let name = spec?.name ?? sc.id
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(CockpitTheme.grayDot)
                .font(.system(size: 11))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 12, weight: .semibold))
                    if spec?.fleet == true {
                        Text("daemon")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(CockpitTheme.chipBg)
                            .foregroundColor(CockpitTheme.accTx)
                            .clipShape(Capsule())
                    }
                }
                if let opts = spec?.options, !opts.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(opts, id: \.key) { o in
                            StatuslineOptionControl(spec: o, segLabel: name, segmentID: sc.id, model: model)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 2) {
                Button(action: { model.move(from: index, to: index - 1) }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.3 : 1)
                .accessibilityLabel("Move \(name) up")

                Button(action: { model.move(from: index, to: index + 1) }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .disabled(index == count - 1)
                .opacity(index == count - 1 ? 0.3 : 1)
                .accessibilityLabel("Move \(name) down")

                Button(action: { model.removeSegment(sc.id) }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundColor(CockpitTheme.ter)
                .accessibilityLabel("Remove \(name)")
            }
            .font(.system(size: 11))
            .foregroundColor(CockpitTheme.ter)
        }
        .padding(.vertical, 4)
    }

    // MARK: - add segments (StatuslineDialog.tsx:365-390)

    @ViewBuilder
    private var addSegmentsSection: some View {
        let available = model.availableSegments
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(StatuslineEditorCopy.addSegmentsHeader)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(CockpitTheme.ter)
                    .textCase(.uppercase)
                HStack {
                    ForEach(available) { s in
                        Button(action: { model.addSegment(s.id) }) {
                            Text("+ \(s.name)").font(.system(size: 10.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(CockpitTheme.sec)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().stroke(CockpitTheme.hair, lineWidth: 1))
                        .help(Text(s.desc))
                        .accessibilityLabel("Add \(s.name)")
                    }
                }
            }
        }
    }

    // MARK: - footer (StatuslineDialog.tsx:392-415)

    private var footer: some View {
        HStack(spacing: 8) {
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

            if model.applied {
                Text(StatuslineEditorCopy.applied)
                    .font(.system(size: 11))
                    .foregroundColor(CockpitTheme.okTx)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(CockpitTheme.hairSoft).frame(height: 1)
        }
    }
}
