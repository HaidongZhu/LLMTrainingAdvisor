import Foundation
import Testing
@testable import TrainingApp

private final class EchoTool: HealthTool, @unchecked Sendable {
    let name: String
    init(name: String) { self.name = name }

    func execute(params: [String: String]) async -> String {
        params["val"] ?? "default"
    }
}

private func makePlannedTool(name: String, callId: String, params: [String: String]) -> PlannedTool {
    let dict: [String: Any] = ["name": name, "call_id": callId, "params": params]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(PlannedTool.self, from: data)
}

@Suite("ToolRegistry")
struct ToolRegistryTests {

    @Test("duplicate call_id keeps first result")
    func testDuplicateCallIdKeepsFirst() async {
        let registry = ToolRegistry()
        registry.register(EchoTool(name: "echo"))

        let tools: [PlannedTool] = [
            makePlannedTool(name: "echo", callId: "dup", params: ["val": "first"]),
            makePlannedTool(name: "echo", callId: "dup", params: ["val": "second"]),
        ]

        let results = await registry.execute(tools)
        #expect(results["dup"] == "first")
    }

    @Test("tool execution returns results keyed by callId")
    func testToolExecutionReturnsByCallId() async {
        let registry = ToolRegistry()
        registry.register(EchoTool(name: "echo"))

        let tools: [PlannedTool] = [
            makePlannedTool(name: "echo", callId: "a", params: ["val": "A"]),
            makePlannedTool(name: "echo", callId: "b", params: ["val": "B"]),
        ]

        let results = await registry.execute(tools)
        #expect(results["a"] == "A")
        #expect(results["b"] == "B")
        #expect(results.count == 2)
    }
}
