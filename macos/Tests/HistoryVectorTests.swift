import XCTest
@testable import llmpilot

/// Runs the Swift side of testdata/golden-vectors/history-*.json and
/// board-time.json — the SAME vector files the web-side runner
/// (web/tests/golden-vectors.spec.ts) reads, so the Phase-1 chunk-A history
/// ports stay provably identical to the web logic they replace. See
/// testdata/golden-vectors/README.md for the file schema/convention and
/// GoldenVectorTests.swift for the original (single-function) pattern this
/// extends — these files each carry a `fn` selector per case since their
/// modules have more than one ported function.
final class HistoryVectorTests: XCTestCase {
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

    private func assertClose(
        _ got: Double, _ want: Double, _ msg: String, accuracy: Double = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got, want, accuracy: accuracy, msg, file: file, line: line)
    }

    // MARK: - history-pricing.json

    private struct PricingVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let modelID: String
            let tokens: AnalyticsTokens?
        }

        enum Want {
            case none
            case price(Double, Double)
            case value(Double)
        }

        struct Case: Decodable {
            let name: String
            let fn: String
            let input: Input
            let want: Want

            private enum CodingKeys: String, CodingKey { case name, fn, input, want }
            private struct PriceObj: Decodable { let input: Double; let output: Double }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                fn = try c.decode(String.self, forKey: .fn)
                input = try c.decode(Input.self, forKey: .input)
                switch fn {
                case "priceFor":
                    if try c.decodeNil(forKey: .want) {
                        want = .none
                    } else {
                        let p = try c.decode(PriceObj.self, forKey: .want)
                        want = .price(p.input, p.output)
                    }
                case "valueOf":
                    if try c.decodeNil(forKey: .want) {
                        want = .none
                    } else {
                        want = .value(try c.decode(Double.self, forKey: .want))
                    }
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    func testHistoryPricingMatchesGoldenVectors() throws {
        let vectors = try loadFile("history-pricing.json", as: PricingVectorFile.self)
        XCTAssertEqual(vectors.module, "history-pricing")
        for c in vectors.cases {
            switch c.fn {
            case "priceFor":
                let got = HistoryPricing.priceFor(c.input.modelID)
                switch c.want {
                case .none: XCTAssertNil(got, "case '\(c.name)'")
                case let .price(i, o):
                    XCTAssertEqual(got?.input, i, "case '\(c.name)' input price")
                    XCTAssertEqual(got?.output, o, "case '\(c.name)' output price")
                case .value: XCTFail("case '\(c.name)': priceFor case had a numeric want")
                }
            case "valueOf":
                let tokens = try XCTUnwrap(c.input.tokens, "case '\(c.name)': valueOf needs tokens")
                let got = HistoryPricing.valueOf(c.input.modelID, tokens)
                switch c.want {
                case .none: XCTAssertNil(got, "case '\(c.name)'")
                case let .value(v): assertClose(try XCTUnwrap(got, "case '\(c.name)'"), v, "case '\(c.name)'")
                case .price: XCTFail("case '\(c.name)': valueOf case had a price-object want")
                }
            default:
                XCTFail("unknown fn '\(c.fn)'")
            }
        }
    }

    // MARK: - history-aggregate.json

    private struct AggregateVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let tokens: AnalyticsTokens?
            let cells: [AnalyticsCell]?
        }

        struct FamilyWant: Decodable { let family: String; let tokens: Int64; let value: Double; let unpricedIds: [String] }
        struct ProjectWant: Decodable { let project: String; let tokens: Int64; let value: Double }
        struct SummaryWant: Decodable { let total: Double; let unpricedIds: [String] }

        enum Want {
            case number(Int64)
            case summary(SummaryWant)
            case families([FamilyWant])
            case projects([ProjectWant])
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
                case "totalTokens", "ioTokens":
                    want = .number(try c.decode(Int64.self, forKey: .want))
                case "valueSummary":
                    want = .summary(try c.decode(SummaryWant.self, forKey: .want))
                case "groupByFamily":
                    want = .families(try c.decode([FamilyWant].self, forKey: .want))
                case "groupByProject":
                    want = .projects(try c.decode([ProjectWant].self, forKey: .want))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    func testHistoryAggregateMatchesGoldenVectors() throws {
        let vectors = try loadFile("history-aggregate.json", as: AggregateVectorFile.self)
        XCTAssertEqual(vectors.module, "history-aggregate")
        for c in vectors.cases {
            switch (c.fn, c.want) {
            case ("totalTokens", let .number(want)):
                let tokens = try XCTUnwrap(c.input.tokens, "case '\(c.name)'")
                XCTAssertEqual(HistoryAggregate.totalTokens(tokens), want, "case '\(c.name)'")
            case ("ioTokens", let .number(want)):
                let tokens = try XCTUnwrap(c.input.tokens, "case '\(c.name)'")
                XCTAssertEqual(HistoryAggregate.ioTokens(tokens), want, "case '\(c.name)'")
            case ("valueSummary", let .summary(want)):
                let cells = try XCTUnwrap(c.input.cells, "case '\(c.name)'")
                let got = HistoryAggregate.valueSummary(cells)
                assertClose(got.total, want.total, "case '\(c.name)' total")
                XCTAssertEqual(got.unpricedIds, Set(want.unpricedIds), "case '\(c.name)' unpricedIds")
            case ("groupByFamily", let .families(want)):
                let cells = try XCTUnwrap(c.input.cells, "case '\(c.name)'")
                let got = HistoryAggregate.groupByFamily(cells)
                XCTAssertEqual(got.count, want.count, "case '\(c.name)' group count")
                for (g, w) in zip(got, want) {
                    XCTAssertEqual(g.family, w.family, "case '\(c.name)' family")
                    XCTAssertEqual(g.tokens, w.tokens, "case '\(c.name)' tokens for \(w.family)")
                    assertClose(g.value, w.value, "case '\(c.name)' value for \(w.family)")
                    XCTAssertEqual(g.unpricedIds, Set(w.unpricedIds), "case '\(c.name)' unpricedIds for \(w.family)")
                }
            case ("groupByProject", let .projects(want)):
                let cells = try XCTUnwrap(c.input.cells, "case '\(c.name)'")
                let got = HistoryAggregate.groupByProject(cells)
                XCTAssertEqual(got.count, want.count, "case '\(c.name)' group count")
                for (g, w) in zip(got, want) {
                    XCTAssertEqual(g.project, w.project, "case '\(c.name)' project")
                    XCTAssertEqual(g.tokens, w.tokens, "case '\(c.name)' tokens for \(w.project)")
                    assertClose(g.value, w.value, "case '\(c.name)' value for \(w.project)")
                }
            default:
                XCTFail("case '\(c.name)': fn '\(c.fn)' does not match its decoded want shape")
            }
        }
    }

    // MARK: - history-format.json

    private struct FormatVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let n: Double?
            let approx: Bool?
            let iso: String?
            let epochMs: Double?
            let offsetMinutes: Int?
            let dateStr: String?
            let days: Int?
            let range: String?
        }

        enum Want {
            case string(String)
            case int(Int)
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
                case "isoOffsetMinutes", "rangeDays":
                    want = .int(try c.decode(Int.self, forKey: .want))
                default:
                    want = .string(try c.decode(String.self, forKey: .want))
                }
            }
        }
    }

    func testHistoryFormatMatchesGoldenVectors() throws {
        let vectors = try loadFile("history-format.json", as: FormatVectorFile.self)
        XCTAssertEqual(vectors.module, "history-format")
        for c in vectors.cases {
            switch c.fn {
            case "formatTokens":
                let n = try XCTUnwrap(c.input.n, "case '\(c.name)'")
                XCTAssertEqual(HistoryFormat.formatTokens(n), stringWant(c), "case '\(c.name)'")
            case "formatUSD":
                let n = try XCTUnwrap(c.input.n, "case '\(c.name)'")
                let approx = c.input.approx ?? true
                XCTAssertEqual(HistoryFormat.formatUSD(n, approx: approx), stringWant(c), "case '\(c.name)'")
            case "formatPercent":
                let n = try XCTUnwrap(c.input.n, "case '\(c.name)'")
                XCTAssertEqual(HistoryFormat.formatPercent(n), stringWant(c), "case '\(c.name)'")
            case "hhmm":
                let iso = try XCTUnwrap(c.input.iso, "case '\(c.name)'")
                XCTAssertEqual(HistoryFormat.hhmm(iso), stringWant(c), "case '\(c.name)'")
            case "isoOffsetMinutes":
                let iso = try XCTUnwrap(c.input.iso, "case '\(c.name)'")
                guard case let .int(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(HistoryFormat.isoOffsetMinutes(iso), want, "case '\(c.name)'")
            case "hhmmAtEpoch":
                let epochMs = try XCTUnwrap(c.input.epochMs, "case '\(c.name)'")
                let offset = try XCTUnwrap(c.input.offsetMinutes, "case '\(c.name)'")
                XCTAssertEqual(HistoryFormat.hhmmAtEpoch(epochMs, offset), stringWant(c), "case '\(c.name)'")
            case "dateOnly":
                let iso = try XCTUnwrap(c.input.iso, "case '\(c.name)'")
                XCTAssertEqual(HistoryFormat.dateOnly(iso), stringWant(c), "case '\(c.name)'")
            case "addDays":
                let dateStr = try XCTUnwrap(c.input.dateStr, "case '\(c.name)'")
                let days = try XCTUnwrap(c.input.days, "case '\(c.name)'")
                XCTAssertEqual(HistoryFormat.addDays(dateStr, days), stringWant(c), "case '\(c.name)'")
            case "rangeDays":
                let range = try XCTUnwrap(c.input.range, "case '\(c.name)'")
                guard case let .int(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(HistoryFormat.rangeDays[range], want, "case '\(c.name)'")
            default:
                XCTFail("unknown fn '\(c.fn)'")
            }
        }
    }

    private func stringWant(_ c: FormatVectorFile.Case, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case let .string(s) = c.want else {
            XCTFail("case '\(c.name)': expected a string want", file: file, line: line)
            return ""
        }
        return s
    }

    // MARK: - history-burn.json

    private struct BurnVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let hourWeekday: [[Int64]]?
            let todayDateStr: String?
            let cellsToday: [AnalyticsCell]?
            let activityHours: Int?
        }

        enum Want {
            case int(Int)
            case double(Double)
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
                case "hoursWithActivityToday":
                    want = .int(try c.decode(Int.self, forKey: .want))
                case "hourlyRate":
                    want = .double(try c.decode(Double.self, forKey: .want))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    func testHistoryBurnMatchesGoldenVectors() throws {
        let vectors = try loadFile("history-burn.json", as: BurnVectorFile.self)
        XCTAssertEqual(vectors.module, "history-burn")
        for c in vectors.cases {
            switch (c.fn, c.want) {
            case ("hoursWithActivityToday", let .int(want)):
                let rows = try XCTUnwrap(c.input.hourWeekday, "case '\(c.name)'")
                let today = try XCTUnwrap(c.input.todayDateStr, "case '\(c.name)'")
                XCTAssertEqual(BurnMath.hoursWithActivityToday(rows, today), want, "case '\(c.name)'")
            case ("hourlyRate", let .double(want)):
                let cells = try XCTUnwrap(c.input.cellsToday, "case '\(c.name)'")
                let hours = try XCTUnwrap(c.input.activityHours, "case '\(c.name)'")
                assertClose(BurnMath.hourlyRate(cells, hours), want, "case '\(c.name)'")
            default:
                XCTFail("case '\(c.name)': fn '\(c.fn)' does not match its decoded want shape")
            }
        }
    }

    // MARK: - history-colors.json

    private struct ColorsVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let modelID: String?
            let family: String?
            let dark: Bool?
            let t: Double?
        }

        struct Case: Decodable {
            let name: String
            let fn: String
            let input: Input
            let want: String
        }
    }

    func testHistoryColorsMatchesGoldenVectors() throws {
        let vectors = try loadFile("history-colors.json", as: ColorsVectorFile.self)
        XCTAssertEqual(vectors.module, "history-colors")
        for c in vectors.cases {
            switch c.fn {
            case "familyOf":
                let modelID = try XCTUnwrap(c.input.modelID, "case '\(c.name)'")
                XCTAssertEqual(HistoryColors.familyOf(modelID), c.want, "case '\(c.name)'")
            case "colorForFamily":
                let family = try XCTUnwrap(c.input.family, "case '\(c.name)'")
                let dark = try XCTUnwrap(c.input.dark, "case '\(c.name)'")
                // The vector's "want" is spelled in the web's own vocabulary
                // (README convention) — for the "Other" slot the web
                // literally returns the un-resolved CSS var
                // "var(--graydot)" (see colors.ts), which has no Swift
                // equivalent string. This pure port instead resolves that
                // slot outright (see HistoryColors.colorForFamily's own doc
                // comment) — translate the sentinel to the resolved hex a
                // Swift caller actually expects before comparing.
                let want = c.want == "var(--graydot)" ? (dark ? "#6f6f76" : "#a5a5ac") : c.want
                XCTAssertEqual(HistoryColors.colorForFamily(family, dark: dark), want, "case '\(c.name)'")
            case "textOnFamilyFill":
                let family = try XCTUnwrap(c.input.family, "case '\(c.name)'")
                let dark = try XCTUnwrap(c.input.dark, "case '\(c.name)'")
                XCTAssertEqual(HistoryColors.textOnFamilyFill(family, dark: dark), c.want, "case '\(c.name)'")
            case "sequentialColor":
                let t = try XCTUnwrap(c.input.t, "case '\(c.name)'")
                let dark = try XCTUnwrap(c.input.dark, "case '\(c.name)'")
                XCTAssertEqual(HistoryColors.sequentialColor(t, dark: dark), c.want, "case '\(c.name)'")
            default:
                XCTFail("unknown fn '\(c.fn)'")
            }
        }
    }

    // MARK: - history-mix.json

    private struct MixVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct FamilyGroupDTO: Decodable {
            let family: String
            let tokens: Int64
            let value: Double
            let unpricedIds: [String]
        }

        struct SampleDTO: Decodable {
            let at: String
            let percent: Double
        }

        struct Input: Decodable {
            let groups: [FamilyGroupDTO]?
            let cells: [AnalyticsCell]?
            let samples: [SampleDTO]?
            let totalTokens: Double?
        }

        struct SegmentWant: Decodable { let family: String; let tokens: Int64; let value: Double; let unpricedIds: [String] }
        struct ProjectWant: Decodable { let project: String; let tokens: Int64; let value: Double }
        struct TopProjectsWant: Decodable { let rows: [ProjectWant]; let otherCount: Int; let otherTokens: Int64 }

        enum Want {
            case segments([SegmentWant])
            case topProjects(TopProjectsWant)
            case wallMs(Double?)
            case hobbit(String?)
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
                case "buildSegments":
                    want = .segments(try c.decode([SegmentWant].self, forKey: .want))
                case "topProjects":
                    want = .topProjects(try c.decode(TopProjectsWant.self, forKey: .want))
                case "projectWallMs":
                    want = .wallMs(try c.decodeIfPresent(Double.self, forKey: .want))
                case "hobbitFactorString":
                    want = .hobbit(try c.decodeIfPresent(String.self, forKey: .want))
                default:
                    throw DecodingError.dataCorruptedError(forKey: .fn, in: c, debugDescription: "unknown fn '\(fn)'")
                }
            }
        }
    }

    func testHistoryMixMatchesGoldenVectors() throws {
        let vectors = try loadFile("history-mix.json", as: MixVectorFile.self)
        XCTAssertEqual(vectors.module, "history-mix")
        for c in vectors.cases {
            switch (c.fn, c.want) {
            case ("buildSegments", let .segments(want)):
                let groups = try XCTUnwrap(c.input.groups, "case '\(c.name)'").map {
                    HistoryAggregate.FamilyGroup(family: $0.family, tokens: $0.tokens, value: $0.value, unpricedIds: Set($0.unpricedIds))
                }
                let got = HistoryAggregate.buildSegments(groups)
                XCTAssertEqual(got.count, want.count, "case '\(c.name)' segment count")
                for (g, w) in zip(got, want) {
                    XCTAssertEqual(g.family, w.family, "case '\(c.name)' family")
                    XCTAssertEqual(g.tokens, w.tokens, "case '\(c.name)' tokens for \(w.family)")
                    assertClose(g.value, w.value, "case '\(c.name)' value for \(w.family)")
                    XCTAssertEqual(g.unpricedIds, Set(w.unpricedIds), "case '\(c.name)' unpricedIds for \(w.family)")
                }
            case ("topProjects", let .topProjects(want)):
                let cells = try XCTUnwrap(c.input.cells, "case '\(c.name)'")
                let got = HistoryAggregate.topProjects(cells)
                XCTAssertEqual(got.rows.count, want.rows.count, "case '\(c.name)' row count")
                for (g, w) in zip(got.rows, want.rows) {
                    XCTAssertEqual(g.project, w.project, "case '\(c.name)' project")
                    XCTAssertEqual(g.tokens, w.tokens, "case '\(c.name)' tokens for \(w.project)")
                    assertClose(g.value, w.value, "case '\(c.name)' value for \(w.project)")
                }
                XCTAssertEqual(got.otherCount, want.otherCount, "case '\(c.name)' otherCount")
                XCTAssertEqual(got.otherTokens, want.otherTokens, "case '\(c.name)' otherTokens")
            case ("projectWallMs", let .wallMs(want)):
                let dtos = try XCTUnwrap(c.input.samples, "case '\(c.name)'")
                let samples = try dtos.map { dto -> HistorySample in
                    HistorySample(at: try XCTUnwrap(DaemonDates.parseRFC3339(dto.at), "case '\(c.name)'"), percent: dto.percent)
                }
                let got = BurnMath.projectWallMs(samples)
                if let want {
                    assertClose(try XCTUnwrap(got, "case '\(c.name)'"), want, "case '\(c.name)'")
                } else {
                    XCTAssertNil(got, "case '\(c.name)'")
                }
            case ("hobbitFactorString", let .hobbit(want)):
                let total = try XCTUnwrap(c.input.totalTokens, "case '\(c.name)'")
                XCTAssertEqual(HistoryDelight.hobbitFactorString(total), want, "case '\(c.name)'")
            default:
                XCTFail("case '\(c.name)': fn '\(c.fn)' does not match its decoded want shape")
            }
        }
    }

    // MARK: - board-time.json

    private struct BoardTimeVectorFile: Decodable {
        let module: String
        let cases: [Case]

        struct Input: Decodable {
            let kind: String?
            let scope: String?
            let minutes: Int?
            let iso: String?
            let refIso: String?
            let s: String?
            let minutesAgo: Int?
        }

        enum Want {
            case string(String)
            case bool(Bool)
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
                case "isSameDay":
                    want = .bool(try c.decode(Bool.self, forKey: .want))
                default:
                    want = .string(try c.decode(String.self, forKey: .want))
                }
            }
        }
    }

    /// F17 (fresh-user audit 2026-08-16): the lane column shows the whole
    /// model name, not the web's one-letter abbreviation — "F" read as a
    /// truncated word to a stranger. Non-scoped buckets keep their labels;
    /// the fail case is a scoped bucket with no scope, which must not
    /// crash and falls back to bucketLabel's "?".
    func testLaneLabelCarriesTheWholeModelName() {
        XCTAssertEqual(BoardTime.laneLabel(kind: "weekly_scoped", scope: "Fable"), "Fable")
        XCTAssertEqual(BoardTime.laneLabel(kind: "weekly_scoped", scope: "opus"), "Opus")
        XCTAssertEqual(BoardTime.laneLabel(kind: "session", scope: nil), "5h")
        XCTAssertEqual(BoardTime.laneLabel(kind: "weekly_all", scope: nil), "wk")
        XCTAssertEqual(BoardTime.laneLabel(kind: "weekly_scoped", scope: nil), "?")
        XCTAssertEqual(BoardTime.laneLabel(kind: "weekly_scoped", scope: ""), "?")
        // bucketLabel (AX + web parity) is unchanged.
        XCTAssertEqual(BoardTime.bucketLabel(kind: "weekly_scoped", scope: "Fable"), "F")
    }

    func testBoardTimeMatchesGoldenVectors() throws {
        let vectors = try loadFile("board-time.json", as: BoardTimeVectorFile.self)
        XCTAssertEqual(vectors.module, "board-time")
        for c in vectors.cases {
            switch c.fn {
            case "bucketLabel":
                let kind = try XCTUnwrap(c.input.kind, "case '\(c.name)'")
                guard case let .string(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(BoardTime.bucketLabel(kind: kind, scope: c.input.scope), want, "case '\(c.name)'")
            case "fmtDurationLeft":
                let minutes = try XCTUnwrap(c.input.minutes, "case '\(c.name)'")
                guard case let .string(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(BoardTime.fmtDurationLeft(minutes), want, "case '\(c.name)'")
            case "isSameDay":
                let iso = try XCTUnwrap(c.input.iso, "case '\(c.name)'")
                let refIso = try XCTUnwrap(c.input.refIso, "case '\(c.name)'")
                guard case let .bool(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(BoardTime.isSameDay(iso, refIso), want, "case '\(c.name)'")
            case "findingSeverity":
                let s = try XCTUnwrap(c.input.s, "case '\(c.name)'")
                guard case let .string(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(BoardTime.findingSeverity(s).rawValue, want, "case '\(c.name)'")
            case "staleStampFromMinutes":
                let mins = try XCTUnwrap(c.input.minutesAgo, "case '\(c.name)'")
                guard case let .string(want) = c.want else { XCTFail("case '\(c.name)'"); continue }
                XCTAssertEqual(BoardTime.staleStampText(minutesAgo: mins), want, "case '\(c.name)'")
            default:
                XCTFail("unknown fn '\(c.fn)'")
            }
        }
    }
}
