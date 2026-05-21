#!/usr/bin/env bash
# update.sh — fetch a mihomo release from GitHub and push it to the Mudi.
# Runs on the laptop side. Doesn't touch any other provision state — config,
# hook, dnsmasq, fw4 rules all stay as they are. Just swaps the binary, then
# re-triggers the hook if VPN is currently ON so mihomo restarts on the new
# binary.
#
# Usage:
#   ./update.sh                       # latest release tag
#   ./update.sh v1.19.24              # pin a specific version
#   MUDI=root@10.0.0.1 ./update.sh    # custom router host

set -euo pipefail

MUDI="${MUDI:-root@192.168.8.1}"
ARCH="${ARCH:-arm64}"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "→ querying latest release tag from github.com/MetaCubeX/mihomo"
    VERSION=$(curl -fsSL --max-time 10 \
        https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        | grep -oE '"tag_name": *"v[0-9.]+"' \
        | head -1 \
        | grep -oE 'v[0-9.]+') || {
            echo "ERROR: could not fetch latest version; specify one: $0 v1.19.24"
            exit 1
        }
fi

URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/mihomo-linux-${ARCH}-${VERSION}.gz"
TMP=$(mktemp -d)
# shellcheck disable=SC2064  # we want $TMP expanded now, not at signal time
trap "rm -rf $TMP" EXIT

echo "→ downloading $URL"
curl -fL --max-time 120 "$URL" -o "$TMP/mihomo.gz"
gunzip "$TMP/mihomo.gz"
chmod +x "$TMP/mihomo"

NEW_VER=$("$TMP/mihomo" -v 2>&1 | head -1 || echo "unknown")
echo "→ downloaded $NEW_VER ($(du -h "$TMP/mihomo" | cut -f1))"

echo "→ pushing to $MUDI"
scp -q "$TMP/mihomo" "$MUDI:/tmp/mihomo.new"

echo "→ swapping binary on router and reloading"
ssh "$MUDI" 'set -e
    OLD=$(/usrdata/proxy/bin/mihomo -v 2>/dev/null | head -1 || echo "(none)")
    /etc/init.d/mihomo stop 2>/dev/null || true
    pkill -9 mihomo 2>/dev/null || true
    mv /tmp/mihomo.new /usrdata/proxy/bin/mihomo
    chmod 755 /usrdata/proxy/bin/mihomo
    NEW=$(/usrdata/proxy/bin/mihomo -v 2>/dev/null | head -1)
    echo "  old: $OLD"
    echo "  new: $NEW"

    # If VPN is ON in Global mode, re-trigger the hook so mihomo restarts
    # on the new binary with all the route/dnsmasq plumbing intact.
    if [ "$(uci -q get wireguard.global.global_proxy)" = "1" ] \
       && [ "$(uci -q get network.wgclient1.disabled)" != "1" ]; then
        echo "  VPN is ON → re-triggering hook ifup to restart mihomo"
        INTERFACE=wgclient1 ACTION=ifup /etc/hotplug.d/iface/99-vpn-mode
        sleep 2
        if pidof mihomo >/dev/null; then
            echo "  ✓ mihomo running again"
        else
            echo "  ⚠ mihomo not running — check logread -e vpn-mode"
        fi
    else
        echo "  VPN is OFF → mihomo will pick up new binary next time you toggle ON"
    fi
'
