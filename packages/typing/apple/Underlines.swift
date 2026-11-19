// thin lines under your library's words in the text field that has the focus, in any app:
// amber dots under a word you overuse, a green line under a target word you used.
//
// - it reads only the text that is visible in the focused field, through accessibility, and
//   keeps nothing: each pass scans, asks where the matched words are drawn, and forgets.
// - the lines live in a window of eloq's that takes no clicks and never has the focus, so the
//   other app's text, selection and menus behave exactly as before.
// - while you type or scroll the lines are put away, and they return when the text rests,
//   so they never trail behind moving text.
// - password fields, secure input, search fields and eloq's own windows are skipped.
// - electron apps and web views (chromium) draw a rich text field from text nodes, and say where
//   a word is only for one node at a time: there the pass reads the nodes that show.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// one line to draw, in appkit screen coordinates
struct Underline: Equatable {
    let rect: NSRect
    let kind: TextScan.Kind
}

/// what one pass over a text field found
struct UnderlinePass: Equatable {
    /// the field's visible box, which the window covers
    let frame: NSRect
    let lines: [Underline]
}

enum UnderlineReader {
    /// a pass never asks an app for more than this, so a long document costs what a short one does
    static let maxCharacters = 12_000
    static let maxMarks = 160
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }

    private static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    private static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    /// the element's box in accessibility coordinates (the origin is the primary screen's top left)
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// the part of a field that shows: a text view is as tall as its whole text, and the scroll
    /// area and the window around it show a part. `web` says the field is in a web page.
    static func visibleFrame(_ element: AXUIElement, _ field: CGRect) -> (clip: CGRect, web: Bool) {
        var clip = field
        var web = false
        var current = element
        for _ in 0..<24 {
            guard let above = attribute(current, kAXParentAttribute), CFGetTypeID(above) == AXUIElementGetTypeID() else { break }
            let parent = above as! AXUIElement
            let role = attribute(parent, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" { web = true }
            if role == "AXScrollArea" || role == "AXWindow" || role == "AXWebArea", let box = frame(parent) { clip = clip.intersection(box) }
            if role == "AXWindow" { return (clip, web) }
            current = parent
        }
        if let window = attribute(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID(),
           let box = frame(window as! AXUIElement) { clip = clip.intersection(box) }
        return (clip, web)
    }

    /// several attributes of an element in one round trip; nil where the element has none
    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == names.count else { return names.map { _ in nil } }
        return list.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value is NSNull ? nil : value
        }
    }

    /// a web page never costs more than this many elements in a pass
    static let maxNodes = 500
    private static let nodeNames = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute, kAXChildrenAttribute] as [String]

    /// the text nodes of a web rich text field that show, each with its text. chromium clips a
    /// node's box to what shows, so a node that has scrolled away has no height and is passed by,
    /// with everything inside it.
    static func textNodes(_ element: AXUIElement) -> [(node: AXUIElement, text: String)] {
        var found: [(AXUIElement, String)] = []
        var waiting = (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed() as [AXUIElement]
        var visited = 0
        while let node = waiting.popLast(), visited < maxNodes {
            visited += 1
            let values = attributes(node, nodeNames)
            var size = CGSize.zero
            if let extent = values[2], CFGetTypeID(extent) == AXValueGetTypeID() { AXValueGetValue(extent as! AXValue, .cgSize, &size) }
            guard size.height >= 2, size.width >= 2 else { continue }
            if (values[0] as? String) == "AXStaticText" {
                if let text = values[3] as? String, !text.isEmpty { found.append((node, text)) }
            } else if let children = values[4] as? [AXUIElement] {
                waiting.append(contentsOf: children.reversed())
            }
        }
        return found
    }

    /// where the selection, or the cursor, of a field is drawn, in accessibility coordinates. a
    /// native field answers for a character range; a web rich text field answers only for its
    /// text markers. a cursor with no selection has a box with no width.
    static func selectionBox(_ element: AXUIElement) -> CGRect? {
        if let selected = range(attribute(element, kAXSelectedTextRangeAttribute)) {
            // the character before the cursor has a box when the cursor itself has none
            var probe = selected.length > 0 ? selected : CFRange(location: max(selected.location - 1, 0), length: selected.location > 0 ? 1 : 0)
            if let value = AXValueCreate(.cfRange, &probe),
               let box = rect(parameterized(element, kAXBoundsForRangeParameterizedAttribute, value)), box.height > 2, box.height < 200 {
                return selected.length > 0 ? box : CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
            }
        }
        if let markers = attribute(element, "AXSelectedTextMarkerRange"),
           let box = rect(parameterized(element, "AXBoundsForTextMarkerRange", markers)), box.height > 2, box.height < 200 {
            return box
        }
        return nil
    }

    /// the focused element of an app, when it is text a person edits and may be read
    static func focusedText(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        // an app that is busy answers late: give up on this pass and keep the keyboard free
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return isReadableText(element) ? element : nil
    }

    static func isReadableText(_ element: AXUIElement) -> Bool {
        guard let role = attribute(element, kAXRoleAttribute) as? String, textRoles.contains(role) else { return false }
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        return subrole != (kAXSecureTextFieldSubrole as String) && subrole != (kAXSearchFieldSubrole as String)
    }

    /// the visible text of a field and where it starts in the whole text
    static func visibleText(_ element: AXUIElement) -> (text: String, offset: Int)? {
        if var visible = range(attribute(element, kAXVisibleCharacterRangeAttribute)), visible.length > 0 {
            visible.length = min(visible.length, maxCharacters)
            if let value = AXValueCreate(.cfRange, &visible),
               let text = parameterized(element, kAXStringForRangeParameterizedAttribute, value) as? String {
                return (text, visible.location)
            }
        }
        guard let text = attribute(element, kAXValueAttribute) as? String, !text.isEmpty else { return nil }
        return (text.utf16.count > maxCharacters ? String(decoding: Array(text.utf16.prefix(maxCharacters)), as: UTF16.self) : text, 0)
    }

    private static func bounds(_ element: AXUIElement, _ start: Int, _ end: Int) -> CGRect? {
        var range = CFRange(location: start, length: end - start)
        guard let value = AXValueCreate(.cfRange, &range),
              let box = rect(parameterized(element, kAXBoundsForRangeParameterizedAttribute, value)),
              box.width > 0.5, box.height > 2, box.height < 200 else { return nil }
        return box
    }

    /// one pass: scan the field's visible text and find where each matched word is drawn
    static func read(_ element: AXUIElement, with scan: TextScan, primaryHeight: CGFloat) -> UnderlinePass? {
        guard let whole = frame(element) else { return nil }
        let (field, web) = visibleFrame(element, whole)
        guard !field.isNull, field.width > 8, field.height > 8 else { return nil }
        var lines: [Underline] = []
        var marked = 0
        // a box partly outside the field is text that has scrolled under its edge
        let inside = field.insetBy(dx: -1, dy: -1)
        func add(_ box: CGRect, _ kind: TextScan.Kind) {
            guard inside.contains(box) else { return }
            lines.append(Underline(rect: NSRect(x: box.minX, y: primaryHeight - box.maxY, width: box.width, height: box.height), kind: kind))
        }
        /// the marks of one text, which `holder` knows the boxes of, `offset` into its own text
        func mark(_ holder: AXUIElement, _ text: String, _ offset: Int) {
            for mark in scan.scan(text) {
                guard marked < maxMarks else { return }
                marked += 1
                guard let all = bounds(holder, offset + mark.start, offset + mark.end) else { continue }
                guard mark.words.count > 1, let first = mark.words.first,
                      let head = bounds(holder, offset + first.lowerBound, offset + first.upperBound), all.height > head.height * 1.5 else {
                    add(all, mark.kind)
                    continue
                }
                // the phrase wraps: one line under each of its words
                add(head, mark.kind)
                for word in mark.words.dropFirst() {
                    if let box = bounds(holder, offset + word.lowerBound, offset + word.upperBound) { add(box, mark.kind) }
                }
            }
        }
        if web {
            for (node, text) in textNodes(element) { mark(node, text, 0) }
        }
        // a native field, a web field with no nodes (a plain textarea), or nodes that gave no boxes
        if lines.isEmpty {
            marked = 0
            guard let (text, offset) = visibleText(element) else { return nil }
            mark(element, text, offset)
        }
        return UnderlinePass(frame: NSRect(x: field.minX, y: primaryHeight - field.maxY, width: field.width, height: field.height), lines: lines)
    }
}

/// the lines, drawn in the window's own coordinates
final class UnderlineView: NSView {
    var lines: [Underline] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        for line in lines {
            let local = window.convertFromScreen(line.rect)
            // on the glyph box's lower edge, under the descenders, on a whole pixel so the line stays crisp
            let y = local.minY.rounded() + 0.5
            let path = NSBezierPath()
            path.lineWidth = 1
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: local.minX + 0.5, y: y))
            path.line(to: NSPoint(x: local.maxX - 0.5, y: y))
            switch line.kind {
            case .overused:
                path.setLineDash([1, 3], count: 2, phase: 0)
                NSColor.systemOrange.withAlphaComponent(dark ? 0.7 : 0.8).setStroke()
            case .target:
                NSColor.systemGreen.withAlphaComponent(dark ? 0.42 : 0.5).setStroke()
            }
            path.stroke()
        }
    }
}

/// the window the lines live in: over the field, through to the mouse, never key
final class UnderlineWindow: NSPanel {
    let lines = UnderlineView()

    init() {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        setAccessibilityElement(false)
        contentView = lines
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Underlines {
    static let shared = Underlines()

    /// rami can turn the lines off without turning the offers off
    var enabled = true { didSet { if !enabled { hide() } else { refresh(after: 0.1) } } }
    private var scan = TextScan()
    private let window = UnderlineWindow()
    private let queue = DispatchQueue(label: "studio.orbitlabs.eloq.underlines", qos: .userInitiated)
    private var generation = 0
    private var shown: UnderlinePass?
    private var observer: AXObserver?
    private var observed: pid_t = 0
    private var timer: Timer?
    private var started = false
    private var busy = false
    private var woken: Set<pid_t> = []

    func load(_ next: TextScan) {
        scan = next
        refresh(after: 0.1)
    }

    /// called once accessibility is trusted
    func start() {
        guard !started, AXIsProcessTrusted() else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.hide()
                self?.watchFrontApp()
                self?.refresh(after: 0.25)
            }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.hide() }
        // a window that animates, a field that grows: nothing announces these, so look again now and then
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh(after: 0, quiet: true) }
        watchFrontApp()
        refresh(after: 0.2)
    }

    /// the text moved (a key, a scroll): put the lines away now and look again when it rests
    func moved(restAfter delay: TimeInterval) {
        guard started else { return }
        hide()
        refresh(after: delay)
    }

    /// something may have changed (a click): look again, and leave the lines until then
    func changed(after delay: TimeInterval) {
        guard started else { return }
        refresh(after: delay, quiet: true)
    }

    func hide() {
        generation += 1
        shown = nil
        window.orderOut(nil)
    }

    private func refresh(after delay: TimeInterval, quiet: Bool = false) {
        guard started else { return }
        if !quiet { generation += 1 }
        let asked = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, asked == self.generation else { return }
            self.pass(asked)
        }
    }

    private func pass(_ asked: Int) {
        let front = NSWorkspace.shared.frontmostApplication
        guard enabled, !scan.isEmpty, AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let front,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if shown != nil { hide() }
            return
        }
        // an app that answers slowly must not collect a line of waiting passes
        guard !busy else { return }
        busy = true
        let pid = front.processIdentifier, scan = scan
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        queue.async { [weak self] in
            let found = UnderlineReader.focusedText(of: pid).flatMap { UnderlineReader.read($0, with: scan, primaryHeight: primaryHeight) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if asked == self.generation { self.show(found) } else { self.refresh(after: 0.05, quiet: true) }
            }
        }
    }

    private func show(_ pass: UnderlinePass?) {
        guard let pass, !pass.lines.isEmpty else {
            if shown != nil { hide() }
            return
        }
        guard pass != shown else { return }
        let appearing = shown == nil
        shown = pass
        window.setFrame(pass.frame, display: false)
        window.lines.lines = pass.lines
        if appearing {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    // MARK: the front app's own announcements

    /// an electron app builds its accessibility tree when something asks for it, and older ones
    /// only after this flag is set. it is electron's own switch for tools like this one, set once
    /// for each app; the app answers a little later, so look again then.
    private func wake(_ app: NSRunningApplication) {
        guard let bundle = app.bundleURL, !woken.contains(app.processIdentifier),
              FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) else { return }
        woken.insert(app.processIdentifier)
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        for delay in [0.7, 1.4] { refresh(after: delay, quiet: true) }
    }

    private func watchFrontApp() {
        if let front = NSWorkspace.shared.frontmostApplication { wake(front) }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != observed else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observer = nil
        observed = front.processIdentifier
        guard observed != ProcessInfo.processInfo.processIdentifier else { return }
        var made: AXObserver?
        guard AXObserverCreate(observed, underlineNotice, &made) == .success, let made else { return }
        let app = AXUIElementCreateApplication(observed)
        for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
                     kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXApplicationHiddenNotification] {
            AXObserverAddNotification(made, app, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
        observer = made
    }

    fileprivate func noticed() { moved(restAfter: 0.2) }
}

private func underlineNotice(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ info: UnsafeMutableRawPointer?) {
    Underlines.shared.noticed()
}
