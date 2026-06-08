---
name: datastream-dev-debug
description: Debug DataStreamApp in dev environment (192.168.212.112:8080), check actrix server, verify service registration, diagnose WebRTC connectivity. Use when probes fail, service discovery returns nothing, or WebRTC connection issues arise.
---

# DataStreamApp Dev Environment Debug

DataStreamApp 连接内网开发 actrix 服务器 `192.168.212.112:8080`，DuplexStreamService 也部署在同一台机器上，可完全管理。

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
- **`simctl launch` env var not passed** → Use `SIMCTL_CHILD_` prefix.
