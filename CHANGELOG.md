# Changelog

All notable changes to the Claude Session Monitor overlay are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/), and this
project adheres to [Semantic Versioning](https://semver.org/).

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
