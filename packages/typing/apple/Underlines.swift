// thin lines under your library's words in the text field that has the focus, in any app:
// amber dots under a word you overuse, a green line under a target word you used.
//
// - it reads only the text that is visible in the focused field, through accessibility, and
//   keeps nothing: each pass scans, asks where the matched words are drawn, and forgets.
// - the lines live in a window of eloq's that takes no clicks and never has the focus, so the
//   other app's text, selection and menus behave exactly as before.
// - a line never trails behind moving text, and a line that does not move is left alone. a key
//   puts away only the lines it can move (the cursor's own line, from the cursor on), and one
//   quick question tells whether the text above or below the cursor shifted with it. a scroll
//   moves everything, so it puts all of them away. they return when the text rests.
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

/// who drew a line and where it said the word was: asked again, it tells whether the text moved
struct UnderlineSource {
    let holder: AXUIElement
    let start: Int
    let end: Int
    let box: CGRect
}

/// what one pass over a text field found
struct UnderlinePass: Equatable {
    /// the field's visible box, which the window covers
    let frame: NSRect
    let lines: [Underline]
    /// one for each line
    var sources: [UnderlineSource] = []
    /// the cursor's box in appkit screen coordinates, when the field draws one
    var caret: NSRect?

    /// two passes are the same when they would draw the same
    static func == (a: UnderlinePass, b: UnderlinePass) -> Bool { a.frame == b.frame && a.lines == b.lines }

    /// the pass with only these lines
    func keeping(_ indices: [Int]) -> UnderlinePass {
        var next = UnderlinePass(frame: frame, lines: indices.map { lines[$0] })
        next.sources = sources.count == lines.count ? indices.map { sources[$0] } : []
        next.caret = caret
        return next
    }
}

enum UnderlineReader {
    /// a pass never scans more text than this. a native field hands over only what shows; a
    /// field that cannot say what shows hands over its whole text, of which this much is read.
    static let maxCharacters = 12_000
    static let maxMarks = 160
    /// a web field never costs more than this many elements in a pass, hidden ones included
    static let maxNodes = 500
    /// and no pass is longer than this, however slowly the app answers
    static let budget: TimeInterval = 0.2
    private static let nodeNames = [kAXRoleAttribute, kAXSizeAttribute, kAXValueAttribute, kAXChildrenAttribute] as [String]

    /// the part of a field that shows: a text view is as tall as its whole text, and the scroll
    /// area and the window around it show a part. `web` says the field is in a web page.
    static func visibleFrame(_ element: AXUIElement, _ field: CGRect) -> (clip: CGRect, web: Bool) {
        var clip = field
        var web = false
        var current = element
        // a web page nests a field many groups deep (a chat app's message box: about twenty), so
        // the walk goes far, and ends at the page: chromium has clipped the field to it already
        for _ in 0..<64 {
            guard let parent = AX.element(AX.attribute(current, kAXParentAttribute)) else { break }
            let role = AX.attribute(parent, kAXRoleAttribute) as? String ?? ""
            if role == "AXScrollArea" || role == "AXWindow" || role == "AXWebArea", let box = AX.frame(parent) { clip = clip.intersection(box) }
            if role == "AXWindow" { return (clip, web) }
            if role == "AXWebArea" {
                web = true
                break
            }
            current = parent
        }
        if let window = AX.element(AX.attribute(element, kAXWindowAttribute)), let box = AX.frame(window) { clip = clip.intersection(box) }
        return (clip, web)
    }

    /// the text nodes of a web rich text field that show, each with its text. chromium clips a
    /// node's box to what shows, so a node that has scrolled away has no height and is passed by,
    /// with everything inside it.
    static func textNodes(_ element: AXUIElement, until deadline: Date = .distantFuture) -> [(node: AXUIElement, text: String)] {
        var found: [(AXUIElement, String)] = []
        var waiting = Array((AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).reversed())
        var visited = 0
        while let node = waiting.popLast(), visited < maxNodes, Date() < deadline {
            visited += 1
            let values = AX.attributes(node, nodeNames)
            guard let size = AX.size(values[1]), size.height >= 2, size.width >= 2 else { continue }
            if (values[0] as? String) == "AXStaticText" {
                if let text = values[2] as? String, !text.isEmpty { found.append((node, text)) }
            } else if let children = values[3] as? [AXUIElement] {
                waiting.append(contentsOf: children.reversed())
            }
        }
        return found
    }

    /// the visible text of a native field and where it starts in the whole text
    static func visibleText(_ element: AXUIElement) -> (text: String, offset: Int)? {
        if var visible = AX.range(AX.attribute(element, kAXVisibleCharacterRangeAttribute)), visible.length > 0 {
            visible.length = min(visible.length, maxCharacters)
            if let asked = AX.value(visible), let text = AX.parameterized(element, kAXStringForRangeParameterizedAttribute, asked) as? String {
                return (text, visible.location)
            }
        }
        guard let text = AX.attribute(element, kAXValueAttribute) as? String, !text.isEmpty else { return nil }
        return (text.utf16.count > maxCharacters ? String(decoding: Array(text.utf16.prefix(maxCharacters)), as: UTF16.self) : text, 0)
    }

    private static func bounds(_ element: AXUIElement, _ start: Int, _ end: Int) -> CGRect? {
        guard let asked = AX.value(CFRange(location: start, length: end - start)),
              let box = AX.rect(AX.parameterized(element, kAXBoundsForRangeParameterizedAttribute, asked)),
              box.width > 0.5, box.height > 2, box.height < 200 else { return nil }
        return box
    }

    /// the lines a key typed at the cursor cannot move: every line but the cursor's own from the
    /// cursor on. a delete can change the words before the cursor too, so it takes the whole of
    /// the cursor's line. `caret` is where the cursor was at the last pass; typing has only
    /// moved it on from there.
    static func keptWhenTyping(_ lines: [Underline], caret: NSRect, deleting: Bool) -> [Int] {
        lines.indices.filter { i in
            let box = lines[i].rect
            let onCursorLine = box.minY < caret.maxY - 1 && box.maxY > caret.minY + 1
            return !onCursorLine || (!deleting && box.maxX <= caret.minX + 1)
        }
    }

    /// true when the word is no longer drawn where its line is
    static func moved(_ source: UnderlineSource) -> Bool {
        guard let now = bounds(source.holder, source.start, source.end) else { return true }
        return abs(now.minX - source.box.minX) > 0.5 || abs(now.minY - source.box.minY) > 0.5
    }

    /// one pass: scan the field's visible text and find where each matched word is drawn
    static func read(_ element: AXUIElement, with scan: TextScan, primaryHeight: CGFloat) -> UnderlinePass? {
        let deadline = Date().addingTimeInterval(budget)
        guard let whole = AX.frame(element) else { return nil }
        let (field, web) = visibleFrame(element, whole)
        guard !field.isNull, field.width > 8, field.height > 8 else { return nil }
        var lines: [Underline] = []
        var sources: [UnderlineSource] = []
        var marked = 0
        // a box partly outside the field is text that has scrolled under its edge
        let inside = field.insetBy(dx: -1, dy: -1)
        func add(_ box: CGRect, _ kind: TextScan.Kind, _ holder: AXUIElement, _ start: Int, _ end: Int) {
            guard inside.contains(box) else { return }
            lines.append(Underline(rect: AX.appKit(box, primaryHeight: primaryHeight), kind: kind))
            sources.append(UnderlineSource(holder: holder, start: start, end: end, box: box))
        }
        /// the marks of one text, which `holder` knows the boxes of, `offset` into its own text
        func mark(_ holder: AXUIElement, _ text: String, _ offset: Int) {
            for mark in scan.scan(text) {
                guard marked < maxMarks, Date() < deadline else { return }
                marked += 1
                guard let all = bounds(holder, offset + mark.start, offset + mark.end) else { continue }
                guard mark.words.count > 1, let first = mark.words.first,
                      let head = bounds(holder, offset + first.lowerBound, offset + first.upperBound), all.height > head.height * 1.5 else {
                    add(all, mark.kind, holder, offset + mark.start, offset + mark.end)
                    continue
                }
                // the phrase wraps: one line under each of its words
                add(head, mark.kind, holder, offset + first.lowerBound, offset + first.upperBound)
                for word in mark.words.dropFirst() {
                    if let box = bounds(holder, offset + word.lowerBound, offset + word.upperBound) {
                        add(box, mark.kind, holder, offset + word.lowerBound, offset + word.upperBound)
                    }
                }
            }
        }
        let nodes = web ? textNodes(element, until: deadline) : []
        if nodes.isEmpty {
            // a native field, or a web field with no nodes (a plain text box)
            guard let (text, offset) = visibleText(element) else { return nil }
            mark(element, text, offset)
        } else {
            for (node, text) in nodes { mark(node, text, 0) }
        }
        var pass = UnderlinePass(frame: AX.appKit(field, primaryHeight: primaryHeight), lines: lines)
        pass.sources = sources
        pass.caret = lines.isEmpty ? nil : AX.selectionBox(element).map { AX.appKit($0, primaryHeight: primaryHeight) }
        return pass
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

/// keeps the lines true to the field in front. main thread, but for what asks another app
/// something (a pass, the observer), which is on `queue`.
final class Underlines {
    static let shared = Underlines()

    /// the lines can be off while the offers stay on
    var enabled = true {
        didSet {
            if enabled { refresh(after: 0.1) } else { hide() }
        }
    }
    /// the front app's focus or window moved with no key or click of the person's
    var appMoved: (() -> Void)?
    private var scan = TextScan()
    private let window = UnderlineWindow()
    private let queue = DispatchQueue(label: "studio.orbitlabs.eloq.underlines", qos: .userInitiated)
    private var generation = 0
    private var shown: UnderlinePass?
    private var timer: Timer?
    private var started = false
    private var busy = false
    /// where the cursor was at the last pass
    private var caret: NSRect?
    private var probing = 0
    private var lastInput = Date()
    /// the text is moving until then: no look before it
    private var restUntil = Date.distantPast
    private var ticks = 0
    // the front app's observer, touched on `queue` only: making one asks the app, which may be busy
    private var observer: AXObserver?
    private var observed: pid_t = 0
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
        // a window that animates, a field that grows: nothing announces these, so look again now
        // and then: often while the person is at work, seldom once they have stopped
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.tick() }
        watchFrontApp()
        refresh(after: 0.2)
    }

    /// the text moved (a key, a scroll): put the lines away now and look again when it rests
    func moved(restAfter delay: TimeInterval) {
        guard started else { return }
        lastInput = Date()
        restUntil = lastInput.addingTimeInterval(delay)
        hide()
        refresh(after: delay)
    }

    /// a key typed or deleted at the cursor: the lines it cannot move stay as they are. the full
    /// look comes when the keys rest; until then one line above the cursor and one below are
    /// asked whether the text shifted (a line wrapped, a chat box grew).
    func typed(deleting: Bool) {
        guard started else { return }
        guard let pass = shown, let caret, pass.sources.count == pass.lines.count else {
            // nothing shown, or a field that draws no cursor: as a scroll
            moved(restAfter: 0.3)
            return
        }
        lastInput = Date()
        restUntil = lastInput.addingTimeInterval(0.3)
        put(pass.keeping(UnderlineReader.keptWhenTyping(pass.lines, caret: caret, deleting: deleting)))
        refresh(after: 0.3)
        probing += 1
        let asked = probing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, asked == self.probing, let kept = self.shown else { return }
            // the nearest line on each side of the cursor's line stands for its side
            let above = kept.lines.indices.filter { kept.lines[$0].rect.minY >= caret.maxY - 1 }
            let below = kept.lines.indices.filter { kept.lines[$0].rect.maxY <= caret.minY + 1 }
            let nearestAbove = above.min { kept.lines[$0].rect.minY < kept.lines[$1].rect.minY }
            let nearestBelow = below.max { kept.lines[$0].rect.maxY < kept.lines[$1].rect.maxY }
            guard nearestAbove != nil || nearestBelow != nil else { return }
            let sources = (nearestAbove.map { kept.sources[$0] }, nearestBelow.map { kept.sources[$0] })
            self.queue.async {
                let aboveMoved = sources.0.map(UnderlineReader.moved) ?? false
                let belowMoved = sources.1.map(UnderlineReader.moved) ?? false
                guard aboveMoved || belowMoved else { return }
                DispatchQueue.main.async {
                    guard asked == self.probing, let now = self.shown, now == kept else { return }
                    let gone = Set((aboveMoved ? above : []) + (belowMoved ? below : []))
                    self.put(now.keeping(now.lines.indices.filter { !gone.contains($0) }))
                }
            }
        }
    }

    /// show fewer of the lines that are shown, with no other change
    private func put(_ next: UnderlinePass) {
        guard next.lines.count != shown?.lines.count else { return }
        guard !next.lines.isEmpty else {
            shown = nil
            window.orderOut(nil)
            return
        }
        shown = next
        window.lines.lines = next.lines
    }

    /// something may have changed (a click): look again, and leave the lines until then
    func changed(after delay: TimeInterval) {
        guard started else { return }
        lastInput = Date()
        refresh(after: delay, quiet: true)
    }

    func hide() {
        generation += 1
        probing += 1
        shown = nil
        window.orderOut(nil)
    }

    private func tick() {
        ticks += 1
        let now = Date(), idle = now.timeIntervalSince(lastInput)
        // not between two keys; after twenty seconds with no key, click or scroll one look in four
        // is enough; and after two minutes nothing on the screen is waiting to be found
        guard enabled, !scan.isEmpty, now >= restUntil, idle < 120, idle < 20 || ticks % 4 == 0 else { return }
        refresh(after: 0, quiet: true)
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
            let field = AX.focused(of: pid).flatMap { AX.isReadableText($0) ? $0 : nil }
            let found = field.flatMap { UnderlineReader.read($0, with: scan, primaryHeight: primaryHeight) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if asked == self.generation {
                    self.show(found)
                } else if Date() >= self.restUntil {
                    // the answer is of an older state, and nothing else has asked again
                    self.refresh(after: 0.05, quiet: true)
                }
            }
        }
    }

    private func show(_ pass: UnderlinePass?) {
        guard let pass, !pass.lines.isEmpty else {
            if shown != nil { hide() }
            return
        }
        caret = pass.caret
        guard pass != shown else {
            // the same lines; who drew them may be new elements
            shown = pass
            return
        }
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

    // MARK: the front app

    /// the app in front, for the two things that ask it something: an electron app builds its
    /// tree of the page only after its switch is set, once for each app, and answers a little
    /// later; and the app's own announcements (its focus moved, its window moved) need an
    /// observer on it.
    private func watchFrontApp() {
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier, own = ProcessInfo.processInfo.processIdentifier
        let electron = front.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        queue.async { [weak self] in
            guard let self else { return }
            if electron, !self.woken.contains(pid) {
                self.woken.insert(pid)
                AX.wakeElectron(pid)
                DispatchQueue.main.async { for delay in [0.7, 1.4] { self.refresh(after: delay, quiet: true) } }
            }
            guard pid != self.observed else { return }
            if let old = self.observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .commonModes) }
            self.observer = nil
            self.observed = 0
            guard pid != own else { return }
            var made: AXObserver?
            guard AXObserverCreate(pid, underlineNotice, &made) == .success, let made else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, AX.patience)
            for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
                         kAXWindowResizedNotification, kAXWindowMiniaturizedNotification, kAXApplicationHiddenNotification] {
                AXObserverAddNotification(made, app, name as CFString, nil)
            }
            // the announcements arrive on the main thread
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .commonModes)
            self.observer = made
            self.observed = pid
        }
    }

    fileprivate func noticed() {
        moved(restAfter: 0.2)
        appMoved?()
    }
}

private func underlineNotice(_ observer: AXObserver, _ element: AXUIElement, _ name: CFString, _ info: UnsafeMutableRawPointer?) {
    Underlines.shared.noticed()
}
