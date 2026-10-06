import asyncio
import json
import os
import time

import decky

from herdr_monitor import Tracker, find_herdr, herdr_env, list_agents, send_prompt

POLL_SECONDS = 2
DEFAULT_SETTINGS = {
    "notify_blocked": True,   # toast when an agent starts waiting for input
    "notify_done": True,      # toast when an agent finishes its turn
    "nag_blocked": True,      # repeat the needs-input toast every minute
}


def _settings_path():
    return os.path.join(decky.DECKY_PLUGIN_SETTINGS_DIR, "settings.json")


def _load_settings():
    settings = dict(DEFAULT_SETTINGS)
    try:
        with open(_settings_path(), encoding="utf-8") as f:
            stored = json.load(f)
        settings.update({k: bool(v) for k, v in stored.items() if k in DEFAULT_SETTINGS})
    except FileNotFoundError:
        pass
    except (OSError, ValueError):
        decky.logger.exception("could not read settings, using defaults")
    return settings


class Plugin:
    async def _main(self):
        self.settings = _load_settings()
        self.env = herdr_env(decky.DECKY_USER_HOME)
        self.tracker = Tracker()
        self.snapshot = {"installed": False, "online": False, "agents": []}
        self.poll_task = asyncio.get_event_loop().create_task(self._poll_loop())
        decky.logger.info("Claude Session Monitor started")

    async def _unload(self):
        self.poll_task.cancel()

    async def _poll_loop(self):
        while True:
            try:
                await self._poll_once()
            except Exception:
                decky.logger.exception("herdr poll failed")
            await asyncio.sleep(POLL_SECONDS)

    async def _poll_once(self):
        binary = find_herdr(self.env)
        agents = await asyncio.to_thread(list_agents, binary, self.env) if binary else None
        self.snapshot = {
            "installed": binary is not None,
            "online": agents is not None,
            "agents": agents or [],
        }
        await decky.emit("snapshot", self.snapshot)
        for event in self.tracker.update(agents or [], int(time.time() * 1000)):
            if self._should_alert(event):
                await decky.emit("alert", event)

    def _should_alert(self, event):
        if event["status"] == "blocked":
            key = "nag_blocked" if event["event"] == "nag" else "notify_blocked"
            return self.settings[key]
        return event["status"] == "done" and self.settings["notify_done"]

    async def get_snapshot(self):
        return self.snapshot

    async def prompt_agent(self, pane, text):
        binary = find_herdr(self.env)
        if not binary or not text.strip():
            return False
        return await asyncio.to_thread(send_prompt, binary, self.env, pane, text)

    async def get_settings(self):
        return self.settings

    async def set_setting(self, key, value):
        if key not in DEFAULT_SETTINGS:
            raise ValueError(f"unknown setting: {key}")
        self.settings[key] = bool(value)
        os.makedirs(decky.DECKY_PLUGIN_SETTINGS_DIR, exist_ok=True)
        with open(_settings_path(), "w", encoding="utf-8") as f:
            json.dump(self.settings, f, indent=2)
        return self.settings
