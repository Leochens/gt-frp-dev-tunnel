<p align="right">
  English | <a href="./README.zh-CN.md">简体中文</a>
</p>

> Notice: For a more stable FRP setup, use a dedicated low-cost VPS instead of
> sharing a busy application server. You can buy a Tencent Cloud server through
> this referral link and deploy `frps` on it: <https://curl.qcloud.com/jqbR5NAv>.
> Any compatible VPS will work, but a dedicated FRP server is the recommended
> path.

# GT FRP Dev Tunnel

Expose a local development server through your own `frps` gateway and a wildcard
subdomain, then hand the public URL back to a coding agent for mobile or external
validation.

`gt-frp-dev-tunnel` is designed for temporary development checks, not production
traffic. It keeps FRP config in user-level directories, redacts tokens from helper
output, and avoids copying tunnel files into the project being tested.

## Why

When a local web app needs to be tested from a phone, another machine, or a
remote review flow, the usual choices are either deploying too early or exposing
too much machine state. This project gives agents and developers a repeatable
middle path:

- Bring up a small `frps` gateway on your own Linux VPS.
- Configure a local helper once with the gateway address, port, token, and
  wildcard domain.
- Start high-entropy temporary HTTP subdomain tunnels for real local dev servers.
- Verify and stop tunnels from one command line.

## What Is Included

- `scripts/frps-server-setup.sh`: Linux VPS bootstrap for `frps`, Docker or
  systemd runtime, wildcard DNS guidance, firewall check, and client handoff text.
- `scripts/frp-client-bootstrap.sh`: user-level client installer that downloads
  the helper, writes config outside the current project, installs `frpc` when
  needed, and runs `doctor`.
- `scripts/frp_dev_tunnel.py`: cross-platform helper for `config`, `doctor`,
  `install-frpc`, `smoke-test`, `start-auto`, `verify`, `logs`, `stop`, and
  `stop-all`.
- `SKILL.md`: agent instructions for Codex, Claude Code, OpenCode, OpenCloud, or
  similar coding agents.
- `agents/openai.yaml`: OpenAI/Codex-facing metadata.

## Requirements

Server:

- A Linux VPS with root access.
- A domain or subdomain you can point with wildcard DNS, for example
  `*.tunnel.example.com`.
- An inbound TCP port for `frps` clients. The default is `7111`.

Client:

- Python 3.8+.
- `curl` or Python for bootstrap downloads.
- A local `frpc` binary, or Docker if you explicitly choose Docker mode. The
  helper can install a lightweight `frpc` binary for the current user.

## Server Setup

Run this on a dedicated Linux VPS. The server is best used only as the FRP
gateway.

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup
```

If you already know the wildcard domain:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

Choose a custom client connection port:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --server-port 7443
```

Safer review-first flow:

```bash
curl -fsSLO https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh
less frps-server-setup.sh
sudo bash frps-server-setup.sh setup --domain tunnel.example.com
```

For production-like use, prefer a tagged release URL instead of `main` after this
repository starts publishing releases:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/v0.1.0/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

The server script:

- Installs and configures `frps`.
- Uses Docker automatically when available, otherwise falls back to a systemd
  service.
- Generates or accepts an `auth.token`.
- Handles common 80/443 conflicts with Nginx, OpenResty, or Apache when possible.
- Prints wildcard DNS guidance and an external port check command.
- Prints a client-side prompt containing the bootstrap command for your local
  agent.

Force a runtime when needed:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --runtime docker
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --runtime systemd
```

Docker mode uses `snowdreamtech/frps:<frp-version>` by default. Override it with
`--frps-image <image>` if your server needs a mirror or private registry.

## Firewall And DNS

After setup, open the frps client connection port in the server provider firewall
or security group:

```text
Inbound TCP 7111
```

If you used a custom `--server-port`, open that port instead. If HTTP/HTTPS
traffic is not already handled by an existing gateway or CDN, also make sure TCP
`80` and `443` are reachable.

Check the frps connection port from a client machine or any external machine:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | bash -s -- check-port --host tunnel.example.com --port 7111
```

For DNS, point both the root and wildcard host at the gateway server or the
gateway/CDN in front of it:

```text
tunnel.example.com      A      <server-ip>
*.tunnel.example.com    A      <server-ip>
```

## Client Bootstrap

After the server setup finishes, copy the printed prompt to your local
development agent or run the bootstrap command manually:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frp-client-bootstrap.sh | bash -s -- --server-addr tunnel.example.com --server-port 7111 --token '<token>' --public-domain tunnel.example.com --public-scheme http
```

The bootstrap command installs the helper into a user-level directory, writes FRP
config into the user's config directory, installs `frpc` if missing, and runs
`doctor`. It should not create or modify files in the current project.

The examples below use `frp-dev-tunnel`. If bootstrap prints a full `Tunnel
command` path, use that exact path instead.

```bash
frp-dev-tunnel doctor
frp-dev-tunnel smoke-test
```

Use `smoke-test` for first-time setup or when the FRP path is uncertain. For an
already configured machine, start a real local dev server and expose it:

```bash
frp-dev-tunnel start-auto demo 5173
frp-dev-tunnel verify <subdomain>
frp-dev-tunnel logs <subdomain>
frp-dev-tunnel stop <subdomain>
frp-dev-tunnel stop-all
```

## Manual Client Configuration

If you cloned this repository or installed the helper another way:

```bash
frp-dev-tunnel config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token '<frps-token>' \
  --public-domain <wildcard-domain> \
  --public-scheme <http-or-https>
```

Useful environment variables:

```bash
FRP_SERVER_ADDR=<frps-domain-or-ip>
FRP_SERVER_PORT=<frps-port>
FRP_AUTH_TOKEN=<frps-token>
FRP_DEV_DOMAIN=<subdomain-host>
FRP_PUBLIC_SCHEME=http
FRPC_BIN=/path/to/frpc
FRPC_SOURCE_CONFIG=/path/to/frpc.toml
FRP_RUNNER=local
```

Config precedence:

1. `FRPC_SOURCE_CONFIG`, parsed from an existing `frpc.toml`.
2. Saved local config at `FRP_TUNNEL_CONFIG`, or the OS default config path.
3. Environment variables.
4. CLI flags.

## Agent Output Template

When an agent starts a tunnel for a project, it should put the public URL near
the top and keep the management commands visible:

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

## Vite Host Checks

If external Vite access returns a 403 mentioning `allowedHosts` or blocked Host,
the tunnel is reaching the local dev server. Allow only the configured wildcard
domain in the target project's Vite config, then restart the dev server:

```ts
server: {
  allowedHosts: ['.tunnel.example.com'],
}
```

## Security Notes

- Treat generated URLs as temporary validation links, not strong access control.
- Do not expose private data, production credentials, payment/admin actions, or
  destructive tools through a convenience tunnel.
- Keep the FRPS token only in trusted local agent prompts and user-level config.
- Use `FRP_HTTP_USER` and `FRP_HTTP_PASSWORD` only when you intentionally want
  Basic Auth on a tunnel.
- Rotate the FRPS token if it was pasted into an untrusted channel.

Report vulnerabilities through the process in [SECURITY.md](./SECURITY.md).

## Contributing

Issues and pull requests are welcome. Please read [CONTRIBUTING.md](./CONTRIBUTING.md)
before opening a larger change. Community interactions are covered by
[CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## License

MIT. See [LICENSE](./LICENSE).
