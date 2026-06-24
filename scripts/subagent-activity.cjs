#!/usr/bin/env node
// ClaudeSessionMonitor — live subagent hook.
//
// Task/Agent subagents have no pid and no ~/.claude/sessions/<pid>.json of their
// own, so the overlay can't see them from the native session files. Claude Code
// fires a SubagentStart event the instant a subagent is spawned and a
// SubagentStop event when it finishes — both carry the parent's session_id
// (shared between a session and its subagents) plus the child's agent_id. This
// hook turns those two events into a per-subagent marker file the overlay globs
// to render each live subagent nested under its parent session row.
//
// Wired into the GLOBAL ~/.claude/settings.json hooks:
//   SubagentStart -> node subagent-activity.cjs start   (a subagent was spawned)
//   SubagentStop  -> node subagent-activity.cjs stop     (a subagent finished)
//
// It reads the hook payload from stdin (JSON with session_id, agent_id,
// agent_type, prompt, cwd) and writes/removes a marker at
//   ~/.claude/session-subagents/<session_id>/<agent_id>.json
// keyed by the PARENT session_id (the directory) and the child agent_id (the
// file) so overlay.ps1 can join it to the native session's sessionId field and
// nest the child under it. The marker carries a millisecond `startedAt`. Normal
// removal is the SubagentStop `stop` below; the overlay also reaps a parent's
// whole dir when its native session file is gone and skips markers older than a
// staleness window, so a missed `stop` can never pin a ghost child forever.
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

// Filesystem-safe token for use as a path segment (session_id is a UUID and
// agent_id is dash-free hex, so this is defensive only).
function safe(s) {
  return String(s == null ? '' : s).replace(/[^A-Za-z0-9._-]/g, '');
}

function main() {
  const action = (process.argv[2] || '').trim();

  let payload = {};
  const raw = readStdin();
  if (raw) {
    try { payload = JSON.parse(raw); } catch { payload = {}; }
  }

  const sessionId = safe(payload.session_id || payload.sessionId);
  const agentId = safe(payload.agent_id || payload.agentId);
  if (!sessionId || !agentId) return; // no parent/child key — nothing to record

  const dir = path.join(os.homedir(), '.claude', 'session-subagents', sessionId);
  const file = path.join(dir, `${agentId}.json`);

  if (action === 'stop') {
    try { fs.unlinkSync(file); } catch { /* already gone */ }
    // Drop the parent dir too once its last child is gone (best-effort).
    try { fs.rmdirSync(dir); } catch { /* not empty or already gone */ }
    return;
  }

  if (action === 'start') {
    const agentType = payload.agent_type || payload.agentType || '';
    const prompt = payload.prompt || '';
    try {
      fs.mkdirSync(dir, { recursive: true });
      const obj = {
        agentType: String(agentType || ''),
        task: clip(String(prompt || '').split('\n')[0], 80),
        startedAt: Date.now(),
      };
      const tmp = file + '.tmp';
      fs.writeFileSync(tmp, JSON.stringify(obj));
      fs.renameSync(tmp, file); // atomic publish
    } catch { /* swallow — never disrupt Claude Code */ }
    return;
  }
}

try { main(); } catch { /* never throw into the hook runner */ }
