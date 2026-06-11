import Actr
import Foundation
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.actrium.DataStreamApp", category: "ActrService")

@MainActor
final class ActrService: ObservableObject {
    @Published var status = "Starting ACTR node..."
    @Published var errorMessage: String?
    @Published var results: [ProbeResult] = []
    @Published var isRunning = false
    @Published var logLines: [String] = []

    private var actrNode: ActrNode?
    private var actorRef: ActrRef?
    private var isStarting = false
    private var hasRun = false

    var isReady: Bool { actorRef != nil }

    func startIfNeeded() async {
        guard actorRef == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            let configURL = try materializeRuntimeConfig()
            let actorType = ActrType(manufacturer: "zqharry", name: "DuplexStreamProbeClient", version: "1.0.0")

            let handler = ProbeHandlerImpl(service: self)
            let workload = DynamicWorkload(
                lifecycle: ProbeLifecycleAdapter(workload: ProbeServiceWorkload(handler: handler)),
                signaling: nil,
                websocket: nil,
                webrtc: nil,
                credential: nil,
                mailbox: nil
            )

            let node = try await ActrNode.linked(config: configURL, type: actorType, workload: workload)
            let ref = try await node.start()

            actrNode = node
            actorRef = ref
            status = "Ready: \(actorType.toStringRepr())"
            NSLog("[DataStreamApp] ✅ node started")
        } catch {
            status = "ACTR startup failed: \(error)"
            errorMessage = String(describing: error)
            NSLog("[DataStreamApp] ❌ Startup failed: \(error)")
        }
    }

    func stop() async {
        guard let actorRef else { return }
        await actorRef.stop()
        self.actorRef = nil
        actrNode = nil
    }

    nonisolated var shouldAutoRun: Bool {
        ProcessInfo.processInfo.environment["ACTR_DATASTREAMAPP_AUTO_RUN"] == "1"
    }

    func runAllProbes() async {
        guard self.actorRef != nil, !hasRun else {
            logger.warning("runAllProbes: actorRef=\(self.actorRef != nil) hasRun=\(self.hasRun)")
            return
        }
        hasRun = true
        NSLog("[DataStreamApp] runAllProbes: calling StartProbe RPC...")
        isRunning = true
        results = []
        logLines = ["--- Starting DataStream probe run ---"]

        var req = Local_StartProbeRequest()
        req.probeName = "run-all"
        req.targetType = "zqharry:DuplexStreamService:1.0.0"

        do {
            let resp: Local_StartProbeResponse = try await self.actorRef!.call(req)
            logLines.append("StartProbe response: started=\(resp.started) msg=\(resp.message)")
        } catch {
            logLines.append("[FAIL] StartProbe RPC failed: \(error)")
            NSLog("[DataStreamApp] StartProbe RPC failed: \(error)")
        }
        isRunning = false
    }

    private func materializeRuntimeConfig() throws -> URL {
        guard let templateURL = Bundle.main.url(forResource: "actr", withExtension: "toml") else {
            throw ActrServiceError.missingConfigTemplate
        }

        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appURL = supportURL.appendingPathComponent("DataStreamApp", isDirectory: true)
        let dataURL = appURL.appendingPathComponent("hyper", isDirectory: true)
        try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

        var config = try String(contentsOf: templateURL, encoding: .utf8)
        config += """

        [hyper]
        data_dir = "\(dataURL.path)"

        [hyper.trust]
        kind = "dev_only"
        """

        let configURL = appURL.appendingPathComponent("actr.toml")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }
}

private enum ActrServiceError: Error {
    case missingConfigTemplate
}

// MARK: - ProbeService RPC Handler

/// Implements ProbeServiceHandler.startProbe(req:ctx:).
/// When this RPC fires, ctx is delivered — discover target then run all probes.
private final class ProbeHandlerImpl: ProbeServiceHandler, @unchecked Sendable {
    private weak var service: ActrService?

    init(service: ActrService) {
        self.service = service
    }

    func startProbe(
        req: Local_StartProbeRequest,
        ctx: Context
    ) async throws -> Local_StartProbeResponse {
        NSLog("[DataStreamApp] 🔵 startProbe handler, discovering DuplexStreamService...")

        // Discover target synchronously so we can return immediately if not found
        let targetType = try ActrType.fromStringRepr("zqharry:DuplexStreamService:1.0.0")
        let target: ActrId
        do {
            target = try await ctx.discover(targetType: targetType)
            NSLog("[DataStreamApp] Discovered target: \(target.type.toStringRepr())")
        } catch {
            NSLog("[DataStreamApp] ❌ discover failed: \(error)")
            var resp = Local_StartProbeResponse()
            resp.started = false
            resp.message = "discover failed: \(error)"
            return resp
        }

        // Run probes synchronously — ctx is only valid inside the handler
        let svc = service
        let runner = DataStreamProbeRunner(ctx: ctx, target: target)
        var allResults = await runner.runAll()

        // Run real ACL probe and replace p8 placeholder
        if let aclResult = await runAclProbe() {
            // Replace the placeholder p8 result (last in array)
            if let p8Idx = allResults.lastIndex(where: { $0.name == "acl-rejects-unauthorized-client" }) {
                allResults[p8Idx] = aclResult
            }
        }

        for r in allResults {
            let status = r.passed ? "PASS" : "FAIL"
            NSLog("[DataStreamApp] [\(status)] \(r.name) (\(r.durationMs)ms): \(r.details)")
        }
        let passCount = allResults.filter(\.passed).count
        NSLog("[DataStreamApp] Done: \(passCount)/\(allResults.count) passed")

        await MainActor.run {
            svc?.results = allResults
            svc?.isRunning = false
            for r in allResults {
                svc?.logLines.append(contentsOf: r.logLines)
            }
        }

        var resp = Local_StartProbeResponse()
        resp.started = true
        resp.message = "\(passCount)/\(allResults.count) passed"
        return resp
    }

    /// Starts a second linked node with unauthorized identity to test ACL rejection.
    private func runAclProbe() async -> ProbeResult? {
        let start = ContinuousClock.now
        do {
            let unauthorizedType = ActrType(manufacturer: "demo2", name: "UnauthorizedStreamProbeClient", version: "1.0.0")

            // Create a config with empty ACL
            let configURL = try makeUnauthorizedConfig()

            // Simple lifecycle — just try to discover
            let adapter = AclProbeLifecycleAdapter()
            let workload = DynamicWorkload(
                lifecycle: adapter,
                signaling: nil, websocket: nil, webrtc: nil, credential: nil, mailbox: nil
            )

            let node = try await ActrNode.linked(config: configURL, type: unauthorizedType, workload: workload)
            let ref = try await node.start()

            // Wait a moment for onReady
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            // Try discover the same target as the main probe
            let targetType = try ActrType.fromStringRepr("zqharry:DuplexStreamService:1.0.0")
            if let ctx = adapter.savedCtx {
                do {
                    _ = try await ctx.discover(targetType: targetType)
                    // Success = ACL failure
                    await ref.stop()
                    let ms = elapsedMs(from: ContinuousClock.now - start)
                    return ProbeResult(name: "acl-rejects-unauthorized-client", passed: false, durationMs: ms, details: "Discovery succeeded — ACL not enforced", logLines: ["FAIL: unauthorized client should be rejected"])
                } catch {
                    // Expected: discovery fails
                    await ref.stop()
                    let ms = elapsedMs(from: ContinuousClock.now - start)
                    NSLog("[DataStreamApp] ACL probe: unauthorized discovery rejected: \(error)")
                    return ProbeResult(name: "acl-rejects-unauthorized-client", passed: true, durationMs: ms, details: "Rejected: \(error.localizedDescription)", logLines: ["PASS acl-rejects-unauthorized-client error=failed to discover DuplexStreamService"])
                }
            } else {
                await ref.stop()
                let ms = elapsedMs(from: ContinuousClock.now - start)
                return ProbeResult(name: "acl-rejects-unauthorized-client", passed: false, durationMs: ms, details: "onReady never fired for unauthorized node", logLines: ["FAIL: onReady never fired"])
            }
        } catch {
            let ms = elapsedMs(from: ContinuousClock.now - start)
            // If the node itself fails to start, that's also an ACL pass (unauthorized identity rejected)
            let errStr = String(describing: error)
            if errStr.contains("Forbidden") || errStr.contains("rejected") || errStr.contains("unauthorized") || errStr.contains("ACL") {
                NSLog("[DataStreamApp] ACL probe: unauthorized node rejected at start: \(error)")
                return ProbeResult(name: "acl-rejects-unauthorized-client", passed: true, durationMs: ms, details: "Rejected at start: \(errStr)", logLines: ["PASS acl-rejects-unauthorized-client error=failed to start unauthorized client"])
            }
            NSLog("[DataStreamApp] ACL probe error: \(error)")
            return ProbeResult(name: "acl-rejects-unauthorized-client", passed: false, durationMs: ms, details: "Error: \(errStr)", logLines: ["FAIL: \(errStr)"])
        }
    }
}

// MARK: - Unauthorized Config Generator

private func makeUnauthorizedConfig() throws -> URL {
    let fileManager = FileManager.default
    let supportURL = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let appURL = supportURL.appendingPathComponent("DataStreamApp", isDirectory: true)
    let dataURL = appURL.appendingPathComponent("hyper-acl", isDirectory: true)
    try fileManager.createDirectory(at: dataURL, withIntermediateDirectories: true)

    // CI mode: use ACTR_CI_HOST_IP env var for dynamic host IP
    let ciHostIP = ProcessInfo.processInfo.environment["ACTR_CI_HOST_IP"]
    let signalingHost: String
    let realmID: Int
    let realmSecret: String

    if let ciIP = ciHostIP, !ciIP.isEmpty {
        signalingHost = "\(ciIP):8080"
        realmID = 1001
        realmSecret = "rs_TI1u7FdVIrp1giKCd580-Ap42mE7-kmx"
    } else {
        signalingHost = "124.71.231.251:9080"
        realmID = 33554433
        realmSecret = "rs_CA1ueOmjzSmmd8UCgJeefGoCYWPkj8Oh"
    }

    // Extract host:port for STUN URL (drop port, always use 3478)
    let stunHost = signalingHost.split(separator: ":").first.map(String.init) ?? signalingHost

    let config = """
    [signaling]
    url = "ws://\(signalingHost)/signaling/ws"

    [ais_endpoint]
    url = "http://\(signalingHost)/ais"

    [deployment]
    realm_id = \(realmID)
    realm_secret = "\(realmSecret)"

    [discovery]
    visible = false

    [observability]
    filter_level = "error"
    tracing_enabled = false

    [webrtc]
    force_relay = false
    stun_urls = ["stun:\(stunHost):3478"]

    [hyper]
    data_dir = "\(dataURL.path)"

    [hyper.trust]
    kind = "dev_only"
    """

    let configURL = appURL.appendingPathComponent("actr-acl.toml")
    try config.write(to: configURL, atomically: true, encoding: .utf8)
    return configURL
}

// MARK: - ACL Probe Lifecycle Adapter

private final class AclProbeLifecycleAdapter: Workload, @unchecked Sendable {
    var savedCtx: ContextBridge?

    func onStart(ctx: ContextBridge) async throws {}
    func onReady(ctx: ContextBridge) async throws { savedCtx = ctx }
    func onStop(ctx: ContextBridge) async throws {}
    func onError(ctx: ContextBridge, event: ErrorEventBridge) async throws {}
    func dispatch(ctx: ContextBridge, envelope: RpcEnvelopeBridge) async throws -> Data {
        throw ActrError.UnknownRoute(msg: "No dispatch for ACL probe")
    }
}

// MARK: - Lifecycle Adapter

private final class ProbeLifecycleAdapter: Workload, @unchecked Sendable {
    private let workload: ProbeServiceWorkload<ProbeHandlerImpl>

    init(workload: ProbeServiceWorkload<ProbeHandlerImpl>) {
        self.workload = workload
    }

    func onStart(ctx: ContextBridge) async throws {}
    func onReady(ctx: ContextBridge) async throws {}
    func onStop(ctx: ContextBridge) async throws {}

    func onError(ctx: ContextBridge, event: ErrorEventBridge) async throws {
        NSLog("[DataStreamApp] ProbeLifecycleAdapter error: \(event)")
    }

    func dispatch(ctx: ContextBridge, envelope: RpcEnvelopeBridge) async throws -> Data {
        try await workload.__dispatch(ctx: ctx, envelope: envelope)
    }
}

private func elapsedMs(from duration: Duration) -> Int64 {
    let c = duration.components
    return Int64(c.seconds * 1000) + Int64(c.attoseconds / 1_000_000_000_000_000)
}
