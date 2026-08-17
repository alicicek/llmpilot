// realclick — post a REAL left click as a CGEvent, the way a human mouse
// does. Accessibility `click`/AXPress bypasses mouse-down delivery
// entirely, which is how a click-deaf window passed every AX-driven e2e
// walk (audit 2026-08-16, F18). Coordinates are global screen points with
// the origin at the TOP-LEFT of the main display — the same space System
// Events reports for `position of` an element.
//
//   realclick <x> <y>                click at a point (HID tap: whatever
//                                    window is on top gets it)
//   realclick <x> <y> --move         hover only (no button)
//   realclick <x> <y> --pid <pid>    deliver to ONE process's event queue
//                                    (CGEvent.postToPid) — the app routes
//                                    it to its own window under that point
//                                    even when another app's window covers
//                                    it; the gate uses this so a busy
//                                    desktop cannot spoil the assertion.
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var pid: pid_t? = nil
if let i = args.firstIndex(of: "--pid"), i + 1 < args.count, let p = Int32(args[i + 1]) {
    pid = p
    args.removeSubrange(i...(i + 1))
}
let moveOnly = args.contains("--move")
args.removeAll { $0 == "--move" }
guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
    FileHandle.standardError.write("usage: realclick <x> <y> [--move] [--pid <pid>]\n".data(using: .utf8)!)
    exit(2)
}
let p = CGPoint(x: x, y: y)
guard let src = CGEventSource(stateID: .hidSystemState) else { exit(3) }
func post(_ type: CGEventType) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { exit(4) }
    if let pid { e.postToPid(pid) } else { e.post(tap: .cghidEventTap) }
}
post(.mouseMoved)
usleep(120_000)
if !moveOnly {
    post(.leftMouseDown)
    usleep(60_000)
    post(.leftMouseUp)
}
usleep(80_000)
print("realclick: \(moveOnly ? "moved to" : "clicked") \(Int(x)),\(Int(y))\(pid.map { " → pid \($0)" } ?? "")")
