// the two small panels eloq shows at the text cursor of another app: the offer (the words to
// use instead of an overused one) and the capture (add the selected word).
//
// a panel never has the keyboard and never becomes main, so the other app keeps its cursor and
// its selection; the key tap hears the panel's keys.
import AppKit

/// a rounded panel under the text cursor, on every space, kept on the cursor's screen
class CursorPanel: NSPanel {
    let stack = NSStackView()

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

    func clear() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.preferredMaxLayoutWidth = 300
        return field
    }

    /// a key cap and what it does
    func choice(_ key: String, _ text: NSView) -> NSView {
        let cap = NSTextField(labelWithString: key)
        // a symbol (the tab arrow) is drawn smaller than a letter at the same size
        let symbol = key.count == 1 && key.unicodeScalars.allSatisfy { !$0.isASCII }
        cap.font = symbol ? .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .medium) : .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        cap.textColor = .secondaryLabelColor
        cap.alignment = .center
        cap.wantsLayer = true
        cap.layer?.cornerRadius = 4
        cap.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        // one key is a square; option and a digit are two keys wide
        cap.widthAnchor.constraint(equalToConstant: key.count > 1 ? 34 : 20).isActive = true
        cap.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let row = NSStackView(views: [cap, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    /// measured after layout, so the longest line fits inside the rounded edge; then under the
    /// anchor's line, or over it where the screen ends
    func place(at anchor: NSRect, minWidth: CGFloat, maxWidth: CGFloat) {
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        let width = min(max(size.width + 4, minWidth), maxWidth)
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.minX - 14, y: anchor.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - width - 4)
            if origin.y < visible.minY + 4 { origin.y = min(anchor.maxY + 6, visible.maxY - size.height - 4) }
        }
        setFrame(NSRect(x: origin.x, y: origin.y, width: width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

/// the words to use instead of the overused word at the cursor
final class OfferPanel: CursorPanel {
    func show(_ offer: Offer, at caret: NSRect) {
        clear()
        let small = NSFont.smallSystemFontSize
        stack.addArrangedSubview(label("Instead of “\(offer.typed)”", size: small, weight: .semibold, color: .secondaryLabelColor))
        for (i, move) in offer.moves.enumerated() {
            let word = label(move.text, size: NSFont.systemFontSize + 1, weight: i == 0 ? .semibold : .regular)
            let column = NSStackView(views: [word])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 1
            if !move.useWhen.isEmpty { column.addArrangedSubview(label(move.useWhen, size: small, color: .secondaryLabelColor)) }
            // with a space after the word, a bare digit is a number the person types: there it needs option
            stack.addArrangedSubview(choice(i == 0 ? "⇥" : offer.boundary.isEmpty ? "\(i + 1)" : "⌥\(i + 1)", column))
        }
        stack.addArrangedSubview(label("A key shown swaps the word · any other key keeps it", size: small - 1, color: .tertiaryLabelColor))
        place(at: caret, minWidth: 240, maxWidth: 360)
    }
}

/// add the selected word, or what the library already says of it
final class CapturePanel: CursorPanel {
    func show(_ capture: Capture, at anchor: NSRect) {
        clear()
        let small = NSFont.smallSystemFontSize, body = NSFont.systemFontSize
        let word = capture.text.count > 40 ? capture.text.prefix(40) + "…" : capture.text
        func title(_ text: String) { stack.addArrangedSubview(label(text, size: small, weight: .semibold, color: .secondaryLabelColor)) }
        func line(_ text: String) { stack.addArrangedSubview(label(text, size: body)) }
        func foot(_ text: String) { stack.addArrangedSubview(label(text, size: small - 1, color: .tertiaryLabelColor)) }
        switch capture.state {
        case .new:
            title("Add “\(word)” to Eloq")
            stack.addArrangedSubview(choice("O", label("I overuse it", size: body)))
            stack.addArrangedSubview(choice("T", label("I want to use it", size: body)))
            foot("Return opens it in Eloq · Esc cancels")
        case .overused(let moves):
            title("You overuse “\(word)”")
            line(moves.isEmpty ? "No words to use instead yet." : "Try: \(moves.prefix(4).joined(separator: ", "))")
            foot("Already in your library")
        case .target:
            title("“\(word)” is one of your targets")
            line("Use it more.")
            foot("Already in your library")
        case .tooLong:
            title("That selection is long")
            line("Select a word or a short phrase.")
        case .saved(let overused):
            let check = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Added") ?? NSImage())
            check.contentTintColor = .systemGreen
            let row = NSStackView(views: [check, label("Added “\(word)”", size: body, weight: .medium)])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(label(overused ? "A word you overuse" : "A word you want to use", size: small, color: .secondaryLabelColor))
        }
        place(at: anchor, minWidth: 220, maxWidth: 340)
    }
}
