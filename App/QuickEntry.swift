import AppKit
import Carbon
import Combine
import SwiftUI

enum QuickEntryShortcut: String, CaseIterable, Identifiable {
    case disabled, controlOptionSpace, controlOptionN, controlShiftN
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: return "关闭"
        case .controlOptionSpace: return "⌃⌥ 空格"
        case .controlOptionN: return "⌃⌥ N"
        case .controlShiftN: return "⌃⇧ N"
        }
    }
    var keyCode: UInt32? {
        switch self {
        case .disabled: return nil
        case .controlOptionSpace: return UInt32(kVK_Space)
        case .controlOptionN, .controlShiftN: return UInt32(kVK_ANSI_N)
        }
    }
    var modifiers: UInt32 { UInt32(controlKey | (self == .controlShiftN ? shiftKey : optionKey)) }
    var usesVoiceOverModifiers: Bool { self == .controlOptionSpace || self == .controlOptionN }
}

enum QuickEntryError: Error, LocalizedError {
    case shortcutInUse, voiceOverConflict, shortcutRegistration(OSStatus), captureUnavailable
    var errorDescription: String? {
        switch self {
        case .shortcutInUse: return "此快捷键已被占用，请选择另一个。"
        case .voiceOverConflict: return "VoiceOver 正在使用 ⌃⌥，请选择 ⌃⇧ N 或从菜单添加。"
        case .shortcutRegistration: return "无法启用快捷键，请稍后重试。"
        case .captureUnavailable: return "Moro 尚未就绪，请稍后重试。"
        }
    }
}

@MainActor
protocol QuickEntryShortcutRegistering: AnyObject {
    var onTrigger: (@MainActor () -> Void)? { get set }
    var onInvalidation: (@MainActor (String) -> Void)? { get set }
    /// Failure must leave the previous registration intact.
    func register(_ shortcut: QuickEntryShortcut) throws
    func unregister()
}

private let quickEntrySignature: OSType = 0x4D4F524F // MORO

@MainActor
final class CarbonQuickEntryShortcutRegistrar: QuickEntryShortcutRegistering {
    var onTrigger: (@MainActor () -> Void)?
    var onInvalidation: (@MainActor (String) -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activeShortcut: QuickEntryShortcut = .disabled
    private var workspaceObserver: NSObjectProtocol?

    func register(_ shortcut: QuickEntryShortcut) throws {
        guard let keyCode = shortcut.keyCode else { unregister(); return }
        if shortcut.usesVoiceOverModifiers,
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.VoiceOver" }) {
            throw QuickEntryError.voiceOverConflict
        }
        // Inspect only when the user changes the binding, never on a timer.
        var symbolicKeys: Unmanaged<CFArray>?
        let symbolsStatus = CopySymbolicHotKeys(&symbolicKeys)
        guard symbolsStatus == noErr else { throw QuickEntryError.shortcutRegistration(symbolsStatus) }
        let systemKeys = symbolicKeys?.takeRetainedValue() as? [[String: Any]] ?? []
        if systemKeys.contains(where: { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == keyCode
                && (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == shortcut.modifiers
        }) { throw QuickEntryError.shortcutInUse }

        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == quickEntrySignature, identifier.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let registrar = Unmanaged<CarbonQuickEntryShortcutRegistrar>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor [weak registrar] in registrar?.onTrigger?() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw QuickEntryError.shortcutRegistration(status) }
        }

        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, shortcut.modifiers, EventHotKeyID(signature: quickEntrySignature, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &replacement)
        guard status == noErr, let replacement else {
            if hotKey == nil, let handler { RemoveEventHandler(handler); self.handler = nil }
            if status == eventHotKeyExistsErr { throw QuickEntryError.shortcutInUse }
            throw QuickEntryError.shortcutRegistration(status)
        }
        // Acquire the new binding first, so a conflict never loses the old one.
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        activeShortcut = shortcut
        observeVoiceOverLaunch()
    }

    private func observeVoiceOverLaunch() {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver); self.workspaceObserver = nil }
        guard activeShortcut.usesVoiceOverModifiers else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                                              object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == "com.apple.VoiceOver", self.activeShortcut.usesVoiceOverModifiers else { return }
                self.unregister()
                self.onInvalidation?("VoiceOver 已开启；快速添加快捷键已关闭，可改用 ⌃⇧ N。")
            }
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        activeShortcut = .disabled
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver); self.workspaceObserver = nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }
}

private final class QuickEntryPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class QuickEntryController: NSObject, ObservableObject, NSTextFieldDelegate, NSWindowDelegate {
    static let preferenceKey = "moro.quick-entry-shortcut"

    @Published var shortcut: QuickEntryShortcut = .disabled {
        didSet { if shortcut != oldValue && !restoringShortcut { applyShortcut(previous: oldValue) } }
    }
    @Published private(set) var issue: String?
    @Published var text = "" {
        didSet {
            if !readingField, inputField?.stringValue != text { inputField?.stringValue = text }
            captureIssue = nil
            updatePanel()
        }
    }
    @Published private(set) var captureIssue: String?
    @Published private(set) var isSaving = false
    @Published private(set) var isVisible = false

    private let registrar: QuickEntryShortcutRegistering
    private let capture: @MainActor (String) async throws -> UUID
    private let preferences: UserDefaults?
    private var restoringShortcut = false
    private var readingField = false
    private var panel: QuickEntryPanel?
    private weak var inputField: NSTextField?
    private weak var feedback: NSTextField?
    private weak var addButton: NSButton?
    private weak var progress: NSProgressIndicator?
    private var saveTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    convenience init(model: FocusModel, preferences: UserDefaults? = .standard) {
        self.init(preferences: preferences, registrar: CarbonQuickEntryShortcutRegistrar()) { [weak model] title in
            guard let model else { throw QuickEntryError.captureUnavailable }
            return try await model.captureInbox(title: title)
        }
    }

    /// The injected form keeps tests away from real shortcuts and user storage.
    init(preferences: UserDefaults? = nil, registrar: QuickEntryShortcutRegistering,
         capture: @escaping @MainActor (String) async throws -> UUID) {
        self.preferences = preferences; self.registrar = registrar; self.capture = capture
        super.init()
        registrar.onTrigger = { [weak self] in self?.show() }
        registrar.onInvalidation = { [weak self] message in
            guard let self else { return }
            self.restoringShortcut = true; self.shortcut = .disabled; self.restoringShortcut = false
            self.preferences?.set(QuickEntryShortcut.disabled.rawValue, forKey: Self.preferenceKey)
            self.issue = message
        }
        if let saved = preferences?.string(forKey: Self.preferenceKey),
           let selection = QuickEntryShortcut(rawValue: saved), selection != .disabled {
            restoringShortcut = true; shortcut = selection; restoringShortcut = false
            applyShortcut(previous: .disabled)
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    private func applyShortcut(previous: QuickEntryShortcut) {
        do {
            try registrar.register(shortcut)
            preferences?.set(shortcut.rawValue, forKey: Self.preferenceKey)
            issue = nil
        } catch {
            restoringShortcut = true; shortcut = previous; restoringShortcut = false
            preferences?.set(previous.rawValue, forKey: Self.preferenceKey)
            issue = error.localizedDescription
        }
    }

    func show() {
        if panel == nil { createPanel() }
        guard let panel else { return }
        updatePanel()
        if !panel.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let area = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.midX - panel.frame.width / 2, y: area.midY + area.height * 0.18 - panel.frame.height / 2))
            }
        }
        isVisible = true
        // A nonactivating panel accepts input without bringing the main window forward.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputField)
    }

    /// Escape closes the panel and retains the unsaved text for the next opening.
    func dismiss() {
        isVisible = false
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel?.contentView = nil
        panel = nil
    }

    func submit(hasMarkedText: Bool = false) {
        guard !hasMarkedText, !isSaving else { return }
        let rawText = text
        let title = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard title.count <= FocusTodo.maximumTitleLength else {
            captureIssue = "标题最多 \(FocusTodo.maximumTitleLength) 字。"; updatePanel(); return
        }
        isSaving = true; captureIssue = nil; updatePanel()
        saveTask = Task { [weak self, capture] in
            do {
                _ = try await capture(title)
                guard let self else { return }
                self.isSaving = false; self.captureIssue = nil
                if self.text == rawText { self.text = ""; self.dismiss() }
                else { self.updatePanel() }
            } catch {
                guard let self else { return }
                self.isSaving = false; self.captureIssue = error.localizedDescription; self.updatePanel()
            }
            self?.saveTask = nil
        }
    }

    func flush() async { await saveTask?.value }

    func shutdown() {
        registrar.unregister()
        registrar.onTrigger = nil
        registrar.onInvalidation = nil
        dismiss()
    }

    private func createPanel() {
        let panel = QuickEntryPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.title = "Moro 快速添加"
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true; panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.dismiss() }

        let material = NSVisualEffectView()
        material.material = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .windowBackground : .popover
        material.blendingMode = .behindWindow; material.state = .active
        panel.contentView = material

        let header = NSTextField(labelWithString: "收件箱")
        header.font = .systemFont(ofSize: 12, weight: .medium); header.textColor = .secondaryLabelColor
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭，保留输入")!, target: self, action: #selector(closePanel))
        close.bezelStyle = .inline; close.isBordered = false; close.toolTip = "关闭，保留输入 (Esc)"
        close.setAccessibilityLabel("关闭，保留输入")
        let headerRow = NSStackView(views: [header, NSView(), close])
        headerRow.orientation = .horizontal; headerRow.alignment = .centerY

        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 20); field.textColor = .labelColor
        field.placeholderString = "记下一件事"; field.stringValue = text
        field.usesSingleLineMode = true; field.lineBreakMode = .byTruncatingTail
        field.delegate = self; field.setAccessibilityLabel("待办标题")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let status = NSTextField(wrappingLabelWithString: "Esc 关闭，保留输入")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let add = NSButton(title: "添加", target: self, action: #selector(addTask))
        add.bezelStyle = .rounded; add.controlSize = .regular
        add.toolTip = "添加到收件箱 (Return)"; add.setAccessibilityLabel("添加到收件箱")
        let footer = NSStackView(views: [status, spinner, add])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 8

        let column = NSStackView(views: [headerRow, field, footer])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 22),
            column.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -22),
            column.topAnchor.constraint(equalTo: material.topAnchor, constant: 18),
            column.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -18),
            headerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            field.widthAnchor.constraint(equalTo: column.widthAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            footer.widthAnchor.constraint(equalTo: column.widthAnchor),
            close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24),
            add.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
        self.panel = panel; inputField = field; feedback = status; addButton = add; progress = spinner
    }

    private func updatePanel() {
        addButton?.isEnabled = !isSaving && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        feedback?.stringValue = captureIssue ?? (isSaving ? "正在添加…" : "Esc 关闭，保留输入")
        feedback?.textColor = captureIssue == nil ? .secondaryLabelColor : .systemRed
        if isSaving { progress?.startAnimation(nil) } else { progress?.stopAnimation(nil) }
    }

    @objc private func closePanel() { dismiss() }
    @objc private func addTask() { submit(hasMarkedText: (inputField?.currentEditor() as? NSTextView)?.hasMarkedText() == true) }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === inputField else { return }
        readingField = true; text = field.stringValue; readingField = false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            guard !textView.hasMarkedText() else { return false }
            submit(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            guard !textView.hasMarkedText() else { return false }
            dismiss(); return true
        }
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { dismiss(); return false }
    func windowDidResignKey(_ notification: Notification) { if isVisible { dismiss() } }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        saveTask?.cancel()
        let registrar = registrar
        let panel = panel
        Task { @MainActor in
            registrar.unregister(); registrar.onTrigger = nil; registrar.onInvalidation = nil
            panel?.delegate = nil; panel?.orderOut(nil); panel?.contentView = nil
        }
    }
}

struct QuickEntrySettings: View {
    @ObservedObject var controller: QuickEntryController
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("全局快速添加", selection: $controller.shortcut) {
                ForEach(QuickEntryShortcut.allCases) { shortcut in Text(shortcut.title).tag(shortcut) }
            }
            .help("Moro 运行时可从其他应用添加到收件箱，默认关闭。")
            if let issue = controller.issue { Text(issue).font(.caption).foregroundStyle(.red) }
            Button("打开快速添加") { controller.show() }
        }
    }
}
