import Foundation

@main
struct FocusStateTests {
    static var count = 0
    static func expect(_ assertion: Bool, _ message: String) {
        guard assertion else { fatalError("FAIL: \(message)") }
        count += 1
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--worker" {
            let store = FocusStore(directory: URL(fileURLWithPath: args[2]))
            for _ in 0..<41 { try store.toggle(at: Date(timeIntervalSince1970: 100_000)) }
            return
        }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let original = FocusState(duration: 1500, task: "写作")
        try original.validate()
        expect(original.status == .idle && original.remaining == 1500, "defaults")
        expect(FocusState(mode: .rest).duration == 300, "five-minute rest default")

        let running = original.applying(.start, at: start)
        expect(running.deadline == start.addingTimeInterval(1500), "deadline persisted")
        expect(running.remaining(at: start.addingTimeInterval(100)) == 1400, "elapsed wall time")
        expect(running.remaining(at: start.addingTimeInterval(-100)) == 1500, "backward clock does not inflate remaining")
        let paused = running.applying(.pause, at: start.addingTimeInterval(100))
        expect(paused.status == .paused && paused.remaining == 1400, "pause stores remaining")
        expect(paused.remaining(at: start.addingTimeInterval(10_000)) == 1400, "pause does not count time")
        let resumed = paused.applying(.start, at: start.addingTimeInterval(300))
        expect(resumed.deadline == start.addingTimeInterval(1700), "resume excludes pause")
        expect(resumed.sessionID == running.sessionID, "resume retains session")
        expect(running.applying(.selectMode(.rest), at: start.addingTimeInterval(50)) == running, "active mode switch ignored")
        expect(paused.applying(.selectDuration(60), at: start.addingTimeInterval(150)) == paused, "active preset change ignored")

        let done = resumed.applying(.settle, at: start.addingTimeInterval(86_400))
        expect(done.status == .done && done.logs.count == 1, "sleep settles once")
        expect(done.logs[0].endedAt == start.addingTimeInterval(1700), "completion attributed to deadline")
        expect(done.logs[0].seconds == 1500 && done.logs[0].completed, "only active seconds counted")
        expect(done.applying(.settle, at: start.addingTimeInterval(172_800)).logs.count == 1, "no duplicate completion")
        let interrupted = resumed.applying(.finish, at: start.addingTimeInterval(400))
        expect(interrupted.logs[0].seconds == 200 && !interrupted.logs[0].completed, "early finish counts work only")
        expect(running.applying(.setTask("改名"), at: start.addingTimeInterval(10)).applying(.finish, at: start.addingTimeInterval(20)).logs[0].task == "写作", "history task is immutable")
        let fresh = done.applying(.start, at: start.addingTimeInterval(90_000))
        expect(fresh.sessionID != done.sessionID && fresh.logs.count == 1, "new session retains history")
        expect(running.applying(.start, at: start.addingTimeInterval(2000)).status == .done, "stale start settles expired session")
        let rest = FocusState(mode: .rest).applying(.start, at: start).applying(.settle, at: start.addingTimeInterval(400))
        expect(rest.status == .done && rest.logs.isEmpty, "rest is not focus history")
        expect(original.applying(.selectDuration(.nan)) == original, "invalid preset rejected")
        let encoded = try JSONEncoder().encode(resumed)
        expect(try JSONDecoder().decode(FocusState.self, from: encoded) == resumed, "state survives restart")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("afterglow-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FocusStore(directory: directory)
        try store.update(.start, at: start)
        let cold = FocusStore(directory: directory)
        expect(try cold.snapshot(at: start.addingTimeInterval(60)).status == .running, "cold process reads active session")
        try cold.update(.pause, at: start.addingTimeInterval(60))
        expect(try store.snapshot(at: start.addingTimeInterval(80)).remaining == 1440, "other process state is not overwritten")
        let retained = try store.startRest(at: start.addingTimeInterval(80))
        expect(retained.mode == .focus && retained.status == .paused, "stale rest click preserves focus")
        try store.update(.finish, at: start.addingTimeInterval(80))
        expect(try store.startRest(at: start.addingTimeInterval(100)).mode == .rest, "rest action updates and starts transactionally")

        let corrupt = directory.appendingPathComponent("focus-state.json")
        let invalidBytes = Data("broken-json".utf8)
        try invalidBytes.write(to: corrupt)
        do {
            _ = try store.snapshot()
            fatalError("Corrupt data should throw")
        } catch {
            expect(try Data(contentsOf: corrupt) == invalidBytes, "corrupt file preserved")
        }

        let sharedDirectory = directory.appendingPathComponent("cross-process")
        var workers: [Process] = []
        for _ in 0..<6 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = ["--worker", sharedDirectory.path]
            try process.run()
            workers.append(process)
        }
        for worker in workers { worker.waitUntilExit(); expect(worker.terminationStatus == 0, "worker finished") }
        let shared = try FocusStore(directory: sharedDirectory).snapshot(at: Date(timeIntervalSince1970: 100_000))
        expect(shared.status == .paused, "246 concurrent toggles remain serialized")
        try shared.validate()
        print("PASS: \(count) checks; includes 6 processes / 246 shared-store transactions.")
    }
}
