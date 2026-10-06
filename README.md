# Claude Session Monitor (herdr edition)

A lightweight, always-on-top Windows overlay that shows every AI coding agent
running inside [Herdr](https://herdr.dev) — across all workspaces, panes, and
projects — polled live through the herdr CLI.

## Features

- **Live agent list** — polls `herdr agent list` every 2s. Each row shows the
  project folder, the detected **agent kind** (claude, opencode, codex, …), and
  the task title herdr read from the terminal, with a **status-coloured row
  background** (🟢 working · 🟡 blocked/needs-input · 🔵 done · ⚪ idle).
- **Click to focus** — left-click a row to focus that agent's pane via
  `herdr agent focus`, then raise the herdr workspace window (matched by
  workspace label / repo folder in window titles).
- **Shift-click to prompt** — Shift+left-click a row to open an inline composer
  (Enter to send, Shift+Enter newline, ↑/↓ history). The prompt is delivered
  with `herdr agent prompt <pane> <text>` — herdr writes it into the pane's own
  input stream, so no keystroke synthesis and no clipboard use.
- **Status GIF** — the separate floating GIF window (different animated GIF per
  overall state: needs-input > working > done > idle) works exactly as before.
  Click the **GIF** button in the header to set a GIF per state.
- **Status sounds** — per-agent transition sounds and re-nag timers, unchanged.
  Herdr's `done` state maps to the `idle` sound slot.
- **Shown on all desktops / pin toggle / resizable / opacity** — unchanged
  overlay chrome.
- **Version & update check** — unchanged.

## Install / run

1. Install [Herdr](https://herdr.dev) and keep a herdr session running
   (`herdr`, or `herdr server` headless). The `herdr` CLI must be on `PATH`
   (the installer adds it).
2. Clone the repo anywhere.
3. Double-click **`Start Overlay.vbs`**.

To start it automatically at login, drop a shortcut to `Start Overlay.vbs` into
your Startup folder (`shell:startup`).

**No Claude Code hooks are needed anymore.** Herdr detects each agent and its
lifecycle state (`working` / `blocked` / `idle` / `done`) by itself. The old
`scripts/*.cjs` hooks are kept in the repo for reference but are not read by
the overlay.

If herdr is not running, the overlay shows **"herdr offline"** and stays quiet
until a herdr server comes back.

## Files

| File | Purpose |
|------|---------|
| `overlay.ps1` | The overlay (WPF in Windows PowerShell 5.1). |
| `VERSION` | The overlay's version string (single source of truth; checked against GitHub for updates). |
| `Start Overlay.vbs` | Launches `overlay.ps1` hidden. |
| `settings.json` | Saved width, opacity + status-GIF config (local, git-ignored). |
| `scripts/*.cjs` | Legacy Claude Code hooks (no longer used by the herdr edition). |

## Data source (herdr)

Each tick runs `herdr agent list` over herdr's local API socket and renders one
row per record:

- **Name** = project folder (`cwd` leaf).
- **Right of the name** = detected agent kind.
- **Subtitle** = stripped terminal title (the task the agent is on).
- **Tint** = `working` → green, `blocked` → yellow (needs input), `done` →
  blue, `idle`/`unknown` → gray.
- **Age column** = herdr's `state_change_seq` counter (bumps on each state
  change).
- **Sort** = working first, then blocked, then done, then idle (alphabetical by
  project inside each group).

Click delivery:

- **Focus** = `herdr agent focus <pane>` + window-title match on the workspace
  label (or repo folder from the worktree path) to raise herdr's window.
- **Prompt** = `herdr agent prompt <pane> <text>` (bracketed-paste stream, no
  foreground needed).

## Status GIF

Click the **GIF** button in the header to open the settings dialog and paste a GIF for each
state (**Running**, **Needs input**, **Idle**). Each value is a local file path (e.g.
`D:\gifs\working.gif`) or a `file://` / `http(s)://` URL; leave a state blank to show nothing
for it. The floating GIF window only appears when the current state has a GIF configured.

- Drag the GIF window anywhere to move it; drag its bottom-right corner to resize. Position
  and size persist across restarts.
- Overall state priority: any **blocked** agent > any **working** agent > any **done** agent
  > idle.
- GIFs are decoded and animated natively (no external dependencies). For best results use GIFs
  with a transparent background — the window itself is transparent and always-on-top, and shows
  on every virtual desktop like the main overlay.
- Per-state GIF paths are saved in `settings.json` alongside width/opacity.
- **Presets** — both the GIF and Sound dialogs have a **Preset** row at the top to switch whole
  sets in one pick. Pick a name from the dropdown to load that saved set into the fields; type a
  name and click **Save** to store the current set under it (saving over an existing name
  overwrites it); **Delete** removes the named preset. A GIF preset stores the three GIF paths; a
  Sound preset stores the paths, per-state enables, re-nag settings, and volume. Loading a preset
  fills the fields — click the dialog's main **Save** to apply it. Presets persist in
  `settings.json` (`gifPresets` / `sndPresets`).

## Linux (Bazzite / Steam Deck)

On Linux the monitor is a Decky Loader plugin that shows up in Gaming Mode's
Quick Access menu, with toasts when an agent needs input or finishes. See
[`decky/README.md`](decky/README.md). The Windows overlay is unchanged.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (built in).
- [Herdr](https://herdr.dev) v0.8+ installed, with a running session and the
  `herdr` CLI on `PATH`.
