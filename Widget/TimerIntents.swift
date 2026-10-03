import AppIntents
import WidgetKit

struct ToggleTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "开始或暂停"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        // State-dependent action must be resolved within the store transaction.
        _ = try FocusStore.shared.toggle()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct FinishTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "结束计时"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        _ = try FocusStore.shared.update(.finish)
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RestTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "开始休息"
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        _ = try FocusStore.shared.startRest()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
