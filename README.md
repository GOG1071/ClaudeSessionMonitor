# Claude Session Monitor

A lightweight, always-on-top Windows overlay that shows every running Claude Code
session globally — across all terminals, projects, and virtual desktops.

> **Setting up on a new machine?** See [INSTALL.md](INSTALL.md) — it covers the one
> step that isn't in the repo: registering the `waiting` attention hook and the
> live-activity hook in `~/.claude/settings.json`.

## Features

- **Live session list** — reads `~/.claude/sessions/<pid>.json` and refreshes every 2s.
  Each row shows the project folder and the session **PID**, with a **status-coloured row
  background** (🟢 busy · 🟡 needs-input · ⚪ idle · 🔴 ended).
- **What each session is doing** — under the session name, the **recent prompt** line
  (italic amber) shows the most recent user prompt, and the activity line summarises what
  the session is currently doing. With the **live-activity hook** installed (see
  [INSTALL.md](INSTALL.md)), a busy session shows the precise current action — `Editing
  overlay.ps1`, `Bash: git status`, `Read settings.json`, `Agent: <task>` — pushed the instant
  each tool runs (`~/.claude/session-status/`). Without the hook it falls back to a coarser
  summary read from the transcript (`~/.claude/projects/<cwd>/<sessionId>.jsonl`). Hover a row
  for the full text plus pid, version, status, and cwd.
- **Click to focus** — left-click a row to bring that session's terminal window to the
  foreground. Works reliably across the foreground-lock and minimised windows.
- **Shift-click to prompt** — Shift+left-click a row to open an inline composer that reads like
  Claude's own input: a `>` chevron, placeholder text, **Enter** to send, **Shift+Enter** for a
  newline (the box auto-grows, then scrolls), and **↑ / ↓** to recall prompts you've sent to that
  session this run. **Esc** cancels. The overlay focuses the session's terminal and delivers the
  prompt for you — single-line as Unicode keystrokes, multi-line via a clipboard-preserving paste
  (the clipboard is saved and restored) — then submits it.
- **Right-click to link** — for sessions whose terminal can't be auto-identified
  (Windows Terminal exposes only the tab title), focus the terminal once and right-click
  the row to link it. The link is remembered per session.
- **Shown on all desktops** — pinned natively via the Windows virtual-desktop shell API
  (with an automatic "follow the active desktop" fallback if pinning is unavailable).
- **Pin toggle** — the 📌 button in the header turns the always-on-top + show-on-all-desktops
  behaviour on (default) or off. When off, the overlay is a normal window that stays on its
  current desktop. The choice persists across restarts.
- **Resizable & adjustable opacity** — drag the right edge to change width; use the
  header slider to change opacity. Both persist across restarts.
- **Status GIF** — an optional separate floating window shows a different animated GIF
  depending on the overall Claude state across all sessions: **needs-input** (a session
  waiting for you) takes priority over **running** (any busy session), which takes
  priority over **idle**. Click the **GIF** button in the header to set a GIF per state.

## Install / run

1. Clone the repo anywhere.
2. Double-click **`Start Overlay.vbs`** (launches with no console window).

To start it automatically at login, drop a shortcut to `Start Overlay.vbs` into your
Startup folder (`shell:startup`).

## Files

| File | Purpose |
|------|---------|
| `overlay.ps1` | The overlay (WPF in Windows PowerShell 5.1). |
| `Start Overlay.vbs` | Launches `overlay.ps1` hidden. |
| `scripts/session-attention.cjs` | Hook: marks a session **needs-input** (Notification) and clears it (UserPromptSubmit / PreToolUse). |
| `scripts/session-activity.cjs` | Hook: writes a session's **live activity** line (PreToolUse) and clears it (Stop / SubagentStop). |
| `settings.json` | Saved width, opacity + status-GIF config (local, git-ignored). |
| `links.json` | Saved session→window links (local, git-ignored). |

## Status GIF

Click the **GIF** button in the header to open the settings dialog and paste a GIF for each
state (**Running**, **Needs input**, **Idle**). Each value is a local file path (e.g.
`D:\gifs\working.gif`) or a `file://` / `http(s)://` URL; leave a state blank to show nothing
for it. The floating GIF window only appears when the current state has a GIF configured.

- Drag the GIF window anywhere to move it; drag its bottom-right corner to resize. Position
  and size persist across restarts.
- Busy and idle map directly from each session's native status (`busy` → **running**,
  otherwise → **idle**). Dead-process sessions are ignored.
- **Needs-input requires the attention hook.** Claude Code's native `~/.claude/sessions`
  files only ever report `busy`/`idle` — never `waiting` — so the *waiting-for-you* state
  comes from `scripts/session-attention.cjs`, wired into `~/.claude/settings.json` as a
  `Notification` hook (writes a marker when Claude needs input) and a `UserPromptSubmit` hook
  (clears it when you reply). The overlay shows **needs input** for any alive, non-busy session
  that has a marker; markers are reaped automatically when the session goes busy or ends. Without
  these hooks installed, sessions only ever show running/idle.
- GIFs are decoded and animated natively (no external dependencies). For best results use GIFs
  with a transparent background — the window itself is transparent and always-on-top, and shows
  on every virtual desktop like the main overlay.
- Per-state GIF paths are saved in `settings.json` alongside width/opacity.

## Notes / limitations

- The native virtual-desktop pin uses COM GUIDs for Windows 11 24H2/25H2
  (build 261xx/262xx). On other builds the overlay automatically falls back to
  follow-the-active-desktop mode.
- Windows Terminal runs as a single process hosting all windows/tabs, so a session can
  only be auto-matched to its window when the tab/window title contains the project
  folder name; otherwise use right-click to link it.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (built in).
- Claude Code writing session files under `~/.claude/`.
