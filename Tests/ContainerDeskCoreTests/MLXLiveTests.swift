import Darwin
import Foundation
import Testing
@testable import ContainerDeskCore

struct MLXLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINERDESK_MLX_LIVE_CHECK"] == "1"))
    func startsCachedModelStreamsChatAndStopsOwnedServer() async throws {
        let service = DefaultMLXModelService()
        do {
            let capability = await service.capability()
            try #require(capability.available, "The gated live check requires the verified local mlx_lm toolchain.")
            let localModels = try await service.listLocalModels()
            let models = localModels.filter(\.isReady)
            let model = try #require(models.min(by: { $0.diskBytes < $1.diskBytes }), "The gated live check requires a ready, locally cached MLX model.")
            let port = try availableLoopbackPort()
            let server = try await service.startServer(modelID: model.id, options: MLXServerOptions(port: port, maxTokens: 32, temperature: 0))

            let readinessDeadline = Date.now.addingTimeInterval(300)
            var running = false
            while Date.now < readinessDeadline, !Task.isCancelled {
                if await service.ownedServers().first(where: { $0.id == server.id })?.state == .running {
                    running = true
                    break
                }
                if await service.ownedServers().first(where: { $0.id == server.id })?.state == .failed { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(running, "The app-owned loopback MLX server did not become ready.")
            if running {
                let options = try MLXChatOptions(maxTokens: 32, temperature: 0)
                let response = await service.chat(
                    serverID: server.id,
                    messages: [MLXChatMessage(role: .user, content: "Reply with one short greeting.")],
                    options: options
                )
                let (firstChunks, firstChunkContinuation) = AsyncStream<String>.makeStream()
                let consumer = Task {
                    do { for try await chunk in response where !chunk.isEmpty { firstChunkContinuation.yield(chunk) } } catch {}
                }
                var iterator = firstChunks.makeAsyncIterator()
                let firstChunk = await iterator.next()
                consumer.cancel()
                await consumer.value
                firstChunkContinuation.finish()
                #expect(firstChunk?.isEmpty == false)
            }
            await service.stopAllOwnedServers()
            let ended = await service.ownedServers().first(where: { $0.id == server.id })?.state == .stopped
            #expect(ended)
            await service.shutdown()
        } catch {
            await service.shutdown()
            throw error
        }
    }

    private func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MLXError.operationFailed("Could not allocate a local test socket.") }
        defer { _ = close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw MLXError.operationFailed("Could not reserve a temporary local port.") }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw MLXError.operationFailed("Could not read a temporary local port.") }
        return UInt16(bigEndian: bound.sin_port)
    }
}
