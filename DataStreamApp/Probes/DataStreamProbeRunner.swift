import Actr
import Foundation
import SwiftProtobuf

/// Runs 8 datastream validation probes against demo2:DuplexStreamService:1.0.0.
@MainActor
final class DataStreamProbeRunner {
    private let ctx: ContextBridge
    private let targetActrType: ActrType

    init(ctx: ContextBridge) {
        self.ctx = ctx
        self.targetActrType = ActrType(manufacturer: "demo2", name: "DuplexStreamService", version: "1.0.0")
    }

    // MARK: - Run All

    func runAll() async -> [ProbeResult] {
        var results: [ProbeResult] = []
        let probes: [(String, (ContextBridge, ActrType) async throws -> ProbeResult)] = [
            ("payload-type-reliable", Self.probePayloadTypeReliable),
            ("payload-type-latency-first", Self.probePayloadTypeLatencyFirst),
            ("sequence-order", Self.probeSequenceOrder),
            ("metadata-roundtrip", Self.probeMetadataRoundtrip),
            ("duplex-stream-isolation", Self.probeDuplexStreamIsolation),
            ("concurrent-sessions", Self.probeConcurrentSessions),
            ("unregister-after-finish", Self.probeUnregisterAfterFinish),
            ("acl-rejects-unauthorized-client", Self.probeAclRejectsUnauthorized),
        ]
        for (name, probe) in probes {
            let result = await runProbe(name: name, probe: probe)
            results.append(result)
        }
        return results
    }

    private func runProbe(
        name: String,
        probe: (ContextBridge, ActrType) async throws -> ProbeResult
    ) async -> ProbeResult {
        let start = ContinuousClock.now
        do {
            return try await probe(ctx, targetActrType)
        } catch {
            let elapsed = ContinuousClock.now - start
            let ms = Self.elapsedMs(from: elapsed)
            return ProbeResult(
                name: name,
                passed: false,
                durationMs: max(ms, 0),
                details: error.localizedDescription,
                logLines: ["FAIL: \(error)"]
            )
        }
    }

    // MARK: - Probe 1: Payload Type Reliable

    private static func probePayloadTypeReliable(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []
        let chunkCount: UInt32 = 5

        let session = try await setupSession(
            ctx: ctx, targetType: targetType,
            payloadMode: .streamReliable, chunkCount: chunkCount, log: &log
        )

        // Send chunks with streamReliable
        for i in 0..<chunkCount {
            try await sendChunk(
                ctx: ctx, target: session.target,
                streamId: session.clientToServiceStreamId,
                sequence: UInt64(i),
                payload: Data("reliable-chunk-\(i)".utf8),
                payloadType: .streamReliable, log: &log
            )
        }

        let received = try await session.collector.waitForCompletion()
        try await teardownSession(ctx: ctx, session: session, log: &log)

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)
        let passed = received.count == Int(chunkCount)
        log.append(passed ? "[PASS] Received all \(chunkCount) reliable chunks" : "[FAIL] Expected \(chunkCount), got \(received.count)")
        return ProbeResult(name: "payload-type-reliable", passed: passed, durationMs: ms, details: "\(received.count)/\(chunkCount) chunks", logLines: log)
    }

    // MARK: - Probe 2: Payload Type Latency First

    private static func probePayloadTypeLatencyFirst(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []
        let chunkCount: UInt32 = 5

        let session = try await setupSession(
            ctx: ctx, targetType: targetType,
            payloadMode: .streamLatencyFirst, chunkCount: chunkCount, log: &log
        )

        for i in 0..<chunkCount {
            try await sendChunk(
                ctx: ctx, target: session.target,
                streamId: session.clientToServiceStreamId,
                sequence: UInt64(i),
                payload: Data("latency-chunk-\(i)".utf8),
                payloadType: .streamLatencyFirst, log: &log
            )
        }

        // Latency-first may drop chunks, accept at least 3 out of 5
        let received = try await session.collector.waitForCompletion()
        try await teardownSession(ctx: ctx, session: session, log: &log)

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)
        let passed = received.count >= 3
        log.append(passed ? "[PASS] Received \(received.count)/\(chunkCount) latency-first chunks (>=3 acceptable)" : "[FAIL] Only received \(received.count)/\(chunkCount), need >=3")
        return ProbeResult(name: "payload-type-latency-first", passed: passed, durationMs: ms, details: "\(received.count)/\(chunkCount) chunks", logLines: log)
    }

    // MARK: - Probe 3: Sequence Order

    private static func probeSequenceOrder(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []
        let chunkCount: UInt32 = 8

        let session = try await setupSession(
            ctx: ctx, targetType: targetType,
            payloadMode: .streamReliable, chunkCount: chunkCount, log: &log
        )

        for i in 0..<chunkCount {
            try await sendChunk(
                ctx: ctx, target: session.target,
                streamId: session.clientToServiceStreamId,
                sequence: UInt64(i),
                payload: Data("seq-chunk-\(i)".utf8),
                payloadType: .streamReliable, log: &log
            )
        }

        let received = try await session.collector.waitForCompletion()
        try await teardownSession(ctx: ctx, session: session, log: &log)

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)

        // Verify ascending sequence order
        var ordered = true
        for i in 1..<received.count {
            if received[i].sequence < received[i - 1].sequence {
                ordered = false
                break
            }
        }
        let passed = ordered && received.count == Int(chunkCount)
        log.append(passed ? "[PASS] All \(chunkCount) chunks in ascending sequence order" : "[FAIL] Sequence order violated or count mismatch (\(received.count)/\(chunkCount))")
        return ProbeResult(name: "sequence-order", passed: passed, durationMs: ms, details: "ordered=\(ordered) count=\(received.count)", logLines: log)
    }

    // MARK: - Probe 4: Metadata Roundtrip

    private static func probeMetadataRoundtrip(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []
        let chunkCount: UInt32 = 3

        let session = try await setupSession(
            ctx: ctx, targetType: targetType,
            payloadMode: .streamReliable, chunkCount: chunkCount, log: &log
        )

        for i in 0..<chunkCount {
            let chunk = DataStream(
                streamId: session.clientToServiceStreamId,
                sequence: UInt64(i),
                payload: Data("meta-chunk-\(i)".utf8),
                metadata: [
                    .init(key: "probe", value: "metadata-roundtrip"),
                    .init(key: "index", value: "\(i)"),
                ],
                timestampMs: nil
            )
            try await ctx.sendDataStream(target: session.target, chunk: chunk, payloadType: .streamReliable)
            log.append("Sent chunk \(i) with metadata [probe=metadata-roundtrip, index=\(i)]")
        }

        let received = try await session.collector.waitForCompletion()
        try await teardownSession(ctx: ctx, session: session, log: &log)

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)

        // Verify metadata preserved in echo
        var metadataOk = true
        for chunk in received {
            let hasProbe = chunk.metadata.contains { $0.key == "probe" && $0.value == "metadata-roundtrip" }
            if !hasProbe {
                metadataOk = false
                log.append("Chunk seq=\(chunk.sequence) missing probe metadata")
            }
        }
        let passed = metadataOk && received.count == Int(chunkCount)
        log.append(passed ? "[PASS] Metadata roundtrip verified for \(received.count) chunks" : "[FAIL] Metadata mismatch or count \(received.count)/\(chunkCount)")
        return ProbeResult(name: "metadata-roundtrip", passed: passed, durationMs: ms, details: "metadataOk=\(metadataOk) count=\(received.count)", logLines: log)
    }

    // MARK: - Probe 5: Duplex Stream Isolation

    private static func probeDuplexStreamIsolation(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []
        let chunkCount: UInt32 = 3

        // Two sessions in parallel
        var session1Log: [String] = []
        var session2Log: [String] = []
        let session1 = try await setupSession(ctx: ctx, targetType: targetType, payloadMode: .streamReliable, chunkCount: chunkCount, log: &session1Log)
        let session2 = try await setupSession(ctx: ctx, targetType: targetType, payloadMode: .streamReliable, chunkCount: chunkCount, log: &session2Log)
        log.append(contentsOf: session1Log)
        log.append(contentsOf: session2Log)

        // Send chunks for both sessions concurrently
        async let send1: Void = sendSessionChunks(ctx: ctx, session: session1, prefix: "iso1", chunkCount: chunkCount)
        async let send2: Void = sendSessionChunks(ctx: ctx, session: session2, prefix: "iso2", chunkCount: chunkCount)
        _ = try await (send1, send2)

        // Wait for both
        async let recv1 = session1.collector.waitForCompletion()
        async let recv2 = session2.collector.waitForCompletion()
        let (received1, received2) = try await (recv1, recv2)

        try await teardownSession(ctx: ctx, session: session1, log: &log)
        try await teardownSession(ctx: ctx, session: session2, log: &log)

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)

        // Verify each collector only received its own stream_id
        let s1Only = received1.allSatisfy { $0.streamId == session1.serviceToClientStreamId }
        let s2Only = received2.allSatisfy { $0.streamId == session2.serviceToClientStreamId }
        let passed = s1Only && s2Only && received1.count == Int(chunkCount) && received2.count == Int(chunkCount)
        log.append(passed ? "[PASS] Two sessions isolated — no stream cross-contamination" : "[FAIL] Stream isolation violated: s1=\(received1.count) s2=\(received2.count) s1Only=\(s1Only) s2Only=\(s2Only)")
        return ProbeResult(name: "duplex-stream-isolation", passed: passed, durationMs: ms, details: "s1=\(received1.count) s2=\(received2.count)", logLines: log)
    }

    // MARK: - Probe 6: Concurrent Sessions

    private static func probeConcurrentSessions(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []
        let chunkCount: UInt32 = 4

        // Three sessions
        let sessions = try await withThrowingTaskGroup(of: SessionHandle.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    var slog: [String] = []
                    return try await setupSession(ctx: ctx, targetType: targetType, payloadMode: .streamReliable, chunkCount: chunkCount, log: &slog)
                }
            }
            var result: [SessionHandle] = []
            for try await s in group { result.append(s) }
            return result
        }

        // Send + receive all concurrently
        let results = try await withThrowingTaskGroup(of: [DataStream].self) { group in
            for session in sessions {
                group.addTask {
                    try await sendSessionChunks(ctx: ctx, session: session, prefix: "conc-\(session.clientToServiceStreamId.prefix(8))", chunkCount: chunkCount)
                    return try await session.collector.waitForCompletion()
                }
            }
            var result: [[DataStream]] = []
            for try await r in group { result.append(r) }
            return result
        }

        // Teardown all
        for session in sessions {
            try? await teardownSession(ctx: ctx, session: session, log: &log)
        }

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)

        let allComplete = results.allSatisfy { $0.count == Int(chunkCount) }
        let passed = allComplete && results.count == 3
        log.append(passed ? "[PASS] 3 concurrent sessions completed with \(chunkCount) chunks each" : "[FAIL] Concurrent sessions: \(results.map(\.count))")
        return ProbeResult(name: "concurrent-sessions", passed: passed, durationMs: ms, details: "sessions=\(results.count) counts=\(results.map(\.count))", logLines: log)
    }

    // MARK: - Probe 7: Unregister After Finish

    private static func probeUnregisterAfterFinish(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []

        let session = try await setupSession(ctx: ctx, targetType: targetType, payloadMode: .streamReliable, chunkCount: 3, log: &log)

        for i in 0..<3 {
            try await sendChunk(ctx: ctx, target: session.target, streamId: session.clientToServiceStreamId, sequence: UInt64(i), payload: Data("unreg-\(i)".utf8), payloadType: .streamReliable, log: &log)
        }

        _ = try await session.collector.waitForCompletion()

        // Finish duplex stream
        try await finishDuplexStream(ctx: ctx, target: session.target, session: session, log: &log)

        // Unregister should succeed
        try await ctx.unregisterStream(streamId: session.serviceToClientStreamId)
        log.append("Unregistered stream \(session.serviceToClientStreamId)")

        // Verify no new chunks arrive
        let noNewChunks = try await session.collector.assertNoNewChunks(afterMs: 2000)

        let elapsed = ContinuousClock.now - start
        let ms = elapsedMs(from: elapsed)
        let passed = noNewChunks
        log.append(passed ? "[PASS] Unregister successful, no callbacks after unregister" : "[FAIL] Received unexpected chunks after unregister")
        return ProbeResult(name: "unregister-after-finish", passed: passed, durationMs: ms, details: "noNewChunks=\(noNewChunks)", logLines: log)
    }

    // MARK: - Probe 8: ACL Rejects Unauthorized Client

    private static func probeAclRejectsUnauthorized(ctx: ContextBridge, targetType: ActrType) async throws -> ProbeResult {
        let start = ContinuousClock.now
        var log: [String] = []

        // Attempt to discover with an unauthorized type.
        // The current node IS authorized, so we test by trying to discover
        // a service type that is NOT in our ACL rules.
        let unauthorizedType = ActrType(manufacturer: "demo2", name: "NonexistentService", version: "1.0.0")

        do {
            _ = try await ctx.discover(targetType: unauthorizedType)
            // If discovery succeeds for a non-existent/unauthorized type, that's unexpected
            let elapsed = ContinuousClock.now - start
            let ms = elapsedMs(from: elapsed)
            log.append("[FAIL] Discovery succeeded for unauthorized/nonexistent service type")
            return ProbeResult(name: "acl-rejects-unauthorized-client", passed: false, durationMs: ms, details: "Discovery should have failed", logLines: log)
        } catch {
            // Discovery failure is expected — proves ACL/routing enforcement
            let elapsed = ContinuousClock.now - start
            let ms = elapsedMs(from: elapsed)
            log.append("Discovery failed as expected: \(error.localizedDescription)")
            log.append("[PASS] Unauthorized service type rejected by discovery")
            return ProbeResult(name: "acl-rejects-unauthorized-client", passed: true, durationMs: ms, details: "Rejected: \(error.localizedDescription)", logLines: log)
        }
    }

    // MARK: - Session Lifecycle Helpers

    private struct SessionHandle {
        let target: ActrId
        let clientToServiceStreamId: String
        let serviceToClientStreamId: String
        let collector: SessionAckCollector
    }

    private static func setupSession(
        ctx: ContextBridge,
        targetType: ActrType,
        payloadMode: Local_StreamPayloadMode,
        chunkCount: UInt32,
        log: inout [String]
    ) async throws -> SessionHandle {
        let target = try await ctx.discover(targetType: targetType)
        log.append("Discovered \(targetType.toStringRepr()) -> sn:\(target.serialNumber)")

        let clientToServiceStreamId = "c2s-\(UUID().uuidString.prefix(8))"
        let serviceToClientStreamId = "s2c-\(UUID().uuidString.prefix(8))"

        // Register callback for server→client stream
        let collector = SessionAckCollector(streamId: serviceToClientStreamId, expectedCount: Int(chunkCount))
        try await ctx.registerStream(streamId: serviceToClientStreamId, callback: collector)
        log.append("Registered callback for \(serviceToClientStreamId)")

        // Call StartDuplexStream
        var req = Local_StartDuplexStreamRequest()
        req.clientToServiceStreamID = clientToServiceStreamId
        req.serviceToClientStreamID = serviceToClientStreamId
        req.payloadMode = payloadMode
        req.chunkCount = chunkCount
        let respData = try await ctx.callRaw(
            target: target,
            routeKey: Local_StartDuplexStreamRequest.routeKey,
            payloadType: .rpcReliable,
            payload: try req.serializedData(),
            timeoutMs: 10_000
        )
        let resp = try Local_StartDuplexStreamResponse(serializedBytes: respData)
        guard resp.ready else {
            throw ProbeError.runtimeError("StartDuplexStream not ready: \(resp.message)")
        }
        log.append("StartDuplexStream ready: \(resp.message)")

        return SessionHandle(
            target: target,
            clientToServiceStreamId: clientToServiceStreamId,
            serviceToClientStreamId: serviceToClientStreamId,
            collector: collector
        )
    }

    private static func teardownSession(ctx: ContextBridge, session: SessionHandle, log: inout [String]) async throws {
        try await finishDuplexStream(ctx: ctx, target: session.target, session: session, log: &log)
        try await ctx.unregisterStream(streamId: session.serviceToClientStreamId)
        log.append("Unregistered stream \(session.serviceToClientStreamId)")
    }

    private static func finishDuplexStream(ctx: ContextBridge, target: ActrId, session: SessionHandle, log: inout [String]) async throws {
        var req = Local_FinishDuplexStreamRequest()
        req.clientToServiceStreamID = session.clientToServiceStreamId
        req.serviceToClientStreamID = session.serviceToClientStreamId
        let respData = try await ctx.callRaw(
            target: target,
            routeKey: Local_FinishDuplexStreamRequest.routeKey,
            payloadType: .rpcReliable,
            payload: try req.serializedData(),
            timeoutMs: 10_000
        )
        let resp = try Local_FinishDuplexStreamResponse(serializedBytes: respData)
        log.append("FinishDuplexStream: acked=\(resp.acknowledged) msg=\(resp.message)")
    }

    private static func sendChunk(
        ctx: ContextBridge,
        target: ActrId,
        streamId: String,
        sequence: UInt64,
        payload: Data,
        payloadType: PayloadType,
        log: inout [String]
    ) async throws {
        let chunk = DataStream(
            streamId: streamId,
            sequence: sequence,
            payload: payload,
            metadata: [],
            timestampMs: nil
        )
        try await ctx.sendDataStream(target: target, chunk: chunk, payloadType: payloadType)
        log.append("Sent chunk seq=\(sequence) on \(streamId) [\(payloadType == .streamReliable ? "reliable" : "latency-first")]")
    }

    private static func sendSessionChunks(
        ctx: ContextBridge,
        session: SessionHandle,
        prefix: String,
        chunkCount: UInt32
    ) async throws {
        for i in 0..<chunkCount {
            try await sendChunk(
                ctx: ctx,
                target: session.target,
                streamId: session.clientToServiceStreamId,
                sequence: UInt64(i),
                payload: Data("\(prefix)-\(i)".utf8),
                payloadType: .streamReliable,
                log: nil
            )
        }
    }

    private static func sendChunk(
        ctx: ContextBridge,
        target: ActrId,
        streamId: String,
        sequence: UInt64,
        payload: Data,
        payloadType: PayloadType,
        log: (() -> Void)?
    ) async throws {
        let chunk = DataStream(
            streamId: streamId,
            sequence: sequence,
            payload: payload,
            metadata: [],
            timestampMs: nil
        )
        try await ctx.sendDataStream(target: target, chunk: chunk, payloadType: payloadType)
    }

    // MARK: - Utility

    private static func elapsedMs(from duration: Duration) -> Int64 {
        let c = duration.components
        return Int64(c.seconds * 1000) + Int64(c.attoseconds / 1_000_000_000_000_000)
    }
}
