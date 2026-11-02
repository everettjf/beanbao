"""Exercise the JavaScript shipped in the delivery browser against a tiny DOM fixture."""

import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parent.parent / "app" / "DeliveryBrowserViewController.m"


def browser_action_script(payload):
    payload = {"selected": [], **payload}
    source = SOURCE.read_text()
    start = source.index('NSString *script = [NSString stringWithFormat:@"(() => {"')
    end = source.index(', literal];', start)
    pieces = re.findall(r'@?"(?:\\.|[^"\\])*"', source[start:end])
    script = "".join(json.loads(piece.removeprefix("@")) for piece in pieces)
    return script.replace("%@", json.dumps(payload, separators=(",", ":")))


def browser_capture_script():
    source = SOURCE.read_text()
    start = source.index('NSString *script = @"(() => {"',
                         source.index('- (void)captureCurrentPageWithCompletion:'))
    end = source.index(';\n    [self.webView evaluateJavaScript:', start)
    pieces = re.findall(r'@?"(?:\\.|[^"\\])*"', source[start:end])
    return "".join(json.loads(piece.removeprefix("@")) for piece in pieces)


class DeliveryBrowserJavaScriptTests(unittest.TestCase):
    def run_fixture(self, payload, controls, page_text=None):
        script = browser_action_script(payload)
        fixture = f"""
        const controls = {json.dumps(controls)}.map(value => ({{
          textContent: typeof value === 'string' ? value : value.text,
          tagName: typeof value === 'string' ? 'BUTTON' : value.tagName,
          href: typeof value === 'string' ? undefined : value.href,
          clicked: false,
          getBoundingClientRect() {{ return {{ width: 80, height: 30, top: typeof value === 'string' ? 200 : value.top, left: 20 }}; }},
          closest() {{ return this; }},
          click() {{ this.clicked = true; }}
        }}));
        globalThis.location = {{ href: {json.dumps(payload['url'])}, host: 'www.ubereats.com' }};
        globalThis.window = {{ innerWidth: 414, innerHeight: 896 }};
        globalThis.getComputedStyle = () => ({{ display: 'block', visibility: 'visible', opacity: '1' }});
        globalThis.document = {{
          body: {{ innerText: {json.dumps(page_text if page_text is not None else payload['text'])} }},
          querySelector() {{ return null; }},
          querySelectorAll(selector) {{
            return selector.includes('input[type=password]') ||
                   selector.includes('label[for]') || selector.includes('input[type=radio]') ||
                   selector.includes('input[type=checkbox]') ? [] : controls;
          }}
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

    def test_option_clicks_one_visible_radio_label(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Rice Noodle Add 1 to order", "selected": [],
                   "action": "choose_option", "target": "Rice Noodle"}
        script = browser_action_script(payload)
        fixture = f"""
        const radio = {{id:'option-one',type:'radio',name:'noodle',checked:false}};
        const label = {{htmlFor:'option-one',textContent:'Rice Noodle',
          getBoundingClientRect() {{return {{width:200,height:30,top:300,left:20}}}},
          click() {{radio.checked=true}}}};
        globalThis.location = {{href:{json.dumps(payload['url'])},host:'www.ubereats.com'}};
        globalThis.window = {{innerWidth:414,innerHeight:896}};
        globalThis.getComputedStyle = () =>
          ({{display:'block',visibility:'visible',opacity:'1'}});
        globalThis.document = {{body:{{innerText:{json.dumps(payload['text'])}}},
          getElementById(id) {{return id==='option-one' ? radio : null}},
          querySelectorAll(selector) {{
            if(selector==='label[for]')return [label];
            if(selector.includes('input[type=radio]:checked'))return radio.checked ? [radio] : [];
            if(selector.includes('input[type=password]'))return [];
            return [];
          }}
        }};
        process.stdout.write(JSON.stringify({{result:{script},checked:radio.checked}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(completed.stdout),
                         {"result": {"ok": True}, "checked": True})

    def test_open_search_clicks_one_visible_control(self):
        payload = {"url": "https://www.ubereats.com/feed",
                   "text": "Search Uber Eats", "action": "open_search", "target": ""}
        self.assertEqual(self.run_fixture(payload, ["Search Uber Eats"]),
                         {"result": {"ok": True}, "clicks": 1})
        self.assertEqual(self.run_fixture(payload, ["Search Uber Eats", "Search Uber Eats"]),
                         {"result": {"ok": False, "error": "Search control not unique"},
                          "clicks": 0})

    def test_merchant_link_dedupes_visible_destination_and_rejects_offscreen(self):
        payload = {"url": "https://www.ubereats.com/search?q=rice",
                   "text": "Yoshinoya", "action": "open_merchant", "target": "Yoshinoya"}
        link = {"text": "Yoshinoya", "tagName": "A",
                "href": "https://www.ubereats.com/store/yoshinoya/id", "top": 400}
        result = self.run_fixture(payload, [link, link])
        self.assertEqual(result["result"], {"ok": True})
        self.assertEqual(result["clicks"], 1)
        search_button = {"text": "Yoshinoya", "tagName": "BUTTON", "top": 120}
        self.assertEqual(self.run_fixture(payload, [search_button, link]),
                         {"result": {"ok": True}, "clicks": 1})
        tracked = dict(link, href="https://www.ubereats.com/store/yoshinoya/id?tracking=second")
        self.assertEqual(self.run_fixture(payload, [link, tracked])["result"],
                         {"ok": True})
        hidden = dict(link, top=1200)
        self.assertEqual(self.run_fixture(payload, [hidden, hidden]),
                         {"result": {"ok": False, "error": "Action target not unique"},
                          "clicks": 0})

    def test_item_link_dedupes_same_destination_but_not_distinct_items(self):
        payload = {"url": "https://www.ubereats.com/store/example/id",
                   "text": "Chicken Pho", "action": "open_item", "target": "Chicken Pho"}
        item = {"text": "Chicken Pho", "tagName": "A",
                "href": "https://www.ubereats.com/store/example/id?mod=quickView&item=one",
                "top": 400}
        self.assertEqual(self.run_fixture(payload, [item, item]),
                         {"result": {"ok": True}, "clicks": 1})
        other = dict(item, href="https://www.ubereats.com/store/example/id?mod=quickView&item=two")
        self.assertEqual(self.run_fixture(payload, [item, other]),
                         {"result": {"ok": False, "error": "Action target not unique"},
                          "clicks": 0})
        offscreen = dict(other, top=1200)
        self.assertEqual(self.run_fixture(payload, [item, offscreen]),
                         {"result": {"ok": True}, "clicks": 1})

    def test_search_only_submits_the_visible_search_form(self):
        payload = {"url": "https://www.ubereats.com/search-suggestions",
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
        input.contains = value => value === input;
        input.getBoundingClientRect = () => ({{width: 120, height: 35, top: 250, left: 20}});
        input.dispatchEvent = () => true;
        input.form = {{ action: 'https://www.ubereats.com/search',
                        requestSubmit() {{ this.submissions = (this.submissions || 0) + 1; }} }};
        const offscreen = new HTMLInputElement();
        offscreen.type = 'search'; offscreen.placeholder = 'Search Uber Eats';
        offscreen.getAttribute = () => '';
        offscreen.getBoundingClientRect = () => ({{width: 120, height: 35, top: 1200, left: 20}});
        const covered = new HTMLInputElement();
        covered.type = 'search'; covered.placeholder = 'Search Uber Eats';
        covered.getAttribute = () => '';
        covered.getBoundingClientRect = () => ({{width: 120, height: 35, top: 300, left: 20}});
        covered.contains = () => false;
        globalThis.Event = class {{ constructor() {{}} }};
        globalThis.KeyboardEvent = class {{ constructor() {{}} }};
        globalThis.window = {{ innerWidth: 414, innerHeight: 896 }};
        globalThis.getComputedStyle = () => ({{ display: 'block', visibility: 'visible', opacity: '1' }});
        globalThis.document = {{
          body: {{innerText: 'Search Uber Eats'}},
          elementFromPoint() {{return input;}},
          querySelector() {{return null;}},
          querySelectorAll(selector) {{
            return selector.includes('input[type=password]') ||
                   selector.includes('label[for]') || selector.includes('input[type=radio]') ||
                   selector.includes('input[type=checkbox]') ? [] : [input, offscreen, covered];
          }}
        }};
        const result = {script};
        process.stdout.write(JSON.stringify({{result, entered: input.entered,
                                             submissions: input.form.submissions}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(completed.stdout),
                         {"result": {"ok": True}, "entered": "rice bowl", "submissions": 1})

    def test_capture_ignores_hidden_credentials_but_stops_on_visible_ones(self):
        script = browser_capture_script()
        for credential_size, expected in [(0, {"text": "Featured items", "selected": []}),
                                          (40, {"reason": "credentials"})]:
            fixture = f"""
            const credential = {{
              getBoundingClientRect() {{return {{width:{credential_size},height:{credential_size}}}}}
            }};
            globalThis.document = {{
              body: {{innerText:'Featured items'}},
              querySelectorAll(selector) {{return selector.includes('input[type=password]') ?
                [credential] : []}}
            }};
            globalThis.getComputedStyle = () =>
              ({{display:'block',visibility:'visible',opacity:'1'}});
            process.stdout.write(JSON.stringify({script}));
            """
            completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                       check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(completed.stdout), expected)


if __name__ == "__main__":
    unittest.main()
