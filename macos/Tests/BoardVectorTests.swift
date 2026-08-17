import XCTest
@testable import llmpilot

/// Runs the Swift side of testdata/golden-vectors/board-schedule.json,
/// board-clamp.json, board-classify.json, and board-geometry.json — the
/// SAME vector files the web-side runner (web/tests/golden-vectors.spec.ts)
/// reads, so the Phase-3 chunk-A board-core ports (BoardSchedule.swift,
/// BoardClamp.swift, BoardClassify.swift, BoardGeometry.swift) stay
/// provably identical to the web logic they replace. See
/// testdata/golden-vectors/README.md for the file schema/convention and
/// HistoryVectorTests.swift for the `fn`-selector pattern this extends.
final class BoardVectorTests: XCTestCase {
    // MARK: - shared vector loading

    /// testdata/golden-vectors/, resolved relative to this file's own
    /// location — see GoldenVectorTests.vectorsDir for why (derived-data
    /// runs xcodebuild far from the repo checkout).
    private static var vectorsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("testdata/golden-vectors")
    }

    private func loadFile<T: Decodable>(_ name: String, as type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        let dir = Self.vectorsDir
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        XCTAssertTrue(
            exists && isDir.boolValue,
            "golden-vectors dir not found at \(dir.path)",
            file: file, line: line
        )
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        // A truncated/emptied vector file must FAIL, not vacuously pass —
        // every test here is a loop over `cases`.
        let probe = try JSONDecoder().decode(VectorCountProbe.self, from: data)
        XCTAssertFalse(
            probe.cases.isEmpty, "\(name): no cases — refusing a vacuous pass",
            file: file, line: line)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Top-level because Swift forbids nesting types in generic functions.
    private struct VectorCountProbe: Decodable {
        struct AnyCase: Decodable {}
        let cases: [AnyCase]
    }

    // MARK: - board-schedule.json

    private struct ScheduleVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let hour: Int?
            let minute: Int?
            let a: Int?
            let b: Int?
            let minutes: Int?
            let nowMinutes: Int?
            let existingResets: [Int]?
            let activeEndMinutes: Int?
        }

        struct ResetHM: Decodable, Equatable { let hour: Int; let minute: Int }

        enum Want {
            case int(Int)
            case string(String)
            case reset(ResetHM?)
        }

        struct Case: Decodable {
            let name: String
            let fn: String
            let input: Input
            let want: Want

            private enum CodingKeys: String, CodingKey { case name, fn, input, want }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                fn = try c.decode(String.self, forKey: .fn)
                input = try c.decode(Input.self, forKey: .input)
                switch fn {
                case "triggerMinutes", "circularGap", "resetMinutes":
                    want = .int(try c.decode(Int.self, forKey: .want))
                case "fmtHM":
                    want = .string(try c.decode(String.self, forKey: .want))
                case "nextBookableReset":
                    if try c.decodeNil(forKey: .want) {
                        want = .reset(nil)
                    } else {
                        want = .reset(try c.decode(ResetHM.self, forKey: .want))
                    }
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    func testBoardScheduleMatchesGoldenVectors() throws {
        let vectors = try loadFile("board-schedule.json", as: ScheduleVectorFile.self)
        XCTAssertEqual(vectors.module, "board-schedule")
        for c in vectors.cases {
            let msg = "case '\(c.name)'"
            switch (c.fn, c.want) {
            case ("triggerMinutes", let .int(want)):
                let hour = try XCTUnwrap(c.input.hour, msg)
                let minute = try XCTUnwrap(c.input.minute, msg)
                XCTAssertEqual(BoardSchedule.triggerMinutes(hour: hour, minute: minute), want, msg)
            case ("circularGap", let .int(want)):
                let a = try XCTUnwrap(c.input.a, msg)
                let b = try XCTUnwrap(c.input.b, msg)
                XCTAssertEqual(BoardSchedule.circularGap(a, b), want, msg)
            case ("resetMinutes", let .int(want)):
                let hour = try XCTUnwrap(c.input.hour, msg)
                let minute = try XCTUnwrap(c.input.minute, msg)
                XCTAssertEqual(BoardSchedule.resetMinutes(hour: hour, minute: minute), want, msg)
            case ("fmtHM", let .string(want)):
                let minutes = try XCTUnwrap(c.input.minutes, msg)
                XCTAssertEqual(BoardSchedule.fmtHM(minutes), want, msg)
            case ("nextBookableReset", let .reset(want)):
                let nowMinutes = try XCTUnwrap(c.input.nowMinutes, msg)
                let existingResets = try XCTUnwrap(c.input.existingResets, msg)
                let got = BoardSchedule.nextBookableReset(
                    nowMinutes: nowMinutes, existingResets: existingResets, activeEndMinutes: c.input.activeEndMinutes)
                if let want {
                    let g = try XCTUnwrap(got, msg)
                    XCTAssertEqual(g.hour, want.hour, "\(msg) hour")
                    XCTAssertEqual(g.minute, want.minute, "\(msg) minute")
                } else {
                    XCTAssertNil(got, msg)
                }
            default:
                XCTFail("\(msg): fn '\(c.fn)' does not match its decoded want shape")
            }
        }
    }

    // MARK: - board-clamp.json

    private struct ClampVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let prev: [Int]?
            let next: [Int]?
            let floor: Int
            let t: Int?
            let existing: [Int]?
        }

        struct ClampWant: Decodable, Equatable {
            let values: [Int]
            let index: Int
            let hitWall: Bool
            let flashZone: [Int]?
        }

        enum Want {
            case clamp(ClampWant?)
            case zone([Int]?)
        }

        struct Case: Decodable {
            let name: String
            let fn: String
            let input: Input
            let want: Want

            private enum CodingKeys: String, CodingKey { case name, fn, input, want }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                fn = try c.decode(String.self, forKey: .fn)
                input = try c.decode(Input.self, forKey: .input)
                switch fn {
                case "clampMove":
                    if try c.decodeNil(forKey: .want) {
                        want = .clamp(nil)
                    } else {
                        want = .clamp(try c.decode(ClampWant.self, forKey: .want))
                    }
                case "canBookAt":
                    if try c.decodeNil(forKey: .want) {
                        want = .zone(nil)
                    } else {
                        want = .zone(try c.decode([Int].self, forKey: .want))
                    }
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    func testBoardClampMatchesGoldenVectors() throws {
        let vectors = try loadFile("board-clamp.json", as: ClampVectorFile.self)
        XCTAssertEqual(vectors.module, "board-clamp")
        for c in vectors.cases {
            let msg = "case '\(c.name)'"
            switch (c.fn, c.want) {
            case ("clampMove", let .clamp(want)):
                let prev = try XCTUnwrap(c.input.prev, msg)
                let next = try XCTUnwrap(c.input.next, msg)
                let got = BoardClamp.clampMove(prev: prev, next: next, floor: c.input.floor)
                if let want {
                    let g = try XCTUnwrap(got, msg)
                    XCTAssertEqual(g.values, want.values, "\(msg) values")
                    XCTAssertEqual(g.index, want.index, "\(msg) index")
                    XCTAssertEqual(g.hitWall, want.hitWall, "\(msg) hitWall")
                    if let wantZone = want.flashZone {
                        let gotZone = try XCTUnwrap(g.flashZone, "\(msg) flashZone")
                        XCTAssertEqual([gotZone.0, gotZone.1], wantZone, "\(msg) flashZone")
                    } else {
                        XCTAssertNil(g.flashZone, "\(msg) flashZone")
                    }
                } else {
                    XCTAssertNil(got, msg)
                }
            case ("canBookAt", let .zone(want)):
                let t = try XCTUnwrap(c.input.t, msg)
                let existing = try XCTUnwrap(c.input.existing, msg)
                let got = BoardClamp.canBookAt(t, existing: existing, floor: c.input.floor)
                if let want {
                    let g = try XCTUnwrap(got, msg)
                    XCTAssertEqual([g.0, g.1], want, msg)
                } else {
                    XCTAssertNil(got, msg)
                }
            default:
                XCTFail("\(msg): fn '\(c.fn)' does not match its decoded want shape")
            }
        }
    }

    // MARK: - board-classify.json

    private struct ClassifyVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct ScheduleDTO: Decodable {
            let id: String
            let account_id: String
            let hour: Int
            let minute: Int
        }

        struct LaneScheduleDTO: Decodable {
            let trigger: Int
            let reset: Int
            let chained: Bool
        }

        struct MidWindowDTO: Decodable { let start: Int; let end: Int }

        struct Input: Decodable {
            let accountId: String?
            let schedules: [ScheduleDTO]?
            let ls: LaneScheduleDTO?
            let nowMinutes: Int?
            let mid: MidWindowDTO?
            let cls: String?
            let chained: Bool?
        }

        struct LaneWant: Decodable { let id: String; let trigger: Int; let reset: Int; let chained: Bool }
        struct ChipCopyWant: Decodable {
            let suffix: String?
            let suffixTone: String
            let trigLine: String
            let trigTone: String
        }

        enum Want {
            case lanes([LaneWant])
            case string(String)
            case chipCopy(ChipCopyWant)
        }

        struct Case: Decodable {
            let name: String
            let fn: String
            let input: Input
            let want: Want

            private enum CodingKeys: String, CodingKey { case name, fn, input, want }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                fn = try c.decode(String.self, forKey: .fn)
                input = try c.decode(Input.self, forKey: .input)
                switch fn {
                case "laneSchedules":
                    want = .lanes(try c.decode([LaneWant].self, forKey: .want))
                case "classify", "chipDot":
                    want = .string(try c.decode(String.self, forKey: .want))
                case "chipCopy":
                    want = .chipCopy(try c.decode(ChipCopyWant.self, forKey: .want))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    private func classFrom(_ s: String, _ msg: String) throws -> BoardClassify.ChipClass {
        try XCTUnwrap(BoardClassify.ChipClass(rawValue: s), msg)
    }

    func testBoardClassifyMatchesGoldenVectors() throws {
        let vectors = try loadFile("board-classify.json", as: ClassifyVectorFile.self)
        XCTAssertEqual(vectors.module, "board-classify")
        for c in vectors.cases {
            let msg = "case '\(c.name)'"
            switch (c.fn, c.want) {
            case ("laneSchedules", let .lanes(want)):
                let accountId = try XCTUnwrap(c.input.accountId, msg)
                let dtos = try XCTUnwrap(c.input.schedules, msg)
                let schedules = dtos.map {
                    BoardClassify.ScheduleInput(id: $0.id, accountID: $0.account_id, hour: $0.hour, minute: $0.minute)
                }
                let got = BoardClassify.laneSchedules(schedules: schedules, accountID: accountId)
                XCTAssertEqual(got.count, want.count, "\(msg) count")
                for (g, w) in zip(got, want) {
                    XCTAssertEqual(g.schedule.id, w.id, "\(msg) id")
                    XCTAssertEqual(g.trigger, w.trigger, "\(msg) trigger for \(w.id)")
                    XCTAssertEqual(g.reset, w.reset, "\(msg) reset for \(w.id)")
                    XCTAssertEqual(g.chained, w.chained, "\(msg) chained for \(w.id)")
                }
            case ("classify", let .string(want)):
                let lsDTO = try XCTUnwrap(c.input.ls, msg)
                let nowMinutes = try XCTUnwrap(c.input.nowMinutes, msg)
                let ls = BoardClassify.LaneSchedule(
                    schedule: BoardClassify.ScheduleInput(id: "x", accountID: "acc", hour: 0, minute: 0),
                    trigger: lsDTO.trigger, reset: lsDTO.reset, chained: lsDTO.chained)
                let mid = c.input.mid.map { BoardClassify.MidWindow(start: $0.start, end: $0.end) }
                let got = BoardClassify.classify(ls, nowMinutes: nowMinutes, mid: mid)
                XCTAssertEqual(got.rawValue, want, msg)
            case ("chipDot", let .string(want)):
                let clsStr = try XCTUnwrap(c.input.cls, msg)
                let chained = try XCTUnwrap(c.input.chained, msg)
                let cls = try classFrom(clsStr, msg)
                XCTAssertEqual(BoardClassify.chipDot(cls, chained: chained).rawValue, want, msg)
            case ("chipCopy", let .chipCopy(want)):
                let lsDTO = try XCTUnwrap(c.input.ls, msg)
                let clsStr = try XCTUnwrap(c.input.cls, msg)
                let cls = try classFrom(clsStr, msg)
                let ls = BoardClassify.LaneSchedule(
                    schedule: BoardClassify.ScheduleInput(id: "x", accountID: "acc", hour: 0, minute: 0),
                    trigger: lsDTO.trigger, reset: lsDTO.reset, chained: lsDTO.chained)
                let mid = c.input.mid.map { BoardClassify.MidWindow(start: $0.start, end: $0.end) }
                let got = BoardClassify.chipCopy(ls, cls, mid)
                XCTAssertEqual(got.suffix, want.suffix, "\(msg) suffix")
                XCTAssertEqual(got.suffixTone, want.suffixTone, "\(msg) suffixTone")
                XCTAssertEqual(got.trigLine, want.trigLine, "\(msg) trigLine")
                XCTAssertEqual(got.trigTone, want.trigTone, "\(msg) trigTone")
            default:
                XCTFail("\(msg): fn '\(c.fn)' does not match its decoded want shape")
            }
        }
    }

    // MARK: - board-geometry.json

    private struct GeometryVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable { let minutes: Double }

        struct Case: Decodable {
            let name: String
            let fn: String
            let input: Input
            let want: Double
        }
    }

    func testBoardGeometryMatchesGoldenVectors() throws {
        let vectors = try loadFile("board-geometry.json", as: GeometryVectorFile.self)
        XCTAssertEqual(vectors.module, "board-geometry")
        for c in vectors.cases {
            let msg = "case '\(c.name)'"
            switch c.fn {
            case "toPx":
                // The golden vectors pin the DEFAULT 1160pt track width
                // (web's own fixed TRACK_PX) — `toPx`'s `trackPx:` param
                // defaults to `BoardGeometry.trackPx` (1160) so every
                // pre-F16 call site, and this vector file, keep passing
                // unchanged.
                XCTAssertEqual(BoardGeometry.toPx(c.input.minutes), c.want, accuracy: 1e-9, msg)
            case "toPct":
                XCTAssertEqual(BoardGeometry.toPct(c.input.minutes), c.want, accuracy: 1e-9, msg)
            default:
                XCTFail("unknown fn '\(c.fn)'")
            }
        }
    }

    // MARK: - F16: fluid track width (live per-render, not the fixed 1160pt constant)

    /// The golden vectors above pin `toPx`/`toPct` at the DEFAULT 1160pt
    /// track width only. F16 (fresh-user audit 2026-08-16, finding F16)
    /// made the board's track width a LIVE value derived from the
    /// container's available width every render — this proves the same
    /// pure conversion math at a SECOND width, 760pt (roughly what a fluid
    /// track is left with at the cockpit's 1000pt minimum window width
    /// once a header column of about 240pt is subtracted — 704pt with
    /// F17's 296pt column, 760 here as a round second width). Expected values are hand-computed the same way the vectors'
    /// own README documents the 1160pt cases (round(minutes * trackPx/1440
    /// * 10) / 10) — NOT derived by calling the code under test, so this
    /// can't vacuously pass a broken formula.
    func testBoardGeometryFluidWidthAtSecondWidth() {
        let trackPx = 760.0
        XCTAssertEqual(BoardGeometry.toPx(0, trackPx: trackPx), 0, accuracy: 1e-9, "0 minutes -> 0px")
        XCTAssertEqual(BoardGeometry.toPx(1, trackPx: trackPx), 0.5, accuracy: 1e-9, "1 minute")
        // 37 * 760/1440 * 10 = 195.2777... rounds to 195, /10 = 19.5 — same
        // rounding case the 1160pt vector's own "37 minutes" case exercises.
        XCTAssertEqual(BoardGeometry.toPx(37, trackPx: trackPx), 19.5, accuracy: 1e-9, "37 minutes rounds to 1 decimal")
        XCTAssertEqual(BoardGeometry.toPx(1439, trackPx: trackPx), 759.5, accuracy: 1e-9, "last minute of the day")
        // toPct is width-independent by definition (percent of the day,
        // not of the track) — same expected value as the 1160pt vector.
        XCTAssertEqual(BoardGeometry.toPct(360), 25, accuracy: 1e-9, "quarter of the day")
    }

    /// F16 fail case: a track width narrower than the header column itself
    /// — e.g. a container measured mid-layout-pass, or a pathological
    /// resize below the cockpit's stated 1000x700 minimum — must never
    /// derive negative, zero, or NaN geometry. `trackWidth(forAvailable:)`
    /// floors to `minTrackPx`; `ppm(forTrackPx:)`/`toPx` fall back to 0
    /// (not NaN/negative) for any non-finite or non-positive width that
    /// reaches them directly.
    func testBoardGeometryTrackNarrowerThanHeaderStaysSane() {
        let trackPx = BoardGeometry.trackWidth(forAvailable: 50, headerPx: BoardGeometry.headerPx)
        XCTAssertTrue(trackPx.isFinite, "trackWidth(forAvailable: 50) must be finite")
        XCTAssertGreaterThanOrEqual(trackPx, BoardGeometry.minTrackPx, "trackWidth must floor to minTrackPx")

        for minutes in stride(from: 0.0, through: 1439.0, by: 60.0) {
            let px = BoardGeometry.toPx(minutes, trackPx: trackPx)
            XCTAssertTrue(px.isFinite, "toPx(\(minutes)) at trackPx=\(trackPx) must be finite")
            XCTAssertGreaterThanOrEqual(px, 0, "toPx(\(minutes)) at trackPx=\(trackPx) must be non-negative")
        }

        // Direct guard on the helpers themselves, bypassing the
        // trackWidth(forAvailable:) floor, for a zero/negative width that
        // should never reach toPx in practice but must still resolve sanely
        // if it ever does.
        XCTAssertEqual(BoardGeometry.ppm(forTrackPx: 0), 0, "ppm at trackPx=0 must not be NaN/negative")
        XCTAssertEqual(BoardGeometry.ppm(forTrackPx: -100), 0, "ppm at a negative trackPx must not be NaN/negative")
        XCTAssertFalse(BoardGeometry.toPx(720, trackPx: 0).isNaN, "toPx at trackPx=0 must not be NaN")
        XCTAssertEqual(BoardGeometry.toPx(720, trackPx: 0), 0, "toPx at trackPx=0 must be 0, not negative")
    }
}
