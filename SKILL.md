---
name: gt-frp-dev-tunnel
description: Use when Codex needs to expose a local development server for quick external/mobile validation through Guantou's configured frp tunnel instead of deploying to a public cloud service. Triggers include requests about temporary domains, wildcard subdomains, phone testing, local project verification, frp/frpc/frps, OpenResty reverse proxy, intranet tunneling, or Chinese requests such as "临时域名", "内网穿透", "手机访问本地服务", "快速验证", "外网访问本地项目".
---

# GT FRP Dev Tunnel

Use this skill to validate a local dev server from an external device through the existing frp + OpenResty setup.

## Current Architecture

The intended path is:

```text
phone/browser
  -> https://<subdomain>.dev.guantou.site
  -> VPS OpenResty on 80/443
  -> frps HTTP vhost on 127.0.0.1:8080
  -> local frpc
  -> local service port
```

Known local client defaults:

- frpc source config: `/opt/1panel/apps/frpc/frpc/data/frpc.toml`
- persistent frpc container: `1Panel-frpc-WTBk`
- one-off frpc image: `snowdreamtech/frpc:0.67.0`
- wildcard domain namespace: `dev.guantou.site`
- tunnel type for local web apps: `http` with `subdomain = "<name>"`

The VPS must already have:

- DNS wildcard `*.dev.guantou.site` pointing at the VPS.
- frps with `subdomainHost = "dev.guantou.site"` and `vhostHTTPPort = 8080`.
- OpenResty wildcard server for `*.dev.guantou.site` forwarding to frps, preserving `Host`:

```nginx
proxy_pass http://127.0.0.1:8080;
proxy_set_header Host $host;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $http_connection;
```

## Quick Workflow

1. Start the local project on a known port.
2. Prefer binding to `127.0.0.1` unless the framework requires `0.0.0.0`.
3. For phone validation, use an unguessable generated subdomain by default and do not enable HTTP Basic Auth. Mobile browsers can repeatedly prompt for Basic Auth when a dev server opens secondary requests such as HMR, assets, or WebSocket connections.
4. Run the bundled script with `start-auto`:

```bash
/home/guantou/.agents/skills/gt-frp-dev-tunnel/scripts/frp-dev-tunnel.sh start-auto framepost 5173
```

The script prints a URL like:

```bash
https://framepost-6f9c0e2a4b1d8c9a77c2013e.dev.guantou.site/
```

5. Verify externally using the exact printed host:

```bash
curl --noproxy '*' -k -I https://framepost-6f9c0e2a4b1d8c9a77c2013e.dev.guantou.site/
```

6. Give the user only the printed URL.
7. Clean up when done with the printed subdomain:

```bash
/home/guantou/.agents/skills/gt-frp-dev-tunnel/scripts/frp-dev-tunnel.sh stop framepost-6f9c0e2a4b1d8c9a77c2013e
```

## Script

Use `scripts/frp-dev-tunnel.sh` for repeatable operations:

```bash
# Start or replace a temporary tunnel.
scripts/frp-dev-tunnel.sh start <subdomain> <local-port> [local-ip]

# Start a temporary tunnel with a generated high-entropy subdomain.
scripts/frp-dev-tunnel.sh start-auto <prefix> <local-port> [local-ip]

# Show managed temporary tunnel containers.
scripts/frp-dev-tunnel.sh status

# Print logs for one tunnel.
scripts/frp-dev-tunnel.sh logs <subdomain>

# Verify the public URL with curl.
scripts/frp-dev-tunnel.sh verify <subdomain> [path]

# Stop and remove one tunnel.
scripts/frp-dev-tunnel.sh stop <subdomain>
```

Useful environment overrides:

```bash
FRP_DEV_DOMAIN=dev.guantou.site
FRPC_SOURCE_CONFIG=/opt/1panel/apps/frpc/frpc/data/frpc.toml
FRPC_IMAGE=snowdreamtech/frpc:0.67.0
```

Optional Basic Auth:

```bash
FRP_HTTP_USER=viewer
FRP_HTTP_PASSWORD='temporary-password'
```

Do not set `FRP_HTTP_USER` or `FRP_HTTP_PASSWORD` for the default phone-validation path. Prefer `start-auto` and an unguessable URL. Use Basic Auth only when the user explicitly asks for it or the page exposes data/actions that should not rely on URL secrecy.

## Frontend And API Cases

Preferred approach for a frontend plus backend:

- Expose only the frontend dev server through frp.
- Make browser code call relative paths such as `/api/users`.
- Configure the frontend dev server to proxy `/api` to the local backend, for example `http://127.0.0.1:3001`.

This avoids CORS and avoids `localhost` mistakes. Remember: `localhost` inside phone browser JavaScript means the phone, not the development machine.

Use separate subdomains only when the backend must be called directly by the browser:

```text
https://app-demo.dev.guantou.site
https://api-demo.dev.guantou.site
```

In that case, configure backend CORS and credentials deliberately.

## Verification Notes

- Always use `curl --noproxy '*'` on this machine because proxy environment variables may route local checks through `127.0.0.1:7890`.
- If HTTPS fails with a certificate name mismatch, the tunnel may still be working. Confirm with `curl -k`, then fix the OpenResty certificate for `*.dev.guantou.site`.
- A healthy frpc log contains `login to server success` and `start proxy success`.
- The frps error `custom domain [...] should not belong to subdomain host [...]` means the frpc config used `customDomains` for a host under `subdomainHost`; use `subdomain = "<name>"` instead.
- The frpc error `token in login doesn't match token from configuration` means local frpc config and server frps token differ.

## Security

Use this only for temporary validation. The default convenience model is "unguessable URL, no Basic Auth" because it works better on phones and avoids repeated browser credential prompts. This is not strong access control. Do not expose private data, production credentials, or destructive admin actions through this mode.

If the user needs a real access gate, explicitly set `FRP_HTTP_USER` and `FRP_HTTP_PASSWORD`, or put the app behind a proper auth layer. For Vite dev servers, prefer `vite preview` or a production build through the tunnel; Vite HMR can make mobile Basic Auth prompts unreliable.
