---
name: datastream-dev-debug
description: Debug DataStreamApp in dev environment (192.168.212.112:8080), check actrix server, verify service registration, diagnose WebRTC connectivity. Use when probes fail, service discovery returns nothing, or WebRTC connection issues arise.
---

# DataStreamApp Dev Environment Debug

DataStreamApp `dev` 分支连接内网 zq actrix 服务器 `192.168.212.112:8080`，并访问同机的 `datastream-service`。

`test` 分支连接 hw actrix 服务器 `124.71.231.251:9080`，但目标服务部署在 zq 的 `datastream-service-hw` 目录。

## Environment

| Item | Value |
|------|-------|
| Environment | **dev** |
| Git Branch | `dev` |
| Actrix IP | `192.168.212.112` |
| Actrix Port | `8080` |
| Realm ID | `1001` |
| Realm Secret | `rs_TI1u7FdVIrp1giKCd580-Ap42mE7-kmx` |
| Target ActrType | `actrium:DuplexStreamService:0.1.0` |
| Client ActrType | `actrium:DuplexStreamProbeClient:1.0.0` |
| DuplexStreamService Access | ✅ 完全可控 |

## Branch Matrix

| Item | dev | test |
|------|-----|------|
| Git branch | `dev` | `test` |
| Flow | iOS app -> zq actrix -> zq `datastream-service` | iOS app -> hw actrix -> zq `datastream-service-hw` |
| Actrix | `192.168.212.112:8080` | `124.71.231.251:9080` |
| Realm ID | `1001` | `33554433` |
| Target ActrType | `actrium:DuplexStreamService:0.1.0` | `demo2:DuplexStreamService:1.0.0` |
| Client ActrType | `actrium:DuplexStreamProbeClient:1.0.0` | `demo2:DuplexStreamProbeClient:1.0.0` |
| Service home | `/home/actrium/datastream-service` | `/home/actrium/datastream-service-hw` |
| Registry DB | zq `/opt/actrix/database/signaling_cache.db` | hw `/opt/actr-project/actrix/database/signaling_cache.db` |

| Service | URL |
|---------|-----|
| Health | `http://192.168.212.112:8080/health` |
| AIS | `http://192.168.212.112:8080/ais` |
| Signaling WS | `ws://192.168.212.112:8080/signaling/ws` |
| Admin UI | `http://192.168.212.112:8080/admin` (password: `719b0e78658ea2b2`) |
| STUN | `stun:192.168.212.112:3478` |
| TURN | `turn:192.168.212.112:3478` |

## DuplexStreamService Deployment

```
/home/actrium/datastream-service/        ← 外层：actr.toml + keys
└── datastream-workload/                       ← 内层：git clone workload 项目
```

```bash
# 1. Update git repo
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service/datastream-workload && git pull'"

# 2. Build cdylib
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service/datastream-workload && cargo build --release --features cdylib'"

# 3. Package as .actr
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service/datastream-workload && /home/actrium/actr/target/release/actr build -m manifest.toml -t x86_64-unknown-linux-gnu --no-compile -k /home/actrium/echo-service/mfr.keychain.json'"

# 4. Stop old, start new
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr stop <WID>'"
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service && /home/actrium/actr/target/release/actr run -c actr.toml -d'"

# 5. Verify
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"
```

## DuplexStreamService Deployment (test target on zq)

`datastream-service-hw` must be a sibling of `datastream-service`:

```
/home/actrium/datastream-service-hw/
└── datastream-workload/
```

Build and start the test target:

```bash
ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw/datastream-workload && cargo build --release --features cdylib'"

ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw/datastream-workload && /home/actrium/actr/target/release/actr build -m manifest-cdylib.toml -t x86_64-unknown-linux-gnu --no-compile -k /home/actrium/datastream-service-hw/mfr.keychain.json'"

ssh root@192.168.212.112 "su - actrium -c 'cd /home/actrium/datastream-service-hw && /home/actrium/actr/target/release/actr run -c actr.toml -d'"
```

Verify locally on zq and remotely in hw registry:

```bash
ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"

ssh root@124.71.231.251 "sqlite3 /opt/actr-project/actrix/database/signaling_cache.db \
  \"SELECT actor_manufacturer || ':' || actor_device_name as actor, service_name, actor_realm_id, status, datetime(last_heartbeat_at, 'unixepoch') \
   FROM service_registry ORDER BY last_heartbeat_at DESC LIMIT 10;\""
```

## Local Debug

**Fixed device:** iPhone 17 Pro Max `51864B3D-EC7A-4853-B124-4370B9E43617`

```bash
cd /Users/kaito/Project/Actrium/DataStreamApp
DEV="51864B3D-EC7A-4853-B124-4370B9E43617"

xcrun simctl boot "$DEV" 2>/dev/null

xcodebuild -project DataStreamApp.xcodeproj -scheme DataStreamApp \
  -destination "platform=iOS Simulator,id=$DEV" build

APP=$(find ~/Library/Developer/Xcode/DerivedData/DataStreamApp-*/Build/Products/Debug-iphonesimulator -name 'DataStreamApp.app' -d | head -1)
xcrun simctl terminate "$DEV" com.actrium.DataStreamApp 2>/dev/null
xcrun simctl install "$DEV" "$APP"
SIMCTL_CHILD_ACTR_DATASTREAMAPP_AUTO_RUN=1 xcrun simctl launch --console "$DEV" com.actrium.DataStreamApp
```

### Filter Output

```bash
... | grep "DataStreamApp\]"       # NSLog output
... | grep -E "PASS|FAIL|Done:"    # probe results
... | grep -E "ice_|ICE|connected" # WebRTC state
```

## Diagnostic Flow

1. **Health**: `curl -s http://192.168.212.112:8080/health`
2. **Service registered?**: `actr registry discover --endpoint http://192.168.212.112:8080/ais --realm-id 1001 --realm-secret "rs_TI1u7FdVIrp1giKCd580-Ap42mE7-kmx"`
3. **Service running?**: `ssh root@192.168.212.112 "su - actrium -c '/home/actrium/actr/target/release/actr ps'"`
4. **Discovery?**: `grep "Discovered" /tmp/dsa_verify.log` → `actrium:DuplexStreamService:0.1.0`
5. **WebRTC?**: `grep -E "ICE|connected" /tmp/dsa_verify.log`

## Common Issues

- **"No route candidates"** → Service not registered. Check step 2-3.
- **"Connection factory returned no connections"** → ICE closed. Service not answering. Check step 3.
- **"Failed to allocate on turn.Client"** → TURN down. Remove `turn_urls` or fix TURN.
- **"AIS rejected"** → Signing key issue. Rebuild with correct `-k keychain.json`.
- **"AIS rejected registration: MFR lookup failed: not found"** → The package manufacturer and signing key are not registered together in hw actrix. For `datastream-service-hw`, the package is `demo2:DuplexStreamService:1.0.0` but may be signed with the zq `actrium` key (`mfr-3f1749919c8db6ec`). Either sign with a registered `demo2` key or add that signing key as a non-revoked historical key for `demo2` in hw actrix `mfr_key_history`.
- **`simctl launch` env var not passed** → Use `SIMCTL_CHILD_` prefix.
