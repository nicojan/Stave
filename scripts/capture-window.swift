// Usage: swift scripts/capture-window.swift <app name> <output.png>
// Captures the frontmost on-screen, layer-0 window owned by the app. Exits 1 with a message when there is none.
// The app is matched by its shown name or its executable name, so "Stave" also finds the Debug build, which shows as "Stave Debug"
// (plan 5, decision 8).
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: capture-window.swift <app name> <output.png>") }
let appName = arguments[1]
let output = arguments[2]

guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    fail("could not list windows (Screen Recording permission may be missing)")
}
// The list is ordered front to back, so the first match is the frontmost.
func ownedByApp(_ entry: [String: Any]) -> Bool {
    if (entry[kCGWindowOwnerName as String] as? String) == appName { return true }
    guard let pid = entry[kCGWindowOwnerPID as String] as? Int32 else { return false }
    return NSRunningApplication(processIdentifier: pid)?.executableURL?.lastPathComponent == appName
}
let match = info.first { entry in ownedByApp(entry) && (entry[kCGWindowLayer as String] as? Int) == 0 }
guard let windowID = match?[kCGWindowNumber as String] as? Int else { fail("no on-screen window for \(appName)") }

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
process.arguments = ["-x", "-o", "-l\(windowID)", output]
do { try process.run() } catch { fail("could not run screencapture: \(error)") }
process.waitUntilExit()
guard process.terminationStatus == 0 else { fail("screencapture failed with status \(process.terminationStatus)") }
