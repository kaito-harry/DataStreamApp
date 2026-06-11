---
name: datastream-dev-debug
description: Debug DataStreamApp in dev/test environments. Use when probes fail, service discovery returns nothing, WebRTC connection issues arise, or when managing actr services on zq (192.168.212.112). Covers branch-specific configuration, service deployment, and actrix diagnostics.
---

# DataStreamApp Dev/Test Debug

## Key Principle: Use `actrium` user for zq

All SSH operations on zq (`192.168.212.112`) MUST use the `actrium` user directly:

```bash
ssh actrium@192.168.212.112 "<command>"
```

Do NOT use `ssh root@192.168.212.112 "su - actrium -c '...'"`.

For hw actrix (`124.71.231.251`), root access remains unchanged (read-only shared server).

## Environments

| Branch | Flow | Actrix | Realm |
|--------|------|--------|-------|
| `zq-actrix-zq-service` (was `dev`) | iOS → zq actrix → zq datastream-service | `192.168.212.112:8080` | `1001` |
| `hw-actrix-zq-service` (was `test`) | iOS → hw actrix → zq datastream-service-hw | `124.71.231.251:9080` | `33554433` |

## zq Machine (192.168.212.112)

```bash
SSH="ssh actrium@192.168.212.112"

# Check running services
$SSH "/home/actrium/actr/target/release/actr ps"
$SSH "ps aux | grep actr | grep -v grep"

# Check actrix
$SSH "curl -s http://192.168.212.112:8080/health"
$SSH "sqlite3 /home/actrium/actrix/database/signaling_cache.db \"SELECT service_name, datetime(last_heartbeat_at,'unixepoch') FROM service_registry ORDER BY last_heartbeat_at DESC LIMIT 10;\""

# Update actrix + restart (lto = "thin", ~3 min build)
$SSH "cd /home/actrium/actrix && git pull origin main && cargo build --release && sudo systemctl restart actrix"

# Start datastream-service (zq-actrix-zq-service branch)
$SSH "cd /home/actrium/datastream-service && RUST_LOG=info nohup /home/actrium/actr/target/release/actr run --config actr.toml > /tmp/ds-run.log 2>&1 &"

# Start with actr.bak (Jun 4, no sdp_exchange_id)
$SSH "cd /home/actrium/datastream-service && RUST_LOG=info nohup /home/actrium/actr/target/release/actr.bak run --config actr.toml > /tmp/ds-bak-run.log 2>&1 &"

# Check actrix (hw side, read-only)
ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \"SELECT service_name, datetime(last_heartbeat_at,'unixepoch') FROM service_registry ORDER BY last_heartbeat_at DESC LIMIT 10;\""
```

## DuplexStreamService Deployment

```
/home/actrium/datastream-service/
├── actr.toml
├── mfr.keychain.json
└── datastream-workload/       ← git repo
```

### Service Binary Selection

| Binary | Date | sdp_exchange_id | Use with |
|--------|------|-----------------|----------|
| `actr.bak` | Jun 4 | No | actr-swift v0.3.3 (no sdp_exchange_id) |
| `actr` | Jun 10 | Yes (check+generate) | actr-swift v0.3.4+ (has sdp_exchange_id) |

## sdp_exchange_id Protocol

Introduced by **zhanghongjun** in `3b91a500` (Jun 8). The field (`SessionDescription.sdp_exchange_id = 3` in proto) correlates WebRTC Offer/Answer pairs. Both sides must agree on whether to include it.

**actrix relay must be updated** to include this proto field when forwarding messages. Otherwise the field is silently dropped during deserialization/re-serialization.

## Local Simulator

```bash
DEV="51864B3D-EC7A-4853-B124-4370B9E43617"
xcrun simctl boot "$DEV" 2>/dev/null

cd /Users/kaito/Project/Actrium/DataStreamApp
xcodegen generate
xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination "platform=iOS Simulator,id=$DEV" build

APP=$(find ~/Library/Developer/Xcode/DerivedData/DataStreamApp-*/Build/Products/Debug-iphonesimulator -name 'DataStreamApp.app' -d | head -1)
xcrun simctl terminate "$DEV" com.actrium.DataStreamApp 2>/dev/null
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 xcrun simctl launch --console "$DEV" com.actrium.DataStreamApp
```

## SPM Cache Corruption

If you change `exactVersion` in `project.yml` but the client still reports the old Rust version:

1. Delete `DataStreamApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
2. Delete `~/Library/Caches/org.swift.swiftpm/repositories/actr-swift-package-sync-*`
3. Delete `~/Library/Developer/Xcode/DerivedData/DataStreamApp-*`
4. Re-run `xcodegen generate` + `xcodebuild`

Verify with: `grep 'Actr Rust version'` in the client log.
