// the live proof of the package: run its readers and windows on the text fields of one app's
// window, behind the other windows, and write one picture of that window with eloq's lines and
// its offer panel on it. run.sh builds this with the package's own sources.
//
//   harness <out.png> <pid> <window title> [<word>]
//
// it reads only the named window, captures that window and eloq's own windows by id (never the
// screen), and prints what each reader found. with <word>, it puts the cursor after that word
// in a native field first; a web rich text field has its cursor placed by the fixture.
import AppKit
import ApplicationServices

let arguments = CommandLine.arguments
guard arguments.count >= 4, let pid = pid_t(arguments[2]) else { print("usage: harness <out.png> <pid> <window title> [<word>]"); exit(64) }
let out = arguments[1], title = arguments[3], word = arguments.count > 4 ? arguments[4] : nil
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard AXIsProcessTrusted() else { print("this shell has no accessibility permission"); exit(2) }

let target = AXUIElementCreateApplication(pid)
func children(_ e: AXUIElement) -> [AXUIElement] { AX.attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func all(_ e: AXUIElement, _ depth: Int, _ found: inout [AXUIElement]) {
    found.append(e)
    if depth < 40 { for child in children(e) { all(child, depth + 1, &found) } }
}
func fields() -> [AXUIElement] {
    guard let window = (AX.attribute(target, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { (AX.attribute($0, kAXTitleAttribute) as? String ?? "").contains(title) }) else { return [] }
    var found: [AXUIElement] = []
    all(window, 0, &found)
    return found.filter(AX.isReadableText)
}
// as the app does for an electron app in front; a native app ignores it. the tree comes a moment later.
AX.wakeElectron(pid)
var found = fields()
for _ in 0..<8 where found.isEmpty {
    Thread.sleep(forTimeInterval: 0.5)
    found = fields()
}
print("text fields:", found.count)

let scan = TextScan(overused: ["very", "interesting", "really", "basically", "a bunch of", "kind of"], targets: ["compelling", "vivid", "precise"])
let table = TypingLookup(forms: ["very": ["t1"], "interesting": ["t2"], "really": ["t3"], "basically": ["t4"], "a bunch of": ["t5"], "kind of": ["t6"]], maxWords: 3)
let primary = NSScreen.screens.first!.frame.height
var windows: [NSWindow] = []
for field in found {
    let name = AX.attribute(field, kAXDescriptionAttribute) as? String ?? AX.attribute(field, kAXRoleAttribute) as? String ?? "?"
    let started = Date()
    let pass = UnderlineReader.read(field, with: scan, primaryHeight: primary)
    print(name, "| underline pass ms", Int(Date().timeIntervalSince(started) * 1000), "| lines", pass?.lines.count ?? -1, "| text nodes", UnderlineReader.textNodes(field).count)
    if let pass, !pass.lines.isEmpty {
        let overlay = UnderlineWindow()
        overlay.setFrame(pass.frame, display: false)
        overlay.lines.lines = pass.lines
        overlay.orderFrontRegardless()
        windows.append(overlay)
    }
    // a native field takes a cursor from here
    if let word, let value = AX.attribute(field, kAXValueAttribute) as? String, children(field).isEmpty {
        let at = (value as NSString).range(of: word)
        if at.location != NSNotFound, let place = AX.value(CFRange(location: at.location + at.length, length: 0)) {
            AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, place)
        }
    }
    // a web page has one cursor, and every field of it answers for that one: only the field the
    // cursor is in is asked (the app asks the focused field, which is that one)
    if let frame = AX.frame(field), let cursor = AX.selectionBox(field), !frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: cursor.midX, y: cursor.midY)) { continue }
    let reading = CaretReader.read(field)
    switch reading {
    case .unknown: print("  cursor: unknown")
    case .nothing: print("  cursor: nothing to offer")
    case .text(let before, let box):
        let at = table.atCursor(before)
        print("  cursor: before ends “\(before.suffix(24))” | box", box.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none",
              "| word at cursor:", at.map { "“\($0.hit.text)” + “\($0.trailing)”" } ?? "none")
        if let at, let box {
            let panel = OfferPanel()
            let offer = Offer(term: at.hit.termIds[0], typed: at.hit.text, boundary: at.trailing,
                              moves: [Move(id: "m1", text: "compelling", useWhen: "a point that holds attention"), Move(id: "m2", text: "vivid", useWhen: "")], app: "")
            let caret = AX.appKit(box, primaryHeight: primary)
            panel.show(offer, at: NSRect(x: caret.maxX, y: caret.minY, width: 1, height: caret.height))
            windows.append(panel)
        }
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
    let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
    func onScreen(_ owner: pid_t, layers: Set<Int>, named: String? = nil) -> [(Int, CGRect)] {
        // lower layers first, so the picture stacks eloq's windows as the screen does
        info.sorted { (($0[kCGWindowLayer as String] as? Int) ?? 0) < (($1[kCGWindowLayer as String] as? Int) ?? 0) }.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == owner && layers.contains(($0[kCGWindowLayer as String] as? Int) ?? -1) && ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
            .filter { named == nil || ($0[kCGWindowName as String] as? String ?? "").contains(named!) }
            .map { ($0[kCGWindowNumber as String] as! Int, CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary) ?? .zero) }
    }
    func capture(_ id: Int, _ name: String) -> NSImage? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(id), name]
        try? task.run()
        task.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: name) }
        return NSImage(contentsOfFile: name).map { NSImage(data: $0.tiffRepresentation!)! }
    }
    // the named window and no other: an app may have documents of the person's open beside it
    guard let (docId, doc) = onScreen(pid, layers: [0], named: title).first,
          let picture = capture(docId, out + ".part.png") else { print("the window could not be captured"); exit(7) }
    // room under the window for a panel that hangs below its last line
    let canvas = CGRect(x: doc.minX, y: doc.minY, width: doc.width, height: doc.height + 90)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas.size
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()
    // cg bounds have a top-left origin; the bitmap's is bottom-left
    func draw(_ image: NSImage, _ bounds: CGRect) {
        image.draw(in: NSRect(x: bounds.minX - canvas.minX, y: canvas.maxY - bounds.maxY, width: bounds.width, height: bounds.height))
    }
    draw(picture, doc)
    for (i, (id, bounds)) in onScreen(ProcessInfo.processInfo.processIdentifier, layers: [3, 101]).enumerated() {
        if let image = capture(id, out + ".part\(i).png") { draw(image, bounds) }
    }
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print("wrote", out)
    exit(0)
}
app.run()
