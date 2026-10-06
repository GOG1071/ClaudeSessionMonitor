# Changelog

All notable changes to the Claude Session Monitor overlay are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

- **Linux / Bazzite support** as a Decky Loader plugin (`decky/`). It lists
  herdr agents in the Gaming Mode Quick Access menu, sends a toast when an
  agent needs input or finishes (with the same 6s debounce as the overlay), and
  lets you tap an agent to send it a prompt with `herdr agent prompt`.

## [2.0.0] - 2026-09-07

- **Herdr edition.** The overlay no longer reads `~/.claude/sessions/*.json` or
  any Claude Code hooks: it polls `herdr agent list` every 2s and shows every
  AI coding agent running inside [Herdr](https://herdr.dev) (claude, opencode,
  codex, …), colour-coded by herdr's own lifecycle state (working / blocked /
  done / idle).
- Click-to-focus now runs `herdr agent focus` and raises the herdr workspace
  window; right-click also raises it (the old per-row terminal linking is gone
  — herdr owns the terminal).
- Shift-click prompt composer now delivers through `herdr agent prompt`, which
  writes into the pane's own input stream (no keystroke synthesis, no
  clipboard use, works while another window has focus).
- Rows show the herdr pane id as identity, the detected agent kind next to the
  project folder, and the stripped terminal title (the current task) as the
  subtitle. The age column shows herdr's `state_change_seq` counter.
- Added a blue tint for herdr's `done` state; the GIF `done` state falls back
  to the idle GIF and the sound `done` state to the idle sound.
- Header shows **herdr offline** when the herdr server is not running.

## [1.0.12] - 2026-07-17

- The status GIF window now follows the click-through toggle too: while
  click-through is on, clicks pass through it and it fades out completely under
  the cursor, matching the main overlay. Turning click-through off restores it
  and makes it draggable again.

## [1.0.11] - 2026-07-17

- While click-through is on, the overlay now fades out completely whenever the
  cursor is over it, so it never hides what is underneath while you work there.
  The click-through toggle button stays visible and clickable throughout, so you
  can always restore the overlay.

## [1.0.10] - 2026-07-13

- The GIF window no longer falls behind other windows over time. Its topmost
  z-order is now re-asserted on the same timer as the main overlay, fixing the
  case where a terminal grabbing the top slot would silently drop the GIF
  window's always-on-top state.

## [1.0.9] - 2026-06-24

- Clicking the "update available" indicator now runs `git pull` and relaunches
  the overlay in place, instead of opening the repo in a browser.

## [1.0.8] - 2026-06-24

- Merged opacity, GIF, sound, and auto-fit settings into one scrollable popup
  opened from a single ⚙ gear button, replacing the four separate header
  buttons. The popup uses the same minimal scrollbar as the main overlay, and
  its buttons, sliders, text fields, checkboxes, and preset pickers are
  restyled with rounded corners to match the overlay chrome.

## [1.0.7] - 2026-06-24

- The GIF and sound settings popups can now be dragged around — grab either by
  its background to move it off-center.

## [1.0.6] - 2026-06-24

- Hover the version in the header to see the latest changelog entry, sourced
  from this file.

## [1.0.5] - 2026-06-24

- Remember the overlay popup's last position — it now reopens where you last
  dragged it (clamped onto the current screen if a monitor went away).

## [1.0.4] - 2026-06-24

- Re-check for a newer version every minute, not just once at launch.

## [1.0.3] - 2026-06-24

- Keep the settings dialogs and opacity popup above the always-on-top overlay.

## [1.0.2] - 2026-06-24

- Read the update-check version from the private repo via git, so the
  update-available indicator works without a public download.

## [1.0.1] - 2026-06-24

- Randomize the sound re-nag interval within a range so repeated alerts feel
  less robotic.

## [1.0.0] - 2026-06-24

- First versioned release: show the overlay's own version in the header with an
  update-available check.
