import AppKit
import ApplicationServices

// Accessibility helper for UI tests. Targets one process by PID, so several copies of the app
// can run side by side.
//
//   ax menuitem <pid>               print the center "x y" of the app's menu bar item
//   ax tree <pid>                   print the panel's elements: role | label | value | enabled | frame
//   ax press <pid> <label>          AXPress the first element whose label equals <label>
//   ax value <pid> <label>          print the element's value
//   ax enabled <pid> <label>        print 1 or 0
//   ax setvalue <pid> <label> <v>   focus a text field, set its value, and confirm it
//   ax hastext <pid> <text>         exit 0 when an element's label or value equals <text>
//   ax pressprefix <pid> <prefix>   AXPress the first button whose label starts with <prefix>
//   ax menutitle <pid>              print the menu bar item's title
//
// A label is the element's title, description, or (for text fields) its placeholder.

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else {
    FileHandle.standardError.write(Data("usage: ax <command> <pid> [label] [value]\n".utf8))
    exit(2)
}
let app = AXUIElementCreateApplication(pid)

func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v as? T
}

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p: AXValue = attr(e, kAXPositionAttribute), let s: AXValue = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p, .cgPoint, &pt)
    AXValueGetValue(s, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func label(_ e: AXUIElement) -> String {
    for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute] {
        if let s: String = attr(e, k), !s.isEmpty { return s }
    }
    return ""
}

func walk(_ e: AXUIElement, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(e) { return true }
    for c: AXUIElement in attr(e, kAXChildrenAttribute) ?? [] {
        if walk(c, visit) { return true }
    }
    return false
}

func windows() -> [AXUIElement] { attr(app, kAXWindowsAttribute) ?? [] }

func find(_ wanted: String) -> AXUIElement? {
    var found: AXUIElement?
    for w in windows() {
        if walk(w, { e in
            if label(e) == wanted { found = e; return true }
            return false
        }) { break }
    }
    return found
}

func valueString(_ e: AXUIElement) -> String {
    let v: CFTypeRef? = attr(e, kAXValueAttribute)
    if let n = v as? NSNumber { return n.stringValue }
    if let s = v as? String { return s }
    return ""
}

switch args[1] {
case "hastext":
    guard args.count >= 4 else { exit(2) }
    var hit = false
    for w in windows() where walk(w, { label($0) == args[3] || valueString($0) == args[3] }) { hit = true; break }
    exit(hit ? 0 : 1)
case "pressprefix":
    guard args.count >= 4 else { exit(2) }
    var target: AXUIElement?
    for w in windows() where walk(w, { e in
        let role: String = attr(e, kAXRoleAttribute) ?? ""
        if role == kAXButtonRole as String && label(e).hasPrefix(args[3]) { target = e; return true }
        return false
    }) { break }
    guard let target else { exit(1) }
    exit(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success ? 0 : 1)
case "menutitle":
    guard let bar: AXUIElement = attr(app, "AXExtrasMenuBar"),
          let item = (attr(bar, kAXChildrenAttribute) as [AXUIElement]?)?.first else { exit(1) }
    print(label(item).isEmpty ? valueString(item) : label(item))
case "menuitem":
    guard let bar: AXUIElement = attr(app, "AXExtrasMenuBar"),
          let item = (attr(bar, kAXChildrenAttribute) as [AXUIElement]?)?.first,
          let f = frame(item) else { exit(1) }
    print("\(Int(f.midX)) \(Int(f.midY))")
case "tree":
    for w in windows() {
        _ = walk(w) { e in
            let role: String = attr(e, kAXRoleAttribute) ?? "?"
            let enabled: Bool = attr(e, kAXEnabledAttribute) ?? true
            let f = frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
            print("\(role) | \(label(e)) | \(valueString(e)) | \(enabled ? 1 : 0) | \(f)")
            return false
        }
    }
case "press":
    guard args.count >= 4, let e = find(args[3]) else { exit(1) }
    exit(AXUIElementPerformAction(e, kAXPressAction as CFString) == .success ? 0 : 1)
case "value":
    guard args.count >= 4, let e = find(args[3]) else { exit(1) }
    print(valueString(e))
case "enabled":
    guard args.count >= 4, let e = find(args[3]) else { exit(1) }
    let enabled: Bool = attr(e, kAXEnabledAttribute) ?? true
    print(enabled ? 1 : 0)
case "setvalue":
    guard args.count >= 5, let e = find(args[3]) else { exit(1) }
    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let ok = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, args[4] as CFTypeRef) == .success
    AXUIElementPerformAction(e, "AXConfirm" as CFString)
    exit(ok ? 0 : 1)
default:
    exit(2)
}
