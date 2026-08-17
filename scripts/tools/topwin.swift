// topwin — which window owns a screen point? Prints "<owner> pid=<pid>
// id=<window> name='<title>' layer=<n>" for the frontmost on-screen window
// (normal levels 0..19, front-to-back) containing the point, or "none".
// The real-click gate uses it to REFUSE a click that would land on some
// other app's window (a covered cockpit would otherwise read as "dead").
// Coordinates: global screen points, top-left origin (System Events'
// `position of` space).
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3,
      let x = Double(CommandLine.arguments[1]), let y = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write("usage: topwin <x> <y>\n".data(using: .utf8)!)
    exit(2)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list {
    let layer = w[kCGWindowLayer as String] as! Int
    if layer < 0 || layer >= 20 { continue }
    let b = w[kCGWindowBounds as String] as! [String: Double]
    if x >= b["X"]! && x < b["X"]! + b["Width"]! && y >= b["Y"]! && y < b["Y"]! + b["Height"]! {
        print("\(w[kCGWindowOwnerName as String] as? String ?? "?") pid=\(w[kCGWindowOwnerPID as String]!) id=\(w[kCGWindowNumber as String]!) name='\(w[kCGWindowName as String] as? String ?? "")' layer=\(layer)")
        exit(0)
    }
}
print("none")
