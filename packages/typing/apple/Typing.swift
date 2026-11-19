// @eloq/typing on macos: as you type in any app, an overused word from your library shows the
// words you want to use instead, in a small panel at the text cursor. tab takes the first,
// 1-9 picks one, any other key keeps what you typed.
//
// - one key tap per process (a cgevent tap, which needs accessibility permission). it keeps
//   only the last few words typed, in memory, and never stores or sends text.
// - the lookup ports packages/matcher/src/typing.ts exactly (the table is the matcher's
//   `tableForTyping` plus the accepted moves), so the app, the mcp server and this agree.
// - password fields, secure input and eloq's own windows are skipped.
// - a swap deletes the word and types the replacement as key events, which every text field
//   takes; the tap ignores its own events.
// - the same tap serves the underlines (Underlines.swift), which it tells when the text moves,
//   and the capture shortcut (Capture.swift), control-option-command-l.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ExactPackage
import Foundation

public final class TypingModule: ExactPackage {
    private let context: ExactPackageContext

    public init(context: ExactPackageContext) {
        self.context = context
        Watcher.shared.listeners.append { [weak self] move in
            self?.context.emit("typingmove", [move])
        }
        Watcher.shared.captures.append { [weak self] capture in
            self?.context.emit("typingcapture", [capture])
        }
        DispatchQueue.main.async { Services.install() }
    }

    public func later(_ name: String, _ args: [String: Any], preferred: Any?, reply: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async { [self] in
            switch name {
            case "typingStatus":
                reply(Watcher.shared.status())
            case "setTypingTable":
                Watcher.shared.load(args["table"] as? String ?? "")
                Watcher.shared.start()
                context.changed("typing.typingStatus")
                reply(Watcher.shared.status())
            case "setUnderlines":
                Underlines.shared.enabled = args["on"] as? Bool ?? true
                reply(Watcher.shared.status())
            case "openAccessibilitySettings":
                let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
                reply([:])
            default:
                reply(["error": "NotSupportedError"])
            }
        }
    }

    /// trust can be granted while the app is away: start then, and ask the status again
    public func foreground(_ shown: Bool) {
        guard shown else { return }
        Watcher.shared.start()
        context.changed("typing.typingStatus")
    }
}

/// a target to use instead of an overused word
private struct Move {
    let id: String
    let text: String
    let useWhen: String
}

/// what the panel is offering right now
private struct Offer {
    let term: String
    let typed: String       // the word as typed, which a swap deletes
    let boundary: String    // the character that ended it, which a swap types again
    let moves: [Move]
    let app: String
}

private final class Watcher {
    static let shared = Watcher()
    var listeners: [([String: Any]) -> Void] = []
    /// a word to add, or to open in eloq: `{kind, text, overused, target, app}`
    var captures: [([String: Any]) -> Void] = []

    private var table = TypingLookup(forms: [:], maxWords: 0)
    private var moves: [String: [Move]] = [:]
    private var tap: CFMachPort?
    private var typed = ""
    private var offer: Offer?
    private let panel = OfferPanel()
    private var scan = TextScan()
    private var capture: Capture?
    private var captureSerial = 0
    private let capturePanel = CapturePanel()
    // marks the key events a swap posts, so the tap lets them through untouched
    fileprivate static let ownEvents: Int64 = 0x454c_4f51 // "ELOQ"

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.reset()
        }
    }

    func status() -> [String: Any] {
        ["available": true, "trusted": AXIsProcessTrusted(), "running": tap != nil, "words": Double(moves.count),
         "underlines": Underlines.shared.enabled]
    }

    /// the export's typing table: `{maxWords, forms, moves}`
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
        Underlines.shared.load(scan)
    }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        Underlines.shared.start()
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: tapped, userInfo: nil) else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func reset() {
        typed = ""
        dismiss(kept: false)
        endCapture()
    }

    private func dismiss(kept: Bool) {
        if let offer, kept { emit("kept", offer, replacement: "") }
        offer = nil
        panel.orderOut(nil)
    }

    private func emit(_ kind: String, _ offer: Offer, replacement: String) {
        let move: [String: Any] = ["kind": kind, "term": offer.term, "replacement": replacement, "app": offer.app]
        for listener in listeners { listener(move) }
    }

    /// a key or a click; nil swallows it (a swap's tab or digit)
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        if type == .scrollWheel {
            Underlines.shared.moved(restAfter: 0.22)
            return event
        }
        if type == .leftMouseUp {
            // a click moves the cursor or the focus; a drag may have moved the window
            Underlines.shared.changed(after: 0.12)
            return event
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            reset()
            return event
        }
        if event.getIntegerValueField(.eventSourceUserData) == Watcher.ownEvents { return event }
        let flags = event.flags
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if code == Int64(kVK_ANSI_L), flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == [.maskCommand, .maskControl, .maskAlternate] {
            dismiss(kept: false)
            beginCapture()
            return nil
        }
        if let capture, takeCaptureKey(code, flags, capture) { return nil }
        if [123, 124, 125, 126].contains(code) {
            // an arrow moves the cursor and seldom the text: look again, and leave the lines until then
            Underlines.shared.changed(after: 0.1)
        } else if flags.intersection([.maskCommand, .maskControl]).isEmpty || [6, 7, 9].contains(code) {
            // a key that types, deletes or pages moves the text, as do undo, cut and paste
            Underlines.shared.moved(restAfter: 0.3)
        }

        if let offer {
            if code == 48, !flags.contains(.maskCommand) { // tab
                swap(offer, to: offer.moves[0])
                return nil
            }
            if let digit = digitIndex(code), digit < offer.moves.count, flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
                swap(offer, to: offer.moves[digit])
                return nil
            }
            dismiss(kept: true)
        }

        // shortcuts, arrows and other navigation move the cursor: the words before it are unknown
        if !flags.intersection([.maskCommand, .maskControl]).isEmpty || [123, 124, 125, 126, 115, 116, 119, 121, 53].contains(code) {
            reset()
            return event
        }
        if code == 51 { // delete
            if !typed.isEmpty { typed.removeLast() }
            return event
        }
        guard let chars = characters(event), !chars.isEmpty else { return event }
        if skipped() {
            typed = ""
            return event
        }
        for ch in chars {
            if TypingLookup.isBoundary(ch), let last = typed.last, TypingLookup.isWordChar(last) {
                check(boundary: String(ch))
            }
            typed.append(ch)
        }
        if typed.count > 400 { typed = String(typed.suffix(200)) }
        return event
    }

    private func check(boundary: String) {
        guard let hit = table.lookup(typed), let term = hit.termIds.first(where: { !(moves[$0] ?? []).isEmpty }),
              let list = moves[term] else { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let next = Offer(term: term, typed: hit.text, boundary: boundary, moves: Array(list.prefix(9)), app: app)
        offer = next
        emit("overused_seen", next, replacement: "")
        panel.show(next, at: caretRect())
    }

    private func swap(_ offer: Offer, to move: Move) {
        dismiss(kept: false)
        // the boundary was typed after the word: delete both, then type the target and the boundary
        let deletions = offer.typed.count + offer.boundary.count
        post(deletions: deletions, text: matchCase(move.text, like: offer.typed) + offer.boundary)
        if typed.count >= deletions { typed.removeLast(deletions) }
        typed += matchCase(move.text, like: offer.typed) + offer.boundary
        emit("swapped", offer, replacement: move.id)
    }

    /// "Interesting" becomes "Compelling"; "interesting" stays lowercase
    private func matchCase(_ text: String, like typed: String) -> String {
        guard let first = typed.first, first.isUppercase, let head = text.first else { return text }
        return head.uppercased() + text.dropFirst()
    }

    private func post(deletions: Int, text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        func send(_ event: CGEvent?) {
            guard let event else { return }
            event.setIntegerValueField(.eventSourceUserData, value: Watcher.ownEvents)
            event.post(tap: .cgSessionEventTap)
        }
        for _ in 0..<deletions {
            send(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true))
            send(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false))
        }
        for ch in text.utf16 {
            var unit = ch
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            send(down)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            send(up)
        }
    }

    // MARK: capture

    private func sendCapture(_ kind: String, _ capture: Capture, overused: Bool = false, target: Bool = false) {
        let event: [String: Any] = ["kind": kind, "text": capture.text, "overused": overused, "target": target, "app": capture.app]
        for listener in captures { listener(event) }
    }

    private func endCapture() {
        guard capture != nil else { return }
        capture = nil
        captureSerial += 1
        capturePanel.orderOut(nil)
    }

    /// the shortcut: read the selection of the front app and show what eloq knows of it
    fileprivate func beginCapture() {
        endCapture()
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !IsSecureEventInputEnabled() else { return }
        let element = SelectionReader.focused()
        let anchor = SelectionReader.anchor(of: element)
        if let text = SelectionReader.selection(of: element) {
            present(text, app: app, at: anchor)
            return
        }
        SelectionReader.copied(mark: Watcher.ownEvents) { [weak self] text in
            self?.present(text ?? "", app: app, at: anchor)
        }
    }

    /// a word from the selection, or from the services menu
    fileprivate func present(_ raw: String, app: String, at anchor: NSRect) {
        let text = SelectionReader.clean(raw)
        guard !text.isEmpty else {
            // nothing is selected: the add sheet in eloq, ready for typing
            sendCapture("open", Capture(text: "", app: app, state: .new))
            return
        }
        let state = known(text)
        let next = Capture(text: text, app: app, state: state)
        capture = next
        captureSerial += 1
        capturePanel.show(next, at: anchor)
        if state == .tooLong { closeCapture(after: 1.6) }
    }

    /// what the library already says of a cleaned selection
    private func known(_ text: String) -> Capture.State {
        if TypingLookup.tokenize(text).count > SelectionReader.maxWords || text.count > 80 { return .tooLong }
        if let hit = table.lookup(text), TypingLookup.normalize(hit.text) == TypingLookup.normalize(text) {
            return .overused(moves: hit.termIds.flatMap { moves[$0] ?? [] }.map(\.text))
        }
        return scan.kind(of: text) == .target ? .target : .new
    }

    /// saved without a panel to ask (the services menu's two commands)
    fileprivate func save(_ raw: String, overused: Bool, app: String) {
        let text = SelectionReader.clean(raw)
        let mouse = NSEvent.mouseLocation
        let anchor = NSRect(x: mouse.x, y: mouse.y - 4, width: 1, height: 18)
        guard !text.isEmpty else { return }
        let state = known(text)
        guard state == .new else {
            // too long, or already in the library: say which, and add nothing
            let shown = Capture(text: text, app: app, state: state)
            capture = shown
            captureSerial += 1
            capturePanel.show(shown, at: anchor)
            closeCapture(after: 2.2)
            return
        }
        saved(Capture(text: text, app: app, state: .new), overused: overused, at: anchor)
    }

    private func saved(_ capture: Capture, overused: Bool, at anchor: NSRect? = nil) {
        sendCapture("add", capture, overused: overused, target: !overused)
        var done = capture
        done.state = .saved(overused: overused)
        self.capture = done
        captureSerial += 1
        // with no new place, the panel keeps its top left corner
        let frame = capturePanel.frame
        capturePanel.show(done, at: anchor ?? NSRect(x: frame.minX + 14, y: frame.maxY + 6, width: 1, height: 1))
        closeCapture(after: 1.1)
    }

    private func closeCapture(after delay: TimeInterval) {
        let serial = captureSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, serial == self.captureSerial else { return }
            self.endCapture()
        }
    }

    /// a key while the panel is shown; true takes it from the other app
    private func takeCaptureKey(_ code: Int64, _ flags: CGEventFlags, _ capture: Capture) -> Bool {
        let bare = flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        switch (capture.state, code) {
        case (_, 53) where bare: // escape
            endCapture()
            return true
        case (.new, Int64(kVK_ANSI_O)) where bare:
            saved(capture, overused: true)
            return true
        case (.new, Int64(kVK_ANSI_T)) where bare:
            saved(capture, overused: false)
            return true
        case (.new, 36) where bare, (.overused, 36) where bare, (.target, 36) where bare: // return
            sendCapture("open", capture)
            endCapture()
            return true
        default:
            // any other key is the other app's, and the panel has had its say
            endCapture()
            return false
        }
    }

    // MARK: the system

    private func characters(_ event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return length > 0 ? String(utf16CodeUnits: buffer, count: length) : nil
    }

    private func digitIndex(_ code: Int64) -> Int? {
        // the number row 1..9 (ansi key codes)
        let row: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        return row[code]
    }

    /// password fields, secure input, and eloq itself
    private func skipped() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        guard let element = focusedElement() else { return false }
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (role as? String) == "AXSecureTextField" || (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// the text cursor's rectangle in appkit screen coordinates, else the mouse
    private func caretRect() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let fallback = NSRect(x: mouse.x, y: mouse.y, width: 1, height: 18)
        guard let element = focusedElement() else { return fallback }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue else { return fallback }
        var range = CFRange()
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
        // the character before the cursor has a box when the cursor itself has none
        var probe = CFRange(location: max(range.location - 1, 0), length: range.location > 0 ? 1 : 0)
        guard let probeValue = AXValueCreate(.cfRange, &probe) else { return fallback }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         probeValue, &boundsValue) == .success, let boundsValue else { return fallback }
        var rect = CGRect.zero
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect)
        guard rect.width >= 0, rect.height > 0 else { return fallback }
        // ax uses top-left origin on the primary screen; appkit uses bottom-left
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.maxX, y: primary - rect.maxY, width: 1, height: rect.height)
    }
}

private func tapped(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Watcher.shared.reenable()
        return Unmanaged.passUnretained(event)
    }
    guard let out = Watcher.shared.handle(type, event) else { return nil }
    return Unmanaged.passUnretained(out)
}

/// the panel at the text cursor: never key, never main, on every space
private final class OfferPanel: NSPanel {
    private let stack = NSStackView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    fileprivate func show(_ offer: Offer, at caret: NSRect) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Instead of “\(offer.typed)”")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)
        for (i, move) in offer.moves.enumerated() {
            let key = NSTextField(labelWithString: i == 0 ? "⇥" : "\(i + 1)")
            key.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            key.textColor = .tertiaryLabelColor
            key.alignment = .center
            key.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let word = NSTextField(labelWithString: move.text)
            word.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: i == 0 ? .semibold : .regular)
            let column = NSStackView(views: [word])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 1
            if !move.useWhen.isEmpty {
                let hint = NSTextField(labelWithString: move.useWhen)
                hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                hint.textColor = .secondaryLabelColor
                hint.lineBreakMode = .byTruncatingTail
                hint.preferredMaxLayoutWidth = 260
                column.addArrangedSubview(hint)
            }
            let row = NSStackView(views: [key, column])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        let footer = NSTextField(labelWithString: "Tab or a number swaps · keep typing to keep")
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(footer)

        // measured after layout, so the footer and the longest hint fit inside the rounded edge
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let width = min(max(size.width + 4, 240), 360)
        // below the cursor's line, kept on the cursor's screen
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        var origin = NSPoint(x: caret.minX - 14, y: caret.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
            if origin.y < visible.minY + 4 { origin.y = caret.maxY + 6 }
        }
        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

/// the services menu's two commands, "Add to Eloq as Overused" and "Add to Eloq as Target":
/// the system hands over the selected text of any app that offers services
final class Services: NSObject {
    private static let shared = Services()

    static func install() {
        guard NSApp.servicesProvider == nil else { return }
        NSApp.servicesProvider = shared
        NSUpdateDynamicServices()
    }

    private func take(_ board: NSPasteboard, overused: Bool) {
        guard let text = board.string(forType: .string) else { return }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        DispatchQueue.main.async { Watcher.shared.save(text, overused: overused, app: app) }
    }

    @objc func addOverused(_ board: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        take(board, overused: true)
    }

    @objc func addTarget(_ board: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        take(board, overused: false)
    }
}
