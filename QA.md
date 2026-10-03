# 原生版本验证

日期：2026-10-03（Asia/Shanghai）。

环境：Apple Silicon，macOS 27.0.1，Swift 6.4，CLT macOS SDK，Swift 5 language mode，部署目标 macOS 14。

## 0.2 视觉更新

- 新增 `NSVisualEffectView` 窗口后方模糊、明确的深浅色材质外观；主按钮使用 macOS 26 Liquid Glass，旧系统保留 Material 分支。
- 主窗口实机启动、尺寸和 SF Pro 数字排版检查通过；设置中浅色／深色切换实测通过。
- 新增系统“减少透明度”的实色分支，编译通过；未修改用户的系统辅助功能设置。
- WidgetKit 可移除背景、渲染模式适配、扩展完整编译及链接通过；系统桌面宿主仍未验证。
- 静态图明确标注材质示意。ImageRenderer 无法正确取样桌面背景，原生 Material 在离屏渲染出现纹理伪影，因此展示共用文字／控件内容和透明配色层，不将示意图冒充桌面截图。
- 未改动计时状态机或共享存储格式，保留既有时长设置和历史数据。

## 已验证

- Foundation 模型与存储：34 项断言通过，含 6 个独立进程并发执行 246 次共享文件事务。
- 暂停／续计不把暂停时间计入专注；过期、隔日重开按原截止时间结算；UUID 去重；损坏文件不被覆盖。
- 主应用完整编译并生成本地 ad-hoc 签名 `.app`。
- 应用与 App Intents 源码 typecheck 通过。
- WidgetKit Extension 使用 `-application-extension` 完整编译、链接通过。
- 两个 target 的 plist、entitlements、project.pbxproj 格式检查通过，工程文件和对象引用完整。
- 实际启动应用并点击 15 分钟、开始、暂停、空格继续、结束、记录、休息切换；观察到计时和记录变化。
- 设置显示本地预览构建状态，没有宣称桌面组件已安装。
- 共享 SwiftUI 组件内容已导出浅色／深色、小号／中号字体与配色预览。

## 实测修复

开始计时后，菜单栏中的动态日期 `Text` 在当前系统触发 AppKit `MenuBarExtraController.updateButton` 的布局循环。线程采样定位后改为稳定的菜单栏图标，重新运行上述主窗口流程通过。倒计时放在面板内容中。

## 尚未验证

这台机器没有完整 Xcode，没有验证 Xcode 全工程构建、签名 App Group 授权、App Intents 元数据生成、系统小组件图库注册、桌面按钮或退出宿主后的交互。

编译成功、原生预览图和主窗口运行成功都不能替代这一步。没有生成或注册一个未经验证的 `.appex` 安装包，也没有改变系统开发工具选择或系统安全设置。

小组件外观需在系统 WidgetKit 宿主中补测，尤其是桌面单色／自动渲染模式；当前预览是共享 SwiftUI 内容的渲染结果。
