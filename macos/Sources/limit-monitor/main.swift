import Foundation

let cliArguments = CommandLine.arguments.dropFirst()
if cliArguments.contains("--status") {
    exit(StatusMode.run(json: cliArguments.contains("--json")))
}
if cliArguments.contains("--check") {
    exit(CheckMode.run())
}
if cliArguments.contains("--ui-smoke") {
    exit(UISmoke.run())
}
runApp()
