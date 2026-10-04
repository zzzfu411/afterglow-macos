<p align="center"><img src="docs/assets/icon.png" width="96" alt="Afterglow icon" /></p>

<h1 align="center">Afterglow · 留白</h1>

<p align="center">Turn a to-do into focused time. Native macOS, offline, quiet.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-475569?logo=apple&logoColor=white" alt="macOS 14 or later" />
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white" alt="Native SwiftUI app" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b" alt="MIT license" /></a>
  <img src="https://img.shields.io/badge/status-preview-8b7355" alt="Preview status" />
</p>

<p align="center">
  <a href="README.md">简体中文</a> · English<br />
  <a href="#get-started">Get started</a> · <a href="docs/BUILDING.md">Desktop widgets</a> · <a href="CONTRIBUTING.md">Contribute</a>
</p>

<p align="center">
  <img src="Preview/widget-preview.png" width="860" alt="Small and medium widget layouts in dark and light color treatments" />
  <br /><sub>Layout and color study. macOS composites the actual background blur.</sub>
</p>

> **Early preview:** the native app runs locally. Both app and widget pass a full Xcode build; signed installation and on-desktop interactions still need validation.

## Why Afterglow

Write down a task, estimate its time, and focus. Afterglow connects your checklist, timer, and session history with tasks on the left and a quiet timer on the right.

- **At home on Mac.** SwiftUI, AppKit, system materials, SF Pro, and SF Symbols. Dark, light, and automatic appearance.
- **A few clicks.** Pick a duration and start. Press Space to pause or resume, or use the menu bar panel.
- **A persistent sidebar.** Resize or collapse the native split view. Selecting a task keeps the list visible; sidebar visibility is remembered.
- **From tasks to time.** Choose one item, the whole unfinished list, or free focus. Estimates set the timer; session duration can be adjusted independently.
- **Completion stays yours.** Select a task to focus, use its menu to mark it done, and undo or restore mistakes. List edits preserve the current countdown and historical names.
- **Offline by design.** No accounts, servers, or telemetry. Tasks and session history stay on your Mac.
- **Keeps its place.** Persisted deadlines survive sleep and relaunch. Paused time does not count as focused time.
- **Quiet in the background.** Event-driven storage and a single deadline wake-up. No idle polling or third-party runtime dependencies. [Measurement notes](docs/PERFORMANCE.md).

## Features

| Feature | Status |
| --- | --- |
| 15 / 25 / 45-minute focus; 5 / 10 / 15-minute breaks | Available |
| Type 1–180 minutes and press Return; focus and break durations remembered separately | Available |
| Resizable, collapsible task sidebar | Available |
| Tasks with estimates, editing, completion, undo, reopening, and deletion confirmation | Available |
| Single-task, whole-list, or free focus; adjustable session duration | Available |
| Start, pause, resume, finish, and session history | Available |
| One-click next phase and wrap-up | Available |
| System completion reminders and sound | Implemented; requires permission; OS delivery not yet verified |
| Menu bar panel and keyboard shortcuts | Implemented |
| Window materials and appearance switching | Checked on a real Mac |
| Resizable window and adaptive timer size | Available |
| Small / medium WidgetKit widgets and App Intents | Implemented; signed installation not yet validated |

When built with Xcode 26+, app buttons use Liquid Glass on macOS 26+. Earlier toolchains or systems use Material. Reduce Transparency switches surfaces to solid colors.

### Start with a task

1. Click `+` in the sidebar or press `⌘ N`. Enter a task and estimated minutes.
2. Select a task using its circle, title, or Focus button, or choose the whole list. Then start the timer.
3. Use the task’s `···` menu to mark it done. Undo a mistake immediately, or expand Completed and choose Restore.

A whole-list session is one countdown totaling unfinished estimates. Each estimate is 1–180 minutes, with up to 100 saved items; a whole list can exceed 180 minutes. Adjusting the session timer does not change task estimates. Free focus retains its own duration, and completed items collapse into a separate section. Use the toolbar button or `⌘ B` to toggle the sidebar. Editing stays in the sidebar, and hiding it retains an unfinished draft.

## Get started

Requires macOS 14+ with Apple Command Line Tools or full Xcode. The app interface is currently in Chinese.

```sh
git clone https://github.com/zzzfu411/afterglow-macos.git
cd afterglow-macos
./scripts/build-local.sh
open .build/local/留白.app
```

This builds the app and menu bar panel only. Desktop widgets require full Xcode and a valid signing configuration. See [build instructions](docs/BUILDING.md) (Chinese, with shell commands).

| Shortcut | Action |
| --- | --- |
| `Space` | Start / pause / resume |
| `⌘ .` | Finish |
| `⌘ N` | Add a task |
| `⌘ B` | Toggle the task sidebar |
| `⌘ ,` | Settings |

Local builds are ad-hoc signed. No notarized distribution is available yet. Runtime validation has primarily used Apple Silicon. See [packaging and distribution](docs/RELEASING.md).

The first start in the app requests notification permission; Settings also offers an explicit enable action. Pausing or finishing early cancels the reminder. Natural completion leaves delivery to macOS. System notification, Focus, and sound settings affect presentation.

## Development

```sh
./scripts/test.sh          # Timer transitions, restart, and concurrent storage
./scripts/test-window.sh   # Native appearance transitions and layout bounds
./scripts/test-runtime.sh  # Reminder races, file events, deadlines, no idle polling
./scripts/check-native.sh  # SwiftUI and WidgetKit compilation
```

Tests cover 115 core assertions, 246 transactions across six concurrent processes, 92 native appearance, layout, and display checks, and 95 reminder/runtime checks. [GitHub Actions](https://github.com/zzzfu411/afterglow-macos/actions/workflows/ci.yml) runs tests, native compilation, and a full Xcode build. See [QA.md](QA.md) for validation scope and remaining gaps.

Existing timer data loads directly. The first checklist write upgrades storage to version 2; older apps reject that format instead of silently dropping tasks. Back up your data and use a matching older data file before downgrading.

```text
App/       Windows, menu bar, and settings
Widget/    WidgetKit timelines and App Intents
Shared/    Timer state, storage, and views
Tests/     State and persistence tests
```

## Next

- [ ] Validate signed widgets in the desktop gallery and widget host
- [ ] Check wallpaper, monochrome, and transparent appearances
- [ ] Prepare notarized distribution

Issues, visual feedback, and focused improvements are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). System fonts and SF Symbols are accessed through Apple frameworks; font files are not redistributed.
