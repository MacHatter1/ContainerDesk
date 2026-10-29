import CFNetwork
import Foundation

public enum MLXParsedChatEvent: Sendable, Equatable {
    case content(String)
    case done
}

/// Incremental, bounded parser for the `data:` lines emitted by mlx-lm's OpenAI-compatible SSE endpoint.
public struct MLXServerSentEventParser: Sendable {
    private var line = Data()
    public private(set) var didFinish = false
    public let maximumLineBytes: Int

    public init(maximumLineBytes: Int = 1_048_576) {
        self.maximumLineBytes = max(1_024, maximumLineBytes)
    }

    public mutating func feed(_ bytes: Data) throws -> [MLXParsedChatEvent] {
        var events: [MLXParsedChatEvent] = []
        for byte in bytes {
            if byte == 0x0A {
                if let event = try parseLine(line) { events.append(event) }
                line.removeAll(keepingCapacity: true)
            } else {
                guard line.count < maximumLineBytes else { throw MLXError.chatResponseTooLarge }
                line.append(byte)
            }
        }
        return events
    }

    public mutating func finish() throws -> [MLXParsedChatEvent] {
        guard !line.isEmpty else { return [] }
        let event = try parseLine(line)
        line.removeAll(keepingCapacity: false)
        return event.map { [$0] } ?? []
    }

    private mutating func parseLine(_ raw: Data) throws -> MLXParsedChatEvent? {
        var data = raw
        if data.last == 0x0D { data.removeLast() }
        guard let text = String(data: data, encoding: .utf8) else { throw MLXError.operationFailed("The local model returned invalid UTF-8.") }
        guard text.hasPrefix("data:") else { return nil }
        var payload = String(text.dropFirst(5))
        if payload.first == " " { payload.removeFirst() }
        if payload == "[DONE]" { didFinish = true; return .done }
        guard !payload.isEmpty else { return nil }
        guard let payloadData = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw MLXError.operationFailed("The local model returned an invalid chat event.")
        }
        if object["error"] != nil { throw MLXError.operationFailed("The local model rejected the chat request.") }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else { return nil }
        guard let delta = choice["delta"] as? [String: Any] else { return nil }
        if let content = delta["content"] as? String, !content.isEmpty { return .content(content) }
        return nil
    }
}

public protocol MLXChatStreamingTransport: Sendable {
    func stream(url: URL, body: Data) -> AsyncThrowingStream<String, Error>
}

public struct MLXOpenAIChatTransport: MLXChatStreamingTransport, Sendable {
    public init() {}

    public func stream(url: URL, body: Data) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard url.scheme == "http", url.host == "127.0.0.1", url.path == "/v1/chat/completions" else {
                continuation.finish(throwing: MLXError.invalidChatRequest)
                return
            }
            let delegate = MLXNoRedirectDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 0,
                kCFNetworkProxiesHTTPSEnable as String: 0,
            ]
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 300
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = body

            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse,
                          (200..<300).contains(response.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw MLXError.operationFailed("The local MLX server returned HTTP \(status).")
                    }
                    var parser = MLXServerSentEventParser()
                    var outputBytes = 0
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        for event in try parser.feed(Data([byte])) {
                            switch event {
                            case .content(let content):
                                outputBytes += content.utf8.count
                                guard outputBytes <= 2 * 1024 * 1024 else { throw MLXError.chatResponseTooLarge }
                                continuation.yield(content)
                            case .done:
                                continuation.finish()
                                session.invalidateAndCancel()
                                return
                            }
                        }
                    }
                    for event in try parser.finish() {
                        if case .content(let content) = event {
                            outputBytes += content.utf8.count
                            guard outputBytes <= 2 * 1024 * 1024 else { throw MLXError.chatResponseTooLarge }
                            continuation.yield(content)
                        }
                    }
                    guard parser.didFinish else { throw MLXError.operationFailed("The local model stream ended unexpectedly.") }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
                session.finishTasksAndInvalidate()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                session.invalidateAndCancel()
            }
        }
    }
}

private final class MLXNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
