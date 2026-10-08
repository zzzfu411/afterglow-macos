import AppKit
import Foundation

@MainActor
private final class FakeShortcutRegistrar: QuickEntryShortcutRegistering {
    var onTrigger: (@MainActor () -> Void)?
    var onInvalidation: (@MainActor (String) -> Void)?
    var rejected: Set<QuickEntryShortcut> = []
    private(set) var active: QuickEntryShortcut = .disabled
    private(set) var registrations: [QuickEntryShortcut] = []
    private(set) var unregisters = 0
    func register(_ shortcut: QuickEntryShortcut) throws {
        registrations.append(shortcut)
        if rejected.contains(shortcut) { throw QuickEntryError.shortcutInUse }
        active = shortcut
    }
    func unregister() { unregisters += 1; active = .disabled }
}

@MainActor
private final class ControlledCapture {
    var holdNext = false
    var shouldFail = false
    private(set) var titles: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    var isSuspended: Bool { continuation != nil }
    func save(_ title: String) async throws -> UUID {
        titles.append(title)
        if holdNext { holdNext = false; await withCheckedContinuation { continuation = $0 } }
        if shouldFail { throw QuickEntryError.captureUnavailable }
        return UUID()
    }
    func release() {
        let continuation = continuation; self.continuation = nil
        continuation?.resume()
    }
}

@main
struct ShortcutTests {
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError("FAIL: \(message)") }
        checks += 1
    }
    @MainActor private static func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(3)
        while !condition(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        expect(condition(), message)
    }

    @MainActor private static func registrationTests() async {
        let suite = "moro-shortcut-tests-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let registrar = FakeShortcutRegistrar()
        let controller = QuickEntryController(preferences: preferences, registrar: registrar) { _ in UUID() }
        expect(controller.shortcut == .disabled && registrar.registrations.isEmpty,
               "new installations do not register a global shortcut")
        expect(registrar.onTrigger != nil, "registered keys have a weak controller callback ready")
        controller.shortcut = .controlOptionN
        expect(registrar.active == .controlOptionN && controller.issue == nil, "an explicit selection registers the chosen shortcut")
        expect(preferences.string(forKey: QuickEntryController.preferenceKey) == QuickEntryShortcut.controlOptionN.rawValue,
               "successful shortcut selection persists")
        registrar.rejected = [.controlOptionSpace]
        controller.shortcut = .controlOptionSpace
        expect(controller.shortcut == .controlOptionN && registrar.active == .controlOptionN,
               "a conflict preserves the previous working registration")
        expect(controller.issue?.contains("占用") == true, "a registration conflict is visible")
        expect(preferences.string(forKey: QuickEntryController.preferenceKey) == QuickEntryShortcut.controlOptionN.rawValue,
               "failed registration does not overwrite the stored binding")
        let attempts = registrar.registrations.count
        controller.shortcut = .controlOptionN
        expect(registrar.registrations.count == attempts, "reselecting the current shortcut does not register twice")
        controller.shortcut = .disabled
        expect(registrar.active == .disabled && controller.issue == nil, "disabling removes the registration and its stale error")
        expect(preferences.string(forKey: QuickEntryController.preferenceKey) == QuickEntryShortcut.disabled.rawValue,
               "disabled preference persists")
        controller.shortcut = .controlOptionN
        registrar.unregister(); registrar.onInvalidation?("VoiceOver 已开启")
        expect(controller.shortcut == .disabled && controller.issue?.contains("VoiceOver") == true,
               "a newly active system conflict is reflected immediately without polling")
        expect(preferences.string(forKey: QuickEntryController.preferenceKey) == QuickEntryShortcut.disabled.rawValue,
               "a system-invalidated shortcut stays disabled on relaunch")
        controller.shortcut = .controlShiftN
        expect(registrar.active == .controlShiftN && controller.issue == nil,
               "a shortcut without VoiceOver modifiers remains available")
        controller.shutdown()
        expect(registrar.onTrigger == nil && registrar.active == .disabled, "shutdown unregisters and removes the callback")

        preferences.set(QuickEntryShortcut.controlOptionSpace.rawValue, forKey: QuickEntryController.preferenceKey)
        let restoredRegistrar = FakeShortcutRegistrar()
        let restored = QuickEntryController(preferences: preferences, registrar: restoredRegistrar) { _ in UUID() }
        expect(restored.shortcut == .controlOptionSpace && restoredRegistrar.active == .controlOptionSpace,
               "relaunch restores an intentionally enabled binding")
        restored.shutdown()
        let blockedRegistrar = FakeShortcutRegistrar()
        blockedRegistrar.rejected = [.controlOptionSpace]
        let blocked = QuickEntryController(preferences: preferences, registrar: blockedRegistrar) { _ in UUID() }
        expect(blocked.shortcut == .disabled && blocked.issue != nil && blockedRegistrar.active == .disabled,
               "a binding newly occupied on relaunch falls back safely to disabled")
        expect(preferences.string(forKey: QuickEntryController.preferenceKey) == QuickEntryShortcut.disabled.rawValue,
               "a disabled fallback does not silently re-enable a failed binding on the next launch")
        blocked.shutdown()
        preferences.set("unknown-future-value", forKey: QuickEntryController.preferenceKey)
        let invalidRegistrar = FakeShortcutRegistrar()
        let invalid = QuickEntryController(preferences: preferences, registrar: invalidRegistrar) { _ in UUID() }
        expect(invalid.shortcut == .disabled && invalidRegistrar.registrations.isEmpty,
               "an invalid preference never registers an unintended key")
        invalid.shutdown()

        let releasedRegistrar = FakeShortcutRegistrar()
        var released: QuickEntryController? = QuickEntryController(registrar: releasedRegistrar) { _ in UUID() }
        released?.shortcut = .controlOptionN
        let wasReleased = { [weak released] in released == nil }
        released = nil
        await waitUntil("a discarded controller unregisters even if its registrar is retained elsewhere") {
            wasReleased() && releasedRegistrar.active == .disabled && releasedRegistrar.onTrigger == nil
        }
    }

    @MainActor private static func captureTests() async {
        let registrar = FakeShortcutRegistrar(), capture = ControlledCapture()
        let controller = QuickEntryController(registrar: registrar, capture: capture.save)
        controller.text = "  \n  "
        controller.submit()
        await controller.flush()
        expect(capture.titles.isEmpty, "blank quick entry is not submitted")
        controller.text = String(repeating: "文", count: FocusTodo.maximumTitleLength + 1)
        controller.submit()
        expect(capture.titles.isEmpty && controller.captureIssue != nil, "overlong text remains editable with an error")
        controller.text = "中文候选"
        controller.submit(hasMarkedText: true)
        expect(capture.titles.isEmpty && !controller.isSaving, "IME composition confirmation does not submit a task")
        controller.dismiss()
        expect(controller.text == "中文候选", "Escape retains the unsaved input")

        controller.text = "  添加到收件箱  "
        capture.holdNext = true
        controller.submit()
        await waitUntil("quick capture reaches the suspended persistence service") { capture.isSuspended }
        expect(controller.isSaving && controller.text == "  添加到收件箱  ", "input is retained until persistence succeeds")
        controller.submit()
        expect(capture.titles == ["添加到收件箱"], "repeated Return cannot create duplicate in-flight tasks")
        var didFlush = false
        let waiter = Task { @MainActor in await controller.flush(); didFlush = true }
        await Task.yield()
        expect(!didFlush, "flush awaits the asynchronous capture")
        capture.release()
        await waiter.value
        expect(controller.text.isEmpty && !controller.isSaving && controller.captureIssue == nil,
               "successful capture clears only the committed input")

        capture.holdNext = true
        controller.text = "先提交这一条"
        controller.submit()
        await waitUntil("second capture is suspended") { capture.isSuspended }
        controller.text = "随后输入的下一条"
        capture.release()
        await controller.flush()
        expect(controller.text == "随后输入的下一条" && !controller.isSaving,
               "an earlier success does not clear text typed while saving")
        capture.shouldFail = true
        controller.submit()
        await controller.flush()
        expect(controller.text == "随后输入的下一条" && controller.captureIssue != nil && !controller.isSaving,
               "failed capture preserves the title for retry")
        capture.shouldFail = false
        controller.submit()
        await controller.flush()
        expect(controller.text.isEmpty && controller.captureIssue == nil, "a successful retry clears the old failure")
        let count = capture.titles.count
        try? await Task.sleep(nanoseconds: 100_000_000)
        expect(capture.titles.count == count && registrar.registrations.isEmpty, "idle capture does not poll or enable shortcuts")
        controller.shutdown()
    }

    @MainActor private static func modelIntegrationTest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moro-shortcut-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FocusStore(directory: root)
        let model = FocusModel(store: store, remindersEnabled: false)
        await model.flush()
        model.section = .today
        model.quickEntryText = "主窗口尚未提交"
        model.todoDraft = TodoDraft()
        model.todoDraft?.title = "主窗口正在编辑"
        let registrar = FakeShortcutRegistrar()
        let controller = QuickEntryController(registrar: registrar) { try await model.captureInbox(title: $0) }
        controller.text = "全局录入"
        controller.submit()
        await controller.flush()
        await model.flush()
        let item = try store.snapshot().todos.first!
        expect(item.title == "全局录入" && item.listID == nil && item.plannedDate == nil && item.estimatedMinutes == nil,
               "quick capture creates a title-only Inbox task independently of current navigation")
        expect(model.section == .today && model.quickEntryText == "主窗口尚未提交" && model.todoDraft?.title == "主窗口正在编辑",
               "global capture leaves the main window's selection and drafts untouched")
        expect(model.canUndoTodo, "global capture participates in ordinary task undo")
        controller.shutdown()
    }

    @MainActor static func main() async throws {
        await registrationTests()
        await captureTests()
        try await modelIntegrationTest()
        print("PASS: \(checks) quick-entry checks (fake hotkeys; no global registration or real user data)")
    }
}
