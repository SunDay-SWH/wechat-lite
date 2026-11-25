import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class RelayModel: ObservableObject {
    @Published var preferences = RelayCore.preferences()
    @Published var text = ""
    @Published var files: [URL] = []
    @Published var message = ""
    @Published var isError = false
    @Published var busy = false
    @Published var lastFolder: URL?
    @Published var autoPasteReady = AXIsProcessTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var failedTarget: RelayTarget?
    var presentDeliveryFailure: (() -> Void)?
    private var received = Set<UUID>()
    private var queuedShares: [URL] = []
    private var remainingDelivery: [Clip]?

    func save() {
        do { try RelayCore.savePreferences(preferences) }
        catch { fail("提示词未能保存：\(error.localizedDescription)") }
    }

    func status(_ value: String) { message = value; isError = false }
    func fail(_ value: String) { message = value; isError = true }

    private func deliveryFailed(_ value: String, target: RelayTarget) {
        failedTarget = target
        fail(value)
        RelayCore.debug("delivery: failed target=\(target.rawValue) reason=\(value)")
        presentDeliveryFailure?()
    }

    func receive(_ url: URL) {
        guard let id = RelayCore.receiveID(from: url), !received.contains(id) else { return }
        if busy { if !queuedShares.contains(url) { queuedShares.append(url) }; return }
        // One incoming share creates one draft, rather than silently mixing unrelated chats.
        do {
            let (request, incomingFiles) = try RelayCore.loadRequest(id)
            received.insert(id)
            remainingDelivery = nil
            failedTarget = nil
            text = request.text
            files = incomingFiles
            status("已收到微信分享：\(incomingFiles.count) 个文件。")
            send(to: request.target ?? .codex)
        } catch { fail("分享内容未能打开：\(error.localizedDescription)") }
    }

    private func finished() {
        busy = false
        if !queuedShares.isEmpty { receive(queuedShares.removeFirst()) }
    }

    func message() async throws -> ShareMessage {
        let prompt = preferences.prompt
        let content = text
        let attachments = files
        return try await Task.detached(priority: .userInitiated) {
            try RelayCore.makeMessage(prompt: prompt, text: content, files: attachments)
        }.value
    }

    /// Files go on the pasteboard as file URLs, so ⌘V in Codex adds them as attachment cards rather than path text.
    private enum Clip {
        case text(String)
        case files([URL])
    }

    private func clips(for shared: ShareMessage) -> [Clip] {
        var result: [Clip] = []
        if !shared.text.isEmpty { result.append(.text(shared.text)) }
        if !shared.copiedFiles.isEmpty { result.append(.files(shared.copiedFiles)) }
        return result
    }

    private func put(_ clip: Clip) throws {
        let board = NSPasteboard.general
        board.clearContents()
        let written: Bool
        switch clip {
        case .text(let value): written = board.setString(value, forType: .string)
        case .files(let urls): written = board.writeObjects(urls as [NSURL])
        }
        guard written else { throw RelayError.message("未能写入剪贴板，请重试。") }
    }

    /// Terminals ignore file URLs on paste and read only plain text, so the first item also carries the quoted
    /// paths: Finder and chat apps still take the files, a terminal gets the paths.
    private func putAnywhere(_ urls: [URL]) throws {
        let items = urls.enumerated().map { index, url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if index == 0 { item.setString(RelayCore.shellQuoted(urls), forType: .string) }
            return item
        }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.writeObjects(items) else { throw RelayError.message("未能写入剪贴板，请重试。") }
    }

    /// Pastes into whatever chat is open in the target app. Codex deep links can only prefill a brand-new thread
    /// (and `path=` creates a new project), so the clipboard is the only way to reach the current chat.
    func send(to target: RelayTarget) {
        guard !busy else { return }
        guard let bundleID = target.bundleID else { copyOnly(); return }
        guard let targetApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            deliveryFailed("没有找到 \(target.name) 桌面应用。请先安装它。", target: target); return
        }
        let retryPlan = failedTarget == target ? remainingDelivery : nil
        remainingDelivery = nil
        failedTarget = nil
        busy = true
        status("正在整理内容…")
        Task { @MainActor in
            do {
                let plan: [Clip]
                if let retryPlan { plan = retryPlan }
                else {
                    let shared = try await message()
                    if let folder = shared.folder { lastFolder = folder }
                    plan = clips(for: shared)
                }
                remainingDelivery = plan
                // Without auto-paste the user gets one manual ⌘V, so the attachment wins over the prompt text.
                try put(plan.last!)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: targetApp, configuration: config) { app, error in
                    Task { @MainActor in
                        guard let app, error == nil else {
                            self.deliveryFailed("无法打开 \(target.name)：\(error?.localizedDescription ?? "没有取得应用进程")。内容已复制，可手动粘贴。", target: target)
                            self.finished(); return
                        }
                        await self.paste(plan, into: target, app: app)
                        self.finished()
                    }
                }
            } catch { deliveryFailed(error.localizedDescription, target: target); finished() }
        }
    }

    /// The clipboard-only entry: no app is opened and nothing is typed, so it needs no Accessibility grant.
    /// Like a manual ⌘V elsewhere, the attachments win over the prompt text when both exist.
    private func copyOnly() {
        busy = true
        status("正在整理内容…")
        Task { @MainActor in
            defer { finished() }
            do {
                let shared = try await message()
                if let folder = shared.folder { lastFolder = folder }
                guard let clip = clips(for: shared).last else { throw RelayError.message("没有可复制的内容。") }
                if case .files(let urls) = clip { try putAnywhere(urls) } else { try put(clip) }
                RelayCore.debug("copy: wrote \(shared.copiedFiles.isEmpty ? "text" : "\(shared.copiedFiles.count) files")")
                status(shared.copiedFiles.isEmpty ? "文字已复制，到任意位置按 ⌘V 即可。"
                       : "\(shared.copiedFiles.count) 个文件已复制。在访达或聊天中粘贴为文件，在终端中粘贴为路径（⌘V）。")
            } catch { deliveryFailed(error.localizedDescription, target: .copy) }
        }
    }

    private func paste(_ plan: [Clip], into target: RelayTarget, app: NSRunningApplication) async {
        RelayCore.debug("paste: trusted=\(AXIsProcessTrusted()) clips=\(plan.count) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") bundle=\(Bundle.main.bundlePath)")
        guard AXIsProcessTrusted() else {
            // macOS only lets an app type ⌘V into another app after the user grants Accessibility.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            status("内容已复制，在 \(target.name) 按 ⌘V 即可。要自动粘贴，请在「系统设置 → 隐私与安全性 → 辅助功能」中打开「微信轻转」，下次分享起自动生效。")
            return
        }
        let focus = InputFocusSession(app: app)
        let started = Date()
        var retry = FocusRetryPolicy()
        var ready = false
        while Date().timeIntervalSince(started) < retry.timeout {
            if focus.isReady() { ready = true; break }
            if focus.isFrontmost, retry.shouldAttempt(at: Date().timeIntervalSince(started)) {
                if focus.focusComposer() { ready = true; break }
                if focus.treeLooksUnready { retry.retrySoon(at: Date().timeIntervalSince(started)) }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        RelayCore.debug("paste: composer \(ready ? "ready" : "not ready") after \(Int(Date().timeIntervalSince(started) * 1000))ms pid=\(app.processIdentifier)")
        guard ready else {
            try? put(plan.last!)
            deliveryFailed("未能定位 \(target.name) 的聊天输入框。内容已保存并复制；可重试，或点输入框按 ⌘V。", target: target)
            return
        }
        // Let the focus settle before typing into it.
        try? await Task.sleep(nanoseconds: 150_000_000)
        for (index, clip) in plan.enumerated() {
            guard focus.isReady() else {
                try? put(clip)
                deliveryFailed("\(target.name) 的输入焦点已改变，剩余内容已复制，请点聊天输入框按 ⌘V。", target: target); return
            }
            do { try put(clip) } catch { deliveryFailed(error.localizedDescription, target: target); return }
            guard let source = CGEventSource(stateID: .combinedSessionState),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
                deliveryFailed("未能创建粘贴操作，内容已复制，请点聊天输入框按 ⌘V。", target: target); return
            }
            for event in [down, up] {
                event.flags = .maskCommand
                event.post(tap: .cghidEventTap)
            }
            remainingDelivery = Array(plan.dropFirst(index + 1))
            // Give the target time to read the pasteboard before it is replaced by the next clip.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        RelayCore.debug("paste: posted \(plan.count) cmd-v")
        remainingDelivery = nil
        status("已向 \(target.name) 当前聊天输入框粘贴，请检查内容后发送。")
    }

    func requestAutoPaste() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        autoPasteReady = AXIsProcessTrustedWithOptions(options)
    }

    func refreshAutoPaste() { autoPasteReady = AXIsProcessTrusted() }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { fail("开机启动设置失败：\(error.localizedDescription)") }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            fail("请在「系统设置 → 通用 → 登录项」中允许微信轻转。")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Shows or hides the share entries in every share menu (pluginkit's per-user election).
    static func setShareEntries(_ shown: (RelayTarget) -> Bool) {
        for target in RelayTarget.allCases {
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            tool.arguments = ["-e", shown(target) ? "use" : "ignore", "-i", target.extensionID]
            try? tool.run()
            tool.waitUntilExit()
        }
    }

    /// The user's choice of which apps appear in WeChat's share menu.
    func setShareTarget(_ target: RelayTarget, shown: Bool) {
        preferences.setShows(target, shown)
        save()
        let prefs = preferences
        Self.setShareEntries(prefs.shows)
    }

    func openShareSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
    }
}

/// Warm neutral palette that follows light / dark mode.
private func tone(_ light: UInt32, _ dark: UInt32, _ alpha: CGFloat = 1) -> Color {
    func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light) })
}

private enum Palette {
    static let page = tone(0xF7F6F2, 0x1E1D1B)
    static let card = tone(0xFFFFFF, 0x282725)
    static let line = tone(0x000000, 0xFFFFFF, 0.08)
    static let ink = tone(0x1D1D1F, 0xEDECE8)
    static let muted = tone(0x6E6C66, 0xA29F98)
    static let faint = tone(0x9B9890, 0x77746D)
    static let good = tone(0x2E7D4F, 0x6BC48F)
    static let warn = tone(0xB4531B, 0xE0915A)
}

private struct Preset: Identifiable {
    let id: String
    let title: String
    let detail: String
}

private let presets = [
    Preset(id: "raw", title: "仅原文", detail: "只发送分享的内容，不附加任何文字"),
    Preset(id: "summary", title: "总结内容", detail: "先附上一段「整理关键事实和结论」的提示词"),
    Preset(id: "tasks", title: "提取待办", detail: "先附上一段「列出事项、负责人和截止时间」的提示词"),
    Preset(id: "custom", title: "自定义", detail: "使用你自己写的提示词"),
]

struct RelayView: View {
    @ObservedObject var model: RelayModel
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 28)
            sectionTitle("处理方式")
            presetCard.padding(.bottom, 24)
            sectionTitle("分享入口")
            targetsCard.padding(.bottom, 24)
            sectionTitle("通用")
            generalCard.padding(.bottom, 24)
            // Only shown while something still needs setting up.
            if !model.autoPasteReady {
                sectionTitle("准备情况")
                readinessCard.padding(.bottom, 24)
            }
            footer
        }
        .padding(.horizontal, 32).padding(.top, 44).padding(.bottom, 24)
        .frame(width: 520)
        .background(Palette.page)
        .onChange(of: model.preferences.preset) { _, _ in model.save() }
        .onChange(of: model.preferences.customPrompt) { _, _ in model.save() }
        .onChange(of: model.preferences.showInDock) { _, _ in model.save() }
        .onReceive(tick) { _ in model.refreshAutoPaste() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text("微信轻转").font(.system(size: 26, weight: .semibold, design: .serif)).foregroundStyle(Palette.ink)
                Text("在微信里分享给 Codex 或 Claude，内容直接进入当前聊天。")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.faint)
            .padding(.leading, 4).padding(.bottom, 8)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.line))
    }

    private var presetCard: some View {
        card {
            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                if index > 0 { Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 50) }
                presetRow(preset)
            }
            if model.preferences.preset == "custom" {
                TextEditor(text: $model.preferences.customPrompt)
                    .font(.system(size: 13)).foregroundStyle(Palette.ink).scrollContentBackground(.hidden)
                    .padding(10).frame(height: 84)
                    .background(Palette.page, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line))
                    .padding(.horizontal, 16).padding(.bottom, 16).padding(.leading, 34)
                    .accessibilityLabel("自定义提示词")
            }
        }
    }

    private func presetRow(_ preset: Preset) -> some View {
        let selected = model.preferences.preset == preset.id
        return Button { model.preferences.preset = preset.id } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(selected ? Palette.ink : Palette.faint.opacity(0.6), lineWidth: 1.5)
                    if selected { Circle().fill(Palette.ink).padding(4) }
                }.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title).font(.system(size: 13.5, weight: selected ? .semibold : .regular)).foregroundStyle(Palette.ink)
                    Text(preset.detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var targetsCard: some View {
        card {
            ForEach(Array(RelayTarget.allCases.enumerated()), id: \.element) { index, target in
                if index > 0 { Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 16) }
                toggleRow(title: target.name,
                          detail: model.preferences.shows(target) ? "在微信分享菜单中显示" : "已从微信分享菜单中隐藏",
                          isOn: Binding(get: { model.preferences.shows(target) },
                                        set: { model.setShareTarget(target, shown: $0) }))
            }
        }
    }

    private var generalCard: some View {
        card {
            toggleRow(title: "开机时启动", detail: "登录后在后台静默启动，不弹出窗口",
                      isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 16)
            toggleRow(title: "在 Dock 中显示",
                      detail: model.preferences.showInDock ? "关闭窗口后图标仍留在 Dock" : "只在窗口打开时显示；关闭窗口后在后台运行",
                      isOn: $model.preferences.showInDock)
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var readinessCard: some View {
        card {
            statusRow(ok: model.autoPasteReady, title: "自动粘贴",
                      detail: model.autoPasteReady ? "已开启，分享后会自动粘贴到当前聊天" : "需要「辅助功能」权限；开启后退出并重新打开本软件",
                      action: model.autoPasteReady ? nil : ("去开启", { model.requestAutoPaste() }))
            Rectangle().fill(Palette.line).frame(height: 1).padding(.leading, 50)
            statusRow(ok: true, title: "分享入口",
                      detail: "在微信「其他应用」中显示上方勾选的应用；退出软件后隐藏",
                      action: ("管理", { model.openShareSettings() }))
        }
    }

    private func statusRow(ok: Bool, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 17)).foregroundStyle(ok ? Palette.good : Palette.warn).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(Palette.ink)
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if let (label, run) = action {
                Button(label, action: run).buttonStyle(.bordered).controlSize(.small)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if model.message.isEmpty {
                Text("只粘贴，不会替你发送").font(.system(size: 11.5)).foregroundStyle(Palette.faint)
            } else {
                Text(model.message).font(.system(size: 11.5)).foregroundStyle(model.isError ? Palette.warn : Palette.muted)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let target = model.failedTarget {
                Button("重试") { model.send(to: target) }
                    .disabled(model.busy).controlSize(.small)
            }
            Button("本地记录") { NSWorkspace.shared.open(model.lastFolder ?? RelayCore.root) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.padding(.horizontal, 4)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = RelayModel()
    private var window: NSWindow?
    private var started = false
    private var incomingBeforeLaunch: [URL] = []
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Login items don't always carry that flag, so a launch right after boot with the login item on counts too.
        if SMAppService.mainApp.status == .enabled && ProcessInfo.processInfo.systemUptime < 180 { launchedAtLogin = true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundle is an agent (LSUIElement); it joins the Dock while the window is open, or always if chosen.
        if model.preferences.showInDock { NSApp.setActivationPolicy(.regular) }
        RelayModel.setShareEntries(model.preferences.shows)
        do { try RelayCore.privateDirectory(RelayCore.root) }
        catch { model.fail("无法创建本地保存目录：\(error.localizedDescription)") }
        setupMenu()
        makeWindow()
        model.presentDeliveryFailure = { [weak self] in self?.showWindow() }
        started = true
        if incomingBeforeLaunch.isEmpty && !launchedAtLogin { showWindow() }
        else {
            for url in incomingBeforeLaunch { process(url) }
            incomingBeforeLaunch.removeAll()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if !started { incomingBeforeLaunch.append(contentsOf: urls) }
        else { for url in urls { process(url) } }
    }

    private func process(_ url: URL) {
        if RelayCore.receiveID(from: url) != nil {
            model.receive(url)
            if model.isError { showWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Every real quit (Dock menu, ⌘Q, logout) also hides the share entries, so the tool is fully off
    /// until it is opened again.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        RelayModel.setShareEntries { _ in false }
        return .terminateNow
    }

    func showWindow() {
        model.refreshAutoPaste()
        NSApp.setActivationPolicy(.regular)
        if window == nil { makeWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window keeps the app running; without "在 Dock 中显示" it also leaves the Dock.
    func windowWillClose(_ notification: Notification) {
        if !model.preferences.showInDock { NSApp.setActivationPolicy(.accessory) }
    }

    private func makeWindow() {
        let host = NSHostingController(rootView: RelayView(model: model))
        host.sizingOptions = .preferredContentSize // grows when the custom prompt editor appears
        let window = NSWindow(contentViewController: host)
        window.title = "微信轻转"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(host.view.fittingSize)
        window.center()
        self.window = window
    }

    private func setupMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "隐藏微信轻转", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出微信轻转", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"),
            ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")
        ] { edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        editItem.submenu = edit
        bar.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        bar.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = bar
    }
}

@main
struct WeChatLiteMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
