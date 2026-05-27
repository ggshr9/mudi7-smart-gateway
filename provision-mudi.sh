#!/bin/sh
# provision-mudi.sh — v2 — Take a factory-reset GL.iNet Mudi 7 to baseline.
#
# Design (revised 2026-05-20 after debugging GL VPN framework conflicts):
#
#   State machine:
#     VPN OFF              → mihomo NOT running, dnsmasq → Aliyun DNS, pure direct
#     VPN ON + Global Mode → mihomo running, dnsmasq → mihomo, smart split routing
#     VPN ON + Policy Mode → mihomo NOT running (reserved for UU later)
#
#   Critical principle: don't touch GL's VPN policy framework structurally.
#   Just react to its events via hotplug hook + a minimal table 1001 override.
#
# Run ON the Mudi: scp this file, then `sh /tmp/provision-mudi.sh`

set -e

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — all secrets driven by environment variables.
# Put your real values in a separate .env file (not committed) and source it
# before running, e.g.:
#     set -a; . ./mudi.env; set +a; ./provision-mudi.sh
# See README.md for the full list of required variables.
# ─────────────────────────────────────────────────────────────────────────────
VPS_HOST="${VPS_HOST:?Set VPS_HOST (e.g. proxy.example.com)}"
VPS_IP="${VPS_IP:?Set VPS_IP (your VPS public IPv4)}"

# Tailscale (optional). Defaults to the official control plane — set
# TS_LOGIN_SERVER to your own Headscale URL to use self-hosted instead. The
# tailscale daemon below is wired to use mihomo's HTTP proxy, so the official
# login.tailscale.com is reachable from CN networks as long as VPN is ON.
TS_LOGIN_SERVER="${TS_LOGIN_SERVER:-https://login.tailscale.com}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

# VLESS+REALITY (primary proxy). Generate UUID/pubkey/shortid on the VPS with
# `sing-box generate uuid` / `sing-box generate reality-keypair`.
VLESS_PORT="${VLESS_PORT:-443}"
VLESS_UUID="${VLESS_UUID:?Set VLESS_UUID (uuid from sing-box generate uuid)}"
VLESS_PUBKEY="${VLESS_PUBKEY:?Set VLESS_PUBKEY (Reality public key from VPS)}"
VLESS_SHORTID="${VLESS_SHORTID:?Set VLESS_SHORTID (Reality short ID)}"
VLESS_SNI="${VLESS_SNI:-www.microsoft.com}"

# Hysteria-2 (fallback proxy).
HY2_PORT="${HY2_PORT:-443}"
HY2_PASSWORD="${HY2_PASSWORD:?Set HY2_PASSWORD}"
HY2_SNI="${HY2_SNI:-$VPS_HOST}"

# mihomo external-controller API secret (LAN-only API; still a token, change it).
API_SECRET="${API_SECRET:-change-me-mihomo-api}"

MIHOMO_VER="${MIHOMO_VER:-v1.19.24}"
MIHOMO_ARCH="${MIHOMO_ARCH:-arm64}"
CN_CIDR_URL="${CN_CIDR_URL:-https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt}"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: system prep — minimal touches to GL stock
# ─────────────────────────────────────────────────────────────────────────────
echo "========================================="
echo "Phase 1: system prep"
echo "========================================="
opkg update 2>&1 | tail -3
opkg install ip-full kmod-tun curl wget ca-bundle ca-certificates 2>&1 | tail -3

# Disable AGH — mihomo's own filters handle blocklists if needed
/etc/init.d/adguardhome stop 2>/dev/null || true
/etc/init.d/adguardhome disable 2>/dev/null || true
echo "AGH disabled (mihomo has built-in blocking if needed)"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: install mihomo binary (but DON'T enable at boot)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 2: mihomo binary install"
echo "========================================="
mkdir -p /usrdata/proxy/bin /usrdata/proxy/etc /usrdata/proxy/etc/ui /usrdata/proxy/etc/rules

if [ -x /usrdata/proxy/bin/mihomo ]; then
    CUR=$(/usrdata/proxy/bin/mihomo -v 2>/dev/null | head -1 | grep -oE 'v[0-9.]+' | head -1)
    [ "$CUR" = "$MIHOMO_VER" ] && echo "mihomo $CUR already installed" || NEED=1
else
    NEED=1
fi

if [ "$NEED" = "1" ]; then
    cd /tmp
    URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VER}.gz"
    echo "downloading $URL"
    wget -q -O mihomo.gz "$URL" || {
        echo "ERROR: github download failed (likely network). SCP binary from laptop instead."
        echo "Run on laptop: cat mihomo-arm64.gz | ssh -p 22 root@192.168.8.1 'gunzip > /usrdata/proxy/bin/mihomo; chmod 755 /usrdata/proxy/bin/mihomo'"
        exit 1
    }
    gunzip -f mihomo.gz
    install -m 755 mihomo /usrdata/proxy/bin/mihomo
    rm -f /tmp/mihomo.gz /tmp/mihomo
fi
/usrdata/proxy/bin/mihomo -v | head -1

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: mihomo config
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 3: mihomo config"
echo "========================================="
cat > /usrdata/proxy/etc/config.yaml << EOF
###############################################################
# Mihomo (Clash.Meta) — GL.iNet Mudi 7 — provisioned v2
# Architecture: only runs when VPN ON + Global Mode (started by hotplug hook)
###############################################################

geo-auto-update: false

mixed-port: 7890
allow-lan: true
bind-address: '*'
mode: rule
log-level: warning
ipv6: false
unified-delay: true
routing-mark: 524288

external-controller: 0.0.0.0:9090
external-ui: ./ui
secret: ${API_SECRET}

profile:
  store-selected: true
  store-fake-ip: false

tun:
  enable: true
  device: utun
  stack: gvisor
  dns-hijack:
    - any:53
  auto-route: true
  auto-detect-interface: true
  inet4-route-exclude-address:
    - 100.64.0.0/10        # Tailscale CGNAT
    - 10.20.0.0/24         # WG to VPS subnet
    - 169.254.0.0/16       # USB link-local
    - 192.168.50.0/24      # GL admin alt subnet
    - ${VPS_IP}/32         # proxy server (prevent self-tunneling)
  inet6-route-exclude-address:
    - fc00::/7
    - fe80::/10

dns:
  enable: true
  prefer-h3: false
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - '*.lan'
    - '*.local'
    - '*.localdomain'
    - '*.internal'
    - '+.ts.net'
    - '*.${VPS_HOST#*.}'
    - '+.gl-inet.com'
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  proxy-server-nameserver:
    - https://doh.pub/dns-query
    - 223.5.5.5
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
    - 223.5.5.5
  fallback:
    - "https://1.1.1.1/dns-query#PROXY"
    - "https://dns.google/dns-query#PROXY"
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
      - 0.0.0.0/32

proxies:
  - name: vless-reality
    type: vless
    server: ${VPS_HOST}
    port: ${VLESS_PORT}
    uuid: ${VLESS_UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${VLESS_SNI}
    reality-opts:
      public-key: ${VLESS_PUBKEY}
      short-id: ${VLESS_SHORTID}
    client-fingerprint: chrome

  - name: hysteria-2
    type: hysteria2
    server: ${VPS_HOST}
    port: ${HY2_PORT}
    password: ${HY2_PASSWORD}
    sni: ${HY2_SNI}
    alpn:
      - h3

proxy-groups:
  - name: "PROXY"
    type: url-test
    proxies:
      - vless-reality
      - hysteria-2
    # HTTPS, not HTTP — gstatic redirects http→https and mihomo's url-test
    # treats redirects as failures, causing spurious PROXY-failed flapping.
    url: "https://www.gstatic.com/generate_204"
    interval: 60
    tolerance: 50

rules:
  # cn-bypass.nft handles the bulk CN/foreign split at netfilter level.
  # Inner rules below are for traffic that does enter mihomo.
  - 'DOMAIN-SUFFIX,cn,DIRECT'
  - 'DOMAIN-KEYWORD,baidu,DIRECT'
  - 'DOMAIN-KEYWORD,taobao,DIRECT'
  - 'DOMAIN-KEYWORD,weibo,DIRECT'
  - 'DOMAIN-KEYWORD,bilibili,DIRECT'
  - 'DOMAIN-KEYWORD,qq,DIRECT'
  - 'MATCH,PROXY'
EOF

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: cn-bypass.nft + CIDR subscription (always loaded, harmless when no mihomo)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 4: cn-bypass + CIDR cron"
echo "========================================="
mkdir -p /usr/share/nftables.d/ruleset-post

# mihomo TUN forwarding (br-lan ↔ utun)
# Without these, fw4 forward chain falls through to handle_reject and sends TCP RST
# back to LAN clients (silent failure - only Mudi-local curl works since that uses OUTPUT).
# Use `insert` so they land at the chain head, before any zone jumps.
cat > /usr/share/nftables.d/ruleset-post/utun-forward.nft << 'NFT_EOF'
insert rule inet fw4 forward iifname "utun" oifname "br-lan" counter accept comment "mihomo TUN reply"
insert rule inet fw4 forward iifname "br-lan" oifname "utun" counter accept comment "mihomo TUN ingress"
NFT_EOF
chmod 644 /usr/share/nftables.d/ruleset-post/utun-forward.nft

cat > /usr/share/nftables.d/ruleset-post/cn-bypass.nft << 'NFT_EOF'
# CN IP set — marks LAN packets to CN IPs so they skip mihomo TUN
# Idempotent three-stage pattern (kernel 5.15 has no `destroy table`)
table inet cn_bypass { }
delete table inet cn_bypass
table inet cn_bypass {
    set cncidr_v4 {
        type ipv4_addr
        flags interval
        auto-merge
    }
    chain prerouting {
        type filter hook prerouting priority mangle - 10;
        iifname "br-lan" ip daddr @cncidr_v4 meta mark set 0x80000 comment "cn-bypass"
    }
}
NFT_EOF

mkdir -p /usr/local/bin
cat > /usr/local/bin/update-cn-cidr.sh << UPDATE_EOF
#!/bin/sh
# Pull CN CIDR list, write chunked add-element statements that fw4 loads.
# This survives fw4 reloads.
set -e
TMPFILE=\$(mktemp)
trap "rm -f \$TMPFILE" EXIT

curl -fsSL --max-time 30 "${CN_CIDR_URL}" -o "\$TMPFILE" || exit 1
TOTAL=\$(grep -v "^#" "\$TMPFILE" | grep -c "[0-9]")
[ "\$TOTAL" -lt 100 ] && { logger -t cn-cidr-update "list too small (\$TOTAL), abort"; exit 1; }

OUTFILE=/usr/share/nftables.d/ruleset-post/cn-cidr-elements.nft
{
    echo "# Auto-generated. \$TOTAL CIDRs from 17mon/china_ip_list"
    awk '\''
        BEGIN { chunk = ""; n = 0 }
        NF > 0 && !/^#/ {
            chunk = chunk \$1 ", "
            n++
            if (n >= 500) {
                sub(/, \$/, "", chunk)
                print "add element inet cn_bypass cncidr_v4 { " chunk " }"
                chunk = ""; n = 0
            }
        }
        END {
            if (n > 0) {
                sub(/, \$/, "", chunk)
                print "add element inet cn_bypass cncidr_v4 { " chunk " }"
            }
        }
    '\'' "\$TMPFILE"
} > "\$OUTFILE"

fw4 reload >/dev/null 2>&1
FINAL=\$(nft -j list set inet cn_bypass cncidr_v4 2>/dev/null | grep -oE '\\"prefix\\"|\\"range\\"' | wc -l)
logger -t cn-cidr-update "downloaded=\$TOTAL, set has \$FINAL entries"
echo "set=\$FINAL entries"
UPDATE_EOF
chmod 755 /usr/local/bin/update-cn-cidr.sh

# Cron: daily + @reboot
mkdir -p /etc/crontabs
grep -q update-cn-cidr /etc/crontabs/root 2>/dev/null || {
    cat >> /etc/crontabs/root << CRON_EOF
0 3 * * * /usr/local/bin/update-cn-cidr.sh
@reboot sleep 30 && /usr/local/bin/update-cn-cidr.sh
CRON_EOF
    /etc/init.d/cron restart
}

# Initial sync
echo "initial CIDR sync..."
/usr/local/bin/update-cn-cidr.sh || echo "WARN: initial sync failed, will retry @reboot"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: /etc/hosts (static brook server address — robust to upstream DNS quirks)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 5: /etc/hosts"
echo "========================================="
if ! grep -q "${VPS_HOST}" /etc/hosts; then
    echo "${VPS_IP}   ${VPS_HOST}   # provisioned static" >> /etc/hosts
    echo "added ${VPS_HOST} → ${VPS_IP}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: mihomo init.d service (but NOT enabled — only started by hook)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 6: mihomo service (not auto-start)"
echo "========================================="
cat > /etc/init.d/mihomo << 'INIT_EOF'
#!/bin/sh /etc/rc.common
# mihomo procd service. Started ONLY by /etc/hotplug.d/iface/99-vpn-mode hook
# when VPN ON + Global Mode is active. Do NOT enable for boot — by design.
START=95
STOP=15
USE_PROCD=1

start_service() {
    procd_open_instance mihomo
    procd_set_param command /usrdata/proxy/bin/mihomo -d /usrdata/proxy/etc
    procd_set_param respawn 60 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param limits nofile=65535
    procd_close_instance
}

reload_service() {
    curl -sS -X PUT "http://127.0.0.1:9090/configs?force=true" \
        -H "Authorization: Bearer __API_SECRET__" \
        -H "Content-Type: application/json" \
        -d '{"path":"/usrdata/proxy/etc/config.yaml"}'
}
INIT_EOF
# Substitute the API secret into the init.d (heredoc is single-quoted to keep
# shell vars literal, so we patch the placeholder afterwards).
sed -i "s|__API_SECRET__|${API_SECRET}|g" /etc/init.d/mihomo
chmod 755 /etc/init.d/mihomo
# Explicitly NOT enabling — by design

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6.5: /etc/mudi-vpn.conf — fixed tunables for hook + health check.
# Anything derived from live system state (e.g. LAN_NET) is NOT here — the
# hook recomputes those at runtime so subnet changes via GL Web UI take
# effect on the next VPN toggle without re-running this script.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 6.5: VPN config file (fixed tunables)"
echo "========================================="
cat > /etc/mudi-vpn.conf << 'CFG_EOF'
# Sourced by /etc/hotplug.d/iface/99-vpn-mode and /usr/local/bin/mudi-vpn-health.sh
# LAN_NET is intentionally NOT here — hook computes it from network.lan.ipaddr
# every time so changing the LAN subnet via GL Web UI doesn't break routing.
WG_IFACE="wgclient1"
TUN_DEV="utun"
TUN_GW="198.18.0.2"        # mihomo fake-ip-range second IP (next-hop on utun)
VPS_LAN="10.20.0.0/24"     # WG peer's LAN subnet
LAN_RULE_PREF=6500
DNS_PORT=1053              # mihomo DNS listen port
CFG_EOF
chmod 644 /etc/mudi-vpn.conf
echo "wrote /etc/mudi-vpn.conf (LAN_NET derived at hook runtime)"

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: dnsmasq default upstream (Aliyun + DNSPod, used when VPN is OFF)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 7: dnsmasq default upstream"
echo "========================================="
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
uci add_list dhcp.@dnsmasq[0].server="119.29.29.29"
uci set dhcp.@dnsmasq[0].noresolv="1"

# Also fix wgclient1's dnsmasq (port 2153, target of GL's "VPN-aware" DNS hijack):
# GL DNAT'd LAN DNS queries with mark 0x1000 → port 2153 when VPN is ON.
# By default it queries 223.5.5.5/119.29.29.29 → returns REAL IPs → fake-IP bypass + foreign
# domains unreachable. Point it at mihomo's 1053 (with public DNS as strict-order fallback).
if uci -q get dhcp.wgclient1 >/dev/null; then
    uci -q delete dhcp.wgclient1.server
    uci add_list dhcp.wgclient1.server="127.0.0.1#1053"
    uci add_list dhcp.wgclient1.server="223.5.5.5"
    uci set dhcp.wgclient1.strictorder="1"
fi

uci commit dhcp
/etc/init.d/dnsmasq restart

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8: VPN mode hotplug hook — the heart of this architecture
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 8: VPN mode hotplug hook"
echo "========================================="
cat > /etc/hotplug.d/iface/99-vpn-mode << 'HOOK_EOF'
#!/bin/sh
# Three-state machine reactor (GL.iNet Mudi 7 + mihomo)
# All tunables in /etc/mudi-vpn.conf — edit there and re-trigger this hook to apply.
# - ifup + Global Mode (wireguard.global.global_proxy=1):
#     1. Kill stray mihomo, start via procd, wait for utun + DNS port
#     2. Bail if utun never appears (no point continuing)
#     3. Override table 1001 (default→utun, VPS LAN→wgclient)
#     4. Add source-based ip rule (LAN → table 1001)
#     5. Remove GL blackhole rules
#     6. Switch dnsmasq to mihomo with strict-order
# - ifup + Policy Mode → no-op (reserved for UU)
# - ifdown → stop mihomo, remove rule, restore dnsmasq

. /etc/mudi-vpn.conf 2>/dev/null || {
    logger -t vpn-mode "ERROR: /etc/mudi-vpn.conf missing; refusing to run"
    exit 1
}

# LAN subnet recomputed at runtime so GL Web UI subnet changes (e.g. moving
# from 192.168.8.0/24 to 10.0.0.0/24) propagate without re-provisioning.
# Only /24 LAN is supported here; adjust the awk if you use something weirder.
LAN_IP=$(uci -q get network.lan.ipaddr || echo "192.168.8.1")
LAN_NET=$(echo "$LAN_IP" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')

# Only react to OUR WG interface
[ "$INTERFACE" = "$WG_IFACE" ] || exit 0

case "$ACTION" in
    ifup)
        GLOBAL=$(uci -q get wireguard.global.global_proxy 2>/dev/null)
        if [ "$GLOBAL" != "1" ]; then
            logger -t vpn-mode "WG $INTERFACE up (Policy Mode) — mihomo stays off"
            exit 0
        fi
        logger -t vpn-mode "WG $INTERFACE up (Global Mode) — preparing mihomo"

        if pidof mihomo >/dev/null && ip link show "$TUN_DEV" >/dev/null 2>&1; then
            logger -t vpn-mode "mihomo healthy (pid+utun), skipping restart"
        else
            pkill -9 mihomo 2>/dev/null
            sleep 1
            /etc/init.d/mihomo start
        fi

        for i in 1 2 3 4 5 6 7 8 9 10; do
            ip link show "$TUN_DEV" >/dev/null 2>&1 && break
            sleep 1
        done
        for i in 1 2 3 4 5 6 7 8 9 10; do
            netstat -tln 2>/dev/null | grep -q ":${DNS_PORT} " && break
            sleep 1
        done

        if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
            logger -t vpn-mode "ERROR: $TUN_DEV never appeared, aborting hook"
            exit 1
        fi

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

        ip rule del from "$LAN_NET" lookup 1001 pref "$LAN_RULE_PREF" 2>/dev/null
        ip rule add from "$LAN_NET" lookup 1001 pref "$LAN_RULE_PREF"

        ip rule del iif br-lan blackhole pref 9920 2>/dev/null
        ip rule del pref 9910 2>/dev/null

        WANT_SERVER="127.0.0.1#${DNS_PORT}"
        if ! uci -q show dhcp 2>/dev/null | grep -qF "dhcp.@dnsmasq[0].server='${WANT_SERVER}'"; then
            uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
            uci add_list dhcp.@dnsmasq[0].server="${WANT_SERVER}"
            uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
            uci set dhcp.@dnsmasq[0].strictorder="1"
            uci commit dhcp
            /etc/init.d/dnsmasq restart
        fi

        UTUN_OK=$(ip link show "$TUN_DEV" >/dev/null 2>&1 && echo Y || echo N)
        PDNS=$(netstat -tln 2>/dev/null | grep -c ":${DNS_PORT} ")
        logger -t vpn-mode "OK: ${TUN_DEV}=${UTUN_OK}, ${DNS_PORT}-listeners=${PDNS}, t1001-default=$(ip route show table 1001 | grep -c default)"
        ;;

    ifdown)
        logger -t vpn-mode "WG $INTERFACE down — stopping mihomo"
        /etc/init.d/mihomo stop 2>/dev/null
        pkill -9 mihomo 2>/dev/null
        ip rule del from "$LAN_NET" lookup 1001 pref "$LAN_RULE_PREF" 2>/dev/null
        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci -q delete dhcp.@dnsmasq[0].strictorder 2>/dev/null
        uci -q delete dhcp.@dnsmasq[0].strict_order 2>/dev/null  # legacy key cleanup
        uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
        uci add_list dhcp.@dnsmasq[0].server="119.29.29.29"
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        logger -t vpn-mode "OK: pure direct mode"
        ;;
esac
HOOK_EOF
chmod 755 /etc/hotplug.d/iface/99-vpn-mode

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8.5: VPN health check (cron every 5 min, recovers from mihomo crash /
# stale WG handshake / dropped forward rule). Only acts when VPN is supposed
# to be ON in Global Mode — silently no-ops in VPN OFF / Policy Mode.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 8.5: VPN health check + recovery"
echo "========================================="
cat > /usr/local/bin/mudi-vpn-health.sh << 'HEALTH_EOF'
#!/bin/sh
. /etc/mudi-vpn.conf 2>/dev/null || exit 0

# Don't act if user has VPN OFF or in Policy Mode
GLOBAL=$(uci -q get wireguard.global.global_proxy)
WG_DISABLED=$(uci -q get "network.${WG_IFACE}.disabled")
[ "$GLOBAL" != "1" ] && exit 0
[ "$WG_DISABLED" = "1" ] && exit 0

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
HEALTH_EOF
chmod 755 /usr/local/bin/mudi-vpn-health.sh

# Cron entry — every 5 min
grep -q mudi-vpn-health /etc/crontabs/root 2>/dev/null || {
    echo "*/5 * * * * /usr/local/bin/mudi-vpn-health.sh" >> /etc/crontabs/root
    /etc/init.d/cron restart
    echo "installed mudi-vpn-health cron (every 5 min)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8.6: mudi-snapshot — bundle current state into a tar.gz for backup.
# Use before risky changes / factory reset. Output is mode 600 because it
# contains secrets (WG private key, mihomo API token, VLESS UUID, etc.);
# pass --redact to strip them for a sharable diagnostic bundle.
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 8.6: snapshot tool"
echo "========================================="
cat > /usr/local/bin/mudi-snapshot.sh << 'SNAP_EOF'
#!/bin/sh
# Usage:
#   mudi-snapshot.sh                       → full snapshot (contains secrets)
#   mudi-snapshot.sh --redact              → strip secrets, safe to share
#   mudi-snapshot.sh /path/to/file.tar.gz  → custom output path
set -u

REDACT=""
OUT=""
for arg in "$@"; do
    case "$arg" in
        --redact) REDACT=1 ;;
        --help|-h)
            echo "Usage: $0 [--redact] [output.tar.gz]"
            exit 0
            ;;
        *) OUT="$arg" ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M%S)
SUFFIX=""
[ -n "$REDACT" ] && SUFFIX="-redacted"
OUT="${OUT:-/tmp/mudi-snapshot-${STAMP}${SUFFIX}.tar.gz}"

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT
cd "$WORK"
mkdir state etc nftables runtime logs

# --- Metadata ---
{
    echo "snapshot-time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname: $(uname -n)"
    echo "kernel: $(uname -r)"
    grep -E "DISTRIB_(ID|RELEASE|REVISION)" /etc/openwrt_release 2>/dev/null
    echo "mihomo: $(/usrdata/proxy/bin/mihomo -v 2>/dev/null | head -1)"
    echo "redacted: ${REDACT:-no}"
} > state/info.txt

# --- Persistent config ---
uci export    > etc/uci-export.txt 2>/dev/null
uci show      > etc/uci-show.txt   2>/dev/null
cp /etc/mudi-vpn.conf                    etc/                  2>/dev/null
cp /etc/hotplug.d/iface/99-vpn-mode      etc/                  2>/dev/null
cp /etc/init.d/mihomo                    etc/init.d-mihomo     2>/dev/null
cp /etc/crontabs/root                    etc/crontabs-root     2>/dev/null
cp /usrdata/proxy/etc/config.yaml        etc/mihomo-config.yaml 2>/dev/null
cp /etc/hosts                            etc/                  2>/dev/null
cp /usr/local/bin/mudi-vpn-health.sh     etc/                  2>/dev/null
cp /usr/local/bin/update-cn-cidr.sh      etc/                  2>/dev/null

# --- nftables persistent rules ---
cp -r /usr/share/nftables.d/ruleset-post nftables/post 2>/dev/null

# --- Live runtime state ---
ip rule show                                          > runtime/ip-rule.txt 2>&1
ip route show table all                               > runtime/ip-route-all.txt 2>&1
ip -4 addr show                                       > runtime/ip-addr.txt 2>&1
ip link show                                          > runtime/ip-link.txt 2>&1
nft list ruleset                                      > runtime/nft-ruleset.txt 2>&1
wg show all                                           > runtime/wg-show.txt 2>&1
ps w                                                  > runtime/ps.txt 2>&1
netstat -tlnp                                         > runtime/netstat-tcp.txt 2>&1
netstat -ulnp                                         > runtime/netstat-udp.txt 2>&1
cat /proc/net/nf_conntrack 2>/dev/null | head -200    > runtime/conntrack-head200.txt 2>&1
iw dev wlan1 station dump                             > runtime/iw-stations.txt 2>&1
iw dev wlan4 link                                     > runtime/iw-upstream.txt 2>&1
cat /tmp/dhcp.leases                                  > runtime/dhcp-leases.txt 2>&1

# --- Recent logs ---
logread -e vpn-mode    > logs/vpn-mode.log 2>&1
logread -e mudi-health > logs/mudi-health.log 2>&1
logread -e mihomo      > logs/mihomo.log 2>&1
logread | tail -200    > logs/syslog-tail.log 2>&1

# --- Redact secrets if requested ---
if [ -n "$REDACT" ]; then
    # WG private keys (UCI + /etc/wireguard if any)
    sed -i "s/private_key='[^']*'/private_key='<REDACTED>'/g; s/PrivateKey *= *[^[:space:]]*/PrivateKey = <REDACTED>/g" \
        etc/uci-export.txt etc/uci-show.txt 2>/dev/null

    # mihomo config: UUID, PubKey, ShortID, password, API secret
    sed -i "s/uuid: *.*/uuid: <REDACTED>/g; s/public-key: *.*/public-key: <REDACTED>/g; s/short-id: *.*/short-id: <REDACTED>/g; s/password: *.*/password: <REDACTED>/g; s/secret: *.*/secret: <REDACTED>/g" \
        etc/mihomo-config.yaml 2>/dev/null

    # Bearer token in init.d/mihomo
    sed -i "s/Bearer [^\"\\']*/Bearer <REDACTED>/g" etc/init.d-mihomo 2>/dev/null

    # MAC addresses in logs / station dumps (privacy)
    sed -i -E "s/([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/<MAC>/g" \
        runtime/iw-stations.txt runtime/dhcp-leases.txt 2>/dev/null
fi

tar czf "$OUT" -C "$WORK" .
chmod 600 "$OUT"

SIZE=$(du -h "$OUT" 2>/dev/null | awk '{print $1}')
echo "snapshot: $OUT ($SIZE)"
if [ -z "$REDACT" ]; then
    echo "  ⚠  contains secrets — DO NOT share. Re-run with --redact for a"
    echo "     sharable version (UUIDs/keys/MACs stripped)."
fi
echo
echo "to download:"
echo "  scp root@\$(uci get network.lan.ipaddr 2>/dev/null || echo 192.168.8.1):$OUT ./"
SNAP_EOF
chmod 755 /usr/local/bin/mudi-snapshot.sh

# ─────────────────────────────────────────────────────────────────────────────
# Phase 9: Tailscale (optional, skipped if TS_AUTHKEY unset)
# Defaults to the official Tailscale control plane. To use self-hosted
# Headscale instead, set TS_LOGIN_SERVER=https://your-headscale-host:port
# in mudi.env before running. The daemon is wired to use mihomo's HTTP proxy
# so login.tailscale.com is reachable from CN networks (when VPN is ON).
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 9: Tailscale (optional)"
echo "========================================="
if [ -z "${TS_AUTHKEY}" ]; then
    echo "TS_AUTHKEY not set, skipping Tailscale setup"
else
    TS_INIT=/etc/init.d/tailscale
    if [ -f "$TS_INIT" ] && ! grep -q "HTTPS_PROXY" "$TS_INIT"; then
        # When mihomo is OFF (VPN OFF), this proxy points to nothing, so
        # tailscaled would fail to reach control plane until mihomo comes up.
        sed -i 's|procd_set_param env TS_DEBUG_FIREWALL_MODE=auto|procd_set_param env TS_DEBUG_FIREWALL_MODE=auto HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890|' "$TS_INIT"
        echo "patched $TS_INIT with HTTPS_PROXY (works when mihomo is up)"
    fi

    uci set tailscale.settings.enabled='1'
    uci commit tailscale
    /etc/init.d/tailscale enable
    /etc/init.d/tailscale restart
    sleep 3
    # --force-reauth is needed when switching between login servers
    # (e.g. moving from Headscale back to official Tailscale).
    tailscale up \
        --reset \
        --force-reauth \
        --login-server="${TS_LOGIN_SERVER}" \
        --authkey="${TS_AUTHKEY}" \
        --accept-routes \
        --accept-dns=false 2>&1 | head -3 || echo "(Tailscale login may need retry once mihomo is up)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Phase 10: report
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "PROVISIONING COMPLETE"
echo "========================================="
echo
echo "State machine ready:"
echo "  VPN OFF              → pure direct routing (mihomo not running)"
echo "  VPN ON + Global Mode → mihomo handles foreign, cn-bypass keeps CN direct"
echo "  VPN ON + Policy Mode → reserved (UU game accel goes here)"
echo
echo "Next manual steps:"
echo "  1. In GL Web UI (http://192.168.8.1), navigate VPN → WireGuard Client"
echo "  2. Click +Add Manually, configure with:"
echo "       Endpoint: ${VPS_IP}:39753"
echo "       Address:  10.20.0.2/32"
echo "       AllowedIPs: 10.20.0.0/24"
echo "       MTU: 1408"
echo "       (PrivateKey: let GL generate)"
echo "  3. Set Mode = Global"
echo "  4. Once saved, GL will show the generated Public Key."
echo "     Tell me that pubkey so I sync VPS WG peer config."
echo "  5. Toggle VPN ON (screen or Web UI) → test foreign access from phone"
echo
echo "Dashboard (when VPN is ON):"
echo "  http://192.168.8.1:9090/ui/   secret: ${API_SECRET}"
