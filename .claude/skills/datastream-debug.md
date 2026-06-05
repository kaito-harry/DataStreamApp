---
name: datastream-debug
description: Debug DataStreamApp, check remote actrix server logs, verify service registration, diagnose WebRTC connectivity issues. Use when probes fail, service discovery returns nothing, or WebRTC connection issues arise.
---

# DataStreamApp Debug Skill

Debug and diagnostic procedures for DataStreamApp and the remote actrix server.

## Environment

| Item | Value |
|------|-------|
| Remote server | `124.71.231.251` |
| Actrix path | `/opt/actr-project/actrix` |
| Service logs | `/opt/actr-project/demo2_home/hyper/duplex-stream-service/logs/` |
| Realm ID | 33554433 |
| AIS | `http://124.71.231.251:9080/ais` |
| Signaling WS | `ws://124.71.231.251:9080/signaling/ws` |

## Remote Server Access

### Health Check

```bash
curl -s http://124.71.231.251:9080/health | python3 -m json.tool
```

All services should show `"healthy"`: `admin`, `ais`, `control`, `daemon`, `signaling`, `signer`, `stun`, `turn`.

### Check Registered Actors (actr CLI)

```bash
cd /Users/kaito/Project/Actrium/actr

# Standalone discover (requires local build with --endpoint support):
./target/release/actr registry discover \
  --list-only \
  --endpoint http://124.71.231.251:9080/ais \
  --realm-id 33554433 \
  --realm-secret "rs_CA1ueOmjzSmmd8UCgJeefGoCYWPkj8Oh"
```

### List Realm Actors (SSH)

```bash
ssh root@124.71.231.251 "ls /opt/actr-project/demo2_home/hyper/"
ssh root@124.71.231.251 "cat /opt/actr-project/actrix/config.toml | head -30"
```

### Check DuplexStreamService Logs

```bash
ssh root@124.71.231.251 "tail -100 /opt/actr-project/demo2_home/hyper/duplex-stream-service/logs/actr-*.log"
```

### Check DuplexStreamService Status

```bash
ssh root@124.71.231.251 "cd /opt/actr-project && cat demo2_home/hyper/duplex-stream-service/runtime.toml"
```

### Check Actrix Logs

```bash
ssh root@124.71.231.251 "tail -100 /opt/actr-project/actrix/logs/actrix.log"
```

### Restart DuplexStreamService

```bash
ssh root@124.71.231.251 "cd /opt/actr-project/demo2_duplex_stream_service && ./run_service.sh"
```

## Local Debug

### Build & Launch DataStreamApp

```bash
cd /Users/kaito/Project/Actrium/DataStreamApp

# Build
xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination 'platform=iOS Simulator,id=70A270E7-E950-4285-B8F9-D616DAB07E89' build

# Install + Launch with auto-run
APP=$(find ~/Library/Developer/Xcode/DerivedData/DataStreamApp-*/Build/Products/Debug-iphonesimulator -name 'DataStreamApp.app' -d | head -1)
DEV="70A270E7-E950-4285-B8F9-D616DAB07E89"

xcrun simctl terminate "$DEV" com.actrium.DataStreamApp 2>/dev/null
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 xcrun simctl launch --console "$DEV" com.actrium.DataStreamApp
```

### Filter Console Output

```bash
# Show only DataStreamApp NSLog output:
... | grep "DataStreamApp\]"

# Show probe results:
... | grep -E "PASS|FAIL|Done:"

# Show WebRTC connection state:
... | grep -E "ice_|ICE|connected|Relayed"
```

## Diagnostic Flow

When probes fail, follow this order:

### 1. Is the remote server healthy?

```bash
curl -s http://124.71.231.251:9080/health
```

### 2. Is DuplexStreamService registered?

```bash
# Via actr CLI
./target/release/actr registry discover --list-only \
  --endpoint http://124.71.231.251:9080/ais \
  --realm-id 33554433 \
  --realm-secret "rs_CA1ueOmjzSmmd8UCgJeefGoCYWPkj8Oh"
```

Expected: should list `demo2:DuplexStreamService:1.0.0`.

### 3. Is the service actually running?

```bash
ssh root@124.71.231.251 "ls /opt/actr-project/demo2_home/hyper/duplex-stream-service/logs/"
ssh root@124.71.231.251 "tail -50 /opt/actr-project/demo2_home/hyper/duplex-stream-service/logs/actr-*.log"
```

Look for `ActrNode started successfully` and recent activity.

### 4. Can our client discover it?

```bash
# Launch DataStreamApp and check console:
grep "Discovered\|discover" /tmp/dsa_run.log
```

Should show `Discovered target: demo2:DuplexStreamService:1.0.0`.

### 5. Is WebRTC connecting?

```bash
grep -E "ICE|connected|Relayed" /tmp/dsa_run.log
```

Should show:
- `ICE Connection State Changed: Connected`
- `webrtc connected peer=...`

If ICE stays at `Connecting` or `Gathering`, check:
- STUN/TURN server availability
- TURN credential configuration
- `force_relay` setting in `actr.toml`

### 6. Is the RPC being sent and responded to?

```bash
grep -E "call_raw|StartDuplexStream|ready=" /tmp/dsa_run.log
```

A successful flow shows:
1. `RpcReliable (XXX bytes)` — request sent
2. `StartDuplexStream ready=true` — response received

If the request is sent but no response arrives within timeout, the service may be unresponsive.

## Common Issues

### "No route candidates for type"
→ Service not registered on signaling. Check step 2-3 above.

### "Request timeout: XXXXXms"
→ WebRTC connected but service doesn't respond. Check service logs (step 3).

### "Failed to allocate on turn.Client"
→ TURN server unavailable. Remove `turn_urls` from `actr.toml`:
```toml
[webrtc]
	stun_urls = ["stun:124.71.231.251:3478"]
turn_urls = []
```

### "429 Too Many Requests" from actr CLI
→ Rate limited by AIS. Wait 60 seconds and retry.

### "Realm X not found (403)"
→ Realm doesn't exist on this server. Only realm 33554433 is configured.

### Build fails with "MetadataEntry not in scope"
→ Use `.init(key:value:)` inline in `DataStream` initializer. Never use `MetadataEntry` as an explicit type.
