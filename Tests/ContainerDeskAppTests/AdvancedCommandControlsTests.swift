import AppKit
import SwiftUI
import ObjectiveC
import ApplicationServices
import ContainerDeskCore
import Testing
@testable import ContainerDeskApp

struct AdvancedCommandControlsTests {
    @MainActor @Test func cancelStaysEnabledAndCancelsTheOwnedStreamEvenWhenInputsAreInvalid() async throws {
        let client = AdvancedControlClient()
        let store = AppStore(client: client)
        let operation = store.streamWithID(CommandRequest(arguments: ["logs", "--follow", "--", "fixture"]), title: "Advanced Logs")
        let consumer = Task { for try await _ in operation.events { } }
        defer { consumer.cancel() }
        try await waitUntil { await client.started }
        _ = NativeTestApplication.shared
        let host = NSHostingView(rootView: AdvancedCommandControls(running: true, valid: false, run: {
            Issue.record("Run must remain disabled while a command is active")
        }, cancel: { store.cancelOperation(operation.operationID) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { !buttons(in: host).isEmpty }
        let controls = buttons(in: host)
        let cancel = try #require(controls.first { label($0) == "Cancel" })
        let run = try #require(controls.first { label($0) == "Running…" })
        #expect(cancel.value(forKey: "accessibilityEnabled") as? Bool == true)
        #expect(run.value(forKey: "accessibilityEnabled") as? Bool == false)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let method = try #require(class_getInstanceMethod(type(of: cancel), selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> ObjCBool
        let press = unsafeBitCast(method_getImplementation(method), to: Press.self)
        #expect(press(cancel, selector).boolValue)
        try await waitUntil { await client.cancelled }
        #expect(store.operations.first(where: { $0.id == operation.operationID })?.state == .cancelled)
    }

    // SwiftUI's accessibility nodes implement these public selectors without
    // formally adopting NSAccessibilityProtocol. Query the in-process objects.
    @MainActor private func buttons(in value: Any) -> [NSObject] {
        guard let value = value as? NSObject else { return [] }
        let role = NSSelectorFromString("accessibilityRole")
        let children = NSSelectorFromString("accessibilityChildren")
        var result: [NSObject] = []
        if value.responds(to: role), value.perform(role)?.takeUnretainedValue() as? String == NSAccessibility.Role.button.rawValue { result.append(value) }
        if value.responds(to: children), let children = value.perform(children)?.takeUnretainedValue() as? [Any] {
            for child in children { result += buttons(in: child) }
        }
        return result
    }

    @MainActor private func label(_ value: NSObject) -> String? {
        for name in ["accessibilityLabel", "accessibilityTitle"] {
            let selector = NSSelectorFromString(name)
            if value.responds(to: selector), let label = value.perform(selector)?.takeUnretainedValue() as? String { return label }
        }
        return nil
    }

    @MainActor private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await predicate())
    }
}

private actor AdvancedControlClient: ContainerClient {
    private(set) var started = false
    private(set) var cancelled = false
    private var continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation?
    nonisolated func stream(_ request: CommandRequest) -> AsyncThrowingStream<CommandEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in Task { await self.markCancelled() } }
            Task { await self.begin(continuation) }
        }
    }
    func run(_ request: CommandRequest) async throws -> CommandResult { throw CancellationError() }
    private func begin(_ continuation: AsyncThrowingStream<CommandEvent, Error>.Continuation) { self.continuation = continuation; started = true }
    private func markCancelled() { cancelled = true; continuation = nil }
}
