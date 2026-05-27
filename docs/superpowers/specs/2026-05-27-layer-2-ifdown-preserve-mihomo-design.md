# Layer 2 — preserve mihomo across GL framework ifdown when intent is still ON

**Date**: 2026-05-27
**Status**: Approved
**Scope**: `provision-mudi.sh` — `99-vpn-mode` hook (ifdown branch + ifup table 1001 idempotency check)
**Builds on**: `2026-05-27-decouple-mihomo-from-wg-link-design.md`

## Problem

On-device validation revealed that the previous Layer 1 fix (Task 4: demote WG-stale in health
check) only addresses ONE source of mihomo-killing during WG flaps. The dominant source on
this GL.iNet Mudi 7 is:

```
WG REKEY-GIVEUP (wireguard kernel, ~90s of no handshake response)
  → GL wgclient proto handler tears down the interface
    → hotplug iface ifdown event fires for INTERFACE=wgclient1
      → /etc/hotplug.d/iface/99-vpn-mode ifdown branch runs
        → /etc/init.d/mihomo stop + pkill mihomo
        → dnsmasq reverted to direct DNS
```

Then within 30–60 seconds, GL retries and fires ifup, which restarts mihomo + reconverges
everything. The cycle repeats whenever the WG handshake reply doesn't reach the Mudi (NAT
mapping aging, transient packet loss, etc.).

User-visible effect: continuous "VPN flapping" — brief outages every couple of minutes even
though the user toggled VPN ON in the GL Web UI and mihomo's actual upstream (VLESS over
TCP/443 direct to the VPS) is unaffected by WG state.

The user's original intent ("ws vpn off, mihomo 才关") was: **only an explicit user-driven
OFF toggle should stop mihomo**. The current ifdown hook treats every WG-link teardown as
intent-OFF, which is wrong.

## Goals

- ifdown hook distinguishes "user explicitly turned VPN OFF" from "GL framework tore down
  WG due to handshake/flap". The former still stops mihomo; the latter preserves it.
- When mihomo is preserved across a flap and the next ifup fires, the convergence steps
  re-add any state that was lost (e.g., the VPS_LAN route via wgclient1 that the kernel
  auto-removes when wgclient1 disappears).
- The ip rule (LAN → table 1001), dnsmasq config, and mihomo itself are NOT touched on a
  flap-ifdown — so LAN clients see no DNS gap and no proxy interruption.

## Non-goals

- No GL framework patching, no netifd handler changes, no WG endpoint diagnostics.
- No new daemon, watcher, or cron entry.
- No new fields in `/etc/mudi-vpn.conf`.
- We do not try to fix the underlying WG handshake instability (the root cause is a network
  problem — NAT mapping, peer reachability — outside the scope of this script).

## Design

### Change 1: ifdown intent guard

The `ifdown)` branch of the `99-vpn-mode` hook gains an early-exit when the user's intent
is still ON (`wireguard.global.global_proxy=1`). The teardown logic only runs when intent
is OFF (or unset).

```sh
ifdown)
    GLOBAL=$(uci -q get wireguard.global.global_proxy 2>/dev/null)
    if [ "$GLOBAL" = "1" ]; then
        logger -t vpn-mode "WG $INTERFACE down but intent=ON (WG flap) — preserving mihomo state"
        exit 0
    fi
    logger -t vpn-mode "WG $INTERFACE down (intent=OFF) — stopping mihomo"
    /etc/init.d/mihomo stop 2>/dev/null
    pkill -9 mihomo 2>/dev/null
    # Cleanup: remove whatever LAN→1001 rule is currently at our pref.
    OLD_LAN=$(ip rule show | awk -v pref="$LAN_RULE_PREF" '$1 == pref":" && $2 == "from" {print $3}' | head -1)
    if [ -n "$OLD_LAN" ]; then
        ip rule del from "$OLD_LAN" lookup 1001 pref "$LAN_RULE_PREF" 2>/dev/null
    fi
    uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
    uci -q delete dhcp.@dnsmasq[0].strictorder 2>/dev/null
    uci -q delete dhcp.@dnsmasq[0].strict_order 2>/dev/null  # legacy key cleanup
    uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
    uci add_list dhcp.@dnsmasq[0].server="119.29.29.29"
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    logger -t vpn-mode "OK: pure direct mode"
    ;;
```

**Rationale on what stays in place during a flap**:
- mihomo: alive, utun device persists
- table 1001 `default via $TUN_GW dev $TUN_DEV`: persists (utun is owned by mihomo, not wgclient1)
- table 1001 `$VPS_LAN dev $INTERFACE` (wgclient1): removed by kernel automatically when wgclient1 vanishes — handled in Change 2 below
- ip rule LAN → 1001: persists
- dnsmasq config: pointed at mihomo, persists
- LAN client experience: zero DNS gap, zero proxy interruption

### Change 2: ifup table 1001 idempotency check expansion

Currently the ifup hook's table 1001 guard (Task 2) only checks whether the **default**
route matches the desired value. After a flap-ifdown that preserved state, the
`$VPS_LAN dev $INTERFACE` route is missing (kernel auto-removed it when wgclient1
disappeared), but the default route is still correct — so the guard skips the rebuild
and the VPS_LAN route stays missing indefinitely.

Expand the guard to also verify the VPS_LAN route exists:

```sh
WANT_DEFAULT="default via $TUN_GW dev $TUN_DEV"
CUR_DEFAULT=$(ip route show table 1001 2>/dev/null | grep "^default" || true)
HAS_VPS_LAN=$(ip route show table 1001 2>/dev/null | grep -c "^$VPS_LAN ")
if [ "$CUR_DEFAULT" != "$WANT_DEFAULT" ] || [ "$HAS_VPS_LAN" = "0" ]; then
    ip route flush table 1001 2>/dev/null
    ip route add "$VPS_LAN" dev "$INTERFACE" table 1001 2>/dev/null
    ip route add default via "$TUN_GW" dev "$TUN_DEV" table 1001 || {
        logger -t vpn-mode "ERROR: failed to add default via $TUN_GW dev $TUN_DEV"
        exit 1
    }
else
    logger -t vpn-mode "table 1001 default+VPS_LAN already correct, skipping rebuild"
fi
```

Trade-off: the skip-log message is slightly longer to reflect the broader check. The
rebuild path is unchanged.

## Validation

1. **Real flap scenario (the target)**
   - VPN ON via GL Web UI, wait for WG to handshake then flap
   - Observe `logread`: should see `vpn-mode: WG wgclient1 down but intent=ON (WG flap) — preserving mihomo state`
   - `pidof mihomo` returns the same PID across multiple flap cycles
   - LAN client browsing continues without interruption

2. **User OFF toggle still works**
   - With VPN ON and mihomo running, set `wireguard.global.global_proxy=0` via GL Web UI
     (or simulate: `uci set wireguard.global.global_proxy=0; uci commit wireguard`)
   - Trigger ifdown: `INTERFACE=wgclient1 ACTION=ifdown /etc/hotplug.d/iface/99-vpn-mode`
   - Observe `logread`: `vpn-mode: WG wgclient1 down (intent=OFF) — stopping mihomo` followed by `OK: pure direct mode`
   - `pidof mihomo` empty, dnsmasq reverted to direct DNS
   - Restore `global_proxy=1` after test

3. **VPS_LAN route recovery after flap**
   - With mihomo running and VPN ON, manually remove the VPS_LAN route:
     `ip route del 10.20.0.0/24 dev wgclient1 table 1001`
   - Trigger ifup: `INTERFACE=wgclient1 ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode`
   - Observe `logread`: should NOT see the skip log; should see normal rebuild path
   - `ip route show table 1001` shows both default via utun AND 10.20.0.0/24 via wgclient1

4. **Idempotency still works when everything is correct**
   - With both routes correct, manually trigger ifup
   - Observe `logread`: `table 1001 default+VPS_LAN already correct, skipping rebuild`

## Risk

- **mihomo zombies during persistent WG outage**: if WG never comes back (e.g., VPS WG
  permanently broken) but user keeps intent=ON, mihomo stays running forever using the
  VLESS path. This is actually the desired behavior per the user's stated intent.
- **Wedged state**: if `wireguard.global.global_proxy` UCI is in some bizarre state
  (e.g., key deleted entirely), the `$GLOBAL` variable is empty → `[ "$GLOBAL" = "1" ]`
  is false → falls through to the OFF branch. That's correct (no UCI key = no intent ON).
- **Concurrent ifdown then ifup race**: if GL fires ifdown then immediately ifup, both
  hook invocations may run concurrently. The ifdown intent-ON path exits in <100ms, so
  the race window is tiny. Existing ifup idempotency handles re-entry correctly.
