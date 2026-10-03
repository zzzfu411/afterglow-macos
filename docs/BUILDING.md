# 构建与安装

## 主应用

需要 macOS 14 或更高，以及 Apple Command Line Tools 或完整 Xcode。

```sh
./scripts/build-local.sh
open .build/local/留白.app
```

脚本按当前 Mac 的架构构建，使用 ad-hoc 签名，输出在 `.build/local/`。这一构建只含主应用和菜单栏，不安装 WidgetKit 扩展，也不代表公证发行包。

## 桌面小组件

这部分需要[完整 Xcode](https://developer.apple.com/xcode/)和有效的 Apple 开发签名配置。推荐 Xcode 26+，以编译 Liquid Glass 分支；运行目标仍为 macOS 14+。

1. 在 Xcode 打开 `Afterglow.xcodeproj`。
2. 给 **Afterglow** 和 **AfterglowWidgets** 两个 target 选择同一个真实 Team。
3. 核对两边的 App Group entitlement 与 Info.plist。默认标识为 `$(DEVELOPMENT_TEAM).app.afterglow.shared`。
4. 选择 **Afterglow** scheme、**My Mac**，构建并运行宿主一次。
5. 右键桌面 → **编辑小组件** → 搜索 **留白**，添加小号或中号。

也可使用终端：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./scripts/build-xcode.sh YOUR_TEAM_ID
```

将 `YOUR_TEAM_ID` 替换为真实的 10 位 Team ID。此命令不改变全局 `xcode-select`，不自动登录、申请证书或接受协议。

也可以把 Team 写入被 Git 忽略的 `Config/Local.xcconfig`：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

App Group 使用 macOS 专用的 Team 前缀形式。ad-hoc 签名不能替代共享容器授权。组件访问不到共享容器时会显示“打开留白”，而不是创建一个独立计时器。

**状态：组件源码已编译、链接；签名后的桌面安装与交互尚未验证。** 完整检查记录见 [QA.md](../QA.md)。

## 数据与外观

本地预览版的数据路径：

```text
~/Library/Application Support/Afterglow/Standalone/focus-state.json
```

签名版应用与组件在 App Group 中共享数据，与本地预览版分开。外观偏好保存在应用的本机 UserDefaults。此项目不会读取旧网页版本的数据。

计时使用保存的截止日期。每次写入都会持有文件锁，读取最新状态后原子保存；过期结算使用原截止时间，历史记录以 UUID 去重。组件数字由系统日期视图更新，业务代码不依赖每秒后台执行。

主窗口使用 `NSVisualEffectView` 对窗口后方内容进行模糊。macOS 26+ 的按钮使用 Liquid Glass，旧系统使用 Material；“减少透明度”开启时使用实色。桌面组件的最终外观由 WidgetKit 渲染模式决定。

## 开发命令

```sh
./scripts/test.sh
./scripts/check-native.sh
./scripts/render-preview.sh
./scripts/render-icon.sh
python3 scripts/generate-project.py
```

`render-preview.sh` 导出共用视图的字体、布局和静态材质配色示意。离屏渲染无法取样真实桌面，不用于验证 WindowServer 或 WidgetKit 的背景模糊。

工程由 `generate-project.py` 生成；修改源文件列表或工程配置时，更新生成器后重新生成，避免下一次生成覆盖手动调整。

## 发布前

- 验证完整 Xcode 构建和 App Intents 元数据。
- 验证签名版宿主启动后，组件进入系统图库。
- 验证关闭主窗口、退出宿主后，组件读写与倒计时仍正确。
- 检查单色、着色、深浅色和不同壁纸的可读性。
- 如分发安装包，完成 Developer ID 签名与公证。

参考：[创建 Widget Extension](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension) · [交互式组件](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities) · [共享容器授权](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) · [Liquid Glass 与着色模式](https://developer.apple.com/documentation/widgetkit/optimizing-your-widget-for-accented-rendering-mode-and-liquid-glass)
