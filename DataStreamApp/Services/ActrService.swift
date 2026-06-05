import Actr
import Foundation
import SwiftUI

@MainActor
final class ActrService: ObservableObject {
    @Published var status = "Starting ACTR node..."
    @Published var errorMessage: String?
    @Published var results: [ProbeResult] = []
    @Published var isRunning = false
    @Published var logLines: [String] = []

    private var actrNode: ActrNode?
    private var actorRef: ActrRef?
    private var ctx: ContextBridge?
    private var isStarting = false

    var isReady: Bool { ctx != nil }

    func startIfNeeded() async {
        guard ctx == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        do {
            let configURL = try materializeRuntimeConfig()
            let actorType = ActrType(manufacturer: "demo2", name: "DuplexStreamProbeClient", version: "1.0.0")

            let lifecycleAdapter = ProbeClientLifecycleAdapter(onReady: { [weak self] bridge in
                Task { @MainActor in
                    self?.ctx = bridge
                }
            })

            let workload = DynamicWorkload(
                lifecycle: lifecycleAdapter,
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
        } catch {
            status = "ACTR startup failed: \(error)"
            errorMessage = String(describing: error)
        }
    }

    func stop() async {
        guard let actorRef else { return }
        await actorRef.stop()
        self.actorRef = nil
        actrNode = nil
        ctx = nil
    }

    func runAllProbes() async {
        guard let ctx else { return }
        isRunning = true
        results = []
        logLines = ["--- Starting DataStream probe run ---"]

        let runner = DataStreamProbeRunner(ctx: ctx)
        let probeResults = await runner.runAll()

        results = probeResults
        for result in probeResults {
            logLines.append(contentsOf: result.logLines)
        }

        let passCount = probeResults.filter(\.passed).count
        logLines.append("--- Done: \(passCount)/\(probeResults.count) passed ---")
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

/// Simple Workload lifecycle adapter for a pure client.
/// Saves ContextBridge in onReady. No local service dispatch.
private final class ProbeClientLifecycleAdapter: Workload, @unchecked Sendable {
    private let onReadyHandler: (ContextBridge) -> Void

    init(onReady: @escaping (ContextBridge) -> Void) {
        self.onReadyHandler = onReady
    }

    func onStart(ctx: ContextBridge) async throws {}

    func onReady(ctx: ContextBridge) async throws {
        onReadyHandler(ctx)
    }

    func onStop(ctx: ContextBridge) async throws {}

    func onError(ctx: ContextBridge, event: ErrorEventBridge) async throws {
        print("ProbeClientLifecycleAdapter error: \(event)")
    }

    func dispatch(ctx: ContextBridge, envelope: RpcEnvelopeBridge) async throws -> Data {
        // Pure client — no local RPC to dispatch
        throw ActrError.Internal(msg: "No local service dispatch for DataStreamApp client")
    }
}
