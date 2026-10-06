"""herdr polling + transition tracking for the Decky plugin.

Pure logic with no `decky` import, so it is unit-testable off-device. Mirrors the
Windows overlay (overlay.ps1): same `herdr agent list` source, same status
mapping, same 6 s state-flap debounce and silent first-sighting baseline.
"""
import json
import os
import shutil
import subprocess

# herdr agent_status -> human label (overlay.ps1 SessionState.StatusTextFor).
STATUS_LABELS = {
    "working": "working",
    "blocked": "needs input",
    "done": "done",
    "idle": "idle",
}
# Sort order: working, then blocked, then done, then idle/unknown (overlay parity).
STATUS_RANK = {"working": 0, "blocked": 1, "done": 2, "idle": 3}

# herdr classifies a pane from its screen, so a pane running a subagent flaps
# working -> idle -> working. A new state must hold this long before it counts.
STABLE_MS = 6000
# While an agent stays blocked, remind again after this long.
NAG_MS = 60000

CLI_TIMEOUT_S = 5


def herdr_env(user_home, uid=None):
    """Environment for running the herdr CLI as the desktop user.

    Decky starts plugin backends from a system service, so HOME, PATH and
    XDG_RUNTIME_DIR may not match the user's login session. herdr finds its
    server socket through them.
    """
    env = dict(os.environ)
    env["HOME"] = user_home
    if uid is None:
        uid = os.getuid()
    env.setdefault("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    extra = [os.path.join(user_home, ".local", "bin"), os.path.join(user_home, ".cargo", "bin")]
    env["PATH"] = os.pathsep.join(extra + [env.get("PATH", "/usr/local/bin:/usr/bin:/bin")])
    return env


def find_herdr(env):
    """Absolute path of the herdr binary, or None when it is not installed."""
    return shutil.which("herdr", path=env.get("PATH"))


def parse_agents(raw):
    """Turn `herdr agent list` JSON output into sorted display dicts."""
    data = json.loads(raw)
    agents = []
    for rec in (data.get("result") or {}).get("agents") or []:
        pane = rec.get("pane_id")
        if not pane:
            continue
        status = rec.get("agent_status") or "unknown"
        kind = rec.get("agent") or ""
        cwd = (rec.get("cwd") or "").rstrip("/\\")
        name = os.path.basename(cwd.replace("\\", "/")) or cwd or kind
        agents.append({
            "pane": str(pane),
            "name": name,
            "kind": kind,
            "title": rec.get("terminal_title_stripped") or "",
            "status": status,
            "label": STATUS_LABELS.get(status, "unknown"),
        })
    agents.sort(key=lambda a: (STATUS_RANK.get(a["status"], 3), a["name"].lower()))
    return agents


def list_agents(binary, env):
    """One poll. Returns a list of agents, or None when the herdr server is down."""
    try:
        proc = subprocess.run(
            [binary, "agent", "list"], env=env, capture_output=True,
            text=True, timeout=CLI_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return parse_agents(proc.stdout)


def send_prompt(binary, env, pane, text):
    """Deliver text into the agent's pane via `herdr agent prompt`."""
    try:
        proc = subprocess.run(
            [binary, "agent", "prompt", pane, text], env=env,
            capture_output=True, text=True, timeout=CLI_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return proc.returncode == 0


class Tracker:
    """Turns successive polls into alert events.

    - First sighting of a pane is a silent baseline (no alert on launch).
    - A changed status must hold for `stable_ms` before it is confirmed.
    - Each confirmed change yields a "transition" event; a pane that stays
      blocked yields a "nag" event every `nag_ms`.
    """

    def __init__(self, stable_ms=STABLE_MS, nag_ms=NAG_MS):
        self.stable_ms = stable_ms
        self.nag_ms = nag_ms
        self.confirmed = {}   # pane -> confirmed status
        self.pending = {}     # pane -> (candidate status, first seen ms)
        self.last_nag = {}    # pane -> ms of the last transition/nag

    def update(self, agents, now_ms):
        events = []
        seen = set()
        for agent in agents:
            pane, status = agent["pane"], agent["status"]
            seen.add(pane)
            if pane not in self.confirmed:
                self.confirmed[pane] = status
                self.last_nag[pane] = now_ms
                continue
            if status == self.confirmed[pane]:
                self.pending.pop(pane, None)
                if status == "blocked" and now_ms - self.last_nag[pane] >= self.nag_ms:
                    self.last_nag[pane] = now_ms
                    events.append(dict(agent, event="nag"))
                continue
            cand = self.pending.get(pane)
            if cand is None or cand[0] != status:
                self.pending[pane] = (status, now_ms)
            elif now_ms - cand[1] >= self.stable_ms:
                self.confirmed[pane] = status
                self.pending.pop(pane, None)
                self.last_nag[pane] = now_ms
                events.append(dict(agent, event="transition"))
        for pane in list(self.confirmed):
            if pane not in seen:
                self.confirmed.pop(pane, None)
                self.pending.pop(pane, None)
                self.last_nag.pop(pane, None)
        return events
