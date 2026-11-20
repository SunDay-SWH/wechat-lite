import Foundation

private struct FakeTree: InputTree {
    struct Item {
        var info: InputNodeInfo
        var children: [Int] = []
    }
    var items: [Int: Item]
    var complete = true
    func info(_ node: Int) -> InputNodeInfo { items[node]?.info ?? InputNodeInfo(role: "") }
    func children(_ node: Int) -> [Int] { items[node]?.children ?? [] }
}

@main
struct InputFocusTests {
    static func main() throws {
        var passed = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw RelayError.message("FAIL: \(message)") }
            passed += 1
            print("PASS: \(message)")
        }
        func node(_ role: String, _ markers: [String] = [], children: [Int] = [],
                  focused: Bool = false, enabled: Bool = true) -> FakeTree.Item {
            .init(info: InputNodeInfo(role: role, markers: markers, enabled: enabled, focused: focused), children: children)
        }
        var tree = FakeTree(items: [
            0: node("AXWindow", children: [1, 2, 3]),
            1: node("AXTextField", ["Search"], focused: true),
            2: node("AXTextArea", ["xterm-helper-textarea"]),
            3: node("AXTextArea", ["tiptap", "ProseMirror"])
        ])
        try check(ComposerSearch.find(in: 0, tree: tree) == 3, "聚焦搜索框时仍选择聊天编辑器")
        // No app-wide focused element is supplied: searching starts from the known window.
        tree.items[1] = node("AXTextField", ["Search"])
        try check(ComposerSearch.find(in: 0, tree: tree) == 3, "应用级焦点为空时仍从窗口找到输入框")
        tree.items[3] = node("AXGroup", ["chat-composer"], children: [4])
        tree.items[4] = node("AXTextArea")
        try check(ComposerSearch.find(in: 0, tree: tree) == 4, "识别聊天容器内没有标签的编辑器")
        tree.items[3] = node("AXGroup", ["terminal-composer"], children: [4])
        try check(ComposerSearch.find(in: 0, tree: tree) == nil, "排除终端容器内的编辑器")
        tree.items[3] = node("AXTextArea")
        try check(ComposerSearch.find(in: 0, tree: tree) == nil, "不猜测普通文本框是否为聊天输入框")
        tree.items[3] = node("AXTextArea", ["输入消息"], enabled: false)
        try check(ComposerSearch.find(in: 0, tree: tree) == nil, "不选择禁用的聊天输入框")
        tree.items[3] = node("AXTextArea", ["输入消息"])
        try check(ComposerSearch.find(in: 0, tree: tree) == 3, "识别中文聊天输入标签")
        tree.items[0] = node("AXWindow", children: [3, 4])
        tree.items[3] = node("AXTextArea", ["ProseMirror"])
        tree.items[4] = node("AXTextArea", ["ProseMirror"])
        try check(ComposerSearch.find(in: 0, tree: tree) == nil, "两个同等候选编辑器时不猜测")
        tree.items[4] = node("AXTextArea", ["ProseMirror"], focused: true)
        try check(ComposerSearch.find(in: 0, tree: tree) == 4, "多个聊天编辑器时优先已聚焦的编辑器")
        tree.items[3] = node("AXTextArea", ["Prompt"])
        try check(ComposerSearch.find(in: 0, tree: tree) == 3, "明确的聊天输入标签优先于其他富文本编辑器")
        tree.items[3] = node("AXTextArea", ["输入消息"])
        tree.items[4] = node("AXTextArea", ["输入消息"], focused: true)
        tree.complete = false
        try check(ComposerSearch.find(in: 0, tree: tree) == nil, "辅助功能遍历超时或失败时不使用不完整结果")
        tree.complete = true
        try check(ComposerSearch.find(in: 0, tree: tree, limit: 1) == nil, "遍历节点达到限制时不使用截断结果")
        try check(ComposerSearch.find(in: 0, tree: tree, limit: 2) == nil, "达到节点上限不能漏掉另一个候选后误选输入框")
        tree.items[0] = node("AXGroup", children: [0])
        try check(ComposerSearch.find(in: 0, tree: tree, limit: 10) == nil, "循环树能在限制内结束")
        // Claude/Codex expose the chat/session name as the web area's title.
        let titled = FakeTree(items: [
            0: node("AXWindow", ["Claude"], children: [1]),
            1: node("AXWebArea", ["修复搜索和终端问题 - Claude Code"], children: [2, 3]),
            2: node("AXGroup", ["xterm"], children: [4]),
            3: node("AXGroup", ["Primary pane"], children: [5]),
            4: node("AXTextArea", ["Terminal input"]),
            5: node("AXTextArea", ["Prompt", "tiptap", "ProseMirror"])
        ])
        try check(ComposerSearch.find(in: 0, tree: titled) == 5, "会话标题含“搜索/终端”时仍找到聊天输入框")
        var replyTitled = titled
        replyTitled.items[1] = node("AXWebArea", ["Reply to prompt"], children: [3])
        replyTitled.items[5] = node("AXTextArea")
        try check(ComposerSearch.find(in: 0, tree: replyTitled) == nil, "会话标题含“reply/prompt”时不把普通文本框当输入框")
        // Real Claude layout: composer at depth ~35, a task list nested deeper than 40 levels.
        var deep = FakeTree(items: [0: node("AXWindow", children: [1])])
        for level in 1..<35 { deep.items[level] = node("AXGroup", children: [level + 1]) }
        deep.items[35] = node("AXGroup", children: [36, 100])
        deep.items[36] = node("AXTextArea", ["Prompt", "ProseMirror"])
        for level in 100..<110 { deep.items[level] = node("AXGroup", children: [level + 1]) }
        deep.items[110] = node("AXButton")
        try check(ComposerSearch.find(in: 0, tree: deep) == 36, "页面层级超过 40 层时仍找到聊天输入框")
        var retry = FocusRetryPolicy()
        try check(!retry.shouldAttempt(at: 0.1) && retry.shouldAttempt(at: 0.4), "首次对焦等待窗口就绪")
        try check(!retry.shouldAttempt(at: 0.8) && retry.shouldAttempt(at: 1.1)
                  && retry.shouldAttempt(at: 2.0) && retry.shouldAttempt(at: 4.0), "首次对焦失败后持续重试")
        try check(!retry.shouldAttempt(at: retry.timeout), "对焦重试有总时限")
        var quick = FocusRetryPolicy()
        _ = quick.shouldAttempt(at: 0.4)
        quick.retrySoon(at: 0.4)
        try check(!quick.shouldAttempt(at: 0.5) && quick.shouldAttempt(at: 0.65), "网页辅助树未就绪时快速重试")
        print("\(passed) input focus checks passed; no UI was accessed or messages sent.")
    }
}
