// Wire formats: a small Sendable JSON value (AWS Backup is REST-JSON) and a
// minimal XML tree (RDS and STS use the Query protocol with XML responses).
import Foundation

public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// AWS Backup timestamps arrive as epoch seconds (number). Returns RFC3339.
    public var timestamp: String? {
        if let n = double { return RFC3339.string(Date(timeIntervalSince1970: n)) }
        if let s = string, let d = RFC3339.date(s) { return RFC3339.string(d) }
        return nil
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        if data.isEmpty { return .object([:]) }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
}

/// A parsed XML element. RDS list results use <Parent><Member>..</Member></Parent>.
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public internal(set) var text: String = ""
    public internal(set) var children: [XMLNode] = []
    init(name: String) { self.name = name }

    /// First direct child with this name.
    public func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    /// Path lookup: node["DBInstances"]?.text etc.
    public subscript(_ path: String...) -> XMLNode? {
        var cur: XMLNode? = self
        for p in path { cur = cur?.child(p) }
        return cur
    }
    /// Text of a direct child, "" if absent.
    public func str(_ name: String) -> String { child(name)?.text ?? "" }
    public func optStr(_ name: String) -> String? { child(name).map(\.text).flatMap { $0.isEmpty ? nil : $0 } }
    public func int(_ name: String) -> Int { Int(str(name)) ?? 0 }
    public func int64(_ name: String) -> Int64 { Int64(str(name)) ?? 0 }
    public func bool(_ name: String) -> Bool { str(name) == "true" }
    /// The member elements of a list container child.
    public func list(_ name: String) -> [XMLNode] { child(name)?.children ?? [] }
    /// Depth-first search for the first element with this name.
    public func find(_ name: String) -> XMLNode? {
        if self.name == name { return self }
        for c in children { if let f = c.find(name) { return f } }
        return nil
    }

    public static func parse(_ data: Data) throws -> XMLNode {
        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw AWSError.decode("invalid XML: \(parser.parserError?.localizedDescription ?? "empty")")
        }
        return root
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: elementName)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let n = stack.popLast(), !n.children.isEmpty { n.text = "" }
    }
}

public enum AWSError: Error, LocalizedError, Sendable, Equatable {
    case credentials(String)
    case expired(String)
    case http(status: Int, code: String, message: String)
    case decode(String)
    case invalid(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .credentials(let m): return m
        case .expired(let m): return m
        case .http(let s, let c, let m): return "AWS error \(s) \(c): \(m)"
        case .decode(let m): return m
        case .invalid(let m): return m
        case .notFound(let m): return m
        }
    }
}
