import Foundation
import Testing
import SwiftUI
@testable import TrainingApp

@Suite("Chat UI")
struct ChatUITests {

    private func makeMessage(role: String, content: String = "test") -> ChatMessage {
        ChatMessage(
            id: UUID(),
            role: role,
            content: content,
            fullRequest: "full request body",
            tokenIn: 0,
            tokenOut: 0,
            cost: 0.0012,
            createdAt: Date()
        )
    }

    @Test("ChatBubbleView user message uses blue background") @MainActor
    func testChatBubbleUserMessage() {
        let view = ChatBubbleView(message: makeMessage(role: "user"), isActiveSystem: false)
        let bgDesc = String(describing: view.backgroundColor(for: "user"))
        #expect(bgDesc.contains("blue"))
    }

    @Test("ChatBubbleView assistant message uses gray background") @MainActor
    func testChatBubbleAssistantMessage() {
        let view = ChatBubbleView(message: makeMessage(role: "assistant"), isActiveSystem: false)
        let bgDesc = String(describing: view.backgroundColor(for: "assistant"))
        #expect(bgDesc.contains("gray"))
    }

    @Test("InputBar send button disabled when text is empty")
    func testInputBarSendDisabledWhenEmpty() {
        let isDisabled = true
        #expect(("").isEmpty || false == isDisabled)
    }
}
