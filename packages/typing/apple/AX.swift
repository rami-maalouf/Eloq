// the accessibility calls of the package, in one place.
//
// - every call answers nil when the other app does not say, so a caller reads one optional and
//   never an error code.
// - no call waits longer than `AX.patience` for an app that is busy, once `AX.bePatient` has
//   run: a late answer costs one reading. no call is made on the key tap's thread.
// - boxes are in accessibility coordinates (the origin is the primary screen's top left) until
//   `AX.appKit` turns one into appkit's (bottom left).
import AppKit
import ApplicationServices

enum AX {
    /// how long one call waits for the other app, in seconds
    static let patience: Float = 0.25
    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    /// the limit for every accessibility call of this process, which the system-wide element sets
    static func bePatient() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), patience)
    }

    // MARK: reading

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }

    /// several attributes of an element in one round trip; nil where the element has none
    static func attributes(_ element: AXUIElement, _ names: [String]) -> [CFTypeRef?] {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success,
              let list = values as? [AnyObject], list.count == names.count else { return names.map { _ in nil } }
        return list.map { value in
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value is NSNull ? nil : value
        }
    }

    // MARK: values

    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    static func rect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func value(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    /// an accessibility box in appkit screen coordinates; `primaryHeight` is the first screen's
    static func appKit(_ box: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(x: box.minX, y: primaryHeight - box.maxY, width: box.width, height: box.height)
    }

    // MARK: elements

    /// the element's box
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(attribute(element, kAXPositionAttribute)), let extent = size(attribute(element, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// the element that has the keyboard, in whichever app is in front
    static func focused() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, patience)
        return patient(element(attribute(system, kAXFocusedUIElementAttribute)))
    }

    /// the element that has the keyboard in one app
    static func focused(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, patience)
        return patient(element(attribute(app, kAXFocusedUIElementAttribute)))
    }

    private static func patient(_ element: AXUIElement?) -> AXUIElement? {
        if let element { AXUIElementSetMessagingTimeout(element, patience) }
        return element
    }

    /// electron's own switch for tools that read an app through accessibility: such an app builds
    /// its tree of the page only once this is set, and answers a moment later
    static func wakeElectron(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, patience)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    enum Field {
        /// not a text field, or the app does not say
        case none
        /// a password field or a search field: never read, and no offer there
        case closed
        /// text a person edits and eloq may read
        case open
    }

    /// what kind of field an element is. secure input covers password fields in practice; the
    /// role is the second look.
    static func field(_ element: AXUIElement) -> Field {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) { return .closed }
        guard textRoles.contains(role) else { return .none }
        return subrole == (kAXSearchFieldSubrole as String) ? .closed : .open
    }

    static func isReadableText(_ element: AXUIElement) -> Bool { field(element) == .open }

    /// where the selection, or the cursor, of a field is drawn. a native field answers for a
    /// character range; a web rich text field answers only for its text markers. a cursor with
    /// no selection has a box with no width.
    static func selectionBox(_ element: AXUIElement) -> CGRect? {
        func drawn(_ box: CGRect?) -> CGRect? {
            guard let box, box.height > 2, box.height < 200 else { return nil }
            return box
        }
        if let selected = range(attribute(element, kAXSelectedTextRangeAttribute)) {
            // the character before the cursor has a box when the cursor itself has none
            let probe = selected.length > 0 ? selected : CFRange(location: max(selected.location - 1, 0), length: selected.location > 0 ? 1 : 0)
            if let asked = value(probe), let box = drawn(rect(parameterized(element, kAXBoundsForRangeParameterizedAttribute, asked))) {
                return selected.length > 0 ? box : CGRect(x: box.maxX, y: box.minY, width: 0, height: box.height)
            }
        }
        if let markers = attribute(element, "AXSelectedTextMarkerRange") {
            return drawn(rect(parameterized(element, "AXBoundsForTextMarkerRange", markers)))
        }
        return nil
    }
}
