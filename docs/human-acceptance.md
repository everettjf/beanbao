# Device acceptance checklist

Updated November 2, 2026. The tested phone is an iPhone 11 with iOS 26.0.1, Relaxin 0.5.5, and RootHide. The owner has authorized device operation. Keep the phone unlocked and screen on during UI tests. Do not record API keys, private keys, contacts, or personal note contents.

## Verify the installed build

Run `scripts/verify_device.py --expect-bundle` with the paired SSH host, port, identity, and known-hosts options described in [installation](install-and-configure.md). Confirm Bridge, Agent, and App versions, the running Agent service, and Bridge observation. The phone's Auto-Lock setting should remain at the owner's preferred value; this checklist does not change it.

## English text requests

1. Enter **Open Settings** and tap **Start**. Require a completed status and an independently observed foreground bundle ID of `com.apple.Preferences`.
2. Repeat with **Open Contacts**, **Open Notes**, and **Open Maps**. Require matching foreground bundle IDs and no contact data access.
3. Enter **Create note: BeanBao test <unique marker>**. Require completion and the full new title in the Notes list. Use a new marker for each run.
4. With a configured Claude, OpenAI, or compatible model key, enter **Search Maps for Golden Gate Bridge**. Require both the matching marker and place card, without starting navigation. Test each model service separately; a service without a key is not a passed live model test.
5. Enter **Open Maps and send a message**. Require a clear rejection, no device action, and no message sent. The Agent may create an incomplete task record before rejecting it; the service must stay the same and the App must remain in the foreground.

The current test scripts are `scripts/accept_text_device.py`, `scripts/accept_app_text_device.py`, and `scripts/accept_saved_workflow_device.py`. Check the app status, Agent task and service IDs, and actual UI together. A package audit or simulated Bridge test does not replace device acceptance.

## Multi-step research, PDF, email, and app

The current installed build completed one text request through six Palmino tools and left a two-page sourced PDF, an addressed email draft, and the exact Apple Mail listing in one saved session. The PDF was rendered and inspected; the email remained unsent. Exact bundle verification cleared only the app review. The owner chose to skip Mail acceptance for this run, so Mail account setup and native composer verification are deferred. A later separately approved send can test Mail's queued callback; it cannot prove delivery to the recipient.

On the current installed App 0.3.71, **Review email draft** still reports that an Apple Mail account must be set up. Switching Sessions now clears that task-specific prompt. The system composer has not opened, so attachment and callback checks remain unverified and are outside this run's acceptance scope.

Agent 0.3.115 also passed a research interruption test: one completed search receipt survived an Agent-only restart, the same workflow ID resumed, and a three-page PDF with 17 source links was produced. The owner deferred Apple Mail acceptance; physical USB-disconnect and reboot recovery are recorded below.

## Food delivery cart review

1. Open **Browse food delivery** and set a non-personal test address on Uber Eats. Confirm **Check** identifies a supported page.
2. Enter a request naming one merchant, item, and available required option, ending with “add it to the cart for review; do not check out.” Tap **Run**. Verify the visible merchant and option before any add action. If the site changes or asks for sign-in, stop and record the state.
3. Require a cart with exactly the named item and option. BeanBao should report **Cart is ready for review. No checkout or order was started.** Match the Agent's completed `delivery_review_cart` receipt to the visible cart. Do not tap **Go to checkout** as part of this acceptance.

The connected phone passed two earlier uninterrupted runs from an empty cart, including one with the final merchant, item, and option check. On the current installed build, **Check** identified the visible Uber Eats home feed after wireless data permission was allowed, and a fresh uninterrupted text run reached the same read-only cart review with one Chicken Pho and Rice Noodle. No checkout or order was started. Other sites, accounts, and devices still require separate acceptance.

An additional current-build interruption test stopped the Agent after it durably claimed **Add item to cart** and before it saved the result. The website cart contained exactly one Chicken Pho with Rice Noodle; BeanBao restored the session as **Needs review** and blocked another delivery task even after switching sessions. The test item was removed in Uber Eats, the empty cart was observed, and the uncertain test session was discarded. A fresh read-only task then reached **Item options ready for review** without adding an item. This covers the real interrupted-add and recovery path on the connected phone, not signed-in checkout or ordering.

## Food delivery checkout and order

The connected browser still reaches Uber Eats sign-in before checkout. After signing in on the phone, run a checkout-only request and verify that **Review** displays the exact merchant, items, options, address, every charge, and total. Change the address or price before confirming; the order must not be clicked. A live final order test needs the owner's separate approval of a specific real cart and amount. After an approved tap, check the Uber Eats confirmation and order history. If the result is ambiguous, require **Needs review** and no automatic retry. This acceptance has not passed on a real checkout.

## Voice and independent operation

1. Tap **Voice input**, say **Open Maps**, and tap **Stop recording**. Review the editable transcript before tapping **Start**. Require the correct foreground app and completed Agent task. On-device English language assets may need a first-use download.
2. Enable **Quick launch**, switch to Settings, and press Volume Down once to confirm normal volume behavior. Then quickly triple press Volume Down. Require one **Ask BeanBao** panel near the bottom of the screen, a brief **Starting microphone…** state, and then **Listening… Speak now.** without tapping a microphone button. Confirm its controls respond to touch, and additional rapid Volume Down presses do not open another panel. Say **Open Contacts**, tap **Stop recording**, review the transcript, and tap **Run**. Require Contacts to be foreground and the task to complete. If the overlay times out before listening, record the displayed state and the voice-session markers.
3. Unplug USB physically and run **Open Settings** in BeanBao. Reconnect, then check that the task ID advanced, the audit contains start and completion, and Settings is in the foreground. On November 3, the owner reported that Settings opened during this test on the current build. After reconnection, the task ID had advanced to `823313A8-E787-4D08-855C-715C45478397`, the audit recorded `start` and `done` for Settings, Agent status was `done`, and Bridge independently observed `com.apple.Preferences` in the foreground. This passes the current-build phone-only text task check.
4. Reboot, re-enable Relaxin as needed, confirm Agent starts automatically, and run **Open Notes** and a limited Maps search. On November 3, the owner rebooted and re-enabled Relaxin. All four installed package versions remained present, Agent 0.3.117 responded under new service ID `D12C23D5-DAB2-447F-A230-C02B1B2FB46E` without a manual service start, and Bridge observed an unlocked Home screen. **Open Notes** completed as task `43BCB8E1-EE6E-408F-A367-ECA8AEC7FC05` with Notes independently foreground. The app-level **Search Maps for Golden Gate Bridge** completed as task `C0422F28-4976-4B32-A708-B2672897A702`; the device test confirmed both the map marker and place card. No package reinstall or extra reboot was needed.

After that reboot, the saved six-step research session `297C6C2D-FAA2-4A38-AD37-5BE858F7F5CE` still had six completed step receipts and remained `waitingForUser`. Its 24,399-byte PDF and 638-byte draft file were present. Selecting it in **Sessions** showed **Ready for review**; **View PDF report** opened the document in BeanBao's viewer, and returning preserved the review state. This verifies artifact and session persistence through the reboot. The Mail composer remains outside this run's scope.

The tested iOS 26 Sessions table reported accessibility tap points roughly 100 screen points above its rendered rows. The saved-workflow acceptance script selects the exact workflow ID through the Agent and then checks the visible app review controls and PDF viewer; it does not rely on those row coordinates. This is a test automation limitation, not a failure of finger taps in the app.

The physical-button recording and voice-to-task flow passed over an app and from the unlocked Home screen on the tested phone. The current build completed **Open Settings** after its initiating SSH session ended, with the same task ID and verified foreground bundle. The current-build physical USB-disconnect text task and reboot recovery checks have also passed as recorded above. Other devices require separate validation.

After the November 3 reboot, an authenticated `show_voice` request displayed one bottom **Ask BeanBao** panel over Settings with **Listening… Speak now.** and **Stop recording** visible. A second `show_voice` request while the panel was open was rejected. Hiding it removed the panel and left Settings in the foreground. This verifies the overlay session path and duplicate guard after re-jailbreaking; the physical Volume Down trigger was not repeated in this post-reboot check.
