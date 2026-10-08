<p align="center">
  <img src="docs/assets/icon.png" width="96" alt="Moro 应用图标" />
</p>

<h1 align="center">Moro</h1>

<p align="center">轻巧的 Mac 待办。记下事情，需要时开始专注。</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-475569?logo=apple&logoColor=white" alt="macOS 14 或更高" />
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white" alt="SwiftUI 原生应用" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/status-0.7.0_preview-8b7355" alt="0.7.0 预览阶段" />
</p>

<p align="center">
  简体中文 · <a href="README.en.md">English</a><br />
  <a href="#快速开始">快速开始</a> · <a href="docs/SIDEBAR.md">使用方式</a> · <a href="docs/BUILDING.md">构建与小组件</a> · <a href="CONTRIBUTING.md">参与开发</a>
</p>

> **0.7.0 预览**：主界面以待办为中心。小组件源码已通过编译和链接；本版完整 Xcode CI、签名安装与桌面交互仍待验证。验证范围见 [QA.md](QA.md)。

## 为什么做 Moro

- **先记下来。** 只填标题，Return 保存。备注、日期、预计时间和步骤按需补充。
- **把今天看清楚。** 收件箱、今天、接下来、自定义清单与跨清单搜索；支持批量操作和手动排序。
- **误操作有退路。** 完成框、编辑和专注各有入口。支持撤销、重做、恢复待办与最近删除。
- **从事项开始专注。** 点 ▶ 开始一轮计时；清单仍可浏览和编辑。到点后，由你决定继续、休息或完成。
- **属于 Mac，也属于你。** SwiftUI + AppKit、系统字体、浅深色外观；正文保持稳定实色，导航侧栏保留系统通透材质。无账号、服务器或遥测。

## 日常使用

1. 按 `⌘ N`，输入标题，按 Return。可以连续录入，不必先估算时间。
2. 点标题展开详情；安排到今天、移入清单，或补充备注和日期。
3. 做完点完成框。误点可按 `⌘ Z`，已完成和最近删除中也可恢复。

| 可选信息 | 含义 |
| --- | --- |
| 计划日期 | 打算哪天做；安排到今天不会修改截止日期 |
| 截止日期 | 最迟何时完成；支持仅日期或精确时间 |
| 提醒时间 | 独立发送系统通知；只设截止日期不会提醒 |
| 预计时长 | 事情大约需要多久；可留空，与本轮倒计时分开 |

详情中可添加一级步骤，以及每天、每周、每月重复规则。完成重复事项后生成下一次；重新打开再完成不会重复生成。

`⌘ F` 搜索标题与备注。普通视图搜索所有未删除事项；在“最近删除”中搜索可找回已删除内容。清单与日期规则见 [使用方式](docs/SIDEBAR.md)。

### 需要时，再专注

事项右侧 ▶ 使用记住的时长；旁边菜单提供 15 / 25 / 45 分钟和直接输入 **1–180 分钟**。确认的时长会成为下次默认值，不改动事项的预计时间。已有计时时，切换事项或重新指定时长需要确认，原轮投入会保存。

清单菜单或多选菜单可开启逐项专注队列。每次只计一项，下一项由你推进；跳过和到点都不会自动完成事项。底部控制栏负责暂停、继续和结束，大号专注视图按需打开。

每项实际投入按稳定 ID 关联。统计基于**当前保留的最近 1,000 条专注日志**，不代表终身累计；旧日志缺少单项 ID 时只保留历史，不按同名标题猜测归属。

### 随手录入

菜单栏提供快速录入。全局快捷键默认关闭，可在设置中选择 `⌃⌥ Space`、`⌃⌥ N` 或 `⌃⇧ N`；冲突时会提示，不要求辅助功能授权。独立输入框保存到收件箱，Return 成功保存后收起，Esc 收起并保留草稿。

待办提醒需要通知权限。一次优先安排最近 **48 项**；超出的数量会在设置中提示，返回应用时补排。未排入的提醒不会在应用退出后自动补排；通知呈现也受系统专注模式与声音设置影响。

## 快速开始

需要 macOS 14+ 和 Apple Command Line Tools，或完整 Xcode。当前应用界面为中文。

```sh
git clone https://github.com/zzzfu411/afterglow-macos.git
cd afterglow-macos
./scripts/build-local.sh
open .build/local/Moro.app
```

脚本生成按本机架构构建、ad-hoc 签名的主应用，不会安装到“应用程序”，也不包含桌面小组件。小组件需要完整 Xcode、有效签名与 App Group 配置，见 [构建与安装](docs/BUILDING.md)。当前没有已验证的公证发行包。

| 快捷键 | 操作 |
| --- | --- |
| `⌘ N` → Return | 输入并保存新事项 |
| `⌘ B` | 显示 / 隐藏导航侧栏 |
| `⌘ F` | 搜索事项 |
| `⌘ Z` / `⇧⌘ Z` | 撤销 / 重做；输入框内优先处理文字 |
| `⌘ Return` | 开始 / 暂停 / 继续专注 |
| `Space` | 仅在专注视图中控制计时 |
| `⌘ .` | 结束本轮 |
| `⌘ ,` | 设置 |

## 本地数据与资源

数据保存在本机，支持待办 JSON 导出、预览后合并导入。归档 **v2** 包含清单与事项，兼容读取 v1；不包含计时、专注日志或偏好，因此不能代替完整备份。

存储格式为 **v5**。首次读取旧格式时，先备份原始文件，再升级；降级需要对应版本的备份。最多保留 **1,000 项未完成待办、10,000 项总事项**，总数包含已完成和最近删除。文件位置与恢复方式见 [数据说明](docs/BUILDING.md#数据备份与升级)。

原生实现，无 WebView、Electron 或第三方运行时依赖。磁盘操作串行执行，界面分批显示，空闲时不轮询记录。实际测量及其条件见 [资源占用记录](docs/PERFORMANCE.md)，不以模型测试替代整机体验。

## 开发

```sh
./scripts/test.sh          # 状态、重复规则、迁移与跨进程存储
./scripts/test-runtime.sh  # 异步存储、草稿、队列、提醒与模型压力
./scripts/check-native.sh  # SwiftUI / WidgetKit 编译检查
```

其他测试命令见 [构建文档](docs/BUILDING.md#开发检查)。[GitHub Actions](https://github.com/zzzfu411/afterglow-macos/actions/workflows/ci.yml) 配置了测试、原生编译和完整 Xcode 构建；**0.7.0 的完整 Xcode CI 尚待本次代码推送后运行**，历史版本的成功记录不能作为本版验证。

```text
App/       原生窗口、清单、快速录入、提醒与设置
Shared/    事项、计时状态、事务存储与小组件快照
Widget/    今天清单、当前专注与 App Intents
Tests/     状态、存储、通知、归档、布局与运行时回归
```

欢迎提交问题、界面反馈或小范围改进，参见 [贡献指南](CONTRIBUTING.md)。

## 许可

[MIT](LICENSE)。系统字体和 SF Symbols 通过 Apple 系统框架使用，不随项目分发字体文件。
