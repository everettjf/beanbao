import time
import unittest

from beanbao import MockModel, Policy, contains_visible_secret, run


def observation(app="com.apple.springboard"):
    return {"ok": True, "observation_id": "fresh", "timestamp": time.time(),
            "device_state": {"locked_known": True, "locked": False, "screen_on_known": True, "screen_on": True},
            "frontmost_app": {"bundleId": app}, "screen": {"width": 390, "height": 844}}


class FakeBridge:
    def __init__(self):
        self.app = "com.apple.springboard"
        self.actions = []

    def observe(self, **_):
        return observation(self.app)

    def act(self, _, action):
        self.actions.append(action)
        self.app = action["bundle_id"]
        return {"ok": True}


class PolicyTests(unittest.TestCase):
    def test_mock_loop_launches_only_requested_app(self):
        bridge = FakeBridge()
        self.assertIn("目标 App", run("打开地图", bridge, MockModel()))
        self.assertEqual(bridge.actions, [{"action": "launch_app", "bundle_id": "com.apple.Maps"}])

    def test_install_shell_and_unapproved_app_are_rejected(self):
        policy = Policy("打开设置")
        for action in ({"action": "install_app", "path": "/tmp/a.deb"},
                       {"action": "run_command", "command": "true"},
                       {"action": "launch_app", "bundle_id": "com.apple.MobileStore"},
                       {"action": "launch_app", "bundle_id": "com.apple.Maps"}):
            with self.subTest(action=action), self.assertRaises(ValueError):
                policy.check(action, observation())

    def test_locked_and_stale_observation_rejected(self):
        policy = Policy("打开设置")
        action = {"action": "launch_app", "bundle_id": "com.apple.Preferences"}
        locked = observation()
        locked["device_state"]["locked"] = True
        with self.assertRaises(ValueError):
            policy.check(action, locked)
        stale = observation()
        stale["timestamp"] -= 30
        with self.assertRaises(ValueError):
            policy.check(action, stale)

    def test_ui_actions_need_supervised_mode(self):
        allowed = observation("com.apple.Preferences")
        with self.assertRaises(ValueError):
            Policy("测试").check({"action": "tap", "x": 20, "y": 50}, allowed)
        Policy("测试", allow_ui_actions=True).check({"action": "tap", "x": 20, "y": 50}, allowed)

    def test_supervised_mode_still_requires_step_approval(self):
        class TapModel:
            needs_image = False

            def next_action(self, *_):
                return {"action": "tap", "x": 20, "y": 50}

        bridge = FakeBridge()
        bridge.app = "com.apple.Preferences"
        with self.assertRaises(ValueError):
            run("测试", bridge, TapModel(), allow_ui_actions=True, approve=lambda _: False)
        self.assertEqual(bridge.actions, [])

    def test_visible_secret_stops_external_model_before_request(self):
        class Model:
            needs_image = True

            def next_action(self, *_):
                raise AssertionError("model must not receive visible secret")

        class SecretBridge(FakeBridge):
            def observe(self, **_):
                return {**observation(), "ocr": {"texts": [{"text": "sk-" + "a" * 32}]}}

        self.assertTrue(contains_visible_secret({"text": "sk-" + "a" * 32}))
        with self.assertRaisesRegex(ValueError, "疑似密钥"):
            run("打开设置", SecretBridge(), Model())


if __name__ == "__main__":
    unittest.main()
