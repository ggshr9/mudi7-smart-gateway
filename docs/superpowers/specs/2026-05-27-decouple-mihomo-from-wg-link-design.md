# Decouple mihomo lifecycle from WG link state

**Date**: 2026-05-27
**Status**: Approved
**Scope**: `provision-mudi.sh` — `99-vpn-mode` hook (ifup case) and `mudi-vpn-health.sh`

## Problem

The current state machine ties mihomo's lifecycle to WireGuard's link state in two
places, even though mihomo's proxy traffic (VLESS / Hysteria-2 to `VPS_HOST`) does
not flow through the WG tunnel. WG is purely a signal switch — the GL.iNet Web UI's
"VPN" toggle happens to drive a WG interface, and the hotplug `ifup`/`ifdown` events
are used as the user-intent signal.

The two coupling points:

1. **`mudi-vpn-health.sh` treats WG-stale as a degradation.** When the WG handshake
   is older than 180 seconds, it goes into the `problems` list alongside real
   problems (`mihomo-dead`, `${TUN_DEV}-missing`, etc.). Any non-empty `problems`
   list re-triggers the `ifup` hook.

2. **The `ifup` hook is not idempotent.** It starts with an unconditional
   `pkill -9 mihomo; sleep 1; /etc/init.d/mihomo start`, then re-flushes table 1001,
   re-adds the ip rule, rewrites dnsmasq config, and restarts dnsmasq — regardless
   of whether anything was actually broken.

Combined effect: when WG has a connectivity blip (peer unreachable, packet loss,
etc.) but mihomo itself is fine, the cron-driven health check kills a healthy mihomo
every 5 minutes and bounces dnsmasq with it. User-visible: periodic DNS hiccup and
broken in-flight connections.

## Goals

- mihomo's lifecycle is driven by **user intent** (GL Web UI VPN toggle, surfaced as
  the WG interface's `ifup`/`ifdown` events), not by WG link health.
- Health check distinguishes "real degradation that warrants re-converging" from
  "noisy signal we want to log but ignore".
- The `ifup` hook is idempotent: re-running it on a healthy system is a no-op.

## Non-goals

- No new service, daemon, watcher, or cron.
- No changes to mihomo config, nft rules, CN CIDR subscription, or the GL VPN
  framework.
- No new fields in `/etc/mudi-vpn.conf` — existing deployments must keep working
  after re-running `provision-mudi.sh`.
- We do not try to detect "user toggled VPN via UCI without going through the GL
  framework" — out of scope. UCI changes don't fire hotplug events; the GL framework
  is the only supported intent path.

## Design

### Change 1: `99-vpn-mode` ifup case — make convergence idempotent

The `ifup` branch becomes a sequence of "check current state, only mutate if it
differs from desired state" steps.

**mihomo process**: only restart when not actually healthy. Definition of healthy:
both the process exists AND the TUN device exists. If the process is up but `utun`
disappeared, mihomo is internally stuck — full restart.

```sh
if pidof mihomo >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
    logger -t vpn-mode "mihomo healthy, skipping restart"
else
    pkill -9 mihomo 2>/dev/null
    sleep 1
    /etc/init.d/mihomo start
    # existing 10s wait loops for utun + DNS port
fi
```

After the wait loops, the existing `if ! ip link show "$TUN_DEV" ...` bail-out
remains as the hard failure path.

**Routing table 1001**: only flush + rebuild if current default differs from desired.

```sh
WANT="default via $TUN_GW dev $TUN_DEV"
CUR=$(ip route show table 1001 | grep "^default")
if [ "$CUR" != "$WANT" ]; then
    ip route flush table 1001 2>/dev/null
    ip route add "$VPS_LAN" dev "$INTERFACE" table 1001 2>/dev/null
    ip route add default via "$TUN_GW" dev "$TUN_DEV" table 1001 || {
        logger -t vpn-mode "ERROR: failed to add default via $TUN_GW dev $TUN_DEV"
        exit 1
    }
fi
```

**ip rule (LAN → table 1001)**: keep as-is. `del + add` is already idempotent and
must run every time because `LAN_NET` can change if the user moves LAN subnet via
the GL Web UI (this is the point of computing `LAN_NET` at runtime).

**GL blackhole rule deletion**: keep as-is. `ip rule del ... 2>/dev/null` is
idempotent; cost is negligible.

**dnsmasq**: only rewrite + restart if upstream server config differs. The unconditional
restart is the noisiest side effect of re-running ifup (causes a brief DNS gap).

```sh
WANT_SERVER="127.0.0.1#${DNS_PORT}"
if ! uci -q show dhcp | grep -qF "server='${WANT_SERVER}'"; then
    uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server="${WANT_SERVER}"
    uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
    uci set dhcp.@dnsmasq[0].strictorder="1"
    uci commit dhcp
    /etc/init.d/dnsmasq restart
fi
```

**Final OK log line**: keep as-is — useful state report after every convergence.

### Change 2: `mudi-vpn-health.sh` — separate signal noise from real problems

Split the existing single `problems` accumulator into two paths:

1. **Real problems** (cause re-trigger of `ifup`):
   - `mihomo-dead` (`pidof mihomo` empty)
   - `${TUN_DEV}-missing` (utun gone)
   - `dns-down` (port 1053 not listening)
   - `fw-rule-missing` (forward chain missing utun rule)

2. **Signal noise** (info log only, no action):
   - `WG-stale` (handshake older than 180s)

```sh
. /etc/mudi-vpn.conf 2>/dev/null || exit 0
GLOBAL=$(uci -q get wireguard.global.global_proxy)
WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled")
[ "$GLOBAL" != "1" ] && exit 0
[ "$WG_DISABLED" = "1" ] && exit 0

# WG handshake — informational only, WG is signal-only in this setup
HS=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
if [ -z "$HS" ] || [ "$HS" = "0" ] || [ $(($(date +%s) - HS)) -gt 180 ]; then
    logger -t mudi-health "INFO: WG handshake stale (signal-only, not acting)"
fi

problems=""
pidof mihomo >/dev/null || problems="$problems mihomo-dead"
ip link show "$TUN_DEV" >/dev/null 2>&1 || problems="$problems ${TUN_DEV}-missing"
netstat -tln 2>/dev/null | grep -q ":${DNS_PORT} " || problems="$problems dns-down"
nft list chain inet fw4 forward 2>/dev/null | grep -q "oifname \"$TUN_DEV\"" \
    || problems="$problems fw-rule-missing"

[ -z "$problems" ] && exit 0

logger -t mudi-health "DEGRADED: ${problems# } → re-triggering hook ifup"
INTERFACE="$WG_IFACE" ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode
```

## Validation

Manual scenarios to run on the Mudi after re-provisioning:

1. **Normal toggle via GL Web UI**
   - Off → On: `logread | grep vpn-mode` shows mihomo start + convergence log
   - On → Off: mihomo stops, dnsmasq reverts to Aliyun DNS
   - **Expected**: same behavior as today, no regression

2. **WG broken deliberately** (the scenario this design targets)
   - Change WG peer endpoint to an unreachable IP; wait 5+ minutes
   - **Expected**: `logread | grep mudi-health` shows `INFO: WG handshake stale`
     only; no `DEGRADED` line; `pidof mihomo` returns the same PID throughout;
     browsing continues working
   - Restore endpoint; handshake recovers; logs go quiet

3. **mihomo killed deliberately** (recovery still works)
   - `pkill -9 mihomo`; either wait 5 min or run `mudi-vpn-health.sh` manually
   - **Expected**: `DEGRADED: mihomo-dead → re-triggering hook ifup`, mihomo
     restarts, utun comes back, proxy works

4. **Idempotent re-convergence** (verify no dnsmasq bounce)
   - With a healthy system, run `INTERFACE=$WG_IFACE ACTION=ifup
     /etc/hotplug.d/iface/99-vpn-mode` manually
   - **Expected**: log says `mihomo healthy, skipping restart`; no dnsmasq
     restart log; DNS uninterrupted (test with continuous `dig` from a LAN host)

## Risk

- **GL framework edge case**: if GL's policy framework ever brings WG up without
  firing `ifup` (e.g. some internal reload path), nothing here triggers mihomo
  startup. Same risk as today — out of scope for this change.
- **mihomo health definition is narrow**: "process exists + utun exists" doesn't
  catch "mihomo running but VLESS upstream dead". That's already a known gap
  covered by mihomo's own `url-test` proxy group (gstatic 204 every 60s) and
  failover to Hysteria-2 — health check at the OS level intentionally does not
  reach into mihomo internals.
