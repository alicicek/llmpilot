import Foundation

/// Starts the daemon when it's down. No fallback logic beyond this:
/// find the CLI, `daemon install`, `launchctl bootout` + `bootstrap` —
/// exactly what the CLI itself prints as the manual path.
enum DaemonLauncher {
    /// $HOME-first home resolution, matching the CLI's os.UserHomeDir — on
    /// macOS 26 both NSHomeDirectory() and homeDirectoryForCurrentUser ignore
    /// $HOME (verified), so a sandboxed run would otherwise split the plist
    /// path between the app and `daemon install`.
    static func userHome() -> String {
        if let env = ProcessInfo.processInfo.environment["HOME"], !env.isEmpty {
            return env
        }
        return NSHomeDirectory()
    }

    static func findBinary() -> String? {
        if let env = ProcessInfo.processInfo.environment["LLMPILOT_BIN"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        // Official builds bundle the Pro-enabled daemon in Resources; prefer it
        // so the autopilot engine is present. From-source/Homebrew installs have
        // no bundled binary and fall back to the free one on PATH.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("llmpilot").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        for candidate in ["/opt/homebrew/bin/llmpilot", "/usr/local/bin/llmpilot"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Returns nil on success, or what-happened + what-to-do-next copy.
    static func start() -> String? {
        guard let bin = findBinary() else {
            return "llmpilot CLI not found — install it first, then relaunch"
        }
        if let err = run(bin, ["daemon", "install"]) { return err }
        let plist = userHome()
            + "/Library/LaunchAgents/dev.llmpilot.daemon.plist"
        // Legacy `launchctl load` silently no-ops on an already-loaded or
        // disabled agent; bootout (failure ignored — usually just "not
        // loaded") then bootstrap restarts it deterministically.
        let domain = "gui/\(getuid())"
        _ = run("/bin/launchctl", ["bootout", "\(domain)/dev.llmpilot.daemon"])
        return run("/bin/launchctl", ["bootstrap", domain, plist])
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "could not run \(path): \(error.localizedDescription)"
        }
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return msg?.isEmpty == false ? msg : "\(path) exited \(p.terminationStatus)"
        }
        return nil
    }
}
