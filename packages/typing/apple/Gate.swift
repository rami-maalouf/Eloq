// what the key tap's thread may decide on its own, at once: which keys eloq takes.
//
// the tap answers every key of the mac before the key goes on, so its answer must never wait:
// not for another app, and not for eloq's own main thread. the gate holds the few facts that
// answer needs, behind one lock: the swaps tab and the digits make while an offer is shown, the
// keys the capture panel takes, and a count of the keys and clicks seen. the main thread arms
// and disarms it; the tap thread reads it and disarms it at every key that is not eloq's.
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// one key, as the tap saw it
struct Key {
    let code: Int64
    let flags: CGEventFlags
    /// what the key types on the layout in use; empty for a dead key or a function key
    let characters: String
    let repeated: Bool
}

/// what a swap posts: so many backspaces, then the text
struct Swap {
    let deletions: Int
    let text: String

    /// the replacement in the case of what was typed: "Interesting" at a sentence's start gives
    /// "Compelling", "VERY" gives "EXTREMELY", and "I think" gives "my sense is" as the library has it
    static func cased(_ text: String, like typed: String) -> String {
        let word = typed.prefix { !$0.isWhitespace }
        let letters = typed.filter(\.isLetter)
        if letters.count > 1, letters.allSatisfy(\.isUppercase) { return text.uppercased() }
        guard let first = word.first, first.isUppercase, word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I\u{2019}"),
              word.dropFirst().allSatisfy({ !$0.isUppercase }), let head = text.first else { return text }
        return head.uppercased() + text.dropFirst()
    }

    /// the key events of the swap, in order, each marked `mark` so eloq's taps let it through.
    /// a source of its own and no flags: a modifier that is held (option, for a digit) must not
    /// turn a backspace into "delete the word". one event for each character, whole: a character
    /// outside the basic plane is two units.
    func events(mark: Int64) -> [CGEvent] {
        let source = CGEventSource(stateID: .privateState)
        var events: [CGEvent] = []
        func add(_ event: CGEvent?) {
            guard let event else { return }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: mark)
            events.append(event)
        }
        for _ in 0..<deletions {
            for down in [true, false] { add(CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: down)) }
        }
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                add(event)
            }
        }
        return events
    }
}

final class Gate {
    /// which keys the capture panel takes
    enum CaptureKeys {
        case none
        /// a new word: o, t, return, escape
        case choose
        /// a word of the library: return, escape
        case look
        /// a notice that closes by itself: escape
        case notice
    }

    enum CaptureKey {
        case escape, overused, target, open
    }

    enum Verdict {
        /// the other app's key; the main thread hears of it after
        case pass
        /// eloq's, and nothing more to do: the repeat of a key it took
        case swallow
        case swap(Int, Swap)
        case capture(CaptureKey)
        case beginCapture
    }

    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var swaps: [Swap] = []
    private var bareDigits = false
    private var captureKeys = CaptureKeys.none
    private var taken: Int64 = -1
    private var digits = Layout.ansiDigits
    private var ports: [CFMachPort] = []
    private var runLoop: CFRunLoop?
    private var lastScroll: CFAbsoluteTime = 0

    // MARK: the main thread

    /// how many keys and clicks have been seen: a reading that started at one count may arm
    /// the gate only while the count is still that
    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    /// tab and the digits swap from now on, unless a key or a click came since `count`
    func arm(_ next: [Swap], bareDigits bare: Bool, since count: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard count == sequence else { return false }
        swaps = next
        bareDigits = bare
        return true
    }

    func disarm() {
        lock.lock()
        swaps = []
        lock.unlock()
    }

    /// the cursor or the text moved for a reason no key says: disarm, and drop readings on their way
    func touch() {
        lock.lock()
        swaps = []
        sequence += 1
        lock.unlock()
    }

    func setCapture(_ keys: CaptureKeys) {
        lock.lock()
        captureKeys = keys
        lock.unlock()
    }

    func setDigits(_ next: [Int64: Int]) {
        lock.lock()
        digits = next
        lock.unlock()
    }

    func open(_ taps: [CFMachPort]) {
        lock.lock()
        ports = taps
        lock.unlock()
    }

    /// the taps are done: they stop, and the tap thread's run loop ends
    func close() {
        lock.lock()
        let closing = ports, loop = runLoop
        ports = []
        runLoop = nil
        swaps = []
        captureKeys = .none
        lock.unlock()
        for port in closing {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    // MARK: the tap thread

    func running(on loop: CFRunLoop) {
        lock.lock()
        runLoop = loop
        lock.unlock()
    }

    /// the system switched a tap off (it answered late, or the person is in a secure dialog): on again
    func reenable() {
        lock.lock()
        let open = ports
        lock.unlock()
        for port in open { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// a click or a scroll: the offer no longer holds. true when the main thread should hear of
    /// this scroll (a wheel sends hundreds of events; ten a second are enough).
    func pointer(scroll: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        swaps = []
        sequence += 1
        guard scroll else { return true }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastScroll > 0.1 else { return false }
        lastScroll = now
        return true
    }

    func key(_ key: Key) -> Verdict {
        lock.lock()
        defer { lock.unlock() }
        // a key eloq took is eloq's until it is let go
        if key.repeated, key.code == taken { return .swallow }
        taken = -1
        let command = key.flags.contains(.maskCommand), control = key.flags.contains(.maskControl)
        let option = key.flags.contains(.maskAlternate), shift = key.flags.contains(.maskShift)
        func take(_ verdict: Verdict) -> Verdict {
            taken = key.code
            swaps = []
            sequence += 1
            return verdict
        }
        if key.code == Int64(kVK_ANSI_L), command, control, option, !shift { return take(.beginCapture) }
        if captureKeys != .none {
            if !command, !control, !option {
                let letter = key.characters.lowercased()
                if key.code == Int64(kVK_Escape) {
                    captureKeys = .none
                    return take(.capture(.escape))
                }
                if captureKeys == .choose, letter == "o" || letter == "t" {
                    captureKeys = .notice
                    return take(.capture(letter == "o" ? .overused : .target))
                }
                if captureKeys != .notice, key.code == Int64(kVK_Return) || key.code == Int64(kVK_ANSI_KeypadEnter) {
                    captureKeys = .none
                    return take(.capture(.open))
                }
            }
            // any other key is the other app's, and the panel has had its say
            captureKeys = .none
        }
        if !swaps.isEmpty, !command, !control {
            var index: Int?
            if key.code == Int64(kVK_Tab), !option, !shift {
                index = 0
            } else if option, !shift {
                index = digits[key.code]
            } else if !option, bareDigits, key.characters.count == 1, let digit = Int(key.characters), digit >= 1 {
                index = digit - 1
            }
            if let index, index < swaps.count {
                let swap = swaps[index]
                return take(.swap(index, swap))
            }
        }
        swaps = []
        sequence += 1
        return .pass
    }
}
