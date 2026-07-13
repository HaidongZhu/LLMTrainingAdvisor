import Foundation

struct PlannedTool: Codable {
    let name: String
    let callId: String
    let params: [String: String]
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        callId = (try? c.decode(String.self, forKey: .callId)) ?? name
        var p: [String: String] = [:]
        if let nested = try? c.decode([String: String].self, forKey: .params) {
            p = nested
        } else if let mixed = try? c.decode([String: AnyCodable].self, forKey: .params) {
            p = mixed.mapValues { $0.stringValue }
        }
        if p.isEmpty {
            let knownKeys = ["metric", "range", "filter", "sort"]
            let topLevel = try? decoder.container(keyedBy: DynamicCodingKeys.self)
            for key in knownKeys {
                if let v = try? topLevel?.decode(String.self, forKey: DynamicCodingKeys(stringValue: key)!) {
                    p[key] = v
                } else if let v = try? topLevel?.decode(Int.self, forKey: DynamicCodingKeys(stringValue: key)!) {
                    p[key] = String(v)
                }
            }
        }
        params = p
    }

    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(callId, forKey: .callId)
        try c.encode(params, forKey: .params)
    }

    private enum CodingKeys: String, CodingKey { case name, callId = "call_id", params }
}

struct AnyCodable: Codable {
    let stringValue: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { stringValue = s }
        else if let i = try? c.decode(Int.self) { stringValue = String(i) }
        else if let d = try? c.decode(Double.self) { stringValue = AnyCodable.format(d) }
        else { stringValue = "" }
    }
    static func format(_ d: Double) -> String {
        if d.rounded() == d && abs(d) < 1e15 { return String(Int(d)) }
        return String(d)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(stringValue)
    }
}

protocol HealthTool {
    var name: String { get }
    func execute(params: [String: String]) async -> String
}

final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: HealthTool] = [:]
    private let queue = DispatchQueue(label: "tool.registry")

    func register(_ tool: HealthTool) {
        queue.sync { tools[tool.name] = tool }
    }

    func execute(_ planned: [PlannedTool]) async -> [String: String] {
        var results: [String: String] = [:]
        for p in planned {
            if results[p.callId] != nil { continue }
            let tool = queue.sync { tools[p.name] }
            if let t = tool {
                results[p.callId] = await t.execute(params: p.params)
            }
        }
        return results
    }
}
