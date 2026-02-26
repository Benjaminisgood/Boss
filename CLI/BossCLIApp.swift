import Foundation
import ArgumentParser

@main
struct BossCLIApp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boss",
        abstract: "Boss CLI",
        discussion: "Use `boss help` to view the full command reference."
    )

    @Option(name: [.customShort("s"), .long], help: "Override storage directory (default follows app config)")
    var storage: String?

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments")
    var command: [String] = []

    mutating func run() async throws {
        var bridgedArguments: [String] = [CommandLine.arguments.first ?? "boss"]
        if let storage {
            let trimmed = storage.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                bridgedArguments.append(contentsOf: ["--storage", trimmed])
            }
        }
        bridgedArguments.append(contentsOf: command)

        do {
            let cli = BossCLI(arguments: bridgedArguments)
            try await cli.run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ValidationError(message)
        }
    }
}
