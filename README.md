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

The server script installs/configures `frps`, guides wildcard DNS setup, handles 80/443 conflicts with Nginx/OpenResty/Apache when possible, and prints a client-side bootstrap command.

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

The local Agent should first check whether `gt-frp-dev-tunnel` is installed as a skill/plugin/connector:

- If it is already installed, reinstall or refresh it from this repository.
- If it is not installed, install it first.
- If the platform does not support skills, use the bootstrap command below.
- Do not copy helper scripts or FRP config into the user's project, and do not commit tunnel helper files to the project repository.

The prompt gives the local Agent a single bootstrap command like:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frp-client-bootstrap.sh | bash -s -- --server-addr tunnel.example.com --server-port 7111 --token '<token>' --public-domain tunnel.example.com --public-scheme http
```

That command installs the helper into the user's OS-level data directory, writes FRP config into the user's OS-level config directory, installs the lightweight `frpc` client if missing, and runs `doctor`. It should not create or modify files in the current project.

The examples below use `frp-dev-tunnel`; if bootstrap prints a full `Tunnel command` path, use that exact path instead.

After bootstrap, either open a direct tunnel or validate with the tiny smoke project:

```bash
frp-dev-tunnel smoke-test
```

Use the smoke test for first-time setup or when the FRP path is uncertain. For an already configured machine, run the same helper in any real project by starting the project's dev server and then running `frp-dev-tunnel start-auto <project-name> <local-port>`.

Recommended final output for agents:

```text
公网访问已开启
URL: <public-url>
状态: <HTTP 200 OK | blocked: reason | unverified: reason>
本地服务: <local-ip>:<local-port>
隧道名: <subdomain>

管理:
- 查看全部: frp-dev-tunnel list
- 验证当前: frp-dev-tunnel verify <subdomain>
- 查看日志: frp-dev-tunnel logs <subdomain>
- 停止当前: frp-dev-tunnel stop <subdomain>
- 停止全部: frp-dev-tunnel stop-all
```

The same prompt is saved on the server at:

```text
/root/gt-frp-dev-tunnel-client-prompt.txt
```

## Client Helper

On the local development machine, the bootstrap command is preferred. If you already installed or cloned this repository:

```bash
frp-dev-tunnel config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token '<frps-token>' \
  --public-domain <wildcard-domain> \
  --public-scheme <http-or-https>
frp-dev-tunnel doctor
frp-dev-tunnel smoke-test
frp-dev-tunnel start-auto demo 5173
frp-dev-tunnel list
```

If external Vite access returns a 403 mentioning `allowedHosts` or blocked Host, the tunnel is reaching the local dev server. Ask before changing the target project, then allow the wildcard host in the target project's Vite config and restart the dev server:

```ts
server: {
  allowedHosts: ['.tunnel.example.com'],
}
```

Stop a tunnel:

```bash
frp-dev-tunnel stop <subdomain>
frp-dev-tunnel stop-all
```
