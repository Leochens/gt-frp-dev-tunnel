# Design System

## Overview

GT FRP Dev Tunnel is a technical, agent-friendly developer utility. The visual identity should feel like a premium terminal surface mixed with a network operations dashboard: dark canvas, crisp type, bright routing lines, and compact command panels. Layouts should be dense but readable, with code snippets, tunnel URLs, server nodes, and verification states treated as first-class visuals. The product promise is practical: a local dev server gets a temporary public URL without deployment or project clutter.

## Colors

- **Terminal Ink**: `#071014` - primary background.
- **Panel Surface**: `#0E1A20` - command cards and dashboard panels.
- **Panel Edge**: `#263943` - thin borders and separators.
- **Signal Cyan**: `#4DE3FF` - routing lines, active tunnel state, and glow.
- **Agent Green**: `#9AF27A` - success states and verification marks.
- **Warm Command**: `#FFB86B` - shell prompts, tokens, and setup highlights.
- **Primary Text**: `#F4FAFC` - large headlines and core labels.
- **Secondary Text**: `#9CB3BD` - metadata and supporting copy.

## Typography

- **Mono**: `SFMono-Regular`, `Menlo`, `Consolas`, monospace. Commands, URLs, labels, and verification output.
- **Sans**: `Inter`, `Avenir Next`, `Helvetica Neue`, Arial, sans-serif. Large product headlines and explanatory phrases.
- Hero headings use 78-112px sans-serif with 800 weight. Terminal panels use 24-38px monospace with generous line height and tabular numerals.

## Elevation

Depth comes from stacked panels with 1px borders, cyan glows, and layered radial highlights rather than heavy drop shadows. The scene should feel like a focused dev console with energy moving through it: server cards float above a dark base, signal lines sit in the midground, and status pills glow only when something is verified.

## Components

- **Command Console**: Large terminal window with a warm prompt, typed command, and active cursor.
- **VPS Gateway Map**: Central server node connecting local app, frps, wildcard domain, browser, and phone.
- **Agent Handoff Card**: Compact prompt panel showing bootstrap flow and agent ownership.
- **Verification Rail**: Stacked status rows for HTTP response, tunnel name, local port, and cleanup commands.
- **Public URL Badge**: High-contrast URL strip with cyan border, readable at video size.

## Do's and Don'ts

### Do's

- Use dark surfaces with exact cyan, green, and warm command accents.
- Treat commands and URLs as visual objects, not tiny footnotes.
- Keep panels aligned to a disciplined grid while signal lines move with energy.
- Use terminal-style type for product proof: ports, domains, HTTP states, and cleanup commands.

### Don'ts

- Do not make the video a static README page.
- Do not use one-note blue gradients; mix cyan, green, warm command orange, and neutral dark surfaces.
- Do not show secret tokens or realistic credentials.
- Do not use tiny terminal text below 20px.
