# Decouple mihomo from WG link state — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the cron health check from killing a healthy mihomo when WG handshake goes stale, and make the `ifup` hook idempotent so re-runs don't bounce mihomo/dnsmasq unnecessarily.

**Architecture:** Two surgical edits to `provision-mudi.sh`. The `99-vpn-mode` ifup hook (embedded heredoc, lines 463-513) becomes "check state, mutate only if it differs from desired". The `mudi-vpn-health.sh` script (embedded heredoc, lines 542-574) splits its single `problems` accumulator into a real-problem set (triggers ifup) and a signal-only WG-stale log line.

**Tech Stack:** POSIX sh (busybox on OpenWrt), `uci`, `ip`, `nft`, `wg`, `pidof`, `netstat`. Local lint via `bash -n`; CI runs `shellcheck` (`.github/workflows/shellcheck.yml`). No runtime test framework — final validation is manual on the Mudi device per the spec.

**Spec:** `docs/superpowers/specs/2026-05-27-decouple-mihomo-from-wg-link-design.md`

**No test framework caveat:** This is provisioning shell code that runs on the router. There's no unit-test harness for the embedded heredoc bodies. We rely on (1) `bash -n` syntax check of `provision-mudi.sh`, (2) `sh -n` syntax check of extracted heredoc bodies, (3) `shellcheck` (run by CI when pushed; install locally if available), (4) manual scenarios on the actual Mudi as documented in Task 6 / spec §Validation.

---

## File Structure

**Modified:**
- `provision-mudi.sh` — two specific regions inside two embedded heredocs:
  - Lines 472-508 (ifup case body, inside `HOOK_EOF` heredoc starting at 435)
  - Lines 542-574 (entire `mudi-vpn-health.sh` body, inside `HEALTH_EOF` heredoc starting at 542)

**Not modified:**
- ifup's prelude (lines 463-470), wait loops (476-488), ip rule block (497-501), final OK log (510-512)
- ifdown branch (515-528) — already clean
- All other phases (Phase 1-4, 6-8, 8.6+)

---

## Task 1: Make mihomo restart idempotent in ifup hook

**Files:**
- Modify: `provision-mudi.sh` lines 472-474 (inside `HOOK_EOF` heredoc)

**Context:** Current code unconditionally `pkill -9 mihomo; sleep 1; /etc/init.d/mihomo start` on every ifup, even when mihomo is healthy. We change it to only restart when mihomo isn't healthy. "Healthy" = process alive AND TUN device exists (mihomo can be hung with `pidof` still returning but utun gone).

- [ ] **Step 1: Apply the edit**

Use Edit tool:

`old_string`:
```
        logger -t vpn-mode "WG $INTERFACE up (Global Mode) — preparing mihomo"

        pkill -9 mihomo 2>/dev/null
        sleep 1
        /etc/init.d/mihomo start

        for i in 1 2 3 4 5 6 7 8 9 10; do
```

`new_string`:
```
        logger -t vpn-mode "WG $INTERFACE up (Global Mode) — preparing mihomo"

        if pidof mihomo >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
            logger -t vpn-mode "mihomo healthy (pid+utun), skipping restart"
        else
            pkill -9 mihomo 2>/dev/null
            sleep 1
            /etc/init.d/mihomo start
        fi

        for i in 1 2 3 4 5 6 7 8 9 10; do
```

- [ ] **Step 2: Syntax-check the outer script**

Run: `bash -n provision-mudi.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Extract the hook body and syntax-check it as POSIX sh**

Run:
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
Hook: skip mihomo restart in ifup when already healthy

When the cron health check re-triggers ifup to recover one specific
degradation (e.g. missing fw rule), don't bounce mihomo if its process
and utun device are both fine. Healthy = pidof + utun present; either
missing means full restart as before.

EOF
)"
```

---

## Task 2: Make routing table 1001 idempotent in ifup hook

**Files:**
- Modify: `provision-mudi.sh` lines 490-495 (inside `HOOK_EOF` heredoc)

**Context:** `ip route flush table 1001` followed by re-adding is already idempotent in behavior, but every re-run rewrites the table for no reason. Guard with a check: if `default via $TUN_GW dev $TUN_DEV` already present in table 1001, skip the flush+rebuild.

- [ ] **Step 1: Apply the edit**

Use Edit tool:

`old_string`:
```
        ip route flush table 1001 2>/dev/null
        ip route add "$VPS_LAN" dev "$INTERFACE" table 1001 2>/dev/null
        ip route add default via "$TUN_GW" dev "$TUN_DEV" table 1001 || {
            logger -t vpn-mode "ERROR: failed to add default via $TUN_GW dev $TUN_DEV"
            exit 1
        }
```

`new_string`:
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
        fi
```

- [ ] **Step 2: Syntax-check the outer script**

Run: `bash -n provision-mudi.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Extract the hook body and syntax-check it as POSIX sh**

Run:
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
Hook: skip table 1001 rebuild when default route already correct

EOF
)"
```

---

## Task 3: Make dnsmasq config update idempotent in ifup hook

**Files:**
- Modify: `provision-mudi.sh` lines 503-508 (inside `HOOK_EOF` heredoc)

**Context:** Current code rewrites dnsmasq UCI server list and unconditionally calls `/etc/init.d/dnsmasq restart`. The restart causes a brief DNS gap (hundreds of ms) every time ifup re-runs. Guard with a check: if the desired primary server `127.0.0.1#${DNS_PORT}` is already in the UCI list, skip the rewrite + restart. `uci show` output uses `key='value'` (single-quoted), so `grep -qF "server='127.0.0.1#${DNS_PORT}'"` matches reliably.

- [ ] **Step 1: Apply the edit**

Use Edit tool:

`old_string`:
```
        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#${DNS_PORT}"
        uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
        uci set dhcp.@dnsmasq[0].strictorder="1"
        uci commit dhcp
        /etc/init.d/dnsmasq restart
```

`new_string`:
```
        WANT_SERVER="127.0.0.1#${DNS_PORT}"
        if ! uci -q show dhcp 2>/dev/null | grep -qF "server='${WANT_SERVER}'"; then
            uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
            uci add_list dhcp.@dnsmasq[0].server="${WANT_SERVER}"
            uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
            uci set dhcp.@dnsmasq[0].strictorder="1"
            uci commit dhcp
            /etc/init.d/dnsmasq restart
        fi
```

- [ ] **Step 2: Syntax-check the outer script**

Run: `bash -n provision-mudi.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Extract the hook body and syntax-check it as POSIX sh**

Run:
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
Hook: skip dnsmasq rewrite+restart when upstream already correct

Avoids the brief DNS gap caused by /etc/init.d/dnsmasq restart on every
ifup re-trigger from the cron health check.

EOF
)"
```

---

## Task 4: Demote WG-stale to log-only in health check

**Files:**
- Modify: `provision-mudi.sh` lines 552-573 (inside `HEALTH_EOF` heredoc)

**Context:** Current health check lumps WG handshake age into the same `problems` accumulator as real problems. Any non-empty `problems` re-triggers ifup, which (until the previous tasks landed) bounced mihomo. The fix: lift WG handshake check out into a separate info-only branch that never adds to `problems`. The remaining four checks (mihomo-dead, utun-missing, dns-down, fw-rule-missing) keep the existing recovery behavior.

- [ ] **Step 1: Apply the edit**

Use Edit tool:

`old_string`:
```
problems=""

# WG handshake within last 3 min
HS=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}')
if [ -z "$HS" ] || [ "$HS" = "0" ] || [ $(($(date +%s) - HS)) -gt 180 ]; then
    problems="$problems WG-stale"
fi

pidof mihomo >/dev/null || problems="$problems mihomo-dead"
ip link show "$TUN_DEV" >/dev/null 2>&1 || problems="$problems ${TUN_DEV}-missing"
netstat -tln 2>/dev/null | grep -q ":${DNS_PORT} " || problems="$problems dns-down"

# fw4 forward rule still in place (utun accept rules)
nft list chain inet fw4 forward 2>/dev/null | grep -q "oifname \"$TUN_DEV\"" \
    || problems="$problems fw-rule-missing"

if [ -z "$problems" ]; then
    exit 0   # healthy, stay quiet
fi

logger -t mudi-health "DEGRADED: ${problems# } → re-triggering hook ifup"
INTERFACE="$WG_IFACE" ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode
```

`new_string`:
```
# WG handshake — informational only; WG is signal-only in this setup,
# proxy traffic does not flow through it, so a stale handshake is not a
# reason to bounce mihomo or re-run convergence.
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

- [ ] **Step 2: Syntax-check the outer script**

Run: `bash -n provision-mudi.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Extract the health body and syntax-check it as POSIX sh**

Run:
```bash
awk "/^cat > \/usr\/local\/bin\/mudi-vpn-health.sh << 'HEALTH_EOF'/{flag=1; next} /^HEALTH_EOF\$/{flag=0} flag" provision-mudi.sh > /tmp/mudi-vpn-health.sh
sh -n /tmp/mudi-vpn-health.sh && echo OK
rm /tmp/mudi-vpn-health.sh
```
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add provision-mudi.sh
git commit -m "$(cat <<'EOF'
Health: demote WG-stale to info log, stop bouncing mihomo on WG blips

WG is purely the user-intent signal in this setup; proxy traffic goes
mihomo→VLESS direct, not through WG. Treating handshake staleness as a
reason to re-run convergence was killing healthy mihomo every 5 min
whenever the WG peer flapped. Real degradations (mihomo-dead, utun gone,
DNS port silent, fw rule missing) still trigger the recovery path.

EOF
)"
```

---

## Task 5: Final lint pass with shellcheck (if available)

**Files:** none modified; verification only.

**Context:** CI runs shellcheck on push (`.github/workflows/shellcheck.yml`). If shellcheck is installed locally, run it before pushing to catch issues earlier than CI.

- [ ] **Step 1: Check whether shellcheck is installed**

Run: `command -v shellcheck || echo "not installed, skip to Step 3"`

- [ ] **Step 2: Run shellcheck if installed**

Run: `shellcheck -S info -e SC1091 provision-mudi.sh && echo OK`
Expected: `OK` (no findings at info level or above)

If findings appear: read them, fix the script, re-run from Task 1's syntax checks. Do not push with new shellcheck findings.

- [ ] **Step 3: If shellcheck not installed, rely on CI**

CI will run shellcheck on push. If installing locally is desired:
- Debian/Ubuntu: `sudo apt-get install -y shellcheck`
- Arch: `sudo pacman -S shellcheck`
- macOS: `brew install shellcheck`

Then run Step 2.

- [ ] **Step 4: No commit needed for this task**

Nothing changed.

---

## Task 6: On-device manual validation

**Files:** none modified; this task documents the manual verification steps from the spec for the engineer running validation on the actual Mudi.

**Context:** There is no automated way to test the deployed hook. The four scenarios below correspond to spec §Validation. The provisioning script must be re-run on the device to deploy the updated heredocs: `set -a; . ./mudi.env; set +a; sh provision-mudi.sh` from the Mudi after SCPing the updated script.

- [ ] **Step 1: Deploy updated script to Mudi and re-provision**

Run from laptop:
```bash
scp provision-mudi.sh root@192.168.8.1:/tmp/
ssh root@192.168.8.1 'set -a; . /tmp/mudi.env; set +a; sh /tmp/provision-mudi.sh'
```
Expected: provisioning completes without ERROR lines.

- [ ] **Step 2: Scenario A — normal toggle via GL Web UI**

From a LAN device:
1. Open GL Web UI, toggle VPN OFF, wait ~5s
2. Toggle VPN ON, wait ~5s
3. On Mudi: `logread | grep vpn-mode | tail -20`

Expected sequence on toggle ON:
- `WG <iface> up (Global Mode) — preparing mihomo`
- Either `mihomo healthy (pid+utun), skipping restart` (if it was already running for some reason) or no skip line (full restart)
- `OK: utun=Y, 1053-listeners=1, t1001-default=1`

Expected on toggle OFF:
- `WG <iface> down — stopping mihomo`
- `OK: pure direct mode`

- [ ] **Step 3: Scenario B — WG broken deliberately (the target scenario)**

On Mudi:
1. Snapshot mihomo PID: `MIHOMO_PID=$(pidof mihomo); echo "before: $MIHOMO_PID"`
2. Break WG by setting an unreachable peer endpoint. Easiest: temporarily change UCI peer endpoint to `192.0.2.1:51820` (TEST-NET-1):
   ```bash
   ORIG_ENDPOINT=$(uci get network.<wg-peer>.endpoint_host)
   uci set network.<wg-peer>.endpoint_host=192.0.2.1
   uci commit network
   /etc/init.d/network reload
   ```
   (Substitute `<wg-peer>` with the actual UCI key — find via `uci show network | grep endpoint_host`.)
3. Wait 6+ minutes (one full health-check cycle past the 180s staleness threshold)
4. Check: `logread | grep mudi-health | tail -10`
   - Expected: one or more `INFO: WG handshake stale (signal-only, not acting)` lines
   - Expected: **zero** `DEGRADED` lines
5. Check mihomo PID unchanged: `echo "after: $(pidof mihomo)"` — must equal `$MIHOMO_PID`
6. From LAN device: verify proxy still works (open a blocked-in-CN site in a browser)
7. Restore WG:
   ```bash
   uci set network.<wg-peer>.endpoint_host=$ORIG_ENDPOINT
   uci commit network
   /etc/init.d/network reload
   ```

- [ ] **Step 4: Scenario C — mihomo killed deliberately (recovery still works)**

On Mudi:
1. `kill $(pidof mihomo)`
2. `/usr/local/bin/mudi-vpn-health.sh` (manually trigger, don't wait for cron)
3. `logread | grep mudi-health | tail -3`
   - Expected: `DEGRADED: mihomo-dead → re-triggering hook ifup`
4. `pidof mihomo` — expected: a new PID
5. `ip link show utun` — expected: link exists
6. From LAN device: verify proxy works again

- [ ] **Step 5: Scenario D — idempotent re-convergence (no dnsmasq bounce)**

On Mudi, with everything healthy:
1. In one ssh session, start a continuous DNS probe from a LAN host (or from the Mudi itself):
   ```bash
   while true; do dig +short +time=1 +tries=1 @192.168.8.1 example.com || echo "$(date +%H:%M:%S) FAIL"; sleep 0.5; done
   ```
2. In another ssh session, manually trigger ifup:
   ```bash
   INTERFACE="$WG_IFACE" ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode
   ```
   (substitute `$WG_IFACE` from `/etc/mudi-vpn.conf`)
3. Check logs: `logread | grep vpn-mode | tail -5`
   - Expected: `mihomo healthy (pid+utun), skipping restart`
   - Expected: **no** "dnsmasq restart" line in logread (logread won't show one because we skipped the restart)
4. Check the DNS probe: should see no `FAIL` lines during the re-convergence
5. Stop the probe loop

- [ ] **Step 6: Push to remote**

If all four scenarios pass:
```bash
git push origin master
```
CI shellcheck will run on push — wait for the green check before considering the work done.

---

## Self-Review

**Spec coverage check** (against `2026-05-27-decouple-mihomo-from-wg-link-design.md`):

| Spec section | Task |
|---|---|
| Change 1 — mihomo idempotent restart | Task 1 |
| Change 1 — routing table 1001 idempotency | Task 2 |
| Change 1 — ip rule keep as-is | (no-op, intentionally not touched) |
| Change 1 — GL blackhole keep as-is | (no-op, intentionally not touched) |
| Change 1 — dnsmasq idempotency | Task 3 |
| Change 1 — final OK log keep as-is | (no-op, intentionally not touched) |
| Change 2 — health check split | Task 4 |
| Validation §1 normal toggle | Task 6 Step 2 |
| Validation §2 WG broken | Task 6 Step 3 |
| Validation §3 mihomo killed | Task 6 Step 4 |
| Validation §4 idempotent re-convergence | Task 6 Step 5 |
| Non-goals (no new service, etc.) | enforced by file-modification scope |

All spec sections covered. No placeholders. Types/identifiers consistent: `$TUN_DEV`, `$TUN_GW`, `$VPS_LAN`, `$WG_IFACE`, `$DNS_PORT`, `$LAN_NET`, `$LAN_RULE_PREF` — all sourced from `/etc/mudi-vpn.conf` per the script's existing pattern (provision-mudi.sh:379-411).
