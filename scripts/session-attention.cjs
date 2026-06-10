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
// The Notification hook fires for TWO distinct reasons:
//   1. Claude is blocked needing the user to continue — e.g. "Claude needs your
//      permission to use Bash". This is a genuine needs_input.
//   2. The prompt input has been idle ~60s after Claude FINISHED its turn — e.g.
//      "Claude is waiting for your input". This is NOT needs_input; Claude isn't
//      blocked, it just finished and is sitting idle. Treating it as needs_input
//      turns a completed task yellow, which is the bug this filter fixes.
// We distinguish them by the notification `message`: idle-reminder messages are
// ignored, everything else (permission / approval prompts) sets the marker.
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
    // Ignore the idle-timeout reminder ("Claude is waiting for your input"),
    // which fires ~60s after Claude finishes a turn — Claude isn't blocked, so
    // this must NOT turn the row yellow. Only genuine blocking notifications
    // (permission / approval prompts) get through. We do NOT clear an existing
    // marker here: a real pending prompt that the user ignores for 60s would
    // also emit this reminder, and that marker should survive.
    const message = String(payload.message || '');
    if (/waiting for your input/i.test(message)) return;

    try {
      fs.mkdirSync(dir, { recursive: true });
      const obj = {
        sessionId,
        cwd: payload.cwd || '',
        kind: 'needs_input',
        message,
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
