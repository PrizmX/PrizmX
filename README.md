# PrizmX

Open-core **macOS** proxy client. It reads Clash YAML / sing-box style configs, runs a sandboxed host app plus a Packet Tunnel **system extension**, and can take over traffic with FakeIP TUN and/or System Proxy (mixed-port HTTP CONNECT + SOCKS5).

This repository is the **community Mac app** (`app.prizmx.macos`). It is not the Mac App Store / Pro product (`app.prizmx`).

## Features

- Menu bar extra and a Home console (widgets, profiles, policies, rules)
- TUN: FakeIP `198.18.0.0/16` via `app.prizmx.macos.packet-tunnel`
- System Proxy on mixed-port `7890`; optional Allow LAN
- Inspector: live / recent flows (not HTTP MITM)
- Day / month traffic, ranking, path latency (internet / DNS / proxy)

HTTP capture, decrypt, and rewrite are **out of scope** for open-core. Those belong in PrizmX-Premium / PrizmX-Pro.

## Layout

The Xcode project expects these checkouts as **siblings**:

```
PrizmX/                 this repo
PrizmX-Foundation/
PrizmX-Kit/
SwiftTCP/
```

| Path | Role |
| --- | --- |
| `PrizmX/` | Host app |
| `PacketTunnel/` | System extension |
| `scripts/build_mac_dmg.sh` | Signed + notarized DMG |

## Develop

Requirements: recent Xcode, macOS 14+.

1. Clone the four repos next to each other.
2. Open `PrizmX.xcodeproj`, scheme **PrizmX**.
3. Run. The Debug scheme **installs to `/Applications/PrizmX.app`** and launches that copy. System extensions cannot load from DerivedData.
4. Enable **PrizmX Tunnel** in System Settings → General → Login Items & Extensions → Network Extensions.

Debug and a DMG install share the same bundle IDs. Do not Run from Xcode and use a notarized copy at the same time — they overwrite `/Applications` and replace the system extension.

## Release

Push a tag `vX.Y.Z`. GitHub Actions (`.github/workflows/release-macos.yml`) archives, signs, notarizes, and attaches a DMG to the GitHub Release.

Locally, export the variables documented in `scripts/build_mac_dmg.sh` (or a gitignored `scripts/dmg.env`) and run:

```bash
./scripts/build_mac_dmg.sh 0.0.3
```

Sign **inside-out** (system extension, then host). Do not `codesign --deep`.

## Identifiers

| Use | Value |
| --- | --- |
| App | `app.prizmx.macos` |
| Tunnel | `app.prizmx.macos.packet-tunnel` |
| App Group | `N49M3Z72D3.group.app.prizmx` |

## License

[Apache License 2.0](LICENSE)
