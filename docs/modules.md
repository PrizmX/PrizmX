# PrizmX Modules Guide

PrizmX Modules are toggleable, non-destructive configuration overlays compatible with **Surge `.sgmodule`** (INI) and **Stash `.stoverride`** (YAML) formats. Enabled modules layer cleanly on top of your active subscription without modifying the original profile file:

```text
Local ProfileOverlay (highest priority)
  → Enabled Modules (in list order; Move Up / Move Down to adjust)
    → Active Profile / Subscription
```

---

## Supported Sections (Community Open-Core)

| Section | Surge `.sgmodule` | Stash `.stoverride` | Notes |
| --- | --- | --- | --- |
| Metadata | `#!name`, `#!desc`, `#!category`, `#!author`, `#!homepage`, `#!arguments` | `name`, `desc`, `category`, `author`, `homepage` | `{{{arg}}}` placeholder substitution supported |
| Rules | `[Rule]` | `rules:` | Full Clash/Surge matcher syntax: `DOMAIN*`, `IP-CIDR(6)`, `GEOIP`, `GEOSITE`, `IP-ASN`, `DST-PORT` / `DEST-PORT`, `PROCESS-NAME`, `no-resolve`, `AND/OR/NOT`, `MATCH` |
| Hosts | `[Host]` | `hosts:` | Static IP / hostname overrides injected into DNS |
| DNS / FakeIP | `[General]` (`always-real-ip`, `skip-proxy`, `fake-ip-filter`) | `dns.fake-ip-filter` | Merged into FakeIP bypass list |
| Non-MITM Scripts | `[Script]` (`type=cron`, `type=event`) | — | Prefetched and scheduled automatically while module is enabled |
| MITM / Rewrite / HTTP Scripts | Skipped (reported in Inspect) | Skipped (reported in Inspect) | Reserved for PrizmX Pro |

---

## Example Surge `.sgmodule`

```ini
#!name=Dev & Privacy Helpers
#!desc=Blocks sample ad domains, maps local dev host, and runs a network-change check.
#!category=Utility
#!author=PrizmX Community
#!homepage=https://github.com/PrizmX
#!arguments=ad_policy:REJECT,dev_ip:127.0.0.1

[General]
always-real-ip = %APPEND% *.dev.internal

[Rule]
DOMAIN-SUFFIX,ads.example.com,{{{ad_policy}}}
IP-CIDR,198.51.100.0/24,DIRECT,no-resolve

[Host]
api.dev.internal = {{{dev_ip}}}

[Script]
net-check = type=event, event-name=network-changed, script-path=https://example.com/net-check.js, timeout=10
```

## Example Stash `.stoverride`

```yaml
name: Dev Rules Override
desc: Adds internal routing and FakeIP bypasses
category: Utility
rules:
  - DOMAIN-SUFFIX,internal.example.com,DIRECT
  - DST-PORT,8443,REJECT
hosts:
  db.internal: 10.0.0.50
dns:
  fake-ip-filter:
    - "*.internal.example.com"
```
