import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FocusStoreError: Error, LocalizedError {
    case sharedContainerUnavailable(String)
    case unsupportedPlatform
    case fileLockFailed(Int32)
    case oversizedData

    public var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable(let reason):
            return "共享存储不可用：\(reason)"
        case .unsupportedPlatform:
            return "此存储需要 macOS 文件锁支持。"
        case .fileLockFailed(let code):
            return "无法锁定计时数据（\(code)），请重试。"
        case .oversizedData:
            return "计时数据文件过大，原文件已保留。"
        }
    }
}

/// Every action reads the latest file while holding both an in-process lock and
/// a cross-process advisory lock. App and widget must use the same App Group ID
/// and this store; synchronization is not provided to unrelated file writers.
public final class FocusStore: @unchecked Sendable {
    public static let shared = FocusStore()
    private static let processLock = NSLock()

    public let isShared: Bool
    public let availabilityDescription: String
    public let directoryURL: URL?

    private let unavailableReason: String?
    private let fileManager = FileManager.default

    public init(bundle: Bundle = .main) {
        let configured = (bundle.object(forInfoDictionaryKey: "AfterglowAppGroup") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isExtension = bundle.bundleURL.pathExtension == "appex"
            || bundle.object(forInfoDictionaryKey: "NSExtension") != nil
        let resolvedIdentifier = !configured.isEmpty && !configured.contains("$(")

        if resolvedIdentifier,
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: configured) {
            directoryURL = container.appendingPathComponent("Afterglow", isDirectory: true)
            isShared = true
            availabilityDescription = "App Group 共享存储"
            unavailableReason = nil
        } else {
            let reason = resolvedIdentifier ? "请检查 App Group 签名与权限。" : "未配置 AfterglowAppGroup。"
            isShared = false
            unavailableReason = reason
            if isExtension {
                // A widget must not silently show a separate, unrelated timer.
                directoryURL = nil
                availabilityDescription = "小组件无法访问共享计时。\(reason)"
            } else {
                directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("Afterglow/Standalone", isDirectory: true)
                availabilityDescription = "仅本应用存储，不与桌面小组件共享。\(reason)"
            }
        }
    }

    /// An explicit independent directory, useful for isolated previews and tests.
    public init(directory: URL) {
        directoryURL = directory
        isShared = false
        availabilityDescription = "独立目录存储，不代表 App Group 共享。"
        unavailableReason = nil
    }

    /// Settle overdue sessions in the same transaction as the read, exactly once.
    public func snapshot(at now: Date = Date()) throws -> FocusState {
        try update(.settle, at: now)
    }

    @discardableResult
    public func update(_ action: FocusAction, at now: Date = Date()) throws -> FocusState {
        try transaction { $0.applying(action, at: now) }
    }

    @discardableResult
    public func toggle(at now: Date = Date()) throws -> FocusState {
        try transaction { previous in
            let settled = previous.applying(.settle, at: now)
            // A click on an expired running widget must settle it, not start the
            // following phase behind an interface that still showed Pause.
            if previous.status == .running, settled.status == .done { return settled }
            let action: FocusAction = settled.status == .running ? .pause : (settled.status == .done ? .startNext : .start)
            return settled.applying(action, at: now)
        }
    }

    @discardableResult
    public func startRest(at now: Date = Date()) throws -> FocusState {
        try transaction { previous in
            let settled = previous.applying(.settle, at: now)
            guard !settled.isActive else { return settled }
            return settled.applying(.selectMode(.rest), at: now).applying(.start, at: now)
        }
    }

    private func transaction(_ transform: (FocusState) -> FocusState) throws -> FocusState {
        try withExclusiveLock { directory in
            let file = directory.appendingPathComponent("focus-state.json")
            let previous = try read(file)
            let next = transform(previous)
            try next.validate()
            if next != previous {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                encoder.outputFormatting = [.sortedKeys]
                // Rename atomically while retaining the lock on a separate file.
                try encoder.encode(next).write(to: file, options: .atomic)
            }
            return next
        }
    }

    private func read(_ file: URL) throws -> FocusState {
        guard fileManager.fileExists(atPath: file.path) else { return FocusState() }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 2_000_000 else { throw FocusStoreError.oversizedData }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(FocusState.self, from: Data(contentsOf: file))
        try state.validate()
        return state
    }

    private func withExclusiveLock<T>(_ body: (URL) throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let directory = directoryURL else {
            throw FocusStoreError.sharedContainerUnavailable(unavailableReason ?? "没有可用的数据目录。")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        #if canImport(Darwin)
        let lockPath = directory.appendingPathComponent("focus-state.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw FocusStoreError.fileLockFailed(errno) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            if code != EINTR { throw FocusStoreError.fileLockFailed(code) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body(directory)
        #else
        throw FocusStoreError.unsupportedPlatform
        #endif
    }
}
