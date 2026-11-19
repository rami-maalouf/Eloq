// the end-to-end proof of the offer: real key events, through the running eloq app's key tap,
// into a text field of the electron fixture, and the field's text read back.
//
//   e2e <fixture pid>
//
// it needs eloq running with the accessibility permission, and the fixture in front with its
// "scratch" field focused (run.sh e2e does both). it types for about fifteen seconds, and stops
// at once if another app comes to the front, so no key of it lands anywhere else. it uses one
// overused word of the library that has two targets, and so adds a few counts for that word to
// today's progress.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

guard CommandLine.arguments.count > 1, let fixture = pid_t(CommandLine.arguments[1]) else { print("usage: e2e <fixture pid>"); exit(64) }
guard AXIsProcessTrusted() else { print("this shell has no accessibility permission"); exit(2) }
guard let eloq = NSRunningApplication.runningApplications(withBundleIdentifier: "studio.orbitlabs.eloq.app").first else { print("eloq is not running"); exit(3) }

// eloq must have its taps up
var tapCount: UInt32 = 0
CGGetEventTapList(0, nil, &tapCount)
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(tapCount))
CGGetEventTapList(tapCount, &taps, &tapCount)
let own = taps.filter { $0.tappingProcess == eloq.processIdentifier }
print("eloq taps:", own.map { $0.options == .listenOnly ? "listen-only" : "active" }.sorted().joined(separator: ", "))
guard own.contains(where: { $0.options != .listenOnly && $0.enabled }) else { print("eloq has no key tap: it lacks the accessibility permission"); exit(4) }

// a word of the library with two targets, both plain words
let path = NSString(string: "~/Library/Application Support/exact/studio.orbitlabs.eloq.app/data/snapshot.json").expandingTildeInPath
guard let data = FileManager.default.contents(atPath: path), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let typing = json["typing"] as? [String: Any], let forms = typing["forms"] as? [String: [String]],
      let moves = typing["moves"] as? [String: [[String: Any]]] else { print("no typing table in eloq's snapshot"); exit(5) }
func plain(_ s: String) -> Bool { s.count >= 4 && s.allSatisfy { $0.isLetter && $0.isLowercase && $0.isASCII } }
var chosen: (word: String, first: String, second: String)?
for (form, ids) in forms.sorted(by: { $0.key < $1.key }) where plain(form) {
    guard let term = ids.first(where: { !(moves[$0] ?? []).isEmpty }), let list = moves[term], list.count >= 2,
          let a = list[0]["text"] as? String, let b = list[1]["text"] as? String, plain(a), plain(b), forms[a] == nil, forms[b] == nil else { continue }
    chosen = (form, a, b)
    break
}
guard let (word, first, second) = chosen else { print("the library has no plain word with two plain targets"); exit(6) }
print("word: \(word) -> \(first), \(second)")

let app = AXUIElementCreateApplication(fixture)
AX.wakeElectron(fixture)
func children(_ e: AXUIElement) -> [AXUIElement] { AX.attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func find(_ e: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
    if (AX.attribute(e, kAXDescriptionAttribute) as? String) == "scratch", AX.isReadableText(e) { return e }
    guard depth < 40 else { return nil }
    for child in children(e) { if let hit = find(child, depth + 1) { return hit } }
    return nil
}
var scratch: AXUIElement?
for _ in 0..<12 where scratch == nil {
    scratch = find(app)
    if scratch == nil { Thread.sleep(forTimeInterval: 0.5) }
}
guard let scratch else { print("the fixture's scratch field was not found"); exit(7) }

func frontIsFixture() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture }
func pump(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
for _ in 0..<20 where !frontIsFixture() { pump(0.25) }
guard frontIsFixture() else { print("the fixture is not in front"); exit(8) }

let source = CGEventSource(stateID: .hidSystemState)
/// stops the run the moment another app is in front: no key goes to an app of the person's
func post(_ event: CGEvent?) {
    guard frontIsFixture() else { print("another app came to the front (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")): stopped"); exit(9) }
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.012)
}
func type(_ text: String) {
    for character in text {
        let units = Array(String(character).utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            post(event)
        }
    }
}
func press(_ code: Int, _ flags: CGEventFlags = [], characters: String? = nil) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        if let characters {
            let units = Array(characters.utf16)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        post(event)
    }
}
func text() -> String {
    let nodes = UnderlineReader.textNodes(scratch).map(\.text).joined()
    return nodes.isEmpty ? (AX.attribute(scratch, kAXValueAttribute) as? String ?? "").trimmingCharacters(in: .newlines) : nodes
}
func panelUp() -> Bool {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    return info.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == eloq.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 101 }
}
func clear() {
    press(kVK_ANSI_A, .maskCommand)
    press(kVK_Delete)
    pump(0.35)
}

var failures = 0
func expect(_ what: String, _ ok: Bool, _ got: String = "") {
    print(ok ? "ok  " : "FAIL", what, ok || got.isEmpty ? "" : "| got: \(got)")
    if !ok { failures += 1 }
}

// 1. a word just typed, with no space after it: the panel comes when the keys rest, and tab swaps
clear()
type("It was \(word)")
pump(0.9)
expect("the panel shows at the end of a typed word, with no space", panelUp())
press(kVK_Tab)
pump(0.5)
expect("tab swaps it for the first target", text() == "It was \(first)", text())
expect("the panel is away after the swap", !panelUp())

// 2. the same, and a bare digit picks the second target
clear()
type("It was \(word)")
pump(0.9)
press(kVK_ANSI_2, characters: "2")
pump(0.5)
expect("2 swaps it for the second target", text() == "It was \(second)", text())

// 3. after a space the panel stays, and a number is a number
clear()
type("It was \(word) ")
pump(0.7)
expect("the panel stays after a space", panelUp())
press(kVK_ANSI_5, characters: "5")
pump(0.6)
expect("a digit typed after the space is typed", text() == "It was \(word) 5", text())
expect("and the panel is away", !panelUp())

// 4. after a space, option and a digit swap, and the space is kept
clear()
type("It was \(word) ")
pump(0.7)
press(kVK_ANSI_2, .maskAlternate, characters: "\u{2122}")
pump(0.5)
expect("option-2 after a space swaps for the second target and keeps the space", text() == "It was \(second) " || text() == "It was \(second)\u{A0}" || text() == "It was \(second)", text())

// 5. a word that was already there: the cursor goes to its end
clear()
type("It was \(word) today")
pump(0.5)
for _ in 0..<6 { press(kVK_LeftArrow) }
pump(0.9)
expect("the panel shows when the cursor rests at the end of a word written before", panelUp())
press(kVK_Tab)
pump(0.5)
expect("tab swaps that word and leaves the rest", text() == "It was \(first) today", text())

// 6. inside a word there is nothing to offer, and tab is a tab
clear()
type("It was \(word)")
pump(0.4)
press(kVK_LeftArrow)
pump(0.9)
expect("no panel with the cursor inside the word", !panelUp())

// 7. typing on keeps the word
clear()
type("It was \(word)")
pump(0.9)
type("s more")
pump(0.6)
expect("typing on keeps the word, and the panel goes", text() == "It was \(word)s more" && !panelUp(), text())

// 8. the capture shortcut on a selection: the panel asks, and escape adds nothing
clear()
type("zzcapturecheck")
pump(0.4)
press(kVK_ANSI_A, .maskCommand)
pump(0.3)
press(kVK_ANSI_L, [.maskCommand, .maskControl, .maskAlternate])
pump(0.9)
expect("the capture shortcut shows its panel for the selection", panelUp())
press(kVK_Escape)
pump(0.4)
expect("escape closes it, and the text is as it was", !panelUp() && text() == "zzcapturecheck", text())

clear()
print(failures == 0 ? "the offer and the capture shortcut work end to end" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
