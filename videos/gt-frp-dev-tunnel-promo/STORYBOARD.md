# Storyboard

**Format:** 1920x1080  
**Audio:** local TTS voiceover; minimal electronic underscore implied by visual rhythm  
**VO direction:** calm, confident developer-tool launch read; short pauses between claims  
**Style basis:** DESIGN.md

## Asset Audit

| Asset | Type | Assign to Beat | Role |
| --- | --- | --- | --- |
| `logo.svg` | SVG logo | Beat 1, Beat 4 | Brand opener and closer |
| `terminal-window.svg` | SVG interface | Beat 1 | Hero command console |
| `network-map.svg` | SVG diagram | Beat 2 | VPS gateway topology |
| `agent-card.svg` | SVG interface | Beat 3 | Agent handoff proof |
| `phone-check.svg` | SVG interface | Beat 4 | External verification proof |

## BEAT 1 - Local App Needs A Link (0.00-4.60s)

**VO cue:** "Your app runs locally. The demo needs a real link."

**Concept:** The viewer starts inside a dark terminal workspace. A local dev server is alive, but boxed in; a cyan cursor and route pulse imply that the next move is external access.

**Visual description:** The logo glows in the upper-left. A terminal window sits large in the center with `localhost:5173` and a typed tunnel command. A small browser chip labeled `demo.local` waits on the right, separated by an unfinished cyan route. Background particles move like quiet network traffic.

**Techniques:** character typing, per-word kinetic typography, canvas-style particle field via deterministic CSS dots.

**Transition:** Cyan route wipe sweeps into Beat 2.

## BEAT 2 - Your VPS Becomes The Gateway (4.60-9.70s)

**VO cue:** "GT FRP Dev Tunnel turns your own V P S into a reusable gateway."

**Concept:** The terminal unfolds into a network map. The VPS becomes the stable center of the system, receiving local traffic and pushing it to a wildcard public domain.

**Visual description:** The `network-map.svg` topology sits as a tilted dashboard. Lines draw from local app to frps to wildcard domain, with three status meters counting upward. The word `gateway` lands as the cyan route completes.

**Techniques:** SVG path drawing, counter animation, CSS 3D panel tilt.

**Transition:** Velocity-matched upward blur into Beat 3.

## BEAT 3 - Agent Handoff (9.70-15.10s)

**VO cue:** "Set up F R P S once. Hand the bootstrap to any coding agent."

**Concept:** The product becomes operational. The user does the server setup once, then hands a clean bootstrap prompt to the local coding agent.

**Visual description:** The agent handoff card slides forward with a warm prompt. Three command rows cascade: `config`, `doctor`, `start-auto`. Small agent labels orbit the card to show Codex, Claude Code, and other agents can receive the same prompt.

**Techniques:** cascading command rows, kinetic labels, warm prompt glow.

**Transition:** Hard percussive snap to verification.

## BEAT 4 - Verified, Clean, Online (15.10-20.00s)

**VO cue:** "It opens a temporary subdomain, verifies it, and keeps tunnel files out of your project. No deploy. Just your dev server, online."

**Concept:** The payoff is practical proof. A phone checks the public URL, a status rail confirms HTTP 200, and cleanup commands remain ready.

**Visual description:** The phone verification mock anchors the right side while the public URL badge expands across the frame. Green checks pulse down a verification rail: `HTTP 200 OK`, `local service`, `tunnel name`, `stop-all`. The logo returns and the final claim holds: `No deploy. Just online.`

**Techniques:** status pulse, URL badge reveal, final logo glow.

**Transition:** Final fade to dark after the hold.

## Production Architecture

```text
project/
├── index.html
├── DESIGN.md
├── SCRIPT.md
├── STORYBOARD.md
├── transcript.json
├── narration.wav
├── capture/
│   ├── screenshots/
│   ├── assets/
│   │   └── svgs/
│   └── extracted/
└── compositions/
    ├── beat-1-hook.html
    ├── beat-2-gateway.html
    ├── beat-3-agent-handoff.html
    └── beat-4-verified.html
```
