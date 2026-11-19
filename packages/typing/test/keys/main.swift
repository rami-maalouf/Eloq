// the gate decides which keys eloq takes (apple/Gate.swift). this drives it with keys as the
// tap would hand them over, with no tap and no events: run with `bun test/keys.ts`.
import AppKit
import Carbon.HIToolbox

var failures = 0
func expect(_ what: String, _ ok: Bool) {
    if !ok {
        failures += 1
        print("FAIL:", what)
    }
}
func key(_ code: Int, _ characters: String = "", _ flags: CGEventFlags = [], repeated: Bool = false) -> Key {
    Key(code: Int64(code), flags: flags, characters: characters, repeated: repeated)
}
func name(_ verdict: Gate.Verdict) -> String {
    switch verdict {
    case .pass: "pass"
    case .swallow: "swallow"
    case .swap(let index, let swap): "swap \(index) -\(swap.deletions) +\(swap.text)"
    case .capture(let taken): "capture \(taken)"
    case .beginCapture: "begin"
    }
}
let two = [Swap(deletions: 11, text: "compelling"), Swap(deletions: 11, text: "vivid")]
let hotkey: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

// with no offer, every key is the other app's
do {
    let gate = Gate()
    expect("tab passes with no offer", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    expect("a digit passes with no offer", name(gate.key(key(kVK_ANSI_2, "2"))) == "pass")
    expect("each key is counted", gate.count == 2)
}
// the offer at a word's end: tab and bare digits swap
do {
    let gate = Gate()
    expect("arms when nothing came since", gate.arm(two, bareDigits: true, since: gate.count))
    expect("tab takes the first", name(gate.key(key(kVK_Tab, "\t"))) == "swap 0 -11 +compelling")
    expect("the offer is used up", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("2 takes the second", name(gate.key(key(kVK_ANSI_2, "2"))) == "swap 1 -11 +vivid")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("3 has no move, and is typed", name(gate.key(key(kVK_ANSI_3, "3"))) == "pass")
    expect("and the offer is gone after it", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("shift-1 types its mark", name(gate.key(key(kVK_ANSI_1, "!", .maskShift))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("shift-tab is the other app's", name(gate.key(key(kVK_Tab, "\t", .maskShift))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("command-tab is the system's", name(gate.key(key(kVK_Tab, "\t", .maskCommand))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("a letter keeps the word", name(gate.key(key(kVK_ANSI_X, "x"))) == "pass")
    expect("and tab after it is a tab", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
}
// after "word ", a number is a number: the digits need option
do {
    let gate = Gate()
    _ = gate.arm(two, bareDigits: false, since: gate.count)
    expect("a bare 2 is typed", name(gate.key(key(kVK_ANSI_2, "2"))) == "pass")
    _ = gate.arm(two, bareDigits: false, since: gate.count)
    expect("option-2 takes the second", name(gate.key(key(kVK_ANSI_2, "\u{2122}", .maskAlternate))) == "swap 1 -11 +vivid")
    _ = gate.arm(two, bareDigits: false, since: gate.count)
    expect("tab still takes the first", name(gate.key(key(kVK_Tab, "\t"))) == "swap 0 -11 +compelling")
}
// a layout where the number row types letters (azerty): the key of "2" types "é"
do {
    let gate = Gate()
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("é is typed, not taken as a digit", name(gate.key(key(kVK_ANSI_2, "é"))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    expect("shift gives the digit there, and it swaps", name(gate.key(key(kVK_ANSI_2, "2", .maskShift))) == "swap 1 -11 +vivid")
    expect("a layout with no digit row falls back to the ansi row", Layout.digits(["19": "é"].reduce(into: [:]) { $0[Int64($1.key)!] = $1.value }) == Layout.ansiDigits)
    expect("a us layout maps its own row", Layout.digits([18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9"]) == Layout.ansiDigits)
    expect("the key for c is found on the layout", Layout.code(for: "c", in: [8: "c", 34: "i"]) == 8 && Layout.code(for: "c", in: [34: "c"]) == 34)
}
// a reading that began before a key or a click must not arm
do {
    let gate = Gate()
    let before = gate.count
    _ = gate.key(key(kVK_ANSI_A, "a"))
    expect("a key came: no arming", !gate.arm(two, bareDigits: true, since: before))
    expect("so tab is a tab", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    let then = gate.count
    _ = gate.pointer(scroll: false)
    expect("a click came: no arming", !gate.arm(two, bareDigits: true, since: then))
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    _ = gate.pointer(scroll: false)
    expect("a click disarms", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    gate.touch()
    expect("the main thread disarms", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    expect("the first scroll is reported", gate.pointer(scroll: true))
    expect("the next, a moment later, is not", !gate.pointer(scroll: true))
}
// a key eloq took is eloq's while it is held
do {
    let gate = Gate()
    _ = gate.arm(two, bareDigits: true, since: gate.count)
    _ = gate.key(key(kVK_Tab, "\t"))
    expect("the held tab does not type tabs", name(gate.key(key(kVK_Tab, "\t", repeated: true))) == "swallow")
    expect("a new press of tab is a tab", name(gate.key(key(kVK_Tab, "\t"))) == "pass")
    expect("a held letter repeats as always", name(gate.key(key(kVK_ANSI_A, "a", repeated: true))) == "pass")
}
// the capture shortcut and its panel
do {
    let gate = Gate()
    expect("the shortcut begins a capture", name(gate.key(key(kVK_ANSI_L, "l", hotkey))) == "begin")
    expect("held, it begins one only", name(gate.key(key(kVK_ANSI_L, "l", hotkey, repeated: true))) == "swallow")
    expect("with shift it is another shortcut", name(gate.key(key(kVK_ANSI_L, "l", hotkey.union(.maskShift)))) == "pass")
    gate.setCapture(.choose)
    expect("o saves as overused", name(gate.key(key(kVK_ANSI_O, "o"))) == "capture overused")
    expect("held, o types nothing", name(gate.key(key(kVK_ANSI_O, "o", repeated: true))) == "swallow")
    expect("after the choice, t is the other app's", name(gate.key(key(kVK_ANSI_T, "t"))) == "pass")
    gate.setCapture(.choose)
    expect("capital t saves as a target", name(gate.key(key(kVK_ANSI_T, "T", .maskShift))) == "capture target")
    gate.setCapture(.choose)
    expect("on another layout the letter counts, not the key", name(gate.key(key(kVK_ANSI_S, "o"))) == "capture overused")
    gate.setCapture(.choose)
    expect("return opens the word", name(gate.key(key(kVK_Return, "\r"))) == "capture open")
    gate.setCapture(.choose)
    expect("escape cancels", name(gate.key(key(kVK_Escape, "\u{1B}"))) == "capture escape")
    gate.setCapture(.choose)
    expect("another key is typed", name(gate.key(key(kVK_ANSI_X, "x"))) == "pass")
    expect("and ends the panel: o is typed after it", name(gate.key(key(kVK_ANSI_O, "o"))) == "pass")
    gate.setCapture(.look)
    expect("a known word takes no o", name(gate.key(key(kVK_ANSI_O, "o"))) == "pass")
    gate.setCapture(.look)
    expect("a known word opens with return", name(gate.key(key(kVK_Return, "\r"))) == "capture open")
    gate.setCapture(.notice)
    expect("a notice takes no return", name(gate.key(key(kVK_Return, "\r"))) == "pass")
    gate.setCapture(.choose)
    expect("command-o is the other app's", name(gate.key(key(kVK_ANSI_O, "o", .maskCommand))) == "pass")
}
// the case of the replacement
do {
    expect("a sentence's first word", Swap.cased("compelling", like: "Interesting") == "Compelling")
    expect("a word in a sentence", Swap.cased("compelling", like: "interesting") == "compelling")
    expect("i is not a sentence's start", Swap.cased("my sense is", like: "I think") == "my sense is")
    expect("nor is i'm", Swap.cased("my sense is", like: "I’m thinking") == "my sense is")
    expect("all capitals", Swap.cased("extremely", like: "VERY") == "EXTREMELY")
    expect("a name's capitals are not a sentence", Swap.cased("phone", like: "iPhone") == "phone")
    expect("a phrase", Swap.cased("numerous", like: "A bunch of") == "Numerous")
}
// which underlines a key leaves on the screen: all but the cursor's own line from the cursor on
do {
    func line(_ x: CGFloat, _ y: CGFloat) -> Underline { Underline(rect: NSRect(x: x, y: y, width: 40, height: 16), kind: .overused) }
    // appkit coordinates: a larger y is higher on the screen. the cursor is on the line at y 80.
    let lines = [line(10, 100), line(300, 100), line(10, 80), line(200, 80), line(10, 60), line(300, 40)]
    let caret = NSRect(x: 120, y: 80, width: 0, height: 16)
    expect("typing keeps every line but the cursor's own from the cursor on", UnderlineReader.keptWhenTyping(lines, caret: caret, deleting: false) == [0, 1, 2, 4, 5])
    expect("a delete takes the whole of the cursor's line", UnderlineReader.keptWhenTyping(lines, caret: caret, deleting: true) == [0, 1, 4, 5])
    expect("a line that ends at the cursor stays when typing", UnderlineReader.keptWhenTyping([line(80, 80)], caret: caret, deleting: false) == [0])
    expect("a word the cursor is inside goes", UnderlineReader.keptWhenTyping([line(100, 80)], caret: caret, deleting: false) == [])
    var pass = UnderlinePass(frame: .zero, lines: lines)
    pass.caret = caret
    let fewer = pass.keeping([0, 4])
    expect("a pass with fewer lines keeps its frame and its cursor", fewer.lines == [lines[0], lines[4]] && fewer.caret == caret && fewer != pass)
}
print(failures == 0 ? "the gate takes and passes every key as written, and typing keeps the lines it cannot move" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
