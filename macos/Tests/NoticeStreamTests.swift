import XCTest
@testable import llmpilot

/// Decode coverage for `Notice` / `NoticeStream.parse` (Support/
/// NoticeStream.swift) — the wire shape of internal/daemon/notices.go's
/// `Notice` struct, read off one raw `/v1/notices` SSE line. `parse` is a
/// pure function precisely so this needs no live connection (chunk 5B
/// brief).
final class NoticeStreamTests: XCTestCase {
    private func noticeJSON(
        id: String = "1-1", at: String = "2026-08-07T09:00:00Z",
        title: String = "llmpilot", body: String = "a at 80% — resets 15:04"
    ) -> String {
        """
        {"id":"\(id)","at":"\(at)","title":"\(title)","body":"\(body)"}
        """
    }

    func testParsesDataLine() {
        let n = NoticeStream.parse(line: "data: \(noticeJSON())")
        XCTAssertEqual(n?.id, "1-1")
        XCTAssertEqual(n?.title, "llmpilot")
        XCTAssertEqual(n?.body, "a at 80% — resets 15:04")
        XCTAssertNotNil(n?.at)
    }

    func testIgnoresNonDataLines() {
        XCTAssertNil(NoticeStream.parse(line: "event: notice"))
        XCTAssertNil(NoticeStream.parse(line: ""))
        XCTAssertNil(NoticeStream.parse(line: ": keep-alive"))
    }

    func testIgnoresEmptyOrMalformedDataPayload() {
        XCTAssertNil(NoticeStream.parse(line: "data: "))
        XCTAssertNil(NoticeStream.parse(line: "data: {not json"))
        // Missing required fields (title, body) must fail to decode, not
        // silently default — a half-decoded Notice with an empty body would
        // post a blank system notification.
        XCTAssertNil(NoticeStream.parse(line: "data: {\"id\":\"1\",\"at\":\"2026-08-07T09:00:00Z\"}"))
    }

    /// Go's RFC3339Nano trims trailing zeros, so the fractional width varies
    /// per response — Notice.at rides the same DaemonDates decoder every
    /// other daemon date field uses (Models.swift), proven here end to end.
    func testDecodesVariableFractionalSecondDates() {
        let line = "data: \(noticeJSON(at: "2026-08-07T09:00:00.123456789Z"))"
        XCTAssertNotNil(NoticeStream.parse(line: line)?.at)
    }

    func testUnknownExtraFieldsDoNotBreakDecoding() {
        let line = """
        data: {"id":"1-1","at":"2026-08-07T09:00:00Z","title":"llmpilot","body":"b","future_field":true}
        """
        XCTAssertEqual(NoticeStream.parse(line: line)?.id, "1-1")
    }
}
