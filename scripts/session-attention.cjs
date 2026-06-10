#!/usr/bin/env node
// ClaudeSessionMonitor — needs_input detector hook.
//
// The native ~/.claude/sessions/<pid>.json files Claude Code writes only ever
// carry status "busy" or "idle" — there is no native "needs_input". This hook
// supplies that missing signal so overlay.ps1 can tint a row yellow + swap to
// the needs_input GIF whenever Claude is blocked waiting for the user.
//
// Wired into the GLOBAL ~/.claude/settings.json hooks:
//   Notification      -> node session-attention.cjs needs_input   (Claude asks / waits)
//   UserPromptSubmit  -> node session-attention.cjs clear          (user replied)
//   PreToolUse        -> node session-attention.cjs clear          (Claude resumed work)
//
// It reads the Claude Code hook payload from stdin (JSON with session_id, cwd,
// ...) and writes/removes a marker file at
//   ~/.claude/session-attention/<session_id>.json
// keyed by session_id so overlay.ps1 can join it to the native session's
// sessionId field. The marker carries a millisecond `updatedAt`; the overlay
// only honors it while it is NEWER than the native status timestamp, so a
// missed `clear` can never pin a row to needs_input forever (once Claude
// resumes, the native updatedAt advances past the stale marker).
//
// Must NEVER throw into Claude Code — every failure is swallowed (exit 0).

const fs = require('fs');
const path = require('path');
const os = require('os');

// Read the hook payload from stdin. Returns null when nothing is piped (e.g.
// run interactively). Strips a leading UTF-8 BOM some shells prepend.
function readStdin() {
  try {
    if (process.stdin.isTTY) return null;
    let raw = fs.readFileSync(0, 'utf8'); // fd 0
    if (raw.charCodeAt(0) === 0xfeff) raw = raw.slice(1);
    return raw && raw.trim() ? raw : null;
  } catch {
    return null;
  }
}

function main() {
  const action = (process.argv[2] || '').trim();

  let payload = {};
  const raw = readStdin();
  if (raw) {
    try { payload = JSON.parse(raw); } catch { payload = {}; }
  }

  const sessionId = payload.session_id || payload.sessionId;
  if (!sessionId) return; // no key to record against — nothing to do

  const dir = path.join(os.homedir(), '.claude', 'session-attention');
  const file = path.join(dir, `${sessionId}.json`);

  if (action === 'clear') {
    try { fs.unlinkSync(file); } catch { /* already gone */ }
    return;
  }

  if (action === 'needs_input') {
    try {
      fs.mkdirSync(dir, { recursive: true });
      const obj = {
        sessionId,
        cwd: payload.cwd || '',
        kind: 'needs_input',
        updatedAt: Date.now(),
      };
      const tmp = file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(obj));
      fs.renameSync(tmp, file); // atomic publish
    } catch { /* swallow — never disrupt Claude Code */ }
    return;
  }
}

try { main(); } catch { /* never throw into the hook runner */ }
