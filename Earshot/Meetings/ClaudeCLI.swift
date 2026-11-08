import Foundation
import os

enum ClaudeCLIError: LocalizedError {
    case notFound
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notFound:
            String(localized: "Claude Code CLI not found. Install it, or turn off Claude features in Settings.")
        case .failed(let message):
            String(localized: "Claude: \(message)")
        case .timedOut:
            String(localized: "Claude took too long to respond.")
        }
    }
}

/// Runs Claude Code headless (`claude -p`) on the user's own login: no tools, MCP, hooks,
/// slash commands, CLAUDE.md, or memory, so only our prompt reaches the model.
struct ClaudeCLI: Sendable {
    let executable: URL

    /// Official install locations. GUI apps don't inherit the shell's PATH, so we look directly.
    static func locate() -> ClaudeCLI? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
            URL(filePath: "/opt/homebrew/bin/claude"),
            URL(filePath: "/usr/local/bin/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(ClaudeCLI.init)
    }

    static func arguments(model: String, effort: String, system: String) -> [String] {
        [
            "-p",
            "--model", model,
            "--effort", effort,
            "--output-format", "json",
            "--system-prompt", system,
            "--tools", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--settings", #"{"disableAllHooks":true}"#,
        ]
    }

    private struct Result: Decodable {
        let isError: Bool
        let result: String?
    }

    func run(model: String, effort: String, system: String, input: String, timeout: Duration) async throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        let output: Subprocess.Output
        do {
            // Neutral directory, so no project CLAUDE.md or settings are discovered.
            output = try await Subprocess.run(
                executable, Self.arguments(model: model, effort: effort, system: system), environment: environment,
                directory: FileManager.default.temporaryDirectory, input: Data(input.utf8), timeout: timeout)
        } catch is Subprocess.TimedOut {
            throw ClaudeCLIError.timedOut
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(Result.self, from: output.stdout) else {
            throw ClaudeCLIError.failed(output.message)
        }
        guard !result.isError, let text = result.result else {
            throw ClaudeCLIError.failed(result.result ?? "exit \(output.status)")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a command to completion, draining stdout and stderr concurrently so a full pipe can't stall it.
enum Subprocess {
    struct TimedOut: Error {}

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        /// What went wrong, for the user: stderr, else stdout, else the exit status.
        var message: String {
            let text = String(decoding: stderr.isEmpty ? stdout : stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "exit \(status)" : text
        }
    }

    static func run(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil,
        input: Data = Data(), timeout: Duration
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { exited.continuation.yield($0.terminationStatus); exited.continuation.finish() }
        try process.run()

        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()

            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            let (output, errors) = await (out, err)
            var status: Int32 = -1
            for await code in exited.stream { status = code }

            if timedOut.withLock({ $0 }) { throw TimedOut() }
            return Output(status: status, stdout: output, stderr: errors)
        } onCancel: {
            process.terminate()
        }
    }
}
