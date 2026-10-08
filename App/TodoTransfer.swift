import Foundation

/// A portable task archive. Focus sessions, settings, and logs are intentionally
/// absent, so importing a checklist cannot replace the running clock or history.
public struct TodoArchive: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let formatIdentifier = "moro.todo-archive"
    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var todos: [FocusTodo]
    public var collections: [TodoCollection]

    public init(todos: [FocusTodo], collections: [TodoCollection] = [], exportedAt: Date = Date()) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.todos = todos
        self.collections = collections
    }

    public func validate() throws {
        guard format == Self.formatIdentifier else { throw TodoTransferError.invalidArchive }
        guard (1...Self.currentVersion).contains(version) else { throw TodoTransferError.unsupportedVersion(version) }
        if version < 2 && todos.contains(where: \.hasVersion5Metadata) { throw TodoTransferError.invalidArchive }
        guard FocusTodo.validDate(exportedAt), todos.count <= FocusTodo.maximumStoredCount,
              todos.filter(\.isPending).count <= FocusTodo.maximumCount,
              todos.allSatisfy(\.isValid), Set(todos.map(\.id)).count == todos.count,
              collections.count <= TodoCollection.maximumCount,
              collections.allSatisfy(\.isValid), Set(collections.map(\.id)).count == collections.count else {
            throw TodoTransferError.invalidArchive
        }
        let collectionIDs = Set(collections.map(\.id))
        guard todos.allSatisfy({ $0.listID.map { collectionIDs.contains($0) } ?? true }) else {
            throw TodoTransferError.invalidArchive
        }
    }
}

public enum TodoTransferError: Error, LocalizedError {
    case invalidArchive
    case unsupportedVersion(Int)
    case oversizedArchive
    case previewMismatch
    case invalidDestination

    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "这不是有效的 Moro 待办归档，当前数据未更改。"
        case .unsupportedVersion(let version): return "暂不支持此归档版本（\(version)），请使用对应版本的 Moro。"
        case .oversizedArchive: return "归档超过 16 MB，当前数据未更改。"
        case .previewMismatch: return "导入文件与预览不一致，请重新预览。"
        case .invalidDestination: return "请选择本机上的归档文件位置。"
        }
    }
}

public struct TodoImportPreview: Sendable {
    public let addedTodoCount: Int
    public let updatedTodoCount: Int
    public let unchangedTodoCount: Int
    public let addedCollectionCount: Int
    public let updatedCollectionCount: Int
    public let totalTodoCountAfterMerge: Int
    public let pendingTodoCountAfterMerge: Int
    public var overwriteCount: Int { updatedTodoCount + updatedCollectionCount }
    public var hasConflicts: Bool { overwriteCount > 0 }

    // Copy-on-write value snapshots contain only imported/affected metadata;
    // the preview never retains the complete focus state or log history.
    fileprivate let source: TodoArchive
    fileprivate let expectedTodos: [FocusTodo]
    fileprivate let expectedCollections: [TodoCollection]
}

/// Foundation-only synchronous service. The app runs these operations on its
/// storage worker; no polling, network dependency, or separate database is used.
public enum TodoTransfer {
    public static let maximumFileBytes = FocusStore.maximumFileBytes

    public static func archive(from state: FocusState, at date: Date = Date()) throws -> TodoArchive {
        let archive = TodoArchive(todos: state.todos, collections: state.todoList?.collections ?? [], exportedAt: date)
        try archive.validate()
        return archive
    }

    public static func decode(_ data: Data) throws -> TodoArchive {
        guard data.count <= maximumFileBytes else { throw TodoTransferError.oversizedArchive }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive: TodoArchive
        do { archive = try decoder.decode(TodoArchive.self, from: data) }
        catch { throw TodoTransferError.invalidArchive }
        try archive.validate()
        return archive
    }

    public static func read(from url: URL) throws -> TodoArchive {
        guard url.isFileURL else { throw TodoTransferError.invalidDestination }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileBytes else { throw TodoTransferError.oversizedArchive }
        return try decode(Data(contentsOf: url))
    }

    public static func encode(_ archive: TodoArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        guard data.count <= maximumFileBytes else { throw TodoTransferError.oversizedArchive }
        return data
    }

    public static func export(_ archive: TodoArchive, to url: URL) throws {
        guard url.isFileURL else { throw TodoTransferError.invalidDestination }
        let data = try encode(archive)
        try data.write(to: url, options: .atomic)
    }

    /// Same IDs are merged rather than duplicated. Changed incoming records
    /// replace local metadata, including completion/trash state and timestamps.
    /// The UI should explain the overwrite count before asking for confirmation.
    public static func preview(_ archive: TodoArchive, mergingInto state: FocusState) throws -> TodoImportPreview {
        try archive.validate()
        try state.validate()
        let existing = Dictionary(uniqueKeysWithValues: state.todos.map { ($0.id, $0) })
        let existingCollections = Dictionary(uniqueKeysWithValues: (state.todoList?.collections ?? []).map { ($0.id, $0) })
        let affectedIDs = Set(archive.todos.map(\.id))
        let affectedCollectionIDs = Set(archive.collections.map(\.id))
        let added = archive.todos.filter { existing[$0.id] == nil }.count
        let updated = archive.todos.filter { existing[$0.id] != nil && existing[$0.id] != $0 }.count
        let addedCollections = archive.collections.filter { existingCollections[$0.id] == nil }.count
        let updatedCollections = archive.collections.filter { existingCollections[$0.id] != nil && existingCollections[$0.id] != $0 }.count
        let total = state.todos.count + added
        let pending = state.todos.filter { $0.isPending && !affectedIDs.contains($0.id) }.count
            + archive.todos.filter(\.isPending).count
        guard total <= FocusTodo.maximumStoredCount, pending <= FocusTodo.maximumCount,
              existingCollections.count + addedCollections <= TodoCollection.maximumCount else {
            throw FocusStoreError.todoCapacityReached
        }
        return TodoImportPreview(addedTodoCount: added, updatedTodoCount: updated,
                                 unchangedTodoCount: archive.todos.count - added - updated,
                                 addedCollectionCount: addedCollections, updatedCollectionCount: updatedCollections,
                                 totalTodoCountAfterMerge: total, pendingTodoCountAfterMerge: pending,
                                 source: archive, expectedTodos: state.todos.filter { affectedIDs.contains($0.id) },
                                 expectedCollections: (state.todoList?.collections ?? []).filter { affectedCollectionIDs.contains($0.id) })
    }

    /// Passing the displayed preview protects confirmation from subsequent edits
    /// to the same IDs. A mismatch aborts the whole merge, leaving the file intact.
    @discardableResult
    public static func mergeArchive(_ archive: TodoArchive, into store: FocusStore,
                                    preview: TodoImportPreview? = nil, at now: Date = Date()) throws -> (state: FocusState, undo: TodoUndoRecord?) {
        try archive.validate()
        // The store checks the final encoded file size, including merged content.
        if let preview, preview.source != archive { throw TodoTransferError.previewMismatch }
        return try store.mergeTodos(archive.todos, collections: archive.collections,
                                    expectedTodos: preview?.expectedTodos, expectedCollections: preview?.expectedCollections, at: now)
    }
}
