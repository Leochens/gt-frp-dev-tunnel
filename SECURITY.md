# Security Policy

## Supported Versions

This project is pre-1.0. Security fixes are expected to land on the `main`
branch until tagged releases and a longer support policy exist.

## Reporting A Vulnerability

Please do not disclose vulnerabilities, leaked tokens, or server access details
in public issues.

Report security concerns privately through GitHub Security Advisories for this
repository. If that is not available, contact the maintainer through the GitHub
profile linked from the repository owner.

Please include:

- A short description of the issue.
- Affected script or command.
- Steps to reproduce without exposing real secrets.
- Impact and any suggested fix.

## Operational Guidance

- Use a dedicated VPS for the FRP gateway.
- Keep FRPS tokens out of project repositories, chat transcripts, screenshots,
  and public issues.
- Rotate tokens immediately if they were shared outside trusted local setup
  flows.
- Do not expose production admin panels, destructive actions, customer data, or
  real payment flows through temporary validation tunnels.
