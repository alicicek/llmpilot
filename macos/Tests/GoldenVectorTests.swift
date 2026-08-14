import SwiftUI
import XCTest
@testable import llmpilot

/// Runs the Swift side of testdata/golden-vectors/*.json — the SAME vector
/// files the (future) web-side runner reads, so a ported pure-logic module
/// stays provably identical across stacks. See
/// testdata/golden-vectors/README.md for the file schema and convention.
final class GoldenVectorTests: XCTestCase {
    private struct VectorFile: Decodable {
        struct Source: Decodable { let web: String; let swift: String }
        struct Case: Decodable {
            struct Input: Decodable {
                let percent: Double
                let severity: String?
            }
            let name: String
            let input: Input
            let want: String
        }
        let module: String
        let source: Source
        let cases: [Case]
    }

    /// testdata/golden-vectors/, resolved relative to this file's own
    /// location rather than the process's working directory — xcodebuild
    /// can run tests from a derived-data dir far from the repo checkout.
    /// macos/Tests/GoldenVectorTests.swift -> (drop filename) macos/Tests
    /// -> (../..) repo root -> testdata/golden-vectors.
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
            "golden-vectors dir not found at \(dir.path) — check the #filePath-relative walk in GoldenVectorTests.vectorsDir",
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

    func testSeverityMatchesGoldenVectors() throws {
        let vectors = try loadVectors("severity.json")
        XCTAssertEqual(vectors.module, "severity")

        for c in vectors.cases {
            let got = CockpitTheme.severityBand(
                percent: c.input.percent, severity: c.input.severity)
            XCTAssertEqual(
                got.rawValue, c.want,
                "case '\(c.name)': severityBand(percent: \(c.input.percent), severity: \(c.input.severity ?? "nil"))")

            // Parity net for the percent-only band: the menu bar's
            // Theme.severity has no override branch (it colors pure percent
            // gauges), so on override-free cases the two mappings must agree
            // — calm ↔ ok, warn ↔ warn, crit ↔ crit.
            if c.input.severity == nil {
                let color = Theme.severity(c.input.percent)
                let expected: Color
                switch got {
                case .calm: expected = Theme.ok
                case .warn: expected = Theme.warn
                case .crit: expected = Theme.crit
                }
                XCTAssertEqual(
                    color, expected,
                    "case '\(c.name)': Theme.severity must agree with the shared percent bands")
            }
        }
    }
}
