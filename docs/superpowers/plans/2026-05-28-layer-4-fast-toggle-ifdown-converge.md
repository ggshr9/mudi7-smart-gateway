# Layer 4 — Fast toggle via ifdown converge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "screen VPN ON" start mihomo within seconds on networks where WireGuard never handshakes, by converging in the hook's `ifdown` flap branch.

**Architecture:** Single logic change to the `ifdown` branch of `/etc/hotplug.d/iface/99-vpn-mode`: when intent is ON (`disabled != 1`) but mihomo isn't healthy, self-invoke with `ACTION=ifup` (reusing the existing convergence path). Applied identically to the live hook and the `provision-mudi.sh` heredoc source-of-truth. No new daemon; health-check stays as the slow safety net.

**Tech Stack:** POSIX sh (busybox/OpenWrt), UCI, hotplug.d, mihomo, deployed over SSH to GL-E5800 at 192.168.8.1.

---

## Overview

Make "screen VPN ON" start mihomo within seconds on networks where WireGuard
never handshakes, by converging in the hook's `ifdown` flap branch instead of
waiting for the 5-minute health-check. Single logic change, applied in two
places (live hook + provision script).

Design: `docs/superpowers/specs/2026-05-28-layer-4-fast-toggle-ifdown-converge-design.md`

## Current State

- `/etc/hotplug.d/iface/99-vpn-mode` (on device) and the `HOOK_EOF` heredoc in
  `provision-mudi.sh` (~line 434–585) are byte-identical.
- The `ifdown` branch: reads `network.wgclient1.disabled`; if `!= 1` (intent ON)
  it logs `"WG ... down but interface enabled (WG flap) — preserving mihomo state"`
  and `exit 0` — it never starts mihomo. If `= 1` it stops mihomo + cleans up.
- mihomo therefore only auto-starts via the `ifup` branch (needs WG handshake)
  or the 5-min health-check cron.
- Router reachable: `ssh root@192.168.8.1` (keyed; password `Nategu325416`, port 22).
- Current live state: `disabled=0`, mihomo running (started manually this session).

## Desired End State

Toggling the screen switch ON brings mihomo up within ~2s (first ifdown) on the
corp-WiFi uplink, with no dependency on WG. Verified by: stop mihomo with
`disabled=0`, fire one `ACTION=ifdown`, and `curl -x http://192.168.8.1:7890
https://www.google.com` returns 200. Toggling OFF still stops mihomo.

## What We're NOT Doing

- Not touching the `ifup` branch.
- Not changing the health-check, cron, or WG config.
- Not trying to stop the WG REKEY-GIVEUP flap / firewall reloads.
- Not fixing the WG handshake through the corp firewall.

## Implementation Approach

Edit the `ifdown` flap path to: keep the "preserve" short-circuit when mihomo is
healthy, otherwise self-invoke with `ACTION=ifup` (same pattern the health-check
uses). Apply identically to the on-device hook and the `provision-mudi.sh`
heredoc. Test on the live router. Commit + push.

## Phase 1: Edit the hook logic (provision-mudi.sh source of truth)

### Changes Required

#### 1. provision-mudi.sh — `ifdown` flap branch inside the `HOOK_EOF` heredoc

**File**: `provision-mudi.sh`
**Changes**: Replace the early-return flap block with a converge-if-unhealthy
block. Current code:

```sh
        WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled" 2>/dev/null)
        if [ "$WG_DISABLED" != "1" ]; then
            logger -t vpn-mode "WG $INTERFACE down but interface enabled (WG flap) — preserving mihomo state"
            exit 0
        fi
```

New code:

```sh
        WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled" 2>/dev/null)
        if [ "$WG_DISABLED" != "1" ]; then
            # Intent is still ON. If mihomo is already healthy this is just a WG
            # flap — preserve. If mihomo is NOT up (e.g. a network where WG never
            # handshakes, so the ifup branch never fired), converge now via the
            # ifup path so the toggle works in seconds instead of waiting for the
            # 5-min health-check. ACTION=ifup runs only the ifup branch — no
            # recursion back into ifdown.
            if pidof mihomo >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
                logger -t vpn-mode "WG $INTERFACE down but interface enabled (WG flap) — mihomo healthy, preserving"
                exit 0
            fi
            logger -t vpn-mode "WG $INTERFACE down, intent ON but mihomo not up — converging via ifup"
            INTERFACE="$WG_IFACE" ACTION=ifup "$0"
            exit $?
        fi
```

Also update the header comment block (line ~14) from:
`# - ifdown + interface enabled (WG flap) → no-op, preserve mihomo state`
to:
`# - ifdown + interface enabled (WG flap): preserve if mihomo healthy, else converge via ifup`

### Success Criteria

#### Automated Verification
- [ ] `bash -n provision-mudi.sh` parses clean.
- [ ] `shellcheck provision-mudi.sh` shows no new warnings vs. before (CI uses shellcheck).
- [ ] The heredoc still contains exactly one `ACTION=ifup "$0"` self-call and the
      `pidof mihomo` short-circuit.

#### Manual Verification
- [ ] Diff is limited to the `ifdown` branch + the one header comment line.

---

## Phase 2: Deploy to the live router and test

### Overview
Extract the updated hook from `provision-mudi.sh` and install it on the device,
then run the design's test matrix. (Deploy by re-rendering just the hook file —
do not re-run the whole provision script.)

### Changes Required

#### 1. Install updated hook on device

**Action**: Copy the new hook body to `/etc/hotplug.d/iface/99-vpn-mode` on
`192.168.8.1`, `chmod 755`. Back up the existing one first to
`/tmp/99-vpn-mode.bak-<ts>` (NOT under `/etc/hotplug.d/iface/`, per commit
db78aae — a backup there would itself fire on events).

### Success Criteria

#### Automated Verification (run over ssh)
- [ ] **Test 1 — cold toggle, WG blocked:** `uci set network.wgclient1.disabled=0;
      uci commit network`; `/etc/init.d/mihomo stop; pkill -9 mihomo`; confirm
      `pidof mihomo` empty; `INTERFACE=wgclient1 ACTION=ifdown
      /etc/hotplug.d/iface/99-vpn-mode`; then within ~15s `pidof mihomo` non-empty,
      `ip link show utun` exists, `ip route show table 1001` has `default via
      198.18.0.2 dev utun`, and `logread -e vpn-mode | tail` shows "converging via ifup".
- [ ] **Test 1 end-to-end:** `curl -s -o /dev/null -w '%{http_code}' -x
      http://192.168.8.1:7890 https://www.google.com` → `200`.
- [ ] **Test 2 — toggle OFF:** `uci set network.wgclient1.disabled=1; uci commit
      network`; `INTERFACE=wgclient1 ACTION=ifdown /etc/hotplug.d/iface/99-vpn-mode`;
      then `pidof mihomo` empty, no `ip rule` at pref `6500`, `uci get
      dhcp.@dnsmasq[0].server` back to public DNS.
- [ ] **Test 3 — flap idempotency:** with `disabled=0` and mihomo healthy, fire
      `ACTION=ifdown` 3×; each logs "mihomo healthy, preserving"; mihomo PID
      unchanged across all three (no restart); no recursion / no error.
- [ ] **Test 4 — ifup regression:** fire `INTERFACE=wgclient1 ACTION=ifup
      /etc/hotplug.d/iface/99-vpn-mode` directly → behaves as before (logs
      "preparing mihomo" / "OK:", mihomo healthy, table 1001 default present).

#### Manual Verification
- [ ] Restore the user's intended end state after testing (set `disabled=0`,
      ensure mihomo running so the VPN is left ON and working).

---

## Phase 3: Commit and push

### Changes Required
- Commit `provision-mudi.sh` + this plan (and the spec if not already) to master.
- Message: `Hook: Layer 4 — ifdown converges mihomo when intent ON but down`.
- `git push`.

### Success Criteria
#### Automated Verification
- [ ] `git status` clean after commit.
- [ ] `git push` succeeds; `git log --oneline origin/master -1` matches local.

## Notes for the implementer

- The on-device hook and the `provision-mudi.sh` heredoc MUST stay byte-identical
  (modulo the heredoc's `'HOOK_EOF'` quoting). Derive the device file from the
  script, don't hand-edit them separately.
- `"$0"` inside the hook resolves to `/etc/hotplug.d/iface/99-vpn-mode` when run
  by hotplug or by the test harness — correct for the self-call.
