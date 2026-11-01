import Foundation

/// History's last analytics per range, kept in the app's Caches folder so a
/// relaunch shows the charts at once while the daemon is asked again. The
/// daemon's own scan cache holds the same token counts; nothing here is
/// content. Best effort: an unreadable or missing file is simply nothing
/// kept.
struct AnalyticsDiskCache {
    let url: URL

    /// ~/Library/Caches/<bundle id>/history-analytics.json.
    static var standard: AnalyticsDiskCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.llmpilot.menubar", isDirectory: true)
        return AnalyticsDiskCache(url: dir.appendingPathComponent("history-analytics.json"))
    }

    func load() -> [Int: AnalyticsResponse] {
        guard let data = try? Data(contentsOf: url),
              let byKey = try? DaemonDates.decoder().decode([String: AnalyticsResponse].self, from: data)
        else { return [:] }
        var out: [Int: AnalyticsResponse] = [:]
        for (k, v) in byKey {
            if let days = Int(k) { out[days] = v }
        }
        return out
    }

    func save(_ byDays: [Int: AnalyticsResponse]) {
        let byKey = Dictionary(uniqueKeysWithValues: byDays.map { (String($0.key), $0.value) })
        let encoder = JSONEncoder()
        // Fractional seconds kept: the daemon's as_of carries them, and a
        // copy that drops them is not the response it copied.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        guard let data = try? encoder.encode(byKey) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
