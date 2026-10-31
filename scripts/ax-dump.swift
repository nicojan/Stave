// Usage: swift scripts/ax-dump.swift <process name>   (normally run through scripts/ax-dump.sh)
// Prints "role (subrole) | description | value" for every accessibility element of the process's front window.
// It reads AXDescription directly: System Events' `description` returns the role description instead for many SwiftUI controls.
// Needs Accessibility permission for the terminal.
import AppKit
import ApplicationServices

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func dump(_ element: AXUIElement) {
    let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
    let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
    let raw = attribute(element, kAXValueAttribute)
    let value = (raw as? String) ?? (raw as? NSNumber).map { "\($0)" } ?? ""
    let subrole = attribute(element, kAXSubroleAttribute) as? String
    print("\(role)\(subrole.map { " (\($0))" } ?? "") | \(description) | \(value)")
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { dump(child) }
}

guard CommandLine.arguments.count == 2 else { fail("usage: ax-dump.swift <process name>") }
guard AXIsProcessTrusted() else { fail("Accessibility permission is missing for this terminal") }
let name = CommandLine.arguments[1]
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) else { fail("no process named \(name)") }
let root = AXUIElementCreateApplication(app.processIdentifier)
guard let window = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first else { fail("no window for \(name)") }
dump(window)
