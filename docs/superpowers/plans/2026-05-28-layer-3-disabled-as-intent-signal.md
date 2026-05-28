# Layer 3 — `disabled` as intent signal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Switch the mihomo lifecycle intent signal from `wireguard.global.global_proxy` to `network.${WG_IFACE}.disabled`, matching how the GL Web UI's "VPN" master toggle actually works.

**Architecture:** Three surgical edits in `provision-mudi.sh` (two inside the `HOOK_EOF` heredoc — ifup head + ifdown intent guard — and one inside the `HEALTH_EOF` heredoc — early-exit). Plus comment refresh to drop "Policy Mode" / "Global Mode" framing.

**Tech Stack:** POSIX sh (busybox on OpenWrt). Local lint: `bash -n` outer + `sh -n` extracted heredocs. On-device validation by SCP heredoc body via `cat | ssh` and exercising real GL Web UI toggle (or simulated `uci set ... disabled=N` + `ifup/ifdown wgclient1`).

**Spec:** `docs/superpowers/specs/2026-05-28-layer-3-disabled-as-intent-signal-design.md`

---

## File Structure

**Modified:** `provision-mudi.sh` only — three regions inside the embedded heredocs plus minor comment refresh:
- ifup branch head (currently lines 467-473)
- ifdown intent guard (currently lines 561-571)
- health check early-exit (currently lines 608-611)
- Optional comment refresh: hook header inside heredoc + Phase 8.5 outer comment + script preamble lines 6-9

---

## Task 1: ifup — remove `global_proxy` gate

**Files:** `provision-mudi.sh` lines 467-473 inside `HOOK_EOF`.

- [ ] **Step 1: Apply edit**

Edit tool on `/home/nategu/Documents/glinet/provision-mudi.sh`.

`old_string`:
```
case "$ACTION" in
    ifup)
        GLOBAL=$(uci -q get wireguard.global.global_proxy 2>/dev/null)
        if [ "$GLOBAL" != "1" ]; then
            logger -t vpn-mode "WG $INTERFACE up (Policy Mode) — mihomo stays off"
            exit 0
        fi
        logger -t vpn-mode "WG $INTERFACE up (Global Mode, LAN=$LAN_NET) — preparing mihomo"
```

`new_string`:
```
case "$ACTION" in
    ifup)
        logger -t vpn-mode "WG $INTERFACE up (LAN=$LAN_NET) — preparing mihomo"
```

- [ ] **Step 2: Syntax check**

```bash
cd /home/nategu/Documents/glinet
bash -n provision-mudi.sh && echo OK
awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/99.sh && sh -n /tmp/99.sh && echo HOOK_OK; rm /tmp/99.sh
```

Both must print OK.

- [ ] **Step 3: Commit**

```bash
git add provision-mudi.sh
git commit -m "Hook: drop Policy Mode gate in ifup, always set up mihomo

User's intent signal is the WG interface disabled flag, not
wireguard.global.global_proxy. If ifup fires, the interface is enabled,
which means the user wants proxy. Policy Mode was a hypothetical feature
that the user does not use; treating it as 'mihomo off' was extra
behavior beyond what the user wanted.
"
```

---

## Task 2: ifdown — switch intent guard to `disabled`

**Files:** `provision-mudi.sh` lines 561-571 inside `HOOK_EOF`.

- [ ] **Step 1: Apply edit**

`old_string`:
```
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

`new_string`:
```
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

- [ ] **Step 2: Syntax check** (same commands as Task 1 Step 2)

- [ ] **Step 3: Commit**

```bash
git add provision-mudi.sh
git commit -m "Hook: ifdown intent guard uses network.disabled, not global_proxy

GL Web UI's 'VPN' master toggle flips network.wgclient1.disabled, not
wireguard.global.global_proxy. Layer 2's guard was checking the wrong
key, so user-driven VPN OFF toggles fell into the 'preserve mihomo'
flap branch — mihomo kept running, fake-IP DNS kept working, the user
could still bypass GFW despite thinking VPN was off. Switch the guard
to disabled.
"
```

---

## Task 3: health check — drop `global_proxy` early-exit

**Files:** `provision-mudi.sh` lines 608-611 inside `HEALTH_EOF`.

- [ ] **Step 1: Apply edit**

`old_string`:
```
GLOBAL=$(uci -q get wireguard.global.global_proxy)
WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled")
[ "$GLOBAL" != "1" ] && exit 0
[ "$WG_DISABLED" = "1" ] && exit 0
```

`new_string`:
```
WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled" 2>/dev/null)
[ "$WG_DISABLED" = "1" ] && exit 0
```

- [ ] **Step 2: Syntax check**

```bash
cd /home/nategu/Documents/glinet
bash -n provision-mudi.sh && echo OK
awk "/^cat > \/usr\/local\/bin\/mudi-vpn-health.sh << 'HEALTH_EOF'/{flag=1; next} /^HEALTH_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/h.sh && sh -n /tmp/h.sh && echo HEALTH_OK; rm /tmp/h.sh
```

Both must print OK.

- [ ] **Step 3: Commit**

```bash
git add provision-mudi.sh
git commit -m "Health: drop global_proxy early-exit, disabled is sole intent signal

Mirrors Layer 3 hook changes: intent is governed by
network.wgclient1.disabled only. The global_proxy check was redundant
under the new semantics — if disabled=0 the user wants mihomo, no
matter what global_proxy says.
"
```

---

## Task 4: comment refresh (state-machine docs)

**Files:** `provision-mudi.sh` — three comment regions:
- Script preamble lines 6-9 (top-of-file state-machine summary)
- Hook header inside heredoc lines 439-450 (state-machine bullets)
- Phase 8.5 outer comment around line 597

- [ ] **Step 1: Read each block to confirm current text**

```bash
sed -n '6,13p' provision-mudi.sh
sed -n '439,450p' provision-mudi.sh
sed -n '595,600p' provision-mudi.sh
```

- [ ] **Step 2: Update script preamble (lines 6-9)**

`old_string`:
```
#   State machine:
#     VPN OFF              → mihomo NOT running, dnsmasq → Aliyun DNS, pure direct
#     VPN ON + Global Mode → mihomo running, dnsmasq → mihomo, smart split routing
#     VPN ON + Policy Mode → mihomo NOT running (reserved for UU later)
```

`new_string`:
```
#   State machine (Layer 3 — intent driven by network.wgclient1.disabled only):
#     WG disabled (disabled=1) → mihomo NOT running, dnsmasq → Aliyun DNS, pure direct
#     WG enabled  (disabled=0) → mihomo running, dnsmasq → mihomo, smart split routing
```

- [ ] **Step 3: Update hook header bullets (lines 439-450 — exact text via Read first)**

`old_string`:
```
# - ifup + Global Mode (wireguard.global.global_proxy=1):
#     Each step below is idempotent: it only mutates state that doesn't
#     already match desired. Safe to re-run from the cron health check.
#     1. If mihomo not healthy (no pid OR no utun): restart via procd, wait
#     2. Bail if utun never appears (no point continuing)
#     3. If table 1001 default route wrong: flush and rebuild
#     4. Add source-based ip rule (LAN → table 1001)
#     5. Remove GL blackhole rules
#     6. If dnsmasq upstream wrong: rewrite + restart
# - ifup + Policy Mode → no-op (reserved for UU)
# - ifdown + intent=ON (WG flap) → no-op, preserve mihomo state
# - ifdown + intent=OFF (user toggle) → stop mihomo, remove rule, restore dnsmasq
```

`new_string`:
```
# - ifup (WG interface coming up — user has it enabled):
#     Each step below is idempotent: it only mutates state that doesn't
#     already match desired. Safe to re-run from the cron health check.
#     1. If mihomo not healthy (no pid OR no utun): restart via procd, wait
#     2. Bail if utun never appears (no point continuing)
#     3. If table 1001 default route wrong: flush and rebuild
#     4. Add source-based ip rule (LAN → table 1001)
#     5. Remove GL blackhole rules
#     6. If dnsmasq upstream wrong: rewrite + restart
#     7. Self-heal wgclient1 dnsmasq if drifted from mihomo
# - ifdown + interface enabled (WG flap) → no-op, preserve mihomo state
# - ifdown + interface disabled (user toggle) → stop mihomo, remove rule, restore dnsmasq
```

- [ ] **Step 4: Update Phase 8.5 outer comment**

Find and replace whatever currently says "VPN OFF / Policy Mode". Read first
to get exact text, then replace mentions of "Global Mode / Policy Mode" with
"interface disabled".

- [ ] **Step 5: Syntax check + commit**

```bash
cd /home/nategu/Documents/glinet
bash -n provision-mudi.sh && echo OK
awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/99.sh && sh -n /tmp/99.sh && echo HOOK_OK; rm /tmp/99.sh

git add provision-mudi.sh
git commit -m "Docs: state-machine comments reflect disabled-as-intent

Removes 'Global Mode / Policy Mode' framing from the script preamble,
hook header bullets, and Phase 8.5 comment. Two-state machine now:
disabled=0 means run mihomo, disabled=1 means don't.
"
```

---

## Task 5: deploy + on-device validation

**Files:** none (validation only).

- [ ] **Step 1: Extract updated hook + health bodies + transfer**

```bash
cd /home/nategu/Documents/glinet
awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/99-vpn-mode.l3
awk "/^cat > \/usr\/local\/bin\/mudi-vpn-health.sh << 'HEALTH_EOF'/{flag=1; next} /^HEALTH_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/mudi-vpn-health.l3
sh -n /tmp/99-vpn-mode.l3 && sh -n /tmp/mudi-vpn-health.l3 && echo BOTH_OK
md5sum /tmp/99-vpn-mode.l3 /tmp/mudi-vpn-health.l3

cat /tmp/99-vpn-mode.l3 | SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'cat > /tmp/99-vpn-mode.l3'
cat /tmp/mudi-vpn-health.l3 | SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'cat > /tmp/mudi-vpn-health.l3'
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'sh -n /tmp/99-vpn-mode.l3 && sh -n /tmp/mudi-vpn-health.l3 && echo REMOTE_OK'
```

- [ ] **Step 2: Install with backup to /root/mudi-hook-backups/ (NOT in hotplug dir)**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'mkdir -p /root/mudi-hook-backups && cp /etc/hotplug.d/iface/99-vpn-mode /root/mudi-hook-backups/99-vpn-mode.bak.l3.$(date +%H%M%S) && cp /usr/local/bin/mudi-vpn-health.sh /root/mudi-hook-backups/mudi-vpn-health.bak.l3.$(date +%H%M%S) && cp /tmp/99-vpn-mode.l3 /etc/hotplug.d/iface/99-vpn-mode && chmod 755 /etc/hotplug.d/iface/99-vpn-mode && cp /tmp/mudi-vpn-health.l3 /usr/local/bin/mudi-vpn-health.sh && chmod 755 /usr/local/bin/mudi-vpn-health.sh && rm /tmp/99-vpn-mode.l3 /tmp/mudi-vpn-health.l3 && md5sum /etc/hotplug.d/iface/99-vpn-mode /usr/local/bin/mudi-vpn-health.sh && echo "--- single hook check ---" && ls /etc/hotplug.d/iface/ | grep vpn-mode'
```

Expected: matching md5 between local /tmp/*.l3 and on-device files; only `99-vpn-mode` (no `.bak*`) in iface dir.

- [ ] **Step 3: Scenario A — toggle WG OFF via UCI (simulates GL Web UI VPN OFF)**

Prereqs: WG enabled, mihomo running (do `uci set network.wgclient1.disabled=0; uci commit network; ifup wgclient1; /etc/init.d/mihomo start` to get there if needed).

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'PID_BEFORE=$(pidof mihomo); echo "before mihomo=$PID_BEFORE"; logger -t test "TEST_MARK L3_A1"; uci set network.wgclient1.disabled=1; uci commit network; ifdown wgclient1 2>&1; sleep 3; echo; echo "after:"; echo "mihomo=$(pidof mihomo || echo NONE)"; ip link show utun 2>&1 | head -1; uci show "dhcp.@dnsmasq[0].server" 2>/dev/null || uci show dhcp | grep -E "dhcp\\.[a-z0-9]+\\.server=" | head -2; echo; echo "--- logs ---"; logread | awk "/TEST_MARK L3_A1/{found=1} found" | grep -E "vpn-mode|TEST_MARK" | tail -10'
```

Expected: `WG wgclient1 down (interface disabled) — stopping mihomo` + `OK: pure direct mode`. `pidof mihomo` empty. utun gone.

- [ ] **Step 4: Scenario B — toggle WG ON (simulates GL Web UI VPN ON)**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'logger -t test "TEST_MARK L3_B1"; uci set network.wgclient1.disabled=0; uci commit network; ifup wgclient1 2>&1; sleep 8; echo "mihomo=$(pidof mihomo || echo NONE)"; ip link show utun 2>&1 | head -1; uci show "dhcp.@dnsmasq[0].server" 2>/dev/null || uci show dhcp | grep -E "dhcp\\.[a-z0-9]+\\.server=" | head -2; echo "--- logs ---"; logread | awk "/TEST_MARK L3_B1/{found=1} found" | grep -E "vpn-mode|TEST_MARK" | tail -10'
```

Expected: `WG wgclient1 up (LAN=...) — preparing mihomo`. mihomo pid appears. utun up. dnsmasq @0 server points at `127.0.0.1#1053`.

If GL framework's flap behavior fires ifdown again immediately due to WG handshake issues, expect to see `WG wgclient1 down but interface enabled (WG flap) — preserving mihomo state` — mihomo should NOT die.

- [ ] **Step 5: Scenario C — flap behavior unchanged**

Mihomo running, intent ON (disabled=0). Wait 90 seconds for a natural flap.

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'PID=$(pidof mihomo); echo "PID=$PID"; logger -t test "TEST_MARK L3_C1"; for i in 1 2 3; do sleep 30; NOW=$(pidof mihomo); echo "t+${i}*30s mihomo=${NOW:-NONE}"; done; echo "--- logs ---"; logread | awk "/TEST_MARK L3_C1/{found=1} found" | grep -E "vpn-mode|mudi-health|TEST_MARK" | tail -15'
```

Expected: PID unchanged across cycles. Only `preserving mihomo state` logs from flap, no `stopping mihomo`.

- [ ] **Step 6: Scenario D — health quiet when WG disabled**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'uci set network.wgclient1.disabled=1; uci commit network; ifdown wgclient1; sleep 2; logger -t test "TEST_MARK L3_D1"; /usr/local/bin/mudi-vpn-health.sh; echo "exit=$?"; logread | awk "/TEST_MARK L3_D1/{found=1} found" | grep mudi-health'
```

Expected: exit=0, no mudi-health log line (silent early-exit on disabled=1).

- [ ] **Step 7: Restore the user's working state**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'uci set network.wgclient1.disabled=0; uci commit network; ifup wgclient1; sleep 8; /etc/init.d/mihomo start 2>/dev/null; sleep 3; INTERFACE=wgclient1 ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode 2>&1; sleep 2; echo "final: mihomo=$(pidof mihomo) intent=$(uci get wireguard.global.global_proxy) disabled=$(uci get network.wgclient1.disabled)"; nslookup google.com 192.168.8.1 2>&1 | grep "^Address" | head -3'
```

Expected: mihomo running, DNS returns 198.18.x.x (fake-IP, bypass works).

- [ ] **Step 8: Push**

```bash
git push origin master
gh run list --branch master --limit 1
```

---

## Self-Review

Spec coverage:

| Spec section | Task |
|---|---|
| Change 1 ifup drop gate | Task 1 |
| Change 2 ifdown disabled guard | Task 2 |
| Change 3 health early-exit | Task 3 |
| Change 4 comments | Task 4 |
| Validation §1 toggle OFF | Task 5 Step 3 |
| Validation §2 toggle ON | Task 5 Step 4 |
| Validation §3 flap preserves | Task 5 Step 5 |
| Validation §4 health quiet on disabled | Task 5 Step 6 |
| Validation §5 health recovers mihomo | covered implicitly by §2/§5 (re-trigger path) |

No placeholders. Identifier consistency: `WG_DISABLED` (matches existing health
script variable name). Backup destination explicitly `/root/mudi-hook-backups/`
(per Layer 2 post-mortem).
