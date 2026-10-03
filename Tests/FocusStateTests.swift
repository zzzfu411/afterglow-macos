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
        let nextRest = done.applying(.startNext, at: start.addingTimeInterval(90_000))
        expect(nextRest.mode == .rest && nextRest.status == .running && nextRest.duration == 300, "one click starts remembered rest")
        expect(nextRest.logs == done.logs && nextRest.sessionID != done.sessionID, "rest keeps history and has a fresh session")
        expect(rest.applying(.startNext, at: start.addingTimeInterval(500)).mode == .focus, "rest completion starts focus")
        expect(paused.applying(.startNext, at: start.addingTimeInterval(150)) == paused, "stale next cannot abandon paused work")
        expect(paused.applying(.reset, at: start.addingTimeInterval(150)) == paused, "stale wrap-up cannot discard paused work")
        let wrappedUp = nextRest.applying(.finish, at: start.addingTimeInterval(90_060)).applying(.reset)
        expect(wrappedUp.mode == .focus && wrappedUp.status == .idle && wrappedUp.logs == done.logs, "wrap-up preserves history and prepares next focus")
        expect(done.completedNaturally == true && interrupted.completedNaturally == false, "natural completion distinguished from cancellation")
        let custom = original.applying(.selectDuration(37 * 60)).applying(.selectMode(.rest)).applying(.selectDuration(7 * 60)).applying(.selectMode(.focus))
        expect(custom.duration == 37 * 60 && custom.restDuration == 7 * 60, "custom durations remembered independently")
        expect(original.applying(.selectDuration(59)) == original && original.applying(.selectDuration(10_801)) == original, "custom duration boundaries enforced")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(done)) as! [String: Any]
        legacyJSON.removeValue(forKey: "completedNaturally")
        let legacy = try JSONDecoder().decode(FocusState.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        expect(legacy.logs == done.logs && legacy.completedNaturally == nil, "old files migrate without losing history")
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
        let expiredToggle = try store.toggle(at: start.addingTimeInterval(500))
        expect(expiredToggle.status == .done, "expired widget pause settles without starting another phase")
        let nextToggle = try store.toggle(at: start.addingTimeInterval(501))
        expect(nextToggle.status == .running && nextToggle.mode == .focus, "completed widget primary starts next phase")

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
