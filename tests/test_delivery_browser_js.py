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


def browser_order_script(payload):
    source = SOURCE.read_text()
    start = source.index('NSString *orderScript = [NSString stringWithFormat:@"(() => {"')
    end = source.index(', literal];', start)
    pieces = re.findall(r'@?"(?:\\.|[^"\\])*"', source[start:end])
    script = "".join(json.loads(piece.removeprefix("@")) for piece in pieces)
    return script.replace("%@", json.dumps(payload, separators=(",", ":")))


class DeliveryBrowserJavaScriptTests(unittest.TestCase):
    def run_order_fixture(self, payload, controls, page_text=None, sensitive=False):
        script = browser_order_script(payload)
        fixture = f"""
        const controls = {json.dumps(controls)}.map(value => ({{
          textContent: value.text, disabled: !!value.disabled, clicked: false,
          getBoundingClientRect() {{return {{width:80,height:30,top:value.top||200,left:20}}}},
          contains(hit) {{return hit===this}},
          click() {{this.clicked=true}}
        }}));
        globalThis.location={{href:{json.dumps(payload['url'])}}};
        globalThis.innerWidth=414;globalThis.innerHeight=896;
        globalThis.getComputedStyle=()=>({{display:'block',visibility:'visible',opacity:'1'}});
        const sensitiveInput={{getBoundingClientRect() {{return {{width:80,height:30,top:100,left:20}}}}}};
        globalThis.document={{body:{{innerText:{json.dumps(page_text if page_text is not None else payload['text'])}}},
          querySelectorAll(selector) {{return selector.includes('input[type=password]') ?
            ({json.dumps(sensitive)} ? [sensitiveInput] : []) : controls}},
          elementFromPoint(x,y) {{return controls.find(e=>{{const r=e.getBoundingClientRect();return y>=r.top&&y<r.top+r.height}})||null}}
        }};
        process.stdout.write(JSON.stringify({{result:{script},clicks:controls.filter(e=>e.clicked).length}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        return json.loads(completed.stdout)

    def test_order_click_requires_exact_checkout_and_one_visible_control(self):
        payload = {"url": "https://www.ubereats.com/checkout",
                   "text": "Subtotal $18.00 Total $26.49 Place order"}
        button = {"text": "Place order", "top": 200}
        self.assertEqual(self.run_order_fixture(payload, [button]),
                         {"result": {"ok": True}, "clicks": 1})
        for controls, page_text in [([button, button], None),
                                    ([{"text": "Place order", "disabled": True}], None),
                                    ([button], "Subtotal $18.00 Total $28.49 Place order")]:
            self.assertEqual(self.run_order_fixture(payload, controls, page_text)["clicks"], 0)
        other = dict(payload, url="https://www.ubereats.com/store/example/id")
        self.assertEqual(self.run_order_fixture(other, [button])["clicks"], 0)
        self.assertEqual(self.run_order_fixture(payload, [button], sensitive=True)["clicks"], 0)

    def run_fixture(self, payload, controls, page_text=None):
        script = browser_action_script(payload)
        fixture = f"""
        const controls = {json.dumps(controls)}.map(value => ({{
          textContent: typeof value === 'string' ? value : value.text,
          tagName: typeof value === 'string' ? 'BUTTON' : value.tagName,
          href: typeof value === 'string' ? undefined : value.href,
          testID: typeof value === 'string' ? undefined : value.testID,
          ariaLabel: typeof value === 'string' ? undefined : value.ariaLabel,
          clicked: false,
          getBoundingClientRect() {{ return {{ width: 80, height: 30, top: typeof value === 'string' ? 200 : value.top, left: 20 }}; }},
          closest() {{ return this; }},
          contains(hit) {{ return hit === this; }},
          getAttribute(name) {{ return name === 'aria-label' ? this.ariaLabel : null; }},
          click() {{ this.clicked = true; }}
        }}));
        globalThis.location = {{ href: {json.dumps(payload['url'])}, host: 'www.ubereats.com' }};
        globalThis.window = {{ innerWidth: 414, innerHeight: 896 }};
        globalThis.getComputedStyle = () => ({{ display: 'block', visibility: 'visible', opacity: '1' }});
        globalThis.document = {{
          body: {{ innerText: {json.dumps(page_text if page_text is not None else payload['text'])} }},
          elementFromPoint(x,y) {{ return controls.find(e => {{ const r=e.getBoundingClientRect(); return y >= r.top && y < r.top+r.height; }}) || null; }},
          querySelector() {{ return null; }},
          querySelectorAll(selector) {{
            if (selector === 'button[data-testid=add-to-cart-button]')
              return controls.filter(e => e.tagName === 'BUTTON' && e.testID === 'add-to-cart-button');
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
        add = {"text": "Add 1 to order • $27.99", "tagName": "BUTTON",
               "testID": "add-to-cart-button", "ariaLabel": "Add 1 to order", "top": 200}
        self.assertEqual(self.run_fixture(payload, [add, "Place order"])["clicks"], 1)
        self.assertEqual(self.run_fixture(payload, ["Place order"])["clicks"], 0)
        duplicate = dict(add, top=250)
        self.assertEqual(self.run_fixture(payload, [add, duplicate])["clicks"], 0)

    def test_open_cart_requires_the_unique_uber_eats_cart_link(self):
        payload = {"url": "https://www.ubereats.com/store/phin/id",
                   "text": "View order Phin & Bowl 1", "action": "open_cart", "target": ""}
        cart = {"text": "View order Phin & Bowl 1", "tagName": "A",
                "href": "https://www.ubereats.com/cart?diningMode=DELIVERY",
                "ariaLabel": "VIEW CART", "top": 200}
        self.assertEqual(self.run_fixture(payload, [cart])["clicks"], 1)
        self.assertEqual(self.run_fixture(payload, [cart],
                                          page_text="New promotion View order Phin & Bowl 1")["clicks"], 1)
        outside = dict(cart, href="https://example.com/cart")
        self.assertEqual(self.run_fixture(payload, [outside])["clicks"], 0)
        self.assertEqual(self.run_fixture(payload, [cart, dict(cart, top=250)])["clicks"], 0)

    def test_option_clicks_one_visible_radio_label(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Rice Noodle Add 1 to order", "selected": [],
                   "action": "choose_option", "target": "Rice Noodle"}
        script = browser_action_script(payload)
        fixture = f"""
        const radio = {{id:'option-one',type:'radio',name:'noodle',checked:false}};
        const label = {{htmlFor:'option-one',textContent:'Rice Noodle',
          getBoundingClientRect() {{return {{width:200,height:30,top:300,left:20}}}},
          contains(hit) {{return hit===this}},
          click() {{radio.checked=true}}}};
        globalThis.location = {{href:{json.dumps(payload['url'])},host:'www.ubereats.com'}};
        globalThis.window = {{innerWidth:414,innerHeight:896}};
        globalThis.getComputedStyle = () =>
          ({{display:'block',visibility:'visible',opacity:'1'}});
        globalThis.document = {{body:{{innerText:{json.dumps(payload['text'])}}},
          elementFromPoint() {{return label}},
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

    def test_uber_eats_required_option_is_scrolled_into_view_and_selected(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Chicken Pho Rice Noodle Add 1 to order • $27.99", "selected": [],
                   "action": "choose_option", "target": "Rice Noodle"}
        action = browser_action_script(payload)
        capture = browser_capture_script()
        fixture = f"""
        const cardRadio = {{id:'',type:'radio',name:'0',value:'0',checked:false}};
        const requiredRadio = {{id:'required-rice',type:'radio',name:'noodle',checked:false}};
        const richText = {{textContent:'Rice Noodle'}};
        const card = {{textContent:'#1, Ordered by 50+ others Rice Noodle',
          getBoundingClientRect() {{return {{width:324,height:92,top:441,left:16}}}},
          querySelector() {{return cardRadio}},
          querySelectorAll() {{return [{{textContent:'#1, Ordered by 50+ others'}},richText]}},
          contains(hit) {{return hit===this || hit===richText}},
          click() {{cardRadio.checked=true;requiredRadio.checked=true}}}};
        const paired = {{htmlFor:'required-rice',textContent:'Rice Noodle',
          top:633,
          getBoundingClientRect() {{return {{width:382,height:22,top:this.top,left:16}}}},
          scrollIntoView() {{this.top=300}},
          contains(hit) {{return hit===this}},
          click() {{requiredRadio.checked=true}}}};
        cardRadio.closest=()=>card;
        requiredRadio.closest=()=>null;
        globalThis.location={{href:{json.dumps(payload['url'])},host:'www.ubereats.com'}};
        globalThis.window={{innerWidth:414,innerHeight:628}};
        globalThis.getComputedStyle=()=>({{display:'block',visibility:'visible',opacity:'1'}});
        globalThis.document={{body:{{innerText:{json.dumps(payload['text'])}}},
          elementFromPoint(x,y) {{return y<350 ? paired : richText}},
          getElementById(id) {{return id==='required-rice' ? requiredRadio : null}},
          querySelectorAll(selector) {{
            if(selector==='label[for]')return [paired];
            if(selector==='li')return [card];
            if(selector==='input[type=radio]:checked,input[type=checkbox]:checked')
              return [cardRadio,requiredRadio].filter(e=>e.checked);
            return [];
          }}}};
        const result={action};
        const observed={capture};
        process.stdout.write(JSON.stringify({{result,observed,cardChecked:cardRadio.checked}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(completed.stdout),
                         {"result": {"ok": True}, "cardChecked": False,
                          "observed": {"text": payload["text"],
                                       "selected": ["Rice Noodle"],
                                       "available": ["Rice Noodle"]}})

    def test_unpaired_duplicate_label_does_not_block_required_option(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Rice Noodle Add 1 to order", "selected": [],
                   "action": "choose_option", "target": "Rice Noodle"}
        script = browser_action_script(payload)
        fixture = f"""
        const radio = {{id:'visible-option',type:'radio',name:'noodle',checked:false}};
        const visible = {{htmlFor:'visible-option',textContent:'Rice Noodle',
          getBoundingClientRect() {{return {{width:200,height:30,top:300,left:20}}}},
          contains(hit) {{return hit===this}},click() {{radio.checked=true}}}};
        const occluded = {{htmlFor:'hidden-behind-modal',textContent:'Rice Noodle',
          getBoundingClientRect() {{return {{width:200,height:30,top:400,left:20}}}},
          contains() {{return false}},click() {{throw Error('occluded label clicked')}}}};
        globalThis.location = {{href:{json.dumps(payload['url'])},host:'www.ubereats.com'}};
        globalThis.window = {{innerWidth:414,innerHeight:896}};
        globalThis.getComputedStyle = () =>
          ({{display:'block',visibility:'visible',opacity:'1'}});
        globalThis.document = {{body:{{innerText:{json.dumps(payload['text'])}}},
          elementFromPoint(x,y) {{return y<350 ? visible : null}},
          getElementById(id) {{return id==='visible-option' ? radio : null}},
          querySelectorAll(selector) {{
            if(selector==='label[for]')return [occluded,visible];
            if(selector.includes('input[type=radio]:checked'))return [];
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

    def test_two_distinct_radio_options_with_same_label_are_rejected(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Rice Noodle Add 1 to order", "selected": [],
                   "action": "choose_option", "target": "Rice Noodle"}
        script = browser_action_script(payload)
        fixture = f"""
        const inputs = [{{id:'one',type:'radio',name:'first',checked:false}},
                        {{id:'two',type:'radio',name:'second',checked:false}}];
        const labels = inputs.map((input,i)=>({{htmlFor:input.id,textContent:'Rice Noodle',
          getBoundingClientRect() {{return {{width:100,height:20,top:300+i*40,left:20}}}},
          contains() {{return false}},click() {{input.checked=true}}}}));
        globalThis.location = {{href:{json.dumps(payload['url'])},host:'www.ubereats.com'}};
        globalThis.window = {{innerWidth:414,innerHeight:896}};
        globalThis.getComputedStyle = () =>
          ({{display:'block',visibility:'visible',opacity:'1'}});
        globalThis.document = {{body:{{innerText:{json.dumps(payload['text'])}}},
          elementFromPoint(x,y) {{return y<350 ? labels[0] : labels[1]}},
          getElementById(id) {{return inputs.find(x=>x.id===id)||null}},
          querySelectorAll(selector) {{
            if(selector==='label[for]')return labels;
            if(selector.includes('input[type=radio]:checked'))return [];
            if(selector.includes('input[type=password]'))return [];
            return [];
          }}
        }};
        process.stdout.write(JSON.stringify({{result:{script},checked:inputs.map(x=>x.checked)}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(completed.stdout),
                         {"result": {"ok": False, "error": "Option target not unique"},
                          "checked": [False, False]})

    def test_covered_radio_is_not_chosen(self):
        payload = {"url": "https://www.ubereats.com/store/example/id?mod=quickView",
                   "text": "Rice Noodle Add 1 to order", "selected": [],
                   "action": "choose_option", "target": "Rice Noodle"}
        script = browser_action_script(payload)
        fixture = f"""
        const radio = {{id:'option-one',type:'radio',name:'noodle',checked:false}};
        const label = {{htmlFor:'option-one',textContent:'Rice Noodle',
          getBoundingClientRect() {{return {{width:200,height:30,top:300,left:20}}}},
          scrollIntoView() {{}},
          contains() {{return false}},click() {{radio.checked=true}}}};
        globalThis.location = {{href:{json.dumps(payload['url'])},host:'www.ubereats.com'}};
        globalThis.window = {{innerWidth:414,innerHeight:896}};
        globalThis.getComputedStyle = () =>
          ({{display:'block',visibility:'visible',opacity:'1'}});
        globalThis.document = {{body:{{innerText:{json.dumps(payload['text'])}}},
          elementFromPoint() {{return {{}}}},
          getElementById(id) {{return id==='option-one' ? radio : null}},
          querySelectorAll(selector) {{
            if(selector==='label[for]')return [label];
            if(selector.includes('input[type=radio]:checked'))return [];
            if(selector.includes('input[type=password]'))return [];
            return [];
          }}
        }};
        process.stdout.write(JSON.stringify({{result:{script},checked:radio.checked}}));
        """
        completed = subprocess.run([shutil.which("node"), "-e", fixture],
                                   check=True, capture_output=True, text=True)
        self.assertEqual(json.loads(completed.stdout),
                         {"result": {"ok": False, "error": "Option changed"}, "checked": False})

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
        for credential_size, expected in [(0, {"text": "Featured items", "selected": [], "available": []}),
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
