import Actr
import Foundation

/// Per-session DataStream ack collector.
/// Registered as DataStreamCallback for a specific service_to_client_stream_id.
/// Collects incoming DataStream chunks and supports awaiting expected count with timeout.
actor SessionAckCollector: DataStreamCallback {
    private var chunks: [UInt64: DataStream] = [:]
    private let expectedCount: Int
    private let streamId: String
    private var completed = false

    init(streamId: String, expectedCount: Int) {
        self.streamId = streamId
        self.expectedCount = expectedCount
    }

    func onStream(chunk: DataStream, sender: ActrId) async throws {
        // Only accept chunks for our stream
        guard chunk.streamId == streamId else { return }
        chunks[chunk.sequence] = chunk
        if chunks.count >= expectedCount {
            completed = true
        }
    }

    var isComplete: Bool { completed || chunks.count >= expectedCount }

    func getChunks() -> [DataStream] {
        chunks.values.sorted { $0.sequence < $1.sequence }
    }

    /// Poll until all expected chunks received or timeout.
    func waitForCompletion(timeoutMs: Int64 = 15_000) async throws -> [DataStream] {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if isComplete {
                return getChunks()
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        if isComplete {
            return getChunks()
        }
        throw ProbeError.timeout(
            "SessionAckCollector: received \(chunks.count)/\(expectedCount) chunks on stream \(streamId)"
        )
    }

    /// After unregister, verify no further callbacks fire by waiting briefly.
    func assertNoNewChunks(afterMs: Int64 = 2000) async throws -> Bool {
        let before = chunks.count
        try? await Task.sleep(nanoseconds: UInt64(afterMs) * 1_000_000)
        return chunks.count == before
    }
}
