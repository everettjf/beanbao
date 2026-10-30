import io
import json
import time
import unittest
from unittest.mock import patch

from beanbao import AnthropicModel, MockModel, Policy, contains_visible_secret, run


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

    def test_supervised_action_uses_fresh_observation_after_approval(self):
        class SlowBridge:
            reads = 0
            acted_with = None

            def observe(self, **_):
                self.reads += 1
                return {**observation("com.apple.Maps"), "observation_id": str(self.reads),
                        "timestamp": time.time() - 20 if self.reads == 1 else time.time(),
                        "ui": {"search_field": "Search for a place or address"},
                        "ocr": {"texts": [{"text": "dynamic map label " + str(self.reads)}]},
                        "screenshot": {"data": "first-frame" if self.reads == 1 else "changed-map-animation"}}

            def act(self, observation_id, _):
                self.acted_with = observation_id

        class TapThenDone:
            needs_image = True

            def next_action(self, _task, _observation, history):
                return {"action": "done"} if history else {"action": "tap", "x": 20, "y": 50}

        bridge = SlowBridge()
        run("打开地图", bridge, TapThenDone(), allow_ui_actions=True, approve=lambda _: True)
        self.assertEqual(bridge.acted_with, "2")


class AnthropicModelTests(unittest.TestCase):
    def test_native_messages_payload_and_single_json_action(self):
        observation_data = {**observation("com.apple.Maps"),
                            "screenshot": {"data": "ZmFrZQ==", "mimeType": "image/jpeg"}}
        reply = {"content": [{"type": "text", "text": '{"action":"tap","x":170,"y":535}'}]}
        with patch("beanbao.urllib.request.urlopen", return_value=io.BytesIO(json.dumps(reply).encode())) as send:
            action = AnthropicModel("claude-sonnet-5-5", "test-key").next_action(
                "在地图搜索地点", observation_data, [])
        self.assertEqual(action, {"action": "tap", "x": 170, "y": 535})
        request = send.call_args.args[0]
        self.assertEqual(request.full_url, "https://api.anthropic.com/v1/messages")
        body = json.loads(request.data)
        self.assertEqual(body["model"], "claude-sonnet-5-5")
        self.assertEqual(body["messages"][0]["content"][1]["source"]["data"], "ZmFrZQ==")
        self.assertEqual(body["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(body["output_config"]["effort"], "low")
        self.assertNotIn("temperature", body)


if __name__ == "__main__":
    unittest.main()
