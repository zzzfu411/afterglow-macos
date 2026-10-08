<p align="center"><img src="docs/assets/icon.png" width="96" alt="Moro icon" /></p>

<h1 align="center">Moro</h1>

<p align="center">A small Mac to-do app. Write it down. Focus when you need to.</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-475569?logo=apple&logoColor=white" alt="macOS 14 or later" />
  <img src="https://img.shields.io/badge/SwiftUI-native-F05138?logo=swift&logoColor=white" alt="Native SwiftUI app" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-64748b" alt="MIT license" /></a>
  <img src="https://img.shields.io/badge/status-0.7.0_preview-8b7355" alt="0.7.0 preview status" />
</p>

<p align="center">
  <a href="README.md">简体中文</a> · English<br />
  <a href="#get-started">Get started</a> · <a href="docs/SIDEBAR.md">Usage</a> · <a href="docs/BUILDING.md">Build and widgets</a> · <a href="CONTRIBUTING.md">Contribute</a>
</p>

> **0.7.0 preview:** tasks now lead the main window. Widget source compiles and links; this version's full Xcode CI, signed installation, and desktop interactions still need validation. See [QA.md](QA.md).

## Why Moro

- **Capture first.** A title and Return are enough. Add notes, dates, estimates, and steps when useful.
- **See what matters today.** Inbox, Today, Upcoming, custom collections, cross-collection search, batch actions, and manual ordering.
- **Recover from mistakes.** Completion, editing, and focus have separate controls. Undo, redo, reopen completed tasks, or restore from Recently Deleted.
- **Focus from the task.** Press ▶ to start a session while keeping the list available. When time is up, choose to continue, rest, or complete the task.
- **At home on your Mac.** SwiftUI, AppKit, system fonts, and light/dark appearance. A solid reading surface with native sidebar vibrancy. No account, server, or telemetry.

## Everyday use

1. Press `⌘ N`, type a title, and press Return. Keep adding tasks without estimating each one first.
2. Click a title to expand its details. Schedule it for today, move it to a collection, or add notes and dates.
3. Click the completion control when done. Use `⌘ Z` for a mistake, or restore items from Completed and Recently Deleted.

| Optional field | Meaning |
| --- | --- |
| Planned date | When you intend to work on it; rescheduling does not move its deadline |
| Due date | When it must be done; a date alone or an exact time |
| Reminder | An independent system notification; a deadline alone does not notify |
| Estimate | How much work you expect; optional and separate from the session timer |

Details support one level of steps and daily, weekly, or monthly recurrence. Completing a recurring task creates its next occurrence; reopening and completing it again does not create duplicates.

`⌘ F` searches titles and notes across nondeleted tasks. Search inside Recently Deleted to find deleted items. See [usage and date rules](docs/SIDEBAR.md) (Chinese).

### Focus when needed

A task's ▶ uses the remembered duration. Its adjacent menu offers 15 / 25 / 45 minutes or direct input of **1–180 minutes**. A confirmed choice becomes the next default without changing the task's estimate. Switching tasks or setting a new duration during an active session requires confirmation and saves the time already spent.

Start a sequential focus queue from the list menu or a multiple selection. One task runs at a time, and you choose when to advance. Skipping or reaching zero never marks a task complete. A compact bottom bar handles pause, resume, and finish; the larger focus view is optional.

Time is attributed by stable task ID. Per-task statistics use the **latest 1,000 retained focus logs**, not a lifetime total. Legacy logs without a single task ID stay in history rather than being matched by title.

### Capture from anywhere

Quick entry is available from the menu bar. Its global shortcut is off by default; choose `⌃⌥ Space`, `⌃⌥ N`, or `⌃⇧ N` in Settings. Conflicts are reported, and no Accessibility permission is required. The independent entry panel saves to Inbox, closes after a successful Return, and retains its draft when dismissed with Esc.

Task reminders require notification permission. Moro schedules the nearest **48 reminders** first and reports deferred items in Settings. Returning to the app fills available slots; deferred reminders cannot be added while the app is quit. System Focus and sound settings also affect delivery.

## Get started

Requires macOS 14+ and Apple Command Line Tools or full Xcode. The app interface is currently in Chinese.

```sh
git clone https://github.com/zzzfu411/afterglow-macos.git
cd afterglow-macos
./scripts/build-local.sh
open .build/local/Moro.app
```

The script builds an ad-hoc signed app for your Mac's architecture. It does not install into Applications or include a desktop widget. Widgets require full Xcode, valid signing, and an App Group; see [build instructions](docs/BUILDING.md) (Chinese, with shell commands). No validated notarized release package is available yet.

| Shortcut | Action |
| --- | --- |
| `⌘ N` → Return | Enter and save a new task |
| `⌘ B` | Toggle navigation sidebar |
| `⌘ F` | Search tasks |
| `⌘ Z` / `⇧⌘ Z` | Undo / redo; text editing takes priority in text fields |
| `⌘ Return` | Start / pause / resume focus |
| `Space` | Control the timer only in the focus view |
| `⌘ .` | Finish the current session |
| `⌘ ,` | Settings |

## Local data and resources

Data stays on your Mac. Export tasks to JSON or preview and merge an import. Archive **v2** includes tasks and collections and can read v1 archives. It excludes the timer, focus logs, and preferences, so a task export is not a complete backup.

Storage is **v5**. The first read of an older format backs up the original file before migration; downgrading requires a matching backup. Limits are **1,000 pending tasks and 10,000 retained tasks in total**, including completed and deleted items. See [data and recovery](docs/BUILDING.md#数据备份与升级).

Native code, with no WebView, Electron, or third-party runtime dependency. Storage operations are serialized, lists display in batches, and idle storage is not polled. [Resource measurements](docs/PERFORMANCE.md) include their test conditions; model benchmarks are not whole-app measurements.

## Development

```sh
./scripts/test.sh          # State, recurrence, migration, concurrent storage
./scripts/test-runtime.sh  # Async storage, drafts, queues, reminders, model stress
./scripts/check-native.sh  # SwiftUI and WidgetKit compilation
```

More test commands are in the [build guide](docs/BUILDING.md#开发检查). [GitHub Actions](https://github.com/zzzfu411/afterglow-macos/actions/workflows/ci.yml) is configured for tests, native compilation, and a full Xcode build. **The full 0.7.0 Xcode CI run is pending this code being pushed**; older successful runs do not validate this version.

```text
App/       Windows, tasks, quick entry, reminders, settings
Shared/    Tasks, timer state, transactional storage, widget snapshot
Widget/    Today list, current focus, App Intents
Tests/     State, storage, notifications, archives, layout, runtime
```

Issues, visual feedback, and focused changes are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE). System fonts and SF Symbols are accessed through Apple frameworks; font files are not redistributed.
