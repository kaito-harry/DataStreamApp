# DataStreamApp

iOS SwiftUI probe client for `demo2:DuplexStreamService:1.0.0`.

## Conventional Commits

All commit messages MUST follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: <description>    # new feature
fix: <description>     # bug fix
chore: <description>   # maintenance
docs: <description>    # documentation
```

## Project Conventions

- Deployment target: iOS 18.0+
- Swift 6 strict concurrency
- Target arch: arm64 simulator only (ActrFFI.xcframework restriction)
- Linked mode (`ActrNode.linked`), not packaged mode
- All code comments and documentation in English
- External communication (PRs, issues, chat) in 简体中文

## Key Architecture Decisions

1. **ProbeService for ContextBridge**: Pure clients need `ctx` for outbound operations. `ContextBridge` is only available inside RPC handlers, so a local `ProbeService.StartProbe` RPC delivers it.

2. **Synchronous probes**: `ContextBridge` is only valid during the handler's lifetime. Probes run synchronously inside `startProbe(req:ctx:)` — not in `Task.detached`.

3. **MetadataEntry type**: Not re-exported from `Actr`. Use `.init(key:value:)` in `DataStream` initializer context — never use the type name explicitly.

4. **Generated code fixes**: After `protoc` generation, remove all `public` modifiers from `probe.actor.swift` and `duplex_stream.client.swift`. Fix `ActrError.WorkloadError` → `ActrError.UnknownRoute`.

## File Map

| File | Role |
|------|------|
| `ActrService.swift` | Node lifecycle + `ProbeHandlerImpl` (ctx delivery + probe orchestration) + ACL second-node probe |
| `DataStreamProbeRunner.swift` | 8 probe implementations with `withSession` pattern |
| `SessionAckCollector.swift` | `DataStreamCallback` actor for per-session ack collection |
| `ContentView.swift` | SwiftUI: status, Run All button, result list, scrollable log |
| `duplex_stream.proto` | Remote service contract (match `demo2_duplex_stream_service/protos/`) |
| `probe.proto` | Local service for ctx delivery |

## Environment

| Key | Value |
|-----|-------|
| Realm | 33554433 |
| Signaling | `ws://124.71.231.251:9080/signaling/ws` |
| AIS | `http://124.71.231.251:9080/ais` |
| Target service | `demo2:DuplexStreamService:1.0.0` |
| Client identity | `demo2:DuplexStreamProbeClient:1.0.0` |
| Unauthorized (ACL test) | `demo2:UnauthorizedStreamProbeClient:1.0.0` |

## Reference Doc

[STREAM_CAPABILITY_VERIFICATION.zh.md](http://10.30.2.226:6419/4c71bac9/STREAM_CAPABILITY_VERIFICATION.zh.md)
