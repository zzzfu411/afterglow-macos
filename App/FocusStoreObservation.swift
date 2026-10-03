import Foundation
import Darwin

/// Atomic writes replace the JSON inode, so observe its containing directory.
/// This source sleeps in the kernel between writes; there is no polling loop.
final class FocusStoreObservation {
    private var source: DispatchSourceFileSystemObject?

    init(directory: URL?, onChange: @escaping @Sendable () -> Void) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw FocusStoreError.fileLockFailed(errno) }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}
