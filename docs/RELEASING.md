# 打包与分发

`package-release.sh` 接收已经构建的 `.app`，不修改原包，不自动签名或上传 GitHub。两种输出明确区分：

| 模式 | 用途 | 产物 |
| --- | --- | --- |
| `preview` | 本机开发、预览和测试 | 文件名含 `preview` 的 ZIP；不代表已公证 |
| `release` | 站外正式分发 | 通过 Developer ID、公证、票据和 Gatekeeper 检查后才生成的 ZIP |

当前本机构建使用 ad-hoc 签名，仅含主应用。它可以生成预览包，**不能作为已签名、公证的正式版发布**。桌面小组件仍需要完整 Xcode 和可用的开发者签名配置。

## 预览包

在项目根目录运行：

```sh
./scripts/build-local.sh
./scripts/package-release.sh preview ".build/local/留白.app"
```

输出示例：`.build/packages/Afterglow-0.3.0-build4-arm64-preview.zip`。脚本从实际 bundle 读取版本、构建号和架构，不把单架构构建标成 Universal。ZIP 内保留原来的应用名。

预览模式会检查代码签名完整性，但不联系 Apple 公证服务。下载到另一台 Mac 后仍可能被 Gatekeeper 阻止；预览包不是面向普通用户的安装体验，不应附带关闭系统保护的步骤。

## 正式包

先准备：

1. 完整 Xcode，以及 Apple Developer Program 下的 **Developer ID Application** 签名身份。
2. 从 Xcode Archive → Distribute App → Developer ID 导出的 `.app`。主应用和内嵌 WidgetKit 扩展须使用同一 Team、版本和构建号，启用 Hardened Runtime 与安全时间戳，移除 `get-task-allow` 调试授权。
3. 已授权的共享 App Group，以及应用、组件对应的签名配置。当前工程使用 `TEAM_ID.app.afterglow.shared`；仅让 entitlement 字符串相同不能替代开发者账户中的授权。
4. 一个**已经配置好**的 `notarytool` Keychain profile。脚本只使用 profile 名称，不接收密码、API 私钥，也不创建或修改钥匙串项目。配置方式见 [Apple 公证文档](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。

`build-xcode.sh` 的 Debug 构建用于开发安装，不等于 Developer ID 分发导出。按 [Apple 分发签名流程](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)准备应用后运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/package-release.sh release \
  "/path/to/export/Afterglow.app" \
  YOURTEAMID \
  afterglow-notary
```

将 `YOURTEAMID` 替换为真实的 10 位 Team ID，`afterglow-notary` 替换为现有 profile 名称。末尾可追加输出目录；默认 `.build/packages/`。脚本会向 Apple 上传临时 ZIP，最多等待 20 分钟；不会公开发布应用。

正式模式依次执行：

- 校验所有架构的签名，以及主应用和每个内嵌扩展的 Developer ID 证书链、Team、Hardened Runtime、安全时间戳、Sandbox 和共享 App Group。
- 要求包含 WidgetKit 扩展，且组件与宿主的版本、构建号和支持架构一致。
- 用现有 Keychain profile 提交公证，读取结果与完整日志，仅接受 `Accepted`。
- 在临时副本上附加公证票据，通过 `stapler validate`、深层签名验证和 Gatekeeper 评估，再重新打包。

ZIP 本身不能附加票据，因此最终产物包含的是已附加票据的 `.app`。[Apple 打包说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

## 结果与失败处理

成功时输出 ZIP 路径和 SHA-256。文件名始终包含 `preview` 或 `release`，已有 ZIP 不会被覆盖。中途失败会删除临时副本，不留下本次运行产生的 `release.zip`；源应用保持原样。

公证结果与日志保留在输出目录的 `notary-logs/`，即使被接受也应检查其中的警告。超时不会取消 Apple 服务端已接收的任务，可用结果中的 submission ID 查询：

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile afterglow-notary
xcrun notarytool log SUBMISSION_ID --keychain-profile afterglow-notary
```

修正签名或配置后重新导出并打包，不要对已经签名的 bundle 直接改文件，也不要通过反复深层重签名掩盖内嵌组件的问题。[Apple 签名要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

正式包生成后，仍需在另一台 Mac 或干净用户环境中验证：首次打开、离线打开、菜单栏、计时恢复，以及桌面组件添加和读写。公证通过不代表这些功能已经完成实机验证。

## 当前验证边界

预览打包可以在现有 Command Line Tools 环境运行。当前开发环境没有完整 Xcode，也没有可用 Developer ID 证书；正式签名、公证、票据和新机器安装流程尚未实测。脚本会在缺少条件时明确失败，不产生冒充正式版的预览包。

## 没有开发者账号时

本机开发、自用和 GitHub 源码发布可以先继续；Xcode 免费，免费开发者注册与付费会员是两回事。Developer ID 签名及公证分发需要 Apple Developer Program 的相应权限。[会员对照](https://developer.apple.com/help/account/basics/about-your-developer-account)

截至 2026-10-04，Apple 中国大陆官方说明的个人会员价格为 **¥688／年，自动续订**。申请流程：

1. 在 Apple 账户开启双重认证；从 App Store 安装 Apple Developer App。
2. 在 App 的“账户 → 现在注册”选择个人，按 Apple 要求完成实名与身份验证。
3. 由账户持有人确认协议并支付年费。开通后在 Xcode 登录该账户，配置团队、App Group 与签名，再运行完整构建和公证流程。

实名、协议和付款需由本人在 Apple 界面完成，仓库或聊天中不需要保存身份证、密码或私钥。实际费用以 Apple 购买界面为准。来源：[Apple 中国大陆注册说明](https://developer.apple.com/cn/help/account/membership/enrolling-in-the-app/)。
