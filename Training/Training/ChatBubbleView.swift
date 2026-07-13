import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ChatBubbleView: View {
    let message: ChatMessage
    let isActiveSystem: Bool
    @State private var isExpanded: Bool

    init(message: ChatMessage, isActiveSystem: Bool) {
        self.message = message
        self.isActiveSystem = isActiveSystem
        self._isExpanded = State(initialValue: message.role == "system" && message.content.hasPrefix("❌"))
    }

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                if message.role == "system" {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        ScrollView {
                            Text(message.fullRequest)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    } label: {
                        Text(message.content)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(message.content)
                        .padding(10)
                        .background(backgroundColor(for: message.role))
                        .foregroundColor(message.role == "user" ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if (message.role == "assistant" || message.role == "system") && message.cost > 0 {
                    Text("\u{1F4B0} \u{00A5}\(String(format: "%.4f", message.cost))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if message.role == "assistant" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onChange(of: isActiveSystem) { _, new in isExpanded = new }
        .contextMenu {
            Button(action: {
#if os(iOS)
                UIPasteboard.general.string = message.content
#endif
            }) {
                Label("复制内容", systemImage: "doc.on.doc")
            }
            if message.role == "system", !message.fullRequest.isEmpty {
                Button(action: {
#if os(iOS)
                    UIPasteboard.general.string = message.fullRequest
#endif
                }) {
                    Label("复制详情", systemImage: "doc.on.doc.fill")
                }
            }
        }
    }

    func backgroundColor(for role: String) -> Color {
        role == "user" ? .blue.opacity(0.8) : .gray.opacity(0.15)
    }
}
