---
name: gt-frp-dev-tunnel
description: Use when Codex, Claude Code, OpenCloud, or another coding agent needs to expose a local development server through a user-provided frp/frps HTTP subdomain tunnel for quick external/mobile validation. Triggers include temporary public URLs, wildcard subdomains, phone testing, local project verification, frpc/frps, OpenResty/Nginx reverse proxy, intranet tunneling, dependency/environment checks for Python/Node.js/frpc/Docker, or Chinese requests such as "临时域名", "内网穿透", "手机访问本地服务", "快速验证", "外网访问本地项目".
---

# GT FRP Dev Tunnel

Use this skill to expose a local dev server through an existing frps server and HTTP subdomain host without deploying the project.

## Architecture

The expected path is:

```text
phone/browser
  -> https://<subdomain>.<public-domain>
  -> reverse proxy / frps HTTP vhost
  -> frps
  -> local frpc
  -> local service port
```

The VPS/server side must already provide:

- A reachable `frps` server address and port.
- The matching `auth.token`.
- An HTTP `subdomainHost` / wildcard domain that points to the reverse proxy or frps HTTP vhost.
- A reverse proxy, when used, that preserves `Host`.

Do not assume any fixed domain. If no config is present, ask the user for FRPS connection domain/IP, FRPS port, and token. If the public wildcard domain differs from the FRPS connection domain, also ask for or set `--public-domain`.

## Server Bootstrap

If the user does not already have an frps server, prepare a dedicated Linux VPS with the bundled server setup script. The server should ideally be used only as the FRP gateway.

One-line server setup from the open-source repository:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup
```

With a known wildcard domain:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

The server script:

- Writes `/etc/frp/frps.toml`.
- Automatically detects Docker and runs `frps` as a container when Docker is available.
- Falls back to installing the `frps` binary and registering a systemd service when Docker is unavailable.
- Supports `--runtime auto|docker|systemd` for explicit runtime control.
- Uses `snowdreamtech/frps:<frp-version>` in Docker mode unless `--frps-image` is provided.
- Generates or accepts the `auth.token`.
- Lets the user choose the frps client connection port; the default is `7111`.
- Defaults `vhostHTTPPort` to `80` and `vhostHTTPSPort` to `443`.
- Detects 80/443 conflicts and, when possible, writes wildcard reverse-proxy config for Nginx/OpenResty or Apache.
- Prints DNS guidance for `*.tunnel.example.com`.
- Reminds the user to open the frps connection port in the cloud provider firewall/security group.
- Prints a reusable external port check command:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | bash -s -- check-port --host <frps-domain-or-ip> --port 7111
```

- Prints a client-side prompt that first tells the local Agent to check/install/reinstall this skill, then gives a single `frp-client-bootstrap.sh` command. That command downloads the local helper into the target project, writes the FRP client config, installs lightweight `frpc` if missing, and runs `doctor`.

Do not rewrite that final prompt as Codex-only instructions. The receiving Agent may be Codex, Claude Code, OpenCode, OpenCloud, or another coding assistant, so keep the wording generic: "your local Agent / sub-agent".

Client-side skill install rule:

- First check whether `gt-frp-dev-tunnel` is already installed in the local Agent's skill/plugin/connector system.
- If it is installed, reinstall or refresh it from `https://github.com/Leochens/gt-frp-dev-tunnel`.
- If it is missing, install it from that repository before continuing.
- If the platform has no skill mechanism, use the helper scripts directly.

Default the public URL scheme to `http` unless the server setup receives a wildcard TLS certificate or the user explicitly chooses `https`. If a user chooses `https` without a wildcard certificate/CDN/gateway that handles `*.domain`, warn them that HTTPS may fail with TLS/SNI errors and that `--public-scheme http` is the lower-friction validation path.

If the port check fails, tell the user to open inbound TCP `7111` or their chosen `--server-port` in the server provider's firewall/security group, then rerun the same `check-port` command from an external/client machine.

## Environment First

Run the bundled environment check before starting a tunnel:

```bash
scripts/frp-dev-tunnel.sh doctor
```

On Windows without Bash:

```bat
scripts\frp-dev-tunnel.cmd doctor
```

The helper checks:

- Python 3.8+ for the cross-platform tunnel helper.
- Node.js 18+ for common local frontend/Node dev servers.
- A local `frpc` binary; existing Docker can be reused as a compatibility fallback.
- FRPS config completeness.

Install only what is missing. Prefer the one-line install command printed by `doctor`. Do not ask the user to install Docker for this skill; installing the small `frpc` client is the lower-cost path. Do not add project npm dependencies globally unless the target project explicitly requires it.

Runner choice:

- Prefer local `frpc` when available. It works consistently across macOS, Windows, and Linux.
- Use Docker only when Docker already exists on the machine or the user explicitly prefers it. On macOS/Windows Docker mode defaults the tunnel target to `host.docker.internal`; on Linux it uses host networking.
- Override with `FRP_RUNNER=local` or `FRP_RUNNER=docker` when needed.

If `doctor` reports that neither `frpc` nor Docker is available, install `frpc`:

```bash
scripts/frp-dev-tunnel.sh install-frpc
```

This installs only the `frpc` binary into the user-local bin directory. It does not require Docker or sudo.

## Configure FRPS

Fast path from a server setup prompt:

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frp-client-bootstrap.sh | bash -s -- --server-addr <frps-domain-or-ip> --server-port <frps-port> --token <frps-token> --public-domain <subdomain-host> --public-scheme <http-or-https>
```

Use this when helping another local Agent/client machine. It avoids manual token copying across multiple commands and keeps secrets out of project files.

Interactive setup:

```bash
scripts/frp-dev-tunnel.sh config
```

Non-interactive setup for agents or CI-like shells:

```bash
scripts/frp-dev-tunnel.sh config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token <frps-token>
```

If the public wildcard domain is not the same as `serverAddr`:

```bash
scripts/frp-dev-tunnel.sh config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token <frps-token> \
  --public-domain <subdomain-host>
```

If the server setup output includes a public URL scheme, preserve it:

```bash
scripts/frp-dev-tunnel.sh config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token <frps-token> \
  --public-domain <subdomain-host> \
  --public-scheme <http-or-https>
```

Config precedence:

1. `FRPC_SOURCE_CONFIG` parsed from an existing `frpc.toml`.
2. Saved local config at `FRP_TUNNEL_CONFIG`, or the OS default config path.
3. Environment variables.
4. CLI flags.

Useful environment variables:

```bash
FRP_SERVER_ADDR=<frps-domain-or-ip>
FRP_SERVER_PORT=<frps-port>
FRP_AUTH_TOKEN=<frps-token>
FRP_DEV_DOMAIN=<subdomain-host>
FRP_PUBLIC_SCHEME=https
FRPC_BIN=/path/to/frpc
FRPC_SOURCE_CONFIG=/path/to/frpc.toml
FRP_RUNNER=local
```

Never print the token back to the user. The helper redacts tokens in config and logs.

## Start A Tunnel

Before exposing a real project, run the built-in tiny smoke project:

```bash
scripts/frp-dev-tunnel.sh smoke-test
```

This creates a minimal static page with Python's standard library, exposes it through frp, verifies the public URL, and prints a stop command. Use it only to prove the FRP path works.

After the smoke page works:

1. Start the local project on a known port.
2. Prefer binding the dev server to `127.0.0.1`.
3. Run `start-auto` to generate a high-entropy subdomain:

```bash
scripts/frp-dev-tunnel.sh start-auto demo 5173
```

The script prints a URL like:

```text
https://demo-6f9c0e2a4b1d8c9a77c2013e.example.com/
```

Give the user the printed URL only, unless they ask for diagnostics.

Manual subdomain:

```bash
scripts/frp-dev-tunnel.sh start <subdomain> <local-port> [local-ip]
```

Status, logs, verify, and cleanup:

```bash
scripts/frp-dev-tunnel.sh status
scripts/frp-dev-tunnel.sh logs <subdomain>
scripts/frp-dev-tunnel.sh verify <subdomain> [path]
scripts/frp-dev-tunnel.sh stop <subdomain>
```

Use `verify` for external URL checks because it ignores proxy environment variables and skips TLS verification for temporary wildcard certificates.

If `verify` returns a Vite 403 with `allowedHosts` / blocked Host wording, the FRP path is already reaching the local dev server. Add a narrow Vite rule such as `server: { allowedHosts: ['.<public-domain>'] }`, restart the dev server, and verify again.

## Agent Compatibility

For Codex, Claude Code, OpenCloud, or other agents:

- First check whether this skill is installed. Reinstall/refresh it when present; install it when missing.
- If the shell has an interactive TTY, run `config` and let the helper prompt.
- If there is no interactive TTY and config is missing, ask the user for exactly: FRPS connection domain/IP, FRPS port, and FRPS token. Ask for public wildcard domain only when it differs.
- Store config with the helper instead of embedding secrets in the skill or project files.
- Prefer the `frp-client-bootstrap.sh` command generated by the server setup over manually copying multiple config commands.
- Run `scripts/frp-dev-tunnel.sh smoke-test` before touching the user's real project.
- If no tunnel runner exists, run `install-frpc`; do not tell the user to install Docker unless they explicitly want Docker.
- On Windows, prefer `scripts\frp-dev-tunnel.cmd` or `py -3 scripts\frp_dev_tunnel.py`.
- On macOS/Linux, prefer `scripts/frp-dev-tunnel.sh`.
- Keep returned user-facing output short: URL, verification result, and cleanup command when useful.

## Frontend And API Cases

Only apply these to real projects after the smoke test succeeds.

Preferred approach for a frontend plus backend:

- Expose only the frontend dev server through frp.
- Make browser code call relative paths such as `/api/users`.
- Configure the frontend dev server to proxy `/api` to the local backend, for example `http://127.0.0.1:3001`.

This avoids CORS and avoids `localhost` mistakes. Remember: `localhost` inside phone browser JavaScript means the phone, not the development machine.

Use separate subdomains only when the backend must be called directly by the browser:

```text
https://app-demo.<public-domain>
https://api-demo.<public-domain>
```

In that case, configure backend CORS and credentials deliberately.

## Security

Use this only for temporary validation. The default convenience model is "unguessable URL, no Basic Auth" because it works better on phones and avoids repeated browser credential prompts. This is not strong access control. Do not expose private data, production credentials, or destructive admin actions through this mode.

Optional Basic Auth:

```bash
FRP_HTTP_USER=viewer
FRP_HTTP_PASSWORD='temporary-password'
```

Use Basic Auth only when the user explicitly asks for it or the page exposes data/actions that should not rely on URL secrecy.
