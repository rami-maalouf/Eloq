// add the selected word to eloq from any app: one shortcut (control-option-command-l) shows a
// small panel at the selection, then `o` saves it as a word you overuse and `t` as a target.
// a word that is already in the library shows what it is instead, with the words to use.
//
// - the selection comes from accessibility. an app that does not say what is selected is asked
//   with a copy, and the clipboard is put back as it was (what it held as plain data; a file
//   another app has only promised cannot be kept).
// - the panel never takes the focus: the key tap hears its keys, so the other app keeps its
//   selection and its cursor.
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// what the capture panel is about
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
    static let maxCharacters = 80

    /// the selection as a library entry: trimmed, on one line, and a sentence's first capital dropped
    static func clean(_ raw: String) -> String {
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”«»()[]{}.,;:!?…"))
        let oneLine = raw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let text = oneLine.trimmingCharacters(in: edges)
        guard let first = text.first, first.isUppercase, text.dropFirst().allSatisfy({ !$0.isUppercase }) else { return text }
        // "Interesting" at the start of a sentence is "interesting"; "iPhone" and "NASA" keep their capitals
        return first.lowercased() + text.dropFirst()
    }

    static func fits(_ text: String) -> Bool {
        TypingLookup.tokenize(text).count <= maxWords && text.count <= maxCharacters
    }

    /// ask the front app to copy, read what it copied, and put the clipboard back as it was.
    /// `mark` tags the two key events, so the key tap lets them through; `key` types "c" on the
    /// layout in use. `done` runs on the main thread, with nil when the app copied nothing.
    ///
    /// the work is off the main thread: a clipboard with a large picture on it takes time to
    /// keep. an app that answers late is still waited for, so its copy never stays on the
    /// clipboard in place of what the person had there. a clipboard manager may record the
    /// copy; that cannot be prevented from here.
    static func copied(mark: Int64, key: CGKeyCode, done: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let board = NSPasteboard.general
            let before = board.changeCount
            let kept: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
            let source = CGEventSource(stateID: .privateState)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
                event?.flags = .maskCommand
                event?.setIntegerValueField(.eventSourceUserData, value: mark)
                event?.post(tap: .cgSessionEventTap)
            }
            var answered = false
            func answer(_ text: String?) {
                guard !answered else { return }
                answered = true
                DispatchQueue.main.async { done(text) }
            }
            // an app answers within a moment. after 0.6 s the panel stops waiting; the clipboard is
            // watched for two seconds more.
            for step in 1...52 {
                Thread.sleep(forTimeInterval: 0.05)
                if board.changeCount != before {
                    let text = answered ? nil : board.string(forType: .string)
                    board.clearContents()
                    board.writeObjects(kept.map { types in
                        let item = NSPasteboardItem()
                        for (type, data) in types { item.setData(data, forType: type) }
                        return item
                    })
                    answer(text)
                    return
                }
                if step == 12 { answer(nil) }
            }
        }
    }
}
