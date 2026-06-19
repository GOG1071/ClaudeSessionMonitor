#!/usr/bin/env node
// ClaudeSessionMonitor — live activity hook.
//
// The native ~/.claude/sessions/<pid>.json only carries busy/idle, and the
// overlay's transcript tail-parse can only surface a bare tool NAME ("running
// Bash") — never the target. This hook supplies the precise "what right now"
// line ("Bash: git status", "Editing overlay.ps1", "Read transcript.jsonl")
// the instant a tool starts, so overlay.ps1 can show exactly what each busy
// session is doing without parsing the JSONL.
//
// Wired into the GLOBAL ~/.claude/settings.json hooks:
//   PreToolUse    -> node session-activity.cjs start   (a tool is about to run)
//   Stop          -> node session-activity.cjs stop    (turn finished)
//
// It reads the Claude Code hook payload from stdin (JSON with session_id, cwd,
// tool_name, tool_input, ...) and writes/removes a marker at
//   ~/.claude/session-status/<session_id>.json
// keyed by session_id so overlay.ps1 can join it to the native session's
// sessionId field. The marker carries a millisecond `updatedAt`. The overlay
// only honors it while the session is alive AND busy, so a missed `stop` can
// never pin a stale activity forever — once the session goes idle the overlay
// ignores and reaps the marker (same self-healing rule as session-attention).
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

// Collapse whitespace and hard-cap a string so the overlay never has to.
function clip(s, n) {
  const t = String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n - 1) + '…' : t; // … ellipsis
}

// Basename of a path-ish string, tolerant of both slash styles.
function baseName(p) {
  const t = String(p || '').replace(/[\\/]+$/, '');
  const i = Math.max(t.lastIndexOf('\\'), t.lastIndexOf('/'));
  return i >= 0 ? t.slice(i + 1) : t;
}

// Turn (tool_name, tool_input) into one short human-readable activity line.
function describe(tool, input) {
  const t = String(tool || '').trim();
  const inp = input && typeof input === 'object' ? input : {};

  switch (t) {
    case 'Bash':       return 'Bash: ' + clip(String(inp.command || '').split('\n')[0], 60);
    case 'Read':       return 'Read ' + clip(baseName(inp.file_path), 48);
    case 'Edit':
    case 'MultiEdit':  return 'Editing ' + clip(baseName(inp.file_path), 48);
    case 'Write':      return 'Writing ' + clip(baseName(inp.file_path), 48);
    case 'NotebookEdit': return 'Editing ' + clip(baseName(inp.notebook_path), 48);
    case 'Glob':       return 'Glob ' + clip(inp.pattern, 48);
    case 'Grep':       return 'Grep ' + clip(inp.pattern, 48);
    case 'Skill':      return 'Skill ' + clip(inp.skill || inp.command, 48);
    case 'WebFetch':   { try { return 'Fetch ' + clip(new URL(inp.url).host, 48); } catch { return 'WebFetch'; } }
    case 'WebSearch':  return 'Search: ' + clip(inp.query, 56);
    case 'TodoWrite':  return 'Updating tasks';
    case 'ExitPlanMode': return 'Presenting plan';
  }

  // MCP tools arrive as mcp__<server>__<tool>; show "<tool> (<server>)".
  const mcp = /^mcp__([^_]+(?:_[^_]+)*?)__(.+)$/.exec(t);
  if (mcp) return clip(mcp[2].replace(/_/g, ' ') + ' (' + mcp[1] + ')', 64);

  return clip(t || 'working', 48);
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

  const dir = path.join(os.homedir(), '.claude', 'session-status');
  const file = path.join(dir, `${sessionId}.json`);

  if (action === 'stop') {
    try { fs.unlinkSync(file); } catch { /* already gone */ }
    return;
  }

  if (action === 'start') {
    const tool = payload.tool_name || payload.toolName || '';
    const input = payload.tool_input || payload.toolInput || {};
    try {
      fs.mkdirSync(dir, { recursive: true });
      const obj = {
        sessionId,
        cwd: payload.cwd || '',
        tool: String(tool || ''),
        activity: describe(tool, input),
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
