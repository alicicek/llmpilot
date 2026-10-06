import AppKit
import SwiftUI
import XCTest
@testable import llmpilot

/// U1 (audit 2026-10-02, rebuilt 2026-10-03): the chip editor's rules —
/// the preset segmented control derives from what the line IS, each chip
/// carries the renderer's bytes for its own (id, options), a drop lands
/// where the pointer is, and the full-line preview stays the daemon's
/// bytes for exactly the draft. Each test fails against the pre-rebuild
/// model.
@MainActor
final class StatuslineEditorChipsTests: XCTestCase {
    private enum Fixtures {
        static var segments: StatuslineSegmentsResponse {
            let json = """
            {
              "segments": [
                {"id":"account","name":"Account","desc":"which account","deps":["store"],"priority":90,"fleet":false,
                 "options":[{"key":"privacy","label":"Hide email","type":"bool","default":false}]},
                {"id":"usage","name":"Usage","desc":"runway buckets","deps":["store","stdin"],"priority":100,"fleet":false,
                 "options":[{"key":"mode","label":"Display","type":"enum","values":["percent","bar","time"],"default":"percent"}]},
                {"id":"context","name":"Context","desc":"context window","deps":["stdin"],"priority":70,"fleet":false,"options":[]}
              ],
              "presets": [
                {"id":"runway","name":"Runway","desc":"the classic line",
                 "config":{"version":1,"preset":"runway","segments":[{"id":"account"},{"id":"usage"}]}},
                {"id":"dev","name":"Dev","desc":"dev line",
                 "config":{"version":1,"preset":"dev","segments":[{"id":"context"},{"id":"usage"}]}}
              ]
            }
            """
            return try! JSONDecoder().decode(StatuslineSegmentsResponse.self, from: Data(json.utf8))
        }

        static var config: StatuslineConfigResponse {
            try! JSONDecoder().decode(StatuslineConfigResponse.self, from: Data("""
            {"config":{"version":1,"preset":"runway","segments":[{"id":"account"},{"id":"usage"}]},"load_error":""}
            """.utf8))
        }
    }

    private func loadedModel(_ api: StubCockpitAPI) async -> StatuslineEditorModel {
        api.statuslineSegmentsResult = .success(Fixtures.segments)
        api.statuslineConfigResult = .success(Fixtures.config)
        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "FULL", plain: "FULL", width: 120, tier: "truecolor"))
        api.statuslineSegmentPreviewByID = [
            "account": StatuslinePreviewResponse(line: "[acct 2/4 | rin@ashgrove.io]", plain: "", width: 0, tier: "truecolor"),
            "usage": StatuslinePreviewResponse(line: "5h:44%(03:41) wk:37%", plain: "", width: 0, tier: "truecolor"),
            "context": StatuslinePreviewResponse(line: "ctx:34%", plain: "", width: 0, tier: "truecolor"),
        ]
        let model = StatuslineEditorModel(api: api)
        model.previewDebounceDelay = 0.005
        await model.load()
        try? await Task.sleep(nanoseconds: 60_000_000)
        return model
    }

    // MARK: - presets derive from the line

    func testPresetMatchingIsExactIDsWithNoOptions() {
        let presets = Fixtures.segments.presets
        let runway = StatuslineConfig(version: 1, preset: nil, separator: nil, flex: nil, color: nil, keep: nil,
                                      segments: [SLSegmentConfig(id: "account", options: nil), SLSegmentConfig(id: "usage", options: nil)])
        XCTAssertEqual(StatuslineEditorModel.presetMatching(runway, presets: presets), "runway")
        var reordered = runway
        reordered.segments.reverse()
        XCTAssertNil(StatuslineEditorModel.presetMatching(reordered, presets: presets), "order is part of the line")
        var withOption = runway
        withOption.segments[0].options = ["privacy": .bool(true)]
        XCTAssertNil(StatuslineEditorModel.presetMatching(withOption, presets: presets), "an option edit is Custom")
        var extra = runway
        extra.segments.append(SLSegmentConfig(id: "context", options: nil))
        XCTAssertNil(StatuslineEditorModel.presetMatching(extra, presets: presets))
    }

    func testPresetRoundTripsThroughEditAndBack() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        XCTAssertEqual(model.selectedPresetID, "runway", "the saved line IS the Runway preset")

        model.addSegment("context")
        XCTAssertEqual(model.selectedPresetID, "", "an edit lights Custom")
        XCTAssertEqual(model.draft?.preset, "", "and the detach rule still clears the stored pick")

        model.removeSegment("context")
        XCTAssertEqual(model.selectedPresetID, "runway", "re-building a preset by hand re-lights its segment")

        model.selectPreset(Fixtures.segments.presets[1])
        XCTAssertEqual(model.selectedPresetID, "dev")
        XCTAssertEqual(model.draft?.segments.map(\.id), ["context", "usage"])
    }

    // MARK: - chips carry their own bytes

    func testSegmentPreviewKeysOnIDAndOptions() {
        XCTAssertEqual(StatuslineEditorModel.segmentPreviewKey(id: "usage", options: nil), "usage")
        XCTAssertEqual(StatuslineEditorModel.segmentPreviewKey(id: "usage", options: [:]), "usage")
        let bar = StatuslineEditorModel.segmentPreviewKey(id: "usage", options: ["mode": .string("bar")])
        let time = StatuslineEditorModel.segmentPreviewKey(id: "usage", options: ["mode": .string("time")])
        XCTAssertNotEqual(bar, time, "a Usage chip in bar mode is not the one in percent mode")
        XCTAssertTrue(bar.hasPrefix("usage|"))
    }

    func testEveryChipGetsTheRenderersBytesForItsSegment() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        XCTAssertEqual(model.segmentPreview(id: "account", options: nil)?.line, "[acct 2/4 | rin@ashgrove.io]")
        XCTAssertEqual(model.segmentPreview(id: "usage", options: nil)?.line, "5h:44%(03:41) wk:37%")
        XCTAssertEqual(model.segmentPreview(id: "context", options: nil)?.line, "ctx:34%", "tray chips render with defaults")
        // Every per-segment request was a ONE-segment config at the daemon.
        for cfgJSON in api.statuslineSegmentPreviewRequests {
            let cfg = try! JSONDecoder().decode(StatuslineConfig.self, from: Data(cfgJSON.utf8))
            XCTAssertEqual(cfg.segments.count, 1, "chip previews are per segment: \(cfgJSON)")
        }
        // An option edit asks again under the new key; the old key stays cached.
        let before = api.statuslineSegmentPreviewRequests.count
        model.setOption(segmentID: "usage", key: "mode", value: .string("bar"))
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(api.statuslineSegmentPreviewRequests.count, before + 1)
        XCTAssertNotNil(model.segmentPreview(id: "usage", options: ["mode": .string("bar")]))
        XCTAssertEqual(model.segmentPreview(id: "usage", options: nil)?.line, "5h:44%(03:41) wk:37%")
    }

    // MARK: - review 2026-10-03: the rules the first cut got wrong

    func testTrayChipOptionEditAddsTheSegmentCarryingIt() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.setOption(segmentID: "context", key: "x", value: .bool(true))
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "usage", "context"], "an option on a tray chip puts it on the line")
        XCTAssertEqual(model.draft?.segments.last?.options?["x"], .bool(true))
        // An id that is not in the registry is never added, by drop or by option.
        model.addSegment("hello from Safari")
        model.setOption(segmentID: "hello from Safari", key: "x", value: .bool(true))
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "usage", "context"])
    }

    func testReopeningTheEditorRefetchesEveryChip() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        let first = api.statuslineSegmentPreviewRequests.count
        XCTAssertGreaterThan(first, 0)
        await model.load()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(api.statuslineSegmentPreviewRequests.count, first * 2, "live numbers: a reopen renders every chip again")
    }

    func testEmptyLineShowsEmptyAndAsksTheDaemonNothing() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        let full = api.statuslinePreviewRequests.count
        model.removeSegment("account")
        model.removeSegment("usage")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.draft?.segments.count, 0)
        XCTAssertEqual(model.preview, "", "no previous line lingers under an empty draft")
        XCTAssertEqual(api.statuslinePreviewRequests.count, full, "the empty draft is never sent (the daemon 400s it)")
        XCTAssertNil(model.err)
    }

    func testPreviewErrorClearsOnTheNextGoodRender() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        api.statuslinePreviewResult = .failure(DaemonError.http(400, "unknown segment"))
        model.addSegment("context")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNotNil(model.err)
        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "OK", plain: "OK", width: 120, tier: "truecolor"))
        model.removeSegment("context")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(model.err, "a good render clears the preview's own error")
        XCTAssertEqual(model.preview, "OK")
    }

    func testPresetControlFollowsTheLineNotTheFileField() async {
        let api = StubCockpitAPI()
        api.statuslineSegmentsResult = .success(Fixtures.segments)
        api.statuslineConfigResult = .success(try! JSONDecoder().decode(StatuslineConfigResponse.self, from: Data("""
        {"config":{"version":1,"preset":"runway","segments":[{"id":"usage"},{"id":"account"}]},"load_error":""}
        """.utf8)))
        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "x", plain: "x", width: 120, tier: "truecolor"))
        let model = StatuslineEditorModel(api: api)
        model.previewDebounceDelay = 0.005
        await model.load()
        XCTAssertEqual(model.selectedPresetID, "", "the file says runway, the line is not runway: Custom")
    }

    // MARK: - the full-line preview is still the daemon's bytes for exactly the draft

    func testFullPreviewRequestIsTheDraftAndTheStripShowsItsBytes() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.addSegment("context", at: 0)
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard let last = api.statuslinePreviewRequests.last, let cfgJSON = last.config else {
            return XCTFail("no full-line preview request")
        }
        let decoded = try! JSONDecoder().decode(StatuslineConfig.self, from: Data(cfgJSON.utf8))
        XCTAssertEqual(decoded, model.draft, "the strip previews exactly the draft — never a client-side join of chips")
        XCTAssertEqual(decoded.segments.map(\.id), ["context", "account", "usage"])
        XCTAssertNil(last.width, "the full-line preview asks for width=auto")
        XCTAssertEqual(model.preview, "FULL")
    }

    // MARK: - drag lands where the pointer is

    func testDropIndexFollowsRowsThenMidpoints() {
        let frames = [CGRect(x: 0, y: 0, width: 100, height: 30), CGRect(x: 110, y: 0, width: 100, height: 30),
                      CGRect(x: 0, y: 40, width: 100, height: 30)]
        XCTAssertEqual(ChipDrop.index(at: CGPoint(x: 20, y: 10), frames: frames), 0)
        XCTAssertEqual(ChipDrop.index(at: CGPoint(x: 80, y: 10), frames: frames), 1, "past the first chip's midpoint")
        XCTAssertEqual(ChipDrop.index(at: CGPoint(x: 200, y: 10), frames: frames), 2, "past the row")
        XCTAssertEqual(ChipDrop.index(at: CGPoint(x: 10, y: 50), frames: frames), 2, "second row, before its chip's midpoint")
        XCTAssertEqual(ChipDrop.index(at: CGPoint(x: 300, y: 90), frames: frames), 3, "below everything appends")
    }

    func testMoveBeforeIndexAndAddAtIndexReorderTheLine() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        model.addSegment("context", at: 1)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "context", "usage"])
        model.moveSegment("usage", before: 0)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["usage", "account", "context"])
        model.moveSegment("usage", before: 3)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "context", "usage"], "dropping past the end appends")
        model.moveSegment("account", before: 1)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "context", "usage"], "dropping onto itself is a no-op")
        model.addSegment("account", at: 0)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "context", "usage"], "a segment is on the line once")
    }

    // MARK: - in-view drag (lift, follow, chips slide aside)

    private func drag(_ id: String, from home: ChipStrip, at homeIndex: Int, to target: ChipStrip, _ index: Int) -> ChipDrag {
        var d = ChipDrag(id: id, home: home, homeIndex: homeIndex, origin: .zero, press: .zero)
        d.target = target
        d.index = index
        return d
    }

    func testSlotsOpenTheGapWhereTheChipWouldLand() {
        let line = ["a", "b", "c", "d"]
        XCTAssertEqual(ChipDrop.slots(line, strip: .line, drag: nil), line.map(ChipSlot.chip), "no drag, no gap")
        // "a" picked up and aimed between c and d: its own view stays at
        // index 0 (collapsed by the view), the gap sits before d.
        XCTAssertEqual(ChipDrop.slots(line, strip: .line, drag: drag("a", from: .line, at: 0, to: .line, 2)),
                       [.chip("a"), .chip("b"), .chip("c"), .gap, .chip("d")])
        XCTAssertEqual(ChipDrop.slots(line, strip: .line, drag: drag("d", from: .line, at: 3, to: .line, 0)),
                       [.gap, .chip("a"), .chip("b"), .chip("c"), .chip("d")])
        XCTAssertEqual(ChipDrop.slots(line, strip: .line, drag: drag("b", from: .line, at: 1, to: .line, 3)),
                       [.chip("a"), .chip("b"), .chip("c"), .chip("d"), .gap], "past the end appends")
        // Aimed at the tray: the line shows no gap; the tray opens one.
        let away = drag("b", from: .line, at: 1, to: .tray, 1)
        XCTAssertEqual(ChipDrop.slots(line, strip: .line, drag: away), line.map(ChipSlot.chip))
        XCTAssertEqual(ChipDrop.slots(["x", "y"], strip: .tray, drag: away), [.chip("x"), .gap, .chip("y")])
        // Settling: the gap is gone — the chip itself holds the slot now.
        var settled = drag("a", from: .line, at: 0, to: .line, 2)
        settled.settling = true
        XCTAssertEqual(ChipDrop.slots(line, strip: .line, drag: settled), line.map(ChipSlot.chip))
    }

    func testLineIndexHoldsInsideTheGapAndFollowsMidpointsOutside() {
        let chips = [CGRect(x: 0, y: 0, width: 100, height: 30), CGRect(x: 180, y: 0, width: 100, height: 30)]
        let gap = CGRect(x: 106, y: 0, width: 68, height: 30)
        XCTAssertEqual(ChipDrop.lineIndex(at: CGPoint(x: 120, y: 15), chips: chips, gap: gap, current: 1), 1,
                       "inside the open gap the slot holds")
        XCTAssertEqual(ChipDrop.lineIndex(at: CGPoint(x: 40, y: 15), chips: chips, gap: gap, current: 1), 0)
        XCTAssertEqual(ChipDrop.lineIndex(at: CGPoint(x: 260, y: 15), chips: chips, gap: gap, current: 1), 2)
        XCTAssertEqual(ChipDrop.lineIndex(at: CGPoint(x: 120, y: 15), chips: chips, gap: nil, current: 9), 1,
                       "no gap yet: plain midpoint rule")
    }

    func testTrayIndexFollowsTheRegistryNotThePointer() {
        let registry = ["account", "usage", "burn", "context", "dir"]
        XCTAssertEqual(ChipDrop.trayIndex(of: "usage", registry: registry, tray: ["burn", "dir"]), 0)
        XCTAssertEqual(ChipDrop.trayIndex(of: "context", registry: registry, tray: ["burn", "dir"]), 1)
        XCTAssertEqual(ChipDrop.trayIndex(of: "dir", registry: registry, tray: ["account", "burn"]), 2)
        XCTAssertEqual(ChipDrop.trayIndex(of: "unknown", registry: registry, tray: ["burn"]), 1)
    }

    func testLandingMapsEachStripPairToOneModelEdit() {
        let line = ["a", "b", "c"]
        XCTAssertEqual(ChipDrop.landing(drag("a", from: .line, at: 0, to: .line, 2), line: line), .move("a", before: 3))
        XCTAssertEqual(ChipDrop.landing(drag("c", from: .line, at: 2, to: .line, 0), line: line), .move("c", before: 0))
        XCTAssertEqual(ChipDrop.landing(drag("b", from: .line, at: 1, to: .line, 1), line: line), .none, "dropped home")
        XCTAssertEqual(ChipDrop.landing(drag("b", from: .line, at: 1, to: .tray, 0), line: line), .remove("b"))
        XCTAssertEqual(ChipDrop.landing(drag("x", from: .tray, at: 0, to: .line, 1), line: line), .add("x", at: 1))
        XCTAssertEqual(ChipDrop.landing(drag("x", from: .tray, at: 0, to: .tray, 0), line: line), .none,
                       "the tray's order is the registry's")
        var outside = drag("a", from: .line, at: 0, to: .tray, 0)
        outside.goHome()
        XCTAssertEqual(ChipDrop.landing(outside, line: line), .none, "a drop outside both strips goes home")
    }

    func testLandingsReorderInsertAndRemoveThroughTheModel() async {
        let api = StubCockpitAPI()
        let model = await loadedModel(api)
        func land(_ d: ChipDrag) { ChipDrop.commit(ChipDrop.landing(d, line: model.draft?.segments.map(\.id) ?? []), to: model) }

        land(drag("context", from: .tray, at: 0, to: .line, 1))
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "context", "usage"], "insert at the gap")
        XCTAssertEqual(model.draft?.preset, "", "a drag edit detaches the preset like every other edit")
        land(drag("account", from: .line, at: 0, to: .line, 2))
        XCTAssertEqual(model.draft?.segments.map(\.id), ["context", "usage", "account"], "reorder to the end")
        land(drag("account", from: .line, at: 2, to: .line, 0))
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "context", "usage"], "reorder to the front")
        land(drag("context", from: .line, at: 1, to: .tray, 0))
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "usage"], "into the tray removes")
        XCTAssertEqual(model.selectedPresetID, "runway", "and the line is Runway again")
    }

    // MARK: - terminal width and the New line chip

    private static let esc = "\u{1B}"

    /// The registry as the daemon now serves it: `newline` is a segment.
    private func newlineRegistry() -> StatuslineSegmentsResponse {
        let json = """
        {"segments":[
          {"id":"account","name":"Account","desc":"","deps":[],"priority":90,"fleet":false,"options":[]},
          {"id":"newline","name":"New line","desc":"starts a second row","deps":[],"priority":0,"fleet":false,"options":[]},
          {"id":"model","name":"Model","desc":"","deps":[],"priority":60,"fleet":false,"options":[]}
        ],"presets":[]}
        """
        return try! JSONDecoder().decode(StatuslineSegmentsResponse.self, from: Data(json.utf8))
    }

    private func newlineModel(_ api: StubCockpitAPI, line: [String]) async -> StatuslineEditorModel {
        api.statuslineSegmentsResult = .success(newlineRegistry())
        let segs = line.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        api.statuslineConfigResult = .success(try! JSONDecoder().decode(StatuslineConfigResponse.self, from: Data(
            #"{"config":{"version":1,"preset":"","segments":[\#(segs)]},"load_error":""}"#.utf8)))
        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "a\nb", plain: "a\nb", width: 120, tier: "truecolor"))
        api.statuslineSegmentPreviewByID = [
            "account": StatuslinePreviewResponse(line: "acct", plain: "acct", width: 0, tier: "truecolor"),
            "model": StatuslinePreviewResponse(line: "Opus", plain: "Opus", width: 0, tier: "truecolor"),
        ]
        let model = StatuslineEditorModel(api: api)
        model.previewDebounceDelay = 0.005
        await model.load()
        try? await Task.sleep(nanoseconds: 60_000_000)
        return model
    }

    func testFullPreviewAsksForAutoWidthAndChipsKeepZero() async {
        let api = StubCockpitAPI()
        let model = await newlineModel(api, line: ["account", "newline", "model"])
        XCTAssertFalse(api.statuslinePreviewRequests.isEmpty)
        for req in api.statuslinePreviewRequests {
            XCTAssertNil(req.width, "nil is width=auto: the daemon answers at Claude Code's columns")
        }
        model.removeSegment("model")
        model.addSegment("model")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(api.statuslinePreviewRequests.last?.width, "every edit re-asks for auto, never a stale number")
    }

    func testRealWidthSourceCarriesTheColumnsAndFlagsItReal() async {
        let api = StubCockpitAPI()
        let model = await newlineModel(api, line: ["account", "newline", "model"])
        XCTAssertEqual(model.previewRenderedColumns, 120)
        XCTAssertFalse(model.previewWidthIsReal, "no width_source is not real")
        XCTAssertTrue(model.previewWidthLanded, "a render has answered")

        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "a\nb", plain: "a\nb", width: 80, tier: "truecolor", widthSource: "claude-code"))
        model.removeSegment("model")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.previewRenderedColumns, 80, "the resolved width, from the response")
        XCTAssertTrue(model.previewWidthIsReal)

        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "a\nb", plain: "a\nb", width: 120, tier: "truecolor", widthSource: "default"))
        model.addSegment("model")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.previewRenderedColumns, 120)
        XCTAssertFalse(model.previewWidthIsReal, "the daemon never saw a width: default")

        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: "a\nb", plain: "a\nb", width: 0, tier: "truecolor", widthSource: "claude-code"))
        model.removeSegment("model")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.previewRenderedColumns, 120, "a zero width falls back to 120")
    }

    func testNoCaptionUntilTheFirstRenderLandsAndAFailedFirstCallKeepsItHidden() async {
        let api = StubCockpitAPI() // the preview answer defaults to a failure
        api.statuslineSegmentsResult = .success(newlineRegistry())
        api.statuslineConfigResult = .success(try! JSONDecoder().decode(StatuslineConfigResponse.self, from: Data(
            #"{"config":{"version":1,"preset":"","segments":[{"id":"account"}]},"load_error":""}"#.utf8)))
        let model = StatuslineEditorModel(api: api)
        model.previewDebounceDelay = 0.005
        XCTAssertFalse(model.previewWidthLanded, "nothing has answered yet")
        await model.load()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNotNil(model.err, "the first render failed")
        XCTAssertFalse(model.previewWidthLanded, "a failed call shows no default-width claim")
        XCTAssertFalse(model.previewWidthIsReal)
    }

    func testCaptionNeverClaimsItIsYourTerminal() {
        let real = StatuslineEditorCopy.widthCaption(real: true)
        XCTAssertEqual(real.lead + "80" + real.tail, "At the width Claude Code last reported: 80 columns.")
        let fallback = StatuslineEditorCopy.widthCaption(real: false)
        XCTAssertEqual(fallback.lead + "120" + fallback.tail, "Claude Code hasn't reported its width yet — previewing at 120 columns.")
    }

    func testWideGlyphsWidenTheBoxBeyondTheCharacterCount() {
        let size = StatuslineEditorView.previewFontBase
        let cjk = previewRows(String(repeating: "日", count: 10), columns: 200)
        let cells = previewBoxCells(cjk, columns: 200) // 12: counted by Character
        let counted = StatuslineEditorView.previewBoxWidth(cells: cells, fontSize: size)
        XCTAssertGreaterThan(StatuslineEditorView.previewContentWidth(rows: cjk, cells: cells, fontSize: size), counted + 20,
                             "10 CJK characters render far wider than 10 cells")
        let ascii = previewRows(String(repeating: "a", count: 10), columns: 200)
        XCTAssertEqual(StatuslineEditorView.previewContentWidth(rows: ascii, cells: 12, fontSize: size),
                       StatuslineEditorView.previewBoxWidth(cells: 12, fontSize: size), accuracy: 1.5,
                       "plain ASCII stays at the counted width")
    }

    func testWidthSourceDecodesFromTheDaemonsSnakeCaseAndIsOptional() throws {
        let withSource = try DaemonDates.decoder().decode(StatuslinePreviewResponse.self, from: Data(
            #"{"line":"x","plain":"x","width":200,"tier":"truecolor","width_source":"claude-code"}"#.utf8))
        XCTAssertEqual(withSource.widthSource, "claude-code")
        XCTAssertEqual(withSource.width, 200)
        let old = try DaemonDates.decoder().decode(StatuslinePreviewResponse.self, from: Data(
            #"{"line":"x","plain":"x","width":120,"tier":"truecolor"}"#.utf8))
        XCTAssertNil(old.widthSource, "a numeric-width answer carries no width_source")
    }

    func testNewlineChipNeverAsksForASingleSegmentPreview() async {
        let api = StubCockpitAPI()
        let model = await newlineModel(api, line: ["account", "newline", "model"])
        XCTAssertEqual(StatuslineEditorModel.newlineID, "newline")
        let asked = api.statuslineSegmentPreviewRequests.map {
            try! JSONDecoder().decode(StatuslineConfig.self, from: Data($0.utf8)).segments.map(\.id)
        }
        XCTAssertEqual(Set(asked.flatMap { $0 }), ["account", "model"], "a lone newline is a 400 at the daemon: never sent")

        // Tray side: take it off the line and it sits in the tray, still never asked for.
        model.removeSegment("newline")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.availableSegments.map(\.id), ["newline"])
        XCTAssertFalse(api.statuslineSegmentPreviewRequests.contains { $0.contains("newline") })
        XCTAssertNil(model.segmentPreview(id: "newline", options: nil))
    }

    func testNewlineIsNotCountedAsASegmentAndMovesLikeAnyChip() async {
        let api = StubCockpitAPI()
        let model = await newlineModel(api, line: ["account", "newline", "model"])
        XCTAssertEqual(model.draft?.segments.count, 3)
        XCTAssertEqual(model.lineSegmentCount, 2, "the row break is not a segment")
        model.moveSegment("newline", before: 0)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["newline", "account", "model"])
        model.removeSegment("newline")
        model.addSegment("newline", at: 1)
        XCTAssertEqual(model.draft?.segments.map(\.id), ["account", "newline", "model"])
        XCTAssertEqual(model.draft?.segments.last, SLSegmentConfig(id: "model", options: nil), "Apply's payload is plain {id} rows")
        XCTAssertEqual(model.draft?.segments[1], SLSegmentConfig(id: "newline", options: nil))
    }

    func testALineOfOnlyANewLineIsAnEmptyLine() async {
        let api = StubCockpitAPI()
        let model = await newlineModel(api, line: ["account", "newline"])
        let before = api.statuslinePreviewRequests.count
        model.removeSegment("account")
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(model.lineSegmentCount, 0)
        XCTAssertFalse(model.canApply, "the daemon refuses a line of only a row break (400)")
        XCTAssertEqual(api.statuslinePreviewRequests.count, before, "never sent for a preview either")
        XCTAssertEqual(model.preview, "")
    }

    // MARK: - the preview box hugs its rows

    func testBoxCellsHugShortRowsAndEqualTheCutRowAtANarrowWidth() {
        let short = String(repeating: "s", count: 40)
        XCTAssertEqual(previewBoxCells(previewRows(short, columns: 200), columns: 200), 42, "a 40-char row in a 200-column terminal: 40 + 2 indent")
        XCTAssertEqual(previewBoxCells(previewRows(short + "\n" + "ab", columns: 200), columns: 200), 42, "the longest row sets it")
        let long = String(repeating: "L", count: 200)
        // 80 columns, long row: cut to 75 + "…" = 76, + 2 indent = 78 cells — Claude Code's own edge.
        XCTAssertEqual(previewBoxCells(previewRows(long, columns: 80), columns: 80), 78)
        XCTAssertEqual(previewBoxCells(previewRows("x", columns: 1), columns: 1), 1, "never past the terminal's own width")
    }

    func testFontStaysAtBaseUntilTheCellsOverflowThenShrinksToTheFloorAndStops() {
        let base = StatuslineEditorView.previewFontBase
        let w = StatuslineEditorView.previewBoxWidth(cells: 120, fontSize: base)
        XCTAssertEqual(StatuslineEditorView.previewFontSize(cells: 42, available: w), base, "a hugged box keeps 11.5pt")
        XCTAssertEqual(StatuslineEditorView.previewFontSize(cells: 120, available: 0), base, "unmeasured: base")
        let shrunk = StatuslineEditorView.previewFontSize(cells: 140, available: w)
        XCTAssertLessThan(shrunk, base)
        XCTAssertGreaterThanOrEqual(shrunk, StatuslineEditorView.previewFontFloor)
        XCTAssertLessThanOrEqual(StatuslineEditorView.previewBoxWidth(cells: 140, fontSize: shrunk), w + 0.001, "and it then fits")
        XCTAssertEqual(StatuslineEditorView.previewFontSize(cells: 400, available: w), StatuslineEditorView.previewFontFloor,
                       "never under the 9pt floor — past it the box scrolls")
    }
}

// MARK: - the drag through the real gesture path

/// Mounts the REAL editor and drives it with synthesized mouse events, so
/// press → lift → gap → release → settle runs through the view's own
/// gesture, not a hand-set state. With `LLMPILOT_SHOT_DIR` set it also
/// writes the mid-drag and after-drop frames.
@MainActor
final class StatuslineDragHostingTests: XCTestCase {
    private final class FrameBox { var frames: [String: CGRect] = [:] }

    private static let inset: CGFloat = 20
    private static let size = NSSize(width: 600, height: 560)

    private static func segments(withNewline: Bool = false) -> StatuslineSegmentsResponse {
        let rows: [(String, String, Bool)] = [
            ("account", "Account", false), ("usage", "Usage", false), ("burn", "Burn wall", true),
            ("context", "Context", false), ("dir", "Directory", false), ("model", "Model", false),
            ("fleet", "Fleet", true), ("cost", "Cost", false), ("rotation", "Next switch", true),
        ] + (withNewline ? [("newline", "New line", false)] : [])
        let segs = rows.map { #"{"id":"\#($0.0)","name":"\#($0.1)","desc":"","deps":[],"priority":50,"fleet":\#($0.2),"options":[]}"# }
        let json = #"{"segments":[\#(segs.joined(separator: ","))],"presets":[{"id":"runway","name":"Runway","desc":"","config":{"version":1,"preset":"runway","segments":[{"id":"account"},{"id":"usage"}]}}]}"#
        return try! JSONDecoder().decode(StatuslineSegmentsResponse.self, from: Data(json.utf8))
    }

    private func loadedModel(withNewline: Bool = false, previewBytes: String? = nil, line: [String]? = nil) async -> (StatuslineEditorModel, StubCockpitAPI) {
        let api = StubCockpitAPI()
        api.statuslineSegmentsResult = .success(Self.segments(withNewline: withNewline))
        let segs = (line ?? ["account", "usage", "dir", "model", "context", "cost"]).map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
        api.statuslineConfigResult = .success(try! JSONDecoder().decode(StatuslineConfigResponse.self, from: Data(
            #"{"config":{"version":1,"preset":"","segments":[\#(segs)]},"load_error":""}"#.utf8)))
        let esc = "\u{1B}"
        let full = previewBytes ?? "\(esc)[36m[acct 2/4 | rin@ashgrove.io]\(esc)[0m \(esc)[32m5h:44%\(esc)[0m(03:41) wk:37% ~/Dev/llmpilot (main) Opus 5.5"
        api.statuslinePreviewResult = .success(StatuslinePreviewResponse(line: full, plain: full, width: 120, tier: "truecolor"))
        let bytes: [String: String] = [
            "account": "\(esc)[36m[acct 2/4 | rin@ashgrove.io]\(esc)[0m",
            "usage": "\(esc)[32m5h:44%\(esc)[0m(03:41) wk:\(esc)[33m37%\(esc)[0m",
            "burn": "burn ok till 19:05",
            "context": "ctx:34%",
            "dir": "~/Dev/llmpilot (main)",
            "model": "Opus 5.5",
            "fleet": "★a 44% · b 12% · c 3%",
            "cost": "$1.82",
            "rotation": "→work:12%",
        ]
        api.statuslineSegmentPreviewByID = bytes.mapValues {
            StatuslinePreviewResponse(line: $0, plain: $0, width: 0, tier: "truecolor")
        }
        let model = StatuslineEditorModel(api: api)
        model.previewDebounceDelay = 0.005
        await model.load()
        try? await Task.sleep(nanoseconds: 80_000_000)
        return (model, api)
    }

    private func host(_ model: StatuslineEditorModel, box: FrameBox, dark: Bool, size: NSSize? = nil) -> NSWindow {
        let size = size ?? Self.size
        let view = StatuslineEditorView(model: model)
            .onPreferenceChange(ChipFramesKey.self) { box.frames = $0 }
            .frame(width: size.width - Self.inset * 2, alignment: .topLeading)
            .padding(Self.inset)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(CockpitTheme.win)
        let window = AXTestSupport.host(view, size: size)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.makeKey()
        return window
    }

    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Editor-space point → the window's own (bottom-left) coordinates.
    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, _ window: NSWindow) {
        let h = window.contentView?.bounds.height ?? Self.size.height
        let loc = NSPoint(x: p.x + Self.inset, y: h - (p.y + Self.inset))
        guard let e = NSEvent.mouseEvent(
            with: type, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1) else { return XCTFail("no mouse event") }
        NSApp.sendEvent(e)
    }

    private func press(_ p: CGPoint, _ window: NSWindow) async {
        mouse(.leftMouseDown, p, window)
        await settle(0.05)
    }

    private func move(from a: CGPoint, to b: CGPoint, _ window: NSWindow) async {
        for i in 1...12 {
            let t = CGFloat(i) / 12
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), window)
            await settle(0.02)
        }
        await settle(0.3)
    }

    private func release(_ p: CGPoint, _ window: NSWindow) async {
        mouse(.leftMouseUp, p, window)
        await settle(0.4)
    }

    private func shot(_ window: NSWindow, _ name: String) {
        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return XCTFail("no bitmap") }
        content.cacheDisplay(in: content.bounds, to: rep)
        if let dir = ProcessInfo.processInfo.environment["LLMPILOT_SHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func center(_ key: String, _ box: FrameBox) -> CGPoint? {
        guard let f = box.frames[key] else { return nil }
        return CGPoint(x: f.midX, y: f.midY)
    }

    private func ids(_ model: StatuslineEditorModel) -> [String] { model.draft?.segments.map(\.id) ?? [] }

    func testDragReordersAcrossWrappedRowsAndOpensTheGapLive() async throws {
        let (model, _) = await loadedModel()
        let box = FrameBox()
        let window = host(model, box: box, dark: true)
        defer { window.orderOut(nil) }
        await settle()
        shot(window, "drag-0-at-rest")
        let ctx = try XCTUnwrap(box.frames["context"]), usage = try XCTUnwrap(box.frames["usage"])
        let account = try XCTUnwrap(box.frames["account"])
        XCTAssertGreaterThan(ctx.minY, usage.maxY, "fixture must wrap: context sits on a lower row than usage")

        // Pick Context up from the second row, carry it before Usage.
        let start = CGPoint(x: ctx.midX, y: ctx.midY)
        let aim = CGPoint(x: usage.minX + 8, y: usage.midY)
        await press(start, window)
        await move(from: start, to: aim, window)
        let gap = try XCTUnwrap(box.frames[ChipDrop.gapKey], "a gap opens while the chip is in the air")
        XCTAssertEqual(gap.minY, usage.minY, accuracy: 1, "the gap opened on the first row")
        XCTAssertEqual(gap.minX, usage.minX, accuracy: 1, "where Usage was")
        XCTAssertGreaterThan(box.frames["usage"]?.minX ?? 0, usage.minX, "Usage slid aside")
        XCTAssertEqual(ids(model), ["account", "usage", "dir", "model", "context", "cost"], "nothing lands before release")
        shot(window, "drag-1-reorder-mid")

        await release(aim, window)
        XCTAssertEqual(ids(model), ["account", "context", "usage", "dir", "model", "cost"])
        XCTAssertNil(box.frames[ChipDrop.gapKey], "no gap left after the settle")
        XCTAssertEqual(box.frames["context"]?.minX ?? 0, account.maxX + 6, accuracy: 1, "settled into the gap")
        shot(window, "drag-2-reorder-dropped")
    }

    func testTrayChipDraggedUpInsertsAndLineChipDraggedDownRemoves() async throws {
        let (model, _) = await loadedModel()
        let box = FrameBox()
        let window = host(model, box: box, dark: true)
        defer { window.orderOut(nil) }
        await settle()

        // Tray → line: Fleet lands where the gap opens, before Model.
        let fleet = try XCTUnwrap(center("fleet", box))
        let modelChip = try XCTUnwrap(box.frames["model"])
        let aim = CGPoint(x: modelChip.minX + 6, y: modelChip.midY)
        await press(fleet, window)
        await move(from: fleet, to: aim, window)
        XCTAssertNotNil(box.frames[ChipDrop.gapKey])
        shot(window, "drag-3-insert-mid")
        await release(aim, window)
        XCTAssertEqual(ids(model), ["account", "usage", "dir", "fleet", "model", "context", "cost"])
        shot(window, "drag-4-insert-dropped")

        // Line → tray: Directory comes off the line.
        let dir = try XCTUnwrap(center("dir", box))
        let tray = try XCTUnwrap(box.frames[ChipDrop.trayKey])
        let into = CGPoint(x: tray.midX, y: tray.midY)
        await press(dir, window)
        await move(from: dir, to: into, window)
        let trayGap = try XCTUnwrap(box.frames[ChipDrop.gapKey])
        XCTAssertTrue(box.frames[ChipDrop.trayKey]?.intersects(trayGap) == true, "the gap opened in the tray")
        shot(window, "drag-5-remove-mid")
        await release(into, window)
        XCTAssertEqual(ids(model), ["account", "usage", "fleet", "model", "context", "cost"])
        XCTAssertTrue(model.availableSegments.map(\.id).contains("dir"))
    }

    func testEscapeAndADropOutsideSendTheChipHome() async throws {
        let (model, _) = await loadedModel()
        let box = FrameBox()
        let window = host(model, box: box, dark: false)
        defer { window.orderOut(nil) }
        await settle()
        let before = ids(model)

        // Escape mid-drag: home, and the rest of that gesture is ignored.
        let m = try XCTUnwrap(center("model", box))
        let tray = try XCTUnwrap(box.frames[ChipDrop.trayKey])
        await press(m, window)
        await move(from: m, to: CGPoint(x: tray.midX, y: tray.midY), window)
        let aimed = try XCTUnwrap(box.frames[ChipDrop.gapKey], "the tray opened a gap: a release now would remove")
        XCTAssertTrue(box.frames[ChipDrop.trayKey]?.intersects(aimed) == true)
        shot(window, "drag-7-escape-before")
        let esc = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
        NSApp.sendEvent(esc)
        await settle(0.4)
        XCTAssertNil(box.frames[ChipDrop.gapKey], "Escape closed the gap")
        shot(window, "drag-8-escape-after")
        await release(CGPoint(x: tray.midX, y: tray.midY), window)
        XCTAssertEqual(ids(model), before, "Escape put it back")

        // Released over neither strip: home.
        let a = try XCTUnwrap(center("account", box))
        await press(a, window)
        await move(from: a, to: CGPoint(x: a.x, y: 4), window)
        shot(window, "drag-6-outside-mid")
        await release(CGPoint(x: a.x, y: 4), window)
        XCTAssertEqual(ids(model), before, "a drop outside both strips goes home")
        XCTAssertFalse(model.dirty)
    }

    /// Opt-in: REAL HID events (the pointer actually moves) and real
    /// window-server screenshots, served by an outside watcher through
    /// `LLMPILOT_REAL_INPUT_DIR`: each `N.req` holds one command and is
    /// answered by renaming it `N.done` — `shot <name> <x,y,w,h>` runs
    /// `screencapture -x -R`; `move|down|drag|up <x> <y>` and `key <code>`
    /// post one CGEvent at the HID tap (global top-left points). Proves
    /// what synthesized NSEvents can't — the real mouse path, a real
    /// Escape — and shoots frames whose shadow the window server draws
    /// (cacheDisplay draws SwiftUI shadows upside down). The real Escape
    /// needs this app to hold keyboard focus for the whole run; another
    /// app taking focus fails that step without a product fault.
    func testRealInputLiftsShiftsLandsAndEscapes() async throws {
        guard let dir = ProcessInfo.processInfo.environment["LLMPILOT_REAL_INPUT_DIR"] else {
            throw XCTSkip("moves the real pointer — runs only with LLMPILOT_REAL_INPUT_DIR and its watcher")
        }
        let (model, _) = await loadedModel()
        let box = FrameBox()
        let window = host(model, box: box, dark: true)
        defer { window.orderOut(nil) }
        window.level = .floating
        window.setFrameTopLeftPoint(NSPoint(x: 120, y: (NSScreen.screens.first?.frame.height ?? 900) - 80))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await settle(0.6)

        let topH = NSScreen.screens.first?.frame.height ?? 0
        var seq = 0
        func ext(_ cmd: String) async {
            seq += 1
            let req = URL(fileURLWithPath: dir).appendingPathComponent("\(seq).req")
            try? cmd.write(to: req, atomically: true, encoding: .utf8)
            let done = URL(fileURLWithPath: dir).appendingPathComponent("\(seq).done")
            for _ in 0..<750 where !FileManager.default.fileExists(atPath: done.path) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: done.path), "watcher never answered \(cmd)")
        }
        func global(_ p: CGPoint) -> String {
            let h = window.contentView?.bounds.height ?? Self.size.height
            let s = window.convertPoint(toScreen: NSPoint(x: p.x + Self.inset, y: h - (p.y + Self.inset)))
            return "\(Int(s.x)) \(Int(topH - s.y))"
        }
        func realShot(_ name: String) async {
            let r = window.convertToScreen(window.contentView?.frame ?? .zero)
            await ext("shot \(name) \(Int(r.minX)),\(Int(topH - r.maxY)),\(Int(r.width)),\(Int(r.height))")
        }
        func realDrag(_ a: CGPoint, _ b: CGPoint) async {
            let state = "active \(NSApp.isActive), key \(window.isKeyWindow), front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")"
            await ext("move \(global(a))") // scripts/tools/realdrag.swift: hover first, as a hand does
            await settle(0.15)
            await ext("down \(global(a))")
            await settle(0.1)
            XCTAssertNotNil(box.frames[ChipDrop.gapKey], "real press picked nothing up — before it: \(state)")
            for i in 1...14 {
                let t = CGFloat(i) / 14
                await ext("drag \(global(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))")
            }
            await settle(0.35)
        }

        await realShot("real-0-at-rest")
        let ctx = try XCTUnwrap(box.frames["context"]), usage = try XCTUnwrap(box.frames["usage"])
        let aim = CGPoint(x: usage.minX + 8, y: usage.midY)
        await realDrag(CGPoint(x: ctx.midX, y: ctx.midY), aim)
        XCTAssertNotNil(box.frames[ChipDrop.gapKey], "real mouse: the gap opened")
        await realShot("real-1-reorder-mid")
        await ext("up \(global(aim))")
        await settle(0.4)
        XCTAssertEqual(ids(model), ["account", "context", "usage", "dir", "model", "cost"], "real mouse: it landed")
        await realShot("real-2-reorder-dropped")

        let m = try XCTUnwrap(center("model", box))
        let tray = try XCTUnwrap(box.frames[ChipDrop.trayKey])
        let into = CGPoint(x: tray.midX, y: tray.midY)
        await realDrag(m, into)
        XCTAssertTrue(tray.intersects(box.frames[ChipDrop.gapKey] ?? .zero), "real mouse: the tray opened a gap")
        await realShot("real-3-remove-mid")
        XCTAssertTrue(NSApp.isActive && window.isKeyWindow,
                      "a real key goes to the active app's key window (active \(NSApp.isActive), key \(window.isKeyWindow))")
        await ext("key 53")
        await settle(0.4)
        XCTAssertNil(box.frames[ChipDrop.gapKey], "real Escape: home")
        await realShot("real-4-escaped")
        await ext("up \(global(into))")
        await settle(0.4)
        XCTAssertEqual(ids(model), ["account", "context", "usage", "dir", "model", "cost"], "real Escape: nothing changed")

        let m2 = try XCTUnwrap(center("model", box))
        await realDrag(m2, into)
        await ext("up \(global(into))")
        await settle(0.5)
        XCTAssertEqual(ids(model), ["account", "context", "usage", "dir", "cost"], "real mouse: into the tray removes")
        await realShot("real-5-removed")
    }

    /// The preview at the width Claude Code reported: 80 with a long row cut,
    /// 200 with short rows (the box hugs them), and the never-seen default;
    /// plus the New line chip in the tray. Writes PNGs only with
    /// `LLMPILOT_SHOT_DIR` set (xcodebuild forwards it as
    /// `TEST_RUNNER_LLMPILOT_SHOT_DIR`).
    func testAutoWidthPreviewAtEightyTwoHundredAndDefault() async throws {
        let esc = "\u{1B}"
        let row1 = "\(esc)[36m[acct 2/4 | rin@ashgrove.io]\(esc)[0m \(esc)[32m5h:44%\(esc)[0m(03:41) wk:\(esc)[33m37%\(esc)[0m"
        let longRow2 = "\(esc)[34m~/Dev/llmpilot (main)\(esc)[0m Opus 5.5 ctx:34% $1.82 " +
            "\(esc)[2m" + String(repeating: "· session sample field ", count: 4) + "\(esc)[0m tail-end-of-a-long-row"
        let wideRow2 = "\(esc)[34m~/Dev/llmpilot (main)\(esc)[0m Opus 5.5 ctx:34% $1.82 " +
            "\(esc)[2m" + String(repeating: "· session sample field ", count: 3) + "\(esc)[0m end-of-the-row"
        let shortRow2 = "\(esc)[34m~/Dev/llmpilot (main)\(esc)[0m Opus 5.5 ctx:34% $1.82"
        let size = NSSize(
            width: ceil(StatuslineEditorView.previewBoxWidth(cells: 120, fontSize: StatuslineEditorView.previewFontBase)
                + StatuslineEditorView.previewBoxInset * 2 + SheetChromeMetrics.inset * 2),
            height: 700)

        func shoot(_ name: String, columns: Int, source: String, bytes: String, line: [String]) async throws {
            let (m, api) = await loadedModel(withNewline: true, previewBytes: bytes, line: line)
            api.statuslinePreviewResult = .success(StatuslinePreviewResponse(
                line: bytes, plain: bytes, width: columns, tier: "truecolor", widthSource: source))
            m.removeSegment("cost") // a draft edit re-runs the preview at the scripted width
            m.addSegment("cost")
            let box = FrameBox()
            let window = host(m, box: box, dark: true, size: size)
            defer { window.orderOut(nil) }
            await settle(0.5)
            XCTAssertNil(api.statuslinePreviewRequests.last?.width, "the editor asks for auto")
            XCTAssertEqual(m.previewRenderedColumns, columns)
            XCTAssertEqual(m.previewWidthIsReal, source == "claude-code")
            shot(window, name)
        }

        let withBreak = ["account", "usage", "newline", "dir", "model", "context", "cost"]
        try await shoot("auto-80", columns: 80, source: "claude-code", bytes: row1 + "\n" + longRow2, line: withBreak)
        try await shoot("auto-200", columns: 200, source: "claude-code", bytes: row1 + "\n" + shortRow2, line: withBreak)
        try await shoot("auto-200-long", columns: 200, source: "claude-code", bytes: row1 + "\n" + wideRow2, line: withBreak)
        try await shoot("auto-default", columns: 120, source: "default", bytes: row1 + "\n" + shortRow2, line: withBreak)

        // The tray side: a line without the break leaves the New line chip in the tray.
        let (m2, _) = await loadedModel(withNewline: true, previewBytes: row1 + "\n" + shortRow2,
                                        line: ["account", "usage", "dir", "model", "context", "cost"])
        let box2 = FrameBox()
        let window2 = host(m2, box: box2, dark: true, size: size)
        defer { window2.orderOut(nil) }
        await settle(0.5)
        XCTAssertNotNil(box2.frames["newline"], "the New line chip is in the tray")
        shot(window2, "editor-tray")
    }

    /// A terminal wider than the sheet with a long row: the preview section
    /// must stay inside the sheet's width and the font must shrink — a box
    /// that widened its own section would measure itself, never shrink, and
    /// push the whole editor past the sheet's edges.
    func testAWideTerminalWithALongRowShrinksTheFontInsteadOfWideningTheSheet() async throws {
        let sheet = NSSize(
            width: ceil(StatuslineEditorView.previewBoxWidth(cells: 120, fontSize: StatuslineEditorView.previewFontBase)
                + StatuslineEditorView.previewBoxInset * 2 + SheetChromeMetrics.inset * 2),
            height: 700)
        let inner = sheet.width - Self.inset * 2
        // 140 chars: fits once the font shrinks. 400: past the 9pt floor, so it scrolls.
        for (length, shrinksToFit) in [(140, true), (400, false)] {
            let bytes = "acct 5h:44%\n" + String(repeating: "m", count: length)
            let (m, api) = await loadedModel(withNewline: true, previewBytes: bytes, line: ["account", "usage", "newline", "dir"])
            api.statuslinePreviewResult = .success(StatuslinePreviewResponse(
                line: bytes, plain: bytes, width: 500, tier: "truecolor", widthSource: "claude-code"))
            m.removeSegment("dir") // re-runs the preview at the scripted width
            await settle(0.2) // the bytes are in BEFORE the first layout, as when the sheet reopens
            // The real chrome, with no fixed-width frame around the editor:
            // the sheet's own sizing is what a too-wide box pushed against.
            let box = FrameBox()
            let view = SheetChrome(minWidth: sheet.width, minHeight: 480, onClose: {}) {
                StatuslineEditorView(model: m).onPreferenceChange(ChipFramesKey.self) { box.frames = $0 }
            }
            .background(CockpitTheme.win)
            // A sheet's window follows its content's ideal size, so a box
            // that widened the section would grow the sheet.
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled]
            window.setContentSize(sheet)
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            await settle(0.8)
            XCTAssertEqual(m.previewRenderedColumns, 500)
            XCTAssertLessThanOrEqual(window.contentLayoutRect.width, sheet.width + 0.5, "\(length): the sheet did not grow")

            let section = try XCTUnwrap(box.frames[ChipDrop.previewKey], "the preview section reports its frame")
            let preview = try XCTUnwrap(box.frames[ChipDrop.previewBoxKey])
            XCTAssertLessThanOrEqual(section.width, inner + 0.5, "\(length): the section is the width the sheet gives it, not the box's")
            XCTAssertGreaterThanOrEqual(section.minX, -0.5, "\(length): nothing is pushed past the sheet's left edge")
            if shrinksToFit {
                XCTAssertLessThanOrEqual(preview.width, section.width + 0.5, "\(length): the box fits the section")
                XCTAssertLessThan(preview.width,
                                  StatuslineEditorView.previewBoxWidth(cells: length + 2, fontSize: StatuslineEditorView.previewFontBase)
                                    + StatuslineEditorView.previewBoxInset * 2 - 100,
                                  "\(length): the font shrank — at 11.5pt it would be far wider")
            } else {
                XCTAssertGreaterThan(preview.width, section.width, "\(length): at the 9pt floor the box is wider and scrolls inside the section")
            }
        }
    }

    func testAClickStillOpensTheOptions() async throws {
        let (model, _) = await loadedModel()
        let box = FrameBox()
        let window = host(model, box: box, dark: true)
        defer { window.orderOut(nil) }
        await settle()
        let popovers = { NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }.count }
        let before = popovers()
        let u = try XCTUnwrap(center("usage", box))
        await press(u, window)
        await release(u, window)
        XCTAssertEqual(popovers(), before + 1, "a press without movement is a click: the options open")
        XCTAssertEqual(ids(model), ["account", "usage", "dir", "model", "context", "cost"])
        NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") }.forEach { $0.orderOut(nil) }
    }
}

// MARK: - previewRows: the rows as Claude Code cuts them

final class StatuslinePreviewRowsTests: XCTestCase {
    private let esc = "\u{1B}"

    private func text(_ row: [AnsiSpan]) -> String { row.map(\.text).joined() }

    func testNoBytesIsNoRows() {
        XCTAssertEqual(previewRows("", columns: 120), [])
    }

    func testOneRowIsOneRow() {
        let rows = previewRows("acct 5h:44%", columns: 120)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(text(rows[0]), "acct 5h:44%")
    }

    func testNewlineSplitsRows() {
        let rows = previewRows("one\ntwo", columns: 120)
        XCTAssertEqual(rows.map(text), ["one", "two"])
        XCTAssertEqual(previewRows("one\n\nthree", columns: 120).map(text), ["one", "", "three"], "a quiet row stays a row")
    }

    func testARowPastColumnsMinusFourIsCutToColumnsMinusFivePlusAnEllipsis() {
        // Measured in Claude Code 2.1.289 at 80 columns: 76 fits, 77 → 75 + "…".
        let long = String(repeating: "x", count: 77)
        let rows = previewRows("short\n" + long, columns: 80)
        XCTAssertEqual(text(rows[0]), "short", "each row is cut on its own")
        XCTAssertEqual(text(rows[1]), String(repeating: "x", count: 75) + "…")
        XCTAssertEqual(previewVisibleColumns(80), 75)
        XCTAssertEqual(previewVisibleColumns(160), 155)
    }

    func testARowOfExactlyColumnsMinusFourIsNotCut() {
        let exact = String(repeating: "y", count: 76)
        XCTAssertEqual(text(previewRows(exact, columns: 80)[0]), exact)
        XCTAssertEqual(text(previewRows(exact + "y", columns: 80)[0]), String(repeating: "y", count: 75) + "…", "one more is cut")
    }

    func testEscapeCodesAreNotCountedAndColoursSurviveTheCut() {
        // 10 visible red + 10 visible green, behind real escape codes.
        let bytes = "\(esc)[31m" + String(repeating: "r", count: 10) + "\(esc)[0m\(esc)[32m" + String(repeating: "g", count: 10) + "\(esc)[0m"
        XCTAssertEqual(text(previewRows(bytes, columns: 24)[0]), String(repeating: "r", count: 10) + String(repeating: "g", count: 10),
                       "20 visible chars fit 24 − 4 = 20 even though the bytes are longer")
        let cut = previewRows(bytes, columns: 20)[0] // fits 16, cuts to 15
        XCTAssertEqual(text(cut), String(repeating: "r", count: 10) + String(repeating: "g", count: 5) + "…")
        XCTAssertEqual(cut.map(\.color), ["#ff6f61", "#3ddc68", nil], "red and green kept; the ellipsis is default")
        XCTAssertEqual(cut[1].text.count, 5)
    }

    func testACutInsideTheFirstSpanDropsTheRest() {
        let bytes = "\(esc)[31m" + String(repeating: "r", count: 30) + "\(esc)[0m\(esc)[32mgg\(esc)[0m"
        let cut = previewRows(bytes, columns: 15)[0] // cuts to 10
        XCTAssertEqual(cut.map(\.text), [String(repeating: "r", count: 10), "…"])
    }
}
