# Layer 3 — use `network.wgclient1.disabled` as intent signal (not `global_proxy`)

**Date**: 2026-05-28
**Status**: Approved
**Scope**: `provision-mudi.sh` — `99-vpn-mode` hook (ifup + ifdown intent guards) + `mudi-vpn-health.sh` (early-exit)
**Builds on**: `2026-05-27-layer-2-ifdown-preserve-mihomo-design.md`

## Problem

Post-Layer-2 on-device validation revealed the GL Web UI's "VPN" master toggle
flips `network.wgclient1.disabled`, not `wireguard.global.global_proxy`. Our
hook's intent guard checks `global_proxy`, so:

- User flips "VPN OFF" in GL UI → `disabled=1`, `global_proxy` stays at whatever it was
- netifd brings the WG interface down → fires hotplug ifdown
- Our hook sees `global_proxy=1` → "WG flap, preserve mihomo state"
- mihomo keeps running → user can still bypass GFW even though they thought VPN was off

That is the leak the user observed.

Separately: `wireguard.global.global_proxy` toggles Global Mode vs. Policy Mode
in GL's VPN UI, not VPN on/off. Our existing ifup code path skips mihomo setup
when `global_proxy != 1` (treats Policy Mode as "mihomo off"), but the user's
mental model is "WG interface enabled = mihomo on, period". Policy Mode (mihomo
selectively routing) was a hypothetical future feature and the user doesn't use
it.

## Goals

- mihomo lifecycle is governed by `network.${WG_IFACE}.disabled` only.
  `disabled=0` (WG interface enabled) means user wants proxy; `disabled=1`
  means user wants proxy off.
- WG link flaps (interface goes down without user disabling it) still preserve
  mihomo, same as Layer 2.
- The cron health check stops gating on `global_proxy`; only `disabled`
  determines whether it should act.
- No new daemon, watcher, or polling — the existing hotplug + 5-min cron is
  sufficient (netifd already responds to `disabled` UCI changes by firing the
  matching ifup/ifdown hotplug event).

## Non-goals

- Touching GL's VPN framework.
- Supporting Policy Mode (`global_proxy=0`, `disabled=0`). With this change,
  Policy Mode behaves identically to Global Mode — mihomo still runs. If the
  user later wants Policy Mode semantics back, that is a separate design.
- Fixing the AdGuardHome resurrection (GL re-enables AGH on boot, breaking
  Phase 1's `disable`). Out of scope; documented as known issue.
- Reacting to `global_proxy` UCI changes. We do not need to.

## Design

### Change 1: ifup — drop the `global_proxy` gate

Currently lines 467-472 of `provision-mudi.sh` short-circuit ifup when
`global_proxy != 1`. Remove the gate entirely. If ifup fires, the user has
WG enabled (`disabled=0`), and we should always set up mihomo.

Before:
```sh
case "$ACTION" in
    ifup)
        GLOBAL=$(uci -q get wireguard.global.global_proxy 2>/dev/null)
        if [ "$GLOBAL" != "1" ]; then
            logger -t vpn-mode "WG $INTERFACE up (Policy Mode) — mihomo stays off"
            exit 0
        fi
        logger -t vpn-mode "WG $INTERFACE up (Global Mode, LAN=$LAN_NET) — preparing mihomo"
```

After:
```sh
case "$ACTION" in
    ifup)
        logger -t vpn-mode "WG $INTERFACE up (LAN=$LAN_NET) — preparing mihomo"
```

### Change 2: ifdown — replace `global_proxy` intent guard with `disabled`

Currently lines 561-571 distinguish "GL flap" from "user pressed OFF" by
checking `global_proxy`. Switch to checking `disabled`: if the WG interface is
NOT disabled in UCI, the ifdown event is a network-layer flap (REKEY-GIVEUP,
etc.) and we should preserve mihomo. If `disabled=1`, the user genuinely turned
off the interface (via GL Web UI VPN toggle) and we should tear down.

Before:
```sh
ifdown)
    # Intent guard: GL's wgclient handler fires ifdown on WG REKEY-GIVEUP
    # (network-layer flap) as well as on user-driven VPN OFF toggles. Only
    # the latter should tear down mihomo. Distinguish by reading the user
    # intent UCI value — if it's still 1, this ifdown is a flap, not intent.
    GLOBAL=$(uci -q get wireguard.global.global_proxy 2>/dev/null)
    if [ "$GLOBAL" = "1" ]; then
        logger -t vpn-mode "WG $INTERFACE down but intent=ON (WG flap) — preserving mihomo state"
        exit 0
    fi
    logger -t vpn-mode "WG $INTERFACE down (intent=OFF) — stopping mihomo"
```

After:
```sh
ifdown)
    # Intent guard: GL's wgclient handler fires ifdown on WG REKEY-GIVEUP
    # (network-layer flap) as well as on user-driven VPN OFF toggles
    # (which set network.wgclient1.disabled=1). Distinguish by reading
    # the UCI disabled flag — if it is NOT 1, this ifdown is a flap and
    # mihomo should keep running.
    WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled" 2>/dev/null)
    if [ "$WG_DISABLED" != "1" ]; then
        logger -t vpn-mode "WG $INTERFACE down but interface enabled (WG flap) — preserving mihomo state"
        exit 0
    fi
    logger -t vpn-mode "WG $INTERFACE down (interface disabled) — stopping mihomo"
```

### Change 3: health check — drop `global_proxy` early-exit

Currently lines 608-611 early-exit when either `global_proxy != 1` OR
`disabled = 1`. The `global_proxy` check is now redundant — keep only the
`disabled` check.

Before:
```sh
GLOBAL=$(uci -q get wireguard.global.global_proxy)
WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled")
[ "$GLOBAL" != "1" ] && exit 0
[ "$WG_DISABLED" = "1" ] && exit 0
```

After:
```sh
WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled" 2>/dev/null)
[ "$WG_DISABLED" = "1" ] && exit 0
```

### Change 4: comments + Phase 8.5 header

Update header comments inside the hook (lines 6-13 in script preamble, lines
439-450 inside heredoc) and the Phase 8.5 outer comment (around line 597) to
reflect the new state machine. Two states only:

```
WG disabled  → mihomo NOT running, dnsmasq → direct DNS
WG enabled   → mihomo running, dnsmasq → mihomo, smart split routing
```

Policy Mode goes away from documentation.

## Validation

1. **Toggle VPN OFF via GL Web UI** (the original leak scenario)
   - With WG enabled, mihomo running, bypass working
   - Press "VPN OFF" in GL Web UI (sets `disabled=1` → fires ifdown)
   - Expected log: `WG wgclient1 down (interface disabled) — stopping mihomo`
   - Expected log: `OK: pure direct mode`
   - `pidof mihomo` empty
   - LAN client: GFW-blocked sites unreachable (no bypass)

2. **Toggle VPN ON via GL Web UI**
   - With `disabled=1`, mihomo not running
   - Press "VPN ON" in GL Web UI (sets `disabled=0` → fires ifup)
   - Expected log: `WG wgclient1 up (LAN=...) — preparing mihomo`
   - Expected: mihomo starts, table 1001 rebuilt, dnsmasq points at mihomo
   - LAN client: bypass works

3. **WG flap with interface still enabled** (the L2 scenario, unchanged)
   - Mihomo running, WG handshake fails → REKEY-GIVEUP → GL fires ifdown
   - `disabled` stays 0
   - Expected log: `WG wgclient1 down but interface enabled (WG flap) — preserving mihomo state`
   - mihomo PID unchanged across cycles

4. **Health check while WG disabled**
   - With `disabled=1`, manually run `/usr/local/bin/mudi-vpn-health.sh`
   - Expected: silent exit (no log, no action)

5. **Health check while WG enabled and mihomo dead**
   - With `disabled=0` and `pkill -9 mihomo`, run health
   - Expected: `DEGRADED: mihomo-dead ...` → re-trigger ifup → mihomo back

## Risk

- **`global_proxy` becomes a dead UCI key from our perspective**. If a future
  user actually wants Policy Mode (mihomo off but WG up for selective
  routing), this design doesn't support it. They would need to set
  `disabled=1` and use GL's policy framework — which gives them no proxy.
  Acceptable: the user explicitly does not use Policy Mode.
- **AdGuardHome remains a separate problem.** When mihomo is killed by
  intent-OFF teardown, AGH (still on port 53) will fail to upstream to 1053
  and fall back to its own DNS chain. As long as fallback returns real IPs,
  clients get real IPs, GFW blocks → desired behavior. If AGH's fallback ever
  returns something proxy-routed, that would be a leak; not addressed here.
