import AppKit

final class HarnessDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var picker: NSSharingServicePicker?
    let testFile = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory() + "微信轻转测试.txt")
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "这是微信轻转的本地测试文件，不是真实聊天记录。\n测试事项：周五交付；负责人：测试员。\n".write(to: testFile, atomically: true, encoding: .utf8)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "微信轻转分享测试"
        let label = NSTextField(wrappingLabelWithString: "验证 macOS 分享入口，只使用合成测试内容。")
        let file = NSButton(title: "分享测试文件", target: self, action: #selector(shareFile(_:)))
        let text = NSButton(title: "分享测试文字", target: self, action: #selector(shareText(_:)))
        let stack = NSStackView(views: [label, file, text])
        stack.orientation = .vertical; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor), stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func shareFile(_ sender: NSButton) {
        picker = NSSharingServicePicker(items: [testFile])
        picker!.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc func shareText(_ sender: NSButton) {
        picker = NSSharingServicePicker(items: ["分享入口纯文字测试：客户要求周五交付，负责人待确认。"])
        picker!.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = HarnessDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
