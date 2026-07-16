import Foundation
import ClaudeLimitsCore

enum CredentialsProvider {
    static func load() -> (creds: Credentials, source: String)? {
        if let data = readKeychain(), let creds = CredentialsParser.parse(data: data) {
            return (creds, "keychain")
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: url), let creds = CredentialsParser.parse(data: data) {
            return (creds, "~/.claude/.credentials.json")
        }
        return nil
    }

    private static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }
}
