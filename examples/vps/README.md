# VPS-side setup

Sanitized templates of what runs on the VPS that the Mudi connects to.
The Mudi `provision-mudi.sh` script assumes these are already in place.

| File | Where it lives on the VPS |
| --- | --- |
| [sing-box.config.json](sing-box.config.json) | `/etc/sing-box/config.json` |
| [wg0.conf](wg0.conf) | `/etc/wireguard/wg0.conf` |

## One-time prep on a fresh Ubuntu/Debian VPS

```bash
# 1. Install sing-box (1.10+ recommended)
curl -fsSL https://sing-box.app/install.sh | bash
# or download the deb from https://github.com/SagerNet/sing-box/releases

# 2. Install wireguard
apt update && apt install -y wireguard-tools

# 3. Install Let's Encrypt (needed for Hysteria-2 TLS)
apt install -y certbot
certbot certonly --standalone -d YOUR_VPS_DOMAIN
```

## Generate the secrets

```bash
# VLESS UUID
sing-box generate uuid
# → 47b3ce47-aa7d-4cde-8a58-0b3ea14cc84b (your output differs)

# REALITY keypair (the *private* half goes in sing-box, the *public* half
# in mudi.env on the laptop)
sing-box generate reality-keypair
# → PrivateKey: -EeriCxh9HoSydsiaub0EWydACLFhwUzhuMy8OpGUnA
# → PublicKey:  dMpT7mMdVFPLa_5TDYEjdudx0GfFj7gdg3UxXocdOmE

# REALITY short ID
sing-box generate rand --hex 8
# → f4fb944625ef576c

# Hysteria-2 password
sing-box generate rand --base64 24
# → 0RoNoJM9qk_hLn2TWvFU4mRxiKvJTdpP

# WireGuard server keypair
wg genkey | tee /etc/wireguard/server.priv | wg pubkey > /etc/wireguard/server.pub
chmod 600 /etc/wireguard/server.priv
cat /etc/wireguard/server.priv  # paste this into wg0.conf PrivateKey
```

Keep these around — `setup.sh` on the laptop will ask for the public-side
values (UUID, Reality public key, short ID, Hy2 password) to write into
`mudi.env`.

## Fill in the templates

Copy [sing-box.config.json](sing-box.config.json) to `/etc/sing-box/config.json`,
then replace the four `REPLACE_WITH_*` placeholders with the values above.
Same for [wg0.conf](wg0.conf) — the `PrivateKey` is yours, and
`REPLACE_WITH_MUDI_PUBLIC_KEY` is the pubkey GL Web UI prints when you save
the WireGuard Client profile on the Mudi.

## Start the services

```bash
systemctl enable --now sing-box
systemctl enable --now wg-quick@wg0
```

## Open the ports on your VPS firewall

```bash
ufw allow 8443/tcp comment "sing-box VLESS+REALITY"
ufw allow 443/udp  comment "sing-box Hysteria-2"
ufw allow 39753/udp comment "WireGuard for Mudi"
```

(Adjust the WG port if you picked something other than the example.)

## Add the Mudi as a WG peer

When you toggle VPN ON on the Mudi for the first time, GL Web UI generates
a public key. Grab it from the WireGuard Client profile page, append a
`[Peer]` stanza to `wg0.conf`, and reload:

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
sudo wg show
```

## (Optional) Self-hosted Headscale

If you want self-hosted Tailscale instead of the official control plane,
the most painless way is a docker container:

```bash
docker run -d --name headscale \
    -v /etc/headscale:/etc/headscale \
    -p 9443:9443 \
    headscale/headscale:v0.27.0 serve
```

Then in `mudi.env`, set `TS_LOGIN_SERVER=https://your-vps:9443` and use a
Headscale preauthkey (`docker exec headscale headscale preauthkeys create -u 1`)
as `TS_AUTHKEY`.
