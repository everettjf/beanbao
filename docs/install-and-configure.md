# Install and configure BeanBao

Updated November 2, 2026. This is a developer installation procedure for a compatible Relaxin / RootHide jailbreak. The tested device is an iPhone 11 running iOS 26.0.1 and Relaxin 0.5.5. Other devices require their own validation.

## Packages

Install these RootHide `iphoneos-arm64e` packages in order:

1. `dev.beanbao.bridge` 0.2.13: restricted SpringBoard observation, UI actions, and quick voice overlay.
2. `dev.beanbao.agent` 0.3.110: on-device task service, model interpretation, resumable workflows, and a restricted delivery-browser channel.
3. `dev.beanbao.deliverybrowser` 0.1.18: sandboxed Uber Eats browser with visible page checks, bounded Palmino-driven Run control, and explicit checkout review.
4. `dev.beanbao.app` 0.3.68: native text, Apple voice transcription, Sessions with step history and order-history review, App Store review, Activity, shortcut, and model settings UI.

The packages are under `bridge/packages/`, `agent-native/packages/`, `delivery-browser/packages/`, and `app/packages/`. Build from source on a Mac with the RootHide Theos toolchain:

```sh
THEOS=/absolute/path/to/roothide-theos ./scripts/build_packages.sh
python3 scripts/prepare_release_bundle.py
```

The build script runs native policy, Python, and Swift Harness tests and audits package contents, dependencies, architectures, signatures, and launch identity. The bundle script creates a portable archive with the four `.deb` files, `SHA256SUMS`, and an English `INSTALL.md`. It contains no model keys, SSH credentials, or device data.

With a root shell on the jailbroken phone, copy over the packages and install them in this order:

```sh
dpkg -i dev.beanbao.bridge_0.2.13_iphoneos-arm64e.deb
dpkg -i dev.beanbao.agent_0.3.110_iphoneos-arm64e.deb
dpkg -i dev.beanbao.deliverybrowser_0.1.18_iphoneos-arm64e.deb
dpkg -i dev.beanbao.app_0.3.68_iphoneos-arm64e.deb
dpkg-query -W dev.beanbao.bridge dev.beanbao.agent dev.beanbao.deliverybrowser dev.beanbao.app
```

After installing or updating Bridge, reload SpringBoard to enable its injection, then unlock the phone. Updating only Agent or App does not require a SpringBoard reload. BeanBao does not provide an installer for other apps. A public software source and one-tap installer are not available yet.

To check the connected development device, run `python3 scripts/verify_device.py --host 127.0.0.1 --port <forwarded-port> --identity <private-key-path> --known-hosts <known-hosts-path> --expect-bundle`. This checks versions, the Agent service, and Bridge observation; it does not replace a real task test.

## First use

1. Unlock the phone and open BeanBao. Tap **Change** on the **Model service** card. Choose **Claude** for research and App Store workflows, and enter your own key and model name. The older bounded UI tasks can also use OpenAI or a Compatible API. For a compatible service, enter its HTTPS base URL, such as `https://example.com/v1`, and choose a model that accepts images. Each service has a separate key file owned by the mobile user with mode `0600`. A key is needed for model-assisted Maps search, while opening apps and creating notes work locally.
2. Tap a quick action or enter **Open Maps**, **Open Settings**, **Open Contacts**, or **Open Notes**, then tap **Start**. The app reports completion only after checking the actual foreground app. Chinese commands from earlier versions remain accepted.
3. Try **Create note: BeanBao test note**. BeanBao creates a new note, returns to the list, and checks for its complete title. It will not edit an existing note. Avoid reusing the same test title.
4. Try **Search Maps for Golden Gate Bridge**. BeanBao may send a Maps screenshot to the selected model when local actions are insufficient. It searches and checks the place marker and card; it does not start navigation. It stops if the phone locks, the UI changes unexpectedly, or possible credentials appear on screen.
5. Tap **Voice input**, speak an English request, then tap **Stop recording**. Check or edit the transcript before tapping **Start**. iOS 26 uses on-device English dictation where available and may download a language asset on first use. Audio is removed after transcription. Recording stops automatically after 30 seconds.
6. For a multi-step research test, enter **Research on-device speech recognition on iOS, create a PDF with sources**. Open **Sessions** to revisit the result and **View PDF report** to inspect it. The current Claude workflow can also prepare an email draft addressed to an explicit recipient. Apple Mail must have an account configured before **Review email draft** can open its native composer; review the recipient and attachment there before sending.
7. For an App Store handoff, enter **Find app Apple Pages** or a natural request such as **Find the Apple Mail app by Apple**. Review the exact name, developer, product ID, bundle ID, and price before opening the official listing. Installing is a separate user action in the App Store. After that, **Check installation** verifies the matching bundle; simply closing the listing leaves the workflow pending. On the tested phone, the natural Apple Mail request completed after verifying its already installed bundle. The Pages listing's **Get** button required Apple ID sign-in; cancelling left the workflow pending and did not install the app.
8. Tap **Browse food delivery** to open the separate delivery browser. It keeps its own website session and pairs with the Agent for this launch. Tap **Check** to classify the visible page. Set a delivery address on Uber Eats before tapping **Run**. On the connected phone, one uninterrupted text task found Phin & Bowl's Chicken Pho, selected the required Rice Noodle option, added exactly one item, opened the cart, and completed a read-only review. The visible cart showed Chicken Pho, Rice Noodle, and a $27.99 subtotal at the public San Jose City Hall test address. A second full run passed after the Agent gained a final check that the previously executed merchant, item, and option still appear on the cart page. A checkout request requires a complete model-extracted merchant, item, option, address, fee, tax, tip, and total breakdown, checked against the same fresh screen. After a verified review, **Review** displays the whole order in a scrollable screen and offers one explicit **Place order** button. The Agent rechecks the current checkout and records a one-time external attempt before the browser click. If the result is unclear, check Uber Eats order history; BeanBao does not retry. An unresolved order attempt blocks every delivery session, including after switching sessions or restarting the Agent. Its saved evidence cannot be deleted through Sessions. If you find the exact order in Uber Eats history, open its Sessions details and tap **Resolve** to record your report and release the block. If the history is missing or ambiguous, leave it blocked. BeanBao does not claim to verify Uber Eats' server response. Checkout and final click have passed synthetic page tests only. The connected phone still stops at Uber Eats sign-in before a real checkout can be reviewed, and no real order has been placed.
9. Open **Sessions** and tap the information button beside a saved workflow to inspect its read-only step history. Tapping the session row itself still opens or resumes that workflow. The history shows step names, states, and times; it does not display website text or model tool results.

For development over the paired SSH connection, `beanbaoagentctl workflow-details ID` displays the same bounded step history and `beanbaoagentctl resume-workflow ID` resumes an interrupted research session by its saved ID. A mutating step with an uncertain outcome is held for reconciliation rather than retried.

The **Quick launch** Volume Down triple-press switch is off by default. A normal press still changes volume. Triple press opens the quick overlay and asks the BeanBao app to start recording. On the tested phone, a real spoken request completed from both an app and the unlocked Home screen. From Home, the overlay started recording and **Open Settings** brought Settings to the foreground.

## Data and limits

Keys and settings stay on the phone. The Agent audit file records a limited set of task events and results, without request text, note content, screenshots, model replies, or keys. On the tested RootHide device, the SSH view of this file is `/rootfs/private/var/mobile/Library/Application Support/BeanBao/audit.jsonl`.

BeanBao cannot silently install apps or send email without the user's action in the system interface. It does not delete content. A delivery order requires an exact checkout review and an explicit final tap in the browser. Checkout review, payment confirmation, and order history reconciliation have not been verified on a signed-in account; after a possible final click, the session stays in **Needs review** until its outcome can be established. BeanBao runs on the phone without a Mac, iCTRL, or Frida; those tools are used for development and verification. One previous version passed a physical USB-disconnect test. The current version still needs that test, a reboot recovery test, and validation on other devices. See [device tests](build-and-test.md) and [human acceptance](human-acceptance.md).
