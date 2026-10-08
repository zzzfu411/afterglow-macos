import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum FocusStoreError: Error, LocalizedError {
    case sharedContainerUnavailable(String)
    case unsupportedPlatform
    case fileLockFailed(Int32)
    case oversizedData
    case invalidTodoAction
    case todoCapacityReached
    case undoConflict
    case importConflict
    case editConflict

    public var errorDescription: String? {
        switch self {
        case .sharedContainerUnavailable(let reason):
            return "共享存储不可用：\(reason)"
        case .unsupportedPlatform:
            return "此存储需要 macOS 文件锁支持。"
        case .fileLockFailed(let code):
            return "无法锁定计时数据（\(code)），请重试。"
        case .oversizedData:
            return "数据文件超过 16 MB，原文件已保留。请先导出或减少不需要的记录。"
        case .invalidTodoAction:
            return "待办信息无效，未保存更改。"
        case .todoCapacityReached:
            return "待办已达容量上限（1,000 项待办、10,000 项总记录），原数据已保留。"
        case .undoConflict:
            return "这些事项已被其他操作修改，无法撤销。当前数据已保留。"
        case .importConflict:
            return "预览后相关事项或清单发生了变化，请重新预览导入。当前数据已保留。"
        case .editConflict:
            return "此事项已被其他操作修改，请重新打开后编辑。当前数据已保留。"
        }
    }
}

/// Every action reads the latest file while holding both an in-process lock and
/// a cross-process advisory lock. App and widget must use the same App Group ID
/// and this store; synchronization is not provided to unrelated file writers.
public final class FocusStore: @unchecked Sendable {
    public static let shared = FocusStore()
    public static let maximumFileBytes = 16_000_000
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

    /// A compound timer command must not expose a partially selected or stopped
    /// session to the widget. Validate and write only the final atomic result.
    @discardableResult
    public func performActions(_ actions: [FocusAction], at now: Date = Date()) throws -> FocusState {
        guard actions.count <= 64 else { throw FocusStoreError.invalidTodoAction }
        return try transaction { previous in
            var next = previous
            for action in actions {
                if case .selectTarget(let target) = action, target != .free {
                    var list = next.todoList ?? FocusTodoList()
                    list.target = target
                    guard !list.selected.isEmpty else { throw FocusStoreError.invalidTodoAction }
                }
                next = next.applying(action, at: now)
            }
            return next
        }
    }

    /// Capture the exact change under the same lock as the write, including
    /// edits another process made before this completion click arrived.
    public func completeTodo(_ id: UUID, at now: Date = Date()) throws -> (state: FocusState, undo: FocusTodoCompletionUndo?) {
        var undo: FocusTodoCompletionUndo?
        let state = try transaction { previous in
            let updated = previous.applying(.setTodoCompleted(id, true), at: now)
            undo = FocusTodoCompletionUndo(id: id, previous: previous, updated: updated)
            return updated
        }
        return (state, undo)
    }

    /// Batch edits and their undo receipt are committed under the same lock.
    /// An invalid action aborts the entire batch without a partial import/edit.
    @discardableResult
    public func performTodoActions(_ actions: [FocusAction], at now: Date = Date()) throws -> (state: FocusState, undo: TodoUndoRecord?) {
        guard actions.count <= FocusTodo.maximumStoredCount + TodoCollection.maximumCount,
              actions.allSatisfy(\.isTodoAction) else { throw FocusStoreError.invalidTodoAction }
        var previousForUndo: FocusState?
        let state = try transaction { previous in
            previousForUndo = previous
            var next = previous.applying(.settle, at: now)
            for action in actions {
                try Self.checkTodoAction(action, in: next)
                next = next.applying(action, at: now)
            }
            return next
        }
        // Use the canonical persisted values: JSON millisecond dates can differ
        // by a floating-point ULP from the incoming Date. Receipts must match disk.
        return (state, previousForUndo.flatMap { TodoUndoRecord(previous: $0, updated: state) })
    }

    @discardableResult
    public func performTodoAction(_ action: FocusAction, at now: Date = Date()) throws -> (state: FocusState, undo: TodoUndoRecord?) {
        try performTodoActions([action], at: now)
    }

    /// Return an inverse receipt for redo. Only matching changed objects are
    /// restored; elapsed time and unrelated edits can never be rolled back.
    @discardableResult
    public func undoTodo(_ receipt: TodoUndoRecord, at now: Date = Date()) throws -> (state: FocusState, undo: TodoUndoRecord?) {
        var previousForUndo: FocusState?
        let state = try transaction { previous in
            previousForUndo = previous
            return try previous.applying(.settle, at: now).applyingTodoUndo(receipt)
        }
        return (state, previousForUndo.flatMap { TodoUndoRecord(previous: $0, updated: state, title: receipt.title) })
    }

    /// Import metadata in one transaction. Optional preview values make user
    /// confirmation conditional on the exact affected records still matching.
    @discardableResult
    public func mergeTodos(_ items: [FocusTodo], collections: [TodoCollection],
                           expectedTodos: [FocusTodo]? = nil, expectedCollections: [TodoCollection]? = nil,
                           at now: Date = Date()) throws -> (state: FocusState, undo: TodoUndoRecord?) {
        var previousForUndo: FocusState?
        let state = try transaction { previous in
            let itemIDs = Set(items.map(\.id))
            let collectionIDs = Set(collections.map(\.id))
            if let expectedTodos {
                let current = previous.todos.filter { itemIDs.contains($0.id) }
                guard Self.sameItems(current, expectedTodos) else { throw FocusStoreError.importConflict }
            }
            if let expectedCollections {
                let current = (previous.todoList?.collections ?? []).filter { collectionIDs.contains($0.id) }
                guard current.count == expectedCollections.count,
                      Set(current.map(\.id)) == Set(expectedCollections.map(\.id)),
                      current.allSatisfy({ item in expectedCollections.contains(item) }) else { throw FocusStoreError.importConflict }
            }
            previousForUndo = previous
            return try previous.applying(.settle, at: now).mergingTodos(items, collections: collections)
        }
        return (state, previousForUndo.flatMap { TodoUndoRecord(previous: $0, updated: state, title: "导入待办") })
    }

    private static func sameItems(_ lhs: [FocusTodo], _ rhs: [FocusTodo]) -> Bool {
        guard lhs.count == rhs.count, Set(rhs.map(\.id)).count == rhs.count else { return false }
        let expected = Dictionary(uniqueKeysWithValues: rhs.map { ($0.id, $0) })
        return lhs.allSatisfy { expected[$0.id] == $0 }
    }

    private static func checkTodoAction(_ action: FocusAction, in state: FocusState) throws {
        switch action {
        case .addTodo(let item), .upsertTodo(let item):
            guard item.isValid,
                  item.listID.map({ id in state.todoList?.collections.contains(where: { $0.id == id }) == true }) ?? true else {
                throw FocusStoreError.invalidTodoAction
            }
            let previous = state.todos.first { $0.id == item.id }
            guard previous != nil || state.todos.count < FocusTodo.maximumStoredCount,
                  !item.isPending || previous?.isPending == true || state.todos.filter(\.isPending).count < FocusTodo.maximumCount else {
                throw FocusStoreError.todoCapacityReached
            }
        case .replaceTodo(let expected, let replacement):
            guard expected.id == replacement.id,
                  state.todos.first(where: { $0.id == expected.id }) == expected else { throw FocusStoreError.editConflict }
            try checkTodoAction(.upsertTodo(replacement), in: state)
        case .editTodo(_, let title, let minutes, let dueDate):
            guard FocusTodo(title: title, minutes: minutes, dueDate: dueDate).isValid else { throw FocusStoreError.invalidTodoAction }
        case .restoreTodo(let id):
            if let item = state.todos.first(where: { $0.id == id }), item.isDeleted && !item.isCompleted,
               state.todos.filter(\.isPending).count >= FocusTodo.maximumCount { throw FocusStoreError.todoCapacityReached }
        case .setTodoCompleted(let id, false):
            if let item = state.todos.first(where: { $0.id == id }), item.isCompleted && !item.isDeleted,
               state.todos.filter(\.isPending).count >= FocusTodo.maximumCount { throw FocusStoreError.todoCapacityReached }
        case .upsertCollection(let collection):
            guard collection.isValid else { throw FocusStoreError.invalidTodoAction }
            let collections = state.todoList?.collections ?? []
            guard collections.contains(where: { $0.id == collection.id }) || collections.count < TodoCollection.maximumCount else {
                throw FocusStoreError.todoCapacityReached
            }
        case .purgeTodos(let ids):
            guard ids.count <= FocusTodo.maximumStoredCount, Set(ids).count == ids.count,
                  Set(ids).isSubset(of: Set(state.todos.filter(\.isDeleted).map(\.id))) else { throw FocusStoreError.invalidTodoAction }
        case .reorderTodos(let ids):
            guard ids.count <= FocusTodo.maximumCount, Set(ids).count == ids.count,
                  Set(ids).isSubset(of: Set(state.todos.filter(\.isPending).map(\.id))) else { throw FocusStoreError.invalidTodoAction }
        default: break
        }
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

    private func transaction(_ transform: (FocusState) throws -> FocusState) throws -> FocusState {
        try withExclusiveLock { directory in
            let file = directory.appendingPathComponent("focus-state.json")
            let (previous, originalBytes) = try read(file)
            let migrated = previous.migratedToCurrent()
            try migrated.validate()
            let next = try transform(migrated)
            try next.validate()
            if next != previous {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .millisecondsSince1970
                encoder.outputFormatting = [.sortedKeys]
                let bytes = try encoder.encode(next)
                guard bytes.count <= Self.maximumFileBytes else { throw FocusStoreError.oversizedData }
                // Decode and validate the candidate before creating its backup
                // or replacing the live file; conversion never silently repairs corruption.
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .millisecondsSince1970
                let persisted = try decoder.decode(FocusState.self, from: bytes)
                try persisted.validate()
                if previous.version < FocusState.currentVersion, let originalBytes {
                    let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
                    try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                    let backup = backupDirectory.appendingPathComponent("pre-v4-v\(previous.version)-\(UUID().uuidString).json")
                    try originalBytes.write(to: backup, options: .atomic)
                    guard try Data(contentsOf: backup) == originalBytes else { throw FocusStateError.invalidData }
                }
                // Rename atomically while retaining the lock on a separate file.
                try bytes.write(to: file, options: .atomic)
                return persisted
            }
            return next
        }
    }

    private func read(_ file: URL) throws -> (FocusState, Data?) {
        guard fileManager.fileExists(atPath: file.path) else { return (FocusState(), nil) }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.maximumFileBytes else { throw FocusStoreError.oversizedData }
        let data = try Data(contentsOf: file)
        guard data.count <= Self.maximumFileBytes else { throw FocusStoreError.oversizedData }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(FocusState.self, from: data)
        try state.validate()
        return (state, data)
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

private extension FocusAction {
    var isTodoAction: Bool {
        switch self {
        case .addTodo, .upsertTodo, .replaceTodo, .editTodo, .deleteTodo, .trashTodo, .restoreTodo, .purgeTodos,
             .setTodoCompleted, .undoTodoCompletion, .upsertCollection, .deleteCollection, .reorderTodos:
            return true
        default: return false
        }
    }
}
