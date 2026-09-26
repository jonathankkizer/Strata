import Foundation

/// Finding and running the cloud CLIs (`az`, `aws`) that Strata borrows sign-ins from.
///
/// Shared by both credential providers because both have the same three problems:
/// - A GUI app launched from the Finder gets a minimal PATH, not the shell's, so the
///   binary has to be found explicitly — and installs live in more places than
///   Homebrew (pipx, MacPorts, nix, asdf).
/// - The CLI runs helpers of its own (`credential_process` tools like aws-vault or
///   1Password's), which need a PATH too.
/// - A CLI can hang (a network retry after wake, a prompt nobody will answer), and a
///   hung token fetch hangs every transfer waiting on it. So runs have a timeout, and
///   cancelling the caller terminates the process.
enum CLIProcess {

    enum Failure: Error, Sendable, Equatable {
        case launchFailed(message: String)
        case exited(status: Int32, message: String)
        case timedOut(seconds: Int)
    }

    /// Where CLIs are commonly installed, in order. `~` is expanded.
    static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "~/.local/bin",                       // pipx, pip --user
        "/opt/local/bin",                     // MacPorts
        "~/.nix-profile/bin",
        "/nix/var/nix/profiles/default/bin",
        "/run/current-system/sw/bin",         // nix-darwin
        "~/.asdf/shims",
        "~/.local/share/mise/shims",
    ]

    /// The first executable called `name`: the explicit path if it works, then the
    /// usual install locations, then whatever the user's login shell would run.
    static func locate(_ name: String, explicitPath: String?) async -> String? {
        let fileManager = FileManager.default
        if let explicitPath, !explicitPath.isEmpty {
            let expanded = (explicitPath as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) { return expanded }
        }
        for directory in searchDirectories {
            let candidate = ((directory as NSString).expandingTildeInPath as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return await ShellLookup.shared.path(for: name)
    }

    /// Runs `binary` and returns its standard output.
    ///
    /// Output is drained while the process runs rather than at exit, so a CLI that
    /// writes more than a pipe buffer can't deadlock waiting for a reader.
    static func run(binary: String, arguments: [String], timeout: Duration = .seconds(60)) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment(forBinary: binary)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let collected = OutputBuffers()
        stdout.fileHandleForReading.readabilityHandler = { collected.appendOut($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { collected.appendErr($0.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                        do {
                            try process.run()
                        } catch {
                            process.terminationHandler = nil
                            continuation.resume(throwing: Failure.launchFailed(message: error.localizedDescription))
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next()!
                group.cancelAll()
                guard let status = first else {
                    process.terminate()
                    throw Failure.timedOut(seconds: Int(timeout.components.seconds))
                }
                return status
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // Whatever arrived after the last handler call.
        collected.appendOut(stdout.fileHandleForReading.readDataToEndOfFile())
        collected.appendErr(stderr.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()

        guard status == 0 else {
            let message = String(data: collected.err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.exited(status: status, message: message?.isEmpty == false ? message! : "exit \(status)")
        }
        return collected.out
    }

    /// The app's environment with a PATH a shell would recognise: the binary's own
    /// directory first (so a pipx or nix install finds its siblings), then the usual
    /// locations, then whatever PATH the app was given.
    static func environment(forBinary binary: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var directories = [(binary as NSString).deletingLastPathComponent]
        directories += searchDirectories.map { ($0 as NSString).expandingTildeInPath }
        directories += ["/bin", "/usr/sbin", "/sbin"]
        if let existing = environment["PATH"] {
            directories += existing.split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        environment["PATH"] = directories.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        return environment
    }
}

/// Collects a process's output from pipe callbacks, which arrive on arbitrary threads.
private final class OutputBuffers: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func appendOut(_ data: Data) { lock.withLock { outData.append(data) } }
    func appendErr(_ data: Data) { lock.withLock { errData.append(data) } }
    var out: Data { lock.withLock { outData } }
    var err: Data { lock.withLock { errData } }
}

/// Asks the user's login shell where a command is, as a last resort after the usual
/// locations. Slow (it sources their profile), so each answer is remembered for the
/// life of the app, including "not found".
private actor ShellLookup {
    static let shared = ShellLookup()
    private var answers: [String: String?] = [:]

    func path(for name: String) async -> String? {
        if let known = answers[name] { return known }
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var found: String?
        // `name` is always one of our own literals ("az", "aws"), never user input, so
        // interpolating it into the command is safe.
        if let data = try? await CLIProcess.run(binary: shell, arguments: ["-l", "-c", "command -v \(name)"], timeout: .seconds(5)),
           let line = String(data: data, encoding: .utf8)?
               .split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
           line.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: line) {
            found = line
        }
        answers[name] = found
        return found
    }
}
