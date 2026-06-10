# Install

Setup guide for **Claude Session Monitor** (the `overlay.ps1` overlay + the
`waiting` attention hook). Works on a fresh Windows machine.

---

## Prerequisites

- **Windows 10/11** — Windows PowerShell 5.1 and .NET/WPF are built in.
- **Node.js** in your `PATH` (`node --version` should print a version). Needed by the attention hook.
- **Claude Code** installed — it writes `~/.claude/sessions/<pid>.json`, which the overlay reads.

---

## For a user (manual, ~2 minutes)

1. **Clone the repo** anywhere, e.g. `C:\Tools\ClaudeSessionMonitor`. Remember this folder path.

2. **Add two hooks** so Claude reports when it needs your input. Open (or create) the file:

   ```
   %USERPROFILE%\.claude\settings.json
   ```

   If the file is empty/new, start with `{ "hooks": {} }`. Then add a `Notification` and a
   `UserPromptSubmit` entry — replacing `C:/Tools/ClaudeSessionMonitor` with **your** clone path
   (use forward slashes):

   ```json
   {
     "hooks": {
       "Notification": [
         {
           "hooks": [
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-attention.cjs\" waiting" }
           ]
         }
       ],
       "UserPromptSubmit": [
         {
           "hooks": [
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-attention.cjs\" clear" }
           ]
         }
       ]
     }
   }
   ```

   > Already have a `settings.json` with other hooks? Don't replace it — just add these two
   > objects into the existing `Notification` and `UserPromptSubmit` arrays (create the array if
   > it isn't there). Leave every other hook untouched.

3. **Restart any open Claude Code sessions.** Hooks load at session start, so currently-running
   sessions won't report `waiting` until relaunched.

4. **Run the overlay** — double-click `Start Overlay.vbs`, or:

   ```powershell
   powershell -ExecutionPolicy Bypass -File overlay.ps1
   ```

5. *(Optional)* Click the **GIF** button in the header to set a GIF per state
   (running / needs-input / idle).

That's it. A session waiting on your input turns **yellow** (and shows the needs-input GIF)
within ~2 seconds; it returns to running/idle on its own once you reply.

---

## For Claude (automated setup)

If you are an AI agent setting this up, do exactly this:

1. Determine the repo's absolute path (the folder containing `overlay.ps1`). Call it `<REPO>`.
   Convert backslashes to forward slashes for the JSON commands.

2. Confirm prerequisites: `node --version` succeeds; the path `<REPO>/scripts/session-attention.cjs`
   exists.

3. Read `%USERPROFILE%\.claude\settings.json` (path: `$env:USERPROFILE\.claude\settings.json`).
   If it does not exist, create it as `{ "hooks": {} }`.

4. **Idempotently** ensure these two command strings are present — do not duplicate if a hook with
   the same command already exists, and do not remove or reorder any other hooks:

   - In `hooks.Notification[].hooks[]`:
     `node "<REPO>/scripts/session-attention.cjs" waiting`
   - In `hooks.UserPromptSubmit[].hooks[]`:
     `node "<REPO>/scripts/session-attention.cjs" clear`

   Each goes inside an object of the form `{ "hooks": [ { "type": "command", "command": "..." } ] }`,
   appended to the corresponding array (create the array if missing).

5. Validate the file still parses as JSON (e.g. `node -e "JSON.parse(require('fs').readFileSync(process.env.USERPROFILE+'/.claude/settings.json','utf8'))"`).

6. Tell the user to **restart their Claude Code sessions** (hooks load at session start) and to run
   the overlay (`Start Overlay.vbs` or `powershell -ExecutionPolicy Bypass -File overlay.ps1`).

**Do not** add anything else, and **do not** touch unrelated hooks already in the file.

---

## How it works (one paragraph)

Claude Code's native `~/.claude/sessions/<pid>.json` only ever reports `busy` or `idle` — never
"waiting for you." The `Notification` hook runs `scripts/session-attention.cjs`, which drops a
marker file in `~/.claude/session-attention/` when Claude needs input; the `UserPromptSubmit` hook
clears it when you reply. The overlay shows **needs-input** for any live, non-busy session that has
a marker, and reaps the marker automatically when the session goes busy or ends. No hooks → the
overlay still works, but only shows running/idle.

---

## Per-machine state (not shared via git)

`settings.json` (overlay width/opacity/GIF paths) and `links.json` (row→terminal links) are
git-ignored, so they don't travel with the repo — reconfigure them via the overlay UI on each
machine. The `~/.claude/settings.json` hooks are global to the machine and must be added per the
steps above.
