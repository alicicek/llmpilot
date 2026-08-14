import XCTest
@testable import llmpilot

/// Runs the Swift side of testdata/golden-vectors/ansi.json — the SAME
/// vector file the web-side runner (web/tests/golden-vectors.spec.ts) reads,
/// so Ansi.swift's parseAnsi stays provably identical to the web ansi.ts it
/// ports. See testdata/golden-vectors/README.md for the file schema and
/// HistoryVectorTests.swift for the (multi-case-field) pattern this mirrors.
final class AnsiVectorTests: XCTestCase {
    private struct VectorFile: Decodable {
        struct WantSpan: Decodable {
            let text: String
            let color: String?
            let dim: Bool
        }
        struct Case: Decodable {
            let name: String
            let input: String
            let want: [WantSpan]
        }
        let module: String
        let cases: [Case]
    }

    /// testdata/golden-vectors/, resolved relative to this file's own
    /// location (see GoldenVectorTests.vectorsDir for why).
    private static var vectorsDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("testdata/golden-vectors")
    }

    private func loadVectors(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> VectorFile {
        let dir = Self.vectorsDir
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        XCTAssertTrue(
            exists && isDir.boolValue,
            "golden-vectors dir not found at \(dir.path)",
            file: file, line: line
        )
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        let decoded = try JSONDecoder().decode(VectorFile.self, from: data)
        // A truncated/emptied vector file must FAIL, not vacuously pass.
        XCTAssertFalse(
            decoded.cases.isEmpty, "\(name): no cases — refusing a vacuous pass",
            file: file, line: line)
        return decoded
    }

    func testParseAnsiMatchesGoldenVectors() throws {
        let vectors = try loadVectors("ansi.json")
        XCTAssertEqual(vectors.module, "ansi")
        for c in vectors.cases {
            let got = parseAnsi(c.input)
            XCTAssertEqual(got.count, c.want.count, "case '\(c.name)': span count")
            for (i, span) in got.enumerated() where i < c.want.count {
                let w = c.want[i]
                XCTAssertEqual(span.text, w.text, "case '\(c.name)' span \(i) text")
                XCTAssertEqual(span.color, w.color, "case '\(c.name)' span \(i) color")
                XCTAssertEqual(span.dim, w.dim, "case '\(c.name)' span \(i) dim")
            }
        }
    }
}
