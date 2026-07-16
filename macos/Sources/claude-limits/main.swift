import Foundation

if CommandLine.arguments.dropFirst().contains("--check") {
    exit(CheckMode.run())
}
runApp()
