// Output identical to Go's json.Encoder with SetIndent("", "  "): struct
// fields in declaration order, 2-space indent, `"key": value`, `[]`/`{}`
// for empty containers, and HTML-safe escaping of <, > and &. Foundation's
// JSONEncoder does not keep declaration order, so the CLI and settings.json
// use this small ordered encoder instead.
import Foundation

public enum GoJSON {
    /// json.MarshalIndent(v, "", "  ") (or json.Marshal with indent: false);
    /// no trailing newline.
    public static func encode<T: Encodable>(_ value: T, indent: Bool = true) throws -> Data {
        let box = Box()
        var root = SingleTree(box: box, codingPath: [])
        try root.encode(value)
        var out = ""
        write(box.value ?? .null, indent: indent ? "  " : nil, level: 0, into: &out)
        return Data(out.utf8)
    }

    indirect enum Value {
        case null, bool(Bool), int(Int64), uint(UInt64), double(Double), string(String)
        case array([Box]), object([(String, Box)])
    }

    final class Box { var value: Value?; init(_ v: Value? = nil) { value = v } }

    static func write(_ v: Value, indent: String?, level: Int, into out: inout String) {
        func nl(_ l: Int) { if let indent { out += "\n" + String(repeating: indent, count: l) } }
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .uint(let u): out += String(u)
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e21 { out += String(Int64(d)) } else { out += String(d) }
        case .string(let s): quote(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, b) in a.enumerated() {
                if i > 0 { out += "," }
                nl(level + 1); write(b.value ?? .null, indent: indent, level: level + 1, into: &out)
            }
            nl(level); out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            for (i, (k, b)) in o.enumerated() {
                if i > 0 { out += "," }
                nl(level + 1); quote(k, into: &out); out += indent == nil ? ":" : ": "
                write(b.value ?? .null, indent: indent, level: level + 1, into: &out)
            }
            nl(level); out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<", ">", "&", "\u{2028}", "\u{2029}":
                out += String(format: "\\u%04x", u.value)
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }
}

private final class TreeEncoder: Encoder {
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    let box: GoJSON.Box
    init(codingPath: [CodingKey], box: GoJSON.Box = .init()) { self.codingPath = codingPath; self.box = box }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        if case .object = box.value {} else { box.value = .object([]) }
        return KeyedEncodingContainer(KeyedTree<Key>(box: box, codingPath: codingPath))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if case .array = box.value {} else { box.value = .array([]) }
        return UnkeyedTree(box: box, codingPath: codingPath)
    }
    func singleValueContainer() -> SingleValueEncodingContainer { SingleTree(box: box, codingPath: codingPath) }
}

private func encodeValue<T: Encodable>(_ v: T, path: [CodingKey]) throws -> GoJSON.Box {
    let b = GoJSON.Box()
    var c = SingleTree(box: b, codingPath: path)
    try c.encode(v)
    return b
}

private struct KeyedTree<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let box: GoJSON.Box
    let codingPath: [CodingKey]
    private func put(_ k: Key, _ b: GoJSON.Box) {
        guard case .object(var o) = box.value else { return }
        if let i = o.firstIndex(where: { $0.0 == k.stringValue }) { o[i].1 = b } else { o.append((k.stringValue, b)) }
        box.value = .object(o)
    }
    mutating func encodeNil(forKey key: Key) throws { put(key, .init(.null)) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        put(key, try encodeValue(value, path: codingPath + [key]))
    }
    mutating func nestedContainer<NK: CodingKey>(keyedBy keyType: NK.Type, forKey key: Key) -> KeyedEncodingContainer<NK> {
        let b = GoJSON.Box(.object([])); put(key, b)
        return KeyedEncodingContainer(KeyedTree<NK>(box: b, codingPath: codingPath + [key]))
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let b = GoJSON.Box(.array([])); put(key, b)
        return UnkeyedTree(box: b, codingPath: codingPath + [key])
    }
    mutating func superEncoder() -> Encoder { TreeEncoder(codingPath: codingPath) }
    mutating func superEncoder(forKey key: Key) -> Encoder {
        let b = GoJSON.Box(); put(key, b); return TreeEncoder(codingPath: codingPath + [key], box: b)
    }
}

private struct IndexKey: CodingKey {
    var stringValue: String { String(intValue!) }
    var intValue: Int?
    init(_ i: Int) { intValue = i }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.intValue = intValue }
}

private struct UnkeyedTree: UnkeyedEncodingContainer {
    let box: GoJSON.Box
    let codingPath: [CodingKey]
    var count: Int { if case .array(let a) = box.value { return a.count }; return 0 }
    private func add(_ b: GoJSON.Box) {
        guard case .array(var a) = box.value else { return }
        a.append(b); box.value = .array(a)
    }
    mutating func encodeNil() throws { add(.init(.null)) }
    mutating func encode<T: Encodable>(_ value: T) throws { add(try encodeValue(value, path: codingPath + [IndexKey(count)])) }
    mutating func nestedContainer<NK: CodingKey>(keyedBy keyType: NK.Type) -> KeyedEncodingContainer<NK> {
        let b = GoJSON.Box(.object([])); add(b)
        return KeyedEncodingContainer(KeyedTree<NK>(box: b, codingPath: codingPath))
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let b = GoJSON.Box(.array([])); add(b)
        return UnkeyedTree(box: b, codingPath: codingPath)
    }
    mutating func superEncoder() -> Encoder { let b = GoJSON.Box(); add(b); return TreeEncoder(codingPath: codingPath, box: b) }
}

/// String-keyed dictionaries, whose keys Go's encoder sorts.
private protocol GoStringKeyedMap {}
extension Dictionary: GoStringKeyedMap where Key == String {}

private struct SingleTree: SingleValueEncodingContainer {
    let box: GoJSON.Box
    let codingPath: [CodingKey]
    mutating func encodeNil() throws { box.value = .null }
    mutating func encode(_ v: Bool) throws { box.value = .bool(v) }
    mutating func encode(_ v: String) throws { box.value = .string(v) }
    mutating func encode(_ v: Double) throws { box.value = .double(v) }
    mutating func encode(_ v: Float) throws { box.value = .double(Double(v)) }
    mutating func encode(_ v: Int) throws { box.value = .int(Int64(v)) }
    mutating func encode(_ v: Int8) throws { box.value = .int(Int64(v)) }
    mutating func encode(_ v: Int16) throws { box.value = .int(Int64(v)) }
    mutating func encode(_ v: Int32) throws { box.value = .int(Int64(v)) }
    mutating func encode(_ v: Int64) throws { box.value = .int(v) }
    mutating func encode(_ v: UInt) throws { box.value = .uint(UInt64(v)) }
    mutating func encode(_ v: UInt8) throws { box.value = .uint(UInt64(v)) }
    mutating func encode(_ v: UInt16) throws { box.value = .uint(UInt64(v)) }
    mutating func encode(_ v: UInt32) throws { box.value = .uint(UInt64(v)) }
    mutating func encode(_ v: UInt64) throws { box.value = .uint(v) }
    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: TreeEncoder(codingPath: codingPath, box: box))
        // Go writes map keys sorted by their UTF-8 bytes.
        if value is any GoStringKeyedMap, case .object(let o) = box.value {
            box.value = .object(o.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) })
        }
    }
}
