import Foundation

/// A JSON value. The setup draft is kept in this form so the Python side stays the one place that defines its shape;
/// screens read and write it by dotted path ("profile.personal.first_name", "profile.work_history.0.title").
enum JSON: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSON].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(path: String) -> JSON {
        get { path.split(separator: ".").reduce(self) { $0.child(String($1)) } }
        set { self = setting(path.split(separator: ".").map(String.init)[...], to: newValue) }
    }

    func child(_ key: String) -> JSON {
        switch self {
        case .object(let o): return o[key] ?? .null
        case .array(let a):
            guard let i = Int(key), a.indices.contains(i) else { return .null }
            return a[i]
        default: return .null
        }
    }

    private func setting(_ keys: ArraySlice<String>, to value: JSON) -> JSON {
        guard let key = keys.first else { return value }
        let rest = keys.dropFirst()
        switch self {
        case .array(var a):
            guard let i = Int(key), a.indices.contains(i) else { return self }
            a[i] = a[i].setting(rest, to: value)
            return .array(a)
        case .object(var o):
            o[key] = (o[key] ?? .null).setting(rest, to: value)
            return .object(o)
        default:
            return JSON.object([:]).setting(keys, to: value)
        }
    }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var array: [JSON] { if case .array(let a) = self { return a } else { return [] } }
    var strings: [String] { array.compactMap(\.string) }
    var int: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// The value as text for a text field (numbers without a needless ".0").
    var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return ""
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements) { $1 }) }
    init(nilLiteral: ()) { self = .null }
}
