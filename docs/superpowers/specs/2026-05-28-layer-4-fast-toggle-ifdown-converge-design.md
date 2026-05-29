# Layer 4 — Fast toggle: converge mihomo on the ifdown flap event

**Date:** 2026-05-28
**Status:** Approved (design)
**Depends on:** Layer 1 (decouple mihomo from WG link state), Layer 2 (ifdown preserves mihomo when intent=ON), Layer 3 (`disabled` as sole intent signal)

## Problem

On a network where the WireGuard handshake never completes — confirmed on the
user's corporate WiFi uplink (`wlan4 → 10.84.6.0/23`, endpoint
`23.27.134.77:39753`, looping `REKEY-GIVEUP` every ~100s with `0 B received`) —
flipping the screen VPN switch to ON appears to do nothing. mihomo never starts,
so no LAN traffic is proxied and the user cannot reach blocked sites.

### Root cause

mihomo auto-start has exactly two triggers today, and on a WG-blocked network
**neither fires promptly**:

1. **Hotplug `ifup` of `wgclient1`** — GL's `wgclient` proto only emits a clean
   `ifup` once WG actually handshakes. When WG can't handshake it emits only
   `ifdown` / `REKEY-GIVEUP` events, so the hook's `ifup` branch never runs.
2. **The 5-minute health-check cron** (`/usr/local/bin/mudi-vpn-health.sh`) —
   it *does* correctly converge: when `network.wgclient1.disabled=0` and mihomo
   is dead it re-runs the hook with `ACTION=ifup`. But it only runs every 5
   minutes, so after toggling ON the user faces up to ~5 minutes of apparent
   silence and concludes the switch is broken.

The proxy data path itself does **not** need WG: foreign traffic egresses via
mihomo's VLESS-REALITY (TCP/443) + Hysteria-2 (UDP/443), which work fine on the
corp WiFi. Verified 2026-05-28: with mihomo up but WG still `0 B received`,
`curl -x http://192.168.8.1:7890 https://www.google.com` → HTTP 200, exit IP
`23.27.134.77`. WG is only the toggle *signal* + VPS-LAN reachability.

## Goal

Make "screen VPN ON" bring mihomo up within **seconds**, independent of whether
WG ever handshakes. No new daemon. Keep the health-check as the slow safety net.

## Design

Single change point: the `ifdown` branch of `/etc/hotplug.d/iface/99-vpn-mode`.

GL fires an `ifdown` for `wgclient1` within ~2s of a toggle-ON (the proto tears
down before bringing up) and again on every ~100s `REKEY-GIVEUP`. Today the
"flap" path (intent still ON, `disabled != 1`) only logs and exits. Change it to
converge when mihomo is not healthy:

```sh
ifdown)
    WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled" 2>/dev/null)
    if [ "$WG_DISABLED" != "1" ]; then            # intent = ON
        if pidof mihomo >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
            logger -t vpn-mode "WG $INTERFACE down but interface enabled (WG flap) — mihomo healthy, preserving"
            exit 0
        fi
        logger -t vpn-mode "WG $INTERFACE down, intent ON but mihomo not up — converging via ifup"
        INTERFACE="$WG_IFACE" ACTION=ifup "$0"
        exit $?
    fi
    # disabled = 1 → user toggled OFF → stop mihomo (unchanged)
    ...
```

### Why this is correct and safe

- **Fast:** the first ifdown after toggle-ON (~2s) converges; worst case the next
  REKEY-GIVEUP (~100s). Either beats the 5-min cron.
- **No WG dependency:** the reused `ACTION=ifup` path (Layer 1) starts mihomo and
  builds table 1001 / ip rule / dnsmasq regardless of WG handshake state.
- **Idempotent / no thrash:** once mihomo is healthy, later flaps hit the
  `pidof mihomo && utun` short-circuit and just preserve. Matches how the
  health-check already self-invokes the hook with `ACTION=ifup`.
- **No recursion:** the self-call uses `ACTION=ifup`, which runs only the `ifup`
  branch; it never re-enters `ifdown`.

### Unchanged

- `ifup` branch — networks where WG does handshake behave exactly as before.
- `ifdown` + `disabled=1` (user toggled OFF) — still stops mihomo, removes the
  LAN→1001 rule, restores public DNS.
- health-check cron — remains the ≤5-min safety net + boot recovery.
- WG keeps flapping in the background; harmless (mihomo preserved by Layer 2).

## Companion change

Apply the same edit to the hook heredoc inside `provision-mudi.sh` (the
`cat > /etc/hotplug.d/iface/99-vpn-mode << 'HOOK_EOF'` block, ~line 434) so a
future factory-reset re-provision does not regress. Commit + push (project
convention: any hook/mihomo change must also land in `provision-mudi.sh`).

## Testing (on device)

1. **Cold toggle, WG blocked:** `uci set network.wgclient1.disabled=0; uci commit`,
   stop mihomo, fire `INTERFACE=wgclient1 ACTION=ifdown /etc/hotplug.d/iface/99-vpn-mode`
   → expect mihomo running, utun up, table 1001 default present, and
   `curl -x http://192.168.8.1:7890 https://www.google.com` → 200.
2. **Toggle OFF:** `uci set network.wgclient1.disabled=1; uci commit`, fire
   `ACTION=ifdown` → expect mihomo stopped, LAN→1001 rule gone, dnsmasq back to
   public DNS.
3. **Flap idempotency:** with mihomo already healthy, fire `ACTION=ifdown` several
   times → expect "mihomo healthy, preserving" each time, no restart, no recursion.
4. **Regression:** fire `ACTION=ifup` directly → behaves as before.

## Out of scope

- Stopping the WG flap / REKEY-GIVEUP firewall reloads (GL firmware behavior).
- Fixing WG handshake through the corp firewall (network-level; not needed for
  proxying).
