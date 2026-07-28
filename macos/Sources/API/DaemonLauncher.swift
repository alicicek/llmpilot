import Darwin
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

    /// The executable the daemon's launchd job is currently running, or nil
    /// when there is no such job or the path cannot be read.
    static func runningDaemonExecutable() -> String? {
        guard let out = capture("/bin/launchctl",
                                ["print", "gui/\(getuid())/dev.llmpilot.daemon"]),
              let pid = parsePID(out) else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func parsePID(_ launchctlOutput: String) -> pid_t? {
        for line in launchctlOutput.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("pid = ") else { continue }
            return pid_t(t.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Is this daemon executable one an in-place update left behind?
    ///
    /// Deliberately narrow. A from-source or Homebrew install legitimately
    /// runs the daemon from PATH and must NEVER be bounced — doing so on every
    /// launch would be an endless restart loop. Only a binary the updater
    /// staged aside, or one inside some OTHER llmpilot.app, counts as stale.
    static func isStaleExecutable(_ exe: String, ourBundle: String) -> Bool {
        if exe.hasPrefix(ourBundle + "/") { return false }
        if exe.contains("/org.sparkle-project.Sparkle/") { return true }
        return exe.contains("/llmpilot.app/")
    }

    /// Bounce the agent so launchd re-resolves the program from the CURRENT
    /// registration. After an in-place update the old daemon keeps running
    /// from the replaced bundle — Sparkle swaps the app but never restarts a
    /// separate launchd job — so without this the user runs new app code
    /// against a pre-update daemon until they next log out.
    /// Returns nil on success, or what-happened copy.
    static func restartAgent() -> String? {
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/dev.llmpilot.daemon"])
    }

    /// Runs a command and returns stdout, or nil if it could not run.
    private static func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
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
