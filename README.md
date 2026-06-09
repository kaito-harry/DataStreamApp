# DataStreamApp

iOS SwiftUI App that validates branch-specific DuplexStreamService connectivity.

## Overview

| Item | dev branch | test branch | hw-actrix-unknown-service branch |
|------|------------|-------------|---------------------------------|
| Flow | Swift iOS app -> zq actrix -> zq `datastream-service` | Swift iOS app -> hw actrix -> zq `datastream-service-hw` | Swift iOS app -> hw actrix -> any registered datastream service |
| Actrix | `192.168.212.112:8080` | `124.71.231.251:9080` | `124.71.231.251:9080` |
| Target | `actrium:DuplexStreamService:0.1.0` | `demo2:DuplexStreamService:1.0.0` | `demo2:DuplexStreamService:1.0.0` |
| Client identity | `actrium:DuplexStreamProbeClient:1.0.0` | `demo2:DuplexStreamProbeClient:1.0.0` | `demo2:DuplexStreamProbeClient:1.0.0` |
| Realm | `1001` | `33554433` | `33554433` |
| Service home | `/home/actrium/datastream-service` | `/home/actrium/datastream-service-hw` | Unknown |
| Success criteria | 8 datastream probes pass | 8 datastream probes pass | Target discovery succeeds |
| Deployment target | iOS 26.2+ | iOS 26.2+ | iOS 26.2+ |
| Swift | 6.0 | 6.0 | 6.0 |
| Dependencies | actr-swift 0.3.3, SwiftProtobuf 1.32+ | actr-swift 0.3.3, SwiftProtobuf 1.32+ | actr-swift 0.3.3, SwiftProtobuf 1.32+ |

## Project Structure

```
DataStreamApp/
├── project.yml              # XcodeGen project spec
├── actr.toml                # ACTR linked runtime config for the current branch
├── actr.lock.toml           # Placeholder (local generated sources, no lock needed)
├── .protoc-plugin.toml      # protoc-gen-actrframework-swift version pin
├── protos/
│   └── local/
│       ├── duplex_stream.proto   # Remote DuplexStreamService contract
│       └── probe.proto           # Local ProbeService for ctx delivery
└── DataStreamApp/
    ├── App/
    │   └── DataStreamApp.swift   # @main entry point
    ├── Services/
    │   └── ActrService.swift     # Node lifecycle + ProbeService handler
    ├── Probes/
    │   ├── ProbeResult.swift      # Result model
    │   ├── SessionAckCollector.swift  # DataStreamCallback actor
    │   └── DataStreamProbeRunner.swift  # 8 probe implementations
    ├── Views/
    │   └── ContentView.swift      # SwiftUI UI
    └── Generated/
        └── local/
            ├── duplex_stream.pb.swift      # protoc --swift_out
            ├── duplex_stream.client.swift  # protoc --actrframework-swift_out
            ├── probe.pb.swift              # protoc --swift_out
            └── probe.actor.swift           # protoc --actrframework-swift_out
```

## Code Generation

Proto files are compiled to Swift with two `protoc` plugins:

```bash
cd DataStreamApp

# Remote service: client stub only (ProtoSource=Remote)
protoc \
  --proto_path=protos \
  --swift_out=DataStreamApp/Generated \
  --actrframework-swift_out=ProtoSource=Remote,Visibility=Public:DataStreamApp/Generated \
  protos/local/duplex_stream.proto

# Local service: actor scaffold (ProtoSource=Local)
protoc \
  --proto_path=protos \
  --swift_out=DataStreamApp/Generated \
  --actrframework-swift_out=ProtoSource=Local,Visibility=Public:DataStreamApp/Generated \
  protos/local/probe.proto
```

> **Note:** Generated files contain `public` visibility modifiers incompatible with Swift 6 module rules. The `public` keyword must be manually removed from `probe.actor.swift` and `duplex_stream.client.swift` after generation. The committed versions already have this fix applied.

## Xcode Project

```bash
xcodegen generate   # → DataStreamApp.xcodeproj
```

## Build

Always target a concrete arm64 simulator device (ActrFFI.xcframework only ships arm64):

```bash
xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination 'platform=iOS Simulator,id=<DEVICE_UDID>' build
```

Find a suitable device:
```bash
xcrun simctl list devices available | grep "iPhone.*18"
```

## Run (Manual)

```bash
# Boot device, install, launch
xcrun simctl boot <UDID>
xcrun simctl install <UDID> DataStreamApp.app
xcrun simctl launch <UDID> com.actrium.DataStreamApp

# Tap "Run All" button in the app
```

## Run (Auto)

Use the `SIMCTL_CHILD_` prefix to pass environment variables:

```bash
SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 \
  xcrun simctl launch --console <UDID> com.actrium.DataStreamApp
```

The app will:
1. Start ACTR linked node (connects to signaling, registers in realm)
2. Wait for `actorRef` to become ready
3. Call local `ProbeService.StartProbe` RPC → handler receives `ContextBridge`
4. Discover the branch-specific DuplexStreamService via signaling
5. Run the branch-specific verification flow
6. Print `[PASS]` / `[FAIL]` markers to console log

## 8 Probes

These probes apply to the `dev` and `test` branches. The `hw-actrix-unknown-service` branch stops after target discovery.

| # | Name | What It Validates |
|---|------|-------------------|
| 1 | `payload-type-reliable` | Reliable ordered stream delivery (sequence +1000 ack) |
| 2 | `payload-type-latency-first` | Low-latency stream delivery |
| 3 | `sequence-order` | Multi-chunk sequential send, verify ascending ack order |
| 4 | `metadata-roundtrip` | Metadata (`session_id`, `direction`, `chunk_label`) echoed back |
| 5 | `duplex-stream-isolation` | `c2s` and `s2c` stream IDs are distinct and isolated |
| 6 | `concurrent-sessions` | Two concurrent sessions (`concurrent-apple`, `concurrent-banana`) don't cross-contaminate |
| 7 | `unregister-after-finish` | No acks received after `FinishDuplexStream` + unregister |
| 8 | `acl-rejects-unauthorized-client` | Second linked node with unauthorized identity rejected at discovery |

Reference: [STREAM_CAPABILITY_VERIFICATION.zh.md](http://10.30.2.226:6419/4c71bac9/STREAM_CAPABILITY_VERIFICATION.zh.md)

## Architecture Notes

### Why `probe.proto` + `ProbeService`?

Pure ACTR clients need `ContextBridge` for `discover` / `callRaw` / `registerStream` / `sendDataStream`. `ContextBridge` is only available inside RPC handlers. The `ProbeService.StartProbe` RPC delivers `ctx` to the handler, which then runs all probes synchronously before returning.

```
ContentView → runAllProbes()
  → actorRef.call(StartProbeRequest)    [typed RPC via Inproc]
    → ProbeLifecycleAdapter.dispatch()  [WorkloadLifecycleBridge]
      → ProbeServiceWorkload.__dispatch()
        → ProbeHandlerImpl.startProbe(req:ctx:)
          → ctx.discover("<branch-specific DuplexStreamService>")
          → branch-specific verification
            → discovery-only result             [hw-actrix-unknown-service]
            → DataStreamProbeRunner.runAll()    [dev/test]
              → ctx.callRaw(StartDuplexStream)  [WebRTC RPC]
              → ctx.registerStream(s2c, callback)
              → ctx.sendDataStream(c2s, chunks)
              → ctx.callRaw(FinishDuplexStream)
              → ctx.unregisterStream(s2c)
```

### Why Synchronous Execution?

`ContextBridge` is only valid during the RPC handler's lifetime. Running probes in `Task.detached` after the handler returns causes the context to become invalid. All probes run synchronously inside `startProbe(req:ctx:)` and return results when complete.

### MetadataEntry Type

`MetadataEntry` is not re-exported from the `Actr` module. Use type inference via `.init(key:value:)` in `DataStream` initializer context — never use the type name explicitly.

## Known Limitation

The branch-specific remote DuplexStreamService must be running and registered in its realm. On `hw-actrix-unknown-service`, discovery itself is the whole test: a discovered target is success, and no route candidates means the target was not found.
