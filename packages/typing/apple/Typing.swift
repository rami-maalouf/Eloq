// @eloq/typing on macos: eloq at work in every other app.
//
// - the offer: an overused word at the text cursor shows the words you want to use instead, in a
//   small panel; tab takes the first, 1-9 picks one, any other key keeps yours (Watcher.swift).
// - the underlines: thin lines under your library's words in the field you write in
//   (Underlines.swift).
// - the capture: control-option-command-l on a selection, or the services menu's two commands,
//   adds a word to the library (Capture.swift).
//
// all of it rests on one key tap and on accessibility, which need the accessibility permission;
// text is read to answer one question and never stored or sent. the lookup ports
// packages/matcher exactly (TypingLookup.swift), so the app, the mcp server and this agree.
import AppKit
import ApplicationServices
import ExactPackage
import Foundation

public final class TypingModule: ExactPackage {
    private let context: ExactPackageContext
    /// the modules alive, one for each window. main thread.
    private static let modules = NSHashTable<TypingModule>.weakObjects()

    public init(context: ExactPackageContext) {
        self.context = context
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            TypingModule.modules.add(self)
            // one window hears the watcher, so a word is counted once; every window shows the status
            Watcher.shared.onMove = { move in TypingModule.modules.allObjects.first?.context.emit("typingmove", [move]) }
            Watcher.shared.onCapture = { capture in TypingModule.modules.allObjects.first?.context.emit("typingcapture", [capture]) }
            Watcher.shared.onStatus = { TypingModule.modules.allObjects.forEach { $0.context.changed("typing.typingStatus") } }
            Services.install()
            // the permission can be given or taken while the app runs
            Watcher.shared.watchTrust()
        }
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

    /// the permission may have changed while the app was away
    public func foreground(_ shown: Bool) {
        guard shown else { return }
        DispatchQueue.main.async { [self] in
            Watcher.shared.start()
            context.changed("typing.typingStatus")
        }
    }
}

/// the services menu's two commands, "Add to Eloq as Overused" and "Add to Eloq as Target":
/// the system hands over the selected text of any app that offers services. the names of the
/// methods are the `message` values in apple/exact.json.
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
