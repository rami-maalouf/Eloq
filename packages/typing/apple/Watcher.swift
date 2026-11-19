// the key tap of the app, and what it drives: the offer at the cursor, the capture shortcut,
// and the nudges that keep the underlines true.
//
// the offer follows the cursor. after a key or a click rests, the watcher reads the few words
// before the cursor of the focused field; an overused word that ends there, typed a moment ago
// or written long before, shows its targets. tab takes the first; a digit picks another (with
// option once a space follows the word, so a number you type stays a number); any other key
// keeps the word.
//
// - the taps run on a thread of their own and answer from the gate (Gate.swift), so no key of
//   the mac waits for another app or for eloq's main thread. everything else here is the main
//   thread, which hears of each key after it has gone on; accessibility is read on `queue`.
// - a reading may arm the gate only if no key or click came since it began, so tab never acts
//   on an offer that the text has moved away from.
// - a swap deletes the word and types the replacement as key events, which every text field
//   takes; the taps let eloq's own events through.
// - the last words typed are kept in memory for ten seconds at most, to count the overused
//   words you type; text is never stored or sent. password fields and secure input are skipped.
// - an app that gives no text to accessibility gets the offer the older way: from the keys
//   typed, when a space or a punctuation mark ends the word.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// a target to use instead of an overused word
struct Move {
    let id: String
    let text: String
    let useWhen: String
}

/// the overused word at the cursor and what to use instead
struct Offer {
    let term: String
    /// the word as written, which a swap deletes
    let typed: String
    /// what is between the word and the cursor (nothing, a space, a full stop and a space), which a swap types again
    let boundary: String
    let moves: [Move]
    let app: String
}

final class Watcher {
    static let shared = Watcher()
    /// marks the key events eloq posts, so the taps let them through untouched
    static let ownEvents: Int64 = 0x454c_4f51 // "ELOQ"

    /// an overused word seen, swapped or kept: `{kind, term, replacement, app}`
    var onMove: (([String: Any]) -> Void)?
    /// a word to add, or to open in eloq: `{kind, text, overused, target, app}`
    var onCapture: (([String: Any]) -> Void)?
    /// the taps started or stopped
    var onStatus: (() -> Void)?

    fileprivate let gate = Gate()
    private var table = TypingLookup(forms: [:], maxWords: 0)
    private var moves: [String: [Move]] = [:]
    private var scan = TextScan()
    private var running = false
    private var trustTimer: Timer?
    private var keys: [Int64: String] = [:]
    private let queue = DispatchQueue(label: "studio.orbitlabs.eloq.caret", qos: .userInteractive)

    /// the last words typed, for the count and for apps that give no text
    private var typed = ""
    private var lastKey = Date.distantPast
    /// the offer the panel shows and the gate is armed with
    private var offer: Offer?
    /// a word typed and counted, until the next key says whether it was kept
    private var counted: Offer?
    private var look = 0
    private var reading = false
    private var readAgain: (fallback: Offer?, attempt: Int)?
    private let panel = OfferPanel()

    private var capture: Capture?
    private var captureSerial = 0
    private var copying = false
    private let capturePanel = CapturePanel()

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.reset()
        }
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.readLayout()
        }
        Underlines.shared.appMoved = { [weak self] in
            // the focus or the window moved with no key or click of the person's
            self?.dismissOffer()
            self?.lookAtCursor(after: 0.25)
        }
    }

    // MARK: the module's calls

    func status() -> [String: Any] {
        ["available": true, "trusted": AXIsProcessTrusted(), "running": running, "words": Double(moves.count),
         "underlines": Underlines.shared.enabled]
    }

    /// the export's typing table: `{maxWords, forms, moves, targets}`
    func load(_ json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        table = TypingLookup(forms: (object["forms"] as? [String: [String]]) ?? [:],
                             maxWords: (object["maxWords"] as? Int) ?? (object["maxWords"] as? Double).map(Int.init) ?? 0)
        var next: [String: [Move]] = [:]
        for (term, list) in (object["moves"] as? [String: [[String: Any]]]) ?? [:] {
            next[term] = list.compactMap { m in
                guard let id = m["id"] as? String, let text = m["text"] as? String else { return nil }
                return Move(id: id, text: text, useWhen: m["useWhen"] as? String ?? "")
            }
        }
        moves = next
        let targets = (object["targets"] as? [String: Any])?["forms"] as? [String: [String]] ?? [:]
        scan = TextScan(overused: Array(table.forms.keys), targets: Array(targets.keys))
        // an offer on screen is of the old library
        dismissOffer()
        Underlines.shared.load(scan)
    }

    /// start the taps once the accessibility permission is there, and stop them when it is taken
    /// away: looked at every three seconds, so neither needs a relaunch
    func watchTrust() {
        start()
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.running, !AXIsProcessTrusted() { self.stop() } else if !self.running { self.start() }
        }
    }

    func start() {
        guard !running, AXIsProcessTrusted() else { return }
        AX.bePatient()
        let keyMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let pointerMask = CGEventMask((1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.scrollWheel.rawValue))
        guard let keyTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                             eventsOfInterest: keyMask, callback: keyTapped, userInfo: nil) else { return }
        // clicks and scrolls are only heard, so they never wait for eloq at all
        guard let pointerTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                                 eventsOfInterest: pointerMask, callback: pointerTapped, userInfo: nil) else {
            CFMachPortInvalidate(keyTap)
            return
        }
        readLayout()
        gate.open([keyTap, pointerTap])
        let thread = Thread { [gate] in
            guard let loop = CFRunLoopGetCurrent() else { return }
            for port in [keyTap, pointerTap] {
                CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
                CGEvent.tapEnable(tap: port, enable: true)
            }
            gate.running(on: loop)
            CFRunLoopRun()
        }
        thread.name = "eloq key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        running = true
        Underlines.shared.start()
        onStatus?()
    }

    private func stop() {
        guard running else { return }
        running = false
        gate.close()
        reset()
        Underlines.shared.hide()
        onStatus?()
    }

    private func readLayout() {
        keys = Layout.table()
        gate.setDigits(Layout.digits(keys))
    }

    // MARK: what the taps report (main thread, after the event has gone on)

    /// a key that was the other app's
    fileprivate func heard(_ key: Key) {
        if capture != nil { endCapture() }
        // any key but a swap keeps the word that was typed and counted
        keep()
        let now = Date()
        if now.timeIntervalSince(lastKey) > 10 { typed = "" }
        lastKey = now
        let chord = !key.flags.intersection([.maskCommand, .maskControl]).isEmpty
        let option = key.flags.contains(.maskAlternate)
        switch Int(key.code) {
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            // an arrow moves the cursor and seldom the text: look again, and leave the lines until then
            Underlines.shared.changed(after: 0.1)
            typed = ""
            hideOffer()
            lookAtCursor(after: 0.2)
            return
        case kVK_Escape:
            typed = ""
            dismissOffer()
            return
        default:
            break
        }
        let jumps = [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown].contains(Int(key.code))
        if chord || jumps {
            // a shortcut or a jump: the words before the cursor are unknown now. undo, cut and paste change the text.
            if jumps || ["z", "x", "v"].contains(keys[key.code] ?? "") { Underlines.shared.moved(restAfter: 0.3) }
            typed = ""
            hideOffer()
            lookAtCursor(after: 0.3)
            return
        }
        switch Int(key.code) {
        case kVK_Delete, kVK_ForwardDelete:
            Underlines.shared.typed(deleting: true)
            // option deletes a whole word, and forward delete what is after the cursor
            if option || Int(key.code) == kVK_ForwardDelete { typed = "" } else if !typed.isEmpty { typed.removeLast() }
            hideOffer()
            lookAtCursor(after: 0.22)
            return
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab:
            Underlines.shared.typed(deleting: false)
            // the word is done and counted; the cursor has gone to a new line or another field
            if let last = typed.last, TypingLookup.isWordChar(last), !sealed() { _ = count(boundary: "") }
            typed = ""
            hideOffer()
            lookAtCursor(after: 0.3)
            return
        default:
            break
        }
        Underlines.shared.typed(deleting: false)
        guard !key.characters.isEmpty else {
            // a dead key or a function key: nothing typed yet, and the offer no longer holds
            hideOffer()
            lookAtCursor(after: 0.3)
            return
        }
        if sealed() {
            typed = ""
            dismissOffer()
            return
        }
        var fallback: Offer?
        for ch in key.characters {
            if TypingLookup.isBoundary(ch), let last = typed.last, TypingLookup.isWordChar(last) {
                let seen = count(boundary: String(ch))
                // only what a swap can type again may stand after the word
                if TypingLookup.separators.contains(ch) { fallback = seen ?? fallback }
            }
            typed.append(ch)
        }
        if typed.count > 80 { typed = String(typed.suffix(60)) }
        // a space or a full stop after the word leaves the panel in place; a letter makes a new word
        if key.characters.allSatisfy(TypingLookup.separators.contains) { offer = nil } else { hideOffer() }
        lookAtCursor(after: fallback == nil ? 0.22 : 0.05, fallback: fallback)
    }

    /// a click began: the cursor is going somewhere else
    fileprivate func pressed() {
        reset()
    }

    /// a click ended: the cursor or the focus has moved; a drag may have moved the window
    fileprivate func clicked() {
        Underlines.shared.changed(after: 0.12)
        lookAtCursor(after: 0.15)
    }

    /// the text moves under the panel
    fileprivate func scrolled() {
        Underlines.shared.moved(restAfter: 0.22)
        hideOffer()
    }

    /// tab or a digit swapped the word; the tap has posted the keys already
    fileprivate func swapped(_ index: Int) {
        guard let offer, index < offer.moves.count else {
            hideOffer()
            return
        }
        let move = offer.moves[index]
        hideOffer()
        // typed a moment ago with no separator yet, so not counted: it was typed, then swapped
        if counted == nil, typed.hasSuffix(offer.typed + offer.boundary) { emit("overused_seen", offer, replacement: "") }
        counted = nil
        typed = Swap.cased(move.text, like: offer.typed) + offer.boundary
        emit("swapped", offer, replacement: move.id)
        Underlines.shared.moved(restAfter: 0.3)
    }

    func reset() {
        typed = ""
        keep()
        dismissOffer()
        endCapture()
    }

    /// password entry and eloq's own windows: nothing is kept and nothing is offered
    private func sealed() -> Bool {
        IsSecureEventInputEnabled() || NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private func emit(_ kind: String, _ offer: Offer, replacement: String) {
        onMove?(["kind": kind, "term": offer.term, "replacement": replacement, "app": offer.app])
    }

    /// the word that was counted was kept: the person went on
    private func keep() {
        guard let kept = counted else { return }
        counted = nil
        emit("kept", kept, replacement: "")
    }

    // MARK: the offer

    /// the offer for a word the table found, when the library has targets for it
    private func offer(for hit: TypingLookup.Hit, boundary: String, app: String) -> Offer? {
        guard let term = hit.termIds.first(where: { !(moves[$0] ?? []).isEmpty }), let list = moves[term] else { return nil }
        return Offer(term: term, typed: hit.text, boundary: boundary, moves: Array(list.prefix(9)), app: app)
    }

    /// an overused word was typed to its end: count it, and answer the offer for an app that
    /// gives no text
    private func count(boundary: String) -> Offer? {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard let hit = table.lookup(typed), let seen = offer(for: hit, boundary: boundary, app: app) else { return nil }
        counted = seen
        emit("overused_seen", seen, replacement: "")
        return seen
    }

    /// the panel goes away, and tab and the digits are the other app's again
    private func hideOffer() {
        gate.disarm()
        offer = nil
        panel.orderOut(nil)
    }

    /// the same, and a reading on its way is dropped
    private func dismissOffer() {
        gate.touch()
        look += 1
        hideOffer()
    }

    /// read the words before the cursor once the keys rest, and show the offer or put it away.
    /// `fallback` is the offer from the keys typed, for an app that gives no text.
    func lookAtCursor(after delay: TimeInterval, fallback: Offer? = nil, attempt: Int = 0) {
        guard running else { return }
        look += 1
        let asked = look
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, asked == self.look else { return }
            self.readCursor(fallback, attempt)
        }
    }

    private func readCursor(_ fallback: Offer?, _ attempt: Int) {
        guard !moves.isEmpty, capture == nil, !sealed() else {
            hideOffer()
            return
        }
        // one reading at a time: an app that answers slowly gets the latest question next, and no line of them
        guard !reading else {
            readAgain = (fallback, attempt)
            return
        }
        reading = true
        let since = gate.count
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let tail = String(typed.suffix(6))
        queue.async { [weak self] in
            var found = CaretReading.unknown
            if let element = AX.focused() {
                switch AX.field(element) {
                case .open: found = CaretReader.read(element)
                case .closed: found = .nothing
                case .none: found = .unknown
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if let again = self.readAgain {
                    self.readAgain = nil
                    self.lookAtCursor(after: 0, fallback: again.fallback, attempt: again.attempt)
                    return
                }
                // a key or a click came since: its own look is on the way
                guard since == self.gate.count else { return }
                switch found {
                case .unknown:
                    if let fallback { self.show(fallback, at: self.mouseAnchor(), since: since) } else { self.hideOffer() }
                case .nothing:
                    self.hideOffer()
                case .text(let before, let box):
                    // the app has not drawn the last keys yet: ask once more, then believe the field
                    if attempt == 0, !tail.isEmpty, !before.hasSuffix(tail) {
                        self.lookAtCursor(after: 0.25, fallback: fallback, attempt: 1)
                        return
                    }
                    guard let (hit, trailing) = self.table.atCursor(before), let next = self.offer(for: hit, boundary: trailing, app: app) else {
                        self.hideOffer()
                        return
                    }
                    let caret = box.map { AX.appKit($0, primaryHeight: primaryHeight) }.map { NSRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }
                    self.show(next, at: caret ?? self.mouseAnchor(), since: since)
                }
            }
        }
    }

    private func show(_ next: Offer, at caret: NSRect, since: UInt64) {
        let deletions = next.typed.count + next.boundary.count
        let swaps = next.moves.map { Swap(deletions: deletions, text: Swap.cased($0.text, like: next.typed) + next.boundary) }
        // a number typed after "word " is a number: there the digits need option
        guard gate.arm(swaps, bareDigits: next.boundary.isEmpty, since: since) else { return }
        offer = next
        panel.show(next, at: caret)
    }

    private func mouseAnchor(lift: CGFloat = 0) -> NSRect {
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - lift, width: 1, height: 18)
    }

    // MARK: capture

    private func sendCapture(_ kind: String, _ capture: Capture, overused: Bool = false, target: Bool = false) {
        onCapture?(["kind": kind, "text": capture.text, "overused": overused, "target": target, "app": capture.app])
    }

    private func endCapture() {
        // a reading or a copy on its way is dropped too
        captureSerial += 1
        guard capture != nil else { return }
        capture = nil
        gate.setCapture(.none)
        capturePanel.orderOut(nil)
    }

    private func showCapture(_ next: Capture, at anchor: NSRect, closeAfter delay: TimeInterval? = nil) {
        capture = next
        captureSerial += 1
        switch next.state {
        case .new: gate.setCapture(.choose)
        case .overused, .target: gate.setCapture(.look)
        case .tooLong, .saved: gate.setCapture(.notice)
        }
        capturePanel.show(next, at: anchor)
        guard let delay else { return }
        let serial = captureSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, serial == self.captureSerial else { return }
            self.endCapture()
        }
    }

    /// the shortcut: read the selection of the front app and show what eloq knows of it
    fileprivate func beginCapture() {
        endCapture()
        dismissOffer()
        guard !IsSecureEventInputEnabled() else { return }
        let serial = captureSerial
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mouse = mouseAnchor(lift: 4)
        queue.async { [weak self] in
            let element = AX.focused()
            let field = element.map(AX.field) ?? .none
            // nil: the app does not say what is selected. "": it says nothing is.
            let selected = field == .closed ? "" : element.flatMap { AX.attribute($0, kAXSelectedTextAttribute) as? String }
            let box = element.flatMap(AX.selectionBox)
            DispatchQueue.main.async {
                guard let self, serial == self.captureSerial else { return }
                let anchor = box.map { AX.appKit($0, primaryHeight: primaryHeight) }.map { NSRect(x: $0.minX, y: $0.minY, width: max($0.width, 1), height: $0.height) } ?? mouse
                if let selected {
                    self.present(selected, app: app, at: anchor)
                } else if !self.copying {
                    // an app that keeps its selection to itself is asked with a copy
                    self.copying = true
                    SelectionReader.copied(mark: Watcher.ownEvents, key: Layout.code(for: "c", in: self.keys) ?? CGKeyCode(kVK_ANSI_C)) { [weak self] text in
                        guard let self else { return }
                        self.copying = false
                        guard serial == self.captureSerial else { return }
                        self.present(text ?? "", app: app, at: anchor)
                    }
                }
            }
        }
    }

    /// what the library already says of a cleaned selection
    private func known(_ text: String) -> Capture.State {
        guard SelectionReader.fits(text) else { return .tooLong }
        if let hit = table.lookup(text), TypingLookup.normalize(hit.text) == TypingLookup.normalize(text) {
            return .overused(moves: hit.termIds.flatMap { moves[$0] ?? [] }.map(\.text))
        }
        return scan.kind(of: text) == .target ? .target : .new
    }

    /// a selection from the shortcut: the panel asks what it is
    private func present(_ raw: String, app: String, at anchor: NSRect) {
        let text = SelectionReader.clean(raw)
        guard !text.isEmpty else {
            // nothing is selected: the add sheet in eloq, ready for typing
            sendCapture("open", Capture(text: "", app: app, state: .new))
            return
        }
        let state = known(text)
        showCapture(Capture(text: text, app: app, state: state), at: anchor, closeAfter: state == .tooLong ? 1.6 : nil)
    }

    /// a selection from the services menu, which has said what it is: saved with no question
    func save(_ raw: String, overused: Bool, app: String) {
        let text = SelectionReader.clean(raw)
        guard !text.isEmpty else { return }
        let anchor = mouseAnchor(lift: 4)
        let state = known(text)
        guard state == .new else {
            // too long, or already in the library: say which, and add nothing
            showCapture(Capture(text: text, app: app, state: state), at: anchor, closeAfter: 2.2)
            return
        }
        saved(Capture(text: text, app: app, state: .new), overused: overused, at: anchor)
    }

    private func saved(_ capture: Capture, overused: Bool, at anchor: NSRect? = nil) {
        sendCapture("add", capture, overused: overused, target: !overused)
        var done = capture
        done.state = .saved(overused: overused)
        // with no new place, the panel keeps its top left corner
        let frame = capturePanel.frame
        showCapture(done, at: anchor ?? NSRect(x: frame.minX + 14, y: frame.maxY + 6, width: 1, height: 1), closeAfter: 1.1)
    }

    /// a key the capture panel took
    fileprivate func captured(_ key: Gate.CaptureKey) {
        guard let capture else { return }
        switch key {
        case .escape:
            endCapture()
        case .overused:
            saved(capture, overused: true)
        case .target:
            saved(capture, overused: false)
        case .open:
            sendCapture("open", capture)
            endCapture()
        }
    }
}

// MARK: the taps (their own thread)

private func characters(_ event: CGEvent) -> String {
    var length = 0
    var buffer = [UniChar](repeating: 0, count: 8)
    event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
    return length > 0 ? String(utf16CodeUnits: buffer, count: length) : ""
}

private func keyTapped(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let watcher = Watcher.shared
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        watcher.gate.reenable()
        return pass
    }
    guard type == .keyDown, event.getIntegerValueField(.eventSourceUserData) != Watcher.ownEvents else { return pass }
    let key = Key(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags, characters: characters(event),
                  repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    switch watcher.gate.key(key) {
    case .pass:
        DispatchQueue.main.async { watcher.heard(key) }
        return pass
    case .swallow:
        return nil
    case .swap(let index, let swap):
        // posted here, on the tap's thread, so the swap's keys go out before the person's next key
        for posted in swap.events(mark: Watcher.ownEvents) { posted.post(tap: .cgSessionEventTap) }
        DispatchQueue.main.async { watcher.swapped(index) }
        return nil
    case .capture(let taken):
        DispatchQueue.main.async { watcher.captured(taken) }
        return nil
    case .beginCapture:
        DispatchQueue.main.async { watcher.beginCapture() }
        return nil
    }
}

private func pointerTapped(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let watcher = Watcher.shared
    let pass = Unmanaged.passUnretained(event)
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        watcher.gate.reenable()
    case .scrollWheel:
        if watcher.gate.pointer(scroll: true) { DispatchQueue.main.async { watcher.scrolled() } }
    case .leftMouseDown, .rightMouseDown:
        _ = watcher.gate.pointer(scroll: false)
        DispatchQueue.main.async { watcher.pressed() }
    case .leftMouseUp:
        DispatchQueue.main.async { watcher.clicked() }
    default:
        break
    }
    return pass
}
