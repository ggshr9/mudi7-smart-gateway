# Layer 2 — ifdown preserves mihomo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop GL framework's WG flap (ifdown on REKEY-GIVEUP) from killing mihomo when user intent is still ON, and ensure the next ifup re-adds the VPS_LAN route the kernel auto-removed during the flap.

**Architecture:** Two surgical edits inside the `HOOK_EOF` heredoc in `provision-mudi.sh`. The `ifdown)` branch gains an intent guard (`wireguard.global.global_proxy=1` → early-exit, preserve state). The Task-2 idempotency check in the `ifup)` branch is expanded to also verify the `$VPS_LAN` route exists; if not, full flush+rebuild runs.

**Tech Stack:** POSIX sh (busybox on OpenWrt), `uci`, `ip`, `logger`. Local lint via `bash -n` (outer) + `sh -n` (extracted heredoc body); on-device validation via `ssh` against the Mudi at `192.168.8.1`. No runtime test framework — both changes are validated by direct on-device hook invocation matching the spec's Validation section.

**Spec:** `docs/superpowers/specs/2026-05-27-layer-2-ifdown-preserve-mihomo-design.md`

**No test framework caveat:** Same as the Layer 1 plan — shell code inside a single-quoted heredoc deployed to a router. Verification: `bash -n provision-mudi.sh` + `sh -n` on the extracted hook body + on-device manual scenarios (Task 4).

---

## File Structure

**Modified:**
- `provision-mudi.sh` — two regions, both inside the `HOOK_EOF` heredoc (starts at `cat > /etc/hotplug.d/iface/99-vpn-mode << 'HOOK_EOF'` near line 435):
  - The `ifdown)` branch (starts at line 538, ends before `;;`)
  - The Task 2 idempotency block at lines 496-507

**Not modified:**
- ifup mihomo-restart guard (Task 1)
- ifup ip rule / blackhole / dnsmasq blocks (Tasks 3 + existing)
- Health check heredoc (`mudi-vpn-health.sh`)
- Phase headers, comments outside the two targeted regions, all other phases

---

## Task 1: Add intent guard to ifdown branch

**Files:**
- Modify: `provision-mudi.sh` lines 538-555 (inside `HOOK_EOF` heredoc, the `ifdown)` case body)

**Context:** The spec's Change 1. Currently the ifdown branch unconditionally stops mihomo, removes the ip rule, and reverts dnsmasq. After the change, it first checks `wireguard.global.global_proxy`. If `=1` (user intent still ON, this is a GL framework flap), the branch logs a single info line and exits 0 without touching anything. If `≠1` (user toggled OFF or UCI absent), the existing teardown runs.

- [ ] **Step 1: Apply the edit**

Use Edit tool on `/home/nategu/Documents/glinet/provision-mudi.sh`.

`old_string`:
```
    ifdown)
        logger -t vpn-mode "WG $INTERFACE down — stopping mihomo"
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

`new_string`:
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

- [ ] **Step 2: Syntax-check the outer script**

Run: `bash -n /home/nategu/Documents/glinet/provision-mudi.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Extract the hook body and syntax-check it as POSIX sh**

Run from `/home/nategu/Documents/glinet`:
```bash
awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/99-vpn-mode.sh
sh -n /tmp/99-vpn-mode.sh && echo OK
rm /tmp/99-vpn-mode.sh
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add provision-mudi.sh
git commit -m "$(cat <<'EOF'
Hook: ifdown preserves mihomo when intent is still ON

GL's wgclient proto fires ifdown on WG REKEY-GIVEUP (network flap), not
just on user toggle. Treating both as intent-OFF was killing mihomo
every couple minutes whenever WG couldn't keep a stable handshake. Now
the ifdown branch reads wireguard.global.global_proxy; if 1, log a
flap notice and exit without touching mihomo/rules/dnsmasq. The full
teardown only runs when intent is actually 0 (user pressed OFF).

EOF
)"
```

---

## Task 2: Expand table 1001 idempotency check to include VPS_LAN route

**Files:**
- Modify: `provision-mudi.sh` lines 496-507 (inside `HOOK_EOF` heredoc, the Task-2 idempotency block in the `ifup)` case)

**Context:** The spec's Change 2. Currently the guard only compares the default route. After Task 1 of this plan lands, a flap-ifdown leaves mihomo's utun-based default route intact but the kernel removes `$VPS_LAN dev wgclient1 table 1001` when wgclient1 vanishes. On the next ifup the guard sees the default matches → skips rebuild → VPS_LAN stays missing. Expand the guard to also count the VPS_LAN route, so absence triggers a rebuild.

- [ ] **Step 1: Apply the edit**

Use Edit tool on `/home/nategu/Documents/glinet/provision-mudi.sh`.

`old_string`:
```
        WANT_DEFAULT="default via $TUN_GW dev $TUN_DEV"
        CUR_DEFAULT=$(ip route show table 1001 2>/dev/null | grep "^default" || true)
        if [ "$CUR_DEFAULT" != "$WANT_DEFAULT" ]; then
            ip route flush table 1001 2>/dev/null
            ip route add "$VPS_LAN" dev "$INTERFACE" table 1001 2>/dev/null
            ip route add default via "$TUN_GW" dev "$TUN_DEV" table 1001 || {
                logger -t vpn-mode "ERROR: failed to add default via $TUN_GW dev $TUN_DEV"
                exit 1
            }
        else
            logger -t vpn-mode "table 1001 default already correct, skipping rebuild"
        fi
```

`new_string`:
```
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

- [ ] **Step 2: Syntax-check the outer script**

Run: `bash -n /home/nategu/Documents/glinet/provision-mudi.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Extract the hook body and syntax-check it as POSIX sh**

```bash
cd /home/nategu/Documents/glinet
awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/99-vpn-mode.sh
sh -n /tmp/99-vpn-mode.sh && echo OK
rm /tmp/99-vpn-mode.sh
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add provision-mudi.sh
git commit -m "$(cat <<'EOF'
Hook: table 1001 idempotency also checks VPS_LAN route

After Layer 2 ifdown preserves mihomo across a WG flap, the kernel
still auto-removes the $VPS_LAN dev wgclient1 route in table 1001
(because wgclient1 itself vanished). The default-via-utun route
persists. Old guard only compared default and would skip the rebuild,
leaving VPS_LAN missing indefinitely. Expand the guard to also count
the VPS_LAN route; if missing, run the full flush+rebuild.

EOF
)"
```

---

## Task 3: Deploy updated hook to Mudi and validate on-device

**Files:** none modified locally; this task deploys the updated hook heredoc body to the Mudi and runs the spec's Validation scenarios.

**Context:** The hook body lives inside a single-quoted heredoc, so we extract it and copy verbatim to `/etc/hotplug.d/iface/99-vpn-mode` on the device. Mudi credentials: `root@192.168.8.1` with password `Nategu325416` via `sshpass`. The Mudi's busybox doesn't have `sftp-server`, so file transfer uses `cat | ssh ... 'cat > /tmp/...'` instead of `scp`. Backups created with timestamp suffix in case of need to roll back.

- [ ] **Step 1: Extract the updated hook body**

```bash
cd /home/nategu/Documents/glinet
awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/99-vpn-mode.new
wc -l /tmp/99-vpn-mode.new
sh -n /tmp/99-vpn-mode.new && echo SYNTAX_OK
```
Expected: line count >0, `SYNTAX_OK`.

- [ ] **Step 2: Transfer to Mudi and verify on-device syntax**

```bash
cat /tmp/99-vpn-mode.new | SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'cat > /tmp/99-vpn-mode.new'
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'sh -n /tmp/99-vpn-mode.new && echo SYNTAX_OK'
```
Expected: `SYNTAX_OK`.

- [ ] **Step 3: Install with backup**

CRITICAL: backup MUST go outside `/etc/hotplug.d/iface/` because OpenWrt's
hotplug.d framework executes every executable file in that directory. A
`.bak` file with mode 755 (which `cp` preserves) becomes a second hook
that runs on every event — silently rolling back this change every flap.

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'mkdir -p /root/mudi-hook-backups && cp /etc/hotplug.d/iface/99-vpn-mode /root/mudi-hook-backups/99-vpn-mode.bak.$(date +%Y%m%d-%H%M%S) && cp /tmp/99-vpn-mode.new /etc/hotplug.d/iface/99-vpn-mode && chmod 755 /etc/hotplug.d/iface/99-vpn-mode && rm /tmp/99-vpn-mode.new && md5sum /etc/hotplug.d/iface/99-vpn-mode'
```

Then locally:
```bash
md5sum /tmp/99-vpn-mode.new
```
Expected: matching md5 between local and on-device (after install — local file was removed but the variable still exists in /tmp on the laptop until cleaned).

Actually verify by re-extracting locally:
```bash
md5sum /tmp/99-vpn-mode.new 2>/dev/null || awk "/^cat > \/etc\/hotplug.d\/iface\/99-vpn-mode << 'HOOK_EOF'/{flag=1; next} /^HOOK_EOF\$/{flag=0} flag" /home/nategu/Documents/glinet/provision-mudi.sh | md5sum
```

- [ ] **Step 4: Scenario A — real flap (the target)**

Prerequisites: WG enabled + intent ON, wait for WG to handshake then start flapping (which the on-device VPS is known to do due to NAT issues per the Layer 1 validation findings).

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'echo "--- prep: enable WG, wait for first ifup ---"; uci set network.wgclient1.disabled=0; uci commit network; ifup wgclient1 2>/dev/null; logger -t test "TEST_MARK L2_A1 enabled WG, waiting for first up→flap cycle"; for i in 1 2 3 4 5 6 7 8 9 10; do sleep 6; PID=$(pidof mihomo); echo "t+${i}0s mihomo=${PID:-none}"; done; echo "--- logs ---"; logread | awk "/TEST_MARK L2_A1/{found=1} found" | grep -E "vpn-mode|TEST_MARK" | tail -25'
```

Expected:
- mihomo PID appears within first ~30s (after GL fires successful ifup)
- mihomo PID **stays constant** across subsequent WG flap cycles (REKEY-GIVEUP-triggered ifdowns)
- logs show one or more `vpn-mode: WG wgclient1 down but intent=ON (WG flap) — preserving mihomo state`
- logs do NOT show `vpn-mode: WG wgclient1 down — stopping mihomo` after our change deploys
- LAN clients (if any traffic): no proxy interruption

If GL never fires a successful ifup in 60s, the WG handshake is currently failing both directions — note as environmental issue and proceed to manual trigger in Step 5.

- [ ] **Step 5: Scenario B — user OFF toggle still works**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'echo "--- save current intent ---"; ORIG_INTENT=$(uci -q get wireguard.global.global_proxy); echo "ORIG=$ORIG_INTENT"; logger -t test "TEST_MARK L2_B1 user OFF simulation"; echo "--- set intent OFF ---"; uci set wireguard.global.global_proxy=0; uci commit wireguard; sleep 1; echo "--- fire ifdown (simulating GL toggle off) ---"; INTERFACE="wgclient1" ACTION=ifdown /etc/hotplug.d/iface/99-vpn-mode 2>&1; sleep 2; echo "--- state ---"; pidof mihomo || echo "mihomo not running (expected)"; uci show dhcp | grep "@dnsmasq\[0\]\.server" | head -1; echo "--- restore intent ---"; uci set wireguard.global.global_proxy=$ORIG_INTENT; uci commit wireguard; echo "--- logs ---"; logread | awk "/TEST_MARK L2_B1/{found=1} found" | grep -E "vpn-mode|TEST_MARK" | tail -10'
```

Expected:
- `vpn-mode: WG wgclient1 down (intent=OFF) — stopping mihomo` log
- `vpn-mode: OK: pure direct mode` log
- `pidof mihomo` empty
- dnsmasq reverted to `223.5.5.5 119.29.29.29`

- [ ] **Step 6: Scenario C — VPS_LAN route recovery after flap**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'echo "--- prep: ensure mihomo running ---"; pidof mihomo || /etc/init.d/mihomo start; sleep 3; echo "--- baseline routes ---"; ip route show table 1001; logger -t test "TEST_MARK L2_C1 remove VPS_LAN route"; echo "--- remove VPS_LAN route ---"; ip route del 10.20.0.0/24 dev wgclient1 table 1001 2>&1; echo "after remove:"; ip route show table 1001; echo "--- fire ifup ---"; INTERFACE="wgclient1" ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode 2>&1; sleep 2; echo "--- final routes ---"; ip route show table 1001; echo "--- logs ---"; logread | awk "/TEST_MARK L2_C1/{found=1} found" | grep -E "vpn-mode|TEST_MARK" | tail -8'
```

Expected:
- After removal: table 1001 only has `default via 198.18.0.2 dev utun`
- ifup hook log: should NOT contain `table 1001 default+VPS_LAN already correct, skipping rebuild` — should show normal rebuild path (no skip log)
- After ifup: table 1001 has both `default via 198.18.0.2 dev utun` AND `10.20.0.0/24 dev wgclient1`

Caveat: if wgclient1 device doesn't exist when this runs (because GL handler tore it down between commands), the `ip route add 10.20.0.0/24 dev wgclient1` will fail silently (`2>/dev/null`) and the VPS_LAN route won't reappear. That's a device-availability issue, not a hook bug. In that case wait for GL to re-establish the interface or re-enable manually before retrying.

- [ ] **Step 7: Scenario D — full idempotency still skips when everything is correct**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'echo "--- ensure both routes present ---"; ip route show table 1001; logger -t test "TEST_MARK L2_D1 idempotent re-fire"; INTERFACE="wgclient1" ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode 2>&1; sleep 2; echo "--- logs ---"; logread | awk "/TEST_MARK L2_D1/{found=1} found" | grep -E "vpn-mode|TEST_MARK" | tail -8'
```

Expected:
- `vpn-mode: mihomo healthy (pid+utun), skipping restart`
- `vpn-mode: table 1001 default+VPS_LAN already correct, skipping rebuild` (note the new "+VPS_LAN" suffix)
- `vpn-mode: dnsmasq upstream already correct, skipping restart`
- `vpn-mode: OK: LAN=..., utun=Y, 1053-listeners=1, t1001-default=1`

- [ ] **Step 8: Restore Mudi to V0 baseline**

```bash
SSHPASS='Nategu325416' sshpass -e ssh root@192.168.8.1 'echo "--- restore disabled=1 (matches V0 baseline from Layer 1 validation) ---"; uci set network.wgclient1.disabled=1; uci commit network; INTERFACE="wgclient1" ACTION=ifdown /etc/hotplug.d/iface/99-vpn-mode 2>&1; sleep 2; /etc/init.d/mihomo stop 2>/dev/null; pkill -9 mihomo 2>/dev/null; sleep 1; echo "--- final state ---"; echo "WG_DISABLED=$(uci get network.wgclient1.disabled)"; echo "mihomo: $(pidof mihomo || echo not-running)"; echo "global_proxy=$(uci -q get wireguard.global.global_proxy)"; uci show dhcp | grep "@dnsmasq\[0\]\.server" | head -1'
```

Caveat: with the new ifdown intent-guard, `ACTION=ifdown` with `global_proxy=1` will hit the preserve-state branch and NOT stop mihomo. The manual `/etc/init.d/mihomo stop` is what actually stops mihomo for the V0 restore. This is correct behavior — the intent guard is doing its job.

Expected:
- `WG_DISABLED=1`
- `mihomo: not-running`
- `global_proxy=1` (preserved from baseline)
- dnsmasq server: `'223.5.5.5' '119.29.29.29'`

- [ ] **Step 9: No commit for this task — validation only, no code change**

The code changes were committed in Tasks 1 and 2.

---

## Task 4: Final shellcheck pass (CI-relied)

**Files:** none modified.

**Context:** shellcheck not installed locally per Layer 1 plan's discovery. CI (`.github/workflows/shellcheck.yml`) runs on push.

- [ ] **Step 1: Confirm shellcheck still not installed locally**

Run: `command -v shellcheck || echo "not installed, CI will run on push"`

- [ ] **Step 2: If installed, run it**

```bash
shellcheck -S info -e SC1091 provision-mudi.sh && echo OK
```
Expected: `OK` (no info-level findings).

- [ ] **Step 3: No commit**

---

## Self-Review

**Spec coverage check** against `2026-05-27-layer-2-ifdown-preserve-mihomo-design.md`:

| Spec section | Task |
|---|---|
| Change 1 — ifdown intent guard | Task 1 |
| Change 1 — preserve mihomo/rules/dnsmasq on flap | Task 1 (early `exit 0`) |
| Change 2 — table 1001 also checks VPS_LAN | Task 2 |
| Change 2 — skip log message updated to "default+VPS_LAN" | Task 2 (new_string) |
| Validation §1 — real flap | Task 3 Step 4 |
| Validation §2 — user OFF still works | Task 3 Step 5 |
| Validation §3 — VPS_LAN recovery after flap | Task 3 Step 6 |
| Validation §4 — full idempotency | Task 3 Step 7 |
| Non-goals (no new fields, no daemons) | enforced by file-scope of edits |
| Risk: mihomo zombies during persistent WG outage | by design, validated implicitly in §1 |
| Risk: bizarre UCI state | guarded by `[ "$GLOBAL" = "1" ]` exact-match |

All spec sections covered. No placeholders. Type/identifier consistency:
- `GLOBAL` (used in ifup branch line 467 with identical pattern) ✓
- `WANT_DEFAULT`, `CUR_DEFAULT`, `HAS_VPS_LAN` — all local to ifup case ✓
- `$VPS_LAN`, `$WG_IFACE`, `$INTERFACE`, `$TUN_GW`, `$TUN_DEV` — all sourced from `/etc/mudi-vpn.conf` ✓
- Skip log message changes from `"table 1001 default already correct, skipping rebuild"` to `"table 1001 default+VPS_LAN already correct, skipping rebuild"` — only Task 2 emits it, no other reference to the old string anywhere ✓
