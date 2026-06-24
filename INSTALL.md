# Install

Setup guide for **Claude Session Monitor** (the `overlay.ps1` overlay + two
hooks: the `waiting` attention hook and the live-activity hook). Works on a
fresh Windows machine.

---

## Prerequisites

- **Windows 10/11** — Windows PowerShell 5.1 and .NET/WPF are built in.
- **Node.js** in your `PATH` (`node --version` should print a version). Needed by the hooks.
- **Claude Code** installed — it writes `~/.claude/sessions/<pid>.json`, which the overlay reads.

---

## For a user (manual, ~2 minutes)

1. **Clone the repo** anywhere, e.g. `C:\Tools\ClaudeSessionMonitor`. Remember this folder path.

2. **Add the hooks** so Claude reports when it needs your input *and* what each session is
   doing. Open (or create) the file:

   ```
   %USERPROFILE%\.claude\settings.json
   ```

   If the file is empty/new, start with `{ "hooks": {} }`. Then add the entries below —
   replacing `C:/Tools/ClaudeSessionMonitor` with **your** clone path (use forward slashes):

   ```json
   {
     "hooks": {
       "PreToolUse": [
         {
           "matcher": ".*",
           "hooks": [
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-activity.cjs\" start" },
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-attention.cjs\" clear" }
           ]
         }
       ],
       "Stop": [
         {
           "hooks": [
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-activity.cjs\" stop" }
           ]
         }
       ],
       "SubagentStart": [
         {
           "hooks": [
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/subagent-activity.cjs\" start" }
           ]
         }
       ],
       "SubagentStop": [
         {
           "hooks": [
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/subagent-activity.cjs\" stop" }
           ]
         }
       ],
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
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-attention.cjs\" clear" },
             { "type": "command", "command": "node \"C:/Tools/ClaudeSessionMonitor/scripts/session-prompt.cjs\" set" }
           ]
         }
       ]
     }
   }
   ```

   Both hooks are independent — you can install just the `session-attention.cjs` lines (needs-input
   only) or just the `session-activity.cjs` lines (live activity only).

   > Already have a `settings.json` with other hooks? Don't replace it — just merge these
   > objects into the matching event arrays (create an array if it isn't there). The `PreToolUse`
   > entry uses `"matcher": ".*"` so it fires for every tool. Leave every other hook untouched.

3. **Restart any open Claude Code sessions.** Hooks load at session start, so currently-running
   sessions won't report `waiting`/activity until relaunched.

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

2. Confirm prerequisites: `node --version` succeeds; the paths `<REPO>/scripts/session-attention.cjs`,
   `<REPO>/scripts/session-activity.cjs`, `<REPO>/scripts/session-prompt.cjs`, and
   `<REPO>/scripts/subagent-activity.cjs` exist.

3. Read `%USERPROFILE%\.claude\settings.json` (path: `$env:USERPROFILE\.claude\settings.json`).
   If it does not exist, create it as `{ "hooks": {} }`.

4. **Idempotently** ensure these command strings are present — do not duplicate if a hook with
   the same command already exists, and do not remove or reorder any other hooks:

   - In `hooks.PreToolUse[].hooks[]` (inside an entry with `"matcher": ".*"`):
     `node "<REPO>/scripts/session-activity.cjs" start`
     `node "<REPO>/scripts/session-attention.cjs" clear`
   - In `hooks.Stop[].hooks[]`:
     `node "<REPO>/scripts/session-activity.cjs" stop`
   - In `hooks.SubagentStart[].hooks[]`:
     `node "<REPO>/scripts/subagent-activity.cjs" start`
   - In `hooks.SubagentStop[].hooks[]`:
     `node "<REPO>/scripts/subagent-activity.cjs" stop`
   - In `hooks.Notification[].hooks[]`:
     `node "<REPO>/scripts/session-attention.cjs" waiting`
   - In `hooks.UserPromptSubmit[].hooks[]`:
     `node "<REPO>/scripts/session-attention.cjs" clear`
     `node "<REPO>/scripts/session-prompt.cjs" set`

   Each goes inside an object of the form `{ "hooks": [ { "type": "command", "command": "..." } ] }`
   (the `PreToolUse` object also needs `"matcher": ".*"`), appended to the corresponding array
   (create the array if missing).

5. Validate the file still parses as JSON (e.g. `node -e "JSON.parse(require('fs').readFileSync(process.env.USERPROFILE+'/.claude/settings.json','utf8'))"`).

6. Tell the user to **restart their Claude Code sessions** (hooks load at session start) and to run
   the overlay (`Start Overlay.vbs` or `powershell -ExecutionPolicy Bypass -File overlay.ps1`).
   Activity-hook changes to `overlay.ps1` also require restarting the overlay.

**Do not** add anything else, and **do not** touch unrelated hooks already in the file.

---

## How it works (one paragraph)

Claude Code's native `~/.claude/sessions/<pid>.json` only ever reports `busy` or `idle` — never
"waiting for you," and never *what* it's doing. Two hooks fill those gaps:

- **`session-attention.cjs`** (needs-input). The `Notification` hook drops a marker in
  `~/.claude/session-attention/` when Claude needs input; the `UserPromptSubmit` (and `PreToolUse`)
  hook clears it when you reply / resume. The overlay shows **needs-input** for any live, non-busy
  session that has a marker, reaping it automatically when the session goes busy or ends.
- **`session-activity.cjs`** (live activity). The `PreToolUse` hook writes the precise current
  action ("Editing overlay.ps1", "Bash: git status", "Read settings.json") to
  `~/.claude/session-status/`; `Stop` clears it. The overlay shows this line — in
  place of the coarser transcript-derived one — while the session is busy, and reaps stale markers
  the moment a session goes idle or ends.
- **`session-prompt.cjs`** (last user prompt). The `UserPromptSubmit` hook writes the exact prompt
  the user just submitted to `~/.claude/session-prompt/`. The overlay shows it verbatim on the row —
  in place of the lossy transcript tail-parse, which can drop the prompt out of its window on long
  turns. The marker persists for the session (overwritten on each new prompt) and is reaped once the
  native session file is gone.
- **`subagent-activity.cjs`** (live subagents). Task/Agent subagents have no pid and no native
  session file, so they're otherwise invisible. The `SubagentStart` hook writes one marker per live
  spawn under `~/.claude/session-subagents/<parentSessionId>/<agentId>.json` (the parent's session_id
  is shared with its subagents, so it's the directory key); `SubagentStop` deletes it. The overlay
  nests each live subagent as a teal child row directly under its parent session, showing the agent
  type and spawn prompt. A missed `stop` self-heals — the overlay reaps a parent's whole dir when the
  native session is gone and skips markers older than 30 minutes.

No hooks → the overlay still works, but only shows running/idle with the transcript-derived activity
and no nested subagents.

---

## Per-machine state (not shared via git)

`settings.json` (overlay width/opacity/GIF paths) and `links.json` (row→terminal links) are
git-ignored, so they don't travel with the repo — reconfigure them via the overlay UI on each
machine. The `~/.claude/settings.json` hooks are global to the machine and must be added per the
steps above.
