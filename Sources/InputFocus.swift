import AppKit

/// Only metadata is inspected: never read or log the user's draft or transcript.
struct InputNodeInfo {
    var role: String
    var markers: [String] = []
    var enabled = true
    var focused = false

    var isEditor: Bool { ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) }
    var isOtherInput: Bool { otherInputKeyword != nil }
    /// The fixed keyword that matched (safe to log), never the marker text itself.
    var otherInputKeyword: String? {
        let value = markers.joined(separator: " ").lowercased()
        return ["search", "搜索", "查找", "terminal", "终端", "xterm", "monaco", "code-editor",
                "comment text", "批注", "edit instruction", "document-editor"]
            .first(where: value.contains)
    }
    var isComposer: Bool {
        let value = markers.joined(separator: " ").lowercased()
        return ["prosemirror", "tiptap", "composer", "prompt", "message-input", "chat-input",
                "ask anything", "reply", "发消息", "发送消息", "输入消息", "提问", "追问"]
            .contains(where: value.contains)
    }
}

protocol InputTree {
    associatedtype Node
    func info(_ node: Node) -> InputNodeInfo
    func children(_ node: Node) -> [Node]
    var complete: Bool { get }
}

extension InputTree { var complete: Bool { true } }

enum ComposerSearch {
    static let maxDepth = 150
    /// A generic text area might be a terminal or a search result. Require composer metadata,
    /// including metadata on a surrounding composer container, and reject ambiguous editors.
    /// `report` receives a metadata-only summary (roles, scores, fixed keywords) for the debug log.
    static func find<T: InputTree>(in root: T.Node, tree: T, limit: Int = 2000,
                                   report: ((String) -> Void)? = nil) -> T.Node? {
        var notes: [String] = []
        var queue: [(T.Node, Bool, Int)] = [(root, false, 0)]
        var index = 0
        var best: T.Node?
        var bestScore = 0
        var tied = false
        var truncated = false
        while index < queue.count && index < limit {
            let (node, inComposer, depth) = queue[index]
            index += 1
            let info = tree.info(node)
            guard !["AXDialog", "AXSheet", "AXMenu"].contains(info.role) else {
                notes.append("skip \(info.role)"); continue
            }
            // A window's or web area's title is the document title, i.e. the user's chat/session name
            // ("修复搜索…", "terminal …"). It says nothing about the containers inside, so ignore its words.
            let neutral = ["AXWindow", "AXWebArea"].contains(info.role)
            guard info.enabled else {
                if info.isEditor { notes.append("disabled \(info.role)") }
                continue
            }
            if !neutral, let keyword = info.otherInputKeyword {
                // Toggle buttons such as "Terminal" are expected; containers and editors explain a miss.
                if !["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
                     "AXStaticText"].contains(info.role) { notes.append("skip \(info.role)[\(keyword)]") }
                continue
            }
            let composer = inComposer || (!neutral && info.isComposer)
            if info.isEditor && composer {
                let explicit = info.markers.contains { marker in
                    ["composer", "prompt", "输入消息", "发送消息"].contains(where: marker.lowercased().contains)
                }
                let score = (explicit ? 200 : info.isComposer ? 100 : 50) + (info.focused ? 10 : 0)
                notes.append("\(info.role)=\(score)")
                if score > bestScore { best = node; bestScore = score; tied = false }
                else if score == bestScore { tied = true }
            } else if info.isEditor { notes.append("\(info.role)=plain") }
            // Claude's composer alone sits ~35 levels deep and its task lists go past 40, so a tight
            // depth cap marked normal pages "incomplete". The node limit and deadline bound the work.
            if depth < ComposerSearch.maxDepth {
                // Bound memory as well as the number of nodes read from an untrusted AX tree.
                let children = tree.children(node)
                let available = max(0, limit - queue.count)
                if children.count > available { truncated = true }
                for child in children.prefix(available) {
                    queue.append((child, composer, depth + 1))
                }
            } else if !tree.children(node).isEmpty { truncated = true }
        }
        // A truncated tree can hide a second editor. Do not guess in that case.
        let incomplete = truncated || index != queue.count || !tree.complete
        if let report {
            let outcome = best == nil ? "none" : tied ? "tied" : incomplete ? "incomplete" : "ok"
            report("\(outcome) [\(notes.prefix(12).joined(separator: ", "))\(notes.count > 12 ? ", …" : "")]")
        }
        return !tied && !incomplete ? best : nil
    }
}

struct FocusRetryPolicy {
    let timeout: TimeInterval = 6
    private var nextAttempt: TimeInterval = 0.35
    mutating func shouldAttempt(at elapsed: TimeInterval) -> Bool {
        guard elapsed < timeout, elapsed >= nextAttempt else { return false }
        nextAttempt = elapsed + 0.65
        return true
    }
    /// Electron builds its web accessibility tree only after we enable it; while the tree is still a
    /// near-empty shell, poll quickly instead of waiting the normal interval.
    mutating func retrySoon(at elapsed: TimeInterval) {
        nextAttempt = min(nextAttempt, elapsed + 0.2)
    }
}

@MainActor
final class InputFocusSession {
    let app: NSRunningApplication
    private let root: AXUIElement
    private var editor: AXUIElement?
    private var lastDiagnostic = ""
    /// True when the last search saw only the native window shell (web content not exposed yet).
    private(set) var treeLooksUnready = false

    init(app: NSRunningApplication) {
        self.app = app
        root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        // Electron can expose a window before it has enabled its web accessibility tree.
        // Enable once per delivery, rather than resetting it on every 100 ms focus poll.
        let manual = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        RelayCore.debug("focus: pid=\(app.processIdentifier) manualAX=\(manual.rawValue) enhancedAX=\(enhanced.rawValue)")
    }

    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private func read(_ node: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(node, name as CFString, &value)
        return (value, error)
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func currentWindow() -> AXUIElement? {
        if let window = element(read(root, kAXFocusedWindowAttribute as String).0) { return window }
        if let window = element(read(root, kAXMainWindowAttribute as String).0) { return window }
        let windows = read(root, kAXWindowsAttribute as String).0 as? [AXUIElement] ?? []
        // With no focused/main window, multiple windows give us no safe target.
        return windows.count == 1 ? windows[0] : nil
    }

    private func hasModal(in window: AXUIElement) -> Bool {
        if !(read(window, "AXSheets").0 as? [AXUIElement] ?? []).isEmpty { return true }
        return (read(window, kAXModalAttribute as String).0 as? Bool) == true
    }

    private func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }

    /// App-wide AXFocusedUIElement may be unavailable even though the window's editor is
    /// accessible. Confirm the actual composer element instead of requiring that app attribute.
    func isReady() -> Bool {
        guard isFrontmost, let window = currentWindow(), !hasModal(in: window), let editor else { return false }
        if let owner = element(read(editor, kAXWindowAttribute as String).0), !same(owner, window) { return false }
        let (focused, _) = read(root, kAXFocusedUIElementAttribute as String)
        if let focused = element(focused), same(focused, editor) { return true }
        let (windowFocused, _) = read(window, kAXFocusedUIElementAttribute as String)
        if let focused = element(windowFocused), same(focused, editor) { return true }
        return (read(editor, kAXFocusedAttribute as String).0 as? Bool) == true
    }

    func focusComposer() -> Bool {
        guard isFrontmost, let window = currentWindow(), !hasModal(in: window) else {
            editor = nil
            diagnose("no usable front window")
            return false
        }
        let tree = MacInputTree(read: { [self] node, name in read(node, name).0 })
        let started = Date()
        // An already focused composer needs no full walk through a long conversation.
        for owner in [root, window] {
            if let focused = element(read(owner, kAXFocusedUIElementAttribute as String).0) {
                let info = tree.info(focused)
                if info.enabled && info.isEditor && info.isComposer && !info.isOtherInput {
                    editor = focused
                    if isReady() { return true }
                }
            }
        }
        var summary = ""
        let found = ComposerSearch.find(in: window, tree: tree, report: { summary = $0 })
        treeLooksUnready = found == nil && tree.visited < 40
        guard let found else {
            editor = nil
            let (_, focusError) = read(root, kAXFocusedUIElementAttribute as String)
            diagnose("composer not found: \(summary) appFocusAX=\(focusError.rawValue) nodes=\(tree.visited) complete=\(tree.complete)")
            return false
        }
        editor = found
        if isReady() { return true }
        let result = AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        diagnose("set composer focus AX=\(result.rawValue) nodes=\(tree.visited) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return result == .success && isReady()
    }

    private func diagnose(_ value: String) {
        guard value != lastDiagnostic else { return }
        lastDiagnostic = value
        RelayCore.debug("focus: \(value)")
    }
}

private final class MacInputTree: InputTree {
    typealias Node = AXUIElement
    private let read: (AXUIElement, String) -> CFTypeRef?
    private let deadline = Date().addingTimeInterval(0.8)
    private(set) var visited = 0
    private(set) var complete = true
    init(read: @escaping (AXUIElement, String) -> CFTypeRef?) { self.read = read }

    func info(_ node: AXUIElement) -> InputNodeInfo {
        visited += 1
        guard Date() < deadline else { complete = false; return InputNodeInfo(role: "", enabled: false) }
        let names = [kAXRoleAttribute as String, kAXEnabledAttribute as String, kAXFocusedAttribute as String,
                     kAXIdentifierAttribute as String, kAXDescriptionAttribute as String,
                     kAXTitleAttribute as String, kAXHelpAttribute as String,
                     "AXPlaceholderValue", "AXDOMIdentifier", "AXDOMClassList"]
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(node, names as CFArray,
                                                            AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard result == .success, let attributes = values as? [Any], attributes.count == names.count else {
            complete = false
            return InputNodeInfo(role: "", enabled: false)
        }
        let markers = attributes[3..<9].compactMap { $0 as? String } + (attributes[9] as? [String] ?? [])
        return InputNodeInfo(role: attributes[0] as? String ?? "", markers: markers,
                             enabled: (attributes[1] as? Bool) != false, focused: (attributes[2] as? Bool) == true)
    }

    func children(_ node: AXUIElement) -> [AXUIElement] {
        guard Date() < deadline else { complete = false; return [] }
        let children = (read(node, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
        // Some web accessibility roots publish AXContents while AXChildren is still empty.
        return children.isEmpty ? (read(node, kAXContentsAttribute as String) as? [AXUIElement] ?? []) : children
    }
}
