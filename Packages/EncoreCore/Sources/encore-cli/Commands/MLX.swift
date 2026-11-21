import EncoreCore
import EncoreMLX
import Foundation
import MLX

func runMLXCommand(_ args: [String]) async throws {
    // Smoke check that the Metal library is found.
    let x = MLXArray([1.0, 2.0, 3.0] as [Float])
    print("mlx ok:", (x * 2).sum().item(Float.self))
}
