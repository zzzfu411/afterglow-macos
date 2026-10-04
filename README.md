<p align="center">
  <img src="docs/assets/icon.png" width="96" alt="留白应用图标" />
</p>

<h1 align="center">留白 · Afterglow</h1>

<p align="center">把待办变成一段专注。原生 macOS，离线、少打扰。</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-475569?logo=apple&logoColor=white" alt="macOS 14 或更高" />
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white" alt="SwiftUI 原生应用" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/status-preview-8b7355" alt="预览阶段" />
</p>

<p align="center">
  简体中文 · <a href="README.en.md">English</a><br />
  <a href="#快速开始">快速开始</a> · <a href="docs/BUILDING.md">桌面小组件</a> · <a href="CONTRIBUTING.md">参与开发</a>
</p>

<p align="center">
  <img src="Preview/widget-preview.png" width="860" alt="留白小号与中号组件的深浅色布局和配色示意" />
  <br /><sub>组件布局与配色示意。实际背景模糊由 macOS 渲染。</sub>
</p>

> **预览阶段**：主应用已可运行。主应用与小组件已通过完整 Xcode 构建，签名安装和桌面交互仍待验证。

## 为什么做留白

写下一件事，估一个时间，开始专注。留白把清单、计时和记录连在一起，左侧管理待办，右侧只保留这一轮需要的计时操作。

- **像一款 Mac 应用。** SwiftUI + AppKit、系统毛玻璃、SF Pro 与 SF Symbols；支持深色、浅色及自动外观。
- **点击就能开始。** 选时长，点开始；空格暂停或继续。菜单栏也能快速操作。
- **随手展开的边栏。** 原生两栏布局，可拖宽、折叠并记住显示偏好；选中事项后清单保持可见。
- **清单直接变成计时。** 选单项、整张未完成清单，或自由专注。预计时长自动带入，本轮时间也可调整。
- **时间与完成分开。** 选择事项只设置专注；在右侧菜单中标记完成，误标可撤销，已完成项可恢复。改名和编辑不打断本轮计时。
- **离线也完整。** 无账号、无服务器、无遥测。待办和专注记录只保存在本机。
- **休眠后仍能接上。** 保存截止时间，重新打开时恢复或结算；暂停时间不计入专注。
- **少些后台活动。** 状态变化时同步，到点才唤醒；空闲时不轮询记录。没有第三方运行时依赖。[资源占用实测](docs/PERFORMANCE.md)。

## 能做什么

| 功能 | 状态 |
| --- | --- |
| 15 / 25 / 45 分钟专注；5 / 10 / 15 分钟休息 | 可用 |
| 直接输入 1–180 分钟，回车确认；分别记住专注与休息设置 | 可用 |
| 可折叠、可调宽的待办边栏 | 可用 |
| 待办内容与预计时长；编辑、完成、撤销、恢复待办、删除确认 | 可用 |
| 单项 / 整单 / 自由专注；按预计时长开始，可调整本轮时长 | 可用 |
| 开始、暂停、继续、结束；按实际时长显示专注记录 | 可用 |
| 结束后一键休息／开始专注、收工 | 可用 |
| 到点系统提醒与提示音 | 已实现，需通知权限；系统投递待实测 |
| 菜单栏快捷面板、键盘快捷键 | 已实现 |
| 窗口毛玻璃与外观切换 | 已实机检查 |
| 窗口缩放与自适应计时数字 | 可用 |
| 小号 / 中号桌面小组件、App Intents 操作 | 源码已实现，待签名安装验证 |

使用 Xcode 26+ 构建时，macOS 26 及以上使用 Liquid Glass 按钮；较早工具链或系统使用 Material。开启“减少透明度”时，背景回退为实色。

布局与操作约定见 [边栏设计](docs/SIDEBAR.md)。

### 从清单开始

1. 点左侧 `+` 或按 `⌘ N`，填写事项与预计分钟数。
2. 点事项圆点、名称或“专注”，也可选“整张清单”；时间自动带入，再点开始。
3. 事项右侧 `···` →“标记完成”。误标点“撤销”，或展开“已完成”点“恢复待办”。

整单合计未完成事项，进行一次倒计时。每项预计 1–180 分钟，最多保留 100 项；整单总时长可以超过 180 分钟。调整本轮时长不修改事项原本的预计时间。选择“自由专注”可回到独立计时，已完成事项收在折叠区。标题栏按钮或 `⌘ B` 可折叠边栏；新增和编辑在左栏完成，收起边栏会保留未保存草稿。

## 快速开始

需要 macOS 14+ 和 Apple Command Line Tools，或完整 Xcode。当前界面为中文。

```sh
git clone https://github.com/zzzfu411/afterglow-macos.git
cd afterglow-macos
./scripts/build-local.sh
open .build/local/留白.app
```

此命令构建主应用和菜单栏面板，不安装桌面小组件。桌面组件需要完整 Xcode 与有效签名配置，见 **[构建与安装](docs/BUILDING.md)**。

| 快捷键 | 操作 |
| --- | --- |
| `Space` | 开始 / 暂停 / 继续 |
| `⌘ .` | 结束 |
| `⌘ N` | 添加待办 |
| `⌘ B` | 显示 / 隐藏待办边栏 |
| `⌘ ,` | 设置 |

本地构建使用 ad-hoc 签名；当前尚未提供公证发行包。运行验证以 Apple Silicon 为主。预览打包和正式签名分发见 [打包与分发](docs/RELEASING.md)。

首次在应用内开始计时时会请求通知权限，也可从设置中开启。暂停或提前结束会取消提醒；自然到点交由 macOS 投递。系统通知权限、专注模式和声音设置会影响呈现方式。

## 开发

```sh
./scripts/test.sh          # 状态转换、重启恢复、跨进程存储
./scripts/test-window.sh   # 原生外观切换、窗口布局边界
./scripts/test-runtime.sh  # 提醒竞态、文件监听、到期结算与无轮询
./scripts/check-native.sh  # SwiftUI / WidgetKit 编译检查
```

测试包含 115 项核心断言、6 个进程的 246 次存储事务、92 项原生外观、布局与显示检查，以及 95 项提醒与运行时检查。[GitHub Actions](https://github.com/zzzfu411/afterglow-macos/actions/workflows/ci.yml) 自动检查测试、原生编译和完整 Xcode 构建。详细验证范围见 [QA.md](QA.md)。

旧计时数据可直接读取。首次保存清单后使用第 2 版数据格式，旧应用会拒绝打开，避免把新增待办覆盖掉；降级前请备份并使用与旧版本匹配的数据文件。

```text
App/       原生窗口、菜单栏与设置
Widget/    WidgetKit timeline 与 App Intents
Shared/    计时状态、共享存储与视图
Tests/     状态和存储测试
```

## 下一步

- [ ] 完成签名版小组件的桌面添加与交互验证
- [ ] 检查不同壁纸、系统单色与透明外观
- [ ] 完成公证与安装包发布流程

欢迎提交问题、界面反馈或小范围改进。参见 [贡献指南](CONTRIBUTING.md)。

## 许可

[MIT](LICENSE)。系统字体和 SF Symbols 通过 Apple 系统框架使用，不随项目分发字体文件。
