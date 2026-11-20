import Foundation

@main
struct CoreTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try RelayCore.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        var passed = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ description: String) throws {
            guard try condition() else { throw RelayError.message("FAIL: \(description)") }
            passed += 1
            print("PASS: \(description)")
        }
        let input = root.appendingPathComponent("输入/客户 群聊 #1%.txt")
        try RelayCore.privateDirectory(input.deletingLastPathComponent())
        let payload = Data("2026-11-02 张三：周五交付；李四：待确认。\nUnicode 😀 & ? # % +\n".utf8)
        try payload.write(to: input)
        let text = "客户：交付日期是周五。\n开发：需要确认接口。"
        let prompt = "总结 & 待办？ # + % 中文 😀"
        let shared = try RelayCore.makeMessage(prompt: prompt, text: text, files: [input, input], at: root)
        try check(shared.copiedFiles.count == 2 && shared.copiedFiles[0] != shared.copiedFiles[1], "同名附件保持独立")
        for file in shared.copiedFiles { try check(Data(contentsOf: file) == payload, "附件字节完整") }
        try check(shared.text.contains(text) && shared.text.contains(prompt), "中文文字和提示词完整")
        try check(!shared.text.contains(shared.copiedFiles[0].path), "附件不以路径文字出现在消息里")
        let raw = try RelayCore.makeMessage(prompt: RelayPreferences.prompts["raw"]!, text: "  " + text + "\n", files: [], at: root)
        try check(raw.text == text && raw.folder == nil, "仅原文模式不附加任何文字")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sessions").path), "不再为每次分享新建 Codex 项目目录")
        let zip = root.appendingPathComponent("聊天记录_20261102.zip")
        try payload.write(to: zip)
        let record = try RelayCore.makeMessage(prompt: "", text: "", files: [zip], at: root)
        try check(record.copiedFiles.count == 1 && record.text.isEmpty && Data(contentsOf: record.copiedFiles[0]) == payload, "微信聊天记录压缩包原样作为附件")
        let attrs = try FileManager.default.attributesOfItem(atPath: shared.copiedFiles[0].path)
        try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "本地内容仅当前用户可读")
        do { _ = try RelayCore.makeMessage(prompt: prompt, text: "  \n", files: [], at: root); throw RelayError.message("空内容未拒绝") }
        catch RelayError.message(let message) { try check(message.contains("请先"), "拒绝空内容") }
        let symlink = root.appendingPathComponent("symlink.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        do { _ = try RelayCore.checkedSize(of: symlink); throw RelayError.message("符号链接未拒绝") }
        catch RelayError.message(let message) { try check(message.contains("普通文件"), "拒绝符号链接附件") }
        let id = UUID()
        let inbox = root.appendingPathComponent("Inbox/\(id.uuidString)")
        let staged = try RelayCore.copyFile(input, into: inbox)
        _ = try RelayCore.saveRequest(text: text, files: [staged], id: id, target: .claude, at: root)
        let (request, loadedFiles) = try RelayCore.loadRequest(id, at: root)
        try check(request.text == text && Data(contentsOf: loadedFiles[0]) == payload, "分享扩展和主程序交接完整")
        try check(request.target == .claude, "分享入口的目标应用随请求传递")
        let legacyRequest = #"{"version":1,"id":"\#(id.uuidString)","createdAt":0,"text":"","files":[]}"#
        try check(try JSONDecoder().decode(SharedRequest.self, from: Data(legacyRequest.utf8)).target == nil, "旧分享记录仍可读取")
        try check(RelayCore.receiveID(from: URL(string: "wechatlite://receive/\(id.uuidString)")!) == id, "接收合法分享请求")
        try check(RelayCore.receiveID(from: URL(string: "wechatlite://receive/../preferences.json")!) == nil, "拒绝伪造路径请求")
        let malicious = SharedRequest(version: 1, id: id, createdAt: Date(), text: "", files: ["../preferences.json"])
        try JSONEncoder().encode(malicious).write(to: inbox.appendingPathComponent("request.json"))
        do { _ = try RelayCore.loadRequest(id, at: root); throw RelayError.message("路径穿越未拒绝") }
        catch RelayError.message(let message) { try check(message.contains("名称无效"), "拒绝附件路径穿越") }
        var prefs = RelayPreferences()
        prefs.preset = "custom"; prefs.customPrompt = prompt; prefs.openDraftAfterSharing = false
        prefs.setShows(.codex, false)
        try RelayCore.savePreferences(prefs, at: root)
        let restored = RelayCore.preferences(at: root)
        try check(restored.prompt == prompt && !restored.openDraftAfterSharing, "提示词和偏好可恢复")
        try check(!restored.shows(.codex) && restored.shows(.claude), "分享入口勾选可恢复")
        let legacy = #"{"customPrompt":"x","openDraftAfterSharing":true,"preset":"summary"}"#
        try Data(legacy.utf8).write(to: root.appendingPathComponent("preferences.json"))
        try check(RelayCore.preferences(at: root).preset == "raw", "旧版偏好升级为仅原文")
        try check(!RelayCore.preferences(at: root).showInDock, "旧版偏好默认不常驻 Dock")
        try check(RelayTarget.allCases.allSatisfy(RelayCore.preferences(at: root).shows), "旧版偏好默认显示全部分享入口")
        print("\(passed) meaningful checks passed.")
    }
}
