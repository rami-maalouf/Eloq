// the typing lookup, ported from packages/matcher/src/typing.ts (its comment is the rule): the
// last words before the cursor, longest first, normalized exactly as normalize.ts does. no
// appkit here, so test/parity checks it against the typescript reference.
import Foundation

struct TypingLookup {
    let forms: [String: [String]]
    let maxWords: Int

    struct Hit { let termIds: [String]; let text: String }

    func lookup(_ text: String) -> Hit? {
        let words = Self.tokenize(text)
        let n = words.count
        guard n > 0, maxWords > 0 else { return nil }
        for k in stride(from: min(maxWords, n), through: 1, by: -1) {
            let start = words[n - k].lowerBound, end = words[n - 1].upperBound
            let piece = String(text[start..<end])
            let key = Self.normalize(piece)
            if let ids = forms[key], Self.tokenize(key).count == k { return Hit(termIds: ids, text: piece) }
        }
        return nil
    }

    static func isWordChar(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { s in
            switch s.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber: true
            default: false
            }
        }
    }

    static let joiners: Set<Character> = ["'", "\u{2018}", "\u{2019}", "\u{02BC}", "`", "\u{00B4}", "-", "\u{2010}", "\u{2011}"]

    static func isBoundary(_ c: Character) -> Bool { !isWordChar(c) && !joiners.contains(c) }

    /// the word rule of tokenize.ts: runs of letters, marks and digits, joined by one joiner
    static func tokenize(_ text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard isWordChar(text[i]) else { i = text.index(after: i); continue }
            let start = i
            var end = i
            while end < text.endIndex, isWordChar(text[end]) { end = text.index(after: end) }
            while end < text.endIndex, joiners.contains(text[end]) {
                let after = text.index(after: end)
                guard after < text.endIndex, isWordChar(text[after]) else { break }
                end = after
                while end < text.endIndex, isWordChar(text[end]) { end = text.index(after: end) }
            }
            out.append(start..<end)
            i = end
        }
        return out
    }

    static func normalize(_ text: String) -> String {
        var s = text.precomposedStringWithCanonicalMapping
        for a in ["\u{2018}", "\u{2019}", "\u{02BC}", "`", "\u{00B4}"] { s = s.replacingOccurrences(of: a, with: "'") }
        for d in 0x2010...0x2015 { s = s.replacingOccurrences(of: String(UnicodeScalar(d)!), with: "-") }
        s = s.lowercased()
        let spaces = CharacterSet(charactersIn: "\u{09}\u{0A}\u{0B}\u{0C}\u{0D}\u{20}\u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}")
            .union(CharacterSet(charactersIn: UnicodeScalar(0x2000)!...UnicodeScalar(0x200A)!))
        s = s.components(separatedBy: spaces).filter { !$0.isEmpty }.joined(separator: " ")
        let edges = spaces.union(CharacterSet(charactersIn: "\"'“”«»()[]{}.,;:!?"))
        return s.trimmingCharacters(in: edges)
    }
}

/// every library word in a text, ported from packages/matcher/src/matcher.ts `scan`: left to
/// right, the longest form at each word wins, and matches never overlap. offsets are utf-16,
/// as the accessibility api counts them.
struct TextScan {
    enum Kind: String { case overused, target }
    struct Mark: Equatable {
        let start: Int
        let end: Int
        let kind: Kind
        /// each word of the match, for a phrase that wraps onto a second line
        let words: [Range<Int>]
    }

    private let forms: [String: Kind]
    private let heads: [String: Int]
    var isEmpty: Bool { forms.isEmpty }

    /// a form in both lists is overused
    init(overused: [String] = [], targets: [String] = []) {
        var forms: [String: Kind] = [:]
        for form in targets { forms[form] = .target }
        for form in overused { forms[form] = .overused }
        var heads: [String: Int] = [:]
        for form in forms.keys {
            let tokens = TypingLookup.tokenize(form)
            guard let first = tokens.first else { continue }
            let head = String(form[first])
            heads[head] = max(heads[head] ?? 0, tokens.count)
        }
        self.forms = forms
        self.heads = heads
    }

    func kind(of text: String) -> Kind? { forms[TypingLookup.normalize(text)] }

    func scan(_ text: String) -> [Mark] {
        guard !forms.isEmpty, !text.isEmpty else { return [] }
        let tokens = TypingLookup.tokenize(text)
        var normalized: [Substring: String] = [:]
        var marks: [Mark] = []
        var i = 0
        while i < tokens.count {
            let raw = text[tokens[i]]
            let head: String
            if let known = normalized[raw] { head = known } else {
                head = TypingLookup.normalize(String(raw))
                normalized[raw] = head
            }
            var taken = 0
            if let longest = heads[head] {
                for k in stride(from: min(longest, tokens.count - i), through: 1, by: -1) {
                    let start = tokens[i].lowerBound, end = tokens[i + k - 1].upperBound
                    let form = k == 1 ? head : TypingLookup.normalize(String(text[start..<end]))
                    guard let kind = forms[form], TypingLookup.tokenize(form).count == k else { continue }
                    let offset = { (index: String.Index) in index.utf16Offset(in: text) }
                    marks.append(Mark(start: offset(start), end: offset(end), kind: kind,
                                      words: tokens[i..<(i + k)].map { offset($0.lowerBound)..<offset($0.upperBound) }))
                    taken = k
                    break
                }
            }
            i += taken > 0 ? taken : 1
        }
        return marks
    }
}
