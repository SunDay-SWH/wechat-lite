# 微信轻转

macOS 14+ 本机自用应用，Swift + AppKit + SwiftUI。没有菜单栏图标；窗口打开时显示在 Dock。

已安装位置：`/Applications/微信轻转.app`（本机唯一一份）。源码就在本目录，改完重新构建即可更新已安装的应用。

## 构建与更新

需要 macOS、Python 3、Apple Command Line Tools。无第三方依赖。

```sh
python3 build.py
```

脚本依次：运行核心检查 → 退出正在运行的微信轻转 → 原地重建 `/Applications/微信轻转.app`（主程序、两个分享扩展、图标、ad-hoc 签名并校验）→ 注册分享入口 → 重新打开。辅助功能授权按 bundle ID 识别，重建后无需重新授权。

不要在别处另外生成一份 `微信轻转.app`：同 ID 的分享扩展会抢走微信的分享。确需输出到别处时可传绝对路径 `python3 build.py '/path/微信轻转.app'`，用完删掉并 `lsregister -u`。`build/` 目录只放中间产物。

默认构建与当前机器相同的 CPU 架构，不产生通用二进制。

## 发布 Release

1. 改 `build.py` 里的 `CFBundleShortVersionString`（版本号）和 `CFBundleVersion`（构建号），运行 `python3 build.py` 安装新版。
2. `python3 release.py`：把已安装的 `/Applications/微信轻转.app` 打包成 `build/WeChatLite-<版本>-<架构>.dmg`（文件名用英文，GitHub 会去掉附件名里的中文；临时目录打包后即删除，不会多出一份已注册的分享扩展）。
3. 提交并推送后发布：`gh release create v<版本> build/WeChatLite-<版本>-<架构>.dmg --title "微信轻转 <版本>" --notes "..."`。

DMG 只含当前机器架构，ad-hoc 签名、未经 Apple 公证；首次打开需在「系统设置 → 隐私与安全性」中点「仍要打开」。

## 结构

- `Sources/Core.swift`：文件限制、临时文件转存、私有本地目录、分享请求、提示词偏好和待粘贴的消息。
- `Sources/App.swift`：常规 Dock 应用（关窗口不退出，退出时停用分享入口）：设置窗口（处理方式、自动粘贴与分享入口状态）及粘贴到 Codex / Claude 当前聊天，或「仅复制」到剪贴板。
- `Sources/InputFocus.swift`：启用目标应用的网页辅助功能，从当前窗口识别聊天编辑器；支持应用级焦点缺失时核对编辑器自身焦点、限时重试，并排除搜索框和终端。
- `Sources/ShareViewController.swift`：macOS `com.apple.share-services` 扩展，接收 NSItemProvider。
- `Tests/CoreTests.swift`：内容完整性、链接编码、持久化、边界及请求校验。
- `Tests/InputFocusTests.swift`：使用模拟辅助功能树检查输入框识别、歧义处理、搜索框/终端排除和重试时限，不访问真实聊天界面。
- `Tests/ShareHarness.swift`：开发时的系统分享菜单测试窗口，只使用合成数据，不是交付软件的一部分。
- `Resources/MakeIcon.swift`：应用程序图标的本地绘制代码。

## 数据和启动

分享扩展把提供者的临时文件复制到 `~/Library/Application Support/WeChatLite/Inbox/<UUID>/`，原子写入 `request.json` 后，通过 `wechatlite://receive/<UUID>` 唤起自己的主程序。扩展明确指定包含它的 `.app` 为接收方，主程序只接受 UUID 请求及所属目录中的普通文件。

主程序把分享的原文（默认不加提示词）写入剪贴板，切换到 Codex 后在当前聊天输入框粘贴（需在「辅助功能」中允许自动粘贴，否则手动 ⌘V）。不再使用 `codex://threads/new?path=...`，因为它会为每次分享新建项目和聊天。附件复制到 `Files/<时间>/`，以文件 URL 写入剪贴板后再粘贴一次，在 Codex 中成为附件卡片。不自动发送消息。

0.1.2 新增「仅复制」分享入口：只写剪贴板，不打开应用、不需要辅助功能权限；文件以文件 URL 写入，第一项同时带加引号的路径文字，因为 Terminal 粘贴时只读纯文字。

0.1.1 修复：对焦改为最多 6 秒内多次尝试，使用打开应用回调返回的进程；不再依赖应用级 `AXFocusedUIElement` 必须有值。每次粘贴前核对聊天编辑器自身焦点；失败时显示窗口和“重试”，重试只处理尚未执行粘贴的内容。诊断记录含 AX 错误码，不记录聊天正文。安装后的真实微信 → Codex 转发仍需实际分享验收。

分享扩展启用 App Sandbox，并仅对自有 WeChatLite 数据目录使用临时文件访问例外。这种本地签名及目录共享方式面向本机自用；正式分发时应改为开发者签名、App Group 和公证流程。

主程序设置 `LSUIElement=true`、`.accessory` 激活策略，不创建 NSStatusItem。双击可打开设置；关闭窗口不会结束主程序。显式「退出」才终止主程序。用户从分享入口使用时可再次唤起。

## 验证依据

- 系统分享菜单中可见并已启用「Codex」「Claude」「仅复制」三个入口。
- 合成 `.txt` 文件从系统分享扩展到主程序、生成本地副本并唤起 Codex，用户确认草稿出现。
- 纯文字分享已通过 UI 核对，默认自动打开草稿开关已恢复。
- 没有使用真实微信群导出记录、图片/视频等实际微信附件做兼容性验收。

参考：[Apple App Extension Programming Guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)、[OpenAI deep links](https://learn.chatgpt.com/docs/reference/commands#deep-links)。
