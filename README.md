<p align="center">
  <img src="docs/assets/icon.png" width="96" alt="留白应用图标" />
</p>

<h1 align="center">留白 · Afterglow</h1>

<p align="center">原生 macOS 专注计时器。轻量、离线、少打扰。</p>

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

> **预览阶段**：主应用已可运行。WidgetKit 小组件代码已通过编译与链接检查，签名安装和桌面交互仍待验证。

## 为什么做留白

专注工具也应该少占一点注意力。留白把时间与操作留在前面，把记录和设置放在需要时才打开的地方。

- **像一款 Mac 应用。** SwiftUI + AppKit、系统毛玻璃、SF Pro 与 SF Symbols；支持深色、浅色及自动外观。
- **点击就能开始。** 选时长，点开始；空格暂停或继续。菜单栏也能快速操作。
- **离线也完整。** 无账号、无服务器、无遥测。专注记录只保存在本机。
- **休眠后仍能接上。** 保存截止时间，重新打开时恢复或结算；暂停时间不计入专注。
- **保持轻量。** 没有第三方运行时依赖，源码、构建脚本与测试都在这个仓库中。

## 能做什么

| 功能 | 状态 |
| --- | --- |
| 15 / 25 / 45 分钟专注；5 / 10 / 15 分钟休息 | 可用 |
| 开始、暂停、继续、结束与专注记录 | 可用 |
| 菜单栏快捷面板、键盘快捷键 | 已实现 |
| 窗口毛玻璃与外观切换 | 已实机检查 |
| 小号 / 中号桌面小组件、App Intents 操作 | 源码已实现，待签名安装验证 |

macOS 26 及以上使用 Liquid Glass 按钮；较早系统使用 Material。开启“减少透明度”时，背景回退为实色。

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
| `⌘ ,` | 设置 |

本地构建使用 ad-hoc 签名；当前尚未提供公证发行包。运行验证以 Apple Silicon 为主。

## 开发

```sh
./scripts/test.sh          # 状态转换、重启恢复、跨进程存储
./scripts/check-native.sh  # SwiftUI / WidgetKit 编译检查
```

核心测试包含 34 项断言，以及 6 个进程并发执行的 246 次存储事务。详细边界与实机检查见 [QA.md](QA.md)。

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
