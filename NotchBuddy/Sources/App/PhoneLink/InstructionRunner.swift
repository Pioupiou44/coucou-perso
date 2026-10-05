#if PHONE_LINK && !APPSTORE
import AppKit
import CloudKit

// MARK: - Instructions from the iPhone
//
// The iPhone writes an `Instruction` record (text encrypted) for a session.
// When the user turned it on (Settings → General → iPhone, off by default),
// this Mac checks every 15 s, takes each instruction once (the record is
// deleted on read), and continues that same Claude Code conversation in the
// background: `claude -p <text> --resume <session id>`, in the session's own
// folder. The folder and the session come from what this Mac saw in the
// hooks, never from the iPhone. Hooks keep working, so the notch, the iPhone
// and the permission requests (approved by hand, with Face ID on the phone)
// follow the run like any other turn.
// GitHub build only: the App Store build is sandboxed and can't start `claude`.

@MainActor
final class InstructionRunner {
    static let shared = InstructionRunner()

    nonisolated static let enabledKey = "iPhoneInstructionsEnabled"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var database: CKDatabase { CKContainer(identifier: CloudProbe.containerID).privateCloudDatabase }
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?
    private var running: [String: Process] = [:]   // by session id

    /// Instructions older than this are dropped instead of run.
    private let maxAge: TimeInterval = 10 * 60

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on && CloudProbe.isEnabled { start() } else { stop() }
    }

    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func start() {
        guard pollTask == nil else { return }
        log("on: checking for instructions every 15 s")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        log("off")
    }

    // MARK: Reading

    private func check() async {
        var found: [CKRecord] = []
        var ended: [(recordID: CKRecord.ID, pillId: String)] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: SessionSnapshot.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result {
                        switch mod.record.recordType {
                        case "Instruction": found.append(mod.record)
                        case "EndConversation": ended.append((mod.record.recordID, mod.record["pillId"] as? String ?? ""))
                        }
                    }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return
        } catch {
            return
        }
        // « Terminer la conversation » from the phone: drop those pills.
        if !ended.isEmpty {
            _ = try? await database.modifyRecords(saving: [], deleting: ended.map(\.recordID))  // single use
            for (_, pillId) in ended where !pillId.isEmpty {
                AppState.shared.removeTask(id: pillId)
                log("conversation ended from the iPhone (\(pillId))")
            }
        }
        guard !found.isEmpty else { return }
        // Single use: gone from iCloud before anything runs.
        _ = try? await database.modifyRecords(saving: [], deleting: found.map(\.recordID))
        for record in found.sorted(by: { ($0["createdAt"] as? Date ?? .distantPast) < ($1["createdAt"] as? Date ?? .distantPast) }) {
            handle(record)
        }
    }

    private func handle(_ record: CKRecord) {
        let pillId = record["pillId"] as? String ?? ""
        let createdAt = record["createdAt"] as? Date ?? .distantPast
        let text = (record.encryptedValues["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEnabled else { log("ignored: instructions are off"); return }
        guard Date().timeIntervalSince(createdAt) < maxAge else { log("ignored: older than 10 min"); return }
        guard !text.isEmpty, text.count <= 8000 else { log("ignored: empty or too long"); return }
        let isClaudePill = pillId == "integration_claude" || pillId == "agent_cursor"
        let isCopilotPill = pillId.hasPrefix("agent_copilot_")
        guard isClaudePill || isCopilotPill else { log("ignored: \(pillId) can't take instructions"); return }
        guard let session = TurnRecorder.shared.lastSession(for: pillId) else {
            log("ignored: no session seen for \(pillId) yet")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            log("ignored: the session's folder is gone")
            return
        }
        guard running[session.sessionId] == nil else {
            log("ignored: an instruction is already running for this session")
            return
        }
        guard let executable = isCopilotPill ? Self.copilotExecutable() : Self.claudeExecutable() else {
            log("can't find the \(isCopilotPill ? "copilot" : "claude") command")
            return
        }
        run(executable: executable, text: text, sessionId: session.sessionId, cwd: session.cwd, pillId: pillId)
    }

    // MARK: Running

    private func run(executable: String, text: String, sessionId: String, cwd: String, pillId: String) {
        let startedAt = Date()
        let isCopilotPill = pillId.hasPrefix("agent_copilot_")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        if isCopilotPill {
            // The user already approved this instruction with Face ID on the
            // iPhone; headless CLI has nobody to ask, file tools would fail.
            process.arguments = ["-p", text, "--resume", sessionId, "--allow-all-tools"]
        } else {
            process.arguments = ["-p", text, "--resume", sessionId]
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [URL(fileURLWithPath: executable).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
        // The hooks route events by editor: keep them on the same pill.
        if isCopilotPill {
            // Copilot hooks tag with coucou_agent; the env matters less, but
            // keep VS Code's so editor-routed fallbacks stay consistent.
            env["TERM_PROGRAM"] = "vscode"
        } else if pillId == "agent_cursor" {
            env["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
        } else {
            env["TERM_PROGRAM"] = "vscode"
        }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        // Output goes to a file (a pipe could fill up and stall claude); its
        // end is logged if the run fails.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchBuddy/instruction-last.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            try? output?.close()
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            let tail = String(decoding: data.suffix(400), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            let status = finished.terminationStatus
            Task { @MainActor in
                self?.running[sessionId] = nil
                self?.log(status == 0 ? "finished (\(sessionId.prefix(8)))" : "ended with \(status): \(tail)")
                // The answer reaches the phone as a thread message: the
                // instruction (asked from the iPhone) and what the agent
                // answered. Copilot prints the final message between the
                // last tool block and the summary footer; take everything
                // before the footer, dropping leading tool blocks.
                let answer = Self.finalAnswer(from: text)
                self?.recordAnswer(pillId: pillId, instruction: text,
                                   answer: answer, failed: status != 0, startedAt: startedAt)
            }
        }
        do {
            try process.run()
            running[sessionId] = process
            log("running in \(URL(fileURLWithPath: cwd).lastPathComponent) (\(sessionId.prefix(8))): \(text.count) chars")
        } catch {
            log("couldn't start the agent: \(error.localizedDescription)")
        }
    }

    /// Appends the iPhone-asked exchange to the session's thread so the phone
    /// shows the answer as a chat message. The hooks already recorded the
    /// agent's own turn; this closes it with the instruction as the prompt.
    @MainActor
    private func recordAnswer(pillId: String, instruction: String, answer: String, failed: Bool, startedAt: Date) {
        // The turn's real prompt was the instruction sent from the phone.
        TurnRecorder.shared.recordInstructionTurn(pillId: pillId, prompt: instruction,
                                                 answer: failed ? "The instruction failed on the Mac." : answer,
                                                 startedAt: startedAt)
    }

    /// Copilot's headless output ends with a footer (Changes/AI Credits/…).
    /// The final answer is everything after the last tool block (● …)
    /// and before that footer.
    nonisolated static func finalAnswer(from output: String) -> String {
        guard !output.isEmpty else { return "" }
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Drop the footer: from the line that is empty followed by "Changes …" / ends with a "Resume …" hint.
        if let footerIdx = lines.firstIndex(where: { $0.hasPrefix("Changes") || $0.hasPrefix("AI Credits") || $0.hasPrefix("Tokens") || $0.hasPrefix("Resume") }) {
            lines = Array(lines[..<footerIdx])
        }
        // Drop trailing empty lines.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where `claude` usually lives; the app doesn't get the shell's PATH.
    static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The Copilot CLI — resumes the same conversation the VS Code chat uses
    /// (`copilot -p <text> --resume <session id>`), including Agent Host sessions.
    static func copilotExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/copilot",
            "/usr/local/bin/copilot",
            "\(home)/.local/bin/copilot",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[instruction] \(message)")
    }
}
#endif
