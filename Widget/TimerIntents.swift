import AppIntents
import WidgetKit

struct ToggleTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "开始或暂停"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if AFTERGLOW_WIDGET
        _ = try FocusStore.shared.toggle()
        WidgetCenter.shared.reloadAllTimelines()
        #else
        try await FocusModel.shared.performIntent(.toggle)
        #endif
        return .result()
    }
}

struct FinishTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "结束计时"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if AFTERGLOW_WIDGET
        _ = try FocusStore.shared.update(.finish)
        WidgetCenter.shared.reloadAllTimelines()
        #else
        try await FocusModel.shared.performIntent(.finish)
        #endif
        return .result()
    }
}

struct RestTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "开始休息"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if AFTERGLOW_WIDGET
        _ = try FocusStore.shared.startRest()
        WidgetCenter.shared.reloadAllTimelines()
        #else
        try await FocusModel.shared.performIntent(.rest)
        #endif
        return .result()
    }
}

struct WrapUpTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "收工"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        #if AFTERGLOW_WIDGET
        _ = try FocusStore.shared.update(.reset)
        WidgetCenter.shared.reloadAllTimelines()
        #else
        try await FocusModel.shared.performIntent(.reset)
        #endif
        return .result()
    }
}

// Keep the intent definitions in both targets for WidgetKit metadata, while
// routing execution through the host even when its window is closed. Reminder
// cancellation and scheduling then share one serialized coordinator.
#if !AFTERGLOW_WIDGET
extension ToggleTimerIntent: ForegroundContinuableIntent {}
extension FinishTimerIntent: ForegroundContinuableIntent {}
extension RestTimerIntent: ForegroundContinuableIntent {}
extension WrapUpTimerIntent: ForegroundContinuableIntent {}
#endif
