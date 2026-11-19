// add the selected word to eloq from any app: one shortcut (control-option-command-l) shows a
// small panel at the selection, then `o` saves it as a word you overuse and `t` as a target.
// a word that is already in the library shows what it is instead, with the words to use.
//
// - the selection comes from accessibility; an app that does not answer is asked with a copy,
//   and the clipboard is put back as it was.
// - the panel never takes the focus: the key tap hears its keys, so the other app keeps its
//   selection and its cursor.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// what the panel is about
struct Capture {
    enum State: Equatable {
        case new
        case overused(moves: [String])
        case target
        case tooLong
        case saved(overused: Bool)
    }
    let text: String
    let app: String
    var state: State
}

enum SelectionReader {
    /// a word or a short phrase: longer selections are sentences, which the library does not hold
    static let maxWords = 6

    /// the selection as a library entry: trimmed, on one line, and a sentence's first capital dropped
    static func clean(_ raw: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”«»()[]{}.,;:!?…"))
        let oneLine = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let text = oneLine.trimmingCharacters(in: edges)
        guard let first = text.first, first.isUppercase, text.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        // "Interesting" at the start of a sentence is "interesting"; "iPhone" and "NASA" keep their capitals
        return first.lowercased() + text.dropFirst()
    }

    static func focused() -> AXUIElement? {
        guard let focused = UnderlineReader.attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// the selected text of the focused element, when the app says
    static func selection(of element: AXUIElement?) -> String? {
        guard let element, let text = UnderlineReader.attribute(element, kAXSelectedTextAttribute) as? String, !text.isEmpty else { return nil }
        return text
    }

    /// where the selection is drawn, in appkit screen coordinates; else the mouse
    static func anchor(of element: AXUIElement?) -> NSRect {
        let mouse = NSEvent.mouseLocation
        guard let element, let box = UnderlineReader.selectionBox(element) else {
            return NSRect(x: mouse.x, y: mouse.y - 4, width: 1, height: 18)
        }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: box.minX, y: primary - box.maxY, width: max(box.width, 1), height: box.height)
    }

    /// ask the front app to copy, read what it copied, and put the clipboard back as it was
    static func copied(mark: Int64, done: @escaping (String?) -> Void) {
        let board = NSPasteboard.general
        let before = board.changeCount
        let kept: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: mark)
            event?.post(tap: .cgSessionEventTap)
        }
        func settle(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                guard board.changeCount != before else {
                    if tries > 0 { settle(tries - 1) } else { done(nil) }
                    return
                }
                let text = board.string(forType: .string)
                board.clearContents()
                board.writeObjects(kept.map { types in
                    let item = NSPasteboardItem()
                    for (type, data) in types { item.setData(data, forType: type) }
                    return item
                })
                done(text)
            }
        }
        settle(8)
    }
}

/// the panel at the selection: never key, never main, on every space
final class CapturePanel: NSPanel {
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

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.preferredMaxLayoutWidth = 300
        return field
    }

    private func choice(_ key: String, _ text: String) -> NSView {
        let cap = NSTextField(labelWithString: key)
        cap.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        cap.textColor = .secondaryLabelColor
        cap.alignment = .center
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 4
        cap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        cap.widthAnchor.constraint(equalToConstant: 20).isActive = true
        cap.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let row = NSStackView(views: [cap, label(text, size: NSFont.systemFontSize)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    func show(_ capture: Capture, at anchor: NSRect) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let small = NSFont.smallSystemFontSize
        let shownText = capture.text.count > 40 ? capture.text.prefix(40) + "…" : capture.text
        switch capture.state {
        case .new:
            stack.addArrangedSubview(label("Add “\(shownText)” to Eloq", size: small, weight: .semibold, color: .secondaryLabelColor))
            stack.addArrangedSubview(choice("O", "I overuse it"))
            stack.addArrangedSubview(choice("T", "I want to use it"))
            stack.addArrangedSubview(label("Return opens it in Eloq · Esc cancels", size: small - 1, color: .tertiaryLabelColor))
        case .overused(let moves):
            stack.addArrangedSubview(label("You overuse “\(shownText)”", size: small, weight: .semibold, color: .secondaryLabelColor))
            if moves.isEmpty {
                stack.addArrangedSubview(label("No words to use instead yet.", size: NSFont.systemFontSize))
            } else {
                stack.addArrangedSubview(label("Try: \(moves.prefix(4).joined(separator: ", "))", size: NSFont.systemFontSize))
            }
            stack.addArrangedSubview(label("Already in your library", size: small - 1, color: .tertiaryLabelColor))
        case .target:
            stack.addArrangedSubview(label("“\(shownText)” is one of your targets", size: small, weight: .semibold, color: .secondaryLabelColor))
            stack.addArrangedSubview(label("Use it more.", size: NSFont.systemFontSize))
            stack.addArrangedSubview(label("Already in your library", size: small - 1, color: .tertiaryLabelColor))
        case .tooLong:
            stack.addArrangedSubview(label("That selection is long", size: small, weight: .semibold, color: .secondaryLabelColor))
            stack.addArrangedSubview(label("Select a word or a short phrase.", size: NSFont.systemFontSize))
        case .saved(let overused):
            let row = NSStackView(views: [
                NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Added") ?? NSImage()),
                label("Added “\(shownText)”", size: NSFont.systemFontSize, weight: .medium),
            ])
            (row.views.first as? NSImageView)?.contentTintColor = .systemGreen
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(label(overused ? "A word you overuse" : "A word you want to use", size: small, color: .secondaryLabelColor))
        }
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let width = min(max(size.width + 4, 220), 340)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.minX - 14, y: anchor.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
            if origin.y < visible.minY + 4 { origin.y = min(anchor.maxY + 6, visible.maxY - size.height - 4) }
        }
        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: size.height), display: true)
        orderFrontRegardless()
    }
}
