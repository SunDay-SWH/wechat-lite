import Foundation
import Darwin

enum RelayError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct SharedRequest: Codable {
    let version: Int
    let id: UUID
    let createdAt: Date
    let text: String
    let files: [String]
    /// Absent in requests written before the Claude entry existed; those went to Codex.
    var target: RelayTarget? = nil
}

/// Where a share goes. Each one has its own share-menu entry, all built from one binary.
enum RelayTarget: String, Codable, CaseIterable {
    case codex
    case claude
    /// Only puts the share on the clipboard, for pasting anywhere (e.g. a Terminal turns files into paths).
    case copy

    /// Read from the share extension's Info.plist, so one binary serves every share-menu entry.
    static let infoKey = "WeChatLiteTarget"

    /// The desktop app pasted into; nil for the clipboard-only entry.
    var bundleID: String? {
        switch self {
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .copy: return nil
        }
    }

    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .copy: return "仅复制"
        }
    }

    /// Title of the share sheet this entry opens.
    var shareTitle: String { bundleID == nil ? "微信轻转 · 复制到剪贴板" : "微信轻转 · 发给 \(name)" }

    /// The Codex entry keeps the original extension ID so its share-menu enablement survives upgrades.
    var extensionID: String { self == .codex ? RelayCore.extensionID : RelayCore.extensionID + "." + rawValue }
}

struct RelayPreferences: Codable {
    var preset = "raw"
    var customPrompt = "阅读这些聊天记录和附件，整理关键事实、结论和下一步。信息不足的地方请明确说明。"
    var openDraftAfterSharing = true
    /// Off: the Dock icon is shown only while the settings window is open.
    var showInDock = false
    /// Targets whose entry is hidden from the share menu; stored as the hidden ones so new targets start shown.
    var hiddenTargets: [RelayTarget] = []
    var schema = 2
    static let prompts = [
        "raw": "",
        "summary": "请总结这些微信聊天记录和附件，按主题整理关键事实、结论和需要关注的问题。保留重要日期、数字和人名，不要补充原文没有的信息。",
        "tasks": "请从这些微信聊天记录和附件中提取待办，列出：事项、负责人、截止时间、当前状态。未提到的负责人或时间写“未明确”，最后列出需要确认的问题。"
    ]
    var prompt: String { Self.prompts[preset] ?? customPrompt }

    func shows(_ target: RelayTarget) -> Bool { !hiddenTargets.contains(target) }

    mutating func setShows(_ target: RelayTarget, _ shown: Bool) {
        hiddenTargets.removeAll { $0 == target }
        if !shown { hiddenTargets.append(target) }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? customPrompt
        openDraftAfterSharing = try c.decodeIfPresent(Bool.self, forKey: .openDraftAfterSharing) ?? openDraftAfterSharing
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? showInDock
        hiddenTargets = (try? c.decodeIfPresent([RelayTarget].self, forKey: .hiddenTargets)) ?? hiddenTargets
        // Version 1 always wrapped shares in a summary prompt; start upgraded installs on the plain original text.
        if try c.decodeIfPresent(Int.self, forKey: .schema) == 2 {
            preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? preset
        }
    }
}

struct ShareMessage {
    let text: String
    let folder: URL?
    let copiedFiles: [URL]
}

enum RelayCore {
    static let appID = "local.sunwenhao.wechatlite"
    static let extensionID = appID + ".share"
    static let maximumFiles = 32
    static let maximumFileBytes: Int64 = 200 * 1024 * 1024
    static let maximumTotalBytes: Int64 = 500 * 1024 * 1024
    static let maximumTextBytes = 4 * 1024 * 1024

    static var root: URL {
        // NSHomeDirectory() points into the sandbox when called by the share extension.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/WeChatLite", isDirectory: true)
    }

    static func debug(_ line: String) {
        let url = root.appendingPathComponent("debug.log")
        let entry = Data("\(Date()) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) { handle.seekToEndOfFile(); handle.write(entry); try? handle.close() }
        else { try? writePrivate(entry, to: url) }
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func preferences(at root: URL = root) -> RelayPreferences {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("preferences.json")),
              let value = try? JSONDecoder().decode(RelayPreferences.self, from: data) else { return RelayPreferences() }
        return value
    }

    static func savePreferences(_ value: RelayPreferences, at root: URL = root) throws {
        try privateDirectory(root)
        try writePrivate(JSONEncoder().encode(value), to: root.appendingPathComponent("preferences.json"))
    }

    /// Paths as a shell would accept them, space-separated, for pasting into a terminal.
    static func shellQuoted(_ urls: [URL]) -> String {
        urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }

    static func safeName(_ name: String) -> String {
        let bad = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let clean = name.components(separatedBy: bad).joined(separator: "_")
        let result = String(clean.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? "附件" : result
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        let clean = safeName(name)
        var target = folder.appendingPathComponent(clean)
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        var index = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
            index += 1
        }
        return target
    }

    static func checkedSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RelayError.message("“\(url.lastPathComponent)”不是普通文件。请先把文件夹压缩后再分享。")
        }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maximumFileBytes else { throw RelayError.message("“\(url.lastPathComponent)”超过 200 MB，请缩小后再分享。") }
        return size
    }

    @discardableResult
    static func copyFile(_ source: URL, into folder: URL, name: String? = nil) throws -> URL {
        _ = try checkedSize(of: source)
        try privateDirectory(folder)
        let target = uniqueURL(in: folder, name: name ?? source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    static func saveRequest(text: String, files: [URL], id: UUID, target: RelayTarget = .codex, at root: URL = root) throws -> URL {
        guard text.utf8.count <= maximumTextBytes else { throw RelayError.message("分享的文字超过 4 MB，请改为文件分享。") }
        guard files.count <= maximumFiles else { throw RelayError.message("一次最多分享 32 个文件。") }
        var total: Int64 = 0
        for file in files { total += try checkedSize(of: file) }
        guard total <= maximumTotalBytes else { throw RelayError.message("附件总大小超过 500 MB，请分批分享。") }
        let folder = root.appendingPathComponent("Inbox/\(id.uuidString)", isDirectory: true)
        try privateDirectory(folder)
        // The extension has already copied provider-owned temporary files here.
        let canonicalFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        for file in files {
            guard file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == canonicalFolder else {
                throw RelayError.message("分享附件的保存位置无效。")
            }
        }
        let request = SharedRequest(version: 1, id: id, createdAt: Date(), text: text, files: files.map(\.lastPathComponent), target: target)
        try writePrivate(JSONEncoder().encode(request), to: folder.appendingPathComponent("request.json"))
        return folder
    }

    static func loadRequest(_ id: UUID, at root: URL = root) throws -> (SharedRequest, [URL]) {
        let folder = root.appendingPathComponent("Inbox/\(id.uuidString)", isDirectory: true)
        let data = try Data(contentsOf: folder.appendingPathComponent("request.json"))
        guard data.count <= maximumTextBytes + 64 * 1024 else { throw RelayError.message("分享记录过大，无法打开。") }
        let request = try JSONDecoder().decode(SharedRequest.self, from: data)
        guard request.version == 1, request.id == id, request.files.count <= maximumFiles else {
            throw RelayError.message("分享记录的格式不受支持。")
        }
        let files = try request.files.map { name -> URL in
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
                throw RelayError.message("分享记录中的附件名称无效。")
            }
            let url = folder.appendingPathComponent(name)
            _ = try checkedSize(of: url)
            return url
        }
        return (request, files)
    }

    static func receiveID(from url: URL) -> UUID? {
        guard url.scheme == "wechatlite", url.host == "receive", url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count == 1 ? UUID(uuidString: parts[0]) : nil
    }

    static func makeMessage(prompt: String, text: String, files: [URL], at root: URL = root) throws -> ShareMessage {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else {
            throw RelayError.message("请先分享、拖入文件，或粘贴聊天内容。")
        }
        guard text.utf8.count <= maximumTextBytes else { throw RelayError.message("文字超过 4 MB，请改为文件添加。") }
        guard files.count <= maximumFiles else { throw RelayError.message("一次最多添加 32 个文件。") }
        var total: Int64 = 0
        for file in files { total += try checkedSize(of: file) }
        guard total <= maximumTotalBytes else { throw RelayError.message("附件总大小超过 500 MB，请分批添加。") }
        var parts: [String] = []
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty { parts.append(instruction) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        guard !files.isEmpty else { return ShareMessage(text: parts.joined(separator: "\n\n"), folder: nil, copiedFiles: []) }
        // Attachments still need a stable local copy, but no per-share Codex project is created any more.
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let folder = uniqueURL(in: root.appendingPathComponent("Files", isDirectory: true), name: stamp)
        try privateDirectory(folder)
        do {
            let copied = try files.map { try copyFile($0, into: folder) }
            return ShareMessage(text: parts.joined(separator: "\n\n"), folder: folder, copiedFiles: copied)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
