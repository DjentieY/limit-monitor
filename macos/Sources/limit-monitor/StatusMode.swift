import Foundation
import LimitMonitorCore

// `--status [--json]` (SPEC v0.5/v0.6): renders the widget snapshot file in the
// reader's own locale (EN default + RU). Runs before any AppKit/NSApplication
// setup and touches no network — the heavy lifting is Core's StatusCommand,
// checks-covered. The snapshot is neutral, so a file written by any process
// renders correctly for this reader.
enum StatusMode {
    static func run(json: Bool) -> Int32 {
        let lang = Language.resolve()
        let output = StatusCommand.output(fileData: SnapshotStore.read(), json: json, now: Date(), lang)
        FileHandle.standardOutput.write(output.stdout)
        return output.exitCode
    }
}
