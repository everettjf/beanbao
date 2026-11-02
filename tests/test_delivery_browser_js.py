"""Exercise the JavaScript shipped in the delivery browser against a tiny DOM fixture."""

import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parent.parent / "app" / "DeliveryBrowserViewController.m"


def browser_action_script(payload):
    source = SOURCE.read_text()
    start = source.index('NSString *script = [NSString stringWithFormat:@"(() => {"')
    end = source.index(', literal];', start)
    pieces = re.findall(r'@?"(?:\\.|[^"\\])*"', source[start:end])
    script = "".join(json.loads(piece.removeprefix("@")) for piece in pieces)
    return script.replace("%@", json.dumps(payload, separators=(",", ":")))


class DeliveryBrowserJavaScriptTests(unittest.TestCase):
    def run_fixture(self, payload, controls, page_text=None):
        script = browser_action_script(payload)
        fixture = f"""
        const controls = {json.dumps(controls)}.map(value => ({{
          textContent: value, tagName: 'BUTTON', clicked: false,
          getBoundingClientRect() {{ return {{ width: 80, height: 30 }}; }},
          closest() {{ return this; }},
          click() {{ this.clicked = true; }}
        }}));
        globalThis.location = {{ href: {json.dumps(payload['url'])}, host: 'www.ubereats.com' }};
        globalThis.document = {{
          body: {{ innerText: {json.dumps(page_text if page_text is not None else payload['text'])} }},
          querySelector() {{ return null; }},
          querySelectorAll() {{ return controls; }}
        }};
        const result = {script};
        process.stdout.write(JSON.stringify({{ result, clicks: controls.filter(e => e.clicked).length }}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        return json.loads(completed.stdout)

    def test_checkout_link_clicks_once_only_for_same_page(self):
        payload = {"url": "https://www.ubereats.com/store/example/id",
                   "text": "Go to checkout", "action": "open_checkout", "target": ""}
        self.assertEqual(self.run_fixture(payload, ["Go to checkout"]),
                         {"result": {"ok": True}, "clicks": 1})
        self.assertEqual(self.run_fixture(payload, ["Go to checkout"],
                                          page_text="Go to checkout Total $99"),
                         {"result": {"ok": False, "error": "Page changed"}, "clicks": 0})
        self.assertEqual(self.run_fixture(payload, ["Go to checkout", "Go to checkout"]),
                         {"result": {"ok": False, "error": "Action target not unique"},
                          "clicks": 0})
        purchase = dict(payload, action="place_order", target="Go to checkout")
        self.assertEqual(self.run_fixture(purchase, ["Go to checkout"]),
                         {"result": {"ok": False, "error": "Unsupported action"},
                          "clicks": 0})

    def test_add_to_cart_only_matches_quantity_button(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Rice bowl Add 1 to order", "action": "add_to_cart", "target": ""}
        self.assertEqual(self.run_fixture(payload, ["Add 1 to order", "Place order"])["clicks"], 1)
        self.assertEqual(self.run_fixture(payload, ["Place order"])["clicks"], 0)

    def test_search_only_submits_the_visible_search_form(self):
        payload = {"url": "https://www.ubereats.com/feed",
                   "text": "Search Uber Eats", "action": "search", "target": "rice bowl"}
        script = browser_action_script(payload)
        fixture = f"""
        globalThis.location = {{ href: {json.dumps(payload['url'])}, host: 'www.ubereats.com' }};
        globalThis.HTMLInputElement = class {{
          set value(value) {{ this.entered = value; }}
        }};
        const input = new HTMLInputElement();
        input.type = 'search'; input.placeholder = 'Search Uber Eats';
        input.getAttribute = () => '';
        input.getBoundingClientRect = () => ({{width: 120, height: 35}});
        input.dispatchEvent = () => true;
        input.form = {{ action: 'https://www.ubereats.com/search',
                        requestSubmit() {{ this.submissions = (this.submissions || 0) + 1; }} }};
        globalThis.Event = class {{ constructor() {{}} }};
        globalThis.KeyboardEvent = class {{ constructor() {{}} }};
        globalThis.document = {{
          body: {{innerText: 'Search Uber Eats'}},
          querySelector() {{return null;}},
          querySelectorAll() {{return [input];}}
        }};
        const result = {script};
        process.stdout.write(JSON.stringify({{result, entered: input.entered,
                                             submissions: input.form.submissions}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(completed.stdout),
                         {"result": {"ok": True}, "entered": "rice bowl", "submissions": 1})


if __name__ == "__main__":
    unittest.main()
