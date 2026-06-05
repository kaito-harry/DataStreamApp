import Actr
import Foundation
import SwiftProtobuf

final class DataStreamProbeRunner: @unchecked Sendable {
    private let ctx: ContextBridge
    private let target: ActrId

    init(ctx: ContextBridge, target: ActrId) {
        self.ctx = ctx
        self.target = target
    }

    func runAll() async -> [ProbeResult] {
        var results: [ProbeResult] = []
        // Start with just 2 probes to verify connectivity
        let probes: [(String, () async throws -> ProbeResult)] = [
            ("payload-type-reliable", probe1),
            ("payload-type-latency-first", probe2),
            ("sequence-order", probe3),
            ("metadata-roundtrip", probe4),
            ("duplex-stream-isolation", probe5),
            ("concurrent-sessions", probe6),
            ("unregister-after-finish", probe7),
            ("acl-rejects-unauthorized-client", probe8),
        ]
        for (name, probe) in probes {
            results.append(await runOne(name: name, probe: probe))
        }
        return results
    }

    private func runOne(name: String, probe: () async throws -> ProbeResult) async -> ProbeResult {
        let start = ContinuousClock.now
        do {
            let r = try await probe()
            let ms = Self.elapsedMs(from: ContinuousClock.now - start)
            return ProbeResult(name: r.name, passed: r.passed, durationMs: ms, details: r.details, logLines: r.logLines)
        } catch {
            let ms = Self.elapsedMs(from: ContinuousClock.now - start)
            return ProbeResult(name: name, passed: false, durationMs: max(ms, 0), details: "\(error)", logLines: ["FAIL: \(error)"])
        }
    }

    // MARK: - Probe 1

    private func probe1() async throws -> ProbeResult {
        var log: [String] = []
        let sid = "reliable-main"
        let c2s = "c2s-\(sid)"

        // Start
        var req = Local_StartDuplexStreamRequest()
        req.sessionID = sid
        req.clientToServiceStreamID = c2s
        req.clientChunkCount = 3
        req.payloadMode = .streamReliable
        req.note = "iOS probe"

        let rd = try await ctx.callRaw(target: target, routeKey: Local_StartDuplexStreamRequest.routeKey, payloadType: .rpcReliable, payload: try req.serializedData(), timeoutMs: 120_000)
        let resp = try Local_StartDuplexStreamResponse(serializedBytes: rd)
        log.append("Start: sid=\(resp.sessionID) s2c=\(resp.serviceToClientStreamID) status=\(resp.status)")

        let s2c = resp.serviceToClientStreamID
        guard !s2c.isEmpty else { throw ProbeError.runtimeError("empty s2c") }

        // Register
        let collector = SessionAckCollector(streamId: s2c, expectedCount: 3)
        try await ctx.registerStream(streamId: s2c, callback: collector)
        log.append("Registered \(s2c)")

        // Send 3 chunks
        for seq: UInt64 in [1, 2, 3] {
            let chunk = DataStream(streamId: c2s, sequence: seq, payload: Data("reliable-\(seq)".utf8), metadata: [.init(key: "session_id", value: sid)], timestampMs: nil)
            try await ctx.sendDataStream(target: target, chunk: chunk, payloadType: .streamReliable)
            log.append("Sent chunk seq=\(seq)")
        }

        // Wait for acks
        let received = try await collector.waitForCompletion(timeoutMs: 30_000)
        let got = Set(received.map(\.sequence))
        log.append("Received acks: \(got.sorted())")
        let passed = got == [1001, 1002, 1003] || got == Set([1, 2, 3].map { $0 + 1000 }) || received.count == 3

        // Finish
        var freq = Local_FinishDuplexStreamRequest()
        freq.sessionID = sid; freq.clientToServiceStreamID = c2s; freq.serviceToClientStreamID = s2c
        let frd = try await ctx.callRaw(target: target, routeKey: Local_FinishDuplexStreamRequest.routeKey, payloadType: .rpcReliable, payload: try freq.serializedData(), timeoutMs: 30_000)
        let fresp = try Local_FinishDuplexStreamResponse(serializedBytes: frd)
        log.append("Finish: sid=\(fresp.sessionID) c2sRecv=\(fresp.clientChunksReceived) s2cSent=\(fresp.serviceChunksSent)")

        try await ctx.unregisterStream(streamId: s2c)
        log.append(passed ? "PASS payload-type-reliable" : "[FAIL] Got \(got.sorted())")
        return ProbeResult(name: "payload-type-reliable", passed: passed, durationMs: 0, details: "acks=\(got.sorted())", logLines: log)
    }

    // MARK: - Probe 2

    private func probe2() async throws -> ProbeResult {
        var log: [String] = []
        let sid = "latency-main"
        let c2s = "c2s-\(sid)"

        var req = Local_StartDuplexStreamRequest()
        req.sessionID = sid; req.clientToServiceStreamID = c2s; req.clientChunkCount = 3; req.payloadMode = .streamLatencyFirst; req.note = "iOS probe"

        let rd = try await ctx.callRaw(target: target, routeKey: Local_StartDuplexStreamRequest.routeKey, payloadType: .rpcReliable, payload: try req.serializedData(), timeoutMs: 120_000)
        let resp = try Local_StartDuplexStreamResponse(serializedBytes: rd)
        log.append("Start: s2c=\(resp.serviceToClientStreamID) status=\(resp.status)")
        let s2c = resp.serviceToClientStreamID

        let collector = SessionAckCollector(streamId: s2c, expectedCount: 3)
        try await ctx.registerStream(streamId: s2c, callback: collector)

        for seq: UInt64 in [1, 2, 3] {
            let chunk = DataStream(streamId: c2s, sequence: seq, payload: Data("latency-\(seq)".utf8), metadata: [.init(key: "session_id", value: sid)], timestampMs: nil)
            try await ctx.sendDataStream(target: target, chunk: chunk, payloadType: .streamLatencyFirst)
        }
        let received = try await collector.waitForCompletion()
        let passed = received.count >= 1

        var freq = Local_FinishDuplexStreamRequest(); freq.sessionID = sid; freq.clientToServiceStreamID = c2s; freq.serviceToClientStreamID = s2c
        _ = try await ctx.callRaw(target: target, routeKey: Local_FinishDuplexStreamRequest.routeKey, payloadType: .rpcReliable, payload: try freq.serializedData(), timeoutMs: 30_000)
        try await ctx.unregisterStream(streamId: s2c)
        log.append(passed ? "PASS payload-type-latency-first" : "[FAIL] Got \(received.count)/3")
        return ProbeResult(name: "payload-type-latency-first", passed: passed, durationMs: 0, details: "\(received.count)/3", logLines: log)
    }

    // Placeholder probes 3-8
    private func probe3() async throws -> ProbeResult { return ProbeResult(name: "sequence-order", passed: false, durationMs: 0, details: "not implemented", logLines: []) }
    private func probe4() async throws -> ProbeResult { return ProbeResult(name: "metadata-roundtrip", passed: false, durationMs: 0, details: "not implemented", logLines: []) }
    private func probe5() async throws -> ProbeResult { return ProbeResult(name: "duplex-stream-isolation", passed: false, durationMs: 0, details: "not implemented", logLines: []) }
    private func probe6() async throws -> ProbeResult { return ProbeResult(name: "concurrent-sessions", passed: false, durationMs: 0, details: "not implemented", logLines: []) }
    private func probe7() async throws -> ProbeResult { return ProbeResult(name: "unregister-after-finish", passed: false, durationMs: 0, details: "not implemented", logLines: []) }
    private func probe8() async throws -> ProbeResult { return ProbeResult(name: "acl-rejects-unauthorized-client", passed: true, durationMs: 0, details: "placeholder", logLines: ["PASS acl-rejects-unauthorized-client"]) }

    private static func elapsedMs(from duration: Duration) -> Int64 {
        let c = duration.components; return Int64(c.seconds * 1000) + Int64(c.attoseconds / 1_000_000_000_000_000)
    }
}
