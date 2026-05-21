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

# Headscale (optional self-hosted Tailscale control plane). Leave empty to skip.
HEADSCALE_URL="${HEADSCALE_URL:-https://${VPS_HOST}:9443}"
HEADSCALE_AUTHKEY="${HEADSCALE_AUTHKEY:-}"

# VLESS+REALITY (primary proxy). Generate UUID/pubkey/shortid on the VPS with
# `sing-box generate uuid` / `sing-box generate reality-keypair`.
VLESS_PORT="${VLESS_PORT:-8443}"
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
    url: "http://www.gstatic.com/generate_204"
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
# - ifup + Global Mode (wireguard.global.global_proxy=1):
#     1. Kill any stray mihomo (clean slate)
#     2. Start mihomo via procd
#     3. Wait for utun + port 1053 listening
#     4. Override table 1001 (default→utun, 10.20.0.0/24→wgclient)
#     5. Add source-based ip rule (LAN → table 1001)
#     6. Remove GL blackhole rules
#     7. Switch dnsmasq to mihomo with strict_order
# - ifup + Policy Mode → no-op (reserved for UU)
# - ifdown → stop mihomo, remove rule, restore dnsmasq

case "$INTERFACE" in wgclient*) ;; *) exit 0 ;; esac

LAN_NET="192.168.8.0/24"
LAN_RULE_PREF=6500

case "$ACTION" in
    ifup)
        GLOBAL=$(uci -q get wireguard.global.global_proxy 2>/dev/null)
        if [ "$GLOBAL" != "1" ]; then
            logger -t vpn-mode "WG $INTERFACE up (Policy Mode) — mihomo stays off"
            exit 0
        fi
        logger -t vpn-mode "WG $INTERFACE up (Global Mode) — preparing mihomo"

        pkill -9 mihomo 2>/dev/null
        sleep 1
        /etc/init.d/mihomo start

        for i in 1 2 3 4 5 6 7 8 9 10; do
            ip link show utun >/dev/null 2>&1 && break
            sleep 1
        done
        for i in 1 2 3 4 5 6 7 8 9 10; do
            netstat -tln 2>/dev/null | grep -q ":1053 " && break
            sleep 1
        done

        ip route flush table 1001 2>/dev/null
        ip route add 10.20.0.0/24 dev "$INTERFACE" table 1001 2>/dev/null
        ip route add default via 198.18.0.2 dev utun table 1001

        ip rule del from "$LAN_NET" lookup 1001 pref $LAN_RULE_PREF 2>/dev/null
        ip rule add from "$LAN_NET" lookup 1001 pref $LAN_RULE_PREF

        ip rule del iif br-lan blackhole pref 9920 2>/dev/null
        ip rule del pref 9910 2>/dev/null

        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci add_list dhcp.@dnsmasq[0].server="127.0.0.1#1053"
        uci add_list dhcp.@dnsmasq[0].server="223.5.5.5"
        uci set dhcp.@dnsmasq[0].strict_order="1"
        uci commit dhcp
        /etc/init.d/dnsmasq restart

        UTUN_OK=$(ip link show utun >/dev/null 2>&1 && echo Y || echo N)
        P1053=$(netstat -tln 2>/dev/null | grep -c ":1053 ")
        logger -t vpn-mode "OK: utun=$UTUN_OK, 1053-listeners=$P1053, table1001-default=$(ip route show table 1001 | grep -c default)"
        ;;

    ifdown)
        logger -t vpn-mode "WG $INTERFACE down — stopping mihomo"
        /etc/init.d/mihomo stop 2>/dev/null
        pkill -9 mihomo 2>/dev/null
        ip rule del from "$LAN_NET" lookup 1001 pref $LAN_RULE_PREF 2>/dev/null
        uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci -q delete dhcp.@dnsmasq[0].strict_order 2>/dev/null
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
# Phase 9: Tailscale → Headscale (optional, skipped if HEADSCALE_AUTHKEY unset)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "========================================="
echo "Phase 9: Tailscale → Headscale (optional)"
echo "========================================="
if [ -z "${HEADSCALE_AUTHKEY}" ]; then
    echo "HEADSCALE_AUTHKEY not set, skipping Tailscale/Headscale setup"
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
    tailscale up \
        --login-server="${HEADSCALE_URL}" \
        --authkey="${HEADSCALE_AUTHKEY}" \
        --accept-routes \
        --accept-dns=false \
        --reset 2>&1 | head -3 || echo "(Tailscale login may need retry once mihomo is up)"
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
