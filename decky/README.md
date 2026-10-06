# Claude Session Monitor for Bazzite / Steam Deck (Decky plugin)

The Windows overlay can't be shown in Gaming Mode: gamescope only displays the
focused app, so no floating window can sit on top of a game. On Linux the
monitor is a [Decky Loader](https://decky.xyz) plugin instead. Bazzite ships
Decky Loader.

- **Quick Access panel** (the `…` button, then the plugin's robot icon) lists
  every agent running in herdr: project, agent kind, task title, and a status
  dot (green = working, yellow = needs input, blue = done, gray = idle).
- **Toasts while you play.** You get a Steam notification with sound when an
  agent needs input or finishes, plus a reminder every minute while it is still
  waiting. Each one can be switched off in the panel. A status must hold for 6s
  before it counts, so a pane flapping during a subagent run doesn't spam you.
  Agents already running when the plugin starts don't trigger a notification.
- **Tap an agent to prompt it.** Type with the Steam keyboard. The text is
  sent with `herdr agent prompt`.

## Requirements

- herdr installed for your user. The default installer puts it in
  `~/.local/bin`:

  ```sh
  curl -fsSL https://herdr.dev/install.sh | sh
  ```

- A herdr server that keeps running after you switch to Gaming Mode. Run it as
  a systemd user service:

  ```sh
  mkdir -p ~/.config/systemd/user
  cat > ~/.config/systemd/user/herdr.service <<'UNIT'
  [Unit]
  Description=herdr server

  [Service]
  ExecStart=%h/.local/bin/herdr server
  Restart=on-failure

  [Install]
  WantedBy=default.target
  UNIT
  systemctl --user enable --now herdr.service
  ```

  Start your agents in herdr from Desktop Mode or over SSH. They keep running
  when you switch to Gaming Mode.

## Build and install

You can build on any machine with Node 18+ and Python 3:

```sh
cd decky
npm install
npm test          # backend unit tests
npm run package   # writes out/claude-session-monitor.zip
```

Copy the zip to the Bazzite machine. Then, in Gaming Mode, open Decky's
settings (gear icon in the Decky tab), go to **General**, and turn on
**Developer mode**. In the new **Developer** tab, pick **Install Plugin from
ZIP File** and choose the zip.

## Troubleshooting

- **"herdr not found"**: the plugin looks for `herdr` on `PATH`, then in
  `~/.local/bin` and `~/.cargo/bin`.
- **"herdr offline"**: `herdr agent list` failed. Check the server with
  `systemctl --user status herdr`.
- Backend logs are in `~/homebrew/logs/claude-session-monitor/`.

## Layout

| Path | Purpose |
|------|---------|
| `main.py` | Decky backend: polls herdr every 2s and emits snapshots and alerts. |
| `py_modules/herdr_monitor.py` | Pure herdr logic: CLI calls, parsing, debounce and reminder tracking. |
| `src/index.tsx` | Quick Access panel UI and toasts. |
| `tests/` | Unit tests for `herdr_monitor.py` (`npm test`). |
| `package.py` | Builds the installable zip. |
