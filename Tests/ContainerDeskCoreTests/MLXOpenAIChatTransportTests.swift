import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

struct MLXOpenAIChatTransportTests {
    @Test func streamsLocalHTTPEventsAndStopsAtDone() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello 👩‍💻\"}}]}\n\ndata: [DONE]\n\n"
        let server = try ChatHTTPFixture(body: body)
        defer { server.stop() }
        var chunks: [String] = []
        for try await chunk in MLXOpenAIChatTransport().stream(url: server.url, body: Data("{}".utf8)) { chunks.append(chunk) }
        #expect(chunks == ["Hello 👩‍💻"])
    }

    @Test(arguments: [302, 500])
    func rejectsRedirectsAndHTTPFailures(status: Int) async throws {
        let server = try ChatHTTPFixture(body: "", status: status)
        defer { server.stop() }
        await #expect(throws: MLXError.self) {
            for try await _ in MLXOpenAIChatTransport().stream(url: server.url, body: Data("{}".utf8)) {}
        }
    }

    @Test func truncatedEventStreamFailsInsteadOfClaimingSuccess() async throws {
        let server = try ChatHTTPFixture(body: "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n")
        defer { server.stop() }
        await #expect(throws: MLXError.self) {
            for try await _ in MLXOpenAIChatTransport().stream(url: server.url, body: Data("{}".utf8)) {}
        }
    }

    @Test func refusesNonLoopbackDestinationsBeforeConnecting() async {
        await #expect(throws: MLXError.invalidChatRequest) {
            for try await _ in MLXOpenAIChatTransport().stream(url: URL(string: "https://example.com/v1/chat/completions")!, body: Data()) {}
        }
    }

    @Test func cancellingAQuietConnectionFinishesTheConsumer() async throws {
        let server = try ChatHTTPFixture(body: "", hold: true)
        defer { server.stop() }
        let consumer = Task {
            do { for try await _ in MLXOpenAIChatTransport().stream(url: server.url, body: Data("{}".utf8)) {} } catch {}
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while !server.connected {
            try #require(ContinuousClock.now < deadline, "HTTP test connection did not open")
            try await Task.sleep(for: .milliseconds(2))
        }
        consumer.cancel()
        await consumer.value
        #expect(ContinuousClock.now < deadline)
    }
}

private final class ChatHTTPFixture: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private let finished = DispatchGroup()
    let url: URL
    var connected: Bool { lock.withLock { client >= 0 } }

    init(body: String, status: Int = 200, hold: Bool = false) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        listener = descriptor
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { close(descriptor); throw POSIXError(.EIO) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard named == 0 else { close(descriptor); throw POSIXError(.EIO) }
        url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/v1/chat/completions")!
        finished.enter()
        Thread.detachNewThread { [self] in
            defer { finished.leave() }
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            lock.withLock { client = fd }
            defer { lock.withLock { client = -1 }; close(fd) }
            var noPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            var readTimeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes = [UInt8](repeating: 0, count: 4096)
            // A single read can contain only part of the headers or body. Closing
            // with unread request data can reset TCP and discard the HTTP response.
            var request = Data()
            var requestLength: Int?
            while request.count < 64 * 1024 {
                let count = read(fd, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                request.append(contentsOf: bytes.prefix(count))
                if requestLength == nil, let end = request.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(decoding: request[..<end.lowerBound], as: UTF8.self)
                    guard let field = headers.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                          let length = Int(field.dropFirst("content-length:".count).trimmingCharacters(in: .whitespacesAndNewlines)),
                          (0...64 * 1024).contains(length) else { return }
                    requestLength = end.upperBound + length
                }
                if let requestLength, request.count >= requestLength { break }
            }
            guard let requestLength, request.count >= requestLength else { return }
            if hold {
                while read(fd, &bytes, bytes.count) > 0 {}
                return
            }
            let response = "HTTP/1.1 \(status) Test\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nLocation: http://127.0.0.1:1/redirect\r\nConnection: close\r\n\r\n\(body)"
            // Byte-sized writes exercise split UTF-8 through the real HTTP transport.
            for byte in response.utf8 {
                var byte = byte
                if write(fd, &byte, 1) != 1 { break }
            }
        }
    }

    func stop() {
        _ = shutdown(listener, SHUT_RDWR)
        _ = close(listener)
        lock.withLock { if client >= 0 { _ = shutdown(client, SHUT_RDWR) } }
        _ = finished.wait(timeout: .now() + 2)
    }
}
