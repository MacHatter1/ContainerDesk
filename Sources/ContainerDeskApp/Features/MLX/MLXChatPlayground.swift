import AppKit
import ContainerDeskCore
import SwiftUI

struct MLXChatPlayground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var store: MLXStore
    let sceneID: String
    let server: MLXServerSession?
    @Binding var maxTokens: Int
    @Binding var temperature: Double

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(server.map { "Local server · 127.0.0.1:\(String($0.port))" } ?? "Server required", systemImage: "network")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Conversation stays on this Mac and in memory.")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Clear", systemImage: "trash") {
                    if let server { store.clearChat(serverID: server.id, sceneID: sceneID) }
                }
                .disabled(server == nil)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)

            if let server, server.state == .running {
                transcript(serverID: server.id)
                Divider()
                ChatComposer(
                    isStreaming: store.isChatStreaming(for: server.id, sceneID: sceneID),
                    canSend: server.state == .running,
                    send: { text in
                        Task {
                            await store.sendChat(serverID: server.id, sceneID: sceneID, text: text, maxTokens: maxTokens, temperature: temperature)
                        }
                    },
                    stop: { store.cancelChat(serverID: server.id, sceneID: sceneID) }
                )
                .padding(14)
                if let error = store.chatError(serverID: server.id, sceneID: sceneID) {
                    Text(error)
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.bottom, 10)
                }
            } else if let server, server.state == .failed {
                ContentUnavailableView(
                    "Local server failed",
                    systemImage: "exclamationmark.triangle",
                    description: Text(server.detail ?? "See Server Logs for details, then retry from Overview.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Start this model’s server first",
                    systemImage: "play.circle",
                    description: Text("Chat Playground sends requests only to a running ContainerDesk-owned server on 127.0.0.1.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDisappear { store.cancelChats(forScene: sceneID) }
    }

    private func transcript(serverID: UUID) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.conversation(serverID: serverID, sceneID: sceneID)) { turn in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(turn.role == .user ? "You" : "Assistant")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(turn.content.isEmpty && turn.role == .assistant ? "Generating…" : turn.content)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if turn.role == .assistant, !turn.content.isEmpty {
                                Button("Copy Reply", systemImage: "doc.on.doc") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(turn.content, forType: .string)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            turn.role == .user ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .id(turn.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: store.conversation(serverID: serverID, sceneID: sceneID).last?.content) { _, _ in
                if let last = store.conversation(serverID: serverID, sceneID: sceneID).last {
                withAnimation(reduceMotion ? nil : .easeOut(duration: ContainerDeskMotion.short)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}

private struct ChatComposer: View {
    let isStreaming: Bool
    let canSend: Bool
    let send: (String) -> Void
    let stop: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("Message the local model… (⌘ Return to send)", text: $draft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    submit()
                    return .handled
                }
                .disabled(!canSend || isStreaming)
            HStack {
                Text("Runs on this Mac · messages are not saved").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isStreaming {
                    Button("Stop Generation", systemImage: "stop.fill", role: .destructive, action: stop)
                } else {
                    Button("Send", systemImage: "arrow.up.circle.fill") { submit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, canSend, !isStreaming else { return }
        draft = ""
        send(value)
    }
}
