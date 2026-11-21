import Foundation

/// A generation parameter value. Encodes as a bare JSON scalar.
public enum ParamValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        default: nil
        }
    }
    public var intValue: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): Int(v)
        default: nil
        }
    }
    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }

    /// Loosely typed form for JSON bridges (Python helper, future HTTP API).
    public var jsonObject: Any {
        switch self {
        case .bool(let v): v
        case .int(let v): v
        case .double(let v): v
        case .string(let v): v
        }
    }
}

public typealias ParamValues = [String: ParamValue]
