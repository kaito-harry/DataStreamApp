import Actr
import Foundation

/// Per-session collector for manual stream echo chunks.
actor StreamEchoCollector: DataStreamCallback {
    private var chunks: [UInt64: DataStream] = [:]
    private let expectedCount: Int
    private let streamId: String

    init(streamId: String, expectedCount: Int) {
        self.streamId = streamId
        self.expectedCount = expectedCount
    }

    func onStream(chunk: DataStream, sender: ActrId) async throws {
        guard chunk.streamId == streamId else { return }
        chunks[chunk.sequence] = chunk
    }

    var receivedCount: Int { chunks.count }

    func waitForCompletion(timeoutMs: Int64) async throws -> [DataStream] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if chunks.count >= expectedCount {
                return sortedChunks()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if chunks.count >= expectedCount {
            return sortedChunks()
        }
        throw ProbeError.timeout(
            "StreamEchoCollector: received \(chunks.count)/\(expectedCount) chunks on stream \(streamId)"
        )
    }

    private func sortedChunks() -> [DataStream] {
        chunks.values.sorted { $0.sequence < $1.sequence }
    }

    static func displayLine(payload: String) -> String {
        if payload.hasPrefix("echo: hello ") {
            let suffix = payload.dropFirst("echo: hello ".count)
            return "received: echo \(suffix)"
        }
        if payload.hasPrefix("echo:") {
            return "received: \(payload)"
        }
        if payload.hasPrefix("hello ") {
            let suffix = payload.dropFirst("hello ".count)
            return "received: echo \(suffix)"
        }
        return "received: \(payload)"
    }
}
