import Foundation
import LimitMonitorCore

// `--status [--json]` (SPEC v0.5): renders the widget snapshot file. Runs
// before any AppKit/NSApplication setup and touches no network — the heavy
// lifting is Core's StatusCommand, checks-covered.
enum StatusMode {
    static func run(json: Bool) -> Int32 {
        let output = StatusCommand.output(fileData: SnapshotStore.read(), json: json, now: Date())
        FileHandle.standardOutput.write(output.stdout)
        return output.exitCode
    }
}
