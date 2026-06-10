# Claude Session Monitor

A lightweight, always-on-top Windows overlay that shows every running Claude Code
session globally — across all terminals, projects, and virtual desktops.

## Features

- **Live session list** — reads `~/.claude/sessions/<pid>.json` and refreshes every 2s.
  Each row shows the project folder, the session **PID**, and a coloured status dot
  (🟢 busy · ⚪ idle · 🔴 ended).
- **What each session is doing** — the second line summarises the session's current
  activity, read from its transcript (`~/.claude/projects/<cwd>/<sessionId>.jsonl`).
  Hover a row for the full text plus pid, version, status, and cwd.
- **Click to focus** — left-click a row to bring that session's terminal window to the
  foreground. Works reliably across the foreground-lock and minimised windows.
- **Right-click to link** — for sessions whose terminal can't be auto-identified
  (Windows Terminal exposes only the tab title), focus the terminal once and right-click
  the row to link it. The link is remembered per session.
- **Shown on all desktops** — pinned natively via the Windows virtual-desktop shell API
  (with an automatic "follow the active desktop" fallback if pinning is unavailable).
- **Resizable & adjustable opacity** — drag the right edge to change width; use the
  header slider to change opacity. Both persist across restarts.

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
| `settings.json` | Saved width + opacity (local, git-ignored). |
| `links.json` | Saved session→window links (local, git-ignored). |

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
