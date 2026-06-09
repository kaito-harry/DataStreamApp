---
name: datastream-test-debug
description: Debug DataStreamApp in test environment (124.71.231.251:9080), check remote actrix server logs, verify service registration, diagnose WebRTC connectivity. Use when probes fail, service discovery returns nothing, or WebRTC connection issues arise.
---

# DataStreamApp Test Debug Skill

Debug and diagnostic procedures for the `test` branch: Swift iOS app -> hw actrix -> zq `datastream-service-hw`.

## Environment

| Item | Value |
|------|-------|
| iOS Simulator | **iPhone 17 Pro Max** `51864B3D-EC7A-4853-B124-4370B9E43617` |
| hw actrix server | `124.71.231.251:9080` |
| zq service server | `192.168.212.112` |
| Actrix path | `/opt/actr-project/actrix` |
| Service home | `/home/actrium/datastream-service-hw` |
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

### Check Registered Actors (hw signaling cache)

```bash
ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \
  \"SELECT actor_manufacturer || ':' || actor_device_name as actor, service_name, actor_realm_id, status, datetime(last_heartbeat_at, 'unixepoch') \
   FROM service_registry ORDER BY last_heartbeat_at DESC LIMIT 10;\""
```

### Check DuplexStreamService Status on zq

```bash
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"
```

### Check DuplexStreamService Logs on zq

```bash
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr logs <WID>'"
```

### Check Actrix Logs

```bash
ssh root@124.71.231.251 "tail -100 /opt/actr-project/actrix/actrix.log"
```

### Restart DuplexStreamService on zq

```bash
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr stop <WID>'"
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw && /home/actrium/actr/target/release/actr run -c actr.toml -d'"
```

## Local Debug

### Build & Launch DataStreamApp

**Fixed device:** iPhone 17 Pro Max `51864B3D-EC7A-4853-B124-4370B9E43617`

```bash
cd /Users/kaito/Project/Actrium/DataStreamApp
DEV="51864B3D-EC7A-4853-B124-4370B9E43617"

# Ensure device is booted
xcrun simctl boot "$DEV" 2>/dev/null

# Build
xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination "platform=iOS Simulator,id=$DEV" build

# Install + Launch with auto-run
APP=$(find ~/Library/Developer/Xcode/DerivedData/DataStreamApp-*/Build/Products/Debug-iphonesimulator -name 'DataStreamApp.app' -d | head -1)
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

## Environments

| Key | dev | test |
|-----|-----|------|
| Git branch | `dev` | `test` |
| Actrix | `192.168.212.112:8080` | `124.71.231.251:9080` |
| Realm ID | 1001 | 33554433 |
| Target type | `actrium:DuplexStreamService:0.1.0` | `demo2:DuplexStreamService:1.0.0` |
| Client type | `actrium:DuplexStreamProbeClient:1.0.0` | `demo2:DuplexStreamProbeClient:1.0.0` |
| Service home | `/home/actrium/datastream-service` | `/home/actrium/datastream-service-hw` |
| Registry DB | zq `/opt/actrix/database/signaling_cache.db` | hw `/opt/actr-project/actrix/database/signaling_cache.db` |

## DataStreamService Deployment (dev)

Two-layer structure (参照 echo-service):
```
/home/actrium/datastream-service/        ← 外层：actr.toml + keys
└── datastream-workload/                       ← 内层：git clone workload 项目
```

```bash
# 1. Clone/update git repo (inner)
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service/datastream-workload && git pull'"

# 2. Build cdylib
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service/datastream-workload && cargo build --release --features cdylib'"

# 3. Package as .actr
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service/datastream-workload && /home/actrium/actr/target/release/actr build -m manifest.toml -t x86_64-unknown-linux-gnu --no-compile -k /home/actrium/echo-service/mfr.keychain.json'"

# 4. Stop old, start new (from outer dir where actr.toml lives)
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr stop <WID>'"
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service && /home/actrium/actr/target/release/actr run -c actr.toml -d'"

# 5. Verify
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"
```

## DataStreamService Deployment (test)

Two-layer structure on zq:

```
/home/actrium/datastream-service-hw/
└── datastream-workload/
```

```bash
# 1. Build cdylib
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw/datastream-workload && cargo build --release --features cdylib'"

# 2. Package as demo2 service
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw/datastream-workload && /home/actrium/actr/target/release/actr build -m manifest-cdylib.toml -t x86_64-unknown-linux-gnu --no-compile -k /home/actrium/datastream-service-hw/mfr.keychain.json'"

# 3. Start from outer dir where actr.toml lives
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw && /home/actrium/actr/target/release/actr run -c actr.toml -d'"

# 4. Verify zq runtime and hw registry
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"
ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \
  \"SELECT actor_manufacturer || ':' || actor_device_name as actor, service_name, actor_realm_id, status, datetime(last_heartbeat_at, 'unixepoch') \
   FROM service_registry ORDER BY last_heartbeat_at DESC LIMIT 10;\""
```

## Diagnostic Flow

When probes fail, follow this order:

### 1. Is the target server healthy?

```bash
# dev
curl -s http://192.168.212.112:8080/health
# test
curl -s http://124.71.231.251:9080/health
```

### 2. Is DuplexStreamService registered?

```bash
# dev
cd /Users/kaito/Project/Actrium/actr
./target/release/actr registry discover --list-only \
  --endpoint http://192.168.212.112:8080/ais \
  --realm-id 1001 \
  --realm-secret "rs_TI1u7FdVIrp1giKCd580-Ap42mE7-kmx"

# test
./target/release/actr registry discover --list-only \
  --endpoint http://124.71.231.251:9080/ais \
  --realm-id 33554433 \
  --realm-secret "rs_CA1ueOmjzSmmd8UCgJeefGoCYWPkj8Oh"
```

Expected: should list the target service.

### 3. Is the service running?

```bash
# dev
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"
ssh root@192.168.212.112 "tail -50 /home/actrium/.actr/hyper/logs/actr-*.log"

# test
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"
```

### 4. Can our client discover it?

```bash
grep "Discovered\|discover" /tmp/dsa_verify.log
```

Should show: `Discovered target: actrium:DuplexStreamService:0.1.0` (dev) or `demo2:DuplexStreamService:1.0.0` (test).

### 5. Is WebRTC connecting?

```bash
grep -E "ICE|connected|Relayed" /tmp/dsa_verify.log
```

Should show:
- `ICE Gathering State Changed: Complete`
- `peer connection state changed: connected`

### 6. Is the RPC being sent and responded to?

```bash
grep -E "RpcReliable|Start:|status=" /tmp/dsa_verify.log
```

A successful flow shows:
1. `RpcReliable (138 bytes)` — request sent
2. `Start: sid=... s2c=... status=ok` — response received

## Common Issues

### "No route candidates for type"
→ Service not registered on signaling. Check step 2-3.

If hw signaling cache shows `demo2:DuplexStreamService` as available but route candidates still return 0, inspect actrix logs:

```bash
ssh root@124.71.231.251 "grep -nE '从缓存恢复|Restored|RouteCandidates|未找到 demo2/DuplexStreamService|清理内存中的过期服务' /opt/actr-project/actrix/actrix.log | tail -120"
```

Known hw actrix behavior: restored `service_registry` rows do not preserve `ActrType.version`, while route candidate lookup requires exact `manufacturer + name + version`. Restart `datastream-service-hw` from zq so it performs a fresh full registration:

```bash
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr stop <WID>'"
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw && /home/actrium/actr/target/release/actr run -c actr.toml -d'"
```

### "Request timeout: XXXXXms"
→ WebRTC connected but service doesn't respond. Check service logs.

### "empty service_to_client_stream_id" (probe 1)
→ Proto mismatch: client expects `status` field but service returns `ready` bool. Align proto files.

### "Configuration error: Connection factory returned no connections"
→ WebRTC ICE completed then closed — service not sending SDP answer. Check service is running.

### "Failed to allocate on turn.Client"
→ TURN server unavailable. Remove `turn_urls` from `actr.toml` or fix TURN service.

### "AIS rejected registration: MFR lookup failed"
→ The package manufacturer and signing key are not registered together in hw actrix. For `datastream-service-hw`, the package is `demo2:DuplexStreamService:1.0.0` but may be signed with the zq `actrium` key (`mfr-3f1749919c8db6ec`). Either sign with a registered `demo2` key or add that signing key as a non-revoked historical key for `demo2` in hw actrix `mfr_key_history`.

### "missing symbol 'actr_init'" (cdylib)
→ Built without cdylib feature. Add `[features] cdylib = ["actr-framework/cdylib"]` and use `--features cdylib`.

### "429 Too Many Requests" from actr CLI
→ AIS rate limited. Wait 60 seconds.

### "Realm X not found (403)"
→ Realm doesn't exist on this server.

### Build fails with "MetadataEntry not in scope"
→ Use `.init(key:value:)` inline in `DataStream` initializer. Never use `MetadataEntry` as explicit type.

### Swift 6: "passing closure as 'sending' parameter risks data races"
→ Don't use `defer { Task {} }`. Call `teardown()` explicitly before `return`.

### `simctl launch` env var not passed
→ Must use `SIMCTL_CHILD_` prefix: `SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 xcrun simctl launch ...`
