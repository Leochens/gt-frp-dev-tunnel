# Contributing

Thanks for helping improve GT FRP Dev Tunnel.

## Development Setup

This repository is mostly shell and Python scripts. There is no package install
step for normal development.

Useful local checks:

```bash
python3 -m py_compile scripts/frp_dev_tunnel.py
bash -n scripts/frp-client-bootstrap.sh
bash -n scripts/frp-dev-tunnel.sh
bash -n scripts/frps-server-setup.sh
```

If you change tunnel behavior, test the smallest safe path first:

```bash
scripts/frp-dev-tunnel.sh --help
scripts/frp-dev-tunnel.sh show-config
```

Only run real `config`, `smoke-test`, or `start-auto` commands against a trusted
FRPS server. Do not commit generated configs, logs, tokens, or helper installs.

## Pull Requests

- Keep changes focused.
- Explain the server/client platform you tested on.
- Include command output for syntax checks or tunnel verification when relevant.
- Avoid broad formatting churn in scripts.
- Update `README.md`, `SKILL.md`, and `CHANGELOG.md` when user-facing behavior changes.

## Security

Do not open a public issue for suspected vulnerabilities or leaked credentials.
Use the process in `SECURITY.md`.
