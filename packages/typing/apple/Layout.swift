// which key types which character on the keyboard layout in use. the offer's digits and the
// copy that reads a selection are keys of the layout, not of a us keyboard.
// main thread: the layout calls are the text input system's.
import Carbon.HIToolbox
import Foundation

enum Layout {
    /// the number row of an ansi keyboard, for a layout that cannot be read
    static let ansiDigits: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]

    /// key code -> the character the key types with no modifier
    static func table() -> [Int64: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var table: [Int64: String] = [:]
        data.withUnsafeBytes { bytes in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, units.count, &length, &units)
                if status == noErr, length > 0 { table[Int64(code)] = String(utf16CodeUnits: units, count: length) }
            }
        }
        return table
    }

    /// key code -> 0...8 for the keys that type 1...9 with no modifier; the ansi row when the layout has none
    static func digits(_ table: [Int64: String]) -> [Int64: Int] {
        var digits: [Int64: Int] = [:]
        for (code, typed) in table {
            if typed.count == 1, let digit = Int(typed), digit >= 1 { digits[code] = digit - 1 }
        }
        return digits.count == 9 ? digits : ansiDigits
    }

    /// the key that types `letter`, so command with it is the layout's own shortcut
    static func code(for letter: String, in table: [Int64: String]) -> CGKeyCode? {
        table.first { $0.value == letter }.map { CGKeyCode($0.key) }
    }
}
