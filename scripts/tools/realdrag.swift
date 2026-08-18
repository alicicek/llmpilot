// realdrag — press, drag, release as REAL CGEvents, the way a human's mouse
// resizes a window. `realclick` only ever posts down/up at one point, and
// System Events' `set size of window` bypasses AppKit's live-resize path
// entirely — neither can see a window whose minimum size is not enforced
// (audit 2026-08-17, N1: the shipped 1.3.1 cockpit dragged down to 226×231
// while `win.minSize` read 1000×700 and every unit test passed).
// Coordinates are global screen points with the origin at the TOP-LEFT of
// the main display — the same space System Events reports for `position of`.
//
//   realdrag <x1> <y1> <x2> <y2> [--steps N]
//
// The intermediate leftMouseDragged events matter: AppKit's live resize
// tracks the drag, and a single jump from press to release is not the same
// gesture. Default 24 steps at ~12ms is a brisk but ordinary human drag.
import CoreGraphics
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
var steps = 24
if let i = args.firstIndex(of: "--steps"), i + 1 < args.count, let n = Int(args[i + 1]), n > 0 {
    steps = n
    args.removeSubrange(i...(i + 1))
}
guard args.count >= 4,
      let x1 = Double(args[0]), let y1 = Double(args[1]),
      let x2 = Double(args[2]), let y2 = Double(args[3]) else {
    FileHandle.standardError.write("usage: realdrag <x1> <y1> <x2> <y2> [--steps N]\n".data(using: .utf8)!)
    exit(2)
}
guard let src = CGEventSource(stateID: .hidSystemState) else { exit(3) }
func post(_ type: CGEventType, _ p: CGPoint) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { exit(4) }
    e.post(tap: .cghidEventTap)
}
post(.mouseMoved, CGPoint(x: x1, y: y1))
usleep(150_000) // let the resize cursor settle over the edge
post(.leftMouseDown, CGPoint(x: x1, y: y1))
usleep(120_000)
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
    usleep(12_000)
}
usleep(120_000)
post(.leftMouseUp, CGPoint(x: x2, y: y2))
usleep(150_000)
print("realdrag: \(Int(x1)),\(Int(y1)) -> \(Int(x2)),\(Int(y2)) in \(steps) steps")
