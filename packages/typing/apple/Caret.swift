// what is just before the text cursor of a field, which decides whether the offer shows: the
// offer follows the cursor, so it finds a word typed a moment ago and a word that was already
// there in the same way.
//
// - a web field (chromium: electron apps) answers through text markers, which are positions in
//   the page: its character ranges run two paragraphs together. a native field answers for
//   character ranges.
// - only the cursor's own paragraph is read, at most `CaretReader.reach` characters of it, and
//   nothing is kept after the answer.
import ApplicationServices
import Foundation

enum CaretReading: Equatable {
    /// the field does not say where its cursor is or what is before it
    case unknown
    /// the field says, and there is nothing to offer: text is selected, or the cursor is inside a word
    case nothing
    /// the text before the cursor, and the cursor's box when the field draws one
    case text(before: String, box: CGRect?)
}

enum CaretReader {
    /// the longest phrase in a library is a few words: this many characters hold it
    static let reach = 240

    static func read(_ element: AXUIElement) -> CaretReading {
        let reading = byMarkers(element) ?? byRange(element) ?? .unknown
        guard case .text(let before, _) = reading else { return reading }
        return .text(before: before, box: AX.selectionBox(element))
    }

    /// a letter, a digit, or a mark that joins two word parts: the cursor is not at a word's end
    private static func continuesWord(_ after: String?) -> Bool {
        guard let first = after?.first else { return false }
        return TypingLookup.isWordChar(first) || TypingLookup.joiners.contains(first)
    }

    /// the paragraph's last line of `text`, at most `reach` characters
    private static func tail(_ text: String) -> String {
        let line = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return String(line.suffix(reach))
    }

    /// text markers are positions in a page, so a paragraph's start and the cursor bound exactly
    /// the text between them, whatever the field counts as a character
    private static func byMarkers(_ element: AXUIElement) -> CaretReading? {
        guard let selection = AX.attribute(element, "AXSelectedTextMarkerRange"), CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() else { return nil }
        if let length = AX.parameterized(element, "AXLengthForTextMarkerRange", selection) as? Int, length > 0 { return .nothing }
        let caret = AXTextMarkerRangeCopyStartMarker(selection as! AXTextMarkerRange)
        func string(from start: AXTextMarker, to end: AXTextMarker) -> String? {
            AX.parameterized(element, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(kCFAllocatorDefault, start, end)) as? String
        }
        guard let paragraph = AX.parameterized(element, "AXParagraphTextMarkerRangeForTextMarker", caret), CFGetTypeID(paragraph) == AXTextMarkerRangeGetTypeID(),
              let before = string(from: AXTextMarkerRangeCopyStartMarker(paragraph as! AXTextMarkerRange), to: caret) else { return nil }
        if let next = AX.parameterized(element, "AXNextTextMarkerForTextMarker", caret), CFGetTypeID(next) == AXTextMarkerGetTypeID(),
           continuesWord(string(from: caret, to: next as! AXTextMarker)) { return .nothing }
        return .text(before: tail(before), box: nil)
    }

    private static func byRange(_ element: AXUIElement) -> CaretReading? {
        // a web rich text field has its text in child nodes, and its ranges join two paragraphs
        // with nothing between them: without markers there is no safe answer
        if let children = AX.attribute(element, kAXChildrenAttribute) as? [AXUIElement], !children.isEmpty { return nil }
        guard let selected = AX.range(AX.attribute(element, kAXSelectedTextRangeAttribute)), selected.location != kCFNotFound else { return nil }
        guard selected.length == 0 else { return .nothing }
        let start = max(selected.location - reach, 0)
        guard selected.location > start else { return .text(before: "", box: nil) }
        guard let span = AX.value(CFRange(location: start, length: selected.location - start)),
              let before = AX.parameterized(element, kAXStringForRangeParameterizedAttribute, span) as? String else { return nil }
        if let one = AX.value(CFRange(location: selected.location, length: 1)),
           continuesWord(AX.parameterized(element, kAXStringForRangeParameterizedAttribute, one) as? String) { return .nothing }
        return .text(before: tail(before), box: nil)
    }
}
