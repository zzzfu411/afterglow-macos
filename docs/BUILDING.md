# 构建与安装 · 0.7.0

## 主应用

需要 macOS 14 或更高，以及 Apple Command Line Tools 或完整 Xcode。

```sh
./scripts/build-local.sh
open .build/local/Moro.app
```

输出为 `.build/local/Moro.app`，按当前 Mac 的架构构建，使用 ad-hoc 签名。脚本不会安装到“应用程序”；如需常驻使用，可退出旧版后将产物拖入“应用程序”。该构建包含主窗口、菜单栏和独立快速录入，不包含 WidgetKit 扩展，也不是公证发行包。

当前界面为中文。全局快速录入快捷键默认关闭，需要在设置中自行选择；提醒需要单独允许通知。

## 桌面小组件

0.7.0 组件源码展示今天的少量事项与当前专注：小号最多展示 2 项，中号最多 3 项；点事项打开主应用，计时控制通过 App Intents 执行。扩展读取专用快照，不读取完整备注、步骤和日志。

**验证状态：本版小组件源码编译、链接和完整 Xcode CI 已通过；签名安装、系统图库和桌面交互仍待实机验证。** 本版 [CI 记录](https://github.com/zzzfu411/afterglow-macos/actions/runs/37769848982) 验证代码提交 `d968824`，关闭代码签名。完整边界见 [QA.md](../QA.md)。

构建扩展需要完整 Xcode，以及能授权 App Group 的有效 Apple 签名配置。仅安装 Command Line Tools 或对主应用进行 ad-hoc 签名，不能完成这一步。

1. 用 Xcode 打开 `Afterglow.xcodeproj`。
2. 为 **Afterglow** 和 **AfterglowWidgets** 两个 target 选择同一个真实 Team。
3. 核对两个 target 的 App Group entitlement 与 Info.plist；默认标识为 `$(DEVELOPMENT_TEAM).app.afterglow.shared`。
4. 选择 **Afterglow** scheme、**My Mac**，构建并运行宿主一次。
5. 签名与共享容器正常后，右键桌面 → **编辑小组件** → 搜索 **Moro**。

终端构建：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/build-xcode.sh YOUR_TEAM_ID
```

将 `YOUR_TEAM_ID` 换成真实的 10 位 Team ID。命令不会改变全局 `xcode-select`，也不会代为登录、申请证书或接受协议。也可将 Team 写入被 Git 忽略的 `Config/Local.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

共享容器不可用或快照失效时，组件提示打开 Moro，不创建第二套独立数据。组件最终的背景和着色由 WidgetKit 与系统设置决定；源码编译成功不能验证桌面材质或通知的真实呈现。

## 数据备份与升级

Moro 保留原有 bundle ID、App Group、URL scheme 和数据路径。工程与 scheme 仍名为 `Afterglow`，产物为 `Moro.app` 与 `MoroWidgets.appex`，不需要因为改名重建待办。

本地主应用的数据目录：

```text
~/Library/Application Support/Afterglow/Standalone/
  focus-state.json       事项、清单、计时与保留的日志
  widget-snapshot.json   可重新生成的小组件摘要
  Backups/               升级前原始文件
```

签名版应用与扩展使用 App Group 目录，与本地预览版分开；不会自动合并两份数据。外观、导航与快捷键偏好在本机 UserDefaults 中，应用不读取旧网页版本的数据。

### 格式与恢复

当前状态格式为 **v5**。第一次读取旧格式时，存储层先原子保存原始文件备份，命名为 `Backups/pre-v5-v<原版本>-<UUID>.json`，再原子替换升级后的状态。失败会报告错误并保留原文件，不用空清单覆盖损坏数据。旧版应用会拒绝新格式。

升级前也可自行复制整个数据目录。恢复状态文件时先退出主应用；使用签名版时，先从桌面移除访问同一容器的小组件。保留当前文件副本，再用匹配应用版本的备份替换 `focus-state.json`。重启主应用后会重新生成快照。不要删除整个数据目录来处理启动错误。

“文件”菜单或设置中的待办导出生成 **归档 v2**，兼容读取 v1。归档包含事项、清单、步骤、重复规则及完成/删除状态，**不包含计时、专注日志和 UserDefaults 偏好**。导入前显示新增与覆盖数量，同 ID 合并，不重复创建；导入不会替换当前计时或专注日志。需要保留完整历史时，应备份状态文件，而非只导出待办。

### 容量与统计边界

| 数据 | 当前上限 |
| --- | --- |
| 未完成且未删除的事项 | 1,000 项 |
| 所有保留事项，含已完成与最近删除 | 10,000 项 |
| 自定义清单 | 100 个 |
| 每项一级步骤 | 100 个 |
| 状态文件 / 待办归档 | 16 MB |
| 专注日志 | 最近 1,000 条 |
| 待办撤销记录 | 会话内最多 20 次且受 4 MB 预算限制 |

文字内容较多时，文件大小限制可能先于项数限制生效。已完成和最近删除不消耗未完成额度；达到总容量后，可先导出归档，再明确选择永久删除不再保留的内容。应用不会为腾出待办容量自动清空历史事项。

单项专注统计依据当前保留的日志，不是终身累计。没有单项 ID 的旧日志保留在历史中，不猜测归属。

## 外观与资源

主窗口正文采用系统实色背景，侧栏使用原生 vibrancy，随窗口激活与辅助功能设置变化。此版本不以整窗毛玻璃作为阅读表面。“自动”外观跟随系统；“减少透明度”使用实色回退。

磁盘读写在串行工作队列中执行，文件锁协调进程，原子写入保证事务完整。列表按 100 项分批展示；日期边界、激活、唤醒和数据变更触发更新，无持续轮询。计时保存截止时间，暂停不累计，过期结算按会话 ID 去重。

提醒独立于截止日期，优先排入最近 48 项待办提醒并为计时提醒留出空间；未排入数量与失败状态显示在设置中。进入应用时重新协调，退出后不会为超额事项继续补排。

测量方法、资源数据与剩余验证范围见 [PERFORMANCE.md](PERFORMANCE.md) 和 [QA.md](../QA.md)。模型基准测试不能替代完整应用、WindowServer 或 WidgetKit 的测量。

## 开发检查

```sh
./scripts/test.sh                  # 状态、步骤、重复、迁移、跨进程事务
./scripts/test-runtime.sh          # 异步模型、草稿、队列、无轮询与压力检查
./scripts/test-todo-reminders.sh   # 待办通知授权、重排与失败恢复
./scripts/test-todo-transfer.sh    # 归档、合并与冲突
./scripts/test-shortcuts.sh        # 快速录入、快捷键与保存竞态
./scripts/test-widget-snapshot.sh  # 小组件摘要和时间边界
./scripts/test-window.sh           # 原生外观、输入与布局
./scripts/check-native.sh          # SwiftUI / WidgetKit 编译
./scripts/build-local.sh           # 主应用构建
```

测试使用临时数据、隔离偏好或替身服务；相关测试不会请求真实通知权限或修改用户待办。原生界面测试需要能访问 macOS 窗口服务的登录会话。自动化检查的准确范围以 [QA.md](../QA.md) 为准。

工程由 `scripts/generate-project.py` 生成。修改源文件清单或工程配置后，更新生成器再运行：

```sh
python3 scripts/generate-project.py
```

`render-preview.sh` 仅输出共享视图的静态示意，不能作为 0.7.0 主界面截图，也不能验证桌面背景模糊。`render-icon.sh` 用于现有应用图标资产。

正式分发仍需验证已签名宿主、组件图库与桌面操作，并完成适用的公证流程。打包工具与命令见 [RELEASING.md](RELEASING.md)。
