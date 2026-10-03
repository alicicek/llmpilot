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
        XCTAssertEqual(last.width, 120)
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
}
