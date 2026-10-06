# Install

Setup guide for **Claude Session Monitor** (herdr edition). The overlay reads
live agent state from [Herdr](https://herdr.dev) — no Claude Code hooks needed.

---

## Prerequisites

- **Windows 10/11** — Windows PowerShell 5.1 and .NET/WPF are built in.
- **Herdr v0.8+** installed ([herdr.dev](https://herdr.dev)), with a running
  session (`herdr`, or `herdr server` headless) and the `herdr` CLI on `PATH`.
- Any supported AI coding agent inside a herdr pane (claude, opencode, codex,
  …) — herdr detects it automatically.

---

## Setup (~1 minute)

1. **Install Herdr** and launch a session:

   ```powershell
   powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
   herdr
   ```

2. **Clone this repo** anywhere, e.g. `C:\Tools\ClaudeSessionMonitor`.

3. **Run the overlay** — double-click `Start Overlay.vbs`, or:

   ```powershell
   powershell -ExecutionPolicy Bypass -File overlay.ps1
   ```

4. *(Optional)* Click the **GIF** button in the header to set a GIF per state
   (running / needs-input / idle) and the ⚙ gear for sounds/opacity.

That's it. Every agent in every herdr workspace shows up within ~2 seconds,
colour-coded by state; a blocked (needs-input) agent turns **yellow** and plays
the needs-input sound/GIF.

---

## For Claude (automated setup)

If you are an AI agent setting this up, do exactly this:

1. Determine the repo's absolute path (the folder containing `overlay.ps1`).
   Call it `<REPO>`.

2. Confirm prerequisites:
   - `herdr --version` succeeds (v0.8+), `herdr status` shows a running server.
   - `<REPO>/overlay.ps1` and `<REPO>/Start Overlay.vbs` exist.

3. Run the overlay:
   `Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','<REPO>\overlay.ps1'`

4. Verify: after a few seconds, `%TEMP%\ClaudeSessionsOverlay.pid` contains a
   live PID, and `herdr agent list` returns JSON with `result.agents`.

No hook installation into `~/.claude/settings.json` is required for the herdr
edition. The legacy `scripts/*.cjs` hooks are kept in the repo but unused.

---

## How it works (one paragraph)

Every 2 seconds the overlay runs `herdr agent list`, which herdr answers over
its local API socket with one record per detected agent: pane id, agent kind,
cwd, lifecycle status (`working` / `blocked` / `idle` / `done`), and the
stripped terminal title. Each record becomes one row, tinted by status and
sorted working-first. Left-click runs `herdr agent focus <pane>` and raises the
matching herdr workspace window (title-matched by workspace label or repo
folder). Shift-click opens an inline composer whose text is delivered with
`herdr agent prompt <pane> <text>` — herdr writes it into the pane's own input
stream, so no keystroke synthesis or clipboard use. The GIF/sound subsystems
are unchanged and driven by the aggregated overall state (blocked > working >
done > idle).

If herdr is not running, the overlay header shows **herdr offline** and the
board clears until a herdr server returns.

---

## Per-machine state (not shared via git)

`settings.json` (overlay width/opacity/GIF paths/presets) is git-ignored, so it
doesn't travel with the repo — reconfigure it via the overlay UI on each
machine.
