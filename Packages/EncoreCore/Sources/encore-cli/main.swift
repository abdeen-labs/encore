import EncoreCore
import EncoreMLX
import Foundation

// Developer harness. Each area owns one file under Commands/.
//   encore-cli <area> <subcommand> [options]

let arguments = Array(CommandLine.arguments.dropFirst())
guard let area = arguments.first else {
    print("usage: encore-cli <catalog|hub|audio|text|mlx|python|service> …")
    exit(2)
}
let rest = Array(arguments.dropFirst())

do {
    switch area {
    case "catalog": try await runCatalogCommand(rest)
    case "hub": try await runHubCommand(rest)
    case "audio": try await runAudioCommand(rest)
    case "text": try await runTextCommand(rest)
    case "mlx": try await runMLXCommand(rest)
    case "python": try await runPythonCommand(rest)
    case "service": try await runServiceCommand(rest)
    default:
        print("unknown area: \(area)")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
