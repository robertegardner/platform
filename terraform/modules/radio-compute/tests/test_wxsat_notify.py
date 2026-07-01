import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import wxsat_notify  # noqa: E402


class NotifyTest(unittest.TestCase):
    def test_unconfigured_returns_false_no_raise(self):
        with mock.patch.dict(os.environ, {"NTFY_URL": "", "NTFY_TOPIC": ""}, clear=False):
            self.assertFalse(wxsat_notify.notify("pass", "t", "m"))

    def test_posts_to_topic_url(self):
        env = {"NTFY_URL": "https://ntfy.sh", "NTFY_TOPIC": "meteor-cape"}
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch("wxsat_notify.urllib.request.urlopen") as uo:
            uo.return_value.__enter__ = lambda s: s
            uo.return_value.__exit__ = lambda *a: False
            ok = wxsat_notify.notify("decode", "Meteor decode", "M2-4 45deg", tags="satellite")
        self.assertTrue(ok)
        req = uo.call_args[0][0]
        self.assertEqual(req.full_url, "https://ntfy.sh/meteor-cape")
        self.assertEqual(req.data, b"M2-4 45deg")
        self.assertEqual(req.headers.get("Title"), "Meteor decode")
        self.assertEqual(req.headers.get("Tags"), "satellite")

    def test_trailing_slash_in_url_is_normalized(self):
        env = {"NTFY_URL": "https://ntfy.sh/", "NTFY_TOPIC": "x"}
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch("wxsat_notify.urllib.request.urlopen") as uo:
            uo.return_value.__enter__ = lambda s: s
            uo.return_value.__exit__ = lambda *a: False
            wxsat_notify.notify("pass", "t", "m")
        self.assertEqual(uo.call_args[0][0].full_url, "https://ntfy.sh/x")

    def test_never_raises_on_network_error(self):
        env = {"NTFY_URL": "https://ntfy.sh", "NTFY_TOPIC": "x"}
        with mock.patch.dict(os.environ, env, clear=False), \
             mock.patch("wxsat_notify.urllib.request.urlopen", side_effect=OSError("boom")):
            self.assertFalse(wxsat_notify.notify("pass", "t", "m"))


if __name__ == "__main__":
    unittest.main()
