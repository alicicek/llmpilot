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

    /// Floor interlock for every launchctl MUTATION in this file: launchctl
    /// ignores $HOME, so `gui/<uid>/dev.llmpilot.daemon` is ALWAYS the real
    /// user's daemon — bootout/bootstrap would stop it and repoint the label
    /// at a sandbox plist that the harness then deletes; kickstart -k is a
    /// SIGKILL into the credential-write hazard window. Two callers must
    /// never mutate it:
    /// - XCTest (hosted unit tests reached these through un-stubbed seams —
    ///   proven live 2026-08-07);
    /// - harnesses that opt in via LLMPILOT_NO_LAUNCHD=1 (e2e-native.sh —
    ///   its fixture daemon runs in the foreground, launchd has no role).
    /// Deliberately NOT keyed on LLMPILOT_TEST alone: e2e-firstrun.sh
    /// legitimately bootstraps a sandbox agent under LLMPILOT_TEST, behind
    /// its own already-loaded-label preconditions. A floor here means the
    /// view model cannot forget to check — refusal copy is returned like any
    /// other launch error.
    static var launchdMutationRefusal: String? {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil {
            return "refusing to touch the real launchd domain from a test process"
        }
        if env["LLMPILOT_NO_LAUNCHD"] == "1" {
            return "LLMPILOT_NO_LAUNCHD is set — refusing to touch the real launchd domain"
        }
        return nil
    }

    /// Returns nil on success, or what-happened + what-to-do-next copy.
    static func start() -> String? {
        if let refusal = launchdMutationRefusal { return refusal }
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

    /// What the daemon's launchd job is executing.
    ///
    /// The three states must not be collapsed. 1.2.2 folded `executableGone`
    /// into `noJob` and so could never fire on the update it was written for:
    /// Sparkle deletes the bundle it moved aside, and a process whose
    /// executable has been unlinked has no path left to read.
    enum DaemonExecutable: Equatable, Sendable {
        /// No such job, or launchd named no pid — nothing to judge.
        case noJob
        /// A live process whose executable can no longer be located on disk.
        /// This is the NORMAL state after an in-place update.
        case executableGone
        case path(String)
    }

    /// What the daemon's launchd job is currently executing.
    static func runningDaemonExecutable() -> DaemonExecutable {
        guard let out = capture("/bin/launchctl",
                                ["print", "gui/\(getuid())/dev.llmpilot.daemon"]),
              let pid = parsePID(out) else { return .noJob }
        return executable(ofPID: pid)
    }

    /// Split out from the launchd lookup so tests can drive the real reader
    /// against a real process — the coverage gap that let 1.2.1 and 1.2.2 both
    /// ship a check that could not fire. Every earlier test supplied the path
    /// instead of reading it.
    static func executable(ofPID pid: pid_t) -> DaemonExecutable {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        // proc_pidpath answers 0 for a running process whose executable was
        // deleted (measured on macOS 26.5: a live pid returns its path, the
        // same pid returns 0 with an empty buffer once the file is unlinked).
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return .executableGone }
        return .path(String(cString: buf))
    }

    static func parsePID(_ launchctlOutput: String) -> pid_t? {
        for line in launchctlOutput.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("pid = ") else { continue }
            return pid_t(t.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Is the daemon one an in-place update left behind?
    ///
    /// An executable that has vanished from disk is stale whatever its path
    /// was: the only thing that deletes a running daemon's binary is an
    /// updater replacing the bundle around it. Bouncing is safe even in the
    /// rarer readings of that state (the process exited under us; a package
    /// manager swapped the file), because launchd re-resolves the program from
    /// the CURRENT registration — and FleetViewModel bounces at most once per
    /// app launch, so no reading of it can loop.
    static func isStale(_ state: DaemonExecutable, ourBundle: String) -> Bool {
        switch state {
        case .noJob: return false
        case .executableGone: return true
        case .path(let exe): return isStaleExecutable(exe, ourBundle: ourBundle)
        }
    }

    /// Is this daemon executable PATH one an in-place update left behind?
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
        if let refusal = launchdMutationRefusal { return refusal }
        return run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/dev.llmpilot.daemon"])
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
