#!/usr/bin/env node
// ClaudeSessionMonitor — last-user-prompt hook.
//
// The overlay can only guess the current user prompt by tail-parsing the
// transcript JSONL (last ~80 lines, clipped) — which is lossy: a long turn can
// push the prompt out of the tail window, and tool_result / system lines muddy
// the pick. This hook captures the EXACT prompt the instant the user submits it,
// so overlay.ps1 can show it verbatim instead of reconstructing it.
//
// Wired into the GLOBAL ~/.claude/settings.json hooks:
//   UserPromptSubmit -> node session-prompt.cjs set     (user submitted a prompt)
//
// It reads the Claude Code hook payload from stdin (JSON with session_id, cwd,
// prompt, ...) and writes a marker at
//   ~/.claude/session-prompt/<session_id>.json
// keyed by session_id so overlay.ps1 can join it to the native session's
// sessionId field. The marker persists (no clear) — it always reflects the most
// recent prompt — and is reaped by the overlay once the native session file is
// gone, so the directory stays bounded.
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

// Collapse whitespace and hard-cap so the overlay never has to.
function clip(s, n) {
  const t = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n - 1) + '…' : t; // … ellipsis
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

  const dir = path.join(os.homedir(), '.claude', 'session-prompt');
  const file = path.join(dir, `${sessionId}.json`);

  if (action === 'clear') {
    try { fs.unlinkSync(file); } catch { /* already gone */ }
    return;
  }

  if (action === 'set') {
    const prompt = clip(payload.prompt || payload.user_prompt || '', 200);
    if (!prompt) return; // empty submit — leave the previous prompt in place
    try {
      fs.mkdirSync(dir, { recursive: true });
      const obj = {
        sessionId,
        cwd: payload.cwd || '',
        prompt,
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
