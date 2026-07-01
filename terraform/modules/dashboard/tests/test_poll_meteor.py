import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import dashboard  # noqa: E402


class PollMeteorTest(unittest.TestCase):
    def test_down_when_status_unreachable(self):
        with mock.patch.object(dashboard, "_get_json", return_value=(None, "unreachable")):
            t = dashboard.poll_meteor()
        self.assertEqual(t["title"], "Meteor")
        self.assertEqual(t["state"], "down")

    def test_headline_and_upcoming_and_thumb(self):
        soon = __import__("time").time() + 1800  # 30 min out
        def fake_get(url):
            if url.endswith("/api/wxsat/status"):
                return ({"state": "idle", "dry_run": False,
                         "next_pass": {"satellite": "METEOR-M2 4", "max_elev": 62,
                                       "aos_unix": soon}}, None)
            if url.endswith("/api/wxsat/passes"):
                return ({"passes": [{"satellite": "METEOR-M2 4", "max_elev": 62,
                                     "aos_unix": soon}]}, None)
            if url.endswith("/api/wxsat/captures"):
                return ({"captures": [{"satellite": "METEOR-M2 4", "image": "d/full.png",
                                       "thumb": "d/thumb.png", "created": 123, "outcome": "image"}]}, None)
            return (None, "n/a")
        with mock.patch.object(dashboard, "_get_json", side_effect=fake_get):
            t = dashboard.poll_meteor()
        self.assertEqual(t["state"], "ok")
        self.assertIn("METEOR-M2 4", t["headline"])
        self.assertTrue(t["upcoming"])
        self.assertEqual(t["upcoming"][0]["elev"], 62)
        self.assertTrue(t["image_url"].startswith("/api/proxy/meteor-latest.png"))
        # the proxy path global points at the radio image route
        self.assertEqual(dashboard._METEOR_IMG["path"], "/api/wxsat/image/d/thumb.png")

    def test_passes_as_bare_list_and_no_captures(self):
        def fake_get(url):
            if url.endswith("/api/wxsat/status"):
                return ({"state": "scheduled"}, None)
            if url.endswith("/api/wxsat/passes"):
                return ([{"satellite": "METEOR-M2 3", "max_elev": 20, "aos_unix": None}], None)
            if url.endswith("/api/wxsat/captures"):
                return ({"captures": []}, None)
            return (None, "n/a")
        with mock.patch.object(dashboard, "_get_json", side_effect=fake_get):
            t = dashboard.poll_meteor()
        self.assertEqual(t["state"], "ok")
        self.assertNotIn("image_url", {k: v for k, v in t.items() if v})
        self.assertEqual(dashboard._METEOR_IMG["path"], None)


if __name__ == "__main__":
    unittest.main()
