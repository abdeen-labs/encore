import Darwin
import Foundation

/// How hard macOS is working to find memory (the kernel's own pressure level).
public enum MemoryPressure: String, Codable, Sendable, Hashable {
    case normal, warning, critical
}

/// The machine's memory right now.
public struct SystemMemory: Codable, Sendable, Hashable {
    /// Installed RAM.
    public var physicalBytes: Int64
    /// What could be handed to a new allocation without compressing or swapping: installed RAM minus app
    /// memory, wired memory and the compressor (file cache counts as available, as in Activity Monitor).
    public var availableBytes: Int64
    public var pressure: MemoryPressure

    public init(physicalBytes: Int64, availableBytes: Int64, pressure: MemoryPressure = .normal) {
        self.physicalBytes = physicalBytes; self.availableBytes = availableBytes; self.pressure = pressure
    }

    public var usedBytes: Int64 { max(0, physicalBytes - availableBytes) }
}

/// Reads system memory. Injectable so the governor can be tested (and the CLI can pretend to be a smaller Mac).
public protocol SystemMemoryProbe: Sendable {
    func read() -> SystemMemory
}

/// The real machine, via `host_statistics64` and `kern.memorystatus_vm_pressure_level`.
public struct LiveSystemMemory: SystemMemoryProbe {
    public init() {}

    public func read() -> SystemMemory {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var available = physical
        if result == KERN_SUCCESS {
            let page = Int64(vm_kernel_page_size)
            let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
            let used = (max(0, app) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
            available = max(0, physical - used)
        }
        return SystemMemory(physicalBytes: physical, availableBytes: available, pressure: Self.pressure())
    }

    static func pressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        switch level {
        case 4...: return .critical
        case 2...: return .warning
        default: return .normal
        }
    }
}

/// The live machine capped to a smaller installed RAM, for exercising the governor on a big Mac.
public struct CappedSystemMemory: SystemMemoryProbe {
    public var capBytes: Int64
    public init(capBytes: Int64) { self.capBytes = capBytes }
    public func read() -> SystemMemory {
        let live = LiveSystemMemory().read()
        return SystemMemory(physicalBytes: min(capBytes, live.physicalBytes), availableBytes: min(capBytes, live.availableBytes),
                            pressure: live.pressure)
    }
}

/// When a model fits comfortably, when it's tight and when it won't fit.
///
/// Model sizes are the manifests' measured peak memory while generating (`ModelVariant.memoryBytes`),
/// so the arithmetic is deliberately simple:
/// - Encore keeps its loaded models within `budgetFraction` of installed RAM (the rest is the system's and other apps').
/// - A load is comfortable when it stays inside that budget and the memory free right now, minus a safety
///   headroom, covers it — possibly after unloading idle models, which the governor does on its own.
/// - It won't fit when the model alone exceeds the budget, or when the shortfall is more than
///   `swapToleranceFraction` of RAM even after unloading everything idle (heavy swapping).
/// - Anything in between is tight: it will load, but macOS will compress or swap and everything slows down.
/// Memory pressure from the kernel downgrades a comfortable verdict to tight.
public struct MemoryPolicy: Codable, Sendable, Hashable {
    public var budgetFraction: Double = 0.75
    public var headroomFraction: Double = 0.10
    public var minimumHeadroomBytes: Int64 = 2_000_000_000
    public var swapToleranceFraction: Double = 0.25

    public init() {}

    public func budget(physical: Int64) -> Int64 { Int64(Double(physical) * budgetFraction) }
    public func headroom(physical: Int64) -> Int64 { max(minimumHeadroomBytes, Int64(Double(physical) * headroomFraction)) }

    /// Whether `need` more bytes can be loaded next to `loaded` bytes of Encore models, given `available` free memory.
    public func fitsComfortably(need: Int64, loaded: Int64, available: Int64, physical: Int64) -> Bool {
        need + loaded <= budget(physical: physical) && need <= available - headroom(physical: physical)
    }

    /// - Parameters:
    ///   - need: the model's peak memory.
    ///   - loaded: memory of the other models Encore has loaded.
    ///   - evictable: the part of `loaded` that is idle and could be unloaded.
    public func verdict(need: Int64, loaded: Int64, evictable: Int64, memory: SystemMemory) -> (MemoryAssessment.Verdict, unloadsIdle: Bool) {
        let physical = memory.physicalBytes
        if need > budget(physical: physical) { return (.wontFit, false) }
        let downgrade = memory.pressure != .normal
        if fitsComfortably(need: need, loaded: loaded, available: memory.availableBytes, physical: physical) {
            return (downgrade ? .tight : .comfortable, false)
        }
        if fitsComfortably(need: need, loaded: loaded - evictable, available: memory.availableBytes + evictable, physical: physical) {
            return (downgrade ? .tight : .comfortable, true)
        }
        let shortfall = need - (memory.availableBytes + evictable - headroom(physical: physical))
        if Double(shortfall) > Double(physical) * swapToleranceFraction { return (.wontFit, evictable > 0) }
        return (.tight, evictable > 0)
    }
}

/// The answer to "will this model fit?", with the numbers behind it.
public struct MemoryAssessment: Codable, Sendable, Hashable {
    public enum Verdict: String, Codable, Sendable, Hashable { case comfortable, tight, wontFit }

    public var verdict: Verdict
    public var modelID: String
    public var variantID: String
    /// The variant's measured peak memory.
    public var requiredBytes: Int64
    public var memory: SystemMemory
    /// Memory of the other models Encore has loaded (by their measured peaks).
    public var loadedBytes: Int64
    /// The part of `loadedBytes` that is idle and would be unloaded to make room.
    public var evictableBytes: Int64
    public var budgetBytes: Int64
    public var headroomBytes: Int64
    /// Already loaded: nothing more is needed.
    public var alreadyLoaded: Bool
    /// Idle models the governor would unload first, least recently used first.
    public var wouldUnload: [String]

    /// One or two plain sentences for the UI.
    public var summary: String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        func s(_ b: Int64) -> String { f.string(fromByteCount: b) }
        if alreadyLoaded { return "Loaded and ready." }
        switch verdict {
        case .comfortable:
            let unload = wouldUnload.isEmpty ? "" : " Encore will unload \(wouldUnload.joined(separator: ", ")) first."
            return "Needs about \(s(requiredBytes)); \(s(memory.availableBytes)) is free.\(unload)"
        case .tight:
            let why = memory.pressure != .normal ? "the Mac is already short of memory" : "only \(s(memory.availableBytes)) is free"
            return "Needs about \(s(requiredBytes)) and \(why). It will run, but macOS will compress or swap memory and everything slows down. Quitting other apps helps."
        case .wontFit:
            if requiredBytes > budgetBytes {
                return "Needs about \(s(requiredBytes)), more than this Mac (\(s(memory.physicalBytes))) can comfortably hold. Pick a smaller variant."
            }
            return "Needs about \(s(requiredBytes)) but only \(s(memory.availableBytes)) is free. Quit other apps or pick a smaller variant."
        }
    }
}
