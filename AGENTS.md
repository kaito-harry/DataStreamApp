# AGENTS.md

This file provides guidance to AI agents when working with code in this repository.

## actr Version

- **Fixed version**: `0.3.6` (actr-swift-package-sync)
- **force_relay**: `false` (default, do not force TURN relay)
- **actrix role**: Provides signaling + STUN + TURN (all on port 3478/udp). App and service establish WebRTC through actrix, not directly.

## Simulator

- Fixed device: **iPhone 17 Pro Max**, iOS 26.2
- UDID resolved dynamically via `xcrun simctl list devices available`
