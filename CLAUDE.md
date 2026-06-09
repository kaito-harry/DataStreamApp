# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

iOS SwiftUI probe client for branch-specific DuplexStreamService environments.

## Conventional Commits

All commit messages MUST follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: <description>    # new feature
fix: <description>     # bug fix
chore: <description>   # maintenance
docs: <description>    # documentation
```

## Project Conventions

- Deployment target: iOS 26.2+
- Swift 6 strict concurrency
- Target arch: arm64 simulator only (ActrFFI.xcframework restriction)
- Linked mode (`ActrNode.linked`), not packaged mode
- All code comments and documentation in English
- External communication (PRs, issues, chat) in 简体中文

## Build & Run

```bash
# Generate Xcode project
xcodegen generate

# Find arm64 simulator device
xcrun simctl list devices available | grep "iPhone.*18"

# Build (arm64 simulator only — ActrFFI.xcframework restriction)
xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination 'platform=iOS Simulator,id=<DEVICE_UDID>' build

# Manual run
xcrun simctl boot <UDID>
xcrun simctl install <UDID> DataStreamApp.app
xcrun simctl launch <UDID> com.actrium.DataStreamApp

# Auto-run (sets env var to trigger automatic probe execution)
SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 \
  xcrun simctl launch --console <UDID> com.actrium.DataStreamApp
```

## Code Generation

```bash
cd DataStreamApp

# Remote service: client stub (ProtoSource=Remote)
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

> After generation, remove all `public` modifiers from `probe.actor.swift` and `duplex_stream.client.swift` (incompatible with Swift 6 module rules). Fix `ActrError.WorkloadError` → `ActrError.UnknownRoute`. Committed versions already have these fixes.

## Key Architecture Decisions

1. **ProbeService for ContextBridge**: Pure clients need `ctx` for outbound operations. `ContextBridge` is only available inside RPC handlers, so a local `ProbeService.StartProbe` RPC delivers it.

2. **Synchronous probes**: `ContextBridge` is only valid during the handler's lifetime. Probes run synchronously inside `startProbe(req:ctx:)` — not in `Task.detached`.

3. **MetadataEntry type**: Not re-exported from `Actr`. Use `.init(key:value:)` in `DataStream` initializer context — never use the type name explicitly.

4. **Generated code fixes**: After `protoc` generation, remove all `public` modifiers from `probe.actor.swift` and `duplex_stream.client.swift`. Fix `ActrError.WorkloadError` → `ActrError.UnknownRoute`.

## File Map

| File | Role |
|------|------|
| `ActrService.swift` | Node lifecycle + `ProbeHandlerImpl` (ctx delivery + probe orchestration). **Real ACL probe (probe 8) lives here** — starts a second linked node with unauthorized identity. |
| `DataStreamProbeRunner.swift` | Probe implementations. **Only probes 1-2 are implemented** (reliable + latency-first). Probes 3-7 are placeholders returning `passed: false`, probe 8 is a placeholder returning `passed: true`. |
| `SessionAckCollector.swift` | `DataStreamCallback` actor for per-session ack collection with polling-based timeout |
| `ContentView.swift` | SwiftUI: status indicator, Run All button, result list, scrollable log. Auto-run via `ACTR_DATASTREAMAPP_AUTO_RUN=1` env var |
| `duplex_stream.proto` | Remote service contract (match `demo2_duplex_stream_service/protos/`) |
| `probe.proto` | Local service for ctx delivery |

## Environment

| Key | zq-actrix-zq-service branch | test branch | hw-actrix-unknown-service branch |
|-----|-------------------------------|-------------|---------------------------------|
| Flow | Swift iOS app -> zq actrix -> zq `datastream-service` | Swift iOS app -> hw actrix -> zq `datastream-service-hw` | Swift iOS app -> hw actrix -> any registered datastream service |
| Realm | `1001` | `33554433` | `33554433` |
| Signaling | `ws://192.168.212.112:8080/signaling/ws` | `ws://124.71.231.251:9080/signaling/ws` | `ws://124.71.231.251:9080/signaling/ws` |
| AIS | `http://192.168.212.112:8080/ais` | `http://124.71.231.251:9080/ais` | `http://124.71.231.251:9080/ais` |
| Target service | `actrium:DuplexStreamService:0.1.0` | `demo2:DuplexStreamService:1.0.0` | `demo2:DuplexStreamService:1.0.0` |
| Client identity | `actrium:DuplexStreamProbeClient:1.0.0` | `demo2:DuplexStreamProbeClient:1.0.0` | `demo2:DuplexStreamProbeClient:1.0.0` |
| Service home | `/home/actrium/datastream-service` | `/home/actrium/datastream-service-hw` | Unknown |
| Success criteria | 8 datastream probes pass | 8 datastream probes pass | Target discovery succeeds |

## Test Server (actrix)

| Key | Value |
|-----|-------|
| SSH | `ssh root@124.71.231.251` |
| Actrix binary | `/opt/actr-project/actrix/target/release/actrix` |
| Actrix source | `/opt/actr-project/actrix/` |
| Config | `/opt/actr-project/actrix/config_ssl.toml` |
| Database | `/opt/actr-project/actrix/database/actrix.db` |
| Signaling cache | `/opt/actr-project/actrix/database/signaling_cache.db` |

### Querying registered actors

```bash
# Active actors (with heartbeat)
ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \
  \"SELECT actor_manufacturer || ':' || actor_device_name as actor, service_name, \
   datetime(last_heartbeat_at, 'unixepoch') as last_hb, status \
   FROM service_registry ORDER BY last_heartbeat_at DESC;\""

# Count by type
ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \
  \"SELECT actor_manufacturer || ':' || actor_device_name, COUNT(*) \
   FROM service_registry GROUP BY 1;\""
```

### Admin API

```bash
# Login (password from config_ssl.toml [control.admin_ui])
TOKEN=$(curl -s -X POST http://124.71.231.251:9080/admin/api/auth/login \
  -H 'Content-Type: application/json' -d '{"password":"actrix2024"}' | jq -r '.token')

# Node info
curl -s http://124.71.231.251:9080/admin/api/node -H "Authorization: Bearer $TOKEN" | jq
```

> ⚠️ **CRITICAL: Read-only access only.** Never modify any code, config, or data on the test server (124.71.231.251). Only query, read, and inspect. This server is a shared test environment.

## zq Service Homes

`zq-actrix-zq-service` uses `/home/actrium/datastream-service`.
`test` uses `/home/actrium/datastream-service-hw`, which is deployed on zq but registers into hw actrix.
`hw-actrix-unknown-service` uses hw actrix only. The service host is intentionally unknown; discovery success is the test result.

## Reference Doc

[STREAM_CAPABILITY_VERIFICATION.zh.md](http://10.30.2.226:6419/4c71bac9/STREAM_CAPABILITY_VERIFICATION.zh.md)
