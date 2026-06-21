# GT FRP Dev Tunnel

Expose a local development server through your own `frps` server and a wildcard subdomain. This repository contains:

- A client helper for starting temporary local `frpc` tunnels.
- A server bootstrap script for installing and configuring `frps` on a Linux VPS.
- A skill-style instruction file for coding agents that can install/use repository skills.

## Server One-Line Setup

Run this on a dedicated Linux VPS. The server is best used only as the FRP gateway.

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup
```

If you already know the wildcard domain:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

The default frps client connection port is `7111`. You can choose another port:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --server-port 7443
```

Safer review-first flow:

```bash
curl -fsSLO https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh
less frps-server-setup.sh
sudo bash frps-server-setup.sh setup --domain tunnel.example.com
```

For production-like usage, prefer a tagged release URL instead of `main` after this repository has releases:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/v0.1.0/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

The server script installs/configures `frps`, guides wildcard DNS setup, handles 80/443 conflicts with Nginx/OpenResty/Apache when possible, and prints a client-side prompt.

By default, the server runtime is `auto`:

- If Docker is installed and the daemon is available, `frps` runs as a container named `gt-frp-frps`.
- If Docker is unavailable, the script falls back to downloading the `frps` binary and registering a systemd service.

Force a runtime when needed:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --runtime docker
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --runtime systemd
```

Docker mode uses `snowdreamtech/frps:<frp-version>` by default. Override with `--frps-image <image>` if your server needs a mirror or private registry.

## Firewall And Port Check

After setup, open the frps client connection port in your server provider firewall/security group:

```text
Inbound TCP 7111
```

If you used a custom `--server-port`, open that port instead. If HTTP/HTTPS traffic is not already handled by an existing gateway or CDN, also make sure TCP `80` and `443` are reachable.

Check the frps connection port from your client machine or any external machine:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | bash -s -- check-port --host tunnel.example.com --port 7111
```

If the check says the port is not reachable, open the port in the cloud firewall/security group, then run the same command again.

## Client Agent Handoff

After the server setup finishes, copy the printed prompt to your local development Agent or sub-agent. The prompt is intentionally generic because the receiving Agent might be Codex, Claude Code, OpenCode, OpenCloud, or another coding assistant.

The prompt tells the local Agent to:

1. Inspect and install/use this repository:

```text
https://github.com/Leochens/gt-frp-dev-tunnel
```

2. Configure the client helper with the generated FRPS parameters.
3. Run `doctor`.
4. Start a temporary tunnel for the local development port.

The same prompt is saved on the server at:

```text
/root/gt-frp-dev-tunnel-client-prompt.txt
```

## Client Helper

On the local development machine, after installing or cloning this repository:

```bash
scripts/frp-dev-tunnel.sh doctor
scripts/frp-dev-tunnel.sh config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token '<frps-token>' \
  --public-domain <wildcard-domain> \
  --public-scheme <http-or-https>
scripts/frp-dev-tunnel.sh start-auto demo 5173
```

Stop a tunnel:

```bash
scripts/frp-dev-tunnel.sh stop <subdomain>
```
