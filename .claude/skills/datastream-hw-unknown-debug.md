---
name: datastream-hw-unknown-debug
description: Debug the hw-actrix-unknown-service branch, where DataStreamApp uses hw actrix and treats target discovery as the whole test because the datastream-service host is unknown.
---

# DataStreamApp HW Unknown Service Debug Skill

Debug and diagnostic procedures for `hw-actrix-unknown-service`: Swift iOS app -> hw actrix -> unknown datastream service host.

## Environment

| Item | Value |
|------|-------|
| Git branch | `hw-actrix-unknown-service` |
| iOS Simulator | **iPhone 17 Pro Max** `51864B3D-EC7A-4853-B124-4370B9E43617` |
| Actrix | `124.71.231.251:9080` |
| Realm ID | `33554433` |
| Target type | `demo2:DuplexStreamService:1.0.0` |
| Client type | `demo2:DuplexStreamProbeClient:1.0.0` |
| Service home | Unknown |
| Success criteria | `ctx.discover` returns a target candidate |

## Health Check

```bash
curl -s http://124.71.231.251:9080/health | python3 -m json.tool
```

## Check Signaling Cache

```bash
ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \
  \"SELECT actor_manufacturer || ':' || actor_device_name as actor, service_name, actor_realm_id, status, datetime(last_heartbeat_at, 'unixepoch') \
   FROM service_registry WHERE actor_manufacturer='demo2' OR service_name LIKE '%DuplexStream%' \
   ORDER BY last_heartbeat_at DESC LIMIT 10;\""
```

## Run Discovery Test

```bash
cd /Users/kaito/Project/Actrium/DataStreamApp
DEV="51864B3D-EC7A-4853-B124-4370B9E43617"

xcodegen generate
xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination "platform=iOS Simulator,id=$DEV" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build

APP=$(find ~/Library/Developer/Xcode/DerivedData/DataStreamApp-*/Build/Products/Debug-iphonesimulator -name 'DataStreamApp.app' -type d | head -1)
xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl terminate "$DEV" com.actrium.DataStreamApp 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 xcrun simctl launch --console "$DEV" com.actrium.DataStreamApp
```

Expected success:

```text
[PASS] discover-target target=<actr-id>/demo2:DuplexStreamService:1.0.0
```

Expected failure when no peer is registered:

```text
[FAIL] discover-target target not found: demo2:DuplexStreamService:1.0.0
```

## Common Issue

### Target appears in cache but discovery fails

hw actrix may restore `service_registry` rows without preserving `ActrType.version`, while route lookup requires exact `manufacturer + name + version`. Ask the owner of the remote datastream service to restart it so it performs a fresh registration into hw actrix.
