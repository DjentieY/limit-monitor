import Foundation
import LimitMonitorCore

// Executes the key source of a config provider (v0.4). Called on EVERY poll —
// keys are rotated/renewed externally and must never be cached across polls.
// The resolved value lives only in memory: never logged, never printed, never
// embedded in any error message.
enum KeyResolver {
    enum Outcome {
        case key(String)
        /// Localized reason from KeyResolutionStrings — safe to show in menu/--check.
        case failure(String)
    }

    static func resolve(
        _ source: KeySource,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        _ lang: Language
    ) -> Outcome {
        switch source {
        case .literal(let value):
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? .failure(KeyResolutionStrings.text(.empty, lang)) : .key(key)
        case .env(let name):
            // Unreliable for Finder-launched apps (launchd environment) — the
            // README recommends `command` + Keychain instead.
            let key = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return key.isEmpty ? .failure(KeyResolutionStrings.text(.envUnset, lang)) : .key(key)
        case .command(let command):
            return run(command, lang)
        }
    }

    // /bin/sh -c <command>, stdout trimmed. stderr is discarded — it could echo
    // secret material. The 10 s deadline covers the WHOLE operation (output EOF
    // AND process exit): stdout is read via readabilityHandler, never with a
    // blocking readDataToEndOfFile, so a child that keeps the pipe open (a
    // backgrounded/daemonizing helper) cannot wedge the poll or --check. On
    // expiry the child's process GROUP is SIGKILLed (Process children lead
    // their own group on Darwin, so the shell's descendants die too), and the
    // watchdog trip is an unconditional failure — output of a timed-out
    // command is never accepted as a key, whatever the exit status.
    private static func run(_ command: String, _ lang: Language) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let handle = stdout.fileHandleForReading
        let bufferLock = NSLock()
        var buffer = Data()
        let sawEOF = DispatchSemaphore(value: 0)
        handle.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                sawEOF.signal()
            } else {
                bufferLock.lock()
                buffer.append(chunk)
                bufferLock.unlock()
            }
        }

        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            return .failure(KeyResolutionStrings.text(.commandFailed, lang))
        }

        let deadline = DispatchTime.now() + 10
        var timedOut = sawEOF.wait(timeout: deadline) == .timedOut
        if !timedOut { timedOut = exited.wait(timeout: deadline) == .timedOut }
        if timedOut {
            handle.readabilityHandler = nil
            let pid = process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? handle.close()
        guard !timedOut, process.terminationStatus == 0 else {
            return .failure(KeyResolutionStrings.text(.commandFailed, lang))
        }
        bufferLock.lock()
        let data = buffer
        bufferLock.unlock()
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(KeyResolutionStrings.text(.empty, lang))
        }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? .failure(KeyResolutionStrings.text(.empty, lang)) : .key(key)
    }
}
