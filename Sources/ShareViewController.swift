import AppKit
import UniformTypeIdentifiers

private enum ReceivedPiece {
    case text(String)
    case file(URL)
}

@objc(WeChatLiteShareController)
final class ShareViewController: NSViewController {
    private let jobID = UUID()
    private var started = false
    private var cancelled = false
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在读取你分享的内容…")
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var jobFolder: URL { RelayCore.root.appendingPathComponent("Inbox/\(jobID.uuidString)") }
    private let target = (Bundle.main.object(forInfoDictionaryKey: RelayTarget.infoKey) as? String)
        .flatMap(RelayTarget.init(rawValue:)) ?? .codex

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let title = NSTextField(labelWithString: target.shareTitle)
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        cancelButton.target = self
        cancelButton.action = #selector(cancelShare)
        let stack = NSStackView(views: [title, statusLabel, spinner, cancelButton])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        preferredContentSize = view.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }
        started = true
        Task { @MainActor in await readShare() }
    }

    @MainActor private func readShare() async {
        do {
            try RelayCore.privateDirectory(jobFolder)
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let providers = items.flatMap { $0.attachments ?? [] }
            guard providers.count <= RelayCore.maximumFiles else { throw RelayError.message("一次最多分享 32 项内容，请分批分享。") }
            var texts: [String] = []
            var files: [URL] = []
            for item in items {
                if let text = item.attributedContentText?.string, !text.isEmpty { texts.append(text) }
            }
            for provider in providers {
                guard !cancelled else { return }
                statusLabel.stringValue = "正在读取第 \(files.count + 1) 项内容…"
                let piece = try await read(provider)
                switch piece {
                case .text(let text): if !texts.contains(text) { texts.append(text) }
                case .file(let url): files.append(url)
                }
            }
            guard !cancelled else { return }
            let text = texts.joined(separator: "\n\n")
            guard !text.isEmpty || !files.isEmpty else { throw RelayError.message("没有收到可读取的文字或文件。可以先把微信内容导出为文件，再拖进微信轻转。") }
            _ = try RelayCore.saveRequest(text: text, files: files, id: jobID, target: target)
            statusLabel.stringValue = "内容已就绪，正在打开微信轻转…"
            // Explicitly target our containing app, rather than an arbitrary URL-scheme handler.
            let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let link = URL(string: "wechatlite://receive/\(jobID.uuidString)")!
            let config = NSWorkspace.OpenConfiguration()
            // Copy-only shares are handled in the background, so the user can switch straight to where they paste.
            config.activates = target.bundleID != nil
            NSWorkspace.shared.open([link], withApplicationAt: host, configuration: config) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self, !self.cancelled else { return }
                    if let error { self.showError(error) }
                    else { self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil) }
                }
            }
        } catch { if !cancelled { showError(error) } }
    }

    private func read(_ provider: NSItemProvider) async throws -> ReceivedPiece {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    if let error { continuation.resume(throwing: error); return }
                    let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url, url.isFileURL else { continuation.resume(throwing: RelayError.message("收到的文件地址无效。")); return }
                    do {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let copied = try RelayCore.copyFile(url, into: self.jobFolder)
                        continuation.resume(returning: .file(copied))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return try await loadText(provider, type: UTType.url.identifier)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return try await loadText(provider, type: UTType.plainText.identifier)
        }
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) else {
            throw RelayError.message("不支持这类分享内容，请先保存成文件后再拖入。")
        }
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: RelayError.message("无法读取分享的附件。")); return }
                do {
                    let name: String
                    if let suggested = suggestedName, !suggested.isEmpty {
                        name = (suggested as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? suggested + "." + url.pathExtension : suggested
                    } else { name = url.lastPathComponent }
                    let copied = try RelayCore.copyFile(url, into: self.jobFolder, name: name)
                    continuation.resume(returning: .file(copied))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider, type: String) async throws -> ReceivedPiece {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, error in
                if let error { continuation.resume(throwing: error); return }
                let text: String?
                if let url = value as? URL { text = url.absoluteString }
                else if let string = value as? String { text = string }
                else if let attributed = value as? NSAttributedString { text = attributed.string }
                else if let data = value as? Data { text = String(data: data, encoding: .utf8) }
                else { text = nil }
                guard let text else { continuation.resume(throwing: RelayError.message("无法读取分享的文字。")); return }
                continuation.resume(returning: .text(text))
            }
        }
    }

    @MainActor private func showError(_ error: Error) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = error.localizedDescription
        statusLabel.textColor = .systemRed
        cancelButton.title = "关闭"
    }

    @objc private func cancelShare() {
        cancelled = true
        // Provider callbacks may still be running; delete only after their process exits on cancel.
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
