import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "py_modules"))

from herdr_monitor import Tracker, parse_agents  # noqa: E402


def agent(pane, status, name="proj"):
    return {"pane": pane, "name": name, "kind": "claude", "title": "", "status": status, "label": status}


class ParseAgentsTest(unittest.TestCase):
    def test_maps_fields_and_sorts_by_status_then_name(self):
        raw = json.dumps({"result": {"agents": [
            {"pane_id": "w1:p1", "agent": "claude", "cwd": "/home/u/zeta/", "agent_status": "idle",
             "terminal_title_stripped": "resting"},
            {"pane_id": "w1:p2", "agent": "codex", "cwd": "/home/u/alpha", "agent_status": "blocked"},
            {"pane_id": "w1:p3", "agent": "claude", "cwd": "/home/u/beta", "agent_status": "working"},
            {"agent": "claude", "cwd": "/no/pane", "agent_status": "working"},
        ]}})
        agents = parse_agents(raw)
        self.assertEqual([a["name"] for a in agents], ["beta", "alpha", "zeta"])
        self.assertEqual(agents[1]["label"], "needs input")
        self.assertEqual(agents[2]["title"], "resting")

    def test_unknown_status_and_missing_cwd(self):
        raw = json.dumps({"result": {"agents": [
            {"pane_id": "w2:p1", "agent": "opencode", "agent_status": "weird"}]}})
        [a] = parse_agents(raw)
        self.assertEqual((a["name"], a["label"]), ("opencode", "unknown"))

    def test_empty_result(self):
        self.assertEqual(parse_agents(json.dumps({"result": {}})), [])


class TrackerTest(unittest.TestCase):
    def setUp(self):
        self.t = Tracker(stable_ms=6000, nag_ms=60000)

    def test_first_sighting_is_silent(self):
        self.assertEqual(self.t.update([agent("p", "blocked")], 0), [])

    def test_transition_fires_only_after_holding_stable(self):
        self.t.update([agent("p", "working")], 0)
        self.assertEqual(self.t.update([agent("p", "blocked")], 2000), [])
        self.assertEqual(self.t.update([agent("p", "blocked")], 4000), [])
        [ev] = self.t.update([agent("p", "blocked")], 8000)
        self.assertEqual((ev["event"], ev["status"]), ("transition", "blocked"))
        self.assertEqual(self.t.update([agent("p", "blocked")], 10000), [])

    def test_flap_back_is_absorbed(self):
        self.t.update([agent("p", "working")], 0)
        self.t.update([agent("p", "idle")], 2000)
        self.assertEqual(self.t.update([agent("p", "working")], 4000), [])
        self.assertEqual(self.t.update([agent("p", "working")], 20000), [])

    def test_blocked_nags_every_interval(self):
        self.t.update([agent("p", "blocked")], 0)
        self.assertEqual(self.t.update([agent("p", "blocked")], 59000), [])
        [ev] = self.t.update([agent("p", "blocked")], 60000)
        self.assertEqual(ev["event"], "nag")
        self.assertEqual(self.t.update([agent("p", "blocked")], 61000), [])

    def test_working_does_not_nag(self):
        self.t.update([agent("p", "working")], 0)
        self.assertEqual(self.t.update([agent("p", "working")], 600000), [])

    def test_vanished_pane_is_rebaselined_silently(self):
        self.t.update([agent("p", "working")], 0)
        self.t.update([], 2000)
        self.assertEqual(self.t.update([agent("p", "blocked")], 4000), [])
        self.assertEqual(self.t.update([agent("p", "blocked")], 20000), [])


if __name__ == "__main__":
    unittest.main()
